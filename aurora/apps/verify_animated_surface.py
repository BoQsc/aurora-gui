#!/usr/bin/env python3
"""Validate the primary animated AURSFACE contract."""
from __future__ import annotations

import argparse
import struct
import sys
import time
from pathlib import Path


def snapshot(path: Path) -> tuple[int, int, int, bytes]:
    data = path.read_bytes()
    if len(data) < 80 or data[:8] != b"AURSFACE":
        raise RuntimeError(f"not an AURSFACE: {path}")
    header = struct.unpack_from("<I", data, 12)[0]
    width = struct.unpack_from("<I", data, 16)[0]
    height = struct.unpack_from("<I", data, 20)[0]
    active = struct.unpack_from("<I", data, 24)[0]
    capacity = struct.unpack_from("<I", data, 28)[0]
    sequence = struct.unpack_from("<Q", data, 32)[0]
    host_read = struct.unpack_from("<Q", data, 40)[0]
    event_bytes = struct.unpack_from("<I", data, 56)[0]
    frame_bytes = struct.unpack_from("<I", data, 64)[0]
    if active not in (0, 1):
        raise RuntimeError(f"invalid active frame {active}")
    if frame_bytes != width * height * 4:
        raise RuntimeError("frame size does not match width * height * 4")
    offset = header + capacity * event_bytes + active * frame_bytes
    frame = data[offset:offset + frame_bytes]
    if len(frame) != frame_bytes:
        raise RuntimeError("truncated active frame")
    return active, sequence, host_read, frame


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--surface", required=True, type=Path)
    parser.add_argument("--interval", type=float, default=0.75)
    args = parser.parse_args()
    first = snapshot(args.surface)
    time.sleep(args.interval)
    second = snapshot(args.surface)
    changed = sum(a != b for a, b in zip(first[3], second[3]))
    print(f"active {first[0]} -> {second[0]}")
    print(f"sequence {first[1]} -> {second[1]}")
    print(f"host_read {first[2]} -> {second[2]}")
    print(f"pixels changed {changed}")
    if second[1] <= first[1]:
        raise RuntimeError("sequence did not advance")
    if second[2] <= first[2]:
        raise RuntimeError("host acknowledgement did not advance")
    if second[2] < first[1]:
        raise RuntimeError("host did not consume the previous published frame")
    if first[3] == second[3]:
        raise RuntimeError("pixels did not change")
    print("PASS animated AURSFACE")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL animated AURSFACE: {error}", file=sys.stderr)
        raise SystemExit(1)
