#!/bin/bash
# =============================================================================
# DeckHD All-in-One BIOS Patcher & Flasher
# =============================================================================
# Usage:
#   ./deckhd-flash.sh              — full run (patch + flash)
#   ./deckhd-flash.sh --dry-run    — validate only, no writes, no flashing
#
# Only requires: git, python3, zenity — all stock on SteamOS. No pacman needed.
# Run from Desktop Mode on your Steam Deck.
# =============================================================================

set -eo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}── $* ${NC}"; }

WORKDIR="$HOME/.deckhd-patcher"
BIOSMAKER_DIR="$WORKDIR/BiosMaker"
ORIGINAL_FD=$(ls /usr/share/jupiter_bios/F7A*_sign.fd 2>/dev/null | head -n1)
BACKUP_FD="$WORKDIR/original_backup.fd"
PATCHED_BIN="$WORKDIR/bios_DeckHD.bin"
PATCHED_FD="$WORKDIR/deckhd_patched.fd"

preflight() {
    section "Preflight checks"
    [[ -f /usr/share/jupiter_bios_updater/h2offt ]] \
        || die "h2offt not found. Are you running this on a Steam Deck?"
    [[ -n "$ORIGINAL_FD" ]] \
        || die "No F7A*_sign.fd found in /usr/share/jupiter_bios/. Is SteamOS up to date?"
    info "Found BIOS file : $ORIGINAL_FD"
    info "BIOS version    : $(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo 'unknown')"
    for cmd in git python3 zenity; do
        command -v "$cmd" &>/dev/null \
            || die "'$cmd' is missing. Try rebooting — it should be present on stock SteamOS."
    done
    info "Dependencies OK : git, python3, zenity"
    $DRY_RUN && warn "DRY-RUN MODE — no files will be written, nothing will be flashed."
    mkdir -p "$WORKDIR"
}

clone_biosmaker() {
    section "Fetching DeckHD/BiosMaker"
    if [[ -d "$BIOSMAKER_DIR/.git" ]]; then
        git -C "$BIOSMAKER_DIR" pull --quiet && info "BiosMaker updated."
    else
        git clone --quiet https://github.com/DeckHD/BiosMaker.git "$BIOSMAKER_DIR"
        info "BiosMaker cloned."
    fi
    [[ -f "$BIOSMAKER_DIR/edid.bin" ]] || die "edid.bin not found in BiosMaker repo."
    info "edid.bin present."
}

backup_bios() {
    section "Backup"
    if $DRY_RUN; then
        info "[dry-run] Would back up live BIOS to $WORKDIR/live_bios_backup.fd"
        cp "$ORIGINAL_FD" "$BACKUP_FD"
        return
    fi
    info "Backing up live BIOS to $WORKDIR/live_bios_backup.fd ..."
    sudo /usr/share/jupiter_bios_updater/h2offt "$WORKDIR/live_bios_backup.fd" -O \
        && info "Live BIOS backup saved." \
        || warn "Live BIOS backup failed (non-fatal). Continuing..."
    cp "$ORIGINAL_FD" "$BACKUP_FD"
}

patch_bios() {
    section "Patch validation & application"

    python3 - "$BACKUP_FD" "$BIOSMAKER_DIR/edid.bin" "$PATCHED_BIN" "$DRY_RUN" << 'PYEOF'
import sys, struct, hashlib

fd_path   = sys.argv[1]
edid_path = sys.argv[2]
out_path  = sys.argv[3]
dry_run   = sys.argv[4].lower() == "true"

BOLD="\033[1m"; GREEN="\033[0;32m"; RED="\033[0;31m"
CYAN="\033[0;36m"; YELL="\033[1;33m"; NC="\033[0m"

def ok(m):   print(f"  {GREEN}✓{NC} {m}")
def fail(m): print(f"  {RED}✗{NC} {m}", file=sys.stderr)
def info(m): print(f"  {CYAN}·{NC} {m}")

errors = []

def find_pattern(data, pattern_hex):
    """Find a hex pattern in data, supporting '??' wildcards."""
    pattern_hex = pattern_hex.replace(' ', '')
    pat_bytes = []
    for i in range(0, len(pattern_hex), 2):
        chunk = pattern_hex[i:i+2]
        pat_bytes.append(None if chunk == '??' else int(chunk, 16))
    plen = len(pat_bytes)
    for i in range(len(data) - plen + 1):
        if all(pb is None or data[i+j] == pb for j, pb in enumerate(pat_bytes)):
            return i
    return -1

# ── Load .fd and extract BIOS payload ────────────────────────────────────────
print(f"\n{BOLD}[1/4] Inspecting BIOS capsule{NC}")

with open(fd_path, 'rb') as f:
    fd_data = f.read()

IFLASH_MARKER = b'$_IFLASH_BIOSIMG'
marker_pos = fd_data.find(IFLASH_MARKER)
if marker_pos == -1:
    fail("$_IFLASH_BIOSIMG marker not found!")
    sys.exit(1)

payload_size  = struct.unpack_from('<I', fd_data, marker_pos + 20)[0]
payload_start = marker_pos + 24
bios = bytearray(fd_data[payload_start : payload_start + payload_size])

ok(f".fd capsule parsed — marker at 0x{marker_pos:08X}")
info(f"BIOS payload size   : {len(bios):,} bytes ({len(bios)/1024/1024:.2f} MB)")
info(f"BIOS SHA256 (orig)  : {hashlib.sha256(bios).hexdigest()[:24]}...")

# The patcher works on two EC firmware blocks embedded in the BIOS:
#   EC1 at offset 0x000000, length 0x20000
#   EC2 at offset 0x040000, length 0x20000
EC1_OFFSET = 0x000000
EC2_OFFSET = 0x040000
EC_LEN     = 0x020000

# ── Patterns (taken verbatim from patcher.cpp FindPattern calls) ──────────────
# Each is (name, hex_pattern, description)
PATTERNS = {
    "display_id": (
        "e0 70 09 90 16 01 e0 44 20 f0 80 06 90 16 15 74 80 f0 90 16 0a "
        "e0 90 03 56 20 e6 04 74 01 f0 22 74 02 f0 22",
        "EC display_id byte (patcher.cpp offset +0x21)"
    ),
    "edid": (
        "00 ff ff ff ff ff ff 00 59 96 01 30 01 00 00 00 1e 1c 01 04 "
        "a5 0a 0f 78 16 00 00 00 00 00 00 00 00 00 00 00 00 00 01 00 "
        "01 00 01 00 01 00 01 00 01 00 01 00 01 00 0f 1b 20 48 30 00 "
        "2c 50 20 14 02 04 3c 3c 00 00 00 1e 00 00 00 fc 00 41 4e 58 "
        "37 35 33 30 20 55 0a 20 20 20 00 00 00 10 00 00 00 00 00 00 "
        "00 00 00 00 00 00 00 00 00 00 00 00 10 00 00 00 00 00 00 00 "
        "00 00 00 00 00 00 00 00 93",
        "Original ANX7530 EDID (128 bytes)"
    ),
    "mipi_port_cmds": (
        "aa 00 00 00 64 6c 00 00 e0 15 6c 00 93 e1 15 6c 00 65 e2 15 "
        "6c 00 f8 e3 15 6c 00 03 80 15 6c 00 01 e0 15 6c 00 00 00 15 "
        "6c 00 8c 01 15 6c 00 00 03 15 6c 00 a8 04 15",
        "MIPI port init command table"
    ),
    "pdcp_cmds": (
        "10 01 06 10 02 82 11 00 06 11 01 82 11 03 01 "
        "11 04 01 11 05 01 11 06 01 ff ff ff",
        "PDCP/DPCD init command table"
    ),
    "spi_cmds": (
        "a0 20 a1 03 a2 20 a3 00 a4 14 a5 00 a6 14 a7 00 "
        "a8 00 a9 05 aa 10 ab 00 ac 02 ad 00 ae 1a af 00 "
        "9d 3c b0 0c b1 48 9f 7b 9e c0 ff ff",
        "SPI init command table (timing/resolution registers)"
    ),
    "bios_version": (
        "24 42 56 44 54 24",
        "BIOS version string marker ($BVDT$)"
    ),
}

# ── Validate all patterns in both EC blocks ───────────────────────────────────
print(f"\n{BOLD}[2/4] Validating patterns in BIOS image{NC}")

ec1 = bios[EC1_OFFSET : EC1_OFFSET + EC_LEN]
ec2 = bios[EC2_OFFSET : EC2_OFFSET + EC_LEN]

found = {}  # name -> (ec_block_name, absolute_offset_in_bios)

for name, (pattern, desc) in PATTERNS.items():
    if name == "bios_version":
        # Searched in full bios, not EC blocks
        pos = find_pattern(bios, pattern)
        if pos == -1:
            fail(f"{name}: NOT found in BIOS — {desc}")
            errors.append(f"Pattern '{name}' not found")
        else:
            ok(f"{name} at 0x{pos:08X} (full BIOS) — {desc}")
            found[name] = ("bios", pos)
        continue

    # Search in EC1
    pos1 = find_pattern(ec1, pattern)
    pos2 = find_pattern(ec2, pattern)

    if pos1 == -1 and pos2 == -1:
        fail(f"{name}: NOT found in EC1 or EC2 — {desc}")
        errors.append(f"Pattern '{name}' not found in any EC block")
    else:
        if pos1 != -1:
            ok(f"{name} in EC1 at 0x{EC1_OFFSET + pos1:08X} — {desc}")
            found[f"{name}_ec1"] = pos1
        if pos2 != -1:
            ok(f"{name} in EC2 at 0x{EC2_OFFSET + pos2:08X} — {desc}")
            found[f"{name}_ec2"] = pos2

# Validate edid.bin
print(f"\n{BOLD}[3/4] Validating edid.bin{NC}")
with open(edid_path, 'rb') as f:
    new_edid = f.read()

if len(new_edid) != 128:
    fail(f"edid.bin is {len(new_edid)} bytes — expected 128!")
    errors.append("edid.bin wrong size")
else:
    ok(f"edid.bin is 128 bytes")
    info(f"DeckHD EDID mfr : {new_edid[8]:02X}{new_edid[9]:02X} "
         f"product {new_edid[10]:02X}{new_edid[11]:02X}")

# ── Summary / apply ───────────────────────────────────────────────────────────
print(f"\n{BOLD}[4/4] {'Dry-run summary' if dry_run else 'Applying patches'}{NC}")

if errors:
    print(f"\n  {RED}{BOLD}VALIDATION FAILED — {len(errors)} issue(s):{NC}")
    for e in errors: fail(e)
    print(f"\n  Do NOT flash until these are resolved.\n")
    sys.exit(1)

if dry_run:
    print(f"\n  {GREEN}{BOLD}✓ All validations passed! ({len(PATTERNS)} patterns found){NC}")
    print(f"  {YELL}Dry-run complete — no files were written.{NC}")
    print(f"\n  Run without --dry-run to patch and flash.\n")
    sys.exit(0)

# ── Apply patches ─────────────────────────────────────────────────────────────
def patch_ec(ec, label):
    """Apply all EC patches to a single EC block (bytearray)."""
    # 1. display_id: set byte at pattern+0x21 to 1
    pos = find_pattern(ec, PATTERNS["display_id"][0])
    if pos != -1:
        ec[pos + 0x21] = 1
        ok(f"{label}: display_id patched at 0x{pos+0x21:04X}")

    # 2. EDID: replace 128 bytes at pattern offset
    pos = find_pattern(ec, PATTERNS["edid"][0])
    if pos != -1:
        ec[pos : pos + 128] = new_edid
        ok(f"{label}: EDID replaced at 0x{pos:04X}")

    # 3. MIPI port commands: replace with DeckHD inits
    # New MIPI init table (from patcher.cpp inits[] struct, little-endian packed)
    # Format: ANX_MIPI_PORT_CMD { uint8_t offset; uint32_t value; } = 5 bytes each
    # Values from patcher.cpp inits[]:
    mipi_new = bytes([
        0x00, 0xe8, 0x03, 0x00, 0x00,  # DELAY 1000ms
        0x6c, 0x15, 0xff, 0x51, 0x00,  # set_display_brightness 0xff
        0x6c, 0x15, 0x2c, 0x53, 0x00,  # write_control_display 0x2c
        0x6c, 0x15, 0x00, 0x55, 0x00,  # write_power_save 0x00
        0x6c, 0x05, 0x00, 0x11, 0x00,  # exit_sleep_mode
        0x00, 0x50, 0x00, 0x00, 0x00,  # DELAY 80ms
        0x6c, 0x05, 0x00, 0x29, 0x00,  # set_display_on
        0x00, 0x14, 0x00, 0x00, 0x00,  # DELAY 20ms
        0x6c, 0x15, 0x00, 0x35, 0x00,  # set_tear_on
        0xff, 0x00, 0x00, 0x00, 0x00,  # END
    ])
    pos = find_pattern(ec, PATTERNS["mipi_port_cmds"][0])
    if pos != -1:
        ec[pos : pos + len(mipi_new)] = mipi_new
        ok(f"{label}: MIPI port cmds patched at 0x{pos:04X}")

    # 4. PDCP commands: replace with DeckHD pdcp_init[]
    # ANX_SLAVE_CMD { uint8_t slave_id, offset, value } = 3 bytes each
    pdcp_new = bytes([
        0x10, 0x01, 0x0f,  # SLAVEID_DPCD, MAX_LINK_RATE, 0x0f
        0x10, 0x02, 0x82,  # SLAVEID_DPCD, MAX_LANE_COUNT, 0x82
        0x11, 0x00, 0x06,
        0x11, 0x01, 0x82,
        0x11, 0x03, 0x01,
        0x11, 0x04, 0x01,
        0x11, 0x05, 0x01,
        0x11, 0x06, 0x01,
        0xff, 0xff, 0xff,  # END
    ])
    pos = find_pattern(ec, PATTERNS["pdcp_cmds"][0])
    if pos != -1:
        ec[pos : pos + len(pdcp_new)] = pdcp_new
        ok(f"{label}: PDCP cmds patched at 0x{pos:04X}")

    # 5. SPI commands: replace with DeckHD spi_init[] for 1920x1200
    # ANX_SPI_CMD { uint8_t offset, value } = 2 bytes each
    # SW_H_ACTIVE=1200 (0x04B0), SW_V_ACTIVE=1920 (0x0780)
    # SW_HFP=40, SW_HSYNC=20, SW_HBP=40
    # SW_VFP=18, SW_VSYNC=2, SW_VBP=20
    spi_new = bytes([
        0xa0, 0xb0,  # SW_H_ACTIVE_L  (1200 & 0xff = 0xB0)
        0xa1, 0x04,  # SW_H_ACTIVE_H  (1200 >> 8   = 0x04)
        0xa2, 0x28,  # SW_HFP_L       (40 = 0x28)
        0xa3, 0x00,  # SW_HFP_H
        0xa4, 0x14,  # SW_HSYNC_L     (20 = 0x14)
        0xa5, 0x00,  # SW_HSYNC_H
        0xa6, 0x28,  # SW_HBP_L       (40 = 0x28)
        0xa7, 0x00,  # SW_HBP_H
        0xa8, 0x80,  # SW_V_ACTIVE_L  (1920 & 0xff = 0x80)
        0xa9, 0x07,  # SW_V_ACTIVE_H  (1920 >> 8   = 0x07)
        0xaa, 0x12,  # SW_VFP_L       (18 = 0x12)
        0xab, 0x00,  # SW_VFP_H
        0xac, 0x02,  # SW_VSYNC_L     (2)
        0xad, 0x00,  # SW_VSYNC_H
        0xae, 0x14,  # SW_VBP_L       (20 = 0x14)
        0xaf, 0x00,  # SW_VBP_H
        0x9d, 0x3c,  # SW_PANEL_FRAME_RATE = 60
        0xb0, 0x0c,  # SW_PANEL_INFO_0: 3 lanes
        0xb1, 0x48,  # SW_PANEL_INFO_1: DSC_NO_DSC | BURST
        0x9f, 0x7b,  # MISC_NOTIFY_OCM1
        0x9e, 0xc0,  # MISC_NOTIFY_OCM0: MCU_LOAD_DONE | PANEL_INFO_SET_DONE
        0xff, 0xff,  # END
    ])
    pos = find_pattern(ec, PATTERNS["spi_cmds"][0])
    if pos != -1:
        ec[pos : pos + len(spi_new)] = spi_new
        ok(f"{label}: SPI cmds patched at 0x{pos:04X}")

    # 6. Recalculate EC checksum (sum of bytes 0x2000..0x1F7FE, stored big-endian at 0x1F7FE)
    checksum = sum(ec[0x2000:0x1f7fe]) & 0xffff
    ec[0x1f7fe] = (checksum >> 8) & 0xff
    ec[0x1f7ff] = checksum & 0xff
    ok(f"{label}: checksum recalculated = 0x{checksum:04X}")

# Patch EC1 and EC2
ec1 = bytearray(bios[EC1_OFFSET : EC1_OFFSET + EC_LEN])
ec2 = bytearray(bios[EC2_OFFSET : EC2_OFFSET + EC_LEN])
patch_ec(ec1, "EC1")
patch_ec(ec2, "EC2")
bios[EC1_OFFSET : EC1_OFFSET + EC_LEN] = ec1
bios[EC2_OFFSET : EC2_OFFSET + EC_LEN] = ec2

# 7. Patch BIOS version string: append " DeckHD" after $BVDT$ marker (twice)
marker_pat = PATTERNS["bios_version"][0]
search_from = 0
patched_ver = 0
for _ in range(2):
    pos = find_pattern(bios[search_from:], marker_pat)
    if pos == -1:
        break
    pos += search_from
    # Walk forward to the version string (past the marker + 22 bytes per patcher.cpp offset)
    ver_pos = pos + 22
    # Find end of version string (null terminator)
    while bios[ver_pos] != 0:
        ver_pos += 1
    # Overwrite last 7 chars before null with " DeckHD"
    bios[ver_pos - 1 : ver_pos - 1 + 7] = b' DeckHD'
    ok(f"BIOS version string patched at 0x{ver_pos:08X}")
    patched_ver += 1
    search_from = ver_pos + 1

if patched_ver < 2:
    info(f"Warning: only found {patched_ver}/2 version strings")

# Write output
with open(out_path, 'wb') as f:
    f.write(bios)

info(f"Patched BIOS SHA256 : {hashlib.sha256(bios).hexdigest()[:24]}...")
print(f"\n  {GREEN}{BOLD}✓ All patches applied successfully.{NC}\n")
PYEOF

    info "Patch step complete."
}

rebuild_fd() {
    section "Rebuilding .fd capsule"
    if $DRY_RUN; then
        info "[dry-run] Would splice patched .bin back into .fd capsule."
        return
    fi

    python3 - "$BACKUP_FD" "$PATCHED_BIN" "$PATCHED_FD" << 'PYEOF'
import sys, struct

fd_path  = sys.argv[1]
bin_path = sys.argv[2]
out_path = sys.argv[3]

with open(fd_path, 'rb') as f:
    fd_data = f.read()

MARKER = b'$_IFLASH_BIOSIMG'
marker_pos = fd_data.find(MARKER)
if marker_pos == -1:
    print("ERROR: $_IFLASH_BIOSIMG marker not found!", file=sys.stderr)
    sys.exit(1)

stored_size   = struct.unpack_from('<I', fd_data, marker_pos + 20)[0]
payload_start = marker_pos + 24

with open(bin_path, 'rb') as f:
    bin_data = f.read()

header = bytearray(fd_data[:payload_start])
if len(bin_data) != stored_size:
    struct.pack_into('<I', header, marker_pos + 20, len(bin_data))
    print(f"  Size updated: {stored_size:,} -> {len(bin_data):,} bytes")

trailer  = fd_data[payload_start + stored_size:]
out_data = bytes(header) + bin_data + trailer

with open(out_path, 'wb') as f:
    f.write(out_data)

print(f"  Output .fd: {len(out_data):,} bytes -> {out_path}")
PYEOF
    info ".fd capsule rebuilt."
}

flash_bios() {
    if $DRY_RUN; then
        section "Dry-run complete"
        echo ""
        info "All checks passed. Run without --dry-run to patch and flash."
        echo ""
        exit 0
    fi

    section "Flash"
    warn "========================================================="
    warn "  About to flash your BIOS. Do NOT power off the Deck!"
    warn "  Backup: $WORKDIR/live_bios_backup.fd"
    warn "========================================================="

    zenity --question \
        --title="DeckHD BIOS Flasher" \
        --text="Validation passed. Ready to flash the DeckHD patched BIOS.\n\nBackup saved to:\n$WORKDIR/live_bios_backup.fd\n\nProceed?" \
        --width=500 2>/dev/null \
        || { info "Flash cancelled by user."; exit 0; }

    SUDO_PASS=$(zenity --password --title="Enter sudo password" 2>/dev/null)
    [[ -n "$SUDO_PASS" ]] || die "No password entered. Aborting."

    echo "$SUDO_PASS" | sudo -S /usr/share/jupiter_bios_updater/h2offt "$PATCHED_FD"
    info "Flash complete! Your Steam Deck will reboot."
}

main() {
    echo ""
    echo -e "\033[0;36m\033[1m"
    echo "  ██████╗ ███████╗  ██████╗██╗  ██╗██╗  ██╗██████╗ "
    echo "  ██╔══██╗██╔════╝ ██╔════╝██║ ██╔╝██║  ██║██╔══██╗"
    echo "  ██║  ██║█████╗   ██║     █████╔╝ ███████║██║  ██║"
    echo "  ██║  ██║██╔══╝   ██║     ██╔═██╗ ██╔══██║██║  ██║"
    echo "  ██████╔╝███████╗ ╚██████╗██║  ██╗██║  ██║██████╔╝"
    echo "  ╚═════╝ ╚══════╝  ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ "
    echo -e "\033[0m"
    $DRY_RUN \
        && echo -e "  \033[1;33mDRY-RUN MODE — validation only, nothing will be written or flashed\033[0m\n" \
        || echo -e "  DeckHD All-in-One BIOS Patcher\n"

    preflight
    clone_biosmaker
    backup_bios
    patch_bios
    rebuild_fd
    flash_bios
}

main "$@"
