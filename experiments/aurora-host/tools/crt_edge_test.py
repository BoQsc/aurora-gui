#!/usr/bin/env python3
"""Exercise Unicode, locale, environment, and unusual-path CRT behavior."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
DEFAULT_HOST = ROOT / "build" / "verify" / "aurora-host-experiment.exe"
PROBE_SOURCE = ROOT / "tests" / "crt_probe.d"

sys.path.insert(0, str(ROOT / "tools"))
from check_crt_imports import verify_crt_imports  # noqa: E402


class EdgeError(Exception):
    pass


def run(command: list[str], *, cwd: Path = ROOT,
        env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=cwd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
        timeout=180,
    )
    if completed.returncode != 0:
        raise EdgeError(
            "command failed: " + " ".join(str(part) for part in command)
            + f"\nexit {completed.returncode}\n"
            + completed.stdout + completed.stderr
        )
    return completed


def verify_ppm(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    match = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", data)
    if not match:
        raise EdgeError(f"render output is not a P6 PPM: {path}")
    width, height, maximum = (int(value) for value in match.groups())
    if maximum != 255 or len(data) <= match.end():
        raise EdgeError(f"render output has invalid pixels: {path}")
    return width, height


def build_probe(dmd: str, temporary: Path) -> Path:
    probe = temporary / "crt-probe.exe"
    objects = temporary / "probe-obj"
    objects.mkdir()
    command = [
        dmd,
        "-mscrtlib=msvcrt",
        "-O",
        "-release",
        "-i",
        f"-I{ROOT / 'source'}",
        f"-I{ROOT / 'generated'}",
        f"-od={objects}",
        f"-of={probe}",
        str(PROBE_SOURCE),
    ]
    run(command)
    if not probe.is_file():
        raise EdgeError("CRT probe executable was not produced")
    errors = verify_crt_imports(probe)
    if errors:
        raise EdgeError("CRT probe imports are invalid:\n" + "\n".join(errors))
    return probe


def edge_scene(path: Path) -> None:
    scene = json.loads((ROOT / "samples" / "hello.scene.json").read_text(
        encoding="utf-8"
    ))
    scene["window"]["title"] = "Grüße — Ω ✓"
    for child in scene["root"]["children"]:
        if child.get("id") == "heading":
            child["text"] = "Grüße — Ω ✓"
        elif child.get("id") == "subtitle":
            child["text"] = "İstanbul · 世界 · café"
        elif child.get("type") == "row":
            for item in child["children"]:
                if item.get("id") == "hello":
                    item["text"] = "Привет"
    path.write_text(
        json.dumps(scene, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", type=Path, default=DEFAULT_HOST)
    parser.add_argument("--dmd", default="dmd")
    args = parser.parse_args()
    host = args.host.resolve()
    if not host.is_file():
        raise EdgeError(f"missing host executable: {host}")
    errors = verify_crt_imports(host)
    if errors:
        raise EdgeError("host CRT imports are invalid:\n" + "\n".join(errors))

    with tempfile.TemporaryDirectory(prefix="aurora crt edge ") as temporary:
        temporary_root = Path(temporary)
        unusual = temporary_root / "ünicode 空 格 (100%) #1"
        unusual.mkdir()
        scene = unusual / "café — Ω ✓.scene.json"
        edge_scene(scene)

        checked = run([str(host), "--check", str(scene)])
        if "scene OK:" not in checked.stdout:
            raise EdgeError("Unicode scene check did not succeed")

        output = unusual / "rèndu — ✓.ppm"
        run([str(host), "--render", str(scene), "--out", str(output)])
        width, height = verify_ppm(output)
        if width <= 0 or height <= 0:
            raise EdgeError("Unicode scene render has invalid dimensions")

        locale_env = os.environ.copy()
        locale_env["LANG"] = "tr_TR.UTF-8"
        locale_env["LC_ALL"] = "tr_TR.UTF-8"
        version = run([str(host), "--version"], env=locale_env)
        if "aurora-host-experiment" not in version.stdout:
            raise EdgeError("locale host version check did not succeed")

        unicode_value = "Grüße 世界 ✓"
        probe_env = locale_env.copy()
        probe_env["AURORA_CRT_UNICODE"] = unicode_value
        probe = build_probe(args.dmd, temporary_root)
        probe_result = run([str(probe), unicode_value], env=probe_env)
        if "CRT probe passed" not in probe_result.stdout:
            raise EdgeError("CRT probe did not report success")

    print("CRT edge test passed: Unicode argv/environment, locale, time, "
          "and unusual scene paths")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (EdgeError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"CRT edge test failed: {error}", file=sys.stderr)
        raise SystemExit(1)
