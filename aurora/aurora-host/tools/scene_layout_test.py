#!/usr/bin/env python3
"""Check explicit text-area sizing and scene minimum window size."""
from __future__ import annotations

import argparse
import ctypes
import json
import sys
import tempfile
from ctypes import wintypes
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
sys.path.insert(0, str(TOOLS))
import control_client  # noqa: E402

user32 = ctypes.WinDLL("user32", use_last_error=True)
SWP_NOMOVE = 0x0002
SWP_NOZORDER = 0x0004
SWP_NOACTIVATE = 0x0010


def window_for_pid(pid: int) -> int:
    found: list[int] = []
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND,
                                        wintypes.LPARAM)

    def visit(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd):
            found.append(hwnd)
        return True

    user32.EnumWindows(callback_type(visit), 0)
    if not found:
        raise RuntimeError(f"no visible window for host pid {pid}")
    return found[0]


def client_size(hwnd: int) -> tuple[int, int]:
    rect = wintypes.RECT()
    if not user32.GetClientRect(hwnd, ctypes.byref(rect)):
        raise RuntimeError("GetClientRect failed")
    return rect.right - rect.left, rect.bottom - rect.top


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, type=Path)
    args = parser.parse_args()
    control_client.EXE = args.host

    scene = {
        "schemaVersion": 2,
        "window": {
            "title": "Layout Contract Test",
            "width": 700,
            "height": 500,
            "minWidth": 500,
            "minHeight": 400,
            "theme": "dark",
        },
        "root": {
            "type": "column",
            "padding": 10,
            "spacing": 8,
            "children": [
                {
                    "id": "editor",
                    "type": "textArea",
                    "text": "fixed transcript\n",
                    "height": 120,
                },
                {
                    "id": "footer",
                    "type": "button",
                    "text": "Footer",
                    "action": "noop",
                },
            ],
        },
    }
    with tempfile.TemporaryDirectory(prefix="aurora-layout-") as directory:
        scene_path = Path(directory) / "layout.scene.json"
        scene_path.write_text(json.dumps(scene), encoding="utf-8")
        session = control_client.HostSession(str(scene_path))
        try:
            session.wait_ready()
            editor = session.send("getBounds", node="editor")["rect"]
            footer = session.send("getBounds", node="footer")["rect"]
            if editor["height"] != 120:
                raise RuntimeError(
                    f"textArea height was {editor['height']}, expected 120")
            if footer["y"] < editor["y"] + editor["height"]:
                raise RuntimeError(
                    f"footer overlapped the fixed transcript: {editor} / {footer}")
            hwnd = window_for_pid(session.process.pid)
            user32.SetWindowPos(hwnd, 0, 0, 0, 200, 150,
                                SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE)
            width, height = client_size(hwnd)
            if width < 500 or height < 400:
                raise RuntimeError(
                    f"minimum client size was {width}x{height}, expected >= 500x400")
            print(
                "scene layout passed: textArea height=120, footer visible, "
                f"minimum client={width}x{height}")
        finally:
            session.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
