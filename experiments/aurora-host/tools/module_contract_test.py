#!/usr/bin/env python3
"""Prove the out-of-process module lifecycle and surface contract."""
from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
import time
from pathlib import Path

from host_session import EXE, ROOT, Host, ppm_counts, screenshot_path
from surface_client import SharedSurface

PROTOCOL = 9
SCHEMA = 2
WIDTH = 320
HEIGHT = 240
STALE_MS = 250
COLORS = {
    (16, 24, 32),
    (0, 200, 120),
    (230, 57, 70),
    (241, 250, 238),
}
REQUIRED_CAPABILITIES = {
    "control-stdin",
    "shared-surface",
    "surface-diagnostics",
    "surface-dpi",
    "surface-input-reserve",
    "surface-stale-policy",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def run_cli(exe: Path, *args: str) -> str:
    completed = subprocess.run(
        [str(exe), *args],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    require(
        completed.returncode == 0,
        f"{' '.join(args)} failed: {completed.stdout}{completed.stderr}",
    )
    return completed.stdout


def capabilities(exe: Path) -> set[str]:
    output = run_cli(exe, "--capabilities")
    line = next(
        (item for item in output.splitlines() if item.startswith("capabilities: ")),
        "",
    )
    require(line != "", f"capabilities line missing: {output!r}")
    return {item.strip() for item in line.removeprefix("capabilities: ").split(",")}


def checker() -> bytes:
    pixels = bytearray()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            color = (
                (16, 24, 32, 255),
                (0, 200, 120, 255),
                (230, 57, 70, 255),
                (241, 250, 238, 255),
            )[
                (1 if x >= WIDTH // 2 else 0)
                + (2 if y >= HEIGHT // 2 else 0)
            ]
            pixels.extend(color)
    return bytes(pixels)


def wait_for_surface(host: Host, node: str, predicate, timeout: float = 6.0) -> dict:
    deadline = time.monotonic() + timeout
    last: dict | None = None
    while time.monotonic() < deadline:
        last = host.request("surface", node=node)
        if predicate(last):
            return last
        time.sleep(0.02)
    raise RuntimeError(f"surface condition not met: {last!r}")


def wait_for_ring(host: Host, node: str, minimum: int, timeout: float = 5.0) -> dict:
    deadline = time.monotonic() + timeout
    last: dict | None = None
    while time.monotonic() < deadline:
        last = host.request("surface", node=node)
        if last["inputTail"] - last["inputHead"] >= minimum:
            return last
        time.sleep(0.01)
    raise RuntimeError(f"input ring did not receive events: {last!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", type=Path, default=EXE)
    args = parser.parse_args()
    require(args.host.is_file(), f"missing host executable: {args.host}")

    version = run_cli(args.host, "--version")
    require("aurora-host-experiment" in version, f"unexpected version: {version!r}")
    require(
        f"protocol {PROTOCOL} schema {SCHEMA}" in version,
        f"protocol/schema mismatch: {version!r}",
    )
    supported = capabilities(args.host)
    missing_capabilities = REQUIRED_CAPABILITIES - supported
    require(
        not missing_capabilities,
        f"missing capabilities: {sorted(missing_capabilities)!r}",
    )

    with tempfile.TemporaryDirectory(prefix="aurora-module-contract-") as name:
        temp = Path(name)
        surface_path = temp / "module.surface"
        scene_path = temp / "module.scene.json"
        scene_path.write_text(
            json.dumps(
                {
                    "schemaVersion": SCHEMA,
                    "window": {
                        "title": "Module contract",
                        "width": WIDTH,
                        "height": HEIGHT,
                    },
                    "root": {
                        "id": "module",
                        "type": "surface",
                        "path": str(surface_path),
                        "width": WIDTH,
                        "height": HEIGHT,
                        "staleMs": STALE_MS,
                        "events": ["pointer", "key"],
                    },
                }
            ),
            encoding="utf-8",
        )

        host = Host(scene_path, exe=args.host)
        surface: SharedSurface | None = None
        closed = False
        try:
            status = host.request("status")
            require(status.get("protocol") == PROTOCOL, f"status protocol: {status!r}")
            window = status.get("window", {})
            require(
                window.get("width") == WIDTH and window.get("height") == HEIGHT,
                f"unexpected logical window size: {window!r}",
            )
            require(status.get("nodes") == 1, f"unexpected node count: {status!r}")

            missing = wait_for_surface(
                host,
                "module",
                lambda info: not info["mapped"] and "missing" in info["error"].lower(),
            )
            surface = SharedSurface(surface_path, WIDTH, HEIGHT)
            mapped = wait_for_surface(host, "module", lambda info: info["mapped"])
            require(mapped["error"] == "", f"mapped surface reported an error: {mapped!r}")
            require(
                (mapped["pixelWidth"], mapped["pixelHeight"]) == (WIDTH, HEIGHT),
                f"unexpected native dimensions: {mapped!r}",
            )
            expected_preferred = (
                int(WIDTH * mapped["displayScale"] + 0.5),
                int(HEIGHT * mapped["displayScale"] + 0.5),
            )
            require(
                (mapped["preferredWidth"], mapped["preferredHeight"])
                == expected_preferred,
                f"unexpected preferred dimensions: {mapped!r}",
            )
            require(mapped["staleAfterMs"] == STALE_MS, f"stale policy mismatch: {mapped!r}")

            input_map = host.request("inputmap")
            key_down = input_map["kinds"]["keyDown"]
            key_up = input_map["kinds"]["keyUp"]
            pointer_down = input_map["kinds"]["pointerDown"]
            pointer_move = input_map["kinds"]["pointerMove"]
            pointer_up = input_map["kinds"]["pointerUp"]
            wheel = input_map["kinds"]["wheel"]
            left = input_map["buttons"]["left"]
            w_key = input_map["keys"]["w"]

            sequence = surface.publish(checker())
            surface.wait_for_host(sequence)
            visible = screenshot_path("aurora-module-contract.ppm")
            host.request("screenshot", path=str(visible))
            counts = ppm_counts(visible, COLORS)
            require(
                all(count > 0 for count in counts.values()),
                f"module frame was not composited: {counts!r}",
            )

            surface.read_inputs()
            host.request("pointer", node="module", kind="down", x=12, y=16, button="left")
            host.request("pointer", node="module", kind="move", x=40, y=30, button="left")
            host.request("pointer", node="module", kind="up", x=40, y=30, button="left")
            host.request(
                "pointer",
                node="module",
                kind="wheel",
                x=40,
                y=30,
                wheelX=0,
                wheelY=-120,
            )
            host.request("key", node="module", kind="down", key="w", modifiers=1)
            host.request("key", node="module", kind="up", key="w", modifiers=1)
            ring_info = wait_for_ring(host, "module", 6)
            events = surface.read_inputs()
            actual = {
                (
                    event["kind"],
                    event["button"],
                    event["key"],
                    event["x"],
                    event["y"],
                    event["wheelX"],
                    event["wheelY"],
                )
                for event in events
            }
            expected = {
                (pointer_down, left, 0, 12, 16, 0, 0),
                (pointer_move, left, 0, 40, 30, 0, 0),
                (pointer_up, left, 0, 40, 30, 0, 0),
                (wheel, left, 0, 40, 30, 0, -120),
                (key_down, 0, w_key, 0, 0, 0, 0),
                (key_up, 0, w_key, 0, 0, 0, 0),
            }
            missing_events = expected - actual
            require(not missing_events, f"input ring missing events: {missing_events!r}")
            require(
                ring_info["inputTail"] - ring_info["inputHead"] >= 6,
                f"ring counters inconsistent: {ring_info!r}",
            )

            time.sleep(STALE_MS / 1000.0 + 0.4)
            stale = host.request("surface", node="module")
            require(stale["stale"], f"surface did not become stale: {stale!r}")
            require(
                stale["frameAgeMs"] >= STALE_MS,
                f"stale age is below the policy: {stale!r}",
            )
            sequence = surface.publish(checker())
            surface.wait_for_host(sequence)
            fresh = host.request("surface", node="module")
            require(not fresh["stale"], f"surface did not recover: {fresh!r}")

            surface.close()
            with surface_path.open("r+b") as stream:
                stream.write(b"BROKEN!!")
            invalid = wait_for_surface(
                host,
                "module",
                lambda info: not info["mapped"] and "magic" in info["error"].lower(),
            )
            invalid_shot = screenshot_path("aurora-module-contract-invalid.ppm")
            host.request("screenshot", path=str(invalid_shot))
            stale_colors = ppm_counts(invalid_shot, COLORS)
            require(
                not any(stale_colors.values()),
                f"stale module pixels survived invalidation: {stale_colors!r}",
            )

            surface = SharedSurface(
                surface_path,
                WIDTH,
                HEIGHT,
                reuse_existing=True,
            )
            recovered = wait_for_surface(host, "module", lambda info: info["mapped"])
            sequence = surface.publish(checker())
            surface.wait_for_host(sequence)
            recovered_shot = screenshot_path("aurora-module-contract-recovered.ppm")
            host.request("screenshot", path=str(recovered_shot))
            recovered_colors = ppm_counts(recovered_shot, COLORS)
            require(
                all(count > 0 for count in recovered_colors.values()),
                f"recovered module frame was not visible: {recovered_colors!r}",
            )

            host.request("close")
            host.process.wait(timeout=5)
            closed = True
            require(host.process.returncode == 0, f"host exit code: {host.process.returncode}")

            print(
                json.dumps(
                    {
                        "protocol": status["protocol"],
                        "capabilities": sorted(REQUIRED_CAPABILITIES),
                        "logical": [WIDTH, HEIGHT],
                        "native": [mapped["pixelWidth"], mapped["pixelHeight"]],
                        "frame": sequence,
                        "ring": {
                            "head": ring_info["inputHead"],
                            "tail": ring_info["inputTail"],
                            "events": len(events),
                        },
                        "missing": missing["error"],
                        "stale": {
                            "stale": stale["stale"],
                            "frameAgeMs": stale["frameAgeMs"],
                        },
                        "invalid": invalid["error"],
                        "recovered": recovered["mapped"],
                        "exitCode": host.process.returncode,
                    },
                    indent=2,
                )
            )
            print("module contract test passed")
            return 0
        finally:
            if not closed:
                host.close()
            if surface is not None:
                surface.close()
            if host.errors:
                print("host stderr:\n" + "\n".join(host.errors))


if __name__ == "__main__":
    raise SystemExit(main())