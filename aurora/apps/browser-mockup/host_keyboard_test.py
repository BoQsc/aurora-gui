#!/usr/bin/env python3
"""Verify address typing through aurora-host's real scene/input path.

This starts the host as a separate process with a 960x640 surface node that opts
into pointer and key events, then uses the host control `key` command. The host
writes the events into the same shared-surface ring used by physical keyboard
input. It does not call the app's key handler directly.
"""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parent
AURORA = PROJECT.parents[1]
HOST_DIR = AURORA / "aurora-host"
AURORA_D = AURORA / "aurora-d" / "source"
AURORA_STANDARD = AURORA / "aurora-standard" / "source"
SOURCE = PROJECT / "module.d"
sys.path.insert(0, str(HOST_DIR / "tools"))
from host_session import Host, read_ppm  # noqa: E402
sys.path.insert(0, str(PROJECT))
from interaction_test import wait_ready  # noqa: E402

APP_WIDTH = 960
APP_HEIGHT = 640
WINDOW_WIDTH = 1200
WINDOW_HEIGHT = 900
CONTROL = 2


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def wait_mapped(host: Host, timeout: float = 8.0) -> dict:
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = host.request("surface", node="browser")
        if last.get("mapped") and last.get("sequence", 0) > 0:
            return last
        time.sleep(0.05)
    raise RuntimeError(f"surface did not map in host: {last!r}")


def key(host: Host, name: str, modifiers: int = 0) -> None:
    host.request("key", node="browser", kind="down", key=name,
                 modifiers=modifiers)
    host.request("key", node="browser", kind="up", key=name,
                 modifiers=modifiers)
    time.sleep(0.02)


def type_text(host: Host, value: str) -> None:
    for character in value:
        if character == " ":
            key(host, "space")
        elif "a" <= character <= "z":
            key(host, character)
        else:
            raise RuntimeError(f"test cannot type {character!r}")


def wait_page(state_path: Path, page: int, query: str | None = None,
              timeout: float = 6.0) -> dict:
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = json.loads(state_path.read_text(encoding="utf-8"))
            tab = last["tabs"][last["activeTab"]]
            if tab["page"] == page and (query is None or tab.get("query") == query):
                return last
        except (OSError, json.JSONDecodeError, KeyError):
            pass
        time.sleep(0.04)
    raise RuntimeError(f"state did not reach page {page}: {last!r}")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="aurora-host-keyboard-") as name:
        work = Path(name)
        executable = work / "browser-mockup.exe"
        surface = work / "browser.surface"
        state = work / "browser.state.json"
        scene = work / "browser.scene.json"
        shot = PROJECT / "build" / "browser-mockup" / "host-resized.ppm"
        shot.parent.mkdir(parents=True, exist_ok=True)

        built = subprocess.run(
            ["dmd", "-O", "-release", "-i",
             f"-I{AURORA_D}", f"-I{AURORA_STANDARD}",
             f"-of={executable}", str(SOURCE)],
            capture_output=True, text=True, encoding="utf-8", timeout=120,
        )
        require(built.returncode == 0,
                f"module build failed:\n{built.stdout}{built.stderr}")

        scene.write_text(json.dumps({
            "schemaVersion": 2,
            "window": {
                "title": "Aurora Browser Mockup — Keyboard Host",
                "width": APP_WIDTH,
                "height": APP_HEIGHT,
                "theme": "dark",
            },
            "root": {
                "id": "browser",
                "type": "surface",
                "path": str(surface),
                "width": APP_WIDTH,
                "height": APP_HEIGHT,
                "flex": 1,
                "fit": "contain",
                "background": "#080c12",
                "staleMs": 1500,
                "events": ["pointer", "key"],
            },
        }), encoding="utf-8")

        module = subprocess.Popen(
            [str(executable), "--surface", str(surface), "--state", str(state),
             "--seconds", "30"],
            cwd=str(work), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        host: Host | None = None
        try:
            wait_ready(state, surface)
            host = Host(scene)
            mapped = wait_mapped(host)
            require(mapped["pixelWidth"] == APP_WIDTH and
                    mapped["pixelHeight"] == APP_HEIGHT,
                    f"host mapped unexpected native surface: {mapped!r}")

            key(host, "l", CONTROL)
            type_text(host, "gallery")
            key(host, "enter")
            wait_page(state, 3)

            key(host, "k", CONTROL)
            type_text(host, "unknown thing")
            key(host, "enter")
            final = wait_page(state, 4, "unknown thing")
            require(final["tabs"][final["activeTab"]]["page"] == 4,
                    "keyboard search did not open the search page")

            host.request("resize", width=WINDOW_WIDTH, height=WINDOW_HEIGHT)
            time.sleep(0.3)
            host.request("screenshot", path=str(shot))
            width, height, pixels = read_ppm(shot)
            require(width > 0 and height > 0,
                    f"host screenshot is {width}x{height}")
            require(len(pixels) == width * height * 3,
                    "host screenshot payload length is incorrect")

            # The 960x640 image is contained in a 1200x900 window: x scales
            # by 1.25 and the image is centered with 50 px top/bottom bars.
            # Map the Gallery bookmark back into the app's 960x640 space.
            click_x = round(419 * WINDOW_WIDTH / APP_WIDTH)
            click_y = round(119 * (WINDOW_WIDTH / APP_WIDTH) +
                (WINDOW_HEIGHT - APP_HEIGHT * WINDOW_WIDTH / APP_WIDTH) / 2)
            host.request("pointer", node="browser", kind="down",
                         x=click_x, y=click_y, button="left")
            host.request("pointer", node="browser", kind="up",
                         x=click_x, y=click_y, button="left")
            resized = wait_page(state, 3)
            print(f"PASS browser mockup host keyboard page={final['tabs'][final['activeTab']]['page']} query={final['tabs'][final['activeTab']]['query']}")
            print(f"PASS browser mockup resized pointer page={resized['tabs'][resized['activeTab']]['page']} click={click_x},{click_y}")
            print(f"shot={shot} size={width}x{height}")
            return 0
        finally:
            if host is not None:
                host.close()
            if module.poll() is None:
                module.terminate()
            module.wait(timeout=5)
            if module.stderr is not None:
                error = module.stderr.read().decode("utf-8", "replace")
                if error:
                    print(error, file=sys.stderr)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL browser mockup host keyboard: {error}", file=sys.stderr)
        raise SystemExit(1)
