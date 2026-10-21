#!/usr/bin/env python3
"""Enforce the Aurora package manifest policy and report vendor package paths."""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {".git", ".dub", "build", "build-validation", "__pycache__"}
def main() -> int:
    errors: list[str] = []
    vendor: list[str] = []

    required = [ROOT / "LICENSE", ROOT / "LICENSE-CC0.txt", ROOT / "LICENSING.md"]
    for path in required:
        if not path.is_file():
            errors.append(f"missing licensing file: {path.relative_to(ROOT)}")

    license_text = (ROOT / "LICENSE").read_text(encoding="utf-8")
    if "BSD Zero Clause License" not in license_text:
        errors.append("LICENSE does not identify the BSD Zero Clause License")
    cc0_text = (ROOT / "LICENSE-CC0.txt").read_text(encoding="utf-8")
    if "CC0 1.0 Universal" not in cc0_text:
        errors.append("LICENSE-CC0.txt does not contain the CC0 1.0 text")
    for vendor_license in sorted((ROOT / "vendor").glob("*/LICENSE")):
        text = vendor_license.read_text(encoding="utf-8")
        if "BSD Zero Clause License" not in text:
            errors.append(f"{vendor_license.relative_to(ROOT)} does not identify 0BSD")

    for path in sorted(ROOT.rglob("dub.json")):
        if any(part in EXCLUDED for part in path.parts):
            continue
        relative = path.relative_to(ROOT)
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            errors.append(f"{relative}: invalid manifest: {error}")
            continue

        license_id = data.get("license", "")
        if license_id != "0BSD":
            errors.append(f"{relative}: license is {license_id!r}, expected '0BSD'")
        metadata = json.dumps(
            {"authors": data.get("authors"), "copyright": data.get("copyright")},
            ensure_ascii=False,
        )
        if "OpenAI" in metadata:
            errors.append(f"{relative}: metadata still names OpenAI")
        if relative.parts[0] == "vendor":
            vendor.append(f"{relative}: {license_id}")

    for message in vendor:
        print(f"vendor package: {message}")

    if errors:
        for message in errors:
            print(f"license error: {message}", file=sys.stderr)
        return 1

    print("license policy passed: all Aurora package manifests are 0BSD")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
