import ctypes
import subprocess
import sys
import time
from ctypes import wintypes
from pathlib import Path

ROOT = Path(r"C:\Users\windows10\Documents\github_repositories\aurora-gui\aurora")
HOST = ROOT / "aurora-host" / "aurora-host.exe"
SCENE = ROOT / "apps" / "marching-cubes-terrain" / "terrain.scene.json"
TITLE = "Marching Cubes Terrain"
user32 = ctypes.windll.user32


def main():
    host = None
    try:
        before = user32.GetForegroundWindow()
        host = subprocess.Popen(
            [str(HOST), "--run", str(SCENE), "--minimized", "--no-activate"],
            cwd=str(HOST.parent),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        hwnd = 0
        for _ in range(100):
            hwnd = user32.FindWindowW(None, TITLE)
            if hwnd and user32.IsWindowVisible(hwnd):
                break
            time.sleep(0.05)
        if not hwnd:
            raise RuntimeError("host window did not appear")
        time.sleep(0.5)
        after = user32.GetForegroundWindow()
        print(
            f"before={before} after={after} "
            f"focus_preserved={before == after} "
            f"minimized={bool(user32.IsIconic(hwnd))}",
            flush=True,
        )
        return 0 if before == after and user32.IsIconic(hwnd) else 1
    except Exception as error:
        print(f"FAILED: {error}", flush=True)
        return 2
    finally:
        if host is not None and host.poll() is None:
            host.terminate()
            try:
                host.wait(timeout=5)
            except subprocess.TimeoutExpired:
                host.kill()
                host.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(main())
