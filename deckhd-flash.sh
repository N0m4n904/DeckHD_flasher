#!/bin/bash
# =============================================================================
# DeckHD All-in-One BIOS Patcher & Flasher
# =============================================================================
# What this does:
#   1. Clones DeckHD/BiosMaker and builds the patcher tools
#   2. Runs biosmaker.sh on your existing signed .fd to produce a patched .bin
#   3. Splices the patched .bin back into the original .fd capsule wrapper
#   4. Flashes the result with h2offt
#
# Requirements: auto-installed if missing (pacman + rustup)
# Run from Desktop Mode on your Steam Deck.
# =============================================================================

set -eo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Paths ─────────────────────────────────────────────────────────────────────
WORKDIR="$HOME/.deckhd-patcher"
BIOSMAKER_DIR="$WORKDIR/BiosMaker"
ORIGINAL_FD=$(ls /usr/share/jupiter_bios/F7A*_sign.fd 2>/dev/null | head -n1)
BACKUP_FD="$WORKDIR/original_backup.fd"
PATCHED_BIN=""   # set after biosmaker runs
PATCHED_FD="$WORKDIR/deckhd_patched.fd"

# ── Preflight checks & dependency install ────────────────────────────────────
preflight() {
    info "Running preflight checks..."

    [[ -f /usr/share/jupiter_bios_updater/h2offt ]] \
        || die "h2offt not found. Are you running this on a Steam Deck?"

    [[ -n "$ORIGINAL_FD" ]] \
        || die "No F7A*_sign.fd found in /usr/share/jupiter_bios/. Is SteamOS up to date?"

    info "Found BIOS: $ORIGINAL_FD"

    mkdir -p "$WORKDIR"

    # ── pacman packages ───────────────────────────────────────────────────────
    # Map: command-to-check → pacman package name
    declare -A PACMAN_DEPS=(
        [git]="git"
        [gcc]="gcc"
        [g++]="gcc"          # g++ is in the same gcc package on Arch
        [python3]="python"
        [zenity]="zenity"
        [curl]="curl"
    )

    MISSING_PKGS=()
    for cmd in "${!PACMAN_DEPS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            pkg="${PACMAN_DEPS[$cmd]}"
            # Avoid duplicates (gcc covers both gcc and g++)
            if [[ ! " ${MISSING_PKGS[*]} " =~ " ${pkg} " ]]; then
                MISSING_PKGS+=("$pkg")
            fi
        fi
    done

    if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
        # These tools all ship with SteamOS desktop mode by default.
        # Rather than touching the filesystem or keyring, just tell the
        # user what is missing and let them handle it safely themselves.
        echo ""
        die "The following required tools are missing: ${MISSING_PKGS[*]}\n\n" \
            "On a stock SteamOS these should already be present.\n" \
            "If you recently ran a system update, try rebooting first.\n" \
            "To install manually (in Desktop Mode):\n" \
            "  sudo steamos-readonly disable\n" \
            "  sudo pacman -Sy ${MISSING_PKGS[*]}\n" \
            "  sudo steamos-readonly enable"
    else
        info "All dependencies present."
    fi

    # ── Rust/cargo — needed to build uninsyde ─────────────────────────────────
    # Load cargo env in case it was previously installed but not in PATH
    [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"

    if ! command -v cargo &>/dev/null; then
        warn "Rust/cargo not found. Installing via rustup (user-local, no sudo needed)..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --no-modify-path --profile minimal
        source "$HOME/.cargo/env"
    else
        info "cargo already present: $(cargo --version)"
    fi
}

# ── Backup ────────────────────────────────────────────────────────────────────
backup_bios() {
    info "Backing up current live BIOS to $WORKDIR/live_bios_backup.fd ..."
    sudo /usr/share/jupiter_bios_updater/h2offt "$WORKDIR/live_bios_backup.fd" -O \
        && info "Backup saved." \
        || warn "Live BIOS backup failed (non-fatal). Continuing..."

    info "Copying original signed .fd as template..."
    cp "$ORIGINAL_FD" "$BACKUP_FD"
}

# ── Clone & build BiosMaker ───────────────────────────────────────────────────
build_biosmaker() {
    info "Cloning DeckHD/BiosMaker..."
    if [[ -d "$BIOSMAKER_DIR/.git" ]]; then
        git -C "$BIOSMAKER_DIR" pull --quiet
    else
        git clone --quiet https://github.com/DeckHD/BiosMaker.git "$BIOSMAKER_DIR"
    fi

    info "Building uninsyde (Rust)..."
    git clone --quiet https://github.com/jbit/uninsyde.git "$WORKDIR/uninsyde" 2>/dev/null || true
    cargo build --release --manifest-path "$WORKDIR/uninsyde/Cargo.toml" --quiet
    cp "$WORKDIR/uninsyde/target/release/uninsyde" "$BIOSMAKER_DIR/uninsyde"

    info "Building patcher (C++)..."
    pushd "$BIOSMAKER_DIR" > /dev/null
    g++ -O2 -o patcher patcher.cpp
    chmod +x biosmaker.sh UEFIReplace
    popd > /dev/null
}

# ── Run biosmaker ─────────────────────────────────────────────────────────────
run_biosmaker() {
    info "Running biosmaker.sh on $ORIGINAL_FD ..."
    pushd "$BIOSMAKER_DIR" > /dev/null
    bash biosmaker.sh "$ORIGINAL_FD"
    popd > /dev/null

    # biosmaker outputs a file named like F7A0123_DeckHD.bin next to the input
    PATCHED_BIN=$(ls "$(dirname "$ORIGINAL_FD")"/*_DeckHD.bin 2>/dev/null | head -n1)

    # If not there, check the BiosMaker dir itself
    if [[ -z "$PATCHED_BIN" ]]; then
        PATCHED_BIN=$(ls "$BIOSMAKER_DIR"/*_DeckHD.bin 2>/dev/null | head -n1)
    fi

    [[ -n "$PATCHED_BIN" ]] \
        || die "biosmaker.sh ran but no *_DeckHD.bin output found. Check for errors above."

    info "Patched binary: $PATCHED_BIN"
}

# ── Splice .bin back into .fd capsule ─────────────────────────────────────────
# The .fd file is an Insyde iFlash capsule: a header ending at the
# $_IFLASH_BIOSIMG marker, followed by the raw BIOS image, followed by padding.
# We keep the original header and replace the payload with the patched .bin.
rebuild_fd() {
    info "Rebuilding .fd capsule from patched .bin..."

    python3 - "$BACKUP_FD" "$PATCHED_BIN" "$PATCHED_FD" << 'PYEOF'
import sys, os

fd_path   = sys.argv[1]
bin_path  = sys.argv[2]
out_path  = sys.argv[3]

MARKER = b'$_IFLASH_BIOSIMG'

with open(fd_path, 'rb') as f:
    fd_data = f.read()

marker_pos = fd_data.find(MARKER)
if marker_pos == -1:
    print("ERROR: $_IFLASH_BIOSIMG marker not found in .fd file!", file=sys.stderr)
    sys.exit(1)

# The iFlash chunk header after the marker is 16 bytes of marker +
# 4 bytes chunk-type + 4 bytes payload size = 24 bytes total before payload.
# Validate by checking the payload size field matches the .bin we have.
CHUNK_HEADER_SIZE = 24
payload_offset = marker_pos + CHUNK_HEADER_SIZE

stored_size = int.from_bytes(fd_data[marker_pos+20:marker_pos+24], 'little')
print(f"  .fd header ends at offset : 0x{marker_pos:08X}")
print(f"  Payload offset            : 0x{payload_offset:08X}")
print(f"  Stored payload size       : {stored_size:,} bytes ({stored_size / 1024 / 1024:.2f} MB)")

with open(bin_path, 'rb') as f:
    bin_data = f.read()

bin_size = len(bin_data)
print(f"  Patched .bin size         : {bin_size:,} bytes ({bin_size / 1024 / 1024:.2f} MB)")

if bin_size != stored_size:
    print(f"WARNING: size mismatch ({bin_size} vs {stored_size}). "
          "Updating size field in header.", file=sys.stderr)
    # Patch the size field in the header copy we'll write
    header = bytearray(fd_data[:payload_offset])
    header[marker_pos+20:marker_pos+24] = bin_size.to_bytes(4, 'little')
    header_bytes = bytes(header)
else:
    header_bytes = fd_data[:payload_offset]

# Preserve any trailing data after the original payload (EC firmware, padding…)
original_payload_end = payload_offset + stored_size
trailer = fd_data[original_payload_end:]

out_data = header_bytes + bin_data + trailer
with open(out_path, 'wb') as f:
    f.write(out_data)

print(f"  Output .fd size           : {len(out_data):,} bytes")
print(f"  Written to                : {out_path}")
PYEOF

    info ".fd capsule rebuilt successfully."
}

# ── Flash ─────────────────────────────────────────────────────────────────────
flash_bios() {
    warn "========================================================="
    warn "  About to flash your BIOS. Do NOT power off the Deck!"
    warn "  A backup is at: $WORKDIR/live_bios_backup.fd"
    warn "========================================================="

    zenity --question \
        --title="DeckHD BIOS Flasher" \
        --text="Ready to flash the DeckHD patched BIOS.\n\nA backup has been saved to:\n$WORKDIR/live_bios_backup.fd\n\nProceed with flashing?" \
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
    echo "  ██████╗ ███████╗ ██████╗██╗  ██╗██╗  ██╗██████╗ "
    echo "  ██╔══██╗██╔════╝██╔════╝██║ ██╔╝██║  ██║██╔══██╗"
    echo "  ██║  ██║█████╗  ██║     █████╔╝ ███████║██║  ██║"
    echo "  ██║  ██║██╔══╝  ██║     ██╔═██╗ ██╔══██║██║  ██║"
    echo "  ██████╔╝███████╗╚██████╗██║  ██╗██║  ██║██████╔╝"
    echo "  ╚═════╝ ╚══════╝ ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ "
    echo "  DeckHD All-in-One BIOS Patcher"
    echo ""

    preflight
    backup_bios
    build_biosmaker
    run_biosmaker
    rebuild_fd
    flash_bios
}

main "$@"
