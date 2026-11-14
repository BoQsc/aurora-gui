#!/usr/bin/env python3
"""Add the Aurora 0BSD SPDX header to D source files when it is missing."""

from __future__ import annotations

import argparse
from pathlib import Path

HEADER = b"// SPDX-License-Identifier: 0BSD"
DEFAULT_ROOT = Path(__file__).resolve().parent / "aurora-window-widget"


def has_header(data: bytes) -> bool:
    if not data:
        return False
    return data.split(b"\n", 1)[0].rstrip(b"\r") == HEADER


def update(path: Path, check: bool) -> bool:
    data = path.read_bytes()
    if has_header(data):
        return False
    if check:
        print(f"missing: {path}")
        return True
    path.write_bytes(HEADER + b"\n" + data)
    print(f"updated: {path}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="*",
        type=Path,
        help="Directories or .d files (default: aurora-window-widget)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Report missing headers without changing files",
    )
    args = parser.parse_args()

    roots = args.paths or [DEFAULT_ROOT]
    files: list[Path] = []
    for root in roots:
        if root.is_dir():
            files.extend(sorted(root.rglob("*.d")))
        elif root.suffix == ".d":
            files.append(root)
        else:
            parser.error(f"not a directory or .d file: {root}")

    files = sorted(set(files))
    changed = sum(1 for path in files if update(path, args.check))
    verb = "would update" if args.check else "updated"
    print(f"{verb} {changed} of {len(files)} D file(s)")
    return 1 if args.check and changed else 0


if __name__ == "__main__":
    raise SystemExit(main())
