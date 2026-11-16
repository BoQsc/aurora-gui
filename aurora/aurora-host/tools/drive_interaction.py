"""Drive the live host demo through stdin/stdout and verify the rendered result.

Run from the aurora-host directory:
    python -B tools/drive_interaction.py
"""
from __future__ import annotations

import json
from pathlib import Path
import sys

from host_session import EXE, ROOT, Host, ppm_counts, screenshot_path


SCENE = ROOT / "samples" / "interaction.scene.json"


def canvas_commands(x: int, y: int) -> list[dict]:
    return [
        {
            "op": "text",
            "x": 24,
            "y": 24,
            "text": "input acknowledged; scene redrawn",
            "color": "#f1faee",
            "scale": 2,
        },
        {
            "op": "rect",
            "x": 400,
            "y": 120,
            "width": 60,
            "height": 60,
            "color": "#00ff88",
        },
        {
            "op": "circle",
            "x": x,
            "y": y,
            "radius": 14,
            "color": "#e63946",
        },
        {
            "op": "line",
            "x": 60,
            "y": 180,
            "x2": x,
            "y2": y,
            "color": "#f4a261",
            "thickness": 3,
        },
    ]


def main() -> int:
    if not EXE.exists():
        raise RuntimeError(f"missing executable: {EXE}")
    host = Host(SCENE)
    try:
        host.request("setTick", node="live", hz=60)
        host.request("pointer", node="live", kind="down", x=120, y=100, button="left")
        host.request("pointer", node="live", kind="move", x=220, y=140, button="left")
        host.request("pointer", node="live", kind="wheel", x=220, y=140, wheelX=0, wheelY=120)
        host.request("pointer", node="live", kind="up", x=220, y=140, button="left")
        host.request("key", node="live", kind="down", key="a", modifiers=1)
        host.request("key", node="live", kind="up", key="a", modifiers=1)

        pointer_down = host.wait_event(
            lambda event: event.get("event") == "pointer" and event.get("kind") == "down"
        )
        pointer_up = host.wait_event(
            lambda event: event.get("event") == "pointer" and event.get("kind") == "up"
        )
        wheel = host.wait_event(
            lambda event: event.get("event") == "pointer" and event.get("kind") == "wheel"
        )
        key_down = host.wait_event(
            lambda event: event.get("event") == "key" and event.get("kind") == "down"
        )
        tick = host.wait_event(lambda event: event.get("event") == "tick")

        host.request("setCanvas", node="live", commands=canvas_commands(220, 140))
        status = "pointer=(%d,%d) key=%s wheel=%d tick=.%d" % (
            pointer_up["x"],
            pointer_up["y"],
            key_down["key"],
            wheel["wheelY"],
            int(round(tick["delta"] * 1000)),
        )
        host.request("setText", node="status", text=status)
        tree = host.request("tree")
        status_nodes = [node for node in tree["nodes"] if node["id"] == "status"]
        if not status_nodes or status_nodes[0]["text"] != status:
            raise RuntimeError(f"label did not update: {status_nodes!r}")

        screenshot = screenshot_path("aurora-host-interaction.ppm")
        host.request("screenshot", path=str(screenshot))
        counts = ppm_counts(screenshot, {(0, 255, 136), (230, 57, 70)})
        if counts[(0, 255, 136)] <= 0:
            raise RuntimeError(f"redrawn marker missing from screenshot: {counts!r}")
        if counts[(230, 57, 70)] <= 0:
            raise RuntimeError(f"pointer circle missing from screenshot: {counts!r}")

        print(
            json.dumps(
                {
                    "events": {
                        "pointer_down": pointer_down,
                        "pointer_up": pointer_up,
                        "wheel": wheel,
                        "key_down": key_down,
                        "tick": tick,
                    },
                    "status": status,
                    "screenshot": str(screenshot),
                    "colors": {str(key): value for key, value in counts.items()},
                },
                indent=2,
            )
        )
        return 0
    finally:
        host.close()
        if host.errors:
            print("host stderr:\n" + "\n".join(host.errors), file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
