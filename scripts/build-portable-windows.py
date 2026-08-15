#!/usr/bin/env python3
"""Build and verify the distributable Windows Aurora executables."""

from __future__ import annotations

import argparse
import shutil
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


def build_game_capture_hook(repo_root: Path, compiler: str) -> None:
    """Build the D-only injectable hook before embedding the stream exe.

    The hook deliberately uses betterC/custom entry-point linking because it is
    loaded into a foreign process. It is staged only for --single-exe builds;
    normal development builds continue to use a separately built DLL.
    """
    stream_root = repo_root / "aurora-stream"
    embedded = stream_root / "embedded"
    output = embedded / "gamecaphook.dll"
    resolved = shutil.which(compiler) or compiler
    compiler_path = Path(resolved)
    if compiler_path.exists():
        compiler_path = compiler_path.resolve()
    libdir_candidates = []
    if compiler_path.exists():
        # DMD's Windows layout is <dmd>/windows/bin/dmd.exe and its MinGW
        # import libraries are in <dmd>/windows/lib64/mingw.
        libdir_candidates.append(compiler_path.parent.parent / "lib64" / "mingw")
    libdir_candidates.append(Path(r"C:\D\dmd2\windows\lib64\mingw"))
    libdir = next((candidate for candidate in libdir_candidates if candidate.is_dir()), None)

    command = [
        compiler,
        "-m64",
        "-shared",
        "-betterC",
        "-O",
        "-release",
        "-inline",
        "-boundscheck=off",
        "gamecaphook.d",
        "source/aurorastream/d3d11.d",
        "-Isource",
        "-I../vendor/aurora-d-0.4.5/source",
        f"-of={output}",
        "-L/NODEFAULTLIB",
        "-L/ENTRY:gamecaphookEntry",
        "-L/OPT:REF",
        "-L/OPT:ICF",
    ]
    for library in ("kernel32.lib", "user32.lib", "gdi32.lib", "ucrtbase.lib"):
        command.append(f"-L{libdir / library if libdir else library}")
    run(command, stream_root)
    if not output.is_file():
        print(f"::error::hook compiler did not produce {output}", flush=True)
        raise SystemExit(1)


def verify_stream_ffmpeg_inventory(ffmpeg: Path) -> None:
    """Refuse a release payload that lacks Aurora Stream's capture filters.

    ddagrab is an FFmpeg source filter, not an input device. A former minimal
    build enabled it under --enable-indev, which configured successfully but
    silently shipped an executable without Desktop Duplication support.
    """
    checks = [
        (
            [str(ffmpeg), "-hide_banner", "-filters"],
            ("ddagrab", "gfxcapture", "hwdownload"),
        ),
        (
            [str(ffmpeg), "-hide_banner", "-h", "filter=gfxcapture"],
            ("pre-existing HWND handle", "display yellow border"),
        ),
        ([str(ffmpeg), "-hide_banner", "-devices"], ("gdigrab", "dshow", "lavfi")),
    ]
    for command, required in checks:
        result = subprocess.run(
            command,
            cwd=ffmpeg.parent,
            capture_output=True,
            text=True,
            errors="replace",
        )
        output = (result.stdout or "") + (result.stderr or "")
        missing = [name for name in required if name not in output]
        if result.returncode != 0 or missing:
            details = ", ".join(missing) if missing else f"exit {result.returncode}"
            print(
                f"::error::{ffmpeg} is not release-ready; missing FFmpeg "
                f"capabilities: {details}",
                flush=True,
            )
            raise SystemExit(1)
    print(f"Aurora Stream FFmpeg capture inventory passed: {ffmpeg}", flush=True)


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
            "aurora-stream (requires <app>/embedded/ffmpeg.exe + ffprobe.exe; "
            "aurora-stream also builds/embeds gamecaphook.dll with DMD)"
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
            if name == "aurora-stream":
                verify_stream_ffmpeg_inventory(embedded / "ffmpeg.exe")
                build_game_capture_hook(repo_root, args.compiler)
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
