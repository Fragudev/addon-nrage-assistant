#!/usr/bin/env python3
"""Draws the shape art of the NRAGE style (docs/NRAGE_STYLE_PLAN.md section 3.3) as white TGA files with alpha.

It reuses the analytic rasterizer of make_icons.py. The game tints the art at runtime, so it is drawn white.

  cutN_fill   the corner square of a panel whose top-left corner is cut by N units: the half that stays solid.
  cutN_edge   the matching diagonal border line, one unit thick measured across the line.
  glow        a soft square halo for nine-slicing: the 24 px border falls off, the 16 px middle is solid.
  corner_glow a soft radial with its centre in the top-left corner of the tile, for the window corner.

The cut tiles cover exactly the N x N corner square (the other corners are the same tile flipped with SetTexCoord)
and are drawn with a power-of-two side: N units are spread over that many pixels, so the scale is 4x for the cuts
of 4 and 8, and 5.33x for 6.

Usage: tools/make_shapes.py [output-directory]   (default NrageAssistant/Media/Shapes)
"""

import math
import os
import sys

from make_icons import Shape, edge, render, write_tga

CUTS = {4: 16, 6: 32, 8: 32}  # cut size in units -> tile side in pixels
GLOW_BORDER = 24
GLOW_MIDDLE = 16


class CutFill(Shape):
    """The part of the corner square that stays solid: everything on the inner side of x + y = cut."""

    def __init__(self, cut, side):
        self.cut, self.scale = cut, side / cut

    def coverage(self, px, py):
        # Perpendicular distance (in units) to the diagonal, positive on the solid side.
        d = ((px + py) / self.scale - self.cut) / math.sqrt(2)
        return edge(-d, 0)


class CutEdge(Shape):
    """A line one unit thick, measured across it, along the inside of the diagonal."""

    def __init__(self, cut, side):
        self.cut, self.scale = cut, side / cut

    def coverage(self, px, py):
        d = ((px + py) / self.scale - self.cut) / math.sqrt(2)
        # Centre of the band is half a unit inside the diagonal; half width is half a unit.
        return edge(abs(d - 0.5) * self.scale, 0.5 * self.scale)


class Glow(Shape):
    """Alpha 1 over the middle square, falling off quadratically over the border to 0 at the tile edge."""

    def __init__(self, side):
        self.side = side

    def coverage(self, px, py):
        lo, hi = GLOW_BORDER, self.side - GLOW_BORDER
        dx = max(lo - px, 0, px - hi)
        dy = max(lo - py, 0, py - hi)
        return max(0.0, 1 - math.hypot(dx, dy) / GLOW_BORDER) ** 2


class CornerGlow(Shape):
    """A radial falloff centred on the top-left corner of the tile, reaching 0 at the tile's side."""

    def __init__(self, side):
        self.side = side

    def coverage(self, px, py):
        return max(0.0, 1 - math.hypot(px, py) / self.side) ** 2


def art():
    shapes = {}
    for cut, side in CUTS.items():
        shapes[f"cut{cut}_fill"] = (side, [CutFill(cut, side)])
        shapes[f"cut{cut}_edge"] = (side, [CutEdge(cut, side)])
    side = 2 * GLOW_BORDER + GLOW_MIDDLE
    shapes["glow"] = (side, [Glow(side)])
    shapes["corner_glow"] = (128, [CornerGlow(128)])
    return shapes


def main():
    output = sys.argv[1] if len(sys.argv) > 1 else os.path.join("NrageAssistant", "Media", "Shapes")
    os.makedirs(output, exist_ok=True)
    for name, (side, shapes) in art().items():
        write_tga(os.path.join(output, name + ".tga"), render(shapes, side))
        print("wrote", name, f"{side}x{side}")


if __name__ == "__main__":
    main()
