#!/usr/bin/env python3
"""Generate app/res/icon.png, the Onion OS launcher icon.

Composites the sparkle in assets/ onto a rounded tile, recoloured light. The
source art is solid black, which is very nearly invisible against Onion's dark
themes; only its alpha channel is kept, so the antialiased edges survive the
recolour.

The source lives in assets/ rather than app/res/ so that only the generated
icon ships in the release archive.

The result is committed so that installing never requires a build step. This
script exists so the artwork is reproducible and reviewable as source, and CI
fails if the committed PNG drifts from it.

Written against the standard library only: the Miyoo toolchain image has no
imaging libraries, and contributors should not need to install one.

    python3 tools/make_icon.py [--output PATH] [--source PATH] [--size N]
"""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys
import zlib

# The tile is rendered at SUPERSAMPLE times the target size and box-filtered
# down, which gives clean curves without hand-rolling an antialiaser.
SUPERSAMPLE = 3

BACKGROUND = (30, 36, 48, 255)  # slate, reads well on Onion's dark themes
FOREGROUND = (236, 240, 245, 255)  # off-white
TRANSPARENT = (0, 0, 0, 0)

# Fraction of the tile the sparkle occupies, leaving a margin so the icon does
# not crowd its neighbours in the Apps carousel.
GLYPH_SCALE = 0.68

Color = tuple[int, int, int, int]


# -----------------------------------------------------------------------------
# PNG decoding
# -----------------------------------------------------------------------------


def read_png(path: pathlib.Path) -> "Canvas":
    """Decode an 8-bit non-interlaced PNG. Enough for the committed source art."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"make_icon: {path} is not a PNG")

    pos, idat = 8, bytearray()
    width = height = channels = 0

    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        tag = data[pos + 4 : pos + 8]
        payload = data[pos + 8 : pos + 8 + length]
        pos += 12 + length  # length + tag + payload + crc

        if tag == b"IHDR":
            width, height, depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            if depth != 8 or interlace != 0:
                sys.exit("make_icon: only 8-bit non-interlaced PNGs are supported")
            channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type, 0)
            if not channels:
                sys.exit(f"make_icon: unsupported colour type {color_type}")
        elif tag == b"IDAT":
            idat += payload
        elif tag == b"IEND":
            break

    raw = zlib.decompress(bytes(idat))
    rows = _unfilter(raw, width, height, channels)

    canvas = Canvas(max(width, height))
    for y in range(height):
        row = rows[y]
        for x in range(width):
            px = row[x * channels : (x + 1) * channels]
            canvas.pixels[y * canvas.size + x] = _to_rgba(px, channels)
    return canvas


def _to_rgba(px: bytes, channels: int) -> list[int]:
    if channels == 4:
        return list(px)
    if channels == 3:
        return [px[0], px[1], px[2], 255]
    if channels == 2:
        return [px[0], px[0], px[0], px[1]]
    return [px[0], px[0], px[0], 255]


def _unfilter(raw: bytes, width: int, height: int, channels: int) -> list[bytearray]:
    """Reverse the per-scanline filters defined by the PNG spec."""
    stride = width * channels
    rows: list[bytearray] = []
    prev = bytearray(stride)
    i = 0

    for _ in range(height):
        method = raw[i]
        i += 1
        line = bytearray(raw[i : i + stride])
        i += stride

        if method == 1:  # Sub
            for x in range(channels, stride):
                line[x] = (line[x] + line[x - channels]) & 0xFF
        elif method == 2:  # Up
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xFF
        elif method == 3:  # Average
            for x in range(stride):
                left = line[x - channels] if x >= channels else 0
                line[x] = (line[x] + ((left + prev[x]) >> 1)) & 0xFF
        elif method == 4:  # Paeth
            for x in range(stride):
                left = line[x - channels] if x >= channels else 0
                up = prev[x]
                up_left = prev[x - channels] if x >= channels else 0
                guess = left + up - up_left
                da, db, dc = (
                    abs(guess - left),
                    abs(guess - up),
                    abs(guess - up_left),
                )
                if da <= db and da <= dc:
                    pick = left
                elif db <= dc:
                    pick = up
                else:
                    pick = up_left
                line[x] = (line[x] + pick) & 0xFF
        elif method != 0:
            sys.exit(f"make_icon: unknown PNG filter {method}")

        rows.append(line)
        prev = line

    return rows


# -----------------------------------------------------------------------------
# Raster
# -----------------------------------------------------------------------------


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

    def resized(self, size: int) -> "Canvas":
        """Area-average resample. Only ever used to shrink, where it is exact."""
        out = Canvas(size)
        ratio = self.size / size
        for y in range(size):
            y0, y1 = int(y * ratio), max(int((y + 1) * ratio), int(y * ratio) + 1)
            for x in range(size):
                x0, x1 = int(x * ratio), max(int((x + 1) * ratio), int(x * ratio) + 1)
                totals = [0, 0, 0, 0]
                count = 0
                for sy in range(y0, min(y1, self.size)):
                    for sx in range(x0, min(x1, self.size)):
                        src = self.pixels[sy * self.size + sx]
                        alpha = src[3]
                        totals[0] += src[0] * alpha
                        totals[1] += src[1] * alpha
                        totals[2] += src[2] * alpha
                        totals[3] += alpha
                        count += 1
                if count == 0 or totals[3] == 0:
                    out.pixels[y * size + x] = [0, 0, 0, 0]
                else:
                    out.pixels[y * size + x] = [
                        totals[0] // totals[3],
                        totals[1] // totals[3],
                        totals[2] // totals[3],
                        totals[3] // count,
                    ]
        return out

    def tinted(self, color: Color) -> "Canvas":
        """Replace every colour while keeping alpha, so antialiasing survives."""
        out = Canvas(self.size)
        for i, src in enumerate(self.pixels):
            out.pixels[i] = [color[0], color[1], color[2], src[3]]
        return out

    def composite(self, other: "Canvas", ox: int, oy: int) -> None:
        """Source-over alpha blend of `other` at (ox, oy)."""
        for y in range(other.size):
            for x in range(other.size):
                src = other.pixels[y * other.size + x]
                alpha = src[3]
                if alpha == 0:
                    continue

                dx, dy = ox + x, oy + y
                if not (0 <= dx < self.size and 0 <= dy < self.size):
                    continue

                dst = self.pixels[dy * self.size + dx]
                inv = 255 - alpha
                self.pixels[dy * self.size + dx] = [
                    (src[0] * alpha + dst[0] * inv) // 255,
                    (src[1] * alpha + dst[1] * inv) // 255,
                    (src[2] * alpha + dst[2] * inv) // 255,
                    min(255, alpha + dst[3] * inv // 255),
                ]

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


# -----------------------------------------------------------------------------


def draw(size: int, source: pathlib.Path) -> Canvas:
    tile = Canvas(size * SUPERSAMPLE)
    radius = 36 * (size * SUPERSAMPLE) / 200.0
    tile.rounded_rect(
        0, 0, size * SUPERSAMPLE - 1, size * SUPERSAMPLE - 1, radius, BACKGROUND
    )
    icon = tile.downsample(SUPERSAMPLE)

    glyph = read_png(source).tinted(FOREGROUND).resized(int(size * GLYPH_SCALE))
    offset = (size - glyph.size) // 2
    icon.composite(glyph, offset, offset)

    return icon


def main() -> None:
    repo_root = pathlib.Path(__file__).resolve().parent.parent

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, default=repo_root / "app/res/icon.png")
    parser.add_argument(
        "--source", type=pathlib.Path, default=repo_root / "assets/dpad-chat-icon.png"
    )
    parser.add_argument("--size", type=int, default=200)
    args = parser.parse_args()

    icon = draw(args.size, args.source)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(icon.to_png())
    print(f"wrote {args.output} ({args.size}x{args.size}) from {args.source.name}")


if __name__ == "__main__":
    main()
