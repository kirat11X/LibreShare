#!/usr/bin/env python3
"""Generates the tray icons (assets/tray/*.png) with the standard library only.

    python3 assets/src/make_tray_icons.py

tray_idle.png    blue disc with a white "share" glyph (three nodes, two links)
tray_active.png  same, plus a green "receiving" badge in the lower right corner

64x64 RGBA, antialiased by 4x supersampling; the tray backends scale it down.
The output is deterministic, so regenerating produces identical bytes.
"""
import math
import os
import struct
import zlib

SIZE = 64
SS = 4  # supersampling factor
BLUE = (30, 111, 217)
WHITE = (255, 255, 255)
GREEN = (46, 204, 113)


def dist_to_segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def render(active):
    n = SIZE * SS
    s = SS
    # Glyph geometry in output pixels.
    left = (19.0, 32.0)
    top = (44.0, 19.0)
    bottom = (44.0, 45.0)
    node_r = 6.5
    link_w = 2.2
    disc_c, disc_r = 32.0, 31.0
    badge_c, badge_r, ring_r = (49.0, 49.0), 9.5, 12.5

    def sample(x, y):
        """Colour (r, g, b, a) of the sub-pixel at output coords (x, y)."""
        if math.hypot(x - disc_c, y - disc_c) > disc_r:
            return (0, 0, 0, 0)
        colour = BLUE
        in_glyph = (
            math.hypot(x - left[0], y - left[1]) <= node_r
            or math.hypot(x - top[0], y - top[1]) <= node_r
            or math.hypot(x - bottom[0], y - bottom[1]) <= node_r
            or dist_to_segment(x, y, *left, *top) <= link_w
            or dist_to_segment(x, y, *left, *bottom) <= link_w
        )
        if in_glyph:
            colour = WHITE
        if active:
            d = math.hypot(x - badge_c[0], y - badge_c[1])
            if d <= badge_r:
                colour = GREEN
            elif d <= ring_r:
                colour = WHITE
        return (*colour, 255)

    rows = []
    for oy in range(SIZE):
        row = bytearray([0])  # PNG filter type 0
        for ox in range(SIZE):
            r = g = b = a = 0
            for sy in range(SS):
                for sx in range(SS):
                    cr, cg, cb, ca = sample(ox + (sx + 0.5) / s, oy + (sy + 0.5) / s)
                    # Premultiplied accumulation avoids dark fringes at the edge.
                    r += cr * ca
                    g += cg * ca
                    b += cb * ca
                    a += ca
            total = SS * SS
            if a == 0:
                row += bytes((0, 0, 0, 0))
            else:
                row += bytes((round(r / a), round(g / a), round(b / a), round(a / total)))
        rows.append(bytes(row))
    return b"".join(rows)


def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def write_png(path, raw):
    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)  # 8-bit RGBA
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tray")
    os.makedirs(out, exist_ok=True)
    write_png(os.path.join(out, "tray_idle.png"), render(False))
    write_png(os.path.join(out, "tray_active.png"), render(True))
    print("wrote", os.path.normpath(out))
