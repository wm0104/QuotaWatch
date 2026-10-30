#!/usr/bin/env python3
"""Original QuotaWatch blue account cards; deterministic opaque PNGs, stdlib only.

No fonts, downloaded art, logos or rounded-square mask. iOS supplies the mask.
Regenerate: python3 scripts/generate_icons.py; validate checked-in art: --check.
"""
import json
import math
import struct
import sys
import zlib
from pathlib import Path

CATALOG = Path(__file__).resolve().parents[1] / "QuotaWatch/Assets.xcassets"
ICONS = CATALOG / "AppIcon.appiconset"
INFO = {"info": {"author": "quotawatch", "version": 1}}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def manifest():
    images = []
    slots = [("iphone", size, scale) for size in (20, 29, 40, 60) for scale in (2, 3)]
    slots += [("ipad", size, scale) for size in (20, 29, 40, 76) for scale in (1, 2)]
    slots += [("ipad", 83.5, 2), ("ios-marketing", 1024, 1)]
    for idiom, size, scale in slots:
        pixels = int(size * scale)
        images.append({"idiom": idiom, "size": f"{size}x{size}",
                       "scale": f"{scale}x", "filename": f"icon-{pixels}.png"})
    return dict(INFO, images=images)


def mix(a, b, amount):
    return tuple(x + (y - x) * amount for x, y in zip(a, b))


def clamp(value):
    return max(0.0, min(1.0, value))


def rounded_distance(x, y, box, radius):
    left, top, right, bottom = (v / 1024 for v in box)
    radius /= 1024
    dx = abs(x - (left + right) / 2) - (right - left) / 2 + radius
    dy = abs(y - (top + bottom) / 2) - (bottom - top) / 2 + radius
    return math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - radius


def pixel(x, y, size):
    # User-selected B: two account cards, a single blue quota indicator.
    color = mix((56, 112, 242), (28, 73, 201), y)
    layers = [
        ((246, 237, 698, 641), 88, (144, 182, 255)),
        ((325, 337, 777, 741), 88, (245, 248, 255)),
        ((392, 421, 612, 452), 15, (173, 197, 251)),
        ((392, 500, 710, 540), 20, (223, 232, 252)),
        ((392, 500, 602, 540), 20, (53, 113, 234)),
        ((392, 598, 524, 629), 15, (173, 197, 251)),
    ]
    for box, radius, tint in layers:
        if box[0] / 1024 - 1 / size <= x <= box[2] / 1024 + 1 / size and box[1] / 1024 - 1 / size <= y <= box[3] / 1024 + 1 / size:
            color = mix(color, tint, clamp(0.5 - rounded_distance(x, y, box, radius) * size))
    return bytes(round(channel) for channel in color)


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def render(size):
    raw = bytearray()
    for row in range(size):
        raw.append(0)  # PNG filter: none; render analytically at each output size.
        for col in range(size):
            raw.extend(pixel((col + 0.5) / size, (row + 0.5) / size, size))
    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (PNG_SIGNATURE + chunk(b"IHDR", header) +
            chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def check_png(path, size):
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("Not a PNG: " + str(path))
    pos, kinds, compressed = 8, [], bytearray()
    while pos < len(data):
        length, = struct.unpack_from(">I", data, pos)
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length]
        crc, = struct.unpack_from(">I", data, pos + 8 + length)
        if crc != zlib.crc32(kind + body):
            raise ValueError("PNG checksum mismatch: " + str(path))
        if kind == b"IHDR" and body != struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0):
            raise ValueError("Icon must be correct-size opaque 8-bit RGB: " + str(path))
        if kind == b"IDAT":
            compressed.extend(body)
        kinds.append(kind)
        pos += length + 12
    if kinds != [b"IHDR", b"IDAT", b"IEND"] or pos != len(data):
        raise ValueError("Unexpected PNG chunks: " + str(path))
    if len(zlib.decompress(compressed)) != size * (1 + size * 3):
        raise ValueError("Incomplete PNG raster: " + str(path))


def main():
    if sys.argv[1:] not in ([], ["--check"]):
        raise SystemExit("Usage: generate_icons.py [--check]")
    content = manifest()
    sizes = sorted({int(float(image["size"].split("x")[0]) * int(image["scale"][0]))
                    for image in content["images"]})
    if not sys.argv[1:]:
        ICONS.mkdir(parents=True, exist_ok=True)
        (CATALOG / "Contents.json").write_text(json.dumps(INFO, indent=2) + "\n")
        (ICONS / "Contents.json").write_text(json.dumps(content, indent=2) + "\n")
        for size in sizes:
            (ICONS / f"icon-{size}.png").write_bytes(render(size))
    if json.loads((CATALOG / "Contents.json").read_text()) != INFO:
        raise ValueError("Unexpected catalog metadata")
    if json.loads((ICONS / "Contents.json").read_text()) != content:
        raise ValueError("Missing or incorrect iPhone/iPad/marketing icon slots")
    for size in sizes:
        check_png(ICONS / f"icon-{size}.png", size)
    print(f"AppIcon: {len(content['images'])} slots / {len(sizes)} opaque PNGs verified (20...1024px)")


if __name__ == "__main__":
    main()
