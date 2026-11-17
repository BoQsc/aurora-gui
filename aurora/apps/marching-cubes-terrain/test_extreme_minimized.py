import ctypes
import statistics
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
APP_SECONDS = 30
SAMPLE_SECONDS = 2.0

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
        [str(HOST), "--run", str(SCENE), "--minimized", "--no-activate"],
        cwd=str(HOST.parent),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
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
    app = None
    host = None
    rows = []
    try:
        foreground_before = user32.GetForegroundWindow()
        app = start_app()
        if not wait_for_surface():
            raise RuntimeError("surface did not appear")
        host = start_host()
        hwnd = wait_for_window()
        if not hwnd:
            raise RuntimeError("host window did not appear")
        time.sleep(1.0)
        minimized = bool(user32.IsIconic(hwnd))
        if not minimized:
            raise RuntimeError("host window is not minimized")

        for index in range(1, ITERATIONS + 1):
            start_sequence, start_read = surface_sequences()
            started = time.monotonic()
            time.sleep(SAMPLE_SECONDS)
            elapsed = time.monotonic() - started
            end_sequence, end_read = surface_sequences()
            producer_fps = (end_sequence - start_sequence) / elapsed
            host_fps = (end_read - start_read) / elapsed
            focus_preserved = foreground_before == user32.GetForegroundWindow()
            row = (index, minimized, focus_preserved, producer_fps, host_fps)
            rows.append(row)
            print(
                f"test={index} minimized={minimized} "
                f"focus_preserved={focus_preserved} "
                f"producer_fps={producer_fps:.2f} host_read_fps={host_fps:.2f}",
                flush=True,
            )

        producer = [row[3] for row in rows]
        host_values = [row[4] for row in rows]
        print(
            "summary "
            f"tests={len(rows)} "
            f"all_minimized={all(row[1] for row in rows)} "
            f"all_focus_preserved={all(row[2] for row in rows)} "
            f"producer_min={min(producer):.2f} "
            f"producer_max={max(producer):.2f} "
            f"host_min={min(host_values):.2f} "
            f"host_max={max(host_values):.2f}",
            flush=True,
        )
        return 0 if all(row[1] and row[2] and row[3] >= 60.0
            for row in rows) else 1
    except Exception as error:
        print(f"FAILED: {error}", flush=True)
        return 2
    finally:
        stop(app)
        stop(host)


if __name__ == "__main__":
    sys.exit(main())
