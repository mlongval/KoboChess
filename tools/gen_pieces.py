#!/usr/bin/env python3
"""Generate the twelve chess piece images used by the Kobo Chess plugin.

The artwork is drawn here rather than shipped as third-party assets, so there
is nothing to attribute and nothing to license. Shapes are described in a
1000x1000 coordinate space and rendered supersampled, then downscaled, which
is what gives the curves clean edges.

Style is the one that reads best on a greyscale e-ink panel and matches
printed chess diagrams: white pieces are white with a heavy black contour,
black pieces are solid black with white contours inside.

Usage:  python3 tools/gen_pieces.py [--size 256] [--out DIR]
"""

import argparse
import os

from PIL import Image, ImageDraw, ImageFilter

# Internal drawing resolution. Everything is described in a 1000x1000 space and
# drawn at SS times that, then downscaled with a good filter.
UNIT = 1000
SS = 4

# Contour weights, in unit space.
OUTLINE_W = 46      # outer contour of a white piece
DETAIL_W = 26       # contour lines inside a white piece
DETAIL_W_BLACK = 20  # ...and inside a black piece, where they are white on black

WHITE = (255, 255, 255)
BLACK = (0, 0, 0)


# ---------------------------------------------------------------------------
# Shape helpers
#
# Each piece is a list of primitives. They are unioned into one silhouette, so
# they can overlap freely; the seams never show on the outside, and the
# individual outlines become the internal contour lines.
#
# A primitive's role decides how it is treated:
#   "body"  - part of the silhouette, and its outline becomes a contour line
#   "solid" - part of the silhouette with no contour line of its own. Used for
#             small features (a crown's finials, a rook's merlons) which a
#             contour line would swallow whole rather than describe.
#   "cut"   - an incised line: black on a white piece, white on a black one.
# ---------------------------------------------------------------------------

def poly(*points, role="body"):
    return ("polygon", list(points), role)


def ellipse(cx, cy, rx, ry, role="body"):
    return ("ellipse", (cx - rx, cy - ry, cx + rx, cy + ry), role)


def circle(cx, cy, r, role="body"):
    return ellipse(cx, cy, r, r, role)


def rect(x0, y0, x1, y1, role="body"):
    return poly((x0, y0), (x1, y0), (x1, y1), (x0, y1), role=role)


def line(points, width, role="cut"):
    """A stroked curve of a given width.

    Some features -- a horse's cheek, its mouth -- are lines rather than the
    edge of a filled area. Deriving them from an overlapping shape means
    controlling the line by moving something invisible, which is unworkable
    for a curve; stroking a path directly is what the drawing actually is.
    """
    return ("line", {"points": list(points), "width": width}, role)


def base():
    """The plinth every piece stands on."""
    return [
        poly((170, 940), (830, 940), (800, 862), (200, 862)),
        poly((225, 866), (775, 866), (745, 800), (255, 800), role="solid"),
    ]


def stem(top_y, top_half, bottom_y, bottom_half):
    """A tapered body between two rounded collars."""
    return poly(
        (500 - top_half, top_y), (500 + top_half, top_y),
        (500 + bottom_half, bottom_y), (500 - bottom_half, bottom_y),
    )


# ---------------------------------------------------------------------------
# The pieces
# ---------------------------------------------------------------------------

def pawn():
    return [
        circle(500, 285, 145),
        # Collar under the head.
        poly((372, 430), (628, 430), (610, 486), (390, 486)),
        # Body flaring out to the base.
        poly((410, 470), (590, 470), (672, 800), (328, 800)),
    ] + base()


def rook():
    shapes = []
    # Crenellated top: three merlons standing on a solid band.
    for x0, x1 in ((228, 348), (440, 560), (652, 772)):
        shapes.append(rect(x0, 120, x1, 250, role="solid"))
    shapes.append(rect(228, 250, 772, 330))
    # Collar.
    shapes.append(poly((262, 330), (738, 330), (706, 398), (294, 398), role="solid"))
    # Body.
    shapes.append(poly((330, 386), (670, 386), (700, 800), (300, 800)))
    return shapes + base()


def knight():
    # A horse's head and neck in profile, facing left.
    #
    # The outline is traced as one loop: up the throat to the nose, over the
    # muzzle and forehead to the ears, then down the back of the neck to the
    # chest. It is deliberately broad -- a knight drawn as a thin head on a
    # thin neck reads as scrawny next to the rook and queen, which are solid
    # from base to top.
    # The head is a long wedge pointing down and forward. Getting that angle
    # right is what separates a horse from a bear: the muzzle has to reach
    # low and forward while the forehead slopes back and up to the ear.
    head = poly(
        # Chest and throat, rising to the jaw.
        (262, 800), (258, 706), (244, 632), (222, 574), (196, 528),
        # Chin and muzzle: the lowest, most forward part of the head.
        (166, 500), (128, 494), (104, 466), (106, 434), (126, 404),
        # The long bridge of the nose, sloping up and back to the brow.
        (170, 384), (230, 362), (300, 330), (368, 292), (430, 246),
        # Two ears with a deep notch between them -- the silhouette that says
        # "knight" at a glance, more than any other single feature. The notch
        # has to be cut generously: the contour stroke grows the outline from
        # both of its sides, so a shallow one closes up into a single bump.
        (474, 190), (480, 100), (538, 228), (592, 96), (628, 212),
        # The crest, then down the arch of the neck to the chest.
        (688, 286), (740, 372), (780, 470), (800, 576), (800, 676),
        (788, 754), (778, 800),
    )
    # The cheek: one long curve from below the ears down to the chin. This is
    # what separates the face from the jaw, and without it the head reads as
    # a featureless wedge no matter how well proportioned it is.
    # It has to swing well clear of the nose bridge: run it too close and the
    # muzzle is pinched into a thin crescent instead of reading as a face.
    cheek = line([(456, 262), (430, 352), (388, 442), (330, 498),
                  (256, 522), (188, 508)], 26)
    # Mouth and nostril.
    mouth = line([(112, 462), (150, 478)], 18)
    nostril = circle(152, 424, 15, role="cut")
    # The eye, an upright oval rather than a dot -- it reads as an eye at
    # square size, where a circle reads as a hole. It sits in the gap between
    # the nose bridge and the cheek line.
    eye = ellipse(402, 332, 20, 27, role="cut")
    return [head, cheek, mouth, nostril, eye] + base()


def bishop():
    return [
        # Finial.
        circle(500, 118, 62, role="solid"),
        # Mitre: a teardrop, wide at the bottom.
        poly(
            (500, 160), (588, 250), (628, 372), (620, 470),
            (560, 512), (440, 512), (380, 470), (372, 372), (412, 250),
        ),
        # The slit in the mitre: the bishop's one identifying mark, so it is
        # incised rather than contoured and stays visible in both colours.
        poly((488, 196), (556, 306), (532, 318), (476, 214), role="cut"),
        # Collar.
        poly((392, 500), (608, 500), (588, 566), (412, 566), role="solid"),
        # Body.
        poly((424, 552), (576, 552), (664, 800), (336, 800)),
    ] + base()


def queen():
    shapes = []
    # Coronet: five balls on spikes.
    points = ((238, 214), (370, 150), (500, 128), (630, 150), (762, 214))
    for cx, cy in points:
        shapes.append(circle(cx, cy, 58, role="solid"))
    # The crown body linking the spikes down to the collar.
    shapes.append(poly(
        (238, 232), (370, 176), (500, 152), (630, 176), (762, 232),
        (700, 470), (300, 470),
    ))
    # Collar.
    shapes.append(poly((286, 458), (714, 458), (676, 536), (324, 536)))
    shapes.append(poly((318, 528), (682, 528), (660, 590), (340, 590), role="solid"))
    # Body.
    shapes.append(poly((356, 578), (644, 578), (700, 800), (300, 800)))
    return shapes + base()


def king():
    shapes = []
    # Cross. Solid, so that on a black king it stays a cross instead of
    # collapsing into an outline of one.
    shapes.append(rect(462, 60, 538, 250, role="solid"))
    shapes.append(rect(396, 128, 604, 200, role="solid"))
    # Crown.
    shapes.append(poly(
        (268, 300), (732, 300), (760, 400), (700, 500), (300, 500), (240, 400),
    ))
    # Collar.
    shapes.append(poly((286, 488), (714, 488), (676, 560), (324, 560)))
    shapes.append(poly((318, 552), (682, 552), (660, 610), (340, 610), role="solid"))
    # Body.
    shapes.append(poly((356, 598), (644, 598), (700, 800), (300, 800)))
    return shapes + base()


PIECES = {
    "p": pawn,
    "n": knight,
    "b": bishop,
    "r": rook,
    "q": queen,
    "k": king,
}


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def draw_shapes(mask, shapes, fill=None, outline=None, width=0, roles=None):
    """Draw the primitives whose role is in `roles` (all of them if None)."""
    d = ImageDraw.Draw(mask)
    for kind, geom, role in shapes:
        if roles is not None and role not in roles:
            continue
        if kind == "polygon":
            pts = [(x * SS, y * SS) for x, y in geom]
            d.polygon(pts, fill=fill, outline=outline, width=width * SS)
        elif kind == "ellipse":
            box = tuple(v * SS for v in geom)
            d.ellipse(box, fill=fill, outline=outline, width=width * SS)
        elif kind == "line":
            # A stroke has no interior to outline, so it only takes part in
            # the filling passes.
            if fill is None:
                continue
            pts = [(x * SS, y * SS) for x, y in geom["points"]]
            w = max(1, int(geom["width"] * SS))
            d.line(pts, fill=fill, width=w, joint="curve")
            # Round the end caps, which `joint` does not cover.
            r = w // 2
            for x, y in (pts[0], pts[-1]):
                d.ellipse((x - r, y - r, x + r, y + r), fill=fill)


def stroke_outward(mask, shapes, amount, roles):
    """Add a stroke centred on each shape's boundary, growing the mask by
    `amount` on every side.

    Pillow strokes a polygon outline *inward* from its path, so it cannot
    enlarge a silhouette. Drawing the boundary as a thick line does: a line is
    stroked centred on its path. Unlike a blur-based dilation this keeps
    corners square, which matters for the rook's crenellations.
    """
    d = ImageDraw.Draw(mask)
    w = int(amount * 2 * SS)
    for kind, geom, role in shapes:
        if role not in roles:
            continue
        if kind == "line":
            continue        # strokes are interior detail; they never grow the outline
        if kind == "polygon":
            pts = [(x * SS, y * SS) for x, y in geom]
            d.line(pts + [pts[0]], fill=255, width=w, joint="curve")
            # `joint` does not round the closing corner, so cap it by hand.
            r = w // 2
            for x, y in pts:
                d.ellipse((x - r, y - r, x + r, y + r), fill=255)
        elif kind == "ellipse":
            x0, y0, x1, y1 = (v * SS for v in geom)
            pad = amount * SS
            d.ellipse((x0 - pad, y0 - pad, x1 + pad, y1 + pad), fill=255)


def _offset(mask, amount, threshold):
    """Blur-and-threshold, which shrinks or grows a mask depending on where
    the threshold sits. A true morphological kernel at this supersampled
    resolution would be enormous and slow, and the difference does not survive
    the downscale."""
    blurred = mask.filter(ImageFilter.GaussianBlur(amount * SS * 0.6))
    return blurred.point(lambda v: 255 if v >= threshold else 0)


def shrink(mask, amount):
    """Erode a mask by roughly `amount` unit-space pixels."""
    return _offset(mask, amount, 248)


def grow(mask, amount):
    """Dilate a mask by roughly `amount` unit-space pixels.

    Needed because Pillow strokes a polygon's outline inward from its path,
    so drawing shapes with a wide outline never produces a silhouette any
    larger than the filled one.
    """
    return _offset(mask, amount, 8)


def render(shapes, is_white, size):
    """Render one piece to an RGBA image of the requested size."""
    big = (UNIT * SS, UNIT * SS)
    solid_roles = ("body", "solid", "cut")

    # Union of the filled shapes: the interior of the piece.
    inner = Image.new("L", big, 0)
    draw_shapes(inner, shapes, fill=255, roles=solid_roles)

    # The full silhouette: the interior grown outwards by the contour weight.
    # Both colours grow by the same amount so the two sets have equal visual
    # weight on the board; on a white piece the added ring is the black
    # contour, on a black piece it is simply more black.
    outer = inner.copy()
    stroke_outward(outer, shapes, OUTLINE_W / 2, solid_roles)

    # Contour lines where the major parts of the piece meet. Only "body"
    # shapes contribute; "solid" ones are too small to survive being outlined.
    detail_w = DETAIL_W if is_white else DETAIL_W_BLACK
    detail = Image.new("L", big, 0)
    draw_shapes(detail, shapes, fill=None, outline=255, width=detail_w,
                roles=("body",))

    # Clip contour lines to the piece. On a black piece they are additionally
    # held back from the edge, so the silhouette stays crisp rather than
    # getting chewed into by white.
    keep_in = inner if is_white else shrink(inner, detail_w)
    detail = Image.composite(detail, Image.new("L", big, 0), keep_in)

    # Incised lines are drawn at full strength regardless.
    cuts = Image.new("L", big, 0)
    draw_shapes(cuts, shapes, fill=255, roles=("cut",))

    if is_white:
        # White body; black outer contour, contour lines and incisions.
        rgb = Image.new("RGB", big, BLACK)
        rgb.paste(Image.new("RGB", big, WHITE), (0, 0), inner)
        rgb.paste(Image.new("RGB", big, BLACK), (0, 0), detail)
        rgb.paste(Image.new("RGB", big, BLACK), (0, 0), cuts)
    else:
        # Solid black body with white contour lines and incisions inside it.
        rgb = Image.new("RGB", big, BLACK)
        rgb.paste(Image.new("RGB", big, WHITE), (0, 0), detail)
        rgb.paste(Image.new("RGB", big, WHITE), (0, 0), cuts)

    img = Image.merge("RGBA", (*rgb.split(), outer))
    return img.resize((size, size), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--size", type=int, default=256,
                    help="output image size in pixels (default 256)")
    ap.add_argument("--out", default="kobochess.koplugin/pieces",
                    help="output directory")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    for letter, builder in PIECES.items():
        shapes = builder()
        for colour, is_white in (("w", True), ("b", False)):
            img = render(shapes, is_white, args.size)
            path = os.path.join(args.out, f"{colour}{letter}.png")
            img.save(path, "PNG", optimize=True)
            print(f"  {path}  {img.size[0]}x{img.size[1]}")

    # A contact sheet on a checkerboard, so both colours are visible against
    # both square shades -- a white background would hide the white pieces.
    s = args.size
    sheet = Image.new("RGBA", (s * 6, s * 2), (255, 255, 255, 255))
    d = ImageDraw.Draw(sheet)
    for col in range(6):
        for row in range(2):
            if (col + row) % 2 == 1:
                d.rectangle((col * s, row * s, (col + 1) * s - 1, (row + 1) * s - 1),
                            fill=(180, 180, 180, 255))
    for col, letter in enumerate("pnbrqk"):
        for row, colour in enumerate(("w", "b")):
            piece = Image.open(os.path.join(args.out, f"{colour}{letter}.png"))
            sheet.paste(piece, (col * s, row * s), piece)
    # Written to the working directory rather than into the plugin: it is for
    # reviewing the set, not for shipping to the device.
    sheet_path = "pieces_preview.png"
    sheet.save(sheet_path)
    print(f"  {sheet_path}  (preview only, not shipped)")


if __name__ == "__main__":
    main()
