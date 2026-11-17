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
RUN_SECONDS = 90
SAMPLE_SECONDS = 5.0
SW_MAXIMIZE = 3

user32 = ctypes.windll.user32


def sequences():
    data = SURFACE.read_bytes()[:80]
    return struct.unpack_from("<Q", data, 32)[0], struct.unpack_from("<Q", data, 40)[0]


def wait_for_surface(timeout=8.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if SURFACE.exists():
            try:
                sequences()
                return True
            except OSError:
                pass
        time.sleep(0.05)
    return False


def wait_for_window(timeout=8.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        hwnd = user32.FindWindowW(None, TITLE)
        if hwnd and user32.IsWindowVisible(hwnd):
            return hwnd
        time.sleep(0.05)
    return 0


def stop(process):
    if process is None:
        return
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def main():
    app = None
    host = None
    try:
        app = subprocess.Popen(
            [
                str(APP), "--animate", "--test-motion", "--extreme-motion",
                "--shaders", str(SHADERS), "--surface", str(SURFACE),
                "--out", str(OUT), "--time", str(RUN_SECONDS + 10),
            ],
            cwd=str(APP.parent.parent),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if not wait_for_surface():
            raise RuntimeError("surface did not appear")
        host = subprocess.Popen(
            [str(HOST), "--run", str(SCENE)],
            cwd=str(HOST.parent),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        hwnd = wait_for_window()
        if not hwnd:
            raise RuntimeError("host window did not appear")
        time.sleep(0.5)
        for _ in range(10):
            user32.ShowWindow(hwnd, SW_MAXIMIZE)
            user32.SetForegroundWindow(hwnd)
            time.sleep(0.2)
            if user32.IsZoomed(hwnd):
                break
        if not user32.IsZoomed(hwnd):
            raise RuntimeError("host window did not maximize")
        print("maximized=True", flush=True)

        samples = []
        started = time.monotonic()
        previous = sequences()
        previous_time = started
        while True:
            time.sleep(SAMPLE_SECONDS)
            now = time.monotonic()
            current = sequences()
            elapsed = now - previous_time
            producer_fps = (current[0] - previous[0]) / elapsed
            host_fps = (current[1] - previous[1]) / elapsed
            samples.append((now - started, producer_fps, host_fps))
            print(
                f"t={now - started:.1f}s producer_fps={producer_fps:.2f} "
                f"host_read_fps={host_fps:.2f}",
                flush=True,
            )
            previous = current
            previous_time = now
            if now - started >= RUN_SECONDS:
                break

        producer = [row[1] for row in samples]
        host_values = [row[2] for row in samples]
        print(
            "summary "
            f"samples={len(samples)} "
            f"producer_min={min(producer):.2f} "
            f"producer_avg={statistics.mean(producer):.2f} "
            f"producer_max={max(producer):.2f} "
            f"host_min={min(host_values):.2f} "
            f"host_avg={statistics.mean(host_values):.2f} "
            f"host_max={max(host_values):.2f}",
            flush=True,
        )
        return 0 if min(producer) >= 60.0 and min(host_values) >= 60.0 else 1
    except Exception as error:
        print(f"FAILED: {error}", flush=True)
        return 2
    finally:
        stop(host)
        stop(app)


if __name__ == "__main__":
    sys.exit(main())
