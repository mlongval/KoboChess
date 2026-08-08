#!/usr/bin/env python3
"""Drive the KOReader desktop emulator by tapping chess squares.

Used to exercise the plugin without a device: it finds the board in a
screenshot, converts a square name to a pixel position and synthesises an X11
click there. Board geometry is detected rather than hardcoded, so it keeps
working when the layout changes.

Needs python-xlib, ImageMagick's `import`, and KOReader running on the given
display. See the Development section of the README for the whole loop.

Usage:
    python3 tools/emulator_tap.py e2 e4          # play e2-e4
    python3 tools/emulator_tap.py @700,1110      # tap raw pixel coordinates
    python3 tools/emulator_tap.py e2 s2 e4       # ... with a 2 second pause

    DISPLAY_NUM=:99 python3 tools/emulator_tap.py e7 e5
"""

import os
import subprocess
import sys
import tempfile
import time

from PIL import Image
from Xlib import X, display
from Xlib.ext import xtest

DISPLAY_NUM = os.environ.get("DISPLAY_NUM", ":99")
INK = 60          # a pixel this dark is part of the board's border


def screenshot(path):
    subprocess.run(["import", "-display", DISPLAY_NUM, "-window", "root", path],
                   check=True)


def board_geometry():
    """Locate the board and return (left, top, square_size).

    The board is found by its border: the two full-width dark rows that are
    exactly one board-width apart, since the board is square.
    """
    with tempfile.NamedTemporaryFile(suffix=".png") as tmp:
        screenshot(tmp.name)
        image = Image.open(tmp.name).convert("L")
        width, height = image.size
        px = image.load()

        def dark_column(x, y0, y1):
            return sum(1 for y in range(y0, y1) if px[x, y] < INK) / (y1 - y0)

        columns = [x for x in range(width)
                   if dark_column(x, height // 6, height * 5 // 6) > 0.60]
        if not columns:
            raise SystemExit("could not find the board: is Chess on screen?")
        left, right = columns[0], columns[-1]
        size = right - left + 1

        def dark_row(y):
            span = range(left + 5, right - 5)
            return sum(1 for x in span if px[x, y] < INK) / len(span)

        rows = [y for y in range(height) if dark_row(y) > 0.95]
        tops = [y for y in rows if any(abs((b - y + 1) - size) <= 2
                                       for b in rows if b > y)]
        if not tops:
            raise SystemExit("found the board's sides but not its top and bottom")
        return left, tops[0], size / 8.0


def square_xy(name, geometry):
    left, top, square = geometry
    file_ = ord(name[0]) - ord("a")
    rank = int(name[1])
    if not (0 <= file_ <= 7 and 1 <= rank <= 8):
        raise SystemExit(f"not a square: {name}")
    return (int(left + file_ * square + square / 2),
            int(top + (8 - rank) * square + square / 2))


def tap(dsp, x, y):
    xtest.fake_input(dsp, X.MotionNotify, x=x, y=y)
    dsp.sync()
    time.sleep(0.05)
    xtest.fake_input(dsp, X.ButtonPress, 1)
    dsp.sync()
    time.sleep(0.06)
    xtest.fake_input(dsp, X.ButtonRelease, 1)
    dsp.sync()


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)

    dsp = display.Display(DISPLAY_NUM)
    geometry = None

    for arg in sys.argv[1:]:
        if arg.startswith("s"):                 # s2.5 -> sleep 2.5 seconds
            time.sleep(float(arg[1:]))
            continue
        if arg.startswith("@"):                 # @x,y -> raw coordinates
            x, y = (int(v) for v in arg[1:].split(","))
        else:
            if geometry is None:                # only look for the board if needed
                geometry = board_geometry()
                print("board: left=%d top=%d square=%.1f" % geometry)
            x, y = square_xy(arg, geometry)
        print(f"tap {arg} -> ({x},{y})")
        tap(dsp, x, y)
        time.sleep(0.4)


if __name__ == "__main__":
    main()
