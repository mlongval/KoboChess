#!/usr/bin/env bash
#
# Install Kobo Chess onto a Kobo running KOReader.
#
# Two ways to install:
#
#   ./install.sh kobo                 copy over SSH to a networked device
#   ./install.sh /media/you/KOBO      copy to a USB-mounted device
#
# The first form takes any ssh target (a host from ~/.ssh/config, user@ip, or
# a Tailscale name). The second takes the mount point of the Kobo's user
# partition -- the folder that appears when you plug the device in.
#
# Pass --with-nickelmenu to also install the NickelMenu entry, which puts
# "Chess" on the Kobo home screen menu.
#
# KOReader's built-in SSH server listens on a non-standard port and often with
# no password, which plain ssh cannot do unattended. Override the commands for
# that case:
#
#   SSH="sshpass -p '' ssh -p 2222" SCP="sshpass -p '' scp -P 2222" \
#       ./install.sh root@<kobo-ip> --with-nickelmenu

set -euo pipefail

PLUGIN_DIR="kobochess.koplugin"
# Where KOReader lives on a Kobo, relative to the user partition.
KOREADER_REL=".adds/koreader"

# Overridable so the script can drive KOReader's SSH server, which uses a
# non-standard port and may accept a blank password.
SSH=${SSH:-ssh}
SCP=${SCP:-scp}

usage() {
    # Print the header comment block, so the usage text and the documentation
    # at the top of this file can never drift apart.
    awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "$0"
    exit 1
}

WITH_NM=0
TARGET=""
for arg in "$@"; do
    case "$arg" in
        --with-nickelmenu) WITH_NM=1 ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $arg" >&2; usage ;;
        *) TARGET="$arg" ;;
    esac
done
[[ -n "$TARGET" ]] || usage

cd "$(dirname "$0")"

if [[ ! -d "$PLUGIN_DIR" ]]; then
    echo "error: $PLUGIN_DIR not found (run this from the project root)" >&2
    exit 1
fi
if [[ ! -f "$PLUGIN_DIR/pieces/wk.png" ]]; then
    echo "error: piece images are missing -- run: python3 tools/gen_pieces.py" >&2
    exit 1
fi

# --- USB-mounted device -----------------------------------------------------
if [[ -d "$TARGET" ]]; then
    DEST="$TARGET/$KOREADER_REL/plugins"
    if [[ ! -d "$TARGET/$KOREADER_REL" ]]; then
        echo "error: no KOReader at $TARGET/$KOREADER_REL" >&2
        echo "       is this the Kobo's user partition, and is KOReader installed?" >&2
        exit 1
    fi
    echo "Installing to $DEST"
    mkdir -p "$DEST"
    rm -rf "${DEST:?}/$PLUGIN_DIR"
    cp -r "$PLUGIN_DIR" "$DEST/"
    # Kobos are FAT32; strip anything that cannot survive the trip.
    find "$DEST/$PLUGIN_DIR" -name '._*' -delete 2>/dev/null || true

    if [[ $WITH_NM -eq 1 ]]; then
        if [[ ! -d "$TARGET/.adds/nm" ]]; then
            echo "warning: no NickelMenu at $TARGET/.adds/nm -- skipping menu entry" >&2
        else
            cp nickelmenu/kobochess "$TARGET/.adds/nm/kobochess"
            cp nickelmenu/kobochess-launch.sh "$TARGET/.adds/kobochess-launch.sh"
            echo "Installed the NickelMenu entry."
        fi
    fi

    sync
    echo "Done. Eject the device, then open KOReader → menu → Tools → Chess."
    exit 0
fi

# --- Over SSH ---------------------------------------------------------------
echo "Installing to $TARGET over SSH"

# Kobos ship a BusyBox userland where KOReader's location can vary; find it
# rather than assuming.
KOREADER_PATH=$($SSH "$TARGET" 'for d in /mnt/onboard/.adds/koreader /mnt/sd/.adds/koreader; do
    [ -f "$d/reader.lua" ] && echo "$d" && break
done' || true)

if [[ -z "$KOREADER_PATH" ]]; then
    echo "error: could not find KOReader on $TARGET" >&2
    echo "       looked in /mnt/onboard/.adds/koreader and /mnt/sd/.adds/koreader" >&2
    exit 1
fi
echo "Found KOReader at $KOREADER_PATH"

DEST="$KOREADER_PATH/plugins"
$SSH "$TARGET" "mkdir -p '$DEST' && rm -rf '$DEST/$PLUGIN_DIR'"

# scp rather than rsync: stock Kobo firmware has no rsync.
if command -v rsync >/dev/null 2>&1 && $SSH "$TARGET" 'command -v rsync' >/dev/null 2>&1; then
    rsync -a --delete "$PLUGIN_DIR" "$TARGET:$DEST/"
else
    $SCP -q -r "$PLUGIN_DIR" "$TARGET:$DEST/"
fi

if [[ $WITH_NM -eq 1 ]]; then
    if $SSH "$TARGET" '[ -d /mnt/onboard/.adds/nm ]'; then
        $SCP -q nickelmenu/kobochess "$TARGET:/mnt/onboard/.adds/nm/kobochess"
        $SCP -q nickelmenu/kobochess-launch.sh "$TARGET:/mnt/onboard/.adds/kobochess-launch.sh"
        $SSH "$TARGET" 'chmod +x /mnt/onboard/.adds/kobochess-launch.sh'
        echo "Installed the NickelMenu entry (appears after the next Nickel restart)."
    else
        echo "warning: no NickelMenu at /mnt/onboard/.adds/nm -- skipping menu entry" >&2
    fi
fi

echo "Done. Restart KOReader, then: menu → Tools → Chess."
if [[ $WITH_NM -eq 0 ]]; then
    echo
    echo "To add a 'Chess' entry to the Kobo home menu, re-run with --with-nickelmenu."
fi
