# SPDX-License-Identifier: 0BSD
"""Assert that an exported TerraForest package carries the current code.

Usage: python check_export_package.py <pck> <marker> [<marker> ...]
Exits non-zero when a marker is missing, so a stale export fails the check.
"""
import mmap
import sys


def main() -> int:
    path, markers = sys.argv[1], sys.argv[2:]
    if not markers:
        print("no markers given")
        return 2
    missing = []
    with open(path, "rb") as handle:
        with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as view:
            for marker in markers:
                found = view.find(marker.encode()) >= 0
                print(f"{'PASS' if found else 'FAIL'} {marker}")
                if not found:
                    missing.append(marker)
    print(f"EXPORT_PACKAGE markers={len(markers)} missing={len(missing)}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
