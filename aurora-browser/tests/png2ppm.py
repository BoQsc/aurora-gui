"""Decode an 8-bit non-interlaced PNG (colour type 2 or 6) to a binary PPM.

The reference corpora store their independent Edge frames as PNG and the engine
writes PPM, so this is the converter between the two sides of a comparison.
It is the same reader the scratch corpora used; it is duplicated here so a
recipe can convert a reference without depending on a scratch directory.

Usage: python png2ppm.py in.png out.ppm
"""
import struct
import sys
import zlib


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    i = 8
    idat = bytearray()
    w = h = depth = ctype = None
    while i < len(data):
        length, tag = struct.unpack(">I4s", data[i:i + 8])
        body = data[i + 8:i + 8 + length]
        i += 12 + length
        if tag == b"IHDR":
            w, h, depth, ctype, comp, filt, inter = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and ctype in (2, 6) and inter == 0, (depth, ctype, inter)
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
    raw = zlib.decompress(bytes(idat))
    bpp = 3 if ctype == 2 else 4
    stride = w * bpp
    out = bytearray()
    prev = bytearray(stride)
    pos = 0
    for _ in range(h):
        ft = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if ft == 1:
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 0xff
        elif ft == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xff
        elif ft == 3:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xff
        elif ft == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 0xff
        prev = line
        out += line
    if bpp == 4:
        rgb = bytearray()
        for o in range(0, len(out), 4):
            rgb += out[o:o + 3]
        out = rgb
    return w, h, bytes(out)


def main():
    w, h, px = read_png(sys.argv[1])
    with open(sys.argv[2], "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (w, h))
        f.write(px)
    print("wrote %s (%dx%d)" % (sys.argv[2], w, h))
    return 0


if __name__ == "__main__":
    sys.exit(main())
