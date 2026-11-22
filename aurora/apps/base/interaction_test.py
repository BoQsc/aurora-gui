#!/usr/bin/env python3
"""Exercise pointer, keyboard, and state through the real host control channel."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
HOST = ROOT / "aurora-host"
HOST_EXE = HOST / "aurora-host.exe"
AURORA_D = ROOT / "aurora-d" / "source"
AURORA_STANDARD = ROOT / "aurora-standard" / "source"
sys.path.insert(0, str(HOST / "tools"))
from host_session import Host  # noqa: E402


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def build_module(exe: Path) -> None:
    completed = subprocess.run(
        [
            "dmd", "-O", "-release", "-i",
            "-I" + str(AURORA_D),
            "-I" + str(AURORA_STANDARD),
            "-of=" + str(exe),
            str(PROJECT / "module.d"),
        ],
        cwd=str(PROJECT),
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=120,
    )
    require(completed.returncode == 0,
            f"module build failed:\n{completed.stdout}{completed.stderr}")


def read_state(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def wait_state(path: Path, predicate, timeout: float = 5.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = read_state(path)
        if predicate(state):
            return state
        time.sleep(0.05)
    raise RuntimeError(f"state never matched; last={read_state(path)!r}")


def click(host: Host, x: int, y: int) -> None:
    host.request("pointer", node="module", kind="down", x=x, y=y,
                 button="left")
    host.request("pointer", node="module", kind="up", x=x, y=y,
                 button="left")


def press_control(host: Host, key: str) -> None:
    host.request("key", node="module", kind="down", key=key, modifiers=2)
    host.request("key", node="module", kind="up", key=key, modifiers=2)


def main() -> int:
    require(HOST_EXE.is_file(), f"missing host: {HOST_EXE}")
    with tempfile.TemporaryDirectory(prefix="aurora-base-input-") as name:
        temp = Path(name)
        exe = temp / "base.exe"
        surface = temp / "app.surface"
        state_path = temp / "app.state.json"
        scene_path = temp / "app.scene.json"
        log_path = temp / "module.log"
        artifacts = PROJECT / "build" / "interaction"
        artifacts.mkdir(parents=True, exist_ok=True)
        activity_shot = artifacts / "activity.ppm"
        guide_shot = artifacts / "guide.ppm"

        build_module(exe)

        scene = {
            "schemaVersion": 2,
            "window": {
                "title": "Aurora Base Input Check",
                "width": 1180,
                "height": 760,
                "decorated": True,
            },
            "root": {
                "id": "module",
                "type": "surface",
                "path": str(surface),
                "width": 1180,
                "height": 760,
                "flex": 1,
                "fit": "contain",
                "background": "#080c12",
                "staleMs": 5000,
                "events": ["pointer", "key"],
            },
        }
        scene_path.write_text(json.dumps(scene, indent=2), encoding="utf-8")

        log = open(log_path, "wb")
        module = subprocess.Popen(
            [str(exe), "--surface", str(surface), "--state", str(state_path),
             "--build", "7", "--seconds", "60"],
            cwd=str(PROJECT), stdin=subprocess.DEVNULL, stdout=log,
            stderr=subprocess.STDOUT,
        )
        host = Host(scene_path, minimized=False)
        try:
            wait_state(state_path, lambda value: value.get("build") == 7,
                       timeout=10)
            for _ in range(100):
                try:
                    info = host.request("surface", node="module")
                    if info.get("mapped"):
                        break
                except Exception:
                    pass
                time.sleep(0.05)
            else:
                raise RuntimeError("surface never mapped")

            # The host launches minimized for the check; give the surface its
            # real client size before injecting widget-local pointer coordinates.
            host.request("resize", width=1180, height=760)
            time.sleep(0.2)

            click(host, 713, 355)  # Card 2: Host-owned window -> Activity
            state = wait_state(state_path, lambda value: value.get("page") == 1)
            require(state.get("navCollapsed") is False,
                    "sidebar changed before it was asked to")
            time.sleep(0.2)
            host.request("screenshot", path=str(activity_shot))

            press_control(host, "b")
            state = wait_state(state_path,
                               lambda value: value.get("navCollapsed") is True)

            press_control(host, "3")
            state = wait_state(state_path, lambda value: value.get("page") == 2)

            time.sleep(0.3)
            host.request("screenshot", path=str(guide_shot))
            for shot in (activity_shot, guide_shot):
                require(shot.is_file(), f"host produced no screenshot: {shot}")
                data = shot.read_bytes()
                require(data[:2] == b"P6",
                        f"screenshot is not a PPM: {shot}")
            print(
                "PASS Aurora Base input "
                f"page={state.get('page')} navCollapsed="
                f"{state.get('navCollapsed')} shots={artifacts}"
            )
        finally:
            try:
                host.close()
            finally:
                module.terminate()
                module.wait(timeout=5)
                log.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL Aurora Base input: {error}", file=sys.stderr)
        raise SystemExit(1)
