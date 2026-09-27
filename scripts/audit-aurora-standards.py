#!/usr/bin/env python3
"""Audit the repository-wide Aurora behavior contract.

This deliberately uses only the Python standard library.  It is a fast source
check, not a replacement for DUB builds or the headless UI regressions.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
CORE_SOURCE = ROOT / "vendor" / "aurora-d-0.4.5" / "source"


@dataclass(frozen=True)
class Finding:
    code: str
    message: str
    path: str = ""
    line: int = 0


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def line_of(text: str, needle: str) -> int:
    offset = text.find(needle)
    return 0 if offset < 0 else text.count("\n", 0, offset) + 1


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def discover_packages(errors: list[Finding]) -> list[dict[str, object]]:
    packages: list[dict[str, object]] = []
    canonical = CORE_SOURCE.resolve()
    for manifest in sorted(ROOT.glob("aurora-*/dub.json")):
        try:
            data = json.loads(read(manifest))
        except (OSError, json.JSONDecodeError) as error:
            errors.append(Finding(
                "invalid-manifest", str(error), relative(manifest)))
            continue

        source_paths = data.get("sourcePaths", [])
        resolved = []
        for raw in source_paths:
            normalized = str(raw).replace("\\", "/")
            resolved.append((manifest.parent / normalized).resolve())
        uses_core = canonical in resolved
        stale_core_paths = [
            str(raw) for raw in source_paths
            if "aurora-d-" in str(raw) and
            (manifest.parent / str(raw).replace("\\", "/")).resolve() != canonical
        ]
        if stale_core_paths:
            errors.append(Finding(
                "stale-core-path",
                "package references a different Aurora-D source: " +
                ", ".join(stale_core_paths),
                relative(manifest)))
        if not uses_core:
            errors.append(Finding(
                "missing-core-path",
                "package does not compile the repository's canonical Aurora-D source",
                relative(manifest)))
        packages.append({
            "name": data.get("name", manifest.parent.name),
            "manifest": relative(manifest),
            "uses_canonical_core": uses_core,
        })
    if not packages:
        errors.append(Finding(
            "no-packages", "no aurora-*/dub.json packages were discovered"))
    return packages


def verify_core_contracts(errors: list[Finding]) -> list[str]:
    contracts = {
        "sharp font rasterization is the window default": (
            CORE_SOURCE / "aurora" / "platform" / "base.d",
            "FontRenderMode fontRenderMode = FontRenderMode.sharp;",
        ),
        "native-weight grayscale contrast is the atlas default": (
            CORE_SOURCE / "aurora" / "text" / "atlas.d",
            'environment.get("AURORA_TEXT_CONTRAST", "0.5")',
        ),
        "invalid frame deltas are sanitized before widget ticks": (
            CORE_SOURCE / "aurora" / "window.d",
            "deltaSeconds != deltaSeconds || deltaSeconds < 0.0",
        ),
        "font contrast override is documented": (
            ROOT / "vendor" / "aurora-d-0.4.5" / "docs" / "FONTS.md",
            "AURORA_TEXT_CONTRAST=0",
        ),
        "frameless window shell orchestration is framework-owned": (
            CORE_SOURCE / "aurora" / "widgets" / "titlebar.d",
            "class FramelessWindowTitleBar : TitleBar",
        ),
    }
    verified: list[str] = []
    for name, (path, needle) in contracts.items():
        try:
            text = read(path)
        except OSError as error:
            errors.append(Finding("missing-contract-file", str(error), relative(path)))
            continue
        if needle not in text:
            errors.append(Finding(
                "missing-core-contract", name, relative(path)))
            continue
        verified.append(name)
    return verified


def downstream_debt(errors: list[Finding]) -> list[Finding]:
    """Return grandfathered downstream policy copies and reject new ones.

    Keeping the small allowlist here makes the audit a ratchet: current debt is
    visible, while a newly copied policy fails CI until it is either promoted
    to Aurora or deliberately reviewed here.
    """
    allowed: set[str] = set()
    policies = [
        (
            "downstream-render-policy",
            "font rendering policy is duplicated below Aurora-D",
            re.compile(
                r'environment\s*\[\s*"AURORA_(?:TEXT_CONTRAST|FONT_RENDER_MODE|HINTING)"'
                r"|\benableNativeTextRendering\b"
            ),
        ),
        (
            "downstream-window-shell-policy",
            "frameless window-shell orchestration is duplicated below Aurora-D",
            re.compile(
                r"\brestoreFromDrag\b|\b_dragStartWindowOrigin\b"
                r"|onSnapApplied\s*=\s*&applySnap"
            ),
        ),
    ]
    found: list[Finding] = []
    for source_root in sorted(ROOT.glob("aurora-*/source")):
        for path in sorted(source_root.rglob("*.d")):
            text = read(path)
            for code, message, pattern in policies:
                match = pattern.search(text)
                if match is None:
                    continue
                item = Finding(
                    code,
                    message,
                    relative(path),
                    text.count("\n", 0, match.start()) + 1,
                )
                if item.path not in allowed:
                    errors.append(item)
                else:
                    found.append(item)
    return found


def promotion_candidates() -> list[dict[str, object]]:
    candidates: list[dict[str, object]] = []
    for candidate in candidates:
        candidate["present_paths"] = [
            path for path in candidate["paths"] if (ROOT / path).is_file()
        ]
    return candidates


def audit() -> dict[str, object]:
    errors: list[Finding] = []
    packages = discover_packages(errors)
    contracts = verify_core_contracts(errors)
    debt = downstream_debt(errors)
    return {
        "packages": packages,
        "contracts": contracts,
        "debt": [asdict(item) for item in debt],
        "promotion_candidates": promotion_candidates(),
        "errors": [asdict(item) for item in errors],
    }


def print_human(result: dict[str, object]) -> None:
    packages = result["packages"]
    contracts = result["contracts"]
    debt = result["debt"]
    candidates = result["promotion_candidates"]
    errors = result["errors"]
    print(f"Aurora standards: {len(packages)} packages use one core source")
    print(f"Core contracts verified: {len(contracts)}")
    for item in debt:
        location = f"{item['path']}:{item['line']}"
        print(f"DEBT {item['code']} {location} - {item['message']}")
    for candidate in candidates:
        print(
            f"CANDIDATE {candidate['id']} -> {candidate['owner']} "
            f"({len(candidate['present_paths'])} locations; "
            f"{candidate['approval']})"
        )
    for item in errors:
        location = item["path"]
        if item["line"]:
            location += f":{item['line']}"
        suffix = f" {location}" if location else ""
        print(f"ERROR {item['code']}{suffix} - {item['message']}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit machine-readable output")
    parser.add_argument(
        "--fail-on-debt", action="store_true",
        help="also fail for grandfathered downstream policy copies",
    )
    args = parser.parse_args()
    result = audit()
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print_human(result)
    return 1 if result["errors"] or (args.fail_on_debt and result["debt"]) else 0


if __name__ == "__main__":
    raise SystemExit(main())
