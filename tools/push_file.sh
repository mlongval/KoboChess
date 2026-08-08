#!/usr/bin/env bash
# Push one large file to a Kobo over a flaky link, resuming where it stopped.
#
# scp cannot resume, and the Elipsa's Wi-Fi drops often enough that a 109 MB
# network file never finishes in one stream: the transfer stalls, scp sits
# there holding a dead socket, and nothing moves. This sends the file in
# chunks instead, asking the device after each drop how many bytes it already
# has and carrying on from there.
#
#   ./tools/push_file.sh <local-file> root@<ip> <remote-path>

set -uo pipefail

LOCAL=${1:?local file}
TARGET=${2:?user@host}
REMOTE=${3:?remote path}

SSH=${SSH:-ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222}
CHUNK=${CHUNK:-4194304}          # 4 MiB per connection
MAX_STALLS=${MAX_STALLS:-1000}   # give up eventually rather than spin forever

TOTAL=$(stat -c %s "$LOCAL")
echo "pushing $(basename "$LOCAL") -- $TOTAL bytes"

$SSH "$TARGET" "mkdir -p $(dirname "$REMOTE")" >/dev/null 2>&1

stalls=0
while :; do
    # Ask the device how much it already has. A failed query must NOT be read
    # as "zero bytes": the link drops constantly, and appending from offset 0
    # onto an 80 MB partial silently corrupts it in a way only the closing md5
    # would catch, after another twenty minutes of transfer. Distinguish "the
    # file is empty" from "I could not ask" -- print a sentinel the shell
    # cannot produce by dying.
    have=$($SSH "$TARGET" "if [ -e $REMOTE ]; then wc -c < $REMOTE; else echo 0; fi; echo EOT" 2>/dev/null | tr -d ' \r')
    if [[ "${have##*$'\n'}" != "EOT" ]]; then
        stalls=$(( stalls + 1 ))
        echo "  could not read remote size (${stalls}) -- retrying"
        [[ $stalls -ge $MAX_STALLS ]] && { echo "giving up" >&2; exit 1; }
        sleep 3
        continue
    fi
    have=${have%$'\n'EOT}
    case $have in ''|*[!0-9]*)
        stalls=$(( stalls + 1 ))
        echo "  unreadable remote size (${stalls}) -- retrying"
        sleep 3
        continue ;;
    esac

    if [[ $have -ge $TOTAL ]]; then
        if [[ $have -gt $TOTAL ]]; then
            # A resumed chunk that half-arrived can overshoot; start clean.
            echo "remote is larger than the source -- truncating and restarting"
            $SSH "$TARGET" "rm -f $REMOTE" >/dev/null 2>&1
            continue
        fi
        echo "complete: $have/$TOTAL"
        break
    fi

    pct=$(( have * 100 / TOTAL ))
    echo "at $have/$TOTAL (${pct}%)"

    # dd out one chunk and append it on the far side. If the link dies the
    # partial chunk is still on disk, and the next pass picks up after it.
    # bs is the read size, not the offset unit -- skip_bytes/count_bytes let
    # the offsets stay in bytes while dd still reads in sensible blocks.
    if dd if="$LOCAL" bs=65536 skip="$have" count="$CHUNK" \
           iflag=skip_bytes,count_bytes status=none 2>/dev/null \
       | $SSH "$TARGET" "cat >> $REMOTE" 2>/dev/null; then
        stalls=0
    else
        stalls=$(( stalls + 1 ))
        echo "  chunk failed (${stalls}) -- retrying"
        if [[ $stalls -ge $MAX_STALLS ]]; then
            echo "giving up after $stalls consecutive failures" >&2
            exit 1
        fi
        sleep 3
    fi
done

echo "verifying"
local_sum=$(md5sum "$LOCAL" | cut -d' ' -f1)
remote_sum=$($SSH "$TARGET" "md5sum $REMOTE 2>/dev/null | cut -d' ' -f1" 2>/dev/null | tr -d ' \r')
if [[ -n "$remote_sum" && "$local_sum" == "$remote_sum" ]]; then
    echo "md5 ok: $local_sum"
else
    echo "md5 MISMATCH: local $local_sum remote ${remote_sum:-<none>}" >&2
    exit 1
fi
