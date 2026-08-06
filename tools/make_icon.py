#!/usr/bin/env python3
"""Generate app/res/icon.png, the Onion OS launcher icon.

The icon is committed to the repository so that installing the app never
requires a build step. This script exists so the artwork is reproducible and
reviewable as source rather than as an opaque binary.

Written against the standard library only: the Miyoo toolchain image has no
imaging libraries, and contributors should not need to install one.

    python3 tools/make_icon.py [--output PATH] [--size N]
"""

from __future__ import annotations

import argparse
import pathlib
import struct
import zlib

# Rendered at SUPERSAMPLE times the target size and box-filtered down, which
# gives clean edges on the curves without hand-rolling an anti-aliaser.
SUPERSAMPLE = 3

BACKGROUND = (30, 36, 48, 255)  # slate, reads well on Onion's dark themes
FOREGROUND = (236, 240, 245, 255)  # off-white
TRANSPARENT = (0, 0, 0, 0)

Color = tuple[int, int, int, int]


class Canvas:
    """A minimal RGBA raster with the few primitives this icon needs."""

    def __init__(self, size: int, fill: Color = TRANSPARENT) -> None:
        self.size = size
        self.pixels = [list(fill) for _ in range(size * size)]

    def _set(self, x: int, y: int, color: Color) -> None:
        if 0 <= x < self.size and 0 <= y < self.size:
            self.pixels[y * self.size + x] = list(color)

    def rounded_rect(
        self, x0: float, y0: float, x1: float, y1: float, radius: float, color: Color
    ) -> None:
        for y in range(int(y0), int(y1) + 1):
            for x in range(int(x0), int(x1) + 1):
                # Distance past the straight edges, clamped at zero. Inside the
                # corner boxes this is the offset from the corner arc's centre.
                dx = max(x0 + radius - x, 0.0, x - (x1 - radius))
                dy = max(y0 + radius - y, 0.0, y - (y1 - radius))
                if dx * dx + dy * dy <= radius * radius:
                    self._set(x, y, color)

    def triangle(
        self, points: tuple[tuple[float, float], ...], color: Color
    ) -> None:
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        for y in range(int(min(ys)), int(max(ys)) + 1):
            for x in range(int(min(xs)), int(max(xs)) + 1):
                if self._in_triangle(x, y, points):
                    self._set(x, y, color)

    @staticmethod
    def _in_triangle(
        px: float, py: float, points: tuple[tuple[float, float], ...]
    ) -> bool:
        (ax, ay), (bx, by), (cx, cy) = points

        def edge(x0: float, y0: float, x1: float, y1: float) -> float:
            return (px - x0) * (y1 - y0) - (py - y0) * (x1 - x0)

        d1, d2, d3 = edge(ax, ay, bx, by), edge(bx, by, cx, cy), edge(cx, cy, ax, ay)
        has_neg = d1 < 0 or d2 < 0 or d3 < 0
        has_pos = d1 > 0 or d2 > 0 or d3 > 0
        return not (has_neg and has_pos)

    def downsample(self, factor: int) -> "Canvas":
        out = Canvas(self.size // factor)
        area = factor * factor
        for y in range(out.size):
            for x in range(out.size):
                totals = [0, 0, 0, 0]
                for sy in range(factor):
                    for sx in range(factor):
                        src = self.pixels[
                            (y * factor + sy) * self.size + (x * factor + sx)
                        ]
                        # Premultiply so transparent pixels do not darken edges.
                        alpha = src[3]
                        totals[0] += src[0] * alpha
                        totals[1] += src[1] * alpha
                        totals[2] += src[2] * alpha
                        totals[3] += alpha
                alpha_sum = totals[3]
                if alpha_sum == 0:
                    out.pixels[y * out.size + x] = [0, 0, 0, 0]
                else:
                    out.pixels[y * out.size + x] = [
                        totals[0] // alpha_sum,
                        totals[1] // alpha_sum,
                        totals[2] // alpha_sum,
                        alpha_sum // area,
                    ]
        return out

    def to_png(self) -> bytes:
        raw = bytearray()
        for y in range(self.size):
            raw.append(0)  # filter type 0 (None) for this row
            for x in range(self.size):
                raw.extend(self.pixels[y * self.size + x])

        def chunk(tag: bytes, payload: bytes) -> bytes:
            return (
                struct.pack(">I", len(payload))
                + tag
                + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
            )

        header = struct.pack(">IIBBBBB", self.size, self.size, 8, 6, 0, 0, 0)
        return (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b"")
        )


def draw(size: int) -> Canvas:
    """Draw a D-pad beside a speech bubble on a rounded tile."""
    s = size / 200.0  # all coordinates below are authored against a 200px grid
    canvas = Canvas(size)

    canvas.rounded_rect(0, 0, size - 1, size - 1, 36 * s, BACKGROUND)

    # D-pad: two overlapping bars forming a cross, left of centre.
    cx, cy, arm, half = 62 * s, 100 * s, 33 * s, 11 * s
    canvas.rounded_rect(cx - arm, cy - half, cx + arm, cy + half, 4 * s, FOREGROUND)
    canvas.rounded_rect(cx - half, cy - arm, cx + half, cy + arm, 4 * s, FOREGROUND)

    # Speech bubble to the right, with a tail pointing back at the D-pad.
    bx0, by0, bx1, by1 = 110 * s, 62 * s, 178 * s, 118 * s
    canvas.rounded_rect(bx0, by0, bx1, by1, 14 * s, FOREGROUND)
    canvas.triangle(
        ((bx0 + 10 * s, by1 - 2 * s), (bx0 + 34 * s, by1 - 2 * s), (bx0 + 8 * s, by1 + 22 * s)),
        FOREGROUND,
    )

    # Three dots, cut back out of the bubble in the background colour.
    dot_y = (by0 + by1) / 2
    for i in range(3):
        dot_x = bx0 + (17 + i * 17) * s
        canvas.rounded_rect(
            dot_x - 4 * s, dot_y - 4 * s, dot_x + 4 * s, dot_y + 4 * s, 4 * s, BACKGROUND
        )

    return canvas


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent / "app/res/icon.png",
    )
    parser.add_argument("--size", type=int, default=200)
    args = parser.parse_args()

    canvas = draw(args.size * SUPERSAMPLE).downsample(SUPERSAMPLE)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(canvas.to_png())
    print(f"wrote {args.output} ({args.size}x{args.size})")


if __name__ == "__main__":
    main()
