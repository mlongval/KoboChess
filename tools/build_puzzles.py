#!/usr/bin/env python3
"""Build the bundled puzzle file from the Lichess puzzle database.

The Lichess puzzle database (https://database.lichess.org/#puzzles) is
released under CC0. It holds millions of puzzles; the device needs a few
thousand, so this keeps a modest, well-tested subset spread evenly over the
ratings a club player meets:

    curl -s https://database.lichess.org/lichess_db_puzzle.csv.zst \
        | zstd -dc | python3 tools/build_puzzles.py

or, from a copy already downloaded:

    zstd -dc lichess_db_puzzle.csv.zst | python3 tools/build_puzzles.py

Only the first --max-rows rows are read. The file is ordered by puzzle id,
which is random, so the start of it is as good a sample as any and the rest
of the download is never needed (curl stops when this script does).

Output: kobochess.koplugin/data/puzzles.tsv, one puzzle per line:

    id <TAB> FEN <TAB> moves (UCI, space separated) <TAB> rating <TAB> themes

The FEN is the position before the opponent's move; the first move in the
list is that move, and the solver plays the second, fourth, ... ones. This is
the database's own convention, kept as it is.
"""

import argparse
import csv
import io
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "kobochess.koplugin", "data", "puzzles.tsv")

# Themes that say nothing to someone solving the puzzle (they describe the
# puzzle's length or source rather than its idea) are dropped to save space.
DROP_THEMES = {"master", "masterVsMaster", "superGM", "oneMove", "veryLong",
               "long", "short", "playerGames"}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--min-rating", type=int, default=800)
    ap.add_argument("--max-rating", type=int, default=2300,
                    help="exclusive upper bound")
    ap.add_argument("--bucket", type=int, default=100, help="width of a rating bucket")
    ap.add_argument("--per-bucket", type=int, default=250)
    ap.add_argument("--max-rows", type=int, default=1500000)
    ap.add_argument("--min-plays", type=int, default=1000)
    ap.add_argument("--min-popularity", type=int, default=85)
    ap.add_argument("--max-deviation", type=int, default=85)
    ap.add_argument("--max-moves", type=int, default=10,
                    help="longest move list kept, opponent's moves included")
    ap.add_argument("--seed", type=int, default=2026)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    nbuckets = (args.max_rating - args.min_rating) // args.bucket
    # Reservoir sampling per bucket: every qualifying puzzle read has the same
    # chance of being kept, without holding them all in memory.
    buckets = [[] for _ in range(nbuckets)]
    seen = [0] * nbuckets

    stream = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", newline="")
    reader = csv.reader(stream)
    header = next(reader)
    col = {name: i for i, name in enumerate(header)}
    rows = 0
    for row in reader:
        rows += 1
        if rows > args.max_rows:
            break
        try:
            rating = int(row[col["Rating"]])
            deviation = int(row[col["RatingDeviation"]])
            popularity = int(row[col["Popularity"]])
            plays = int(row[col["NbPlays"]])
        except (ValueError, IndexError):
            continue
        if not (args.min_rating <= rating < args.max_rating):
            continue
        if deviation > args.max_deviation or popularity < args.min_popularity \
                or plays < args.min_plays:
            continue
        moves = row[col["Moves"]].split()
        if len(moves) < 2 or len(moves) > args.max_moves:
            continue
        b = (rating - args.min_rating) // args.bucket
        themes = [t for t in row[col["Themes"]].split() if t not in DROP_THEMES]
        entry = (row[col["PuzzleId"]], row[col["FEN"]], " ".join(moves),
                 str(rating), " ".join(themes))
        seen[b] += 1
        if len(buckets[b]) < args.per_bucket:
            buckets[b].append(entry)
        else:
            j = rng.randrange(seen[b])
            if j < args.per_bucket:
                buckets[b][j] = entry

    puzzles = sorted((p for b in buckets for p in b), key=lambda p: (int(p[3]), p[0]))
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        for p in puzzles:
            f.write("\t".join(p) + "\n")

    print(f"read {rows} rows, kept {len(puzzles)} puzzles -> {args.out}", file=sys.stderr)
    for i, b in enumerate(buckets):
        lo = args.min_rating + i * args.bucket
        print(f"  {lo}-{lo + args.bucket - 1}: {len(b)} (of {seen[i]})", file=sys.stderr)
    # Leave the rest of the download unread: closing stdin makes curl stop.
    os._exit(0)


if __name__ == "__main__":
    main()
