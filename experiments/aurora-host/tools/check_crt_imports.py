#!/usr/bin/env python3
"""Reject redistributable Microsoft CRT imports in an Aurora host executable."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pe_imports import PeError, read_imports  # noqa: E402

FORBIDDEN_EXACT = {"ucrtbase.dll"}
FORBIDDEN_PREFIXES = (
    "msvcr",
    "msvcp",
    "vcruntime",
    "api-ms-win-crt-",
)
REQUIRED = {"msvcrt.dll"}


def verify_crt_imports(executable: Path) -> list[str]:
    """Return policy violations; an empty list means the image is acceptable."""
    try:
        imports = read_imports(executable)
    except (OSError, PeError) as error:
        return [str(error)]

    errors: list[str] = []
    for dll in sorted(imports):
        if dll == "msvcrt.dll":
            continue
        if dll in FORBIDDEN_EXACT or dll.startswith(FORBIDDEN_PREFIXES):
            errors.append(
                f"{executable.name} imports redistributable CRT {dll}"
            )
    missing = sorted(REQUIRED - set(imports))
    if missing:
        errors.append(
            f"{executable.name} does not import the system CRT: "
            + ", ".join(missing)
        )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check that a host executable uses Windows msvcrt.dll, "
        "not a redistributable Visual C++ CRT."
    )
    parser.add_argument("executable", type=Path)
    parser.add_argument(
        "--quiet", action="store_true", help="print nothing on success"
    )
    args = parser.parse_args()
    executable = args.executable.resolve()
    errors = verify_crt_imports(executable)
    if errors:
        for error in errors:
            print(f"CRT import check failed: {error}", file=sys.stderr)
        return 1
    if not args.quiet:
        print(f"CRT imports OK: {executable.name} uses Windows msvcrt.dll")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
