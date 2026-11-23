#!/usr/bin/env python3
"""Validate the already-running v2 host without launching any window or process."""
from __future__ import annotations

import ctypes
import json
import socket
from ctypes import wintypes

PORT = 8792
TITLE = "Aurora OpenCode Lite V2"
user32 = ctypes.WinDLL("user32", use_last_error=True)


def windows() -> list[tuple[int, str]]:
    result: list[tuple[int, str]] = []
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND,
                                        wintypes.LPARAM)

    def visit(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        length = user32.GetWindowTextLengthW(hwnd)
        if length:
            buffer = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, buffer, length + 1)
            result.append((hwnd, buffer.value))
        return True

    user32.EnumWindows(callback_type(visit), 0)
    return result


def request(sock, buffer, request_id, command):
    sock.sendall((json.dumps({"id": request_id, "command": command}) +
                  "\n").encode())
    while True:
        while b"\n" not in buffer:
            buffer += sock.recv(65536)
        line, buffer = buffer.split(b"\n", 1)
        text = line.decode(errors="replace")
        if text.startswith("RESPONSE "):
            response = json.loads(text[9:])
            if response.get("id") == request_id:
                return response, buffer


def main() -> int:
    visible = windows()
    found = [hwnd for hwnd, title in visible if title == TITLE]
    if len(found) != 1:
        raise RuntimeError(f"expected exactly one v2 window, found {len(found)}")
    console_windows = [title for _, title in visible
                       if "aurora-opencode-lite-v2-controller" in
                       title.lower()]
    if console_windows:
        raise RuntimeError(
            f"visible controller console window(s): {console_windows}")
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    try:
        tree, buffer = request(sock, b"", 1, "tree")
    finally:
        sock.close()
    nodes = {node["id"]: node for node in tree["nodes"]}
    required = ["lite-version", "lite-session", "lite-clear", "lite-retry",
                "lite-status", "lite-transcript", "lite-input", "lite-send"]
    missing = [node for node in required if node not in nodes]
    if missing:
        raise RuntimeError(f"missing v2 nodes: {missing}")
    if nodes["lite-version"].get("text") != "v2":
        raise RuntimeError("v2 version label is missing")
    if nodes["lite-session"].get("text", "").startswith("Session") is False:
        raise RuntimeError("v2 session label is missing")
    print(f"live v2 passed: one window, {len(nodes)} nodes, no helper window")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
