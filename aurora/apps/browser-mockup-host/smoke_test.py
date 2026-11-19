#!/usr/bin/env python3
"""Smoke-test the host-owned browser scene and its canvas reflow."""
from __future__ import annotations

import json
from pathlib import Path
import sys
import time

PROJECT = Path(__file__).resolve().parent
AURORA = PROJECT.parents[1]
sys.path.insert(0, str(AURORA / "aurora-host" / "tools"))
sys.path.insert(0, str(PROJECT))
from host_session import Host  # noqa: E402
from controller import BrowserController, SCENE  # noqa: E402

OUT = PROJECT / "build"
OUT.mkdir(parents=True, exist_ok=True)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def wait_action(host: Host, timeout: float = 3.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            event = host.pop_event(
                lambda value: value.get("event") == "action", timeout=0.2)
            return event
        except TimeoutError:
            pass
    raise RuntimeError("host emitted no action event")


def main() -> int:
    host = Host(SCENE, watch=False)
    controller = BrowserController(host)
    try:
        controller.refresh()
        start_bounds = controller.canvas_bounds()
        require(start_bounds[0] > 200 and start_bounds[1] > 100,
                f"invalid start canvas bounds: {start_bounds}")

        host.request("click", node="bookmark-design")
        event = wait_action(host)
        controller.handle_action(str(event.get("action", "")))
        require(controller.tab.page == "design",
                f"bookmark action did not navigate: {controller.tab.page}")


        host.request("click", node="new-tab")
        event = wait_action(host)
        controller.handle_action(str(event.get("action", "")))
        require(len(controller.tabs) == 2,
                f"new tab action failed: {len(controller.tabs)} tabs")
        host.request("setText", node="address", text="gallery", notify=False)
        host.request("click", node="go")
        event = wait_action(host)
        controller.handle_action(str(event.get("action", "")))
        require(controller.tab.page == "gallery",
                f"address Go failed: {controller.tab.page}")

        before = controller.canvas_bounds()
        host.request("resize", width=1400, height=900)
        time.sleep(0.2)
        controller.redraw()
        after = controller.canvas_bounds()
        require(after[0] != before[0] or after[1] != before[1],
                f"canvas did not reflow: {before} -> {after}")
        require(after[0] > before[0] and after[1] > before[1],
                f"canvas did not grow with the host: {before} -> {after}")

        print(
            "PASS host-scene browser "
            f"page={controller.tab.page} canvas={before}->{after}"
        )
        return 0
    finally:
        controller.close()
        if host.errors:
            print("\n".join(host.errors), file=sys.stderr)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL host-scene browser: {error}", file=sys.stderr)
        raise SystemExit(1)
