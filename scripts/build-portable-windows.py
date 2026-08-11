#!/usr/bin/env python3
"""Build and verify the distributable Windows Aurora executables."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


APPLICATIONS = {
    "aurora-cut": (Path("."), Path("aurora-cut.exe")),
    "aurora-image-viewer": (
        Path("aurora-image-viewer"),
        Path("aurora-image-viewer/aurora-image-viewer.exe"),
    ),
    "aurora-opencode": (
        Path("aurora-opencode"),
        Path("aurora-opencode/aurora-opencode.exe"),
    ),
    "aurora-stream": (
        Path("aurora-stream"),
        Path("aurora-stream/aurora-stream.exe"),
    ),
}


def run(command: list[str], cwd: Path) -> None:
    print(f"+ ({cwd}) {' '.join(command)}", flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build Aurora's statically linked portable Windows executables."
    )
    parser.add_argument(
        "--compiler",
        default="dmd",
        help="DUB compiler executable or compiler name (default: dmd)",
    )
    parser.add_argument(
        "--app",
        action="append",
        choices=sorted(APPLICATIONS),
        dest="applications",
        help="build only this application; may be repeated",
    )
    parser.add_argument(
        "--no-force",
        action="store_true",
        help="allow DUB to reuse an existing build instead of forcing a relink",
    )
    args = parser.parse_args()

    if sys.platform != "win32":
        parser.error("portable Windows executables must be linked on Windows")

    repo_root = Path(__file__).resolve().parent.parent
    verifier = repo_root / "scripts/verify-windows-portability.py"
    selected = args.applications or list(APPLICATIONS)

    run([sys.executable, "-X", "utf8", str(verifier)], repo_root)
    for name in selected:
        package_root, executable = APPLICATIONS[name]
        command = [
            "dub",
            "build",
            "--build=portable-release",
            f"--compiler={args.compiler}",
        ]
        if not args.no_force:
            command.append("--force")
        run(command, repo_root / package_root)
        run(
            [
                sys.executable,
                "-X",
                "utf8",
                str(verifier),
                "--skip-manifests",
                str(repo_root / executable),
            ],
            repo_root,
        )

    print("All requested portable Windows executables passed PE import checks.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
