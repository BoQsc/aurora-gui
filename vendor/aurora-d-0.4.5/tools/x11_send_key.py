#!/usr/bin/env python3
"""Send one key press/release through XTEST using only Python's standard library."""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import sys
import time


class X11Error(RuntimeError):
    pass


def load_library(name: str, fallback: str) -> ctypes.CDLL:
    path = ctypes.util.find_library(name) or fallback
    try:
        return ctypes.CDLL(path)
    except OSError as error:
        raise X11Error(f"could not load {name}: {error}") from error


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--window", required=True, help="X11 window ID, decimal or 0x-prefixed")
    parser.add_argument("key", help="X keysym name such as F11 or Escape")
    args = parser.parse_args()

    try:
        window = int(args.window, 0)
    except ValueError as error:
        raise X11Error(f"invalid X11 window ID: {args.window}") from error

    x11 = load_library("X11", "libX11.so.6")
    xtst = load_library("Xtst", "libXtst.so.6")

    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.restype = ctypes.c_int
    x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
    x11.XStringToKeysym.restype = ctypes.c_ulong
    x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    x11.XKeysymToKeycode.restype = ctypes.c_ubyte
    x11.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
    x11.XSetInputFocus.restype = ctypes.c_int
    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XFlush.restype = ctypes.c_int
    xtst.XTestFakeKeyEvent.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint,
        ctypes.c_int,
        ctypes.c_ulong,
    ]
    xtst.XTestFakeKeyEvent.restype = ctypes.c_int

    display = x11.XOpenDisplay(None)
    if not display:
        raise X11Error("could not connect to DISPLAY")
    try:
        keysym = x11.XStringToKeysym(args.key.encode("ascii"))
        if keysym == 0:
            raise X11Error(f"unknown X keysym: {args.key}")
        keycode = int(x11.XKeysymToKeycode(display, keysym))
        if keycode == 0:
            raise X11Error(f"the X server has no keycode for: {args.key}")

        # RevertToParent=2, CurrentTime=0. XTEST then injects normal key events
        # through the server rather than setting the SendEvent flag directly.
        x11.XSetInputFocus(display, ctypes.c_ulong(window), 2, 0)
        x11.XFlush(display)
        time.sleep(0.05)
        if not xtst.XTestFakeKeyEvent(display, keycode, 1, 0):
            raise X11Error(f"XTEST could not press {args.key}")
        if not xtst.XTestFakeKeyEvent(display, keycode, 0, 0):
            raise X11Error(f"XTEST could not release {args.key}")
        x11.XFlush(display)
    finally:
        x11.XCloseDisplay(display)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except X11Error as error:
        print(f"x11_send_key.py: {error}", file=sys.stderr)
        raise SystemExit(2)
