#!/bin/bash
# =============================================================================
# DeckHD All-in-One BIOS Patcher & Flasher
# =============================================================================
# Usage:
#   ./deckhd-flash.sh              — full run (patch + flash)
#   ./deckhd-flash.sh --dry-run    — validate only, no writes, no flashing
#
# Only requires: git, python3, zenity — all stock on SteamOS. No pacman needed.
# Uses Zig (downloaded as single binary to ~/. deckhd-patcher) to compile
# patcher.cpp — no system gcc/g++ required.
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
ZIG_DIR="$WORKDIR/zig"
ORIGINAL_FD=$(ls /usr/share/jupiter_bios/F7A*_sign.fd 2>/dev/null | head -n1)
BACKUP_FD="$WORKDIR/original_backup.fd"
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
    for cmd in git python3 zenity curl tar; do
        command -v "$cmd" &>/dev/null \
            || die "'$cmd' is missing. Try rebooting — it should be present on stock SteamOS."
    done
    info "Dependencies OK : git, python3, zenity, curl, tar"
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
    [[ -f "$BIOSMAKER_DIR/uninsyde" ]]    || die "uninsyde binary not found in BiosMaker repo."
    [[ -f "$BIOSMAKER_DIR/UEFIReplace" ]] || die "UEFIReplace binary not found in BiosMaker repo."
    [[ -f "$BIOSMAKER_DIR/patcher.cpp" ]] || die "patcher.cpp not found in BiosMaker repo."
    chmod +x "$BIOSMAKER_DIR/uninsyde" "$BIOSMAKER_DIR/UEFIReplace"
    info "BiosMaker ready (uninsyde, UEFIReplace, patcher.cpp, edid.bin present)."
}

# ── Install Zig (user-local, no sudo, no pacman) ──────────────────────────────
# Zig bundles its own C++ compiler — no system gcc needed.
install_zig() {
    section "Checking C++ compiler (Zig)"

    if [[ -x "$ZIG_DIR/zig" ]]; then
        info "Zig already present: $("$ZIG_DIR/zig" version)"
        return
    fi

    info "Downloading Zig (single binary, no sudo needed)..."
    # Zig 0.13.0 for x86_64-linux
    ZIG_VERSION="0.13.0"
    ZIG_TARBALL="zig-linux-x86_64-${ZIG_VERSION}.tar.xz"
    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"

    curl -L --progress-bar "$ZIG_URL" -o "$WORKDIR/$ZIG_TARBALL"
    mkdir -p "$ZIG_DIR"
    tar -xf "$WORKDIR/$ZIG_TARBALL" -C "$ZIG_DIR" --strip-components=1
    rm "$WORKDIR/$ZIG_TARBALL"

    [[ -x "$ZIG_DIR/zig" ]] || die "Zig extraction failed."
    info "Zig installed: $("$ZIG_DIR/zig" version)"
}

# ── Compile patcher.cpp via Zig ───────────────────────────────────────────────
compile_patcher() {
    section "Compiling patcher.cpp"

    if [[ -x "$BIOSMAKER_DIR/patcher" ]]; then
        info "patcher binary already compiled, skipping."
        return
    fi

    info "Compiling patcher.cpp with Zig c++ frontend..."
    # Zig can compile C/C++ directly: zig c++ <flags>
    "$ZIG_DIR/zig" c++ \
        -O2 \
        -o "$BIOSMAKER_DIR/patcher" \
        "$BIOSMAKER_DIR/patcher.cpp" \
        -I "$BIOSMAKER_DIR" \
        -lc

    [[ -x "$BIOSMAKER_DIR/patcher" ]] || die "patcher compilation failed."
    info "patcher compiled successfully."
}

# ── Backup ────────────────────────────────────────────────────────────────────
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

# ── Run biosmaker.sh (the real thing) ─────────────────────────────────────────
run_biosmaker() {
    section "Running biosmaker.sh"

    # biosmaker.sh must run from its own directory (uses relative paths)
    pushd "$BIOSMAKER_DIR" > /dev/null

    # It calls g++ internally — override with our Zig wrapper
    # Create a local g++ shim that redirects to zig c++
    mkdir -p "$BIOSMAKER_DIR/bin"
    cat > "$BIOSMAKER_DIR/bin/g++" << SHIMEOF
#!/bin/bash
exec "$ZIG_DIR/zig" c++ "\$@"
SHIMEOF
    chmod +x "$BIOSMAKER_DIR/bin/g++"
    export PATH="$BIOSMAKER_DIR/bin:$PATH"

    info "Running: biosmaker.sh $BACKUP_FD"
    bash biosmaker.sh "$BACKUP_FD"

    popd > /dev/null

    # biosmaker outputs F7A<version>_DeckHD.bin in its working dir
    BIOSVER=$(basename "$ORIGINAL_FD" | sed 's/_sign\.fd//')
    PATCHED_BIN="$BIOSMAKER_DIR/${BIOSVER}_DeckHD.bin"

    [[ -f "$PATCHED_BIN" ]] \
        || die "biosmaker.sh ran but ${BIOSVER}_DeckHD.bin not found. Check output above."

    info "Patched binary produced: $PATCHED_BIN"
}

# ── Validate patched .bin ─────────────────────────────────────────────────────
validate() {
    section "Validating patched .bin"

    python3 - "$PATCHED_BIN" "$DRY_RUN" << 'PYEOF'
import sys, struct, hashlib

bin_path = sys.argv[1]
dry_run  = sys.argv[2].lower() == "true"

GREEN="\033[0;32m"; RED="\033[0;31m"; CYAN="\033[0;36m"
YELL="\033[1;33m"; BOLD="\033[1m"; NC="\033[0m"

def ok(m):   print(f"  {GREEN}✓{NC} {m}")
def fail(m): print(f"  {RED}✗{NC} {m}", file=sys.stderr)
def info(m): print(f"  {CYAN}·{NC} {m}")

with open(bin_path, 'rb') as f:
    bios = f.read()

errors = []

# Check file size (should be 16MB)
if len(bios) != 0x1000000:
    fail(f"Unexpected size: {len(bios):,} bytes (expected 16,777,216)")
    errors.append("wrong size")
else:
    ok(f"File size correct: {len(bios):,} bytes (16 MB)")

# Check DeckHD version string is present
if b' DeckHD' in bios:
    ok("'DeckHD' version string found in patched BIOS")
else:
    fail("' DeckHD' version string NOT found — patcher may have failed")
    errors.append("DeckHD version string missing")

# Check DeckHD EDID manufacturer (11 04 = DeckHD panel)
# The new edid.bin has mfr 11 04 product 01 40
DECKHD_EDID_MFR = bytes([0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x11,0x04])
if DECKHD_EDID_MFR in bios:
    ok("DeckHD EDID (mfr 1104) found in patched BIOS")
else:
    fail("DeckHD EDID not found in patched BIOS")
    errors.append("DeckHD EDID missing")

info(f"SHA256: {hashlib.sha256(bios).hexdigest()[:32]}...")

if errors:
    print(f"\n  {RED}{BOLD}VALIDATION FAILED — {len(errors)} issue(s):{NC}")
    for e in errors: fail(e)
    print(f"\n  Do NOT flash.\n")
    sys.exit(1)

if dry_run:
    print(f"\n  {GREEN}{BOLD}✓ Dry-run validation passed!{NC}")
    print(f"  {YELL}Run without --dry-run to patch and flash.{NC}\n")
    sys.exit(0)

print(f"\n  {GREEN}{BOLD}✓ Validation passed — ready to rebuild .fd{NC}\n")
PYEOF
}

# ── Rebuild .fd capsule ───────────────────────────────────────────────────────
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
    $DRY_RUN \
        && echo -e "  \033[1;33mDRY-RUN MODE — validation only, nothing will be written or flashed\033[0m\n" \
        || echo -e "  DeckHD All-in-One BIOS Patcher\n"

    preflight
    clone_biosmaker
    install_zig
    compile_patcher
    backup_bios
    run_biosmaker
    validate
    rebuild_fd
    flash_bios
}

main "$@"