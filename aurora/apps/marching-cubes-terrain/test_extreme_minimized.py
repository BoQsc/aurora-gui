import ctypes
import math
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(r"C:\Users\windows10\Documents\github_repositories\aurora-gui\aurora")
APP = ROOT / "apps" / "marching-cubes-terrain" / "build" / "marching-cubes-terrain.exe"
HOST = ROOT / "aurora-host" / "aurora-host.exe"
SCENE = ROOT / "apps" / "marching-cubes-terrain" / "terrain.scene.json"
SHADERS = ROOT / "apps" / "marching-cubes-terrain" / "shaders3d"
SURFACE = ROOT / "apps" / "marching-cubes-terrain" / "build" / "terrain-live.surface"
OUT = ROOT / "apps" / "marching-cubes-terrain" / "build" / "terrain-live.ppm"
TITLE = "Marching Cubes Terrain"
ITERATIONS = 8
APP_SECONDS = 8
SAMPLE_SECONDS = 2.0
SW_MINIMIZE = 6

user32 = ctypes.windll.user32


def surface_sequences():
    data = SURFACE.read_bytes()[:80]
    return struct.unpack_from("<Q", data, 32)[0], struct.unpack_from("<Q", data, 40)[0]


def wait_for_window(timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        hwnd = user32.FindWindowW(None, TITLE)
        if hwnd and user32.IsWindowVisible(hwnd):
            return hwnd
        time.sleep(0.05)
    return 0


def wait_for_surface(timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if SURFACE.exists():
            try:
                surface_sequences()
                return True
            except OSError:
                pass
        time.sleep(0.05)
    return False


def start_app():
    return subprocess.Popen(
        [
            str(APP), "--animate", "--test-motion", "--extreme-motion",
            "--shaders", str(SHADERS), "--surface", str(SURFACE),
            "--out", str(OUT), "--time", str(APP_SECONDS),
        ],
        cwd=str(APP.parent.parent),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def start_host():
    return subprocess.Popen(
        [str(HOST), "--run", str(SCENE), "--minimized"],
        cwd=str(HOST.parent),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def stop(process):
    if process is None:
        return
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def main():
    rows = []
    for index in range(1, ITERATIONS + 1):
        app = None
        host = None
        try:
            app = start_app()
            if not wait_for_surface():
                raise RuntimeError("surface did not appear")
            host = start_host()
            hwnd = wait_for_window()
            if not hwnd:
                raise RuntimeError("host window did not appear")
            time.sleep(0.5)
            for _ in range(20):
                user32.ShowWindow(hwnd, SW_MINIMIZE)
                user32.ShowWindowAsync(hwnd, SW_MINIMIZE)
                user32.PostMessageW(hwnd, 0x0112, 0xF020, 0)
                time.sleep(0.1)
                if user32.IsIconic(hwnd):
                    break
            time.sleep(1.0)
            time.sleep(1.0)
            minimized = bool(user32.IsIconic(hwnd))
            start_sequence, start_read = surface_sequences()
            sample_start = time.monotonic()
            time.sleep(SAMPLE_SECONDS)
            elapsed = time.monotonic() - sample_start
            end_sequence, end_read = surface_sequences()
            producer_fps = (end_sequence - start_sequence) / elapsed
            host_fps = (end_read - start_read) / elapsed
            row = (index, minimized, producer_fps, host_fps)
            rows.append(row)
            print(
                f"test={index} minimized={minimized} "
                f"producer_fps={producer_fps:.2f} host_read_fps={host_fps:.2f}",
                flush=True,
            )
        except Exception as error:
            print(f"test={index} FAILED: {error}", flush=True)
            rows.append((index, False, 0.0, 0.0))
        finally:
            stop(host)
            stop(app)

    producer_values = [row[2] for row in rows]
    host_values = [row[3] for row in rows]
    print(
        "summary "
        f"tests={len(rows)} "
        f"all_minimized={all(row[1] for row in rows)} "
        f"producer_min={min(producer_values):.2f} "
        f"producer_max={max(producer_values):.2f} "
        f"host_min={min(host_values):.2f} "
        f"host_max={max(host_values):.2f}",
        flush=True,
    )
    return 0 if all(row[1] and row[2] >= 60.0 for row in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
