import ctypes
import subprocess
import sys
import time
from ctypes import wintypes
from pathlib import Path

ROOT = Path(r"C:\Users\windows10\Documents\github_repositories\aurora-gui\aurora")
APP = ROOT / "apps" / "marching-cubes-terrain" / "build" / "marching-cubes-terrain.exe"
SHADERS = ROOT / "apps" / "marching-cubes-terrain" / "shaders3d"
TITLE = "Marching Cubes Terrain"
user32 = ctypes.windll.user32


def main():
    process = None
    try:
        process = subprocess.Popen(
            [str(APP), "--shaders", str(SHADERS), "--trace-hud"],
            cwd=str(APP.parent.parent),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        time.sleep(2.0)
        hwnds = []
        callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND,
            wintypes.LPARAM)

        def callback(hwnd, _):
            pid = wintypes.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            if pid.value == process.pid and user32.IsWindowVisible(hwnd):
                hwnds.append(hwnd)
            return True

        user32.EnumWindows(callback_type(callback), 0)
        if hwnds:
            hwnd = hwnds[0]
            user32.ShowWindow(hwnd, 9)
            user32.SetForegroundWindow(hwnd)
            user32.BringWindowToTop(hwnd)
        time.sleep(8.0)
        process.terminate()
        try:
            output = process.communicate(timeout=5)[0]
        except subprocess.TimeoutExpired:
            process.kill()
            output = process.communicate()[0]
        values = [
            float(line.split("hud fps=")[1])
            for line in output.splitlines() if "hud fps=" in line
        ]
        print(f"hud_windows={len(values)} values={values}", flush=True)
        if len(values) < 5:
            raise RuntimeError("not enough HUD windows captured")
        if min(values) < 60.0:
            raise RuntimeError(f"HUD window below 60 fps: {min(values)}")
        print(f"PASS HUD min={min(values):.2f} max={max(values):.2f}", flush=True)
        return 0
    except Exception as error:
        print(f"FAILED: {error}", flush=True)
        return 1
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(main())
