#!/usr/bin/env python3
"""Prove the CRT guard rejects a redistributable CRT and accepts the host."""
from __future__ import annotations

import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from check_crt_imports import verify_crt_imports  # noqa: E402


class TestFailure(Exception):
    pass


def run(command: list[str]) -> None:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        errors="replace",
    )
    if completed.returncode != 0:
        raise TestFailure(
            "command failed: "
            + " ".join(command)
            + "\nstdout:\n"
            + completed.stdout
            + "\nstderr:\n"
            + completed.stderr
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=pathlib.Path, required=True)
    parser.add_argument("--dmd", default="dmd")
    args = parser.parse_args()

    dmd = shutil.which(args.dmd) or args.dmd
    host = args.host.resolve()
    if not host.is_file():
        print(f"CRT guard test failed: host not found: {host}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="aurora-crt-guard-") as temp_name:
        negative = pathlib.Path(temp_name) / "msvcr120-probe.exe"
        run(
            [
                dmd,
                f"-I{ROOT / 'source'}",
                "-i",
                "-mscrtlib=msvcrt120",
                f"-of={negative}",
                str(ROOT / "tests" / "crt_probe.d"),
            ]
        )
        negative_errors = verify_crt_imports(negative)
        if not any("msvcr120.dll" in error for error in negative_errors):
            raise TestFailure(
                "guard did not reject the MSVCR120-linked probe:\n"
                + "\n".join(negative_errors)
            )

    host_errors = verify_crt_imports(host)
    if host_errors:
        raise TestFailure(
            "guard rejected the current host:\n" + "\n".join(host_errors)
        )

    print("CRT guard test passed: MSVCR120 rejected, system msvcrt host accepted")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except TestFailure as error:
        print(f"CRT guard test failed: {error}", file=sys.stderr)
        raise SystemExit(1)