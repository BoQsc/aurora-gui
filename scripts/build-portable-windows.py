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
    "aurora-opencode-pro": (
        Path("aurora-opencode-pro"),
        Path("aurora-opencode-pro/aurora-opencode-pro.exe"),
    ),
    "aurora-stream": (
        Path("aurora-stream"),
        Path("aurora-stream/aurora-stream.exe"),
    ),
}


def run(command: list[str], cwd: Path) -> None:
    print(f"+ ({cwd}) {' '.join(command)}", flush=True)
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, errors="replace")
    if result.stdout:
        print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr, flush=True)
    if result.returncode != 0:
        combined = (result.stderr or "") + (result.stdout or "")
        tail = combined.strip().splitlines()[-40:]
        msg = "%0A".join(line[:200] for line in tail)
        print(f"::error::command failed (exit {result.returncode}):%0A{msg}", flush=True)
        raise SystemExit(result.returncode)


def patch_icon(repo_root: Path, ico_path: Path, exe_path: Path) -> None:
    """Append a .rsrc section embedding ico_path to the linked exe (post-link,
    so any linker works — including the old lld-link 9 DMD ships)."""
    run(
        [
            sys.executable,
            "-X",
            "utf8",
            str(repo_root / "scripts/patch-pe-icon.py"),
            str(ico_path),
            str(exe_path),
        ],
        repo_root,
    )


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
    parser.add_argument(
        "--single-exe",
        action="store_true",
        help=(
            "embed the minimal ffmpeg/ffprobe into aurora-cut and "
            "aurora-stream (requires <app>/embedded/ffmpeg.exe + ffprobe.exe)"
        ),
    )
    args = parser.parse_args()

    if sys.platform != "win32":
        parser.error("portable Windows executables must be linked on Windows")

    repo_root = Path(__file__).resolve().parent.parent
    verifier = repo_root / "scripts/verify-windows-portability.py"
    selected = args.applications or list(APPLICATIONS)
    embedded_apps = {"aurora-cut", "aurora-stream"}

    run([sys.executable, "-X", "utf8", str(verifier)], repo_root)
    for name in selected:
        package_root, executable = APPLICATIONS[name]
        single_exe = args.single_exe and name in embedded_apps
        if single_exe:
            embedded = package_root / "embedded"
            for tool in ("ffmpeg.exe", "ffprobe.exe"):
                if not (embedded / tool).is_file():
                    print(
                        f"::error::missing {embedded / tool}: copy the binaries from "
                        f"the ffmpeg-minimal-win64 artifact there, or drop --single-exe",
                        flush=True,
                    )
                    raise SystemExit(1)
            ico = package_root / "assets" / f"{name}.ico"
            if not ico.is_file():
                print(f"::error::missing icon {ico}", flush=True)
                raise SystemExit(1)
        command = [
            "dub",
            "build",
            "--build=portable-single-exe" if single_exe else "--build=portable-release",
            f"--compiler={args.compiler}",
        ]
        if not args.no_force:
            command.append("--force")
        run(command, repo_root / package_root)
        if single_exe:
            patch_icon(repo_root, package_root / "assets" / f"{name}.ico",
                       repo_root / executable)
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
