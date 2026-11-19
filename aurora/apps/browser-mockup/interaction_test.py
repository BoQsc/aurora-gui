#!/usr/bin/env python3
"""Exercise the browser mockup through the real AURSFACE input ring.

The test builds module.d, acts as the host acknowledgement side of the
surface, injects clicks, and checks the module's live state document. It does
not need a desktop window or a network connection.
"""
from __future__ import annotations

import json
import mmap
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
AURORA_D = ROOT / "aurora-d" / "source"
AURORA_STANDARD = ROOT / "aurora-standard" / "source"
SOURCE = PROJECT / "module.d"
WIDTH = 960
HEIGHT = 640
HEADER = 80
EVENT = 24
CAPACITY = 64
BUFFERS = 2
SURFACE_SIZE = HEADER + CAPACITY * EVENT + BUFFERS * WIDTH * HEIGHT * 4
KEY_BACKSPACE = 1
KEY_ENTER = 3
KEY_ESCAPE = 4
KEY_SPACE = 5
KEY_A = 26
CONTROL = 2


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


class LiveSurface:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.file = path.open("r+b")
        self.map = mmap.mmap(self.file.fileno(), 0)
        self.sequence = 0

    def acknowledge(self) -> None:
        sequence = struct.unpack_from("<Q", self.map, 32)[0]
        if sequence > self.sequence:
            self.sequence = sequence
            struct.pack_into("<Q", self.map, 40, sequence)

    def frame(self) -> bytes:
        active = struct.unpack_from("<I", self.map, 24)[0]
        offset = HEADER + CAPACITY * EVENT + active * WIDTH * HEIGHT * 4
        return bytes(self.map[offset : offset + WIDTH * HEIGHT * 4])

    def push(self, kind: int, x: int, y: int) -> None:
        head = struct.unpack_from("<I", self.map, 48)[0]
        tail = struct.unpack_from("<I", self.map, 52)[0]
        require(tail - head < CAPACITY, "input ring is full")
        offset = HEADER + (tail % CAPACITY) * EVENT
        struct.pack_into("<BBHIiiii", self.map, offset, kind, 1, 0, 0, x, y, 0, 0)
        struct.pack_into("<I", self.map, 52, tail + 1)

    def push_key(self, key: int, modifiers: int = 0) -> None:
        for kind in (5, 6):
            head = struct.unpack_from("<I", self.map, 48)[0]
            tail = struct.unpack_from("<I", self.map, 52)[0]
            require(tail - head < CAPACITY, "input ring is full")
            offset = HEADER + (tail % CAPACITY) * EVENT
            struct.pack_into("<BBHIiiii", self.map, offset, kind, 0,
                             key, modifiers, 0, 0, 0, 0)
            struct.pack_into("<I", self.map, 52, tail + 1)

    def pump(self, seconds: float) -> None:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.acknowledge()
            time.sleep(0.008)

    def close(self) -> None:
        self.map.close()
        self.file.close()


def wait_ready(state_path: Path, surface_path: Path, timeout: float = 8.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if surface_path.is_file() and surface_path.stat().st_size == SURFACE_SIZE:
            try:
                state = json.loads(state_path.read_text(encoding="utf-8"))
                if state.get("build") == 1:
                    return state
            except (OSError, json.JSONDecodeError):
                pass
        time.sleep(0.03)
    raise RuntimeError("module did not publish its first live state")


def read_state(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def wait_state(surface: LiveSurface, path: Path, predicate, label: str,
               timeout: float = 3.0) -> dict:
    deadline = time.monotonic() + timeout
    last: dict | None = None
    while time.monotonic() < deadline:
        surface.acknowledge()
        try:
            last = read_state(path)
            if predicate(last):
                return last
        except (OSError, json.JSONDecodeError):
            pass
        time.sleep(0.02)
    raise RuntimeError(f"state did not update for {label}: {last!r}")


def click(surface: LiveSurface, x: int, y: int) -> None:
    surface.push(1, x, y)
    surface.push(3, x, y)
    surface.pump(0.18)


def type_text(surface: LiveSurface, text: str) -> None:
    for character in text:
        if character == " ":
            key = KEY_SPACE
        elif "a" <= character <= "z":
            key = KEY_A + ord(character) - ord("a")
        else:
            raise RuntimeError(f"test cannot type {character!r}")
        surface.push_key(key)
        surface.pump(0.03)


def press_key(surface: LiveSurface, key: int, modifiers: int = 0) -> None:
    surface.push_key(key, modifiers)
    surface.pump(0.12)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="aurora-browser-mockup-") as name:
        work = Path(name)
        executable = work / "browser-mockup.exe"
        built = subprocess.run(
            ["dmd", "-O", "-release", "-i",
             f"-I{AURORA_D}", f"-I{AURORA_STANDARD}",
             f"-of={executable}", str(SOURCE)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=120,
        )
        require(built.returncode == 0,
                f"module build failed:\n{built.stdout}{built.stderr}")

        surface_path = work / "browser.surface"
        state_path = work / "browser.state.json"
        process = subprocess.Popen(
            [str(executable), "--surface", str(surface_path),
             "--state", str(state_path), "--build", "1", "--seconds", "30"],
            cwd=str(work),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        surface: LiveSurface | None = None
        try:
            state = wait_ready(state_path, surface_path)
            require(state["tabCount"] == 1, "expected one startup tab")
            require(state["tabs"][0]["page"] == 0, "expected the start page")

            surface = LiveSurface(surface_path)
            surface.pump(0.25)
            start_frame = surface.frame()

            # Address suggestions: click the bar, then the Design row.
            click(surface, 500, 75)
            click(surface, 500, 197)
            state = wait_state(
                surface, state_path,
                lambda value: value["tabs"][value["activeTab"]]["page"] == 1,
                "address suggestion navigation",
            )
            design_frame = surface.frame()
            require(design_frame != start_frame,
                    "navigating to the design page did not change pixels")

            # Back to start.
            click(surface, 37, 74)
            wait_state(
                surface, state_path,
                lambda value: value["tabs"][value["activeTab"]]["page"] == 0,
                "back navigation",
            )

            # New tab.
            click(surface, 280, 24)
            state = wait_state(
                surface, state_path,
                lambda value: value["tabCount"] == 2 and value["activeTab"] == 1,
                "new tab",
            )

            # Docs bookmark in the new tab.
            click(surface, 318, 119)
            wait_state(
                surface, state_path,
                lambda value: value["tabs"][value["activeTab"]]["page"] == 2,
                "docs bookmark",
            )

            # Docs sidebar: Pointer input section.
            click(surface, 128, 293)
            state = wait_state(
                surface, state_path,
                lambda value: value["tabs"][value["activeTab"]]["docSection"] == 1,
                "docs sidebar",
            )
            docs_frame = surface.frame()
            require(docs_frame != design_frame,
                    "docs page did not change pixels")

            # Gallery bookmark and a gallery swatch.
            click(surface, 419, 119)
            wait_state(
                surface, state_path,
                lambda value: value["tabs"][value["activeTab"]]["page"] == 3,
                "gallery bookmark",
            )
            click(surface, 148, 516)
            state = wait_state(
                surface, state_path,
                lambda value: value["tabs"][value["activeTab"]]["galleryIndex"] == 3,
                "gallery swatch",
            )
            gallery_frame = surface.frame()
            require(gallery_frame != docs_frame,
                    "gallery did not change pixels")

            # Menu item 3 hides the bookmarks bar.
            click(surface, 883, 74)
            click(surface, 812, 239)
            wait_state(
                surface, state_path,
                lambda value: value["bookmarksVisible"] is False,
                "hide bookmarks bar",
            )

            # Close the menu, reopen it, and show the bar again.
            click(surface, 883, 74)
            click(surface, 883, 74)
            click(surface, 883, 74)
            click(surface, 812, 239)
            wait_state(
                surface, state_path,
                lambda value: value["bookmarksVisible"] is True,
                "show bookmarks bar",
            )

            # Close the active tab.
            click(surface, 454, 24)
            state = wait_state(
                surface, state_path,
                lambda value: value["tabCount"] == 1,
                "close tab",
            )

            # Keyboard address flow and the local search results page.
            press_key(surface, KEY_A + ord("l") - ord("a"), CONTROL)
            type_text(surface, "gallery")
            press_key(surface, KEY_ENTER)
            wait_state(
                surface, state_path,
                lambda value: value["tabs"][value["activeTab"]]["page"] == 3,
                "keyboard gallery",
            )

            press_key(surface, KEY_A + ord("k") - ord("a"), CONTROL)
            type_text(surface, "unknown thing")
            press_key(surface, KEY_ENTER)
            state = wait_state(
                surface, state_path,
                lambda value: value["tabs"][value["activeTab"]]["page"] == 4
                    and value["tabs"][value["activeTab"]].get("query") ==
                    "unknown thing",
                "local search page",
            )
            search_frame = surface.frame()
            require(search_frame != gallery_frame,
                    "search page did not change pixels")

            # The first local result opens the design article.
            click(surface, 500, 360)
            wait_state(
                surface, state_path,
                lambda value: value["tabs"][value["activeTab"]]["page"] == 1,
                "search result",
            )

            press_key(surface, KEY_A + ord("l") - ord("a"), CONTROL)
            type_text(surface, "docs input")
            press_key(surface, KEY_ENTER)
            state = wait_state(
                surface, state_path,
                lambda value: value["tabs"][value["activeTab"]]["page"] == 2
                    and value["tabs"][value["activeTab"]]["docSection"] == 1,
                "keyboard docs input",
            )
            print(
                "PASS browser mockup interaction "
                f"tabs={state['tabCount']} page={state['tabs'][0]['page']} "
                f"pixels={len(start_frame)}"
            )
            return 0
        finally:
            if surface is not None:
                surface.close()
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL browser mockup interaction: {error}", file=sys.stderr)
        raise SystemExit(1)
