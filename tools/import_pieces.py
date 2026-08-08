#!/usr/bin/env python3
"""Build the plugin's piece images from a chess sprite sheet.

The sheet is a grid of piece icons. Sheets disagree about how that grid is
arranged, so both the shape and the reading order are options rather than
assumptions: `--grid 6x2 --order wk,wq,wb,...` describes any of them.

Two things here are less obvious than they look:

*Background removal is a flood fill, not a colour key.* The white pieces are
white inside as well as out, so keying on "is this pixel white" punches holes
straight through them. Filling inwards from the borders only removes what is
actually connected to the outside.

*All twelve pieces are scaled by one shared factor.* Fitting each piece to its
square independently would blow the pawn up to the same height as the queen
and destroy the set's proportions.

Usage:
    # the 6x2 sheet: white row then black row, K Q B N R P across
    python3 tools/import_pieces.py --sheet assets/sprite_sheet.png

    # a 4x3 sheet read left-to-right, top-to-bottom
    python3 tools/import_pieces.py --sheet rendered.png --grid 4x3 \\
        --order wk,wq,wr,wb,wn,wp,bk,bq,br,bb,bn,bp
"""

import argparse
import os
from collections import deque

from PIL import Image

# The default sheet: 6 columns by 2 rows, white row above black, K Q B N R P
# across. Cells are named in reading order -- left to right, top to bottom.
DEFAULT_GRID = (6, 2)
DEFAULT_ORDER = ["wk", "wq", "wb", "wn", "wr", "wp",
                 "bk", "bq", "bb", "bn", "br", "bp"]

VALID_NAMES = {c + k for c in "wb" for k in "kqrbnp"}

# A pixel this light, and connected to the border, is background. The sheet
# may carry a baked-in "transparency" checkerboard rather than real alpha,
# so this has to catch both white and the light grey of the checks.
BG_LEVEL = 225

# Fraction of the canvas the largest piece is allowed to occupy.
FIT_W = 0.98
FIT_H = 0.94
# Gap left under the pieces so they do not sit flush against the square edge.
BOTTOM_MARGIN = 0.03


def strip_background(cell):
    """Make the border-connected background transparent."""
    cell = cell.copy()
    w, h = cell.size
    px = cell.load()

    def is_bg(x, y):
        r, g, b, _ = px[x, y]
        return r > BG_LEVEL and g > BG_LEVEL and b > BG_LEVEL

    seen = [[False] * h for _ in range(w)]
    queue = deque()

    def push(x, y):
        if not seen[x][y] and is_bg(x, y):
            seen[x][y] = True
            queue.append((x, y))

    for x in range(w):
        push(x, 0)
        push(x, h - 1)
    for y in range(h):
        push(0, y)
        push(w - 1, y)

    while queue:
        x, y = queue.popleft()
        px[x, y] = (255, 255, 255, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h:
                push(nx, ny)

    return cell


def extract(sheet_path, grid, order):
    """Return {name: tightly-cropped RGBA image} for all twelve pieces."""
    cols, rows = grid
    sheet = Image.open(sheet_path).convert("RGBA")
    W, H = sheet.size
    cw, ch = W / cols, H / rows

    pieces = {}
    for index, name in enumerate(order):
        col, row = index % cols, index // cols
        box = (int(col * cw), int(row * ch), int((col + 1) * cw), int((row + 1) * ch))
        cell = strip_background(sheet.crop(box))
        bbox = cell.getbbox()
        if bbox is None:
            raise SystemExit(
                f"error: cell {col},{row} ({name}) is empty after background removal.\n"
                "       Check --grid: if the cells do not line up with the icons,\n"
                "       pieces get split across cell boundaries.")
        pieces[name] = cell.crop(bbox)
    return pieces


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sheet", default="assets/sprite_sheet.png")
    ap.add_argument("--size", type=int, default=256, help="output canvas, px (default 256)")
    ap.add_argument("--out", default="kobochess.koplugin/pieces")
    ap.add_argument("--grid", default="%dx%d" % DEFAULT_GRID,
                    help="sheet layout as COLSxROWS (default %(default)s)")
    ap.add_argument("--order", default=",".join(DEFAULT_ORDER),
                    help="the twelve cells in reading order, e.g. wk,wq,...,bp")
    args = ap.parse_args()

    if not os.path.exists(args.sheet):
        raise SystemExit(f"error: no sprite sheet at {args.sheet}")

    try:
        cols, rows = (int(v) for v in args.grid.lower().split("x"))
    except ValueError:
        raise SystemExit(f"error: --grid should look like 6x2, got {args.grid!r}")

    order = [name.strip() for name in args.order.split(",") if name.strip()]
    unknown = sorted(set(order) - VALID_NAMES)
    if unknown:
        raise SystemExit(f"error: unknown piece name(s) in --order: {', '.join(unknown)}")
    if sorted(order) != sorted(VALID_NAMES):
        raise SystemExit(
            "error: --order must name all twelve pieces exactly once "
            f"(got {len(order)}: {args.order})")
    if len(order) > cols * rows:
        raise SystemExit(f"error: --order has {len(order)} cells but the grid holds {cols * rows}")

    pieces = extract(args.sheet, (cols, rows), order)

    # One scale factor for the whole set, so a pawn stays smaller than a queen.
    max_w = max(p.width for p in pieces.values())
    max_h = max(p.height for p in pieces.values())
    scale = min(args.size * FIT_W / max_w, args.size * FIT_H / max_h)

    os.makedirs(args.out, exist_ok=True)
    baseline = args.size - int(args.size * BOTTOM_MARGIN)

    for name, piece in sorted(pieces.items()):
        w = max(1, int(round(piece.width * scale)))
        h = max(1, int(round(piece.height * scale)))
        resized = piece.resize((w, h), Image.LANCZOS)

        canvas = Image.new("RGBA", (args.size, args.size), (0, 0, 0, 0))
        # Centred horizontally, standing on a common baseline: the pieces have
        # no plinths of their own, so they need to share one.
        canvas.paste(resized, ((args.size - w) // 2, baseline - h), resized)

        path = os.path.join(args.out, name + ".png")
        canvas.save(path, "PNG", optimize=True)
        print(f"  {path}  piece {w}x{h} on {args.size}px canvas")

    print(f"\nscaled by {scale:.3f} (largest source piece {max_w}x{max_h})")

    # Contact sheet on a checkerboard, for reviewing the set.
    sq = args.size
    order = ["p", "n", "b", "r", "q", "k"]
    sheet = Image.new("RGBA", (sq * 6, sq * 2), (255, 255, 255, 255))
    for col, kind in enumerate(order):
        for row, colour in enumerate(("w", "b")):
            bg = (255, 255, 255, 255) if (col + row) % 2 == 0 else (187, 187, 187, 255)
            tile = Image.new("RGBA", (sq, sq), bg)
            piece = Image.open(os.path.join(args.out, colour + kind + ".png"))
            tile.paste(piece, (0, 0), piece)
            sheet.paste(tile, (col * sq, row * sq))
    sheet.save("pieces_preview.png")
    print("  pieces_preview.png  (preview only, not shipped)")


if __name__ == "__main__":
    main()
