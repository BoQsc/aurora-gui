"""Convert the PPM probes to PNG and report parity statistics."""

import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_ppm(path):
    data = open(path, "rb").read()
    fields, offset = [], 0
    while len(fields) < 4:
        while data[offset:offset + 1].isspace():
            offset += 1
        start = offset
        while not data[offset:offset + 1].isspace():
            offset += 1
        fields.append(data[start:offset])
    offset += 1
    magic, width, height, maximum = fields
    assert magic == b"P6" and int(maximum) == 255
    return int(width), int(height), data[offset:offset + 3 * int(width) * int(height)]


def write_png(path, width, height, pixels):
    raw = b"".join(b"\0" + pixels[row * width * 3:(row + 1) * width * 3]
                   for row in range(height))

    def chunk(tag, payload):
        body = tag + payload
        return (struct.pack(">I", len(payload)) + body +
                struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" +
                           chunk(b"IHDR", header) +
                           chunk(b"IDAT", zlib.compress(raw, 9)) +
                           chunk(b"IEND", b""))


def statistics(pixels):
    count = len(pixels) // 3
    total = [0, 0, 0]
    for index in range(len(pixels)):
        total[index % 3] += pixels[index]
    mean = [round(value / count, 2) for value in total]
    dark = sum(1 for index in range(0, len(pixels), 3)
               if max(pixels[index], pixels[index + 1], pixels[index + 2]) > 40)
    return mean, dark


def difference(left, right):
    mismatch = 0
    worst = 0
    for index in range(0, len(left), 3):
        delta = max(abs(left[index] - right[index]),
                    abs(left[index + 1] - right[index + 1]),
                    abs(left[index + 2] - right[index + 2]))
        if delta > 8:
            mismatch += 1
        worst = max(worst, delta)
    return mismatch, worst


def main():
    gpu_width, gpu_height, gpu = read_ppm(os.path.join(ROOT, "build", "gpu-probe.ppm"))
    cpu_width, cpu_height, cpu = read_ppm(os.path.join(ROOT, "build", "cpu-probe.ppm"))
    assert (gpu_width, gpu_height) == (cpu_width, cpu_height)

    write_png(os.path.join(ROOT, "build", "gpu-probe.png"), gpu_width, gpu_height, gpu)
    write_png(os.path.join(ROOT, "build", "cpu-probe.png"), cpu_width, cpu_height, cpu)

    print("gpu mean/dark:", statistics(gpu))
    print("cpu mean/dark:", statistics(cpu))
    if len(gpu) == len(cpu):
        mismatch, worst = difference(gpu, cpu)
        print(f"pixels differing by >8: {mismatch} of {len(gpu) // 3} "
              f"({100 * mismatch / (len(gpu) // 3):.2f}%), worst channel delta {worst}")


if __name__ == "__main__":
    sys.exit(main())
