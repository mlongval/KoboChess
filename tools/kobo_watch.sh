#!/bin/bash
#
# Watch for the Kobo coming online, and update it when it does.
#
# The device is off, asleep, or out of Wi-Fi range nearly all the time, so
# there is no moment at which installing to it is a thing you can simply do.
# Run this from cron every few minutes instead: it does nothing at all until
# the Kobo answers, and when it does, it brings the plugin on the device up to
# date with this checkout and gets out of the way.
#
#   */5 * * * * /usr/bin/flock -n ~/logs/.lock_kobochess \
#       /bin/bash ~/Projects/KoboChess/tools/kobo_watch.sh >> ~/logs/kobochess-watch.log 2>&1
#
# It is deliberately NOT install.sh. That script deletes the plugin directory
# on the device and copies a fresh one, which is right when you are standing
# there watching it, and wrong here: the Elipsa carries 109 MB of Stockfish
# and its neural network, and re-sending that over a link which drops -- with
# nobody watching -- would fail slowly and leave the device without an engine
# it had before. So this sends only what it needs to, over the top of what is
# already there, and never removes anything. For a clean install, run
# install.sh by hand.
#
# Everything it does is idempotent, and a fingerprint of what it last sent
# means an unchanged checkout costs one TCP connection every five minutes.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PLUGIN_DIR="kobochess.koplugin"

# Which Kobo, and where the daemon lives, are per-machine facts rather than
# project ones, so they come from a config file if there is one. Everything
# below is only a plausible default -- fill in your own:
#
#   ~/.config/kobochess/watch.conf
#     KOBOCHESS_KOBO_HOST=100.x.y.z        # the Kobo's tailnet address
#     KOBOCHESS_KOBO_NAME=kobo-elipsa      # its name, for the tailnet check
#
CONF="${KOBOCHESS_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/kobochess/watch.conf}"
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

HOST="${KOBOCHESS_KOBO_HOST:-100.64.0.20}"         # the Kobo on the tailnet
NAME="${KOBOCHESS_KOBO_NAME:-kobo-elipsa}"         # as tailscale knows it
PORTS="${KOBOCHESS_KOBO_PORTS:-2222 22}"           # KOReader's SSH server, then dropbear
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/kobochess"
NOTIFY="$ROOT/tools/notify_game.sh"
NUDGE_EVERY="${KOBOCHESS_NUDGE_EVERY:-21600}"      # at most one nudge per 6 hours

mkdir -p "$STATE"

say() {  # only speak when something changed; cron runs this all day
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

announce() {  # log line plus, for the events that matter, a message
    say "$2"
    [ -x "$NOTIFY" ] && "$NOTIFY" "$1" "$2" || true
}

remember_state() {  # returns 0 if this is a change from last time
    local last=""
    [ -f "$STATE/last_state" ] && last=$(cat "$STATE/last_state")
    printf '%s' "$1" > "$STATE/last_state"
    [ "$last" != "$1" ]
}

# --- is it there? -----------------------------------------------------------
#
# A tailnet address answers ICMP whether or not anything is listening, and
# KOReader's SSH server is started by hand from its menu -- so the question is
# not "is the Kobo up" but "is there an sshd on it right now". Ask that
# directly, with a short timeout, and try the ports in order.

PORT=""
for candidate in $PORTS; do
    if nc -z -w 4 "$HOST" "$candidate" 2>/dev/null; then
        PORT="$candidate"
        break
    fi
done

# --- on the tailnet, but not listening? -------------------------------------
#
# The device being reachable and the device being installable are different
# things: KOReader's SSH server is a plugin you switch on by hand, from a menu,
# on the device. So a Kobo that is awake and on the tailnet with the server off
# will never be updated, and will never say why -- it looks exactly like a Kobo
# that is asleep. Tailscale knows the difference, so ask it, and pass the one
# piece of information that only the person holding the device can act on.
#
# Rate-limited hard. The Elipsa drops Wi-Fi whenever it sleeps, which means it
# comes and goes all day; a message on every transition would be noise, and
# noise gets muted.

on_tailnet() {
    command -v tailscale >/dev/null 2>&1 || return 1
    tailscale status --json 2>/dev/null | jq -e --arg name "$NAME" --arg ip "$HOST" '
        (.Peer // {}) | to_entries | any(
            .value as $p
            | ($p.Online == true)
            and (($p.HostName == $name) or (($p.TailscaleIPs // []) | index($ip)))
        )' >/dev/null 2>&1
}

nudge_is_due() {
    local now last=0
    now=$(date +%s)
    [ -f "$STATE/last_nudge" ] && last=$(cat "$STATE/last_nudge")
    [ $((now - last)) -ge "$NUDGE_EVERY" ] || return 1
    printf '%s' "$now" > "$STATE/last_nudge"
    return 0
}

if [ -z "$PORT" ]; then
    if on_tailnet; then
        remember_state "online-no-ssh" || true
        if nudge_is_due; then
            announce "nudge" "the Kobo is awake on the tailnet but its SSH server is off -- turn it on (KOReader -> Network -> SSH server) and the update will go through within five minutes"
        else
            say "Kobo is on the tailnet but nothing is listening on $PORTS -- already nudged recently"
        fi
    else
        remember_state "offline" && say "Kobo not answering on $HOST ($PORTS) -- waiting"
    fi
    exit 0
fi

# KOReader's SSH server is dropbear with a blank password for root. Plain ssh
# gets in, and sshpass is the fallback for a firmware that insists on being
# handed the empty string. BatchMode on the first attempt is what keeps this
# safe to run from cron: a password prompt fails immediately instead of
# hanging a job nobody is watching. The host key is regenerated by KOReader
# from time to time and this is our own tailnet, so it is not checked.
TARGET="root@$HOST"
SSH_MODE=""     # decided once the device is known to need talking to
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

kssh() {
    # KOBOCHESS_SSH replaces the whole way of reaching the device -- set it to
    # "bash -c" to run this against a directory on this machine and see what
    # it would do to a Kobo.
    if [ -n "${KOBOCHESS_SSH:-}" ]; then
        $KOBOCHESS_SSH "$@"
        return
    fi
    if [ "$SSH_MODE" = "sshpass" ]; then
        sshpass -p '' ssh -p "$PORT" "${SSH_OPTS[@]}" "$TARGET" "$@"
    else
        ssh -p "$PORT" "${SSH_OPTS[@]}" -o BatchMode=yes "$TARGET" "$@"
    fi
}

choose_ssh_mode() {
    [ -n "${KOBOCHESS_SSH:-}" ] && { SSH_MODE="override"; return 0; }
    if ssh -p "$PORT" "${SSH_OPTS[@]}" -o BatchMode=yes "$TARGET" true 2>/dev/null; then
        SSH_MODE="plain"; return 0
    fi
    if sshpass -p '' ssh -p "$PORT" "${SSH_OPTS[@]}" "$TARGET" true 2>/dev/null; then
        SSH_MODE="sshpass"; return 0
    fi
    return 1
}

# --- has anything changed since the last time it was up? --------------------
#
# What travels: the plugin itself, and the Claude shim -- which is small, and
# carries the daemon's address, so a change to it must reach the device. What
# stays behind: the other engines. Stockfish is 109 MB, changes about never,
# and is already on the device; sending it again unattended is the one thing
# this script exists to avoid.
#
# The same list decides what is fingerprinted and what is sent, so the two can
# never disagree about what "already installed" means.

payload_files() {
    cd "$ROOT"
    find "$PLUGIN_DIR" -path "$PLUGIN_DIR/engines" -prune -o -type f -print
    [ -d "$PLUGIN_DIR/engines/claude" ] && find "$PLUGIN_DIR/engines/claude" -type f -print
    return 0
}

FINGERPRINT=$(payload_files | sort | (cd "$ROOT" && xargs sha256sum) | sha256sum | cut -d' ' -f1)

if [ -f "$STATE/installed.sha" ] && [ "$(cat "$STATE/installed.sha")" = "$FINGERPRINT" ]; then
    remember_state "online-current" && say "Kobo is up on port $PORT and already current"
    exit 0
fi

remember_state "installing" || true
say "Kobo answering on port $PORT; plugin differs from this checkout -- updating"

# --- how do we get in? ------------------------------------------------------

if ! choose_ssh_mode; then
    announce "failed" "something answers on $HOST:$PORT but will not let us in"
    exit 0
fi

# --- where does KOReader live? ----------------------------------------------

KOREADER_DIRS="${KOBOCHESS_KOREADER_DIRS:-/mnt/onboard/.adds/koreader /mnt/sd/.adds/koreader}"
KOREADER=$(kssh "for d in $KOREADER_DIRS; do
    [ -f \"\$d/reader.lua\" ] && echo \"\$d\" && break
done" 2>/dev/null || true)

if [ -z "$KOREADER" ]; then
    announce "failed" "Kobo answered on $PORT but KOReader was not found -- not installing"
    exit 0
fi

DEST="$KOREADER/plugins"

# --- send it ----------------------------------------------------------------
#
# One tar down one connection: less to go wrong than a file at a time, and if
# the link drops mid-stream the untar fails and the next run tries again --
# the fingerprint is only written once this has finished.

if payload_files | grep -v '\.log$' | tar -C "$ROOT" -czf - -T - \
    | kssh "mkdir -p '$DEST' && tar -C '$DEST' -xzf - && chmod -R +x '$DEST/$PLUGIN_DIR/engines'/*/ 2>/dev/null || true"
then
    printf '%s' "$FINGERPRINT" > "$STATE/installed.sha"
    remember_state "online-current" || true
    announce "installed" "updated the plugin on the Elipsa (port $PORT) -- Claude engine included"
else
    announce "failed" "the update to the Elipsa failed part-way; will retry when it is next up"
    exit 0
fi
