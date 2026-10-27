#!/usr/bin/env python3
"""Build and launch a visible host without locking the build output.

The launcher copies the executable into a unique runtime directory and starts
that copy. Rebuilding the original executable therefore cannot fail with
"Access is denied" and cannot require killing the visible window.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
EXE_NAME = "aurora-host-experiment.exe"


def terminate_process(pid: int) -> None:
    """Terminate one replacement window after the new copy is running."""
    if sys.platform != "win32":
        os.kill(pid, 15)
        return
    import ctypes

    process_terminate = 0x0001
    handle = ctypes.windll.kernel32.OpenProcess(process_terminate, False, pid)
    if not handle:
        raise OSError(f"could not open old host process {pid}")
    try:
        if not ctypes.windll.kernel32.TerminateProcess(handle, 0):
            raise OSError(f"could not terminate old host process {pid}")
    finally:
        ctypes.windll.kernel32.CloseHandle(handle)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scene",
                        help="scene path; defaults to the notepad sample, or the "
                             "embedded starter in --dev mode")
    parser.add_argument("--dev", action="store_true",
                        help="open the host-owned scene source panel")
    parser.add_argument("--exe", type=Path,
                        help="use an already-built host instead of running dub build")
    parser.add_argument("--replace", type=int,
                        help="terminate this older host PID only after the new copy is up")
    parser.add_argument("host_args", nargs=argparse.REMAINDER,
                        help="extra host arguments after --")
    args = parser.parse_args()

    stamp = f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"
    if args.exe is None:
        build_dir = ROOT / "build" / "live" / stamp
        if build_dir.exists():
            raise RuntimeError(f"refusing to reuse live build directory: {build_dir}")
        subprocess.run(["dub", "build", f"--dest={build_dir}"],
                       cwd=ROOT, check=True)
        source_exe = build_dir / EXE_NAME
    else:
        source_exe = args.exe if args.exe.is_absolute() else ROOT / args.exe
    if not source_exe.is_file():
        raise RuntimeError(f"host executable not found: {source_exe}")

    runtime_dir = ROOT / "build" / "run" / stamp
    if runtime_dir.exists():
        raise RuntimeError(f"refusing to reuse runtime directory: {runtime_dir}")
    runtime_dir.mkdir(parents=True)
    runtime_exe = runtime_dir / EXE_NAME
    shutil.copy2(source_exe, runtime_exe)

    extra = args.host_args
    if extra and extra[0] == "--":
        extra = extra[1:]
    scene = None
    if args.scene:
        scene = Path(args.scene)
        if not scene.is_absolute():
            scene = ROOT / scene
    if args.dev:
        command = [str(runtime_exe), "--dev"]
        if scene is not None:
            command.append(str(scene))
        command.extend(extra)
    else:
        if scene is None:
            scene = ROOT / "samples" / "notepad.scene.json"
        command = [str(runtime_exe), "--run", str(scene), "--watch", *extra]
    process = subprocess.Popen(command, cwd=ROOT)
    time.sleep(1.0)
    if process.poll() is not None:
        raise RuntimeError(f"host exited during launch with code {process.returncode}")

    if args.replace is not None and args.replace != process.pid:
        time.sleep(0.5)
        terminate_process(args.replace)

    print(f"RUNNING pid={process.pid}")
    print(f"runtime={runtime_exe}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"live host launch failed: {error}", file=sys.stderr)
        raise SystemExit(1)
