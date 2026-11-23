#!/usr/bin/env python3
"""Verify the independent Aurora OpenCode Lite V2 target."""
from __future__ import annotations

import ctypes
import json
import os
import statistics
import struct
import subprocess
import sys
import time
from pathlib import Path

APP = Path(__file__).resolve().parent
AURORA = APP.parents[1]
DUB = os.environ.get("DUB", "dub")
COMPILER = os.environ.get("DC", "dmd")
PYTHON = sys.executable
EXE = APP / "build" / "aurora-opencode-lite-v2-standalone.exe"


def run(command: list[object], timeout: int = 1800) -> None:
    printable = " ".join(str(part) for part in command)
    print(f"+ {printable}", flush=True)
    subprocess.run([str(part) for part in command], cwd=APP,
                   check=True, timeout=timeout)


def standalone_running() -> bool:
    try:
        result = subprocess.run(
            ["tasklist", "/FI",
             "IMAGENAME eq aurora-opencode-lite-v2-standalone.exe",
             "/FO", "CSV", "/NH"],
            capture_output=True, timeout=30)
    except Exception:
        return False
    return b"aurora-opencode-lite-v2-standalone.exe" in result.stdout.lower()


def pe_layout(path: Path) -> tuple[int, int, int]:
    data = path.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    optional = pe + 24
    subsystem = struct.unpack_from("<H", data, optional + 68)[0]
    directory = optional + (112 if struct.unpack_from("<H", data, optional)[0]
                            == 0x20B else 96)
    resource_rva, resource_size = struct.unpack_from("<II", data, directory + 16)
    return subsystem, resource_rva, resource_size


def pe_imports(path: Path) -> list[str]:
    data = path.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    coff = pe + 4
    count = struct.unpack_from("<H", data, coff + 2)[0]
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    directory = optional + (112 if magic == 0x20B else 96)
    section_table = optional + (240 if magic == 0x20B else 224)
    import_rva = struct.unpack_from("<I", data, directory + 8)[0]
    if import_rva == 0:
        return []

    sections = []
    for index in range(count):
        entry = section_table + index * 40
        virtual_size, virtual_address, raw_size, raw_pointer = (
            struct.unpack_from("<IIII", data, entry + 8))
        sections.append((virtual_address, virtual_size, raw_pointer, raw_size))

    def rva_offset(rva: int) -> int:
        for virtual_address, virtual_size, raw_pointer, raw_size in sections:
            size = max(virtual_size, raw_size)
            if virtual_address <= rva < virtual_address + size:
                return raw_pointer + rva - virtual_address
        raise ValueError(f"RVA 0x{rva:x} is not in an image section")

    def c_string(rva: int) -> str:
        offset = rva_offset(rva)
        end = data.find(b"\0", offset)
        if end < 0:
            raise ValueError("unterminated import string")
        return data[offset:end].decode("ascii", "replace")

    names: list[str] = []
    descriptor = rva_offset(import_rva)
    while True:
        _, _, _, name_rva, _ = (
            struct.unpack_from("<IIIII", data, descriptor))
        if name_rva == 0:
            break
        names.append(c_string(name_rva).lower())
        descriptor += 20
    return sorted(set(names))


def icon_count(path: Path) -> int:
    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    shell32.ExtractIconExW.argtypes = [
        ctypes.c_wchar_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p,
        ctypes.c_uint,
    ]
    shell32.ExtractIconExW.restype = ctypes.c_uint
    return shell32.ExtractIconExW(str(path), -1, None, None, 0)


def main_window(pid: int):
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p,
                                       ctypes.c_void_p)
    user32.EnumWindows.argtypes = [callback_type, ctypes.c_void_p]
    user32.GetWindowThreadProcessId.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    user32.IsWindowVisible.argtypes = [ctypes.c_void_p]
    user32.GetWindowTextLengthW.argtypes = [ctypes.c_void_p]
    user32.GetWindowLongPtrW.argtypes = [ctypes.c_void_p, ctypes.c_int]
    user32.GetWindowLongPtrW.restype = ctypes.c_ssize_t
    found = []

    @callback_type
    def callback(hwnd, data):
        window_pid = ctypes.c_uint32()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(window_pid))
        if window_pid.value == pid and user32.IsWindowVisible(hwnd):
            style = user32.GetWindowLongPtrW(hwnd, -16)
            if style & 0x00C00000 and user32.GetWindowTextLengthW(hwnd) > 0:
                found.append(hwnd)
                return False
        return True

    user32.EnumWindows(callback, None)
    return found[0] if found else None


def warm_startup_ms() -> list[float]:
    values: list[float] = []
    # One untimed warm-up; then five runs.
    for index in range(6):
        started = time.perf_counter()
        process = subprocess.Popen(
            [str(EXE), "--instance-group", "verify-startup"], cwd=APP,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL)
        hwnd = None
        deadline = started + 20
        while time.perf_counter() < deadline and process.poll() is None:
            hwnd = main_window(process.pid)
            if hwnd is not None:
                break
            time.sleep(0.005)
        elapsed = (time.perf_counter() - started) * 1000
        if hwnd is None:
            raise RuntimeError("Lite did not create a titled window")
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        if index > 0:
            values.append(elapsed)
    return values


def main() -> int:
    source = (APP / "source" / "hostlite.d").read_text(encoding="utf-8")
    if "GuiWindow" in source or "LiteShell" in source:
        raise RuntimeError("host-lite still constructs its own GUI")
    scene = json.loads((APP / "assets" / "lite.scene.json").read_text(
        encoding="utf-8"))
    scene_text = json.dumps(scene)
    for required in ("lite-transcript", "lite-send", "lite-input",
                     "lite-status", "lite-provider-opencode",
                     "lite-provider-openai", "lite-key-state"):
        if required not in scene_text:
            raise RuntimeError(f"host scene is missing {required}")
    if "lite-stop" in scene_text:
        raise RuntimeError("host scene still has the separate lite-stop button")

    live = "--live" in sys.argv
    full = "--full" in sys.argv
    if live and full:
        raise RuntimeError("choose either --live or --full")
    if standalone_running():
        if full:
            raise RuntimeError(
                "standalone is running; full verification would rebuild the "
                "locked EXE. Use `python verify.py` for the live check, or "
                "stop the host at an explicit restart point.")
        if not live:
            print("standalone running; selecting the live check "
                  "(controller DLL + scene only).", flush=True)
            live = True

    if live:
        # Live workflow: update the controller DLL and validate the scene, but
        # never rebuild the locked standalone EXE or disturb the running host.
        run([DUB, "build", "--config=plugin", f"--compiler={COMPILER}"])
        print("Lite live check passed: controller DLL rebuilt and scene "
              "validated; running host untouched.")
        return 0

    run([DUB, "build", "--config=http-smoke", f"--compiler={COMPILER}"])
    run([DUB, "build", "--config=session-smoke", f"--compiler={COMPILER}"])
    run([DUB, "build", "--config=live-smoke", f"--compiler={COMPILER}"])
    run([PYTHON, "-B", "tests/run_http_smoke.py"])
    run([PYTHON, "-B", "tests/run_session_smoke.py"])
    run([PYTHON, "-B", "tests/run_live_smoke.py"])
    run([DUB, "build", "--config=host-lite", f"--compiler={COMPILER}"])
    run([DUB, "build", "--config=controller", f"--compiler={COMPILER}"])
    run([PYTHON, "-B", "tests/run_external_controller_test.py"])
    run([PYTHON, "-B", "tests/run_external_failure_test.py"])
    run([PYTHON, "-B", "tests/run_single_instance_test.py"])
    run([PYTHON, "-B", "tests/run_intentional_duplicate_test.py"])
    run([PYTHON, "-B", "tests/run_run_journal_test.py"])
    run([PYTHON, "-B", "tests/run_controller_supervisor_test.py"])
    run([PYTHON, "-B", "tests/run_command_menu_test.py"])
    run([PYTHON, "-B", "tests/run_minimized_control_test.py"])
    run([PYTHON, "-B", "tests/run_enter_submit_test.py"])
    run([DUB, "build", "--config=host-cli", f"--compiler={COMPILER}"])
    run([PYTHON, "-B", "tests/run_cli_control_test.py"])
    run([DUB, "build", "--config=plugin", f"--compiler={COMPILER}"])
    run([DUB, "build", "--config=plugin-smoke", f"--compiler={COMPILER}"])
    run([DUB, "build", "--config=plugin-reload-test",
         f"--compiler={COMPILER}"])
    run([str(APP / "build" / "aurora-opencode-lite-v2-plugin-smoke.exe"),
         "assets/lite.scene.json", "build/opencode-lite-v2-controller.dll"])
    run([str(APP / "build" / "aurora-opencode-lite-v2-plugin-reload-test.exe"),
         "assets/lite.scene.json", "build/opencode-lite-v2-controller.dll"])
    run([PYTHON, "-B", "tests/run_scene_recovery_test.py"])
    run([PYTHON, "-B", "tools/build_standalone.py"])

    size = EXE.stat().st_size
    subsystem, resource_rva, resource_size = pe_layout(EXE)
    imports = pe_imports(EXE)
    icons = icon_count(EXE)
    if size > 8 * 1024 * 1024:
        raise RuntimeError(f"Lite EXE is too large: {size} bytes")
    if subsystem != 2:
        raise RuntimeError(f"Lite EXE subsystem is {subsystem}, expected 2")
    if resource_rva == 0 or resource_size == 0 or icons == 0:
        raise RuntimeError("Lite EXE has no extractable icon resource")
    forbidden = [name for name in imports if name.startswith(
        ("msvcrt", "msvcr", "ucrt", "vcruntime", "api-ms-win-crt"))]
    if forbidden:
        raise RuntimeError("Lite imports a Microsoft CRT: " + ", ".join(forbidden))
    allowed = {"advapi32.dll", "avrt.dll", "gdi32.dll", "kernel32.dll",
               "ole32.dll", "shell32.dll", "user32.dll", "winhttp.dll",
               "winmm.dll", "ws2_32.dll"}
    unexpected = sorted(set(imports) - allowed)
    if unexpected:
        raise RuntimeError("Lite has unexpected imports: " + ", ".join(unexpected))

    startup = warm_startup_ms()
    median = statistics.median(startup)
    if median > 250.0:
        raise RuntimeError(f"Lite warm startup is {median:.1f} ms, expected <=250")
    print(f"Lite: {size} bytes, subsystem 2, icon 1, imports {', '.join(imports)}")
    print(f"Lite startup: median {median:.1f} ms "
          f"({', '.join(f'{value:.1f}' for value in startup)})")
    print("Aurora OpenCode Lite V2 verification passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
