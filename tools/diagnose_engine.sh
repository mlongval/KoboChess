#!/bin/sh
# Run on the Kobo. Collects everything needed to explain a failed engine start
# in one pass, because the Wi-Fi rarely stays up for two.
#
#   sh /tmp/diagnose_engine.sh > /tmp/diag.txt 2>&1

D=/mnt/onboard/.adds/koreader/plugins/kobochess.koplugin/engines/stockfish

echo "=== files ==="
ls -l "$D"
echo
echo "=== checksums (compare against the build machine) ==="
md5sum "$D"/engine "$D"/*.nnue
echo
echo "=== memory ==="
free
echo
echo "=== is it executable at all ==="
"$D/engine" --help >/dev/null 2>&1; echo "--help exit: $?"
echo
echo "=== uci only (no network load) ==="
printf 'uci\nquit\n' | "$D/engine" 2>&1 | tail -3
echo "uci exit: $?"
echo
echo "=== isready with the big net -- this is the step that fails ==="
# Run from the engine's own directory so the small net resolves the way it
# does under the plugin, and keep stderr, which is where Stockfish complains.
cd "$D" || exit 1
printf 'setoption name Threads value 1\nsetoption name Hash value 16\nsetoption name EvalFile value %s/nn-c288c895ea92.nnue\nisready\nquit\n' "$D" \
    | ./engine 2>&1
echo "isready exit: $?"
echo
echo "=== isready with default net names, cwd = engine dir ==="
printf 'isready\nquit\n' | ./engine 2>&1
echo "exit: $?"
echo
echo "=== dmesg tail (an OOM kill or a fault shows up here) ==="
dmesg 2>/dev/null | tail -25
