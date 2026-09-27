#!/usr/bin/env python3
"""Build and validate Aurora Remote using the repository's Windows D toolchain."""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import subprocess
import sys


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
            *include,
            "tests/core_smoke.d",
            "source/auroraremote/crypto.d",
            "source/auroraremote/capsule.d",
            "source/auroraremote/protocol.d",
            "source/auroraremote/framecodec.d",
            *libraries,
            f"-of={VALIDATION / 'core-smoke.exe'}",
            f"-od={VALIDATION}",
        ]
    )
    run([str(VALIDATION / "core-smoke.exe")])
    run(
        [
            compiler,
            "-i",
            *include,
            "tests/direct_smoke.d",
            *libraries,
            f"-of={VALIDATION / 'direct-smoke.exe'}",
            f"-od={VALIDATION}",
        ]
    )
    run([str(VALIDATION / "direct-smoke.exe")])
    run(
        [
            compiler,
            "-i",
            *include,
            "tests/process_smoke.d",
            *libraries,
            f"-of={VALIDATION / 'process-smoke.exe'}",
            f"-od={VALIDATION}",
        ]
    )
    run([str(VALIDATION / "process-smoke.exe")])
    run(
        [
            compiler,
            "-i",
            *include,
            "tests/relay_smoke.d",
            *libraries,
            f"-of={VALIDATION / 'relay-smoke.exe'}",
            f"-od={VALIDATION}",
        ]
    )
    run([str(VALIDATION / "relay-smoke.exe")])
    run(
        [
            compiler,
            "-i",
            *include,
            "tests/transfer_smoke.d",
            *libraries,
            f"-of={VALIDATION / 'transfer-smoke.exe'}",
            f"-od={VALIDATION}",
        ]
    )
    run([str(VALIDATION / "transfer-smoke.exe")])
    run(
        [
            compiler,
            "-i",
            *include,
            "tests/clipboard_smoke.d",
            *libraries,
            f"-of={VALIDATION / 'clipboard-smoke.exe'}",
            f"-od={VALIDATION}",
        ]
    )
    run([str(VALIDATION / "clipboard-smoke.exe")])
    run(
        [
            compiler,
            "-i",
            *include,
            "tests/unattended_smoke.d",
            *libraries,
            f"-of={VALIDATION / 'unattended-smoke.exe'}",
            f"-od={VALIDATION}",
        ]
    )
    run([str(VALIDATION / "unattended-smoke.exe")])
    run(
        [
            compiler,
            "-i",
            *include,
            "tests/peers_smoke.d",
            *libraries,
            f"-of={VALIDATION / 'peers-smoke.exe'}",
            f"-od={VALIDATION}",
        ]
    )
    run([str(VALIDATION / "peers-smoke.exe")])
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
