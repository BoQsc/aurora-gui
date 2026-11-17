#!/usr/bin/env python3
"""Measure live AURSFACE publication rate and enforce a minimum."""
from __future__ import annotations

import argparse
import struct
import sys
import time
from pathlib import Path


def counters(path: Path) -> tuple[int, int, int]:
    data = path.read_bytes()[:80]
    if len(data) < 80 or data[:8] != b"AURSFACE":
        raise RuntimeError(f"not an AURSFACE: {path}")
    sequence = struct.unpack_from("<Q", data, 32)[0]
    host_read = struct.unpack_from("<Q", data, 40)[0]
    width = struct.unpack_from("<I", data, 16)[0]
    return sequence, host_read, width


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--surface", required=True, type=Path)
    parser.add_argument("--seconds", type=float, default=1.0)
    parser.add_argument("--min-fps", type=float, default=30.0)
    args = parser.parse_args()

    before, host_before, width = counters(args.surface)
    started = time.perf_counter()
    time.sleep(args.seconds)
    after, host_after, _ = counters(args.surface)
    elapsed = time.perf_counter() - started
    frames = after - before
    fps = frames / elapsed if elapsed > 0 else 0.0
    print(f"surface width={width}")
    print(f"sequence {before} -> {after} in {elapsed:.2f}s")
    print(f"host_read {host_before} -> {host_after}")
    print(f"publication {fps:.1f} fps (minimum {args.min_fps:.1f})")
    if frames <= 0:
        raise RuntimeError("surface sequence did not advance")
    if host_after <= host_before:
        raise RuntimeError("host acknowledgement did not advance")
    if fps < args.min_fps:
        raise RuntimeError("surface publication rate is below the minimum")
    print("PASS surface frame rate")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL surface frame rate: {error}", file=sys.stderr)
        raise SystemExit(1)
