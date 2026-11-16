#!/usr/bin/env python3
"""Animate a retained canvas through host tick events and verify distinct frames.

Run from the aurora-host directory:
    python -B tools/drive_animation.py
"""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import sys

from host_session import ROOT, Host, ppm_counts, read_ppm, screenshot_path

SCENE = ROOT / "samples" / "animation.scene.json"
GREEN = (74, 222, 128)
ORANGE = (244, 162, 97)


def frame_commands(frame: int) -> tuple[list[dict], str, float]:
    phase = frame * math.pi / 4
    commands: list[dict] = [
        {
            "op": "text",
            "x": 24,
            "y": 18,
            "text": "application-driven canvas animation",
            "color": "#f1faee",
            "scale": 2,
        },
        {
            "op": "rect",
            "x": 20,
            "y": 58,
            "width": 580,
            "height": 210,
            "color": "#101d42",
        },
    ]
    for x in range(40, 601, 40):
        commands.append(
            {"op": "line", "x": x, "y": 68, "x2": x, "y2": 258,
             "color": "#1c2541", "thickness": 1}
        )
    for y in range(70, 259, 38):
        commands.append(
            {"op": "line", "x": 30, "y": y, "x2": 590, "y2": y,
             "color": "#1c2541", "thickness": 1}
        )

    def wave(amplitude: float, frequency: float, shift: float, color: str) -> None:
        point = None
        for x in range(40, 601, 12):
            y = round(163 + amplitude * math.sin((x - 40) * frequency + phase + shift))
            if point is not None:
                commands.append(
                    {"op": "line", "x": point[0], "y": point[1], "x2": x, "y2": y,
                     "color": color, "thickness": 3}
                )
            point = (x, y)

    wave(65, 0.025, 0.0, "#4ade80")
    wave(38, 0.045, math.pi / 2, "#f4a261")

    marker_x = 40 + frame * 180
    marker_y = round(163 + 65 * math.sin((marker_x - 40) * 0.025 + phase))
    commands.extend(
        [
            {"op": "line", "x": marker_x, "y": 68, "x2": marker_x, "y2": 258,
             "color": "#e63946", "thickness": 2},
            {"op": "circle", "x": marker_x, "y": marker_y, "radius": 8,
             "color": "#e63946"},
            {"op": "text", "x": 40, "y": 274,
             "text": "phase %.2f rad  frame %d" % (phase, frame),
             "color": "#f1faee", "scale": 2},
            {"op": "text", "x": 420, "y": 274,
             "text": "green sine  /  orange harmonic",
             "color": "#a8dadc", "scale": 1},
        ]
    )
    return commands, "phase %.2f rad · frame %d · 20 Hz" % (phase, frame), phase


def main() -> int:
    host = Host(SCENE)
    try:
        frames = []
        for frame in range(3):
            tick = host.pop_event(
                lambda event: event.get("event") == "tick"
                and event.get("node") == "wave"
            )
            commands, status, phase = frame_commands(frame)
            host.request("setCanvas", node="wave", commands=commands)
            host.request("setText", node="status", text=status)
            screenshot = screenshot_path("aurora-host-animation-%d.ppm" % frame)
            host.request("screenshot", path=str(screenshot))
            width, height, pixels = read_ppm(screenshot)
            counts = ppm_counts(screenshot, {GREEN, ORANGE})
            if counts[GREEN] <= 0 or counts[ORANGE] <= 0:
                raise RuntimeError(
                    "animation frame %d is missing wave pixels: %r" % (frame, counts)
                )
            frames.append(
                {
                    "frame": frame,
                    "phase": phase,
                    "tickDelta": tick.get("delta"),
                    "screenshot": str(screenshot),
                    "width": width,
                    "height": height,
                    "sha256": hashlib.sha256(pixels).hexdigest(),
                    "colors": {
                        "green": counts[GREEN],
                        "orange": counts[ORANGE],
                    },
                }
            )

        hashes = {frame["sha256"] for frame in frames}
        if len(hashes) != len(frames):
            raise RuntimeError("animation frames are not pixel-distinct: %r" % frames)
        if any(frame["width"] < 600 or frame["height"] < 300 for frame in frames):
            raise RuntimeError("animation screenshot is unexpectedly small: %r" % frames)

        print(json.dumps({"frames": frames, "uniqueFrames": len(hashes)}, indent=2))
        return 0
    finally:
        host.close()
        if host.errors:
            print("host stderr:\n" + "\n".join(host.errors), file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
