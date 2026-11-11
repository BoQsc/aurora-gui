"""One-off asset generator for the Aurora Video Recorder icons.

Draws the window icon in three states (idle, recording, stopped) at every
standard size and packs them into multi-resolution Windows ICO files.

Run from the project folder:  python tools/make_icons.py
"""
import math
import struct
from pathlib import Path

SIZES = (16, 24, 32, 48, 64, 128, 256)
ASSETS = Path(__file__).resolve().parent.parent / "assets"

ACCENT = (96, 165, 250)      # blue ring, matches the dark theme accent
RED = (239, 68, 68)          # recording dot
GREEN = (34, 197, 94)        # finished/stop
DARK = (17, 24, 39)          # plate behind the glyph
WHITE = (255, 255, 255)


def blend(dst, src, alpha):
    return tuple(int(round(d + (s - d) * alpha)) for d, s in zip(dst, src))


def shade(px, x, y, color, coverage):
    """Composite `color` onto pixel (x, y) with `coverage` in 0..1."""
    r, g, b, a = px[x, y]
    base = (r, g, b)
    out = blend(base, color, coverage)
    new_a = a + (255 - a) * coverage
    px[x, y] = (out[0], out[1], out[2], int(round(min(255, new_a))))


def draw_coverage(px, size, inside, color):
    """Fill every pixel whose centre satisfies `inside`, with 4x4 sampling."""
    samples = 4
    for y in range(size):
        for x in range(size):
            hits = 0
            for sy in range(samples):
                for sx in range(samples):
                    fx = (x + (sx + 0.5) / samples) / size
                    fy = (y + (sy + 0.5) / samples) / size
                    if inside(fx, fy):
                        hits += 1
            if hits:
                shade(px, x, y, color, hits / (samples * samples))


def render(size, state):
    # Rounded square plate.
    radius = 0.22
    px = {}
    for y in range(size):
        for x in range(size):
            px[x, y] = (0, 0, 0, 0)

    def in_plate(fx, fy):
        # Rounded-rectangle signed test in normalised coordinates.
        cx = min(max(fx, radius), 1 - radius)
        cy = min(max(fy, radius), 1 - radius)
        return (fx - cx) ** 2 + (fy - cy) ** 2 <= radius ** 2 or (
            radius <= fx <= 1 - radius and 0 <= fy <= 1) or (
            0 <= fx <= 1 and radius <= fy <= 1 - radius)

    def in_ring(fx, fy, inner, outer):
        dx, dy = fx - 0.5, fy - 0.5
        r = math.hypot(dx, dy)
        return inner <= r <= outer

    draw_coverage(px, size, in_plate, DARK)
    # Accent ring.
    draw_coverage(px, size, lambda x, y: in_ring(x, y, 0.355, 0.435), ACCENT)

    if state == "recording":
        draw_coverage(px, size, lambda x, y: in_ring(x, y, 0.0, 0.255), RED)
    elif state == "stopped":
        # Small square "stop" glyph.
        draw_coverage(px, size,
            lambda x, y: 0.325 <= x <= 0.675 and 0.325 <= y <= 0.675, GREEN)
    else:
        # Idle: a small filled dot in the accent colour.
        draw_coverage(px, size, lambda x, y: in_ring(x, y, 0.0, 0.135), ACCENT)

    return px


def to_bmp(px, size):
    """32-bit BGRA DIB payload with an all-zero AND mask, as ICO expects."""
    header = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0,
                         size * size * 4, 0, 0, 0, 0)
    rows = []
    for y in range(size - 1, -1, -1):
        row = bytearray()
        for x in range(size):
            r, g, b, a = px[x, y]
            row += bytes((b, g, r, a))
        rows.append(bytes(row))
    mask_stride = ((size + 31) // 32) * 4
    mask = bytes(mask_stride * size)
    return header + b"".join(rows) + mask


def write_ico(path, state):
    images = [(size, to_bmp(render(size, state), size)) for size in SIZES]
    offset = 6 + 16 * len(images)
    entries, payload = b"", b""
    for size, data in images:
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1,
                               32, len(data), offset)
        offset += len(data)
        payload += data
    path.write_bytes(struct.pack("<HHH", 0, 1, len(images)) + entries + payload)


def main():
    ASSETS.mkdir(exist_ok=True)
    for state, name in (("idle", "icon.ico"),
                        ("recording", "icon-recording.ico"),
                        ("stopped", "icon-stopped.ico")):
        target = ASSETS / name
        write_ico(target, state)
        print(f"{target.name}: {target.stat().st_size} bytes")


if __name__ == "__main__":
    main()
