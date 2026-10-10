#!/usr/bin/env python3
"""Build and validate Aurora RustDesk using the repository's Windows D toolchain."""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parent
VALIDATION = ROOT / "build-validation"


def run(command: list[str]) -> None:
    print("+", " ".join(command), flush=True)
    result = subprocess.run(command, cwd=ROOT)
    if result.returncode:
        raise SystemExit(result.returncode)


def dmd() -> str:
    compiler = shutil.which("dmd")
    if not compiler:
        raise SystemExit("dmd was not found on PATH")
    return compiler


def build(release: bool) -> None:
    command = ["dub", "build", "--compiler=dmd", "--force"]
    if release:
        command.append("--build=release")
    run(command)


def tests() -> None:
    VALIDATION.mkdir(exist_ok=True)
    compiler = dmd()
    include = ["-Isource", "-I../vendor/aurora-d-0.4.5/source"]
    libraries = [
        "bcrypt.lib",
        "crypt32.lib",
        "user32.lib",
        "gdi32.lib",
        "ws2_32.lib",
    ]
    run(
        [
            compiler,
            "-unittest",
            "-main",
            *include,
            "tests/core_smoke.d",
            "source/aurorarustdesk/crypto.d",
            "source/aurorarustdesk/identity.d",
            "source/aurorarustdesk/protocol.d",
            "source/aurorarustdesk/framecodec.d",
            *libraries,
            f"-of={VALIDATION / 'core-smoke.exe'}",
            f"-od={VALIDATION}",
        ]
    )
    run([str(VALIDATION / "core-smoke.exe")])
    for name in ["rendezvous", "session", "transfer", "process"]:
        run(
            [
                compiler,
                "-i",
                *include,
                f"tests/{name}_smoke.d",
                *libraries,
                f"-of={VALIDATION / (name + '-smoke.exe')}",
                f"-od={VALIDATION}",
            ]
        )
        run([str(VALIDATION / (name + "-smoke.exe"))])
    run(
        [
            compiler,
            "-unittest",
            "-main",
            "-version=AuroraHeadless",
            "-i",
            *include,
            "tests/ui_flow_smoke.d",
            *libraries,
            f"-of={VALIDATION / 'ui-flow-smoke.exe'}",
            f"-od={VALIDATION}",
        ]
    )
    run([str(VALIDATION / "ui-flow-smoke.exe")])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--test", action="store_true")
    args = parser.parse_args()
    build(args.release)
    if args.test:
        tests()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
