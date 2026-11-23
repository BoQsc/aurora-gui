#!/usr/bin/env python3
"""Verify the live host guards: no topmost pin, no external force-kill.

The test never touches the mouse or the foreground window. It starts its own
minimized, non-activating host windows, changes only their window style, and
opens the process with PROCESS_TERMINATE without calling TerminateProcess.
"""
from __future__ import annotations

import ctypes
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

APP = Path(__file__).resolve().parents[1]
HOST = APP / "build" / "aurora-opencode-lite-host.exe"
TITLE = "Host Guard Probe"
SCENE = {
    "schemaVersion": 2,
    "window": {
        "title": TITLE,
        "width": 640,
        "height": 360,
        "theme": "dark",
    },
    "root": {
        "id": "root",
        "type": "column",
        "padding": 20,
        "children": [
            {"id": "probe", "type": "label", "text": "guard probe"},
        ],
    },
}

EnumProc = ctypes.WINFUNCTYPE(
    ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32
user32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p,
                                             ctypes.POINTER(ctypes.c_ulong)]
user32.GetWindowThreadProcessId.restype = ctypes.c_ulong
user32.IsWindowVisible.argtypes = [ctypes.c_void_p]
user32.IsWindowVisible.restype = ctypes.c_bool
user32.GetWindowTextW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p,
                                  ctypes.c_int]
user32.GetWindowTextW.restype = ctypes.c_int
user32.EnumWindows.argtypes = [EnumProc, ctypes.c_void_p]
user32.EnumWindows.restype = ctypes.c_bool
user32.GetWindowLongPtrW.argtypes = [ctypes.c_void_p, ctypes.c_int]
user32.GetWindowLongPtrW.restype = ctypes.c_ssize_t
user32.SetWindowPos.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                ctypes.c_int, ctypes.c_uint]
user32.SetWindowPos.restype = ctypes.c_bool
kernel32.OpenProcess.argtypes = [ctypes.c_uint, ctypes.c_bool, ctypes.c_uint]
kernel32.OpenProcess.restype = ctypes.c_void_p
kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
kernel32.CloseHandle.restype = ctypes.c_bool
GWL_EXSTYLE = -20
WS_EX_TOPMOST = 0x00000008
HWND_TOPMOST = ctypes.c_void_p(-1)
SWP_NOSIZE = 0x0001
SWP_NOMOVE = 0x0002
SWP_NOACTIVATE = 0x0010
SWP_SHOWWINDOW = 0x0040
PROCESS_TERMINATE = 0x0001

def window_for(pid: int, timeout: float = 15.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        found = []

        def visit(hwnd, _):
            owner = ctypes.c_ulong()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
            if owner.value == pid and user32.IsWindowVisible(hwnd):
                text = ctypes.create_unicode_buffer(256)
                user32.GetWindowTextW(hwnd, text, len(text))
                if text.value == TITLE:
                    found.append(hwnd)
                    return False
            return True

        user32.EnumWindows(EnumProc(visit), None)
        if found:
            return found[0]
        time.sleep(0.05)
    raise RuntimeError("host window did not appear")


def control(port: int, command: str) -> dict:
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.sendall(json.dumps({"id": 1, "command": command}).encode() + b"\n")
        data = b""
        while b"\n" not in data:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    line = data.split(b"\n", 1)[0].decode()
    if line.startswith("RESPONSE "):
        return json.loads(line[9:])
    raise RuntimeError(f"unexpected control response: {line!r}")


def start(port: int, group: str | None, temp: Path):
    scene = temp / "guard.scene.json"
    scene.write_text(json.dumps(SCENE), encoding="utf-8")
    arguments = [str(HOST), "--scene", str(scene), "--external-controller",
                 "--listen", str(port), "--start-minimized", "--no-activate"]
    if group is not None:
        arguments += ["--instance-group", group]
    environment = os.environ.copy()
    environment["LOCALAPPDATA"] = str(temp)
    environment["APPDATA"] = str(temp)
    return subprocess.Popen(arguments, cwd=str(APP), env=environment,
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE, text=True)


def stop(process, port: int) -> str:
    try:
        control(port, "close")
    finally:
        process.wait(timeout=10)
    return process.stderr.read() if process.stderr is not None else ""


def main() -> int:
    if not HOST.is_file():
        raise RuntimeError(f"build the host first: {HOST}")

    with tempfile.TemporaryDirectory() as raw:
        temp = Path(raw)

        topmost = start(8797, "guard-topmost", temp)
        try:
            hwnd = window_for(topmost.pid)
            before = user32.GetWindowLongPtrW(hwnd, GWL_EXSTYLE)
            user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                                SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE |
                                SWP_SHOWWINDOW)
            time.sleep(0.35)
            after = user32.GetWindowLongPtrW(hwnd, GWL_EXSTYLE)
            if after & WS_EX_TOPMOST:
                raise RuntimeError(
                    f"host accepted a topmost pin: 0x{before:x} -> 0x{after:x}")
            errors = stop(topmost, 8797)
            if "injected pointer/keyboard input is disabled" not in errors:
                raise RuntimeError(
                    "host did not report the development input guard: " + errors)
            topmost = None
        finally:
            if topmost is not None and topmost.poll() is None:
                try:
                    control(8797, "close")
                except Exception:
                    pass
                topmost.wait(timeout=10)

        protected = start(8798, None, temp)
        try:
            window_for(protected.pid)
            handle = kernel32.OpenProcess(PROCESS_TERMINATE, False,
                                          protected.pid)
            if handle:
                kernel32.CloseHandle(handle)
                raise RuntimeError("protected host accepted PROCESS_TERMINATE")
            errors = stop(protected, 8798)
            if "live window protected from forced termination" not in errors:
                raise RuntimeError(
                    "host did not report the live-window guard: " + errors)
            protected = None
        finally:
            if protected is not None and protected.poll() is None:
                try:
                    control(8798, "close")
                except Exception:
                    pass
                protected.wait(timeout=10)

    print("host guards passed: topmost rejected, force-kill denied, "
          "injected input disabled, graceful close works")
    return 0


if __name__ == "__main__":
    sys.exit(main())
