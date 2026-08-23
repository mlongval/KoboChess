#!/bin/sh
#
# Launch KOReader straight into the chess board.
#
# The plugin looks for this flag file when it starts and, if it is there,
# opens the board instead of the file browser. The plugin deletes the flag
# itself, so a crash cannot leave the device permanently stuck in Chess.
#
# Installed at /mnt/onboard/.adds/kobochess-launch.sh and invoked by the
# NickelMenu entry in .adds/nm/kobochess.

KOREADER=/mnt/onboard/.adds/koreader

if [ ! -f "$KOREADER/koreader.sh" ]; then
    # Nothing sensible to do without KOReader; let NickelMenu report failure.
    exit 1
fi

mkdir -p "$KOREADER/settings"
touch "$KOREADER/settings/kobochess_autostart"

# Started with a directory, KOReader opens its file browser there and never
# the last book -- which it otherwise does first, with "Start with: last
# document" set, before the plugin gets a chance to put the board on top.
exec "$KOREADER/koreader.sh" /mnt/onboard
