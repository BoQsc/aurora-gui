#!/usr/bin/env python3
"""Verify scene-embedded ICO data updates the titlebar and live taskbar icon."""
from __future__ import annotations

import argparse
import base64
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from caption_behavior_test import window_for_pid  # noqa: E402
from host_session import Host, read_ppm  # noqa: E402
from icon_test import GCLP_HICON, ICON_BIG, icon_digest  # noqa: E402


def write_scene(path: Path, scene: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(
        json.dumps(scene, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def wait_for_digest(hwnd: int, expected: str, timeout: float = 8.0) -> str:
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        try:
            last = icon_digest(hwnd, ICON_BIG, GCLP_HICON)
        except Exception:
            time.sleep(0.1)
            continue
        if last == expected:
            return last
        time.sleep(0.1)
    raise RuntimeError(
        f"window icon did not update; expected {expected[:12]}, got {last[:12]}")


def wait_for_change(hwnd: int, previous: str, timeout: float = 8.0) -> str:
    deadline = time.monotonic() + timeout
    last = previous
    while time.monotonic() < deadline:
        try:
            last = icon_digest(hwnd, ICON_BIG, GCLP_HICON)
        except Exception:
            time.sleep(0.1)
            continue
        if last != previous:
            return last
        time.sleep(0.1)
    raise RuntimeError(
        f"window icon did not change; stayed {last[:12]}")


def first_icon_digest(hwnd: int, timeout: float = 5.0) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            return icon_digest(hwnd, ICON_BIG, GCLP_HICON)
        except Exception:
            time.sleep(0.1)
    raise RuntimeError("host window did not publish an initial icon")


def screenshot(host: Host, path: Path) -> tuple[int, int, bytes]:
    host.request("screenshot", path=str(path))
    return read_ppm(path)


def differing_pixels(a: bytes, b: bytes) -> int:
    if len(a) != len(b):
        raise RuntimeError("screenshots have different sizes")
    return sum(
        1 for offset in range(0, len(a), 3)
        if a[offset:offset + 3] != b[offset:offset + 3]
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, type=Path)
    parser.add_argument("--scene", default=ROOT / "samples" / "notepad.scene.json",
                        type=Path)
    parser.add_argument("--icon-a", default=ROOT / "assets" / "aurora-host.ico",
                        type=Path)
    parser.add_argument("--icon-b", default=ROOT / "assets" / "aurora-notepad.ico",
                        type=Path)
    args = parser.parse_args()

    base = json.loads(args.scene.read_text(encoding="utf-8"))
    sample = json.loads(
        (ROOT / "samples" / "notepad-icon.scene.json").read_text(
            encoding="utf-8"))
    try:
        embedded = base64.b64decode(sample["window"]["icon"], validate=True)
    except Exception as error:
        raise RuntimeError(
            "samples/notepad-icon.scene.json has invalid base64 icon data"
        ) from error
    if embedded != args.icon_b.read_bytes():
        raise RuntimeError(
            "samples/notepad-icon.scene.json does not embed "
            "assets/aurora-notepad.ico")
    icon_a = base64.b64encode(args.icon_a.read_bytes()).decode("ascii")
    icon_b = base64.b64encode(args.icon_b.read_bytes()).decode("ascii")
    with_a = copy.deepcopy(base)
    with_a["window"]["icon"] = icon_a
    with_b = sample

    with tempfile.TemporaryDirectory(prefix="aurora-scene-icon-") as temp_name:
        temp = Path(temp_name)
        scene_path = temp / "notepad.scene.json"
        write_scene(scene_path, with_a)
        host = Host(scene_path, args.host, watch=True)
        failure = False
        try:
            hwnd = window_for_pid(host.process.pid)
            digest_a = first_icon_digest(hwnd)
            shot_a = screenshot(host, temp / "a.ppm")

            try:
                host.request("setIcon", icon="this is not base64!")
            except RuntimeError as error:
                if "not valid base64" not in str(error):
                    raise
            else:
                raise RuntimeError("setIcon accepted invalid base64")

            response = host.request("setIcon", icon=icon_b)
            if response.get("bytes") != args.icon_b.stat().st_size:
                raise RuntimeError("setIcon reported the wrong byte count")
            digest_set_b = wait_for_change(hwnd, digest_a)
            screenshot(host, temp / "set-b.ppm")

            host.request("setIcon", icon=icon_a)
            wait_for_digest(hwnd, digest_a)

            write_scene(scene_path, with_b)
            # The watch path must notice the new scene without a control reload.
            deadline = time.monotonic() + 8.0
            digest_b = digest_a
            while digest_b == digest_a and time.monotonic() < deadline:
                time.sleep(0.1)
                try:
                    digest_b = icon_digest(hwnd, ICON_BIG, GCLP_HICON)
                except Exception:
                    pass
            if digest_b == digest_a:
                raise RuntimeError("scene watch did not refresh the taskbar icon")
            if digest_b != digest_set_b:
                raise RuntimeError(
                    "setIcon and scene watch produced different taskbar icons")
            shot_b = screenshot(host, temp / "b.ppm")
            if differing_pixels(shot_a[2], shot_b[2]) < 50:
                raise RuntimeError("scene watch did not refresh the titlebar icon")

            write_scene(scene_path, with_a)
            host.request("reload")
            digest_c = wait_for_digest(hwnd, digest_a)
            shot_c = screenshot(host, temp / "c.ppm")
            if digest_c != digest_a:
                raise RuntimeError("control reload did not restore the first icon")
            if differing_pixels(shot_b[2], shot_c[2]) < 50:
                raise RuntimeError("control reload did not refresh the titlebar icon")

            bad = copy.deepcopy(base)
            bad["window"]["icon"] = "this is not base64!"
            bad_path = temp / "bad.scene.json"
            write_scene(bad_path, bad)
            rejected = subprocess.run(
                [str(args.host), "--check", str(bad_path)],
                cwd=str(ROOT),
                capture_output=True,
                text=True,
            )
            message = rejected.stdout + rejected.stderr
            if rejected.returncode == 0 or "not valid base64" not in message:
                raise RuntimeError(
                    "invalid scene icon was not rejected with a clear error\n"
                    + message)
        except Exception:
            failure = True
            raise
        finally:
            if failure and host.errors:
                print("host stderr:", *host.errors, sep="\n", file=sys.stderr)
            host.close()

    print("scene icon test passed: watch, control reload, titlebar, and taskbar")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"scene icon test failed: {error}", file=sys.stderr)
        raise SystemExit(1)