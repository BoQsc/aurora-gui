"""Crop a binary PPM (P6) for the plan-strip render comparison."""
import sys

src, dst, x, y, width, height = (
    sys.argv[1], sys.argv[2],
    *[int(v) for v in sys.argv[3:7]],
)
with open(src, "rb") as fh:
    data = fh.read()
assert data[:2] == b"P6", "expected binary PPM"
i = 2
header = []
while len(header) < 3:
    while data[i:i + 1].isspace():
        i += 1
    if data[i:i + 1] == b"#":
        while data[i:i + 1] not in (b"\n", b""):
            i += 1
        continue
    start = i
    while not data[i:i + 1].isspace():
        i += 1
    header.append(int(data[start:i]))
i += 1
full_width, full_height, _ = header
assert x + width <= full_width and y + height <= full_height, "crop outside frame"
out = bytearray()
for row in range(y, y + height):
    start = i + (row * full_width + x) * 3
    out += data[start:start + width * 3]
with open(dst, "wb") as fh:
    fh.write(b"P6\n" + f"{width} {height}\n255\n".encode() + bytes(out))
print(f"cropped {width}x{height} -> {dst}")
