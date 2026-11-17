#!/usr/bin/env python3
"""Verify the D dev driver: good edit, failed build fallback, recovery edit."""
from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
HOST = ROOT / "aurora-host"
HOST_EXE = HOST / "aurora-host.exe"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def build(source: Path, target: Path) -> None:
    completed = subprocess.run(
        ["dmd", source.name, f"-of={target.name}"],
        cwd=str(source.parent), capture_output=True, text=True,
        encoding="utf-8")
    require(completed.returncode == 0,
            f"build failed for {source.name}: {completed.stdout}{completed.stderr}")


def main() -> int:
    require(HOST_EXE.is_file(), f"missing host: {HOST_EXE}")
    with tempfile.TemporaryDirectory(prefix="aurora-dev-driver-",
                                     ignore_cleanup_errors=True) as name:
        temp = Path(name)
        for file in ("dev.d", "runtime.d", "logic.d"):
            shutil.copyfile(PROJECT / file, temp / file)
        build(temp / "dev.d", temp / "dev.exe")
        build(temp / "runtime.d", temp / "runtime.exe")
        source = temp / "logic.d"
        original = source.read_text(encoding="utf-8")
        out = temp / "out"
        process = subprocess.Popen(
            [
                str(temp / "dev.exe"),
                "--host", str(HOST_EXE),
                "--runtime", str(temp / "runtime.exe"),
                "--source", str(source),
                "--out", str(out),
                "--watch", "30",
            ],
            cwd=str(temp), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", bufsize=1,
        )
        lines: list[str] = []
        host_pid = None
        runtime_pid = None
        stage = 0
        try:
            assert process.stdout is not None
            for line in process.stdout:
                line = line.rstrip("\n")
                lines.append(line)
                print(line, end="\n")
                if stage == 0 and "host=" in line and "runtime=" in line:
                    match = re.search(r"host=(\d+) runtime=(\d+)", line)
                    require(match is not None, "missing initial PIDs")
                    host_pid = int(match.group(1))
                    runtime_pid = int(match.group(2))
                    stage = 1
                    source.write_text(
                        original.replace("enum Revision = 1;",
                                         "enum Revision = 2;"),
                        encoding="utf-8")
                elif stage == 1 and "[2] reload signal sent" in line:
                    match = re.search(r"runtime=(\d+)", line)
                    require(match is not None, "missing reload runtime PID")
                    require(int(match.group(1)) == runtime_pid,
                            "runtime restarted on good edit")
                    stage = 2
                    source.write_text(
                        source.read_text(encoding="utf-8") +
                        "\nthis is not valid D\n",
                        encoding="utf-8")
                elif stage == 2 and "build failed" in line:
                    match = re.search(r"runtime=(\d+)", line)
                    require(match is not None, "missing failed-build runtime PID")
                    require(int(match.group(1)) == runtime_pid,
                            "runtime restarted on failed build")
                    stage = 3
                    source.write_text(
                        original.replace("enum Revision = 1;",
                                         "enum Revision = 3;"),
                        encoding="utf-8")
                elif stage == 3 and "[3] reload signal sent" in line:
                    match = re.search(r"runtime=(\d+)", line)
                    require(match is not None, "missing recovery runtime PID")
                    require(int(match.group(1)) == runtime_pid,
                            "runtime restarted on recovery edit")
                    require(int(match.group(1)) == runtime_pid,
                            "runtime PID changed")
                    stage = 4
                    break
            require(stage == 4, "dev driver did not complete the edit sequence")
            print(f"PASS D dev watch/build fallback hostPid={host_pid} "
                  f"runtimePid={runtime_pid}")
            return 0
        finally:
            subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                capture_output=True, text=True)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL D dev watch/build fallback: {error}", file=sys.stderr)
        raise SystemExit(1)
