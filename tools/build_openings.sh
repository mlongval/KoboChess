#!/bin/sh
# Download the opening names (lichess-org/chess-openings, CC0) and convert
# them into kobochess.koplugin/data/openings.tsv. Needs curl and luajit.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base=https://raw.githubusercontent.com/lichess-org/chess-openings/master
for f in a b c d e; do
    curl -fsSL "$base/$f.tsv" -o "$tmp/$f.tsv"
done
mkdir -p kobochess.koplugin/data
luajit tools/build_openings.lua "$tmp"/a.tsv "$tmp"/b.tsv "$tmp"/c.tsv "$tmp"/d.tsv "$tmp"/e.tsv \
    > kobochess.koplugin/data/openings.tsv
