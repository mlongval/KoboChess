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
# Every folder under kobochess.koplugin/engines/ is copied unless you say
# otherwise. Two Stockfish builds can be there at once (see
# tools/build_stockfish.sh), and they suit different devices:
#
#   --engine stockfish            Stockfish 18 + NNUE; needs ~200 MB free RAM
#                                 (Elipsa, Sage, Libra 2, ...)
#   --engine stockfish-classic    Stockfish 11, classical eval, a few MB
#                                 (Aura and other 256 MB devices)
#   --no-engines                  the built-in Lua engine only
#   --keep-engines                copy only the app; the engines already on
#                                 the device stay as they are (quick updates)
#
# --engine can be repeated. Engines not chosen are not copied, and are removed
# from the device if an earlier install put them there.
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
ENGINES=()          # chosen with --engine; empty + ALL_ENGINES=1 means all
ALL_ENGINES=1
KEEP_ENGINES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-nickelmenu) WITH_NM=1 ;;
        --engine) ENGINES+=("${2:-}"); ALL_ENGINES=0; shift ;;
        --engine=*) ENGINES+=("${1#*=}"); ALL_ENGINES=0 ;;
        --no-engines) ALL_ENGINES=0 ;;
        --keep-engines) ALL_ENGINES=0; KEEP_ENGINES=1 ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) TARGET="$1" ;;
    esac
    shift
done
[[ -n "$TARGET" ]] || usage

cd "$(dirname "$0")"

# What gets copied is a staged copy of the plugin holding only the chosen
# engines, so the same tree can serve devices with different memory budgets.
# SRC is where that copy lives; "." when nothing is filtered.
SRC="."
if [[ $ALL_ENGINES -eq 0 ]]; then
    for e in "${ENGINES[@]}"; do
        if [[ ! -x "$PLUGIN_DIR/engines/$e/engine" ]]; then
            echo "error: no engine at $PLUGIN_DIR/engines/$e/engine -- see tools/build_stockfish.sh" >&2
            exit 1
        fi
    done
    SRC=$(mktemp -d)
    trap 'rm -rf "$SRC"' EXIT
    mkdir -p "$SRC/$PLUGIN_DIR"
    for entry in "$PLUGIN_DIR"/* "$PLUGIN_DIR"/.[!.]*; do
        [[ -e "$entry" ]] || continue
        [[ "$(basename "$entry")" == "engines" ]] && continue
        cp -r "$entry" "$SRC/$PLUGIN_DIR/"
    done
    for e in "${ENGINES[@]}"; do
        mkdir -p "$SRC/$PLUGIN_DIR/engines"
        cp -r "$PLUGIN_DIR/engines/$e" "$SRC/$PLUGIN_DIR/engines/"
    done
    if [[ $KEEP_ENGINES -eq 1 ]]; then
        echo "Engines: the ones already on the device are kept"
    elif [[ ${#ENGINES[@]} -eq 0 ]]; then
        echo "Engines: built-in only"
    else
        echo "Engines: built-in + ${ENGINES[*]}"
    fi
fi

if [[ ! -d "$PLUGIN_DIR" ]]; then
    echo "error: $PLUGIN_DIR not found (run this from the project root)" >&2
    exit 1
fi
# Piece sets live one folder deep -- pieces/<set>/wk.png -- and whichever ones
# are present get copied, so a set built from artwork that cannot be committed
# still travels to the device.
if ! compgen -G "$PLUGIN_DIR/pieces/*/wk.png" >/dev/null; then
    echo "error: no piece set in $PLUGIN_DIR/pieces/ -- run: python3 tools/gen_pieces.py" >&2
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
    if [[ $KEEP_ENGINES -eq 1 && -d "$DEST/$PLUGIN_DIR/engines" ]]; then
        rm -rf "${DEST:?}/.kobochess-engines"
        mv "$DEST/$PLUGIN_DIR/engines" "$DEST/.kobochess-engines"
    fi
    rm -rf "${DEST:?}/$PLUGIN_DIR"
    cp -r "$SRC/$PLUGIN_DIR" "$DEST/"
    if [[ -d "$DEST/.kobochess-engines" ]]; then
        mv "$DEST/.kobochess-engines" "$DEST/$PLUGIN_DIR/engines"
    fi
    # Kobos are FAT32; strip anything that cannot survive the trip.
    find "$DEST/$PLUGIN_DIR" -name '._*' -delete 2>/dev/null || true
    # And an engine has to stay runnable.
    [[ -d "$DEST/$PLUGIN_DIR/engines" ]] && chmod -R +x "$DEST/$PLUGIN_DIR/engines"/*/ 2>/dev/null || true

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
if [[ $KEEP_ENGINES -eq 1 ]]; then
    # the engines step aside while the app is replaced, then come back
    $SSH "$TARGET" "mkdir -p '$DEST' && rm -rf '$DEST/.kobochess-engines' &&
        { [ ! -d '$DEST/$PLUGIN_DIR/engines' ] || mv '$DEST/$PLUGIN_DIR/engines' '$DEST/.kobochess-engines'; } &&
        rm -rf '$DEST/$PLUGIN_DIR'"
else
    $SSH "$TARGET" "mkdir -p '$DEST' && rm -rf '$DEST/$PLUGIN_DIR'"
fi

# scp rather than rsync: stock Kobo firmware has no rsync.
if command -v rsync >/dev/null 2>&1 && $SSH "$TARGET" 'command -v rsync' >/dev/null 2>&1; then
    rsync -a --delete "$SRC/$PLUGIN_DIR" "$TARGET:$DEST/"
else
    $SCP -q -r "$SRC/$PLUGIN_DIR" "$TARGET:$DEST/"
fi

if [[ $KEEP_ENGINES -eq 1 ]]; then
    $SSH "$TARGET" "[ ! -d '$DEST/.kobochess-engines' ] || mv '$DEST/.kobochess-engines' '$DEST/$PLUGIN_DIR/engines'"
fi

# An engine is only an engine if it can be run, and the copy may not have
# carried the bit: the Kobo's user partition is FAT32, which has no permission
# bits of its own.
$SSH "$TARGET" "[ -d '$DEST/$PLUGIN_DIR/engines' ] && chmod -R +x '$DEST/$PLUGIN_DIR/engines'/*/ 2>/dev/null || true"

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
