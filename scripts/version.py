#!/usr/bin/env python3
"""Single-source version management for Aurora programs.

The DUB manifest (`dub.json`) is the ONLY manual version number. This tool
regenerates the derived `VERSION.txt` and `source/.../appversion.d` modules so
the runtime `--version` output, title bars, and logs can never drift from the
manifest.

Usage:
  python scripts/version.py sync [--program aurora-cut|aurora-stream] [--release]
  python scripts/version.py check [--program ...]
  python scripts/version.py bump 0.60.0 [--program ...]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

PROGRAMS = {
    # name -> (repo-relative dub.json, repo-relative VERSION.txt, repo-relative appversion.d, appName)
    "aurora-cut": (
        "dub.json",
        "VERSION.txt",
        "source/auroracut/appversion.d",
        "Aurora Cut",
    ),
    "aurora-stream": (
        "aurora-stream/dub.json",
        "aurora-stream/VERSION.txt",
        "aurora-stream/source/aurorastream/appversion.d",
        "Aurora Stream",
    ),
}


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def read_version(recipe_path: Path) -> str:
    recipe = json.loads(recipe_path.read_text(encoding="utf-8"))
    version = recipe.get("version")
    if not version:
        raise SystemExit(f"{recipe_path}: missing version field")
    return str(version)


def git_short_head(repo: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(repo),
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def appversion_source(app_name: str, version: str, build_id: str) -> str:
    if build_id and build_id != "dev":
        build = f'"{build_id}"'
    else:
        build = '"dev"'
    return (
        "module " + app_name.lower().replace(" ", "") + ".appversion;\n"
        "\n"
        "/** Public application identity used by the title bar, logs, and CLI.\n"
        " * Regenerated from dub.json by scripts/version.py; do not edit. */\n"
        f'enum appName = "{app_name}";\n'
        f'enum appVersion = "{version}";\n'
        f'enum appBuildId = {build};\n'
        'enum appDisplayName = appName ~ " " ~ appVersion;\n'
        'enum appFullVersion = appDisplayName ~ " (build " ~ appBuildId ~ ")";\n'
    )


def sync_program(repo: Path, name: str, release: bool) -> bool:
    recipe_rel, version_rel, appversion_rel, app_name = PROGRAMS[name]
    recipe_path = repo / recipe_rel
    version = read_version(recipe_path)
    build_id = "dev" if not release else git_short_head(repo)

    version_path = repo / version_rel
    appversion_path = repo / appversion_rel

    new_version_text = version + "\n"
    new_appversion = appversion_source(app_name, version, build_id)

    changed = False
    if version_path.read_text(encoding="utf-8") != new_version_text:
        version_path.write_text(new_version_text, encoding="utf-8")
        changed = True
    if appversion_path.read_text(encoding="utf-8") != new_appversion:
        appversion_path.write_text(new_appversion, encoding="utf-8")
        changed = True

    if changed:
        print(f"{name}: synced to {version} (build {build_id})")
    else:
        print(f"{name}: already at {version} (build {build_id})")
    return True


def check_program(repo: Path, name: str) -> bool:
    recipe_rel, version_rel, appversion_rel, app_name = PROGRAMS[name]
    recipe_path = repo / recipe_rel
    version = read_version(recipe_path)

    version_path = repo / version_rel
    appversion_path = repo / appversion_rel

    failures: list[str] = []
    if version_path.read_text(encoding="utf-8").strip() != version:
        failures.append(f"{name}: {version_rel} is out of sync with dub.json")
    expected_appversion = appversion_source(app_name, version, "dev")
    if appversion_path.read_text(encoding="utf-8") != expected_appversion:
        failures.append(f"{name}: {appversion_rel} is out of sync with dub.json")
    if failures:
        print("ERROR: " + "; ".join(failures), file=sys.stderr)
        return False
    print(f"{name}: version {version} in sync")
    return True


def bump_program(repo: Path, name: str, new_version: str) -> bool:
    recipe_rel, _, _, _ = PROGRAMS[name]
    recipe_path = repo / recipe_rel
    recipe = json.loads(recipe_path.read_text(encoding="utf-8"))
    recipe["version"] = new_version
    recipe_path.write_text(
        json.dumps(recipe, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"{name}: bumped dub.json version to {new_version}")
    sync_program(repo, name, False)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=["sync", "check", "bump"],
        help="sync regenerates VERSION.txt + appversion.d; check verifies them",
    )
    parser.add_argument("version", nargs="?", help="new version for `bump`")
    parser.add_argument(
        "--program",
        choices=sorted(PROGRAMS),
        default=None,
        help="restrict to one program (default: all)",
    )
    parser.add_argument(
        "--release",
        action="store_true",
        help="bake the current git short hash as the build id",
    )
    args = parser.parse_args()

    repo = repo_root()
    programs = [args.program] if args.program else sorted(PROGRAMS)
    ok = True
    for name in programs:
        if args.command == "sync":
            sync_program(repo, name, args.release)
        elif args.command == "check":
            ok = check_program(repo, name) and ok
        elif args.command == "bump":
            if not args.version:
                print("ERROR: `bump` requires a version argument", file=sys.stderr)
                return 2
            bump_program(repo, name, args.version)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
