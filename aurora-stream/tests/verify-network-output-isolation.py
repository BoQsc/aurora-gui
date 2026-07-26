#!/usr/bin/env python3
"""Prove that a stalled RTMP handshake cannot own the encoder thread.

Uses only localhost, synthetic A/V, FFmpeg and the Python standard library.
No stream keys or external network services are touched.
"""

from __future__ import annotations

import contextlib
import queue
import shutil
import socket
import subprocess
import threading
import time


class StalledRtmpServer:
    def __init__(self) -> None:
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = int(self.listener.getsockname()[1])
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def _run(self) -> None:
        self.listener.settimeout(0.2)
        connection: socket.socket | None = None
        try:
            while not self.stop_event.is_set():
                try:
                    connection, _ = self.listener.accept()
                    break
                except socket.timeout:
                    continue
            if connection is not None:
                connection.settimeout(0.2)
                # Accept TCP but never answer the RTMP handshake. This is the
                # exact stage at which a direct RTMP muxer blocks before it can
                # emit frame/out_time progress.
                while not self.stop_event.wait(0.2):
                    pass
        finally:
            if connection is not None:
                with contextlib.suppress(OSError):
                    connection.close()
            with contextlib.suppress(OSError):
                self.listener.close()

    def close(self) -> None:
        self.stop_event.set()
        with contextlib.suppress(OSError):
            self.listener.close()
        self.thread.join(timeout=1.0)


def ffmpeg_command(ffmpeg: str, url: str, fifo: bool) -> list[str]:
    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel", "warning",
        "-nostdin",
        "-stats_period", "0.25",
        "-progress", "pipe:2",
        "-re",
        "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=60",
        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
        "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-preset", "ultrafast",
        "-g", "120",
        "-c:a", "aac", "-ar", "48000", "-ac", "2",
    ]
    if fifo:
        command += [
            "-f", "fifo", "-fifo_format", "flv",
            "-queue_size", "1200",
            "-format_opts",
            "max_interleave_delta=0:flush_packets=1:flvflags=no_duration_filesize",
            "-attempt_recovery", "1",
            "-recovery_wait_time", "1",
            "-restart_with_keyframe", "1",
            url,
        ]
    else:
        command += ["-f", "flv", url]
    return command


def run_case(ffmpeg: str, fifo: bool, observe_seconds: float = 3.5) -> tuple[bool, str]:
    server = StalledRtmpServer()
    server.start()
    url = f"rtmp://127.0.0.1:{server.port}/app/local-test"
    process = subprocess.Popen(
        ffmpeg_command(ffmpeg, url, fifo),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    lines: queue.Queue[str] = queue.Queue()

    def read_stderr() -> None:
        assert process.stderr is not None
        for line in process.stderr:
            lines.put(line)

    reader = threading.Thread(target=read_stderr, daemon=True)
    reader.start()
    deadline = time.monotonic() + observe_seconds
    progress = False
    captured: list[str] = []
    try:
        while time.monotonic() < deadline:
            try:
                line = lines.get(timeout=0.05)
            except queue.Empty:
                if process.poll() is not None:
                    break
                continue
            captured.append(line)
            stripped = line.strip()
            if stripped.startswith("frame="):
                value = stripped.split("=", 1)[1].strip()
                if value and value != "0":
                    progress = True
                    break
            if stripped.startswith("out_time="):
                value = stripped.split("=", 1)[1].strip()
                if value not in ("", "N/A", "00:00:00.000000"):
                    progress = True
                    break
    finally:
        with contextlib.suppress(Exception):
            process.kill()
        with contextlib.suppress(Exception):
            process.wait(timeout=2.0)
        server.close()
        reader.join(timeout=0.5)
        while True:
            try:
                captured.append(lines.get_nowait())
            except queue.Empty:
                break
    return progress, "".join(captured)


def main() -> int:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise AssertionError("FFmpeg was not found on PATH")

    direct_progress, direct_log = run_case(ffmpeg, fifo=False)
    if direct_progress:
        raise AssertionError(
            "The direct RTMP control unexpectedly emitted progress while the "
            "server withheld the handshake; the test no longer isolates the stall.\n" +
            direct_log[-4000:]
        )

    fifo_progress, fifo_log = run_case(ffmpeg, fifo=True)
    if not fifo_progress:
        raise AssertionError(
            "The bounded FIFO path did not keep the encoder running while the "
            "RTMP handshake was stalled.\n" + fifo_log[-4000:]
        )

    print("Direct RTMP stalled before progress as expected.")
    print("Bounded FIFO RTMP isolation kept capture/encoding progressing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
