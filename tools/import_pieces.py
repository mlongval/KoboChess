#!/usr/bin/env python3
"""Build the plugin's piece images from a chess sprite sheet.

The sheet is a grid of piece icons. Sheets disagree about how that grid is
arranged, so both the shape and the reading order are options rather than
assumptions: `--grid 6x2 --order wk,wq,wb,...` describes any of them.

`--grid auto` handles the sheets that are not on a grid at all -- icons laid
out by eye, with uneven gaps and a wide margin round the outside. It finds the
rows and then the icons within each row by looking at where there is ink,
which does not care about spacing.

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

    # icons that are not on a regular grid, into a named set
    python3 tools/import_pieces.py --sheet sketchy.jpg --grid auto --rows 2 \\
        --order wp,wk,wq,wb,wn,wr,bp,bk,bq,bb,bn,br --set line-icons
"""

import argparse
import os
from collections import deque

from PIL import Image, ImageFilter

# The default sheet: 6 columns by 2 rows, white row above black, K Q B N R P
# across. Cells are named in reading order -- left to right, top to bottom.
DEFAULT_GRID = (6, 2)
DEFAULT_ORDER = ["wk", "wq", "wb", "wn", "wr", "wp",
                 "bk", "bq", "bb", "bn", "br", "bp"]

VALID_NAMES = {c + k for c in "wb" for k in "kqrbnp"}

# Sets live one folder deep, so several can be installed side by side and
# chosen at runtime: pieces/<set>/wk.png and so on.
PIECES_ROOT = "kobochess.koplugin/pieces"

# A pixel this light, and connected to the border, is background. The sheet
# may carry a baked-in "transparency" checkerboard rather than real alpha,
# so this has to catch both white and the light grey of the checks.
BG_LEVEL = 225

# Fraction of the canvas the largest piece is allowed to occupy.
FIT_W = 0.98
FIT_H = 0.94
# Gap left under the pieces so they do not sit flush against the square edge.
BOTTOM_MARGIN = 0.03

# Icon sets draw every piece to the same size, which on a board leaves the
# pawns standing as tall as the kings. These restore the usual hierarchy, as a
# fraction of the tallest piece.
RELATIVE_HEIGHT = {
    "p": 0.78,
    "n": 0.90,
    "b": 0.93,
    "r": 0.87,
    "q": 0.97,
    "k": 1.00,
}

# Widen individual pieces. A bishop drawn as a narrow mitre reads as spindly
# next to the rook and the pawn, and a little extra width fixes it without
# touching its height.
WIDTH_STRETCH = {
    "b": 1.18,
}

# Thicken a piece's ink, in source pixels, before it is scaled down, for a
# piece drawn lighter than its neighbours. Empty by default: thickening one
# piece to match the others tends to overshoot and make it the odd one out in
# the other direction, which is worse than the problem it solves.
INK_DILATE = {}


def strip_background(cell, bg_level=BG_LEVEL):
    """Make the border-connected background transparent."""
    cell = cell.copy()
    w, h = cell.size
    px = cell.load()

    def is_bg(x, y):
        r, g, b, _ = px[x, y]
        return r > bg_level and g > bg_level and b > bg_level

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


def thicken_ink(piece, amount):
    """Grow the dark parts of a piece by `amount` pixels, in place of redrawing.

    Only the ink spreads: transparent margins stay transparent, so the piece
    gets bolder without gaining a background.
    """
    if amount <= 0:
        return piece
    rgb = piece.convert("RGB")
    alpha = piece.split()[3]
    # Dark and actually part of the piece.
    ink = Image.eval(rgb.convert("L"), lambda v: 255 if v < 128 else 0)
    ink = Image.composite(ink, Image.new("L", piece.size, 0), alpha.point(
        lambda v: 255 if v > 128 else 0))
    size = amount * 2 + 1
    grown = ink.filter(ImageFilter.MaxFilter(size if size % 2 else size + 1))

    out = piece.copy()
    out.paste(Image.new("RGBA", piece.size, (0, 0, 0, 255)), (0, 0), grown)
    return out


def contact_sheet(piece_dir, size):
    """All twelve pieces on a strip of checkerboard, for reviewing a set."""
    sheet = Image.new("RGBA", (size * 6, size * 2), (255, 255, 255, 255))
    for col, kind in enumerate(["p", "n", "b", "r", "q", "k"]):
        for row, colour in enumerate(("w", "b")):
            bg = (255, 255, 255, 255) if (col + row) % 2 == 0 else (187, 187, 187, 255)
            tile = Image.new("RGBA", (size, size), bg)
            piece = Image.open(os.path.join(piece_dir, colour + kind + ".png"))
            tile.paste(piece, (0, 0), piece)
            sheet.paste(tile, (col * size, row * size))
    return sheet


def _bands(present, min_run, min_gap):
    """Group a boolean-per-index array into runs of True, as (start, end).

    Runs closer together than `min_gap` are merged, and runs shorter than
    `min_run` are dropped. Both matter: a piece drawn with a detached plinth
    is two runs a pixel or two apart and must count as one icon, while JPEG
    speckle in the background is a run of its own and must count as none.
    """
    runs, start = [], None
    for i, on in enumerate(present):
        if on and start is None:
            start = i
        elif not on and start is not None:
            runs.append((start, i))
            start = None
    if start is not None:
        runs.append((start, len(present)))

    merged = []
    for run in runs:
        if merged and run[0] - merged[-1][1] < min_gap:
            merged[-1] = (merged[-1][0], run[1])
        else:
            merged.append(run)
    return [r for r in merged if r[1] - r[0] >= min_run]


def extract_auto(sheet_path, rows, order, bg_level=BG_LEVEL):
    """Find the icons by where the ink is, for sheets that are not on a grid.

    Icon sets are often laid out by eye: uneven gaps, a wide margin round the
    outside, and columns that do not line up between rows. Slicing such a sheet
    into equal cells cuts pieces in half. Projecting the ink onto each axis
    instead finds the rows, and then the icons inside each row, wherever they
    happen to sit.
    """
    sheet = strip_background(Image.open(sheet_path).convert("RGBA"), bg_level)
    w, h = sheet.size
    alpha = sheet.split()[3].point(lambda v: 255 if v > 32 else 0)
    px = alpha.load()

    # A band has to be a few pixels thick to count, so JPEG speckle in the
    # background does not read as a row of its own.
    row_ink = [any(px[x, y] for x in range(w)) for y in range(h)]
    row_bands = _bands(row_ink, max(3, h // 100), max(4, h // 20))
    if len(row_bands) != rows:
        raise SystemExit(
            f"error: --grid auto found {len(row_bands)} rows of icons, not {rows}.\n"
            "       Check --rows, or use an explicit --grid COLSxROWS.")

    per_row = len(order) // rows
    boxes = []
    for top, bottom in row_bands:
        col_ink = [any(px[x, y] for y in range(top, bottom)) for x in range(w)]
        # Icons sit closer to each other side by side than the rows do to one
        # another, so the horizontal gap threshold has to be tighter.
        col_bands = _bands(col_ink, max(3, w // 200), max(4, w // 100))
        if len(col_bands) != per_row:
            raise SystemExit(
                f"error: --grid auto found {len(col_bands)} icons in the row at "
                f"y={top}..{bottom}, not {per_row}.\n"
                "       Icons that touch each other cannot be split this way; "
                "use an explicit --grid.")
        for left, right in col_bands:
            boxes.append((left, top, right, bottom))

    pieces = {}
    for name, box in zip(order, boxes):
        cell = sheet.crop(box)
        cell = thicken_ink(cell, INK_DILATE.get(name, 0))
        bbox = cell.getbbox()
        pieces[name] = cell.crop(bbox) if bbox else cell
    return pieces


def extract(sheet_path, grid, order, bg_level=BG_LEVEL):
    """Return {name: tightly-cropped RGBA image} for all twelve pieces."""
    cols, rows = grid
    sheet = Image.open(sheet_path).convert("RGBA")
    W, H = sheet.size
    cw, ch = W / cols, H / rows

    pieces = {}
    for index, name in enumerate(order):
        col, row = index % cols, index // cols
        box = (int(col * cw), int(row * ch), int((col + 1) * cw), int((row + 1) * ch))
        cell = strip_background(sheet.crop(box), bg_level)
        # Thicken before cropping, so growing ink cannot run off the edge.
        cell = thicken_ink(cell, INK_DILATE.get(name, 0))
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
    ap.add_argument("--set", default="vecteezy", dest="set_name",
                    help="name of the piece set to write (default %(default)s); "
                         "it becomes a folder under pieces/ that the plugin "
                         "offers under Options")
    ap.add_argument("--out", help="write here instead of pieces/<set>")
    ap.add_argument("--grid", default="%dx%d" % DEFAULT_GRID,
                    help="sheet layout as COLSxROWS, or 'auto' to find the "
                         "icons by where the ink is (default %(default)s)")
    ap.add_argument("--rows", type=int, default=2,
                    help="rows of icons, for --grid auto (default %(default)s)")
    ap.add_argument("--bg-level", type=int, default=BG_LEVEL, dest="bg_level",
                    help="a pixel this light, and connected to the border, is "
                         "background (default %(default)s)")
    ap.add_argument("--order", default=",".join(DEFAULT_ORDER),
                    help="the twelve cells in reading order, e.g. wk,wq,...,bp")
    args = ap.parse_args()

    if not os.path.exists(args.sheet):
        raise SystemExit(f"error: no sprite sheet at {args.sheet}")

    out_dir = args.out or os.path.join(PIECES_ROOT, args.set_name)

    auto = (args.grid.lower() == "auto")
    cols = rows = None
    if not auto:
        try:
            cols, rows = (int(v) for v in args.grid.lower().split("x"))
        except ValueError:
            raise SystemExit(
                f"error: --grid should look like 6x2, or be 'auto', got {args.grid!r}")

    order = [name.strip() for name in args.order.split(",") if name.strip()]
    unknown = sorted(set(order) - VALID_NAMES)
    if unknown:
        raise SystemExit(f"error: unknown piece name(s) in --order: {', '.join(unknown)}")
    if sorted(order) != sorted(VALID_NAMES):
        raise SystemExit(
            "error: --order must name all twelve pieces exactly once "
            f"(got {len(order)}: {args.order})")
    if auto:
        if len(order) % args.rows != 0:
            raise SystemExit(
                f"error: {len(order)} pieces do not divide evenly into {args.rows} rows")
        pieces = extract_auto(args.sheet, args.rows, order, args.bg_level)
    else:
        if len(order) > cols * rows:
            raise SystemExit(
                f"error: --order has {len(order)} cells but the grid holds {cols * rows}")
        pieces = extract(args.sheet, (cols, rows), order, args.bg_level)

    # One scale factor for the whole set, so a pawn stays smaller than a queen.
    max_w = max(p.width for p in pieces.values())
    max_h = max(p.height for p in pieces.values())
    scale = min(args.size * FIT_W / max_w, args.size * FIT_H / max_h)

    os.makedirs(out_dir, exist_ok=True)
    baseline = args.size - int(args.size * BOTTOM_MARGIN)

    for name, piece in sorted(pieces.items()):
        kind = name[1]
        rel = RELATIVE_HEIGHT.get(kind, 1.0)
        stretch = WIDTH_STRETCH.get(kind, 1.0)
        w = max(1, int(round(piece.width * scale * rel * stretch)))
        h = max(1, int(round(piece.height * scale * rel)))
        resized = piece.resize((w, h), Image.LANCZOS)

        canvas = Image.new("RGBA", (args.size, args.size), (0, 0, 0, 0))
        # Centred horizontally, standing on a common baseline: the pieces have
        # no plinths of their own, so they need to share one.
        canvas.paste(resized, ((args.size - w) // 2, baseline - h), resized)

        path = os.path.join(out_dir, name + ".png")
        canvas.save(path, "PNG", optimize=True)
        print(f"  {path}  piece {w}x{h} on {args.size}px canvas")

    print(f"\nscaled by {scale:.3f} (largest source piece {max_w}x{max_h})")

    preview = contact_sheet(out_dir, args.size)
    preview_path = f"pieces_preview-{os.path.basename(out_dir)}.png"
    preview.save(preview_path)
    print(f"  {preview_path}  (preview only, not shipped)")


if __name__ == "__main__":
    main()
