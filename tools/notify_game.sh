#!/bin/sh
#
# What to do when the chess daemon has something to say. Called as
#
#   notify_game.sh <event> <text>
#
# with event one of: connect (a game started), disconnect (it ended),
# fallback (a move could not be got from Claude and one was invented),
# installed / nudge / failed (from tools/kobo_watch.sh).
#
# Everything lands in the log. Telegram is only used for the events that are
# actually news -- a game starting is not news to the person who just started
# it on the device in their hands, but an engine that has quietly begun
# playing random moves is, and so is a device that has just been installed to.
#
# The bot token is read at run time from the Claude Code Telegram channel's
# own .env, and is never copied anywhere else. If that file is not there, this
# script logs and exits happily: notification is a convenience, not a
# dependency.

set -eu

EVENT="${1:-unknown}"
TEXT="${2:-}"

LOG="${KOBOCHESS_LOG:-$HOME/logs/kobochess.log}"
mkdir -p "$(dirname "$LOG")"
printf '%s %-10s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$EVENT" "$TEXT" >> "$LOG"

# Which events are worth a phone buzzing.
case "$EVENT" in
    fallback|failed|installed|nudge) ;;
    *) exit 0 ;;
esac

ENV_FILE="$HOME/.claude/channels/telegram/.env"
ACCESS="$HOME/.claude/channels/telegram/access.json"
[ -r "$ENV_FILE" ] && [ -r "$ACCESS" ] || exit 0

TOKEN=$(sed -n 's/^[A-Z_]*TOKEN=//p' "$ENV_FILE" | tr -d '"' | tr -d "'" | head -1)

# access.json is pretty-printed, so "allowFrom" and the id it holds are on
# different lines: anything line-based finds nothing and says nothing about
# it, which is the worst way for a notifier to fail. jq if it is here, and
# otherwise flatten the file first and then match.
if command -v jq >/dev/null 2>&1; then
    CHAT=$(jq -r '.allowFrom[0] // empty' "$ACCESS" 2>/dev/null)
else
    CHAT=$(tr -d ' \n\t' < "$ACCESS" | sed -n 's/.*"allowFrom":\["\([0-9][0-9]*\)".*/\1/p' | head -1)
fi
[ -n "$TOKEN" ] && [ -n "$CHAT" ] || exit 0

curl -s -m 10 -o /dev/null \
    "https://api.telegram.org/bot$TOKEN/sendMessage" \
    --data-urlencode "chat_id=$CHAT" \
    --data-urlencode "text=KoboChess: $TEXT" || true
