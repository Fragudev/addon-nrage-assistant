#!/usr/bin/env python3
"""Draws the stroke icons of the UI kit as small white TGA files (32x32, 32 bit, with alpha).

The icons are our own simple shapes: lines, circles, arcs and a few filled dots, rasterized with an analytic
anti-aliasing (no third-party art). The game tints them at runtime with SetVertexColor, so they are drawn white.

Usage: tools/make_icons.py [output-directory]   (default NrageAssistant/Media/Icons)
"""

import math
import os
import struct
import sys

SIZE = 32
STROKE = 2.4


def dist_segment(px, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    length_sq = dx * dx + dy * dy
    if length_sq == 0:
        return math.hypot(px - x1, py - y1)
    t = max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / length_sq))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))


class Shape:
    """A shape answers its signed distance from a point: negative inside a filled part, the stroke distance else."""

    def coverage(self, px, py):
        raise NotImplementedError


class Line(Shape):
    def __init__(self, *points, width=STROKE, closed=False):
        self.points = list(zip(points[0::2], points[1::2]))
        self.width = width
        self.closed = closed

    def coverage(self, px, py):
        best = 99.0
        pts = self.points + ([self.points[0]] if self.closed else [])
        for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
            best = min(best, dist_segment(px, py, x1, y1, x2, y2))
        return edge(best, self.width / 2)


class Circle(Shape):
    def __init__(self, cx, cy, r, width=STROKE, fill=False):
        self.cx, self.cy, self.r, self.width, self.fill = cx, cy, r, width, fill

    def coverage(self, px, py):
        d = math.hypot(px - self.cx, py - self.cy)
        if self.fill:
            return edge(d - self.r, 0)
        return edge(abs(d - self.r), self.width / 2)


class Arc(Shape):
    """An arc of a circle, angles in degrees (0 = right, counter clockwise on screen with y pointing down)."""

    def __init__(self, cx, cy, r, start, end, width=STROKE):
        self.cx, self.cy, self.r, self.start, self.end, self.width = cx, cy, r, start, end, width

    def coverage(self, px, py):
        angle = math.degrees(math.atan2(-(py - self.cy), px - self.cx)) % 360
        start, end = self.start % 360, self.end % 360
        inside = start <= angle <= end if start <= end else (angle >= start or angle <= end)
        if inside:
            return edge(abs(math.hypot(px - self.cx, py - self.cy) - self.r), self.width / 2)
        ends = []
        for a in (self.start, self.end):
            ex = self.cx + self.r * math.cos(math.radians(a))
            ey = self.cy - self.r * math.sin(math.radians(a))
            ends.append(math.hypot(px - ex, py - ey))
        return edge(min(ends), self.width / 2)


class Polygon(Shape):
    """A filled convex polygon."""

    def __init__(self, *points):
        self.points = list(zip(points[0::2], points[1::2]))
        self.cx = sum(x for x, _ in self.points) / len(self.points)
        self.cy = sum(y for _, y in self.points) / len(self.points)

    def coverage(self, px, py):
        worst = -99.0
        for (x1, y1), (x2, y2) in zip(self.points, self.points[1:] + self.points[:1]):
            length = math.hypot(x2 - x1, y2 - y1)
            # Distance outside this edge's half-plane, signed so that the centre is on the inside.
            d = ((px - x1) * (y2 - y1) - (py - y1) * (x2 - x1)) / length
            if (self.cx - x1) * (y2 - y1) - (self.cy - y1) * (x2 - x1) > 0:
                d = -d
            worst = max(worst, d)
        return edge(worst, 0)


def edge(distance, half_width):
    """1 inside the stroke, 0 outside, with a one pixel soft edge."""
    return max(0.0, min(1.0, 0.5 + half_width - distance))


def rect(x, y, w, h, width=STROKE):
    return Line(x, y, x + w, y, x + w, y + h, x, y + h, width=width, closed=True)


def _hex(cx, cy, r):
    """The corners of a flat-top regular hexagon, as a flat list of x, y."""
    corners = []
    for angle in range(0, 360, 60):
        corners += [cx + r * math.cos(math.radians(angle)), cy - r * math.sin(math.radians(angle))]
    return corners


ICONS = {
    "home": [Line(4, 16, 16, 5, 28, 16), Line(7, 14, 7, 27, 25, 27, 25, 14), Line(13, 27, 13, 19, 19, 19, 19, 27)],
    "user": [Circle(16, 11, 5.5), Arc(16, 31, 11, 28, 152)],
    "users": [
        Circle(11, 11, 4.5),
        Arc(11, 28, 9, 25, 155),
        Circle(22, 12, 3.6),
        Arc(22, 28, 7.5, 40, 120),
    ],
    "check-circle": [Circle(16, 16, 12), Line(10, 16.5, 14.5, 21, 22, 11.5)],
    "calendar": [
        rect(5, 7, 22, 20),
        Line(5, 13, 27, 13),
        Line(11, 4, 11, 9),
        Line(21, 4, 21, 9),
    ],
    "gem": [
        Line(9, 6, 23, 6, 29, 13, 16, 28, 3, 13, closed=True),
        Line(3, 13, 29, 13),
        Line(12, 6, 16, 13, 20, 6),
    ],
    "swords": [
        Line(7, 7, 25, 25),
        Line(25, 7, 7, 25),
        Line(20, 28, 28, 20),
        Line(4, 20, 12, 28),
    ],
    "ban": [Circle(16, 16, 12), Line(8, 8, 24, 24)],
    "list": [
        Line(11, 9, 27, 9),
        Line(11, 16, 27, 16),
        Line(11, 23, 27, 23),
        Circle(5.5, 9, 1.6, fill=True),
        Circle(5.5, 16, 1.6, fill=True),
        Circle(5.5, 23, 1.6, fill=True),
    ],
    "book": [rect(6, 5, 20, 22), Line(11, 5, 11, 27), Line(15, 11, 22, 11), Line(15, 16, 22, 16)],
    "close": [Line(8, 8, 24, 24), Line(24, 8, 8, 24)],
    "cross": [Line(9, 9, 23, 23), Line(23, 9, 9, 23)],
    "chevron": [Line(12, 7, 21, 16, 12, 25)],
    "check": [Line(7, 17, 13, 23, 25, 9)],
    "dash": [Line(8, 16, 24, 16)],
    "alert": [Line(16, 7, 16, 18), Circle(16, 24.5, 1.7, fill=True)],
    "gear": [
        Circle(16, 16, 8.5),
        Circle(16, 16, 3.6),
        *[
            Line(
                16 + 8.5 * math.cos(math.radians(a)),
                16 - 8.5 * math.sin(math.radians(a)),
                16 + 12.5 * math.cos(math.radians(a)),
                16 - 12.5 * math.sin(math.radians(a)),
                width=3.2,
            )
            for a in range(0, 360, 45)
        ],
    ],
    "pencil": [Line(6, 26, 8, 20, 21, 7, 25, 11, 12, 24, closed=True), Line(18, 10, 22, 14)],
    "trash": [
        Line(6, 9, 26, 9),
        Line(13, 9, 13, 6, 19, 6, 19, 9),
        Line(9, 9, 10, 27, 22, 27, 23, 9),
        Line(14, 13, 14, 23),
        Line(18, 13, 18, 23),
    ],
    "plus": [Line(16, 7, 16, 25), Line(7, 16, 25, 16)],
    "dots": [Circle(7, 16, 2.3, fill=True), Circle(16, 16, 2.3, fill=True), Circle(25, 16, 2.3, fill=True)],
    "search": [Circle(14, 14, 7.5), Line(19.8, 19.8, 27, 27)],
    "dot": [Circle(16, 16, 9, fill=True)],
    "circle": [Circle(16, 16, 11)],
    "send": [Line(5, 16, 27, 16), Line(19, 8, 27, 16, 19, 24)],
    "disc": [Circle(16, 16, 15.5, fill=True)],
    "hex": [Polygon(*_hex(16, 16, 14))],
    "hex-outline": [Line(*_hex(16, 16, 13.5), closed=True)],
    "diamond": [Polygon(16, 3, 29, 16, 16, 29, 3, 16)],
    # The map pins of the guild map and the PvP intel: a diamond that fills the whole tile, so it never reads as the
    # round pin of a party member. It is both the tinted border and the mask of the class icon.
    "pin-diamond": [Polygon(16, 0.5, 31.5, 16, 16, 31.5, 0.5, 16)],
    # Bold role marks, legible at badge size (about 10 pixels) on top of a class icon.
    "role-tank": [Polygon(5, 4, 27, 4, 27, 15, 16, 29, 5, 15)],
    "role-heal": [Line(16, 4, 16, 28, width=8), Line(4, 16, 28, 16, width=8)],
    "role-dps": [
        Line(7, 7, 25, 25, width=4.5),
        Line(25, 7, 7, 25, width=4.5),
        Line(19, 29, 29, 19, width=4.5),
        Line(3, 19, 13, 29, width=4.5),
    ],
}


def render(shapes, size=SIZE):
    """Rasterizes the shapes into size x size alpha values (2x2 samples per pixel, coordinates in pixels)."""
    pixels = []
    for row in range(size):
        line = []
        for col in range(size):
            alpha = 0.0
            for sub_y in (0.25, 0.75):
                for sub_x in (0.25, 0.75):
                    px, py = col + sub_x, row + sub_y
                    covered = max(shape.coverage(px, py) for shape in shapes)
                    alpha += covered / 4
            line.append(int(round(max(0.0, min(1.0, alpha)) * 255)))
        pixels.append(line)
    return pixels


def write_tga(path, alphas):
    # 32 bit uncompressed true-colour image, origin at the bottom left, 8 alpha bits. Square, any size.
    size = len(alphas)
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 8)
    body = bytearray()
    for row in reversed(alphas):
        for alpha in row:
            body += bytes((255, 255, 255, alpha))
    with open(path, "wb") as handle:
        handle.write(header + bytes(body))


def main():
    output = sys.argv[1] if len(sys.argv) > 1 else os.path.join("NrageAssistant", "Media", "Icons")
    os.makedirs(output, exist_ok=True)
    for name, shapes in ICONS.items():
        write_tga(os.path.join(output, name + ".tga"), render(shapes))
        print("wrote", name)


if __name__ == "__main__":
    main()
