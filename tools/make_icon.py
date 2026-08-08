#!/usr/bin/env python3
"""Generate app/res/icon.png, the Onion OS launcher icon.

Onion's app icons are **74x74 RGBA PNGs**. That is not written down anywhere in
its documentation; it is what all 25 icons in Onion's own default set are, and
what third-party icon packs match. Their artwork spans 65x65 of that tile,
leaving a margin of about 6% - which is why the default padding here is 0.06,
so this icon sits at the same visual size as the ones either side of it.

The source art in assets/ is whatever size it was drawn at. This trims its
transparent border, squares the crop, and downsamples - so the framing on the
device does not depend on how much empty space the artwork was exported with.

Downsampling averages in **premultiplied alpha**. Averaging straight RGBA drags
the colour of fully transparent pixels into its neighbours, which puts a dark
fringe around anything drawn on transparency. Gold line art on nothing is
exactly that case.

The result is committed so that installing never requires a build step. This
script exists so the artwork is reproducible and reviewable as source, and CI
fails if the committed PNG drifts from it - so everything here has to be
deterministic, which is why the resampling is integer arithmetic.

Written against the standard library only: the Miyoo toolchain image has no
imaging libraries, and contributors should not need to install one.

    python3 tools/make_icon.py [--source PATH] [--output PATH]
                               [--size N] [--pad F] [--no-trim]
"""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys
import zlib

# Measured off Onion's own icons rather than documented by it. See the module
# docstring; app/config.json points at the file this produces.
ICON_SIZE = 74
ICON_PAD = 0.06

# Bytes per pixel for each PNG colour type, which is also the filter's idea of
# "the pixel to the left".
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}

Pixel = list[int]
Rows = list[list[Pixel]]


# -----------------------------------------------------------------------------
# Reading
# -----------------------------------------------------------------------------


def decode(path: pathlib.Path) -> tuple[int, int, Rows]:
    """PNG to RGBA rows. Handles the colour types an icon might be saved as."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"make_icon: {path} is not a PNG")

    idat = b""
    palette: bytes | None = None
    alpha: bytes | None = None
    width = height = depth = colour = interlace = 0

    offset = 8
    while offset < len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        tag = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + length]

        if tag == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(
                ">IIBBBBB", body
            )
        elif tag == b"PLTE":
            palette = body
        elif tag == b"tRNS":
            alpha = body
        elif tag == b"IDAT":
            idat += body

        offset += 12 + length

    if depth != 8 or interlace != 0:
        sys.exit("make_icon: only 8-bit non-interlaced PNGs are supported")
    if colour not in CHANNELS:
        sys.exit(f"make_icon: unsupported colour type {colour}")
    if colour == 3 and palette is None:
        sys.exit("make_icon: paletted source has no PLTE chunk")

    return width, height, _unfilter(
        zlib.decompress(idat), width, height, colour, palette, alpha
    )


def _unfilter(
    raw: bytes,
    width: int,
    height: int,
    colour: int,
    palette: bytes | None,
    alpha: bytes | None,
) -> Rows:
    """Undo the per-row filters, then widen whatever it was to RGBA."""
    step = CHANNELS[colour]
    stride = width * step

    rows: Rows = []
    previous = bytearray(stride)
    pos = 0

    for _ in range(height):
        kind = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride

        for i in range(stride):
            left = line[i - step] if i >= step else 0
            up = previous[i]
            corner = previous[i - step] if i >= step else 0

            if kind == 1:
                line[i] = (line[i] + left) & 0xFF
            elif kind == 2:
                line[i] = (line[i] + up) & 0xFF
            elif kind == 3:
                line[i] = (line[i] + (left + up) // 2) & 0xFF
            elif kind == 4:
                # Paeth: whichever of the three neighbours the linear estimate
                # is closest to.
                estimate = left + up - corner
                dl, du, dc = (
                    abs(estimate - left),
                    abs(estimate - up),
                    abs(estimate - corner),
                )
                nearest = left if dl <= du and dl <= dc else up if du <= dc else corner
                line[i] = (line[i] + nearest) & 0xFF

        previous = line
        rows.append(_to_rgba(line, width, step, colour, palette, alpha))

    return rows


def _to_rgba(
    line: bytearray,
    width: int,
    step: int,
    colour: int,
    palette: bytes | None,
    alpha: bytes | None,
) -> list[Pixel]:
    out: list[Pixel] = []

    for x in range(width):
        px = line[x * step:(x + 1) * step]

        if colour == 6:
            out.append(list(px))
        elif colour == 2:
            out.append([px[0], px[1], px[2], 255])
        elif colour == 0:
            out.append([px[0], px[0], px[0], 255])
        elif colour == 4:
            out.append([px[0], px[0], px[0], px[1]])
        else:
            index = px[0]
            assert palette is not None
            # tRNS on a paletted image is a list of alphas, shorter than the
            # palette; anything past the end is opaque.
            a = alpha[index] if alpha is not None and index < len(alpha) else 255
            out.append(
                [palette[index * 3], palette[index * 3 + 1], palette[index * 3 + 2], a]
            )

    return out


# -----------------------------------------------------------------------------
# Framing and scaling
# -----------------------------------------------------------------------------


def content_box(width: int, height: int, rows: Rows) -> tuple[int, int, int, int]:
    """Bounds of everything that is not fully transparent."""
    x0, y0, x1, y1 = width, height, -1, -1

    for y in range(height):
        for x in range(width):
            if rows[y][x][3] > 0:
                x0, y0 = min(x0, x), min(y0, y)
                x1, y1 = max(x1, x), max(y1, y)

    # An image with nothing in it is framed as itself rather than crashing.
    if x1 < 0:
        return 0, 0, width - 1, height - 1
    return x0, y0, x1, y1


def squared(
    box: tuple[int, int, int, int], width: int, height: int
) -> tuple[int, int, int, int]:
    """Grow the shorter side so the art is scaled rather than stretched."""
    x0, y0, x1, y1 = box
    side = max(x1 - x0 + 1, y1 - y0 + 1)
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2

    left, top = cx - side // 2, cy - side // 2
    return (
        max(0, left),
        max(0, top),
        min(width - 1, left + side - 1),
        min(height - 1, top + side - 1),
    )


def resample(rows: Rows, box: tuple[int, int, int, int], size: int) -> Rows:
    """Box-average the source region down to size x size, in premultiplied alpha."""
    x0, y0, x1, y1 = box
    src_w, src_h = x1 - x0 + 1, y1 - y0 + 1

    out: Rows = []
    for oy in range(size):
        sy0 = y0 + oy * src_h // size
        sy1 = max(sy0 + 1, y0 + (oy + 1) * src_h // size)

        row: list[Pixel] = []
        for ox in range(size):
            sx0 = x0 + ox * src_w // size
            sx1 = max(sx0 + 1, x0 + (ox + 1) * src_w // size)

            r = g = b = a = n = 0
            for sy in range(sy0, sy1):
                for sx in range(sx0, sx1):
                    pr, pg, pb, pa = rows[sy][sx]
                    r += pr * pa
                    g += pg * pa
                    b += pb * pa
                    a += pa
                    n += 1

            row.append([r // a, g // a, b // a, a // n] if a else [0, 0, 0, 0])
        out.append(row)

    return out


def framed(art: Rows, art_size: int, size: int) -> Rows:
    """Centre the scaled art on a transparent tile."""
    tile: Rows = [[[0, 0, 0, 0] for _ in range(size)] for _ in range(size)]
    offset = (size - art_size) // 2

    for y in range(art_size):
        for x in range(art_size):
            tile[y + offset][x + offset] = art[y][x]

    return tile


# -----------------------------------------------------------------------------
# Writing
# -----------------------------------------------------------------------------


def encode(tile: Rows, size: int) -> bytes:
    raw = bytearray()
    for row in tile:
        raw.append(0)  # filter type 0 (None) for this row
        for pixel in row:
            raw.extend(pixel)

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


# -----------------------------------------------------------------------------


def main() -> None:
    repo_root = pathlib.Path(__file__).resolve().parent.parent

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source", type=pathlib.Path, default=repo_root / "assets/dpad-chat-icon.png"
    )
    parser.add_argument(
        "--output", type=pathlib.Path, default=repo_root / "app/res/icon.png"
    )
    parser.add_argument("--size", type=int, default=ICON_SIZE)
    parser.add_argument("--pad", type=float, default=ICON_PAD)
    parser.add_argument(
        "--no-trim", action="store_true", help="keep the source's own margin"
    )
    args = parser.parse_args()

    if args.size <= 0:
        sys.exit("make_icon: --size must be positive")
    if not 0 <= args.pad < 0.5:
        sys.exit("make_icon: --pad must be at least 0 and less than 0.5")

    width, height, rows = decode(args.source)

    box = (0, 0, width - 1, height - 1)
    if not args.no_trim:
        box = content_box(width, height, rows)
    box = squared(box, width, height)

    art_size = max(1, round(args.size * (1 - 2 * args.pad)))
    tile = framed(resample(rows, box, art_size), art_size, args.size)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(encode(tile, args.size))

    print(
        f"wrote {args.output} - {args.size}x{args.size} RGBA, "
        f"{art_size}px of art, from {width}x{height} {args.source.name}"
    )


if __name__ == "__main__":
    main()
