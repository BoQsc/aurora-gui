#!/usr/bin/env python3
"""Background-only integration check for Aurora's VLC live preview.

The check never focuses, moves, or resizes VLC. It launches an isolated copy
of Aurora without activation, deliberately supplies the historically broken
VLC + game-capture setting, and verifies that Aurora persists compositor
capture instead. The Aurora window is captured through FFmpeg gfxcapture so
the resulting PNG proves what the live-source canvas actually displayed.
"""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


CREATE_NO_WINDOW = 0x08000000
SW_SHOWMINNOACTIVE = 7
SW_SHOWNOACTIVATE = 4
SWP_NOMOVE = 0x0002
SWP_NOSIZE = 0x0001
SWP_NOACTIVATE = 0x0010
WM_CLOSE = 0x0010
HWND_BOTTOM = 1


def windows() -> list[dict[str, object]]:
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    rows: list[dict[str, object]] = []

    callback_type = ctypes.WINFUNCTYPE(
        wintypes.BOOL, wintypes.HWND, wintypes.LPARAM
    )

    @callback_type
    def visit(hwnd: int, _lparam: int) -> bool:
        if not user32.IsWindowVisible(hwnd):
            return True
        length = user32.GetWindowTextLengthW(hwnd)
        if length <= 0:
            return True
        title = ctypes.create_unicode_buffer(length + 1)
        user32.GetWindowTextW(hwnd, title, length + 1)
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        process = ""
        handle = kernel32.OpenProcess(0x1000, False, pid.value)
        if handle:
            try:
                capacity = wintypes.DWORD(32768)
                path = ctypes.create_unicode_buffer(capacity.value)
                if kernel32.QueryFullProcessImageNameW(
                    handle, 0, path, ctypes.byref(capacity)
                ):
                    process = Path(path.value).name
            finally:
                kernel32.CloseHandle(handle)
        rows.append(
            {
                "hwnd": int(hwnd),
                "pid": int(pid.value),
                "title": title.value,
                "process": process,
            }
        )
        return True

    user32.EnumWindows(visit, 0)
    return rows


def wait_for_window(pid: int, timeout: float = 30.0) -> dict[str, object]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for row in windows():
            if row["pid"] == pid:
                return row
        time.sleep(0.25)
    raise RuntimeError(f"Aurora process {pid} did not create a visible window")


def window_pid(hwnd: int) -> int:
    pid = wintypes.DWORD()
    ctypes.windll.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return int(pid.value)


def capture_window(ffmpeg: Path, hwnd: int, output: Path, env: dict[str, str]) -> None:
    source = (
        f"gfxcapture=hwnd={hwnd}:capture_cursor=0:capture_border=0:"
        "display_border=0:max_framerate=1:output_fmt=bgra"
    )
    result = subprocess.run(
        [
            str(ffmpeg),
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-f",
            "lavfi",
            "-i",
            source,
            "-vf",
            "hwdownload,format=bgra",
            "-frames:v",
            "1",
            str(output),
        ],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
    )
    if result.returncode != 0 or not output.exists():
        raise RuntimeError(
            "Could not capture Aurora integration window: "
            + result.stderr.strip()
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--aurora", required=True, type=Path)
    parser.add_argument("--ffmpeg-bin", required=True, type=Path)
    parser.add_argument("--work-dir", required=True, type=Path)
    parser.add_argument("--vlc-pid", type=int)
    parser.add_argument(
        "--compare-preview",
        action="store_true",
        help="Compare Aurora's canvas with a direct VLC compositor frame (use static media)",
    )
    parser.add_argument(
        "--expect-minimized",
        action="store_true",
        help="Verify the explicit timeout/blank-canvas behavior for a minimized VLC window",
    )
    parser.add_argument("--settle-seconds", type=float, default=12.0)
    args = parser.parse_args()

    if sys.platform != "win32":
        raise RuntimeError("This integration check requires Windows")
    ffmpeg = args.ffmpeg_bin / "ffmpeg.exe"
    ffprobe = args.ffmpeg_bin / "ffprobe.exe"
    if not args.aurora.is_file() or not ffmpeg.is_file() or not ffprobe.is_file():
        raise RuntimeError("Aurora, ffmpeg.exe, or ffprobe.exe is missing")

    vlc = next(
        (
            row
            for row in windows()
            if str(row["process"]).lower() == "vlc.exe"
            and (args.vlc_pid is None or row["pid"] == args.vlc_pid)
        ),
        None,
    )
    if vlc is None:
        raise RuntimeError("Open a non-minimized VLC window before running this check")
    vlc_minimized = bool(ctypes.windll.user32.IsIconic(int(vlc["hwnd"])))
    if vlc_minimized and not args.expect_minimized:
        raise RuntimeError(
            f"VLC HWND {vlc['hwnd']} is minimized; compositor capture cannot "
            "validate a minimized window"
        )
    if args.expect_minimized and not vlc_minimized:
        raise RuntimeError("--expect-minimized was supplied for a non-minimized VLC window")
    if args.compare_preview and args.expect_minimized:
        raise RuntimeError("A minimized window has no live frame to compare")

    work_dir = args.work_dir.resolve()
    work_dir.mkdir(parents=True, exist_ok=True)
    isolated_aurora = work_dir / "aurora-stream-preview-test.exe"
    shutil.copy2(args.aurora.resolve(), isolated_aurora)
    settings_path = work_dir / "aurora-stream-settings.json"
    settings_path.write_text(
        json.dumps(
            {
                "schemaVersion": 9,
                "windowCaptureHwnd": str(vlc["hwnd"]),
                "windowCaptureLabel": (
                    f"vlc.exe — {vlc['title']}"
                ),
                "windowContentCapture": False,
                "gameCaptureMode": True,
                "liveSourcePreviewEnabled": True,
                "twitchEnabled": False,
                "youtubeEnabled": False,
                "desktopAudioEnabled": False,
                "minimizeToTrayOnStart": False,
                "closeToTray": False,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    env = os.environ.copy()
    env["PATH"] = str(args.ffmpeg_bin.resolve()) + os.pathsep + env.get("PATH", "")
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = SW_SHOWMINNOACTIVE
    foreground_before = int(ctypes.windll.user32.GetForegroundWindow())
    process = subprocess.Popen(
        [str(isolated_aurora), "--portable-config"],
        cwd=work_dir,
        env=env,
        startupinfo=startup,
        creationflags=CREATE_NO_WINDOW,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    app_window: dict[str, object] | None = None
    foreground_samples: list[dict[str, int]] = []
    try:
        app_window = wait_for_window(process.pid)
        hwnd = int(app_window["hwnd"])
        user32 = ctypes.windll.user32

        def sample_foreground() -> None:
            foreground = int(user32.GetForegroundWindow())
            owner_pid = window_pid(foreground)
            sample = {"hwnd": foreground, "pid": owner_pid}
            if not foreground_samples or foreground_samples[-1] != sample:
                foreground_samples.append(sample)
            if owner_pid == process.pid:
                raise RuntimeError(
                    "Background preview check activated the Aurora test window"
                )

        sample_foreground()
        user32.ShowWindowAsync(hwnd, SW_SHOWNOACTIVATE)
        user32.SetWindowPos(
            hwnd,
            HWND_BOTTOM,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
        )
        settle_deadline = time.monotonic() + args.settle_seconds
        while time.monotonic() < settle_deadline:
            time.sleep(min(0.25, settle_deadline - time.monotonic()))
            sample_foreground()

        saved = json.loads(settings_path.read_text(encoding="utf-8-sig"))
        if saved.get("gameCaptureMode") is not False:
            raise RuntimeError("Aurora did not disable Game Capture for VLC")
        if saved.get("windowContentCapture") is not False:
            raise RuntimeError("Aurora did not disable PrintWindow for VLC")
        if saved.get("windowCaptureHwnd") != str(vlc["hwnd"]):
            raise RuntimeError("Aurora unexpectedly changed the selected VLC HWND")

        screenshot = work_dir / "aurora-vlc-live-preview.png"
        capture_window(ffmpeg, hwnd, screenshot, env)
        preview_mae: float | None = None
        if args.expect_minimized:
            activity = (work_dir / "aurora-stream-activity.log").read_text(
                encoding="utf-8", errors="replace"
            )
            if "Windows Graphics Capture preview timed out" not in activity:
                raise RuntimeError(
                    "Aurora did not report the minimized-window preview timeout"
                )
        elif args.compare_preview:
            from PIL import Image, ImageChops, ImageStat

            direct = work_dir / "vlc-direct.png"
            capture_window(ffmpeg, int(vlc["hwnd"]), direct, env)
            app_image = Image.open(screenshot).convert("RGB")
            direct_image = Image.open(direct).convert("RGB")
            app_width, app_height = app_image.size
            canvas = app_image.crop(
                (
                    round(app_width * 0.465),
                    round(app_height * 0.146667),
                    round(app_width * 0.98),
                    round(app_height * 0.622565),
                )
            )
            scaled_width = min(
                canvas.width,
                round(canvas.height * direct_image.width / direct_image.height),
            )
            expected = Image.new("RGB", canvas.size)
            expected.paste(
                direct_image.resize(
                    (scaled_width, canvas.height), Image.Resampling.BILINEAR
                ),
                (0, 0),
            )
            difference = ImageStat.Stat(ImageChops.difference(canvas, expected))
            preview_mae = sum(difference.mean) / 3.0
            if preview_mae > 10.0:
                raise RuntimeError(
                    f"Aurora canvas differs from direct VLC capture (MAE {preview_mae:.3f})"
                )
        probe = subprocess.run(
            [
                str(ffprobe),
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=width,height,pix_fmt",
                "-of",
                "json",
                str(screenshot),
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
            check=True,
        )
        metadata = json.loads(probe.stdout)["streams"][0]
        sample_foreground()
        foreground_after = int(user32.GetForegroundWindow())
        print(
            json.dumps(
                {
                    "status": "passed",
                    "vlc": vlc,
                    "aurora": app_window,
                    "screenshot": str(screenshot),
                    "screenshot_stream": metadata,
                    "gameCaptureMode": saved["gameCaptureMode"],
                    "windowContentCapture": saved["windowContentCapture"],
                    "vlc_minimized": vlc_minimized,
                    "preview_mean_absolute_error": preview_mae,
                    "foreground_before": foreground_before,
                    "foreground_after": foreground_after,
                    "foreground_unchanged": foreground_before == foreground_after,
                    "foreground_samples": foreground_samples,
                    "aurora_activated": False,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0
    finally:
        if app_window is not None:
            ctypes.windll.user32.PostMessageW(int(app_window["hwnd"]), WM_CLOSE, 0, 0)
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
