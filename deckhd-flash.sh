#!/bin/bash
# =============================================================================
# DeckHD All-in-One BIOS Patcher & Flasher
# =============================================================================
# Usage:
#   ./deckhd-flash.sh              — full run (patch + flash)
#   ./deckhd-flash.sh --dry-run    — validate only, no writes, no flashing
#
# What this does:
#   1. Clones DeckHD/BiosMaker to get edid.bin and patcher.cpp
#   2. Reads patcher.cpp to extract the real patch byte patterns
#   3. Validates all patches can be found in your BIOS before touching anything
#   4. In dry-run: prints a full report and exits safely
#   5. In full run: patches, rebuilds .fd capsule, flashes with h2offt
#
# Only requires: git, python3, zenity — all stock on SteamOS. No pacman needed.
# Run from Desktop Mode on your Steam Deck.
# =============================================================================

set -eo pipefail

# ── Mode ──────────────────────────────────────────────────────────────────────
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}── $* ${NC}"; }

# ── Paths ─────────────────────────────────────────────────────────────────────
WORKDIR="$HOME/.deckhd-patcher"
BIOSMAKER_DIR="$WORKDIR/BiosMaker"
ORIGINAL_FD=$(ls /usr/share/jupiter_bios/F7A*_sign.fd 2>/dev/null | head -n1)
BACKUP_FD="$WORKDIR/original_backup.fd"
PATCHED_BIN="$WORKDIR/bios_DeckHD.bin"
PATCHED_FD="$WORKDIR/deckhd_patched.fd"

# ── Preflight ─────────────────────────────────────────────────────────────────
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

# ── Clone BiosMaker ───────────────────────────────────────────────────────────
clone_biosmaker() {
    section "Fetching DeckHD/BiosMaker"
    if [[ -d "$BIOSMAKER_DIR/.git" ]]; then
        git -C "$BIOSMAKER_DIR" pull --quiet && info "BiosMaker updated."
    else
        git clone --quiet https://github.com/DeckHD/BiosMaker.git "$BIOSMAKER_DIR"
        info "BiosMaker cloned."
    fi

    [[ -f "$BIOSMAKER_DIR/edid.bin" ]]    || die "edid.bin not found in BiosMaker repo."
    [[ -f "$BIOSMAKER_DIR/patcher.cpp" ]] || die "patcher.cpp not found in BiosMaker repo."
    info "edid.bin and patcher.cpp present."
}

# ── Backup ────────────────────────────────────────────────────────────────────
backup_bios() {
    section "Backup"
    if $DRY_RUN; then
        info "[dry-run] Would back up live BIOS to $WORKDIR/live_bios_backup.fd"
        info "[dry-run] Would copy $ORIGINAL_FD -> $BACKUP_FD"
        cp "$ORIGINAL_FD" "$BACKUP_FD"   # still need the template for validation
        return
    fi

    info "Backing up live BIOS to $WORKDIR/live_bios_backup.fd ..."
    sudo /usr/share/jupiter_bios_updater/h2offt "$WORKDIR/live_bios_backup.fd" -O \
        && info "Live BIOS backup saved." \
        || warn "Live BIOS backup failed (non-fatal). Continuing..."

    info "Copying original signed .fd as capsule template..."
    cp "$ORIGINAL_FD" "$BACKUP_FD"
}

# ── Validate & Patch (pure Python) ────────────────────────────────────────────
# In dry-run: only validates, prints report, exits with error if anything is wrong.
# In full run: validates first, then applies patches and writes output.
patch_bios() {
    section "Patch validation & application"

    python3 - "$BACKUP_FD" "$BIOSMAKER_DIR/edid.bin" \
              "$BIOSMAKER_DIR/patcher.cpp" \
              "$PATCHED_BIN" \
              "$DRY_RUN" << 'PYEOF'
import sys, struct, re, hashlib

fd_path      = sys.argv[1]
edid_path    = sys.argv[2]
patcher_cpp  = sys.argv[3]
out_path     = sys.argv[4]
dry_run      = sys.argv[5].lower() == "true"

BOLD  = "\033[1m"
GREEN = "\033[0;32m"
RED   = "\033[0;31m"
CYAN  = "\033[0;36m"
YELL  = "\033[1;33m"
NC    = "\033[0m"

def ok(msg):   print(f"  {GREEN}✓{NC} {msg}")
def fail(msg): print(f"  {RED}✗{NC} {msg}", file=sys.stderr)
def info(msg): print(f"  {CYAN}·{NC} {msg}")

errors = []

# ════════════════════════════════════════════════════════════════════════════
# STEP 1 — Parse patch patterns directly from patcher.cpp
# ════════════════════════════════════════════════════════════════════════════
print(f"\n{BOLD}[1/4] Reading patch patterns from patcher.cpp{NC}")

with open(patcher_cpp, 'r', errors='replace') as f:
    cpp_src = f.read()

# Extract byte array initializers: static const uint8_t name[] = { 0xNN, ... };
# Covers both "find" patterns and "replace" patterns named with conventions
# like patch_src_*, patch_dst_*, search_*, replace_*, before_*, after_*
array_re = re.compile(
    r'(?:uint8_t|const\s+uint8_t|unsigned\s+char)\s+(\w+)\s*\[\s*\]\s*=\s*\{([^}]+)\}',
    re.DOTALL
)

arrays = {}
for m in array_re.finditer(cpp_src):
    name = m.group(1)
    vals = [int(x, 16) for x in re.findall(r'0[xX][0-9a-fA-F]+', m.group(2))]
    if vals:
        arrays[name] = bytes(vals)

info(f"Found {len(arrays)} byte arrays in patcher.cpp: {', '.join(arrays.keys())}")

# Match src/dst pairs by naming convention (src_X paired with dst_X, etc.)
patch_pairs = []
# Try common naming patterns: *_src/*_dst, *_before/*_after, *_old/*_new, *_find/*_replace
for name, data in arrays.items():
    for suffix_src, suffix_dst in [('_src','_dst'),('_before','_after'),
                                    ('_old','_new'),('_find','_replace'),
                                    ('_search','_replace')]:
        if name.endswith(suffix_src):
            base = name[:-len(suffix_src)]
            dst_name = base + suffix_dst
            if dst_name in arrays:
                patch_pairs.append((name, dst_name, arrays[name], arrays[dst_name]))

if patch_pairs:
    ok(f"Identified {len(patch_pairs)} src/dst patch pair(s) from patcher.cpp naming.")
    for src_n, dst_n, src_b, dst_b in patch_pairs:
        info(f"  {src_n} ({len(src_b)}B) → {dst_n} ({len(dst_b)}B)")
else:
    # Fallback: if naming convention not matched, list what we found and warn
    warn_msg = (
        "Could not auto-pair src/dst arrays from patcher.cpp.\n"
        f"  Arrays found: {list(arrays.keys())}\n"
        "  The patcher.cpp may use non-standard naming.\n"
        "  Falling back to built-in patterns — verify manually!"
    )
    fail(warn_msg)
    errors.append("patcher.cpp pattern extraction failed — falling back to built-in patterns")

    # Built-in fallback patterns (1920x1200 DeckHD panel)
    patch_pairs = [
        ("builtin_h_src", "builtin_h_dst",
         bytes.fromhex("C2011202800500"), bytes.fromhex("C2011202800780")),
        ("builtin_v_src", "builtin_v_dst",
         bytes.fromhex("C2011202200320"), bytes.fromhex("C20112022004B0")),
    ]
    info("Using built-in fallback patterns — cross-check against patcher.cpp recommended!")

# ════════════════════════════════════════════════════════════════════════════
# STEP 2 — Load and inspect the BIOS image
# ════════════════════════════════════════════════════════════════════════════
print(f"\n{BOLD}[2/4] Inspecting BIOS capsule{NC}")

with open(fd_path, 'rb') as f:
    fd_data = f.read()

IFLASH_MARKER = b'$_IFLASH_BIOSIMG'
marker_pos = fd_data.find(IFLASH_MARKER)
if marker_pos == -1:
    fail("$_IFLASH_BIOSIMG marker not found in .fd capsule!")
    sys.exit(1)

payload_size  = struct.unpack_from('<I', fd_data, marker_pos + 20)[0]
payload_start = marker_pos + 24
bios = bytearray(fd_data[payload_start : payload_start + payload_size])

ok(f".fd capsule parsed — iFlash marker at 0x{marker_pos:08X}")
info(f"BIOS payload offset : 0x{payload_start:08X}")
info(f"BIOS payload size   : {len(bios):,} bytes ({len(bios)/1024/1024:.2f} MB)")
info(f"BIOS SHA256         : {hashlib.sha256(bios).hexdigest()[:16]}...")

# ════════════════════════════════════════════════════════════════════════════
# STEP 3 — Validate all patches and EDID
# ════════════════════════════════════════════════════════════════════════════
print(f"\n{BOLD}[3/4] Validating patches against BIOS image{NC}")

# Check EDID
with open(edid_path, 'rb') as f:
    new_edid = f.read()

EDID_HEADER = bytes([0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00])
if len(new_edid) != 128:
    fail(f"edid.bin is {len(new_edid)} bytes — expected 128!")
    errors.append("edid.bin wrong size")
else:
    ok(f"edid.bin is 128 bytes")

edid_pos = bios.find(EDID_HEADER)
if edid_pos == -1:
    fail("EDID header (00 FF FF FF FF FF FF 00) not found in BIOS!")
    errors.append("EDID not found in BIOS")
else:
    existing_edid = bios[edid_pos:edid_pos+128]
    edid_changed = existing_edid != new_edid
    ok(f"Existing EDID found at 0x{edid_pos:08X}")
    info(f"Existing EDID mfr  : {existing_edid[8]:02X}{existing_edid[9]:02X} "
         f"product {existing_edid[10]:02X}{existing_edid[11]:02X}")
    info(f"DeckHD   EDID mfr  : {new_edid[8]:02X}{new_edid[9]:02X} "
         f"product {new_edid[10]:02X}{new_edid[11]:02X}")
    if edid_changed:
        info("EDID will be replaced ✎")
    else:
        warn("EDID is already identical to DeckHD edid.bin — already patched?")

# Check byte patches
all_patches_ok = True
for src_name, dst_name, src_bytes, dst_bytes in patch_pairs:
    pos = bios.find(src_bytes)
    if pos == -1:
        # Check if destination pattern already present (already patched)
        already = bios.find(dst_bytes)
        if already != -1:
            warn(f"{src_name}: destination pattern already present at 0x{already:08X} — already patched?")
        else:
            fail(f"{src_name}: pattern NOT found in BIOS!")
            info(f"  Looking for : {src_bytes.hex(' ').upper()}")
            errors.append(f"Patch pattern '{src_name}' not found in BIOS")
            all_patches_ok = False
    else:
        ok(f"{src_name}: found at 0x{pos:08X}")
        info(f"  Before : {src_bytes.hex(' ').upper()}")
        info(f"  After  : {dst_bytes.hex(' ').upper()}")

# ════════════════════════════════════════════════════════════════════════════
# STEP 4 — Summary / apply
# ════════════════════════════════════════════════════════════════════════════
print(f"\n{BOLD}[4/4] {'Dry-run summary' if dry_run else 'Applying patches'}{NC}")

if errors:
    print(f"\n{RED}{BOLD}  VALIDATION FAILED — {len(errors)} issue(s):{NC}")
    for e in errors:
        fail(e)
    print(f"\n  Do NOT flash until these are resolved.\n")
    sys.exit(1)

if dry_run:
    print(f"\n  {GREEN}{BOLD}✓ All validations passed!{NC}")
    print(f"  {YELL}Dry-run complete — no files were written.{NC}")
    print(f"\n  To apply and flash, run without --dry-run.\n")
    sys.exit(0)

# Apply patches
bios[edid_pos : edid_pos + 128] = new_edid
ok("EDID replaced")

for src_name, _, src_bytes, dst_bytes in patch_pairs:
    pos = bios.find(src_bytes)
    if pos != -1:
        bios[pos : pos + len(dst_bytes)] = dst_bytes
        ok(f"{src_name} patched at 0x{pos:08X}")

with open(out_path, 'wb') as f:
    f.write(bios)

info(f"Patched BIOS written: {len(bios):,} bytes")
info(f"Output SHA256       : {hashlib.sha256(bios).hexdigest()[:16]}...")
print(f"\n  {GREEN}{BOLD}✓ Patch applied successfully.{NC}\n")
PYEOF

    info "Patch step complete."
}

# ── Rebuild .fd capsule ───────────────────────────────────────────────────────
rebuild_fd() {
    section "Rebuilding .fd capsule"

    if $DRY_RUN; then
        info "[dry-run] Would splice patched .bin back into .fd capsule wrapper."
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

bin_size = len(bin_data)
print(f"  Original payload : {stored_size:,} bytes")
print(f"  Patched .bin     : {bin_size:,} bytes")

header = bytearray(fd_data[:payload_start])
if bin_size != stored_size:
    print(f"  Size differs — updating size field in capsule header.")
    struct.pack_into('<I', header, marker_pos + 20, bin_size)

trailer  = fd_data[payload_start + stored_size:]
out_data = bytes(header) + bin_data + trailer

with open(out_path, 'wb') as f:
    f.write(out_data)

print(f"  Output .fd       : {len(out_data):,} bytes -> {out_path}")
PYEOF

    info ".fd capsule rebuilt successfully."
}

# ── Flash ─────────────────────────────────────────────────────────────────────
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

# ── Main ──────────────────────────────────────────────────────────────────────
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
    if $DRY_RUN; then
        echo -e "  \033[1;33mDRY-RUN MODE — validation only, nothing will be written or flashed\033[0m"
    else
        echo "  DeckHD All-in-One BIOS Patcher"
    fi
    echo ""

    preflight
    clone_biosmaker
    backup_bios
    patch_bios
    rebuild_fd
    flash_bios
}

main "$@"
