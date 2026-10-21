"""Exercise the shared-surface hot path with a software-rendered 3D cube.

The host never receives per-frame draw commands here. This process writes RGBA
frames and frame metadata into a memory-mapped file; the host copies the active
buffer on its normal tick. Pointer and keyboard events travel back through the
surface input ring.
"""
from __future__ import annotations

import json
import math
import mmap
import struct
import time
from pathlib import Path
import sys

from host_session import EXE, ROOT, Host, ppm_counts, ppm_unique, screenshot_path

SCENE = ROOT / "samples" / "surface.scene.json"
SURFACE = ROOT / "build" / "live.surface"
WIDTH = 320
HEIGHT = 240
CAPACITY = 64
HEADER = 80
EVENT = 24
BUFFERS = 2
MAGIC = b"AURSFACE"
VERSION = 2


class SharedSurface:
    def __init__(self, path: Path, width: int, height: int) -> None:
        self.path = path
        self.width = width
        self.height = height
        self.frame_bytes = width * height * 4
        self.size = HEADER + CAPACITY * EVENT + BUFFERS * self.frame_bytes
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as stream:
            stream.truncate(self.size)
        self.file = path.open("r+b")
        self.map = mmap.mmap(self.file.fileno(), self.size)
        struct.pack_into(
            "<8sIIIIII", self.map, 0, MAGIC, VERSION, HEADER, width, height, 0, CAPACITY
        )
        struct.pack_into("<Q", self.map, 32, 0)
        struct.pack_into("<Q", self.map, 40, 0)
        struct.pack_into("<IIIII", self.map, 48, 0, 0, EVENT, BUFFERS, self.frame_bytes)
        self.sequence = 0
        self.closed = False

    def frame_offset(self, index: int) -> int:
        return HEADER + CAPACITY * EVENT + index * self.frame_bytes

    def publish(self, pixels: bytes) -> int:
        if len(pixels) != self.frame_bytes:
            raise ValueError(f"frame is {len(pixels)} bytes, expected {self.frame_bytes}")
        active = struct.unpack_from("<I", self.map, 24)[0]
        target = 1 - active
        offset = self.frame_offset(target)
        self.map[offset : offset + self.frame_bytes] = pixels
        struct.pack_into("<I", self.map, 24, target)
        self.sequence += 1
        struct.pack_into("<Q", self.map, 32, self.sequence)
        return self.sequence

    def host_read(self) -> int:
        return struct.unpack_from("<Q", self.map, 40)[0]

    def wait_for_host(self, sequence: int, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        while self.host_read() < sequence:
            if time.monotonic() >= deadline:
                raise TimeoutError(f"host did not read frame {sequence}: {self.host_read()}")
            time.sleep(0.005)

    def read_inputs(self) -> list[dict]:
        head = struct.unpack_from("<I", self.map, 48)[0]
        tail = struct.unpack_from("<I", self.map, 52)[0]
        events: list[dict] = []
        for index in range(head, tail):
            offset = HEADER + (index % CAPACITY) * EVENT
            kind, button, key, modifiers, x, y, wheel_x, wheel_y = struct.unpack_from(
                "<BBHIiiii", self.map, offset
            )
            events.append(
                {
                    "kind": kind,
                    "button": button,
                    "key": key,
                    "modifiers": modifiers,
                    "x": x,
                    "y": y,
                    "wheelX": wheel_x,
                    "wheelY": wheel_y,
                }
            )
        struct.pack_into("<I", self.map, 48, tail)
        return events

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        self.map.close()
        self.file.close()


def background() -> bytearray:
    pixels = bytearray(WIDTH * HEIGHT * 4)
    for y in range(HEIGHT):
        t = y / max(1, HEIGHT - 1)
        row = bytes((int(7 + 14 * t), int(11 + 18 * t), int(20 + 28 * t), 255)) * WIDTH
        start = y * WIDTH * 4
        pixels[start : start + WIDTH * 4] = row
    return pixels


def checker() -> bytes:
    pixels = bytearray()
    colors = (
        (16, 24, 32, 255),
        (0, 200, 120, 255),
        (230, 57, 70, 255),
        (241, 250, 238, 255),
    )
    for y in range(HEIGHT):
        for x in range(WIDTH):
            pixels.extend(colors[(1 if x >= WIDTH // 2 else 0) + (2 if y >= HEIGHT // 2 else 0)])
    return bytes(pixels)


def rotation(yaw: float, pitch: float) -> list[tuple[float, float, float]]:
    cy, sy = math.cos(yaw), math.sin(yaw)
    cp, sp = math.cos(pitch), math.sin(pitch)
    vertices = [
        (-1, -1, -1),
        (1, -1, -1),
        (1, 1, -1),
        (-1, 1, -1),
        (-1, -1, 1),
        (1, -1, 1),
        (1, 1, 1),
        (-1, 1, 1),
    ]
    rotated = []
    for x, y, z in vertices:
        x1 = x * cy + z * sy
        z1 = -x * sy + z * cy
        y1 = y * cp - z1 * sp
        z2 = y * sp + z1 * cp
        rotated.append((x1, y1, z2))
    return rotated


FACES = (
    ((0, 1, 2, 3), (230, 57, 70)),
    ((5, 4, 7, 6), (244, 162, 97)),
    ((4, 0, 3, 7), (42, 157, 143)),
    ((1, 5, 6, 2), (69, 123, 157)),
    ((3, 2, 6, 7), (168, 218, 220)),
    ((4, 5, 1, 0), (131, 56, 236)),
)


def normalize(vector: tuple[float, float, float]) -> tuple[float, float, float]:
    length = math.sqrt(sum(value * value for value in vector)) or 1.0
    return (vector[0] / length, vector[1] / length, vector[2] / length)


def draw_cube(yaw: float, pitch: float) -> bytes:
    pixels = background()
    depth = [-1.0] * (WIDTH * HEIGHT)
    vertices = rotation(yaw, pitch)
    camera = 4.2
    scale = min(WIDTH, HEIGHT) * 0.9
    projected: list[tuple[float, float, float]] = []
    for x, y, z in vertices:
        view_z = z + camera
        perspective = scale / view_z
        projected.append((WIDTH / 2 + x * perspective, HEIGHT / 2 - y * perspective, view_z))
    light = normalize((0.35, 0.55, -0.75))

    def raster_triangle(a, b, c, color):
        ax, ay, az = a
        bx, by, bz = b
        cx, cy, cz = c
        denominator = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
        if abs(denominator) < 1e-9:
            return
        min_x = max(0, int(math.floor(min(ax, bx, cx))))
        max_x = min(WIDTH - 1, int(math.ceil(max(ax, bx, cx))))
        min_y = max(0, int(math.floor(min(ay, by, cy))))
        max_y = min(HEIGHT - 1, int(math.ceil(max(ay, by, cy))))
        for py in range(min_y, max_y + 1):
            for px in range(min_x, max_x + 1):
                sample_x = px + 0.5
                sample_y = py + 0.5
                w0 = ((cx - bx) * (sample_y - by) - (cy - by) * (sample_x - bx)) / denominator
                w1 = ((ax - cx) * (sample_y - cy) - (ay - cy) * (sample_x - cx)) / denominator
                w2 = 1.0 - w0 - w1
                if w0 < -1e-7 or w1 < -1e-7 or w2 < -1e-7:
                    continue
                inverse_z = w0 / az + w1 / bz + w2 / cz
                index = py * WIDTH + px
                if inverse_z <= depth[index]:
                    continue
                depth[index] = inverse_z
                offset = index * 4
                pixels[offset] = color[0]
                pixels[offset + 1] = color[1]
                pixels[offset + 2] = color[2]
                pixels[offset + 3] = 255

    for indices, base in FACES:
        points = [vertices[index] for index in indices]
        edge_a = tuple(points[1][i] - points[0][i] for i in range(3))
        edge_b = tuple(points[2][i] - points[0][i] for i in range(3))
        normal = normalize(
            (
                edge_a[1] * edge_b[2] - edge_a[2] * edge_b[1],
                edge_a[2] * edge_b[0] - edge_a[0] * edge_b[2],
                edge_a[0] * edge_b[1] - edge_a[1] * edge_b[0],
            )
        )
        if normal[2] > 0:
            normal = (-normal[0], -normal[1], -normal[2])
        shade = 0.38 + 0.62 * max(0.0, normal[0] * light[0] + normal[1] * light[1] + normal[2] * light[2])
        color = tuple(min(255, int(channel * shade)) for channel in base)
        quad = [projected[index] for index in indices]
        raster_triangle(quad[0], quad[1], quad[2], color)
        raster_triangle(quad[0], quad[2], quad[3], color)
    return bytes(pixels)


def event_name(kind: int) -> str:
    return {
        1: "pointer down",
        2: "pointer move",
        3: "pointer up",
        4: "wheel",
        5: "key down",
        6: "key up",
    }.get(kind, f"kind {kind}")


def main() -> int:
    if not EXE.exists():
        raise RuntimeError(f"missing executable: {EXE}")
    SURFACE.unlink(missing_ok=True)
    host = Host(SCENE)
    surface = None
    invalid_info = None
    open_failed_info = None
    try:
        missing_info = None
        for _ in range(100):
            missing_info = host.request("surface", node="live")
            if "missing" in missing_info["error"].lower():
                break
            time.sleep(0.02)
        if not missing_info or "missing" not in missing_info["error"].lower():
            raise RuntimeError(f"missing surface was not reported: {missing_info!r}")

        SURFACE.mkdir()
        try:
            for _ in range(100):
                open_failed_info = host.request("surface", node="live")
                if "open failed" in open_failed_info["error"].lower():
                    break
                time.sleep(0.02)
            if (not open_failed_info or open_failed_info["mapped"]
                    or "open failed" not in open_failed_info["error"].lower()):
                raise RuntimeError(
                    f"surface open failure was not reported: {open_failed_info!r}"
                )
        finally:
            SURFACE.rmdir()

        surface = SharedSurface(SURFACE, WIDTH, HEIGHT)
        info = None
        for _ in range(100):
            info = host.request("surface", node="live")
            if info.get("mapped"):
                break
            time.sleep(0.02)
        if not info or not info.get("mapped"):
            raise RuntimeError(f"surface did not map: {info!r}")
        if (info["error"] or info["pixelWidth"] != WIDTH
                or info["pixelHeight"] != HEIGHT
                or info["preferredWidth"] != WIDTH
                or info["preferredHeight"] != HEIGHT
                or info["displayScale"] != 1.0):
            raise RuntimeError(f"mapped surface contract is inconsistent: {info!r}")

        input_map = host.request("inputmap")
        if input_map["keys"]["w"] != 48 or input_map["modifiers"]["shift"] != 1:
            raise RuntimeError(f"input map is inconsistent: {input_map!r}")
        if input_map["kinds"]["keyDown"] != 5 or input_map["buttons"]["left"] != 1:
            raise RuntimeError(f"input map is inconsistent: {input_map!r}")

        checker_sequence = surface.publish(checker())
        surface.wait_for_host(checker_sequence)
        checker_shot = screenshot_path("aurora-host-surface-checker.ppm")
        host.request("screenshot", path=str(checker_shot))
        checker_colors = ppm_counts(
            checker_shot,
            {(16, 24, 32), (0, 200, 120), (230, 57, 70), (241, 250, 238)},
        )
        missing = {str(color): count for color, count in checker_colors.items() if count == 0}
        if missing:
            raise RuntimeError(f"shared-surface frame not visible: {missing!r}")

        sequence = checker_sequence
        for frame in range(24):
            angle = frame * math.tau / 24
            sequence = surface.publish(draw_cube(angle, 0.45))
            surface.wait_for_host(sequence)
        sequence = surface.publish(draw_cube(0.85, 0.4))
        surface.wait_for_host(sequence)

        cube_shot = screenshot_path("aurora-host-surface-cube.ppm")
        host.request("screenshot", path=str(cube_shot))
        unique = ppm_unique(cube_shot)
        if unique < 100:
            raise RuntimeError(f"cube screenshot has too little variation: {unique} colors")

        time.sleep(0.7)
        stale_info = host.request("surface", node="live")
        if not stale_info["stale"] or stale_info["frameAgeMs"] < 500:
            raise RuntimeError(f"surface did not report stale: {stale_info!r}")
        if stale_info["staleAfterMs"] != 250:
            raise RuntimeError(f"surface ignored staleMs policy: {stale_info!r}")
        refreshed = surface.publish(draw_cube(0.9, 0.4))
        surface.wait_for_host(refreshed)
        fresh_info = host.request("surface", node="live")
        if fresh_info["stale"]:
            raise RuntimeError(f"surface did not recover from stale: {fresh_info!r}")

        # Drain events that the real window may have received while frames were
        # published, so the assertion below covers only the injected sequence.
        drained = surface.read_inputs()
        info = host.request("surface", node="live")
        if info["inputTail"] != info["inputHead"]:
            raise RuntimeError(f"input ring did not drain: {info!r}")
        if info["stale"]:
            raise RuntimeError(f"fresh surface reported stale: {info!r}")

        coalesced_before = info["inputCoalesced"]
        host.request("pointer", node="live", kind="down", x=40, y=50, button="left")
        host.request("pointer", node="live", kind="move", x=100, y=80, button="left")
        host.request("pointer", node="live", kind="move", x=100, y=80, button="left")
        host.request("pointer", node="live", kind="up", x=100, y=80, button="left")
        info = host.request("surface", node="live")
        if info["inputCoalesced"] <= coalesced_before:
            raise RuntimeError(f"identical pointer moves were not coalesced: {info!r}")
        coalesced_events = surface.read_inputs()
        identical_moves = [
            event
            for event in coalesced_events
            if event["kind"] == 2 and event["x"] == 100 and event["y"] == 80
        ]
        if len(identical_moves) != 1:
            raise RuntimeError(
                f"expected one coalesced move, got {identical_moves!r}"
            )

        before_saturation = host.request("surface", node="live")
        dropped_before = before_saturation["inputDropped"]
        moves_dropped_before = before_saturation["inputDroppedMoves"]
        for index in range(70):
            host.request(
                "pointer", node="live", kind="move", x=index + 1, y=1, button="left"
            )
        info = host.request("surface", node="live")
        if info["inputDropped"] <= dropped_before:
            raise RuntimeError(f"full input ring did not report drops: {info!r}")
        if info["inputDroppedMoves"] <= moves_dropped_before:
            raise RuntimeError(f"pointer-move drops were not classified: {info!r}")

        # Movement is intentionally capped below capacity. A discrete event
        # injected after the flood must still be appended.
        host.request("key", node="live", kind="down", key="w", modifiers=1)
        host.request("key", node="live", kind="up", key="w", modifiers=1)
        flooded = surface.read_inputs()
        if not any(event["kind"] == 5 and event["key"] == 48 for event in flooded):
            raise RuntimeError(f"key-down was starved by pointer movement: {info!r}")
        if not any(event["kind"] == 6 and event["key"] == 48 for event in flooded):
            raise RuntimeError(f"key-up was starved by pointer movement: {info!r}")

        host.request("pointer", node="live", kind="down", x=40, y=50, button="left")
        host.request("pointer", node="live", kind="move", x=100, y=80, button="left")
        host.request("pointer", node="live", kind="up", x=100, y=80, button="left")
        host.request("pointer", node="live", kind="wheel", x=100, y=80, wheelX=0, wheelY=-120)
        host.request("key", node="live", kind="down", key="a", modifiers=1)
        host.request("key", node="live", kind="up", key="a", modifiers=1)
        info = host.request("surface", node="live")
        if info["inputTail"] - info["inputHead"] < 6:
            raise RuntimeError(f"input ring lost injected events: {info!r}")
        events = surface.read_inputs()
        expected = [
            (1, 1, 0, 40, 50, 0, 0),
            (2, 1, 0, 100, 80, 0, 0),
            (3, 1, 0, 100, 80, 0, 0),
            (4, 1, 0, 100, 80, 0, -120),
            (5, 0, 26, 0, 0, 0, 0),
            (6, 0, 26, 0, 0, 0, 0),
        ]
        actual = {
            (event["kind"], event["button"], event["key"], event["x"], event["y"], event["wheelX"], event["wheelY"])
            for event in events
        }
        missing = [item for item in expected if item not in actual]
        if missing:
            raise RuntimeError(f"input ring missing injected events: {missing!r}; actual={sorted(actual)!r}")

        # Replacing the magic must transition a live mapping into a visible
        # incompatible-file state rather than leaving a stale image behind.
        surface.close()
        with SURFACE.open("r+b") as stream:
            stream.write(b"BROKEN!!")
        for _ in range(100):
            invalid_info = host.request("surface", node="live")
            if not invalid_info["mapped"] and "magic" in invalid_info["error"].lower():
                break
            time.sleep(0.02)
        if not invalid_info or invalid_info["mapped"] or "magic" not in invalid_info["error"].lower():
            raise RuntimeError(f"invalid surface was not reported: {invalid_info!r}")
        invalid_shot = screenshot_path("aurora-host-surface-invalid.ppm")
        host.request("screenshot", path=str(invalid_shot))
        stale_colors = ppm_counts(
            invalid_shot, {(0, 200, 120), (230, 57, 70)}
        )
        if any(stale_colors.values()):
            raise RuntimeError(
                f"stale surface pixels survived invalidation: {stale_colors!r}"
            )

        print(
            json.dumps(
                {
                    "surface": str(SURFACE),
                    "frames": sequence,
                    "checker_screenshot": str(checker_shot),
                    "checker_colors": {str(k): v for k, v in checker_colors.items()},
                    "cube_screenshot": str(cube_shot),
                    "cube_unique_colors": unique,
                    "drained_window_events": len(drained),
                    "input_map": input_map,
                    "input_coalesced": info["inputCoalesced"],
                    "input_dropped": info["inputDropped"],
                    "input_dropped_moves": info["inputDroppedMoves"],
                    "input_dropped_discrete": info["inputDroppedDiscrete"],
                    "stale_after_idle": stale_info,
                    "fresh_after_publish": fresh_info,
                    "missing": missing_info,
                    "open_failed": open_failed_info,
                    "invalid": invalid_info,
                    "invalid_stale_colors": {
                        str(color): count for color, count in stale_colors.items()
                    },
                    "input_ring": [
                        {"event": event_name(event["kind"]), **event}
                        for event in events
                        if (
                            event["kind"],
                            event["button"],
                            event["key"],
                            event["x"],
                            event["y"],
                            event["wheelX"],
                            event["wheelY"],
                        )
                        in expected
                    ],
                },
                indent=2,
            )
        )
        return 0
    finally:
        host.close()
        if surface is not None:
            surface.close()
        if host.errors:
            print("host stderr:\n" + "\n".join(host.errors), file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
