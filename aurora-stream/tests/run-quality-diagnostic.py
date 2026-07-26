#!/usr/bin/env python3
"""Aurora Stream deterministic one-click video/audio quality diagnostic.

Standard-library only.  It drives a synchronized FFplay test card, exercises
multiple local capture/encode/audio paths, decodes every result, and writes one
report with video cadence, audio continuity, A/V sync, helper metrics, and
resource usage.  No stream keys or internet destinations are used.
"""

from __future__ import annotations

import argparse
import array
import contextlib
import ctypes
import dataclasses
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from typing import Iterable

CAPTURE_SECONDS = 12
SYNTHETIC_SECONDS = 6
FPS = 60.0
SAMPLE_RATE = 48_000
# Exact decoded hashes alone can miss a source-frame repeat after lossy H.264
# reconstruction. Downscaled adjacent frames at or below this mean absolute
# luma difference are therefore counted as visually repeated images.
NEAR_DUPLICATE_LUMA_MAD = 0.75
NEAR_DUPLICATE_MEDIAN_RATIO = 0.20
DIFFERENCE_WIDTH = 160
DIFFERENCE_HEIGHT = 90
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0
CREATE_NEW_PROCESS_GROUP = 0x00000200 if os.name == "nt" else 0
ROOT = Path(__file__).resolve().parents[1]
REPORT_PATH = ROOT / "aurora-stream-quality-diagnostic.txt"
AUDIO_REPORT_PATH = ROOT / "aurora-stream-audio-quality-diagnostic.txt"
LOADED_AUDIO_REPORT_PATH = ROOT / "aurora-stream-loaded-audio-diagnostic.txt"
ARTIFACTS = ROOT / "quality-diagnostic-artifacts"

AUDIO_TEST_SOURCE = (
    "aevalsrc='0.12*sin(2*PI*997*t)+"
    "if(lt(mod(t\\,1)\\,0.02)\\,0.75*sin(2*PI*4000*t)\\,0)':"
    "s=48000:c=stereo"
)

TEST_GRAPH = (
    # Generate the moving pattern at 640x360 and use nearest-neighbour scaling.
    # A native 1080p testsrc2 consumed nearly an entire CPU on the target PC,
    # starving its own audio renderer and invalidating later capture phases.
    "testsrc2=size=640x360:rate=60,"
    "scale=1920:1080:flags=neighbor,"
    "drawbox=x=0:y=0:w=240:h=240:color=black:t=fill,"
    "drawbox=x=0:y=0:w=240:h=240:color=white:t=fill:"
    "enable='lt(mod(t,1),0.05)'[out0];"
    + AUDIO_TEST_SOURCE + "[out1]"
)


class Report:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.lines: list[str] = []

    def line(self, value: str = "") -> None:
        self.lines.append(value)
        print(value, flush=True)

    def section(self, title: str) -> None:
        self.line()
        self.line(title)
        self.line("=" * len(title))

    def save(self) -> None:
        self.path.write_text("\n".join(self.lines) + "\n", encoding="utf-8")


@dataclasses.dataclass
class ReservedPair:
    rtp: socket.socket
    rtcp: socket.socket
    rtp_port: int
    rtcp_port: int

    def close(self) -> None:
        for item in (self.rtp, self.rtcp):
            with contextlib.suppress(OSError):
                item.close()


@dataclasses.dataclass
class Helper:
    process: subprocess.Popen[str]
    status_path: Path
    stop_path: Path
    metrics_path: Path
    stdout_path: Path
    stderr_path: Path
    stdout_file: object
    stderr_file: object
    port: int
    rtcp_port: int


@dataclasses.dataclass
class ResourceSummary:
    system_cpu_avg: float | None = None
    system_cpu_max: float | None = None
    ffmpeg_cpu_avg: float | None = None
    ffmpeg_cpu_max: float | None = None
    helper_cpu_avg: float | None = None
    helper_cpu_max: float | None = None
    ffmpeg_memory_max_mb: float | None = None
    helper_memory_max_mb: float | None = None
    gpu_avg: float | None = None
    gpu_max: float | None = None
    gpu_power_avg_w: float | None = None
    gpu_power_max_w: float | None = None
    gpu_temp_max_c: float | None = None


@dataclasses.dataclass
class VideoResult:
    valid: bool = False
    frames: int = 0
    width: int = 0
    height: int = 0
    duration: float = 0.0
    unique_rate: float = 0.0
    duplicates: int = 0
    exact_duplicates: int = 0
    duplicate_ratio: float = 0.0
    longest_run: int = 0
    minimum_adjacent_luma_mad: float = 0.0
    duplicate_luma_threshold: float = 0.0
    interval_max_ms: float = 0.0
    interval_p99_ms: float = 0.0
    flash_times: list[float] = dataclasses.field(default_factory=list)
    flash_interval_jitter_ms: float = 0.0
    error: str = ""


@dataclasses.dataclass
class AudioResult:
    valid: bool = False
    duration: float = 0.0
    median_rms: float = 0.0
    dropout_windows: int = 0
    longest_dropout_ms: float = 0.0
    clipped_samples: int = 0
    phase_jumps: int = 0
    maximum_phase_error: float = 0.0
    marker_times: list[float] = dataclasses.field(default_factory=list)
    marker_interval_jitter_ms: float = 0.0
    error: str = ""


@dataclasses.dataclass
class SyncResult:
    valid: bool = False
    matches: int = 0
    median_offset_ms: float = 0.0
    jitter_ms: float = 0.0
    drift_ms: float = 0.0
    maximum_error_ms: float = 0.0
    error: str = ""


@dataclasses.dataclass
class PhaseResult:
    name: str
    description: str
    output: Path
    command: list[str]
    expected_size: tuple[int, int] | None = None
    secondary_output: Path | None = None
    secondary_expected_size: tuple[int, int] | None = None
    returncode: int | None = None
    timed_out: bool = False
    wall_seconds: float = 0.0
    stderr: str = ""
    queue_warnings: int = 0
    progress_frames: int = 0
    final_speed: float = 0.0
    average_settled_speed: float = 0.0
    helper_metrics: str = ""
    helper_status: str = ""
    resources: ResourceSummary = dataclasses.field(default_factory=ResourceSummary)
    video: VideoResult = dataclasses.field(default_factory=VideoResult)
    secondary_video: VideoResult = dataclasses.field(default_factory=VideoResult)
    audio: AudioResult = dataclasses.field(default_factory=AudioResult)
    sync: SyncResult = dataclasses.field(default_factory=SyncResult)
    failure: str = ""


# Windows resource sampling -------------------------------------------------

if os.name == "nt":
    from ctypes import wintypes

    class FILETIME(ctypes.Structure):
        _fields_ = [("dwLowDateTime", wintypes.DWORD),
                    ("dwHighDateTime", wintypes.DWORD)]

    class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
        _fields_ = [
            ("cb", wintypes.DWORD),
            ("PageFaultCount", wintypes.DWORD),
            ("PeakWorkingSetSize", ctypes.c_size_t),
            ("WorkingSetSize", ctypes.c_size_t),
            ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
            ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
            ("PagefileUsage", ctypes.c_size_t),
            ("PeakPagefileUsage", ctypes.c_size_t),
        ]

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.GetProcessTimes.argtypes = [wintypes.HANDLE, ctypes.POINTER(FILETIME),
                                         ctypes.POINTER(FILETIME), ctypes.POINTER(FILETIME),
                                         ctypes.POINTER(FILETIME)]
    kernel32.GetProcessTimes.restype = wintypes.BOOL
    kernel32.GetSystemTimes.argtypes = [ctypes.POINTER(FILETIME), ctypes.POINTER(FILETIME),
                                        ctypes.POINTER(FILETIME)]
    kernel32.GetSystemTimes.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESS_MEMORY_COUNTERS),
                                           wintypes.DWORD]
    psapi.GetProcessMemoryInfo.restype = wintypes.BOOL
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    PROCESS_VM_READ = 0x0010

    def ft_value(value: FILETIME) -> int:
        return (value.dwHighDateTime << 32) | value.dwLowDateTime

    def system_times() -> tuple[int, int, int] | None:
        idle = FILETIME(); kernel = FILETIME(); user = FILETIME()
        if not kernel32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kernel),
                                       ctypes.byref(user)):
            return None
        return ft_value(idle), ft_value(kernel), ft_value(user)

    def open_process(pid: int):
        return kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ,
                                    False, pid)

    def process_times(handle) -> int | None:
        if not handle:
            return None
        creation = FILETIME(); exit_time = FILETIME(); kernel = FILETIME(); user = FILETIME()
        if not kernel32.GetProcessTimes(handle, ctypes.byref(creation),
                                        ctypes.byref(exit_time), ctypes.byref(kernel),
                                        ctypes.byref(user)):
            return None
        return ft_value(kernel) + ft_value(user)

    def process_memory(handle) -> float | None:
        if not handle:
            return None
        counters = PROCESS_MEMORY_COUNTERS()
        counters.cb = ctypes.sizeof(counters)
        if not psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
            return None
        return counters.WorkingSetSize / (1024.0 * 1024.0)

    def close_handle(handle) -> None:
        if handle:
            kernel32.CloseHandle(handle)
else:
    def system_times():
        return None
    def open_process(pid: int):
        return None
    def process_times(handle):
        return None
    def process_memory(handle):
        return None
    def close_handle(handle) -> None:
        return None


class ResourceSampler:
    def __init__(self, ffmpeg_pid: int, helper_pid: int | None) -> None:
        self.ffmpeg_handle = open_process(ffmpeg_pid)
        self.helper_handle = open_process(helper_pid) if helper_pid else None
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.system_values: list[float] = []
        self.ffmpeg_values: list[float] = []
        self.helper_values: list[float] = []
        self.ffmpeg_memory: list[float] = []
        self.helper_memory: list[float] = []
        self.gpu_values: list[float] = []
        self.gpu_power: list[float] = []
        self.gpu_temp: list[float] = []

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> ResourceSummary:
        self.stop_event.set()
        self.thread.join(timeout=3)
        close_handle(self.ffmpeg_handle)
        close_handle(self.helper_handle)
        return ResourceSummary(
            system_cpu_avg=mean_or_none(self.system_values),
            system_cpu_max=max_or_none(self.system_values),
            ffmpeg_cpu_avg=mean_or_none(self.ffmpeg_values),
            ffmpeg_cpu_max=max_or_none(self.ffmpeg_values),
            helper_cpu_avg=mean_or_none(self.helper_values),
            helper_cpu_max=max_or_none(self.helper_values),
            ffmpeg_memory_max_mb=max_or_none(self.ffmpeg_memory),
            helper_memory_max_mb=max_or_none(self.helper_memory),
            gpu_avg=mean_or_none(self.gpu_values),
            gpu_max=max_or_none(self.gpu_values),
            gpu_power_avg_w=mean_or_none(self.gpu_power),
            gpu_power_max_w=max_or_none(self.gpu_power),
            gpu_temp_max_c=max_or_none(self.gpu_temp),
        )

    def _run(self) -> None:
        cores = max(1, os.cpu_count() or 1)
        previous_wall = time.monotonic()
        previous_system = system_times()
        previous_ffmpeg = process_times(self.ffmpeg_handle)
        previous_helper = process_times(self.helper_handle)
        gpu_tick = 0
        while not self.stop_event.wait(0.5):
            now = time.monotonic()
            wall = now - previous_wall
            current_system = system_times()
            current_ffmpeg = process_times(self.ffmpeg_handle)
            current_helper = process_times(self.helper_handle)
            if previous_system and current_system:
                idle_delta = current_system[0] - previous_system[0]
                total_delta = ((current_system[1] - previous_system[1]) +
                               (current_system[2] - previous_system[2]))
                if total_delta > 0:
                    self.system_values.append(max(0.0, min(100.0,
                        100.0 * (total_delta - idle_delta) / total_delta)))
            if previous_ffmpeg is not None and current_ffmpeg is not None and wall > 0:
                self.ffmpeg_values.append(max(0.0,
                    (current_ffmpeg - previous_ffmpeg) / 10_000_000.0 / wall / cores * 100.0))
            if previous_helper is not None and current_helper is not None and wall > 0:
                self.helper_values.append(max(0.0,
                    (current_helper - previous_helper) / 10_000_000.0 / wall / cores * 100.0))
            ffmem = process_memory(self.ffmpeg_handle)
            hmem = process_memory(self.helper_handle)
            if ffmem is not None: self.ffmpeg_memory.append(ffmem)
            if hmem is not None: self.helper_memory.append(hmem)
            if gpu_tick % 2 == 0:
                self._sample_gpu()
            gpu_tick += 1
            previous_wall = now
            previous_system = current_system
            previous_ffmpeg = current_ffmpeg
            previous_helper = current_helper

    def _sample_gpu(self) -> None:
        if shutil.which("nvidia-smi") is None:
            return
        command = [
            "nvidia-smi",
            "--query-gpu=utilization.gpu,power.draw,temperature.gpu",
            "--format=csv,noheader,nounits",
        ]
        try:
            completed = subprocess.run(command, capture_output=True, text=True,
                                       timeout=2, creationflags=CREATE_NO_WINDOW)
            if completed.returncode != 0:
                return
            fields = [field.strip() for field in completed.stdout.splitlines()[0].split(",")]
            if len(fields) >= 3:
                self.gpu_values.append(float(fields[0]))
                self.gpu_power.append(float(fields[1]))
                self.gpu_temp.append(float(fields[2]))
        except (OSError, ValueError, subprocess.SubprocessError, IndexError):
            return


def mean_or_none(values: list[float]) -> float | None:
    return statistics.fmean(values) if values else None


def max_or_none(values: list[float]) -> float | None:
    return max(values) if values else None


def fmt(value: float | None, suffix: str = "", digits: int = 2) -> str:
    return "N/A" if value is None else f"{value:.{digits}f}{suffix}"


def command_text(command: Iterable[str]) -> str:
    return subprocess.list2cmdline(list(command))


def run_checked(command: list[str], timeout: float = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=str(ROOT), capture_output=True, text=True,
                          timeout=timeout, creationflags=CREATE_NO_WINDOW)


def reserve_pair() -> ReservedPair:
    for _ in range(256):
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.set_inheritable(False)
        try:
            probe.bind(("127.0.0.1", 0))
            candidate = probe.getsockname()[1] & ~1
        finally:
            probe.close()
        if candidate < 1024 or candidate > 65534:
            continue
        rtp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        rtcp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        rtp.set_inheritable(False); rtcp.set_inheritable(False)
        try:
            rtp.bind(("127.0.0.1", candidate))
            rtcp.bind(("127.0.0.1", candidate + 1))
            return ReservedPair(rtp, rtcp, candidate, candidate + 1)
        except OSError:
            rtp.close(); rtcp.close()
    raise RuntimeError("Could not reserve an adjacent localhost RTP/RTCP pair.")


def sdp_text(port: int, rtcp_port: int) -> str:
    return (
        "v=0\r\n"
        "o=- 0 0 IN IP4 127.0.0.1\r\n"
        "s=Aurora Stream quality diagnostic\r\n"
        "c=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\n"
        f"m=audio {port} RTP/AVP 96\r\n"
        "a=rtpmap:96 L16/48000/2\r\n"
        f"a=rtcp:{rtcp_port} IN IP4 127.0.0.1\r\n"
        "a=ptime:20\r\n"
        "a=recvonly\r\n"
    )


def start_helper(executable: Path, folder: Path, pair: ReservedPair,
                 endpoint_id: str, synthetic: bool = False) -> Helper:
    token = f"helper-{pair.rtp_port}-{time.time_ns()}"
    status = folder / f"{token}.status"
    stop = folder / f"{token}.stop"
    metrics = folder / f"{token}.metrics"
    stdout_path = folder / f"{token}.stdout.txt"
    stderr_path = folder / f"{token}.stderr.txt"
    stdout_file = stdout_path.open("w", encoding="utf-8")
    stderr_file = stderr_path.open("w", encoding="utf-8")
    command = [
        str(executable), "--audio-rtp-helper",
        "--port", str(pair.rtp_port),
        "--status", str(status),
        "--stop", str(stop),
        "--metrics", str(metrics),
        "--endpoint", endpoint_id,
    ]
    if synthetic:
        command.append("--synthetic")
    process = subprocess.Popen(command, cwd=str(ROOT), text=True,
                               stdout=stdout_file, stderr=stderr_file,
                               creationflags=CREATE_NO_WINDOW,
                               close_fds=True)
    return Helper(process, status, stop, metrics, stdout_path, stderr_path,
                  stdout_file, stderr_file, pair.rtp_port, pair.rtcp_port)


def wait_helper(helper: Helper, require_capture: bool, timeout: float) -> str:
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        if helper.status_path.exists():
            with contextlib.suppress(OSError):
                last = helper.status_path.read_text(encoding="utf-8", errors="replace").strip()
            if last.startswith("error:"):
                return last
            if require_capture and last == "capturing":
                return last
            if not require_capture and last in {"ready", "capturing"}:
                return last
        if helper.process.poll() is not None:
            return last or f"error:helper exited with code {helper.process.returncode}"
        time.sleep(0.02)
    return last


def stop_helper(helper: Helper) -> tuple[str, str, str]:
    with contextlib.suppress(OSError):
        helper.stop_path.write_text("stop\r\n", encoding="ascii")
    try:
        helper.process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        helper.process.terminate()
        try:
            helper.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            helper.process.kill(); helper.process.wait(timeout=2)
    helper.stdout_file.close(); helper.stderr_file.close()
    metrics = ""; stdout = ""; stderr = ""
    with contextlib.suppress(OSError):
        metrics = helper.metrics_path.read_text(encoding="utf-8", errors="replace").strip()
    with contextlib.suppress(OSError):
        stdout = helper.stdout_path.read_text(encoding="utf-8", errors="replace").strip()
    with contextlib.suppress(OSError):
        stderr = helper.stderr_path.read_text(encoding="utf-8", errors="replace").strip()
    return metrics, stdout, stderr


def helper_metrics(text: str) -> dict[str, int | str]:
    result: dict[str, int | str] = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip(); value = value.strip()
        try: result[key] = int(value)
        except ValueError: result[key] = value
    return result


def parse_progress(stderr: str) -> tuple[int, float, float, int]:
    frame = 0; final_speed = 0.0; settled: list[float] = []
    current_time = 0.0
    queue_warnings = stderr.lower().count("buffers queued")
    for raw in stderr.splitlines():
        line = raw.strip()
        if line.startswith("frame="):
            with contextlib.suppress(ValueError): frame = max(frame, int(line[6:]))
        elif line.startswith("out_time_us="):
            with contextlib.suppress(ValueError): current_time = int(line[12:]) / 1_000_000.0
        elif line.startswith("speed="):
            value = line[6:].rstrip("x")
            with contextlib.suppress(ValueError):
                speed = float(value)
                final_speed = speed
                if current_time >= 2.0: settled.append(speed)
    return frame, final_speed, statistics.fmean(settled) if settled else 0.0, queue_warnings


def build_video_filter(mode: str, audio_filter: str) -> tuple[str, bool, tuple[int, int]]:
    if mode == "current":
        video = (
            "[0:v]fps=fps=60:start_time=0:round=near,settb=AVTB,"
            "setpts=N/(60*TB),scale=1920:1080:force_original_aspect_ratio=decrease:"
            "flags=bicubic,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,"
            "setsar=1,format=yuv420p[v]"
        )
        return video + ";" + audio_filter, False, (1920, 1080)
    if mode == "noscale-yuv":
        video = (
            "[0:v]fps=fps=60:start_time=0:round=near,settb=AVTB,"
            "setpts=N/(60*TB),setsar=1,format=yuv420p[v]"
        )
        return video + ";" + audio_filter, False, (1920, 1080)
    if mode == "bgra-clocked":
        video = "[0:v]settb=AVTB,setpts=N/(60*TB),setsar=1[v]"
        return video + ";" + audio_filter, True, (1920, 1080)
    if mode == "bgra-native":
        video = "[0:v]setsar=1[v]"
        return video + ";" + audio_filter, True, (1920, 1080)
    if mode == "720-fast":
        video = (
            "[0:v]fps=fps=60:start_time=0:round=near,settb=AVTB,"
            "setpts=N/(60*TB),scale=1280:720:flags=fast_bilinear,"
            "setsar=1,format=yuv420p[v]"
        )
        return video + ";" + audio_filter, False, (1280, 720)
    raise ValueError(mode)


def audio_filter(mode: str, input_index: int = 1) -> str:
    if mode == "synthetic":
        return (f"[{input_index}:a]aresample=48000:first_pts=0,"
                "aformat=sample_rates=48000:channel_layouts=stereo,"
                "asetpts=N/SR/TB[a]")
    async_value = {"async1000": "async=1000:", "async1": "async=1:",
                   "noasync": ""}[mode]
    return (f"[{input_index}:a]aresample=48000:{async_value}first_pts=0,"
            "aformat=sample_rates=48000:channel_layouts=stereo,"
            "asetpts=PTS-STARTPTS[a]")


def common_output(output: Path, duration: int, fifo: bool, bgra: bool,
                  size: tuple[int, int], video_map: str = "[v]",
                  audio_map: str = "[a]", direct_d3d11: bool = False,
                  bitrate_kbps: int | None = None) -> list[str]:
    if bitrate_kbps is None:
        bitrate_kbps = 6_000 if size == (1920, 1080) else 4_500
    bitrate = f"{bitrate_kbps}k"
    buffer_size = f"{bitrate_kbps * 2}k"
    result = [
        "-map", video_map, "-map", audio_map,
    ]
    if direct_d3d11:
        result += ["-fps_mode:v", "passthrough"]
    else:
        result += ["-r:v", "60", "-fps_mode:v", "cfr"]
    result += [
        "-c:v", "h264_nvenc", "-preset", "p3", "-tune", "ll",
        "-rc", "cbr", "-b:v", bitrate, "-maxrate", bitrate,
        "-bufsize", buffer_size, "-profile:v", "high",
        "-level:v", "5.1" if size == (2560, 1440) else "4.2",
        "-g", "120", "-keyint_min", "120", "-bf", "2",
    ]
    if bgra:
        result += ["-rgb_mode", "yuv420"]
    result += [
        "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-ac", "2",
        "-max_muxing_queue_size", "2048", "-flags", "+global_header",
        "-t", str(duration),
    ]
    if fifo:
        result += [
            "-f", "fifo", "-fifo_format", "flv", "-queue_size", "360",
            "-format_opts", "max_interleave_delta=0:flush_packets=1:"
            "flvflags=no_duration_filesize",
            "-attempt_recovery", "1", "-recovery_wait_time", "1",
            "-drop_pkts_on_overflow", "1", "-restart_with_keyframe", "1",
            str(output),
        ]
    else:
        result += [
            "-max_interleave_delta", "0", "-flush_packets", "1",
            "-flvflags", "no_duration_filesize", "-f", "flv", str(output),
        ]
    return result


def desktop_command(output: Path, video_mode: str, audio_mode: str,
                    sdp: Path | None, fifo: bool) -> list[str]:
    direct_d3d11 = video_mode == "d3d11-direct"
    video_source = (
        "ddagrab=output_idx=0:framerate=60:draw_mouse=0:dup_frames=1"
    )
    if not direct_d3d11:
        video_source += ",hwdownload,format=bgra"
    command = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "warning", "-nostdin",
        "-stats_period", "0.25", "-progress", "pipe:2", "-benchmark",
        "-thread_queue_size", "512", "-f", "lavfi", "-i",
        video_source,
    ]
    if audio_mode == "synthetic":
        command += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
    else:
        assert sdp is not None
        command += [
            "-protocol_whitelist", "file,udp,rtp",
            "-thread_queue_size", "4096",
            "-buffer_size", "4194304",
            "-reorder_queue_size", "2048",
            "-f", "sdp", "-i", str(sdp),
        ]
    if direct_d3d11:
        command += ["-filter_complex", audio_filter(audio_mode)]
        command += common_output(
            output, CAPTURE_SECONDS, fifo, False, (1920, 1080),
            video_map="0:v", direct_d3d11=True,
        )
    else:
        graph, bgra, size = build_video_filter(
            video_mode, audio_filter(audio_mode)
        )
        command += ["-filter_complex", graph]
        command += common_output(output, CAPTURE_SECONDS, fifo, bgra, size)
    return command


def dual_output_command(twitch_output: Path, youtube_output: Path,
                        audio_mode: str, sdp: Path) -> list[str]:
    """Mirror the default live 1080p Twitch + 1440p YouTube workload locally."""
    command = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "warning", "-nostdin",
        "-stats_period", "0.25", "-progress", "pipe:2", "-benchmark",
        "-thread_queue_size", "512", "-f", "lavfi", "-i",
        "ddagrab=output_idx=0:framerate=60:draw_mouse=0:dup_frames=1,"
        "hwdownload,format=bgra",
        "-protocol_whitelist", "file,udp,rtp",
        "-thread_queue_size", "4096",
        "-buffer_size", "4194304",
        "-reorder_queue_size", "2048",
        "-f", "sdp", "-i", str(sdp),
    ]
    graph = (
        "[0:v]fps=fps=60:start_time=0:round=near,settb=AVTB,"
        "setpts=N/(60*TB),"
        "scale=1920:1080:force_original_aspect_ratio=decrease:flags=bicubic,"
        "pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1[vsource];"
        "[vsource]split=2[vtwitchsource][vyoutubesource];"
        "[vtwitchsource]format=yuv420p[vtwitch];"
        "[vyoutubesource]scale=2560:1440:"
        "force_original_aspect_ratio=decrease:flags=bicubic,"
        "pad=2560:1440:(ow-iw)/2:(oh-ih)/2,setsar=1,"
        "format=yuv420p[vyoutube];"
        + audio_filter(audio_mode)
        + ";[a]asplit=2[atwitch][ayoutube]"
    )
    command += ["-filter_complex", graph]
    command += common_output(
        twitch_output, CAPTURE_SECONDS, True, False, (1920, 1080),
        video_map="[vtwitch]", audio_map="[atwitch]", bitrate_kbps=6_000,
    )
    command += common_output(
        youtube_output, CAPTURE_SECONDS, True, False, (2560, 1440),
        video_map="[vyoutube]", audio_map="[ayoutube]", bitrate_kbps=24_000,
    )
    return command


def synthetic_baseline_command(output: Path) -> list[str]:
    return [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "warning", "-nostdin",
        "-stats_period", "0.25", "-progress", "pipe:2", "-benchmark",
        "-f", "lavfi", "-i", TEST_GRAPH,
        "-map", "0:v", "-map", "0:a", "-c:v", "h264_nvenc",
        "-preset", "p3", "-tune", "ll", "-rc", "cbr", "-b:v", "6000k",
        "-maxrate", "6000k", "-bufsize", "12000k", "-profile:v", "high",
        "-level:v", "4.2", "-g", "120", "-keyint_min", "120", "-bf", "2",
        "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-ac", "2",
        "-t", str(SYNTHETIC_SECONDS), "-max_interleave_delta", "0",
        "-flush_packets", "1", "-flvflags", "no_duration_filesize",
        "-f", "flv", str(output),
    ]


def audio_only_command(output: Path, sdp: Path) -> list[str]:
    return [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "warning", "-nostdin",
        "-stats_period", "0.25", "-progress", "pipe:2",
        "-protocol_whitelist", "file,udp,rtp",
        "-thread_queue_size", "4096",
        "-buffer_size", "4194304",
        "-reorder_queue_size", "2048",
        "-f", "sdp", "-i", str(sdp), "-map", "0:a", "-c:a", "pcm_s16le",
        "-ar", "48000", "-ac", "2", "-t", str(CAPTURE_SECONDS),
        "-f", "wav", str(output),
    ]


def run_phase(phase: PhaseResult, helper: Helper | None,
              pair: ReservedPair | None, report: Report) -> PhaseResult:
    report.section(f"{phase.name} — {phase.description}")
    report.line("Command: " + command_text(phase.command))
    if pair is not None:
        report.line(f"Reserved RTP/RTCP pair: {pair.rtp_port}/{pair.rtcp_port}")
        pair.close()
        report.line("Released receiver reservations immediately before FFmpeg launch.")

    started = time.monotonic()
    process = subprocess.Popen(phase.command, cwd=str(ROOT), stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True,
                               creationflags=CREATE_NO_WINDOW)
    sampler = ResourceSampler(process.pid, helper.process.pid if helper else None)
    sampler.start()
    try:
        stdout, stderr = process.communicate(timeout=CAPTURE_SECONDS + 25)
    except subprocess.TimeoutExpired:
        phase.timed_out = True
        process.kill()
        stdout, stderr = process.communicate(timeout=5)
    phase.wall_seconds = time.monotonic() - started
    phase.returncode = process.returncode
    phase.stderr = stderr
    phase.resources = sampler.stop()
    phase.progress_frames, phase.final_speed, phase.average_settled_speed, phase.queue_warnings = parse_progress(stderr)

    if helper is not None:
        phase.helper_status = wait_helper(helper, require_capture=False, timeout=0.1)
        metrics, helper_stdout, helper_stderr = stop_helper(helper)
        phase.helper_metrics = metrics
        if helper_stdout:
            phase.stderr += "\n--- helper stdout ---\n" + helper_stdout
        if helper_stderr:
            phase.stderr += "\n--- helper stderr ---\n" + helper_stderr

    report.line(f"Return code: {phase.returncode}; timed out: {'yes' if phase.timed_out else 'no'}; wall: {phase.wall_seconds:.3f} s")
    report.line(f"Progress: frames={phase.progress_frames}, final_speed={phase.final_speed:.3f}x, settled_average={phase.average_settled_speed:.3f}x, queue_warnings={phase.queue_warnings}")
    report.line("Resources: system CPU avg/max " + fmt(phase.resources.system_cpu_avg, "%") + "/" + fmt(phase.resources.system_cpu_max, "%") +
                "; FFmpeg CPU avg/max " + fmt(phase.resources.ffmpeg_cpu_avg, "%") + "/" + fmt(phase.resources.ffmpeg_cpu_max, "%") +
                "; helper CPU avg/max " + fmt(phase.resources.helper_cpu_avg, "%") + "/" + fmt(phase.resources.helper_cpu_max, "%"))
    report.line("Resources: FFmpeg RAM max " + fmt(phase.resources.ffmpeg_memory_max_mb, " MiB") +
                "; helper RAM max " + fmt(phase.resources.helper_memory_max_mb, " MiB") +
                "; GPU avg/max " + fmt(phase.resources.gpu_avg, "%") + "/" + fmt(phase.resources.gpu_max, "%") +
                "; GPU power avg/max " + fmt(phase.resources.gpu_power_avg_w, " W") + "/" + fmt(phase.resources.gpu_power_max_w, " W") +
                "; GPU temp max " + fmt(phase.resources.gpu_temp_max_c, " C"))
    if phase.helper_metrics:
        report.line("Helper metrics:\n" + phase.helper_metrics)
    if stderr.strip():
        report.line("FFmpeg/helper output:\n" + stderr.strip())
    return phase


def probe_json(path: Path) -> dict:
    completed = run_checked([
        "ffprobe", "-v", "error", "-count_frames", "-show_entries",
        "format=duration,size:stream=index,codec_type,codec_name,avg_frame_rate,"
        "sample_rate,channels,nb_read_frames,width,height", "-of", "json", str(path),
    ], timeout=30)
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "ffprobe failed")
    return json.loads(completed.stdout)


def video_analysis(path: Path) -> VideoResult:
    result = VideoResult()
    try:
        probe = probe_json(path)
        video = next(stream for stream in probe.get("streams", [])
                     if stream.get("codec_type") == "video")
        result.frames = int(video.get("nb_read_frames") or 0)
        result.width = int(video.get("width") or 0)
        result.height = int(video.get("height") or 0)
        result.duration = float(probe.get("format", {}).get("duration") or 0.0)

        # Keep exact hashes as useful forensic data, but do not use them alone
        # to decide unique cadence: two encodes of the same source image can
        # reconstruct with slightly different pixels after lossy H.264.
        md5 = run_checked(["ffmpeg", "-v", "error", "-i", str(path),
                           "-map", "0:v:0", "-f", "framemd5", "-"], timeout=60)
        if md5.returncode != 0:
            raise RuntimeError(md5.stderr.strip() or "framemd5 failed")
        hashes: list[str] = []
        for line in md5.stdout.splitlines():
            if not line or line.startswith("#"):
                continue
            fields = [field.strip() for field in line.split(",")]
            if len(fields) >= 6:
                hashes.append(fields[-1])
        if not result.frames:
            result.frames = len(hashes)
        for index in range(1, len(hashes)):
            if hashes[index] == hashes[index - 1]:
                result.exact_duplicates += 1

        luma = subprocess.check_output([
            "ffmpeg", "-v", "error", "-i", str(path), "-map", "0:v:0",
            "-vf",
            f"scale={DIFFERENCE_WIDTH}:{DIFFERENCE_HEIGHT}:flags=area,"
            "format=gray",
            "-f", "rawvideo", "-",
        ], timeout=60, creationflags=CREATE_NO_WINDOW)
        frame_bytes = DIFFERENCE_WIDTH * DIFFERENCE_HEIGHT
        luma_frames = len(luma) // frame_bytes
        if luma_frames < 2:
            raise RuntimeError("too few decoded frames for adjacent-image analysis")
        luma_view = memoryview(luma)
        adjacent_mad: list[float] = []
        for index in range(1, luma_frames):
            previous = luma_view[(index - 1) * frame_bytes:index * frame_bytes]
            current = luma_view[index * frame_bytes:(index + 1) * frame_bytes]
            difference = sum(abs(a - b) for a, b in zip(previous, current))
            adjacent_mad.append(difference / frame_bytes)
        result.minimum_adjacent_luma_mad = min(adjacent_mad)
        result.duplicate_luma_threshold = min(
            NEAR_DUPLICATE_LUMA_MAD,
            statistics.median(adjacent_mad) * NEAR_DUPLICATE_MEDIAN_RATIO,
        )
        run = 1
        for mad in adjacent_mad:
            if mad <= result.duplicate_luma_threshold:
                result.duplicates += 1
                run += 1
                result.longest_run = max(result.longest_run, run)
            else:
                run = 1
        result.longest_run = max(result.longest_run, 1)
        duration = result.duration if result.duration > 0 else result.frames / FPS
        result.unique_rate = ((result.frames - result.duplicates) / duration) if duration > 0 else 0.0
        result.duplicate_ratio = 100.0 * result.duplicates / max(1, result.frames - 1)

        frames_json = run_checked([
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "frame=best_effort_timestamp_time", "-of", "json",
            str(path),
        ], timeout=30)
        if frames_json.returncode == 0:
            data = json.loads(frames_json.stdout)
            times = [float(frame["best_effort_timestamp_time"])
                     for frame in data.get("frames", [])
                     if "best_effort_timestamp_time" in frame]
            intervals = [1000.0 * (b - a) for a, b in zip(times, times[1:])]
            if intervals:
                result.interval_max_ms = max(intervals)
                sorted_intervals = sorted(intervals)
                result.interval_p99_ms = sorted_intervals[min(len(sorted_intervals) - 1,
                    int(0.99 * len(sorted_intervals)))]

        width = result.width or 1920
        marker_size = max(32, round(240 * width / 1920))
        brightness = subprocess.check_output([
            "ffmpeg", "-v", "error", "-i", str(path), "-map", "0:v:0",
            "-vf", f"crop={marker_size}:{marker_size}:0:0,scale=1:1,format=gray",
            "-f", "rawvideo", "-",
        ], timeout=60, creationflags=CREATE_NO_WINDOW)
        active = [index for index, value in enumerate(brightness) if value >= 210]
        groups: list[list[int]] = []
        for index in active:
            if not groups or index > groups[-1][-1] + 1:
                groups.append([index])
            else:
                groups[-1].append(index)
        result.flash_times = [statistics.fmean(group) / FPS for group in groups
                              if 1 <= len(group) <= 8]
        if len(result.flash_times) >= 3:
            intervals = [b - a for a, b in zip(result.flash_times, result.flash_times[1:])]
            result.flash_interval_jitter_ms = statistics.pstdev(intervals) * 1000.0
        result.valid = True
    except Exception as error:
        result.error = str(error)
    return result


def wrap_phase(value: float) -> float:
    return (value + math.pi) % (2.0 * math.pi) - math.pi


def dft_block(samples: array.array, start: int, count: int, frequency: float) -> tuple[float, float]:
    omega = 2.0 * math.pi * frequency / SAMPLE_RATE
    real = 0.0; imaginary = 0.0
    for offset in range(count):
        value = samples[start + offset]
        angle = omega * offset
        real += value * math.cos(angle)
        imaginary -= value * math.sin(angle)
    amplitude = math.hypot(real, imaginary) / max(1, count)
    return amplitude, math.atan2(imaginary, real)


def audio_analysis(path: Path) -> AudioResult:
    result = AudioResult()
    try:
        raw = subprocess.check_output([
            "ffmpeg", "-v", "error", "-i", str(path), "-map", "0:a:0",
            "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "s16le", "-",
        ], timeout=60, creationflags=CREATE_NO_WINDOW)
        samples = array.array("h")
        samples.frombytes(raw)
        if sys.byteorder != "little":
            samples.byteswap()
        if len(samples) < SAMPLE_RATE:
            raise RuntimeError("decoded audio is shorter than one second")
        result.duration = len(samples) / SAMPLE_RATE
        block = 480  # 10 ms
        rms_values: list[float] = []
        marker_strength: list[float] = []
        phases: list[float] = []
        tone_strength: list[float] = []
        for start in range(0, len(samples) - block + 1, block):
            segment = samples[start:start + block]
            rms = math.sqrt(sum(value * value for value in segment) / block)
            rms_values.append(rms)
            marker, _ = dft_block(samples, start, block, 4000.0)
            tone, phase = dft_block(samples, start, block, 997.0)
            marker_strength.append(marker)
            tone_strength.append(tone)
            phases.append(phase)
        middle = rms_values[50:-50] if len(rms_values) > 100 else rms_values
        result.median_rms = statistics.median(middle)
        if result.median_rms <= 1.0:
            raise RuntimeError("captured audio is effectively silent")
        dropout_threshold = result.median_rms * 0.18
        dropout_indices = [index for index, value in enumerate(rms_values)
                           if 20 <= index < len(rms_values) - 20 and value < dropout_threshold]
        groups: list[list[int]] = []
        for index in dropout_indices:
            if not groups or index > groups[-1][-1] + 1:
                groups.append([index])
            else:
                groups[-1].append(index)
        result.dropout_windows = len(dropout_indices)
        result.longest_dropout_ms = max((len(group) * 10.0 for group in groups), default=0.0)
        result.clipped_samples = sum(1 for value in samples if abs(value) >= 32760)

        marker_base = statistics.median(marker_strength)
        marker_threshold = max(marker_base * 5.0, result.median_rms * 0.40)
        active = [index for index, value in enumerate(marker_strength)
                  if value >= marker_threshold]
        marker_groups: list[list[int]] = []
        for index in active:
            if not marker_groups or index > marker_groups[-1][-1] + 2:
                marker_groups.append([index])
            else:
                marker_groups[-1].append(index)
        result.marker_times = [statistics.fmean(group) * 0.010 for group in marker_groups
                               if len(group) <= 8]
        if len(result.marker_times) >= 3:
            intervals = [b - a for a, b in zip(result.marker_times, result.marker_times[1:])]
            result.marker_interval_jitter_ms = statistics.pstdev(intervals) * 1000.0

        expected = 2.0 * math.pi * 997.0 * block / SAMPLE_RATE
        phase_errors: list[float] = []
        for index in range(1, len(phases)):
            if index < 20 or index >= len(phases) - 20:
                continue
            # Ignore the deliberate 4 kHz marker and any adjacent block.
            if (marker_strength[index] >= marker_threshold or
                marker_strength[index - 1] >= marker_threshold):
                continue
            if tone_strength[index] < statistics.median(tone_strength) * 0.25:
                continue
            error = abs(wrap_phase(phases[index] - phases[index - 1] - expected))
            phase_errors.append(error)
        result.maximum_phase_error = max(phase_errors, default=0.0)
        result.phase_jumps = sum(1 for value in phase_errors if value > 0.35)
        result.valid = True
    except Exception as error:
        result.error = str(error)
    return result


def sync_analysis(video: VideoResult, audio: AudioResult) -> SyncResult:
    result = SyncResult()
    if not video.valid or not audio.valid:
        result.error = "video or audio analysis is unavailable"
        return result
    differences: list[float] = []
    for flash in video.flash_times:
        if not audio.marker_times:
            break
        nearest = min(audio.marker_times, key=lambda value: abs(value - flash))
        difference = nearest - flash
        if abs(difference) <= 0.45:
            differences.append(difference)
    if len(differences) < 4:
        result.error = "fewer than four matched A/V marker events"
        return result
    median = statistics.median(differences)
    deviations = [value - median for value in differences]
    result.valid = True
    result.matches = len(differences)
    result.median_offset_ms = median * 1000.0
    result.jitter_ms = statistics.pstdev(differences) * 1000.0
    result.drift_ms = (differences[-1] - differences[0]) * 1000.0
    result.maximum_error_ms = max(abs(value) for value in deviations) * 1000.0
    return result


def analyse_phase(phase: PhaseResult, expect_video: bool, expect_tone: bool,
                  report: Report) -> None:
    if phase.returncode != 0 or not phase.output.exists() or phase.output.stat().st_size == 0:
        phase.failure = phase.failure or "output was not produced successfully"
        report.line("ANALYSIS FAILURE: " + phase.failure)
        return
    if expect_video:
        phase.video = video_analysis(phase.output)
        if phase.video.valid:
            report.line(
                f"Video: size={phase.video.width}x{phase.video.height}, "
                f"frames={phase.video.frames}, duration={phase.video.duration:.3f}s, "
                f"unique={phase.video.unique_rate:.3f} FPS, visual_duplicates={phase.video.duplicates} "
                f"({phase.video.duplicate_ratio:.3f}%), exact_duplicates={phase.video.exact_duplicates}, "
                f"minimum_adjacent_luma_MAD={phase.video.minimum_adjacent_luma_mad:.3f}, "
                f"duplicate_MAD_threshold={phase.video.duplicate_luma_threshold:.3f}, "
                f"longest_run={phase.video.longest_run}, "
                f"PTS max/p99={phase.video.interval_max_ms:.3f}/{phase.video.interval_p99_ms:.3f} ms, "
                f"flash_events={len(phase.video.flash_times)}, flash_jitter={phase.video.flash_interval_jitter_ms:.3f} ms"
            )
        else:
            report.line("Video analysis failed: " + phase.video.error)
        if phase.secondary_output is not None:
            if (not phase.secondary_output.exists() or
                    phase.secondary_output.stat().st_size == 0):
                phase.secondary_video.error = "secondary output was not produced"
                report.line("Secondary video analysis failed: " +
                            phase.secondary_video.error)
            else:
                phase.secondary_video = video_analysis(phase.secondary_output)
                if phase.secondary_video.valid:
                    report.line(
                        "Secondary video: "
                        f"size={phase.secondary_video.width}x{phase.secondary_video.height}, "
                        f"frames={phase.secondary_video.frames}, "
                        f"duration={phase.secondary_video.duration:.3f}s, "
                        f"unique={phase.secondary_video.unique_rate:.3f} FPS, "
                        f"visual_duplicates={phase.secondary_video.duplicates}, "
                        f"longest_run={phase.secondary_video.longest_run}"
                    )
                else:
                    report.line("Secondary video analysis failed: " +
                                phase.secondary_video.error)
    if expect_tone:
        phase.audio = audio_analysis(phase.output)
        if phase.audio.valid:
            report.line(
                f"Audio: duration={phase.audio.duration:.3f}s, median_RMS={phase.audio.median_rms:.2f}, "
                f"dropout_windows={phase.audio.dropout_windows}, longest_dropout={phase.audio.longest_dropout_ms:.1f} ms, "
                f"phase_jumps={phase.audio.phase_jumps}, max_phase_error={phase.audio.maximum_phase_error:.3f} rad, "
                f"clipped_samples={phase.audio.clipped_samples}, marker_events={len(phase.audio.marker_times)}, "
                f"marker_jitter={phase.audio.marker_interval_jitter_ms:.3f} ms"
            )
        else:
            report.line("Audio analysis failed: " + phase.audio.error)
    if expect_video and expect_tone:
        phase.sync = sync_analysis(phase.video, phase.audio)
        if phase.sync.valid:
            report.line(
                f"A/V sync: matches={phase.sync.matches}, audio_minus_video={phase.sync.median_offset_ms:.2f} ms, "
                f"jitter={phase.sync.jitter_ms:.2f} ms, drift={phase.sync.drift_ms:.2f} ms, "
                f"max_deviation={phase.sync.maximum_error_ms:.2f} ms"
            )
        else:
            report.line("A/V sync analysis unavailable: " + phase.sync.error)


def video_quality_pass(phase: PhaseResult) -> bool:
    size_matches = (
        phase.expected_size is None or
        (phase.video.width, phase.video.height) == phase.expected_size
    )
    secondary_matches = True
    if phase.secondary_output is not None:
        secondary_matches = (
            phase.secondary_video.valid and
            (phase.secondary_expected_size is None or
             (phase.secondary_video.width, phase.secondary_video.height) ==
             phase.secondary_expected_size) and
            phase.secondary_video.unique_rate >= 59.0 and
            phase.secondary_video.longest_run <= 2
        )
    return (phase.video.valid and size_matches and secondary_matches and
            phase.video.unique_rate >= 59.0 and
            phase.video.longest_run <= 2 and phase.queue_warnings == 0 and
            phase.average_settled_speed >= 0.98)


def audio_quality_pass(phase: PhaseResult) -> bool:
    if not phase.audio.valid:
        return False
    metrics = helper_metrics(phase.helper_metrics)
    receiver_output = phase.stderr.lower()
    return (
        phase.audio.dropout_windows == 0 and phase.audio.phase_jumps == 0 and
        "rtp: missed" not in receiver_output and
        "max delay reached" not in receiver_output and
        "circular buffer overrun" not in receiver_output and
        metrics.get("mmcss_enabled") == "true" and
        int(metrics.get("packets_captured", 0)) > 0 and
        int(metrics.get("silent_frames_sent", 0)) == 0 and
        int(metrics.get("frames_dropped_on_overflow", 0)) == 0 and
        int(metrics.get("stale_frames_discarded", 0)) == 0 and
        int(metrics.get("pacing_frames_skipped", 0)) == 0 and
        int(metrics.get("discontinuities", 0)) == 0 and
        int(metrics.get("send_failures", 0)) == 0 and
        int(metrics.get("maximum_packet_gap_ms", 9999)) <= 30 and
        int(metrics.get("maximum_send_duration_us", 999999)) <= 5_000
    )


def synthetic_transport_quality_pass(phase: PhaseResult) -> bool:
    metrics = helper_metrics(phase.helper_metrics)
    receiver_output = phase.stderr.lower()
    return (
        phase.returncode == 0 and not phase.timed_out and
        "rtp: missed" not in receiver_output and
        "max delay reached" not in receiver_output and
        "circular buffer overrun" not in receiver_output and
        metrics.get("mmcss_enabled") == "true" and
        int(metrics.get("rtp_packets_sent", 0)) > 0 and
        int(metrics.get("pacing_frames_skipped", 0)) == 0 and
        int(metrics.get("send_failures", 0)) == 0 and
        int(metrics.get("maximum_packet_gap_ms", 9999)) <= 30 and
        int(metrics.get("maximum_send_duration_us", 999999)) <= 5_000
    )


def sync_quality_pass(phase: PhaseResult) -> bool:
    return (phase.sync.valid and abs(phase.sync.median_offset_ms) <= 120.0 and
            phase.sync.jitter_ms <= 20.0 and abs(phase.sync.drift_ms) <= 20.0)


def phase_score(phase: PhaseResult) -> float:
    if not phase.video.valid:
        return -1e9
    score = phase.video.unique_rate * 10.0
    score -= phase.video.duplicates * 0.4
    score -= phase.queue_warnings * 50.0
    if phase.audio.valid:
        score -= phase.audio.dropout_windows * 4.0
        score -= phase.audio.phase_jumps * 3.0
    metrics = helper_metrics(phase.helper_metrics)
    score -= int(metrics.get("stale_frames_discarded", 0)) / 480.0
    score -= int(metrics.get("pacing_frames_skipped", 0)) / 480.0
    return score


def launch_test_card(report: Report) -> tuple[subprocess.Popen[str], object, Path]:
    stderr_path = ARTIFACTS / "ffplay-test-card.log"
    stderr_file = stderr_path.open("w", encoding="utf-8")
    command = [
        "ffplay", "-hide_banner", "-loglevel", "warning", "-f", "lavfi",
        "-i", TEST_GRAPH, "-fs", "-alwaysontop", "-noborder", "-volume", "80",
        "-sync", "audio",
    ]
    report.line("Launching synchronized full-screen 60 FPS test card: " + command_text(command))
    process = subprocess.Popen(command, cwd=str(ROOT), stdout=subprocess.DEVNULL,
                               stderr=stderr_file, text=True,
                               creationflags=CREATE_NEW_PROCESS_GROUP)
    time.sleep(3.0)
    if process.poll() is not None:
        stderr_file.close()
        text = stderr_path.read_text(encoding="utf-8", errors="replace") if stderr_path.exists() else ""
        raise RuntimeError(f"ffplay test card exited with code {process.returncode}: {text}")
    return process, stderr_file, stderr_path


def launch_audio_test_signal(report: Report) -> tuple[subprocess.Popen[str], object, Path]:
    stderr_path = ARTIFACTS / "ffplay-audio-test-signal.log"
    stderr_file = stderr_path.open("w", encoding="utf-8")
    command = [
        "ffplay", "-hide_banner", "-loglevel", "warning", "-nodisp",
        "-f", "lavfi", "-i", AUDIO_TEST_SOURCE, "-volume", "80",
    ]
    report.line("Launching deterministic audio test signal: " +
                command_text(command))
    process = subprocess.Popen(
        command, cwd=str(ROOT), stdout=subprocess.DEVNULL,
        stderr=stderr_file, text=True,
        creationflags=CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW,
    )
    time.sleep(1.0)
    if process.poll() is not None:
        stderr_file.close()
        text = stderr_path.read_text(
            encoding="utf-8", errors="replace"
        ) if stderr_path.exists() else ""
        raise RuntimeError(
            f"ffplay audio signal exited with code {process.returncode}: {text}"
        )
    return process, stderr_file, stderr_path


def stop_test_card(process: subprocess.Popen[str], stderr_file: object) -> None:
    with contextlib.suppress(Exception):
        process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill(); process.wait(timeout=2)
    with contextlib.suppress(Exception):
        stderr_file.close()


def select_endpoint(executable: Path) -> tuple[str, str]:
    completed = run_checked([str(executable), "--list-audio-endpoints-json"], timeout=10)
    if completed.returncode not in (0, 2):
        raise RuntimeError(completed.stderr.strip() or "audio endpoint enumeration failed")
    data = json.loads(completed.stdout)
    endpoints = data.get("endpoints", [])
    if not endpoints:
        raise RuntimeError(data.get("error") or "Windows returned no active playback endpoint")
    selected = next((item for item in endpoints if item.get("default")), endpoints[0])
    return str(selected["id"]), str(selected.get("label") or "Windows playback endpoint")


def build_project(report: Report) -> Path:
    report.section("Build and prerequisites")
    for program in ("dub", "ffmpeg", "ffprobe", "ffplay"):
        location = shutil.which(program)
        report.line(f"{program}: {location or 'MISSING'}")
        if not location:
            raise RuntimeError(f"Required program is missing: {program}")
    completed = run_checked(["dub", "build", "--build=debug"], timeout=180)
    report.line("dub build return code: " + str(completed.returncode))
    if completed.stdout.strip(): report.line(completed.stdout.strip())
    if completed.stderr.strip(): report.line(completed.stderr.strip())
    if completed.returncode != 0:
        raise RuntimeError("Aurora Stream did not compile")
    executable = ROOT / "aurora-stream.exe"
    if not executable.exists():
        raise RuntimeError("Build succeeded but aurora-stream.exe was not found")
    return executable


def run_real_phase(executable: Path, endpoint_id: str, name: str,
                   description: str, video_mode: str, audio_mode: str,
                   fifo: bool, report: Report,
                   analyse_video: bool = True,
                   synthetic_helper: bool = False) -> PhaseResult:
    dual_output = video_mode == "dual-default"
    output = ARTIFACTS / (
        f"{name}-twitch.flv" if dual_output else f"{name}.flv"
    )
    secondary_output = (
        ARTIFACTS / f"{name}-youtube.flv" if dual_output else None
    )
    with contextlib.suppress(OSError): output.unlink()
    if secondary_output is not None:
        with contextlib.suppress(OSError): secondary_output.unlink()
    pair = reserve_pair()
    sdp = ARTIFACTS / f"{name}.sdp"
    sdp.write_text(sdp_text(pair.rtp_port, pair.rtcp_port), encoding="ascii")
    helper = start_helper(
        executable, ARTIFACTS, pair, endpoint_id,
        synthetic=synthetic_helper,
    )
    status = wait_helper(
        helper, require_capture=not synthetic_helper, timeout=4.0
    )
    expected_status = "ready" if synthetic_helper else "capturing"
    if status != expected_status:
        metrics, helper_stdout, helper_stderr = stop_helper(helper)
        pair.close()
        expected_size = (1280, 720) if video_mode == "720-fast" else (1920, 1080)
        phase = PhaseResult(
            name, description, output, [], expected_size=expected_size,
            secondary_output=secondary_output,
            secondary_expected_size=(2560, 1440) if dual_output else None,
        )
        phase.helper_status = status
        phase.helper_metrics = metrics
        phase.failure = (status or "helper never reported real WASAPI capture")
        report.section(f"{name} — {description}")
        report.line("FAILED BEFORE FFMPEG: " + phase.failure)
        if metrics: report.line("Helper metrics:\n" + metrics)
        if helper_stdout: report.line("Helper stdout:\n" + helper_stdout)
        if helper_stderr: report.line("Helper stderr:\n" + helper_stderr)
        return phase
    if dual_output:
        assert secondary_output is not None
        command = dual_output_command(output, secondary_output, audio_mode, sdp)
    else:
        command = desktop_command(output, video_mode, audio_mode, sdp, fifo)
    expected_size = (1280, 720) if video_mode == "720-fast" else (1920, 1080)
    phase = PhaseResult(
        name, description, output, command, expected_size=expected_size,
        secondary_output=secondary_output,
        secondary_expected_size=(2560, 1440) if dual_output else None,
        helper_status=status,
    )
    run_phase(phase, helper, pair, report)
    analyse_phase(
        phase, expect_video=analyse_video,
        expect_tone=not synthetic_helper, report=report
    )
    return phase


def audio_only_main() -> int:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    report = Report(AUDIO_REPORT_PATH)
    report.line("Aurora Stream focused audio quality diagnostic")
    report.line("==============================================")
    report.line(f"Started: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    report.line(f"Capture duration: {CAPTURE_SECONDS} seconds")
    report.line("Source: continuous 997 Hz tone plus a 20 ms 4 kHz marker every second.")
    report.line("Video capture and encoding are intentionally excluded.")
    report.save()

    signal = None
    signal_stderr = None
    try:
        executable = build_project(report)
        endpoint_id, endpoint_label = select_endpoint(executable)
        report.line("Selected playback/loopback endpoint: " + endpoint_label)
        signal, signal_stderr, _ = launch_audio_test_signal(report)

        pair = reserve_pair()
        sdp = ARTIFACTS / "audio-only.sdp"
        sdp.write_text(
            sdp_text(pair.rtp_port, pair.rtcp_port), encoding="ascii"
        )
        helper = start_helper(executable, ARTIFACTS, pair, endpoint_id)
        status = wait_helper(helper, require_capture=True, timeout=4.0)
        output = ARTIFACTS / "audio-only.wav"
        with contextlib.suppress(OSError):
            output.unlink()
        phase = PhaseResult(
            "A01", "Real WASAPI/RTP decoded continuity", output,
            audio_only_command(output, sdp), helper_status=status,
        )
        if status == "capturing":
            run_phase(phase, helper, pair, report)
            analyse_phase(
                phase, expect_video=False, expect_tone=True, report=report
            )
        else:
            metrics, helper_stdout, helper_stderr = stop_helper(helper)
            pair.close()
            phase.helper_metrics = metrics
            phase.failure = status or "helper never reported capture"
            report.line("FAILED BEFORE FFMPEG: " + phase.failure)
            if metrics:
                report.line("Helper metrics:\n" + metrics)
            if helper_stdout:
                report.line("Helper stdout:\n" + helper_stdout)
            if helper_stderr:
                report.line("Helper stderr:\n" + helper_stderr)

        report.section("FOCUSED AUDIO VERDICT")
        passed = audio_quality_pass(phase)
        report.line("Decoded waveform and helper transport: " +
                    ("PASS" if passed else "FAIL"))
        report.line(
            "Required: MMCSS active; no decoded dropout/phase jump; no "
            "mid-stream WASAPI discontinuity; no inserted silence, overflow, "
            "stale discard, pacing skip, or RTP send failure."
        )
        report.line("Artifact: " + str(output))
        report.line("Report: " + str(AUDIO_REPORT_PATH))
        report.line(f"Finished: {time.strftime('%Y-%m-%d %H:%M:%S')}")
        report.save()
        return 0 if passed else 1
    except Exception as error:
        report.section("AUDIO DIAGNOSTIC FAILURE")
        report.line(type(error).__name__ + ": " + str(error))
        report.save()
        return 2
    finally:
        if signal is not None and signal_stderr is not None:
            stop_test_card(signal, signal_stderr)


def loaded_audio_main() -> int:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    report = Report(LOADED_AUDIO_REPORT_PATH)
    report.line("Aurora Stream focused loaded A/V audio diagnostic")
    report.line("================================================")
    report.line(f"Started: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    report.line(f"Capture duration per phase: {CAPTURE_SECONDS} seconds")
    report.line(
        "Source: Aurora Stream's silent, timestamped synthetic RTP helper."
    )
    report.line(
        "Normal desktop capture, NVENC, AAC, the bounded live FIFO, and real "
        "SDP/RTP receive path run concurrently as load."
    )
    report.line(
        "This focused mode opens no window, plays no sound, and does not "
        "grade waveform quality, visual frame uniqueness, or A/V sync."
    )
    report.line(
        "It complements the real-WASAPI waveform control by stress-testing "
        "the same receiver buffering without disturbing the desktop."
    )
    report.save()

    try:
        executable = build_project(report)
        endpoint_id, endpoint_label = select_endpoint(executable)
        report.line("Detected playback/loopback endpoint: " + endpoint_label)

        phases = [
            run_real_phase(
                executable, endpoint_id, "L01",
                "Live compatibility capture with buffered WASAPI/RTP",
                "current", "async1000", True, report, analyse_video=False,
                synthetic_helper=True,
            ),
            run_real_phase(
                executable, endpoint_id, "L02",
                "Lower-overhead BGRA capture with buffered WASAPI/RTP",
                "bgra-native", "async1000", True, report,
                analyse_video=False,
                synthetic_helper=True,
            ),
        ]

        report.section("FOCUSED LOADED A/V VERDICT")
        for phase in phases:
            transport_passed = synthetic_transport_quality_pass(phase)
            report.line(
                f"{phase.name}: RTP transport="
                f"{'PASS' if transport_passed else 'FAIL'}; "
                f"encoded_frames={phase.progress_frames}; "
                f"final_speed={phase.final_speed:.3f}x"
            )
        passed = all(
            synthetic_transport_quality_pass(phase) for phase in phases
        )
        report.line(
            "Loaded RTP receive result: " + ("PASS" if passed else "FAIL")
        )
        report.line(
            "Required: no FFmpeg RTP-loss/overrun warning and no sender "
            "pacing skip, excessive packet gap, or send failure."
        )
        report.line("Report: " + str(LOADED_AUDIO_REPORT_PATH))
        report.line(f"Finished: {time.strftime('%Y-%m-%d %H:%M:%S')}")
        report.save()
        return 0 if passed else 1
    except Exception as error:
        report.section("LOADED A/V DIAGNOSTIC FAILURE")
        report.line(type(error).__name__ + ": " + str(error))
        report.save()
        return 2


def main() -> int:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    for path in ARTIFACTS.iterdir():
        if path.is_file():
            with contextlib.suppress(OSError): path.unlink()
    report = Report(REPORT_PATH)
    report.line("Aurora Stream deterministic quality diagnostic")
    report.line("============================================")
    report.line(f"Started: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    report.line(f"Capture duration per quality phase: {CAPTURE_SECONDS} seconds")
    report.line("Test source: synchronized FFplay 1920x1080p60 moving test card, continuous 997 Hz tone, and simultaneous 1 Hz video/audio markers.")
    report.line("Privacy: no stream keys are read and no internet destination is contacted.")
    report.save()

    test_card = None; test_card_stderr = None
    phases: list[PhaseResult] = []
    try:
        executable = build_project(report)
        endpoint_id, endpoint_label = select_endpoint(executable)
        report.line("Selected playback/loopback endpoint: " + endpoint_label)

        # Q01: maximum encoder/mux capacity without desktop capture.
        q01 = PhaseResult("Q01", "Synthetic 1080p60 encoder/AAC capacity baseline",
                          ARTIFACTS / "Q01.flv",
                          synthetic_baseline_command(ARTIFACTS / "Q01.flv"),
                          expected_size=(1920, 1080))
        run_phase(q01, None, None, report)
        analyse_phase(q01, expect_video=True, expect_tone=True, report=report)
        phases.append(q01)

        report.section("Deterministic desktop playback")
        test_card, test_card_stderr, _ = launch_test_card(report)
        report.line("Test card is running. Desktop Duplication and WASAPI phases begin now.")

        # Video-only comparisons isolate capture/filter cost.
        for name, description, video_mode in [
            ("Q02", "Current desktop video path + FFmpeg silence", "current"),
            ("Q03", "BGRA native desktop video candidate + FFmpeg silence", "bgra-native"),
        ]:
            output = ARTIFACTS / f"{name}.flv"
            command = desktop_command(output, video_mode, "synthetic", None, False)
            phase = PhaseResult(
                name, description, output, command,
                expected_size=(1920, 1080),
            )
            run_phase(phase, None, None, report)
            analyse_phase(phase, expect_video=True, expect_tone=False, report=report)
            phases.append(phase)

        # Real full A/V matrix.  Each phase uses a fresh helper and port pair.
        matrix = [
            ("Q04", "Current 1080p60 video + current async=1000 audio", "current", "async1000", False),
            ("Q05", "BGRA native 1080p60 + current async=1000 audio", "bgra-native", "async1000", False),
            ("Q06", "BGRA clocked 1080p60 + no asynchronous audio correction", "bgra-clocked", "noasync", False),
            ("Q07", "BGRA clocked 1080p60 + gentle async=1 audio correction", "bgra-clocked", "async1", False),
            ("Q08", "BGRA native 1080p60 + current audio + live-style FIFO", "bgra-native", "async1000", True),
            ("Q09", "Fast 720p60 fallback + current audio", "720-fast", "async1000", False),
            ("Q12", "Live D3D11-direct 1080p60 + current audio + live FIFO", "d3d11-direct", "async1000", True),
            ("Q13", "Default dual output: Twitch 1080p60 + YouTube 1440p60", "dual-default", "async1000", True),
        ]
        full_av: list[PhaseResult] = []
        for item in matrix:
            phase = run_real_phase(executable, endpoint_id, *item, report=report)
            phases.append(phase); full_av.append(phase)

        # Audio-only bridge quality: no video capture or encoder interference.
        pair = reserve_pair()
        sdp = ARTIFACTS / "Q10.sdp"
        sdp.write_text(sdp_text(pair.rtp_port, pair.rtcp_port), encoding="ascii")
        helper = start_helper(executable, ARTIFACTS, pair, endpoint_id)
        status = wait_helper(helper, require_capture=True, timeout=4.0)
        q10 = PhaseResult("Q10", "Real WASAPI/RTP audio-only continuity control",
                          ARTIFACTS / "Q10.wav",
                          audio_only_command(ARTIFACTS / "Q10.wav", sdp),
                          helper_status=status)
        if status == "capturing":
            run_phase(q10, helper, pair, report)
            analyse_phase(q10, expect_video=False, expect_tone=True, report=report)
        else:
            metrics, helper_stdout, helper_stderr = stop_helper(helper)
            pair.close()
            q10.helper_metrics = metrics
            q10.failure = status or "helper never reported capture"
            report.section("Q10 — Real WASAPI/RTP audio-only continuity control")
            report.line("FAILED BEFORE FFMPEG: " + q10.failure)
            if metrics: report.line("Helper metrics:\n" + metrics)
            if helper_stdout: report.line(helper_stdout)
            if helper_stderr: report.line(helper_stderr)
        phases.append(q10)

        # Repeat the best complete 1080p full-A/V candidate once. Prefer a path
        # that already passed all dimensions before considering raw score.
        candidates = [phase for phase in full_av
                      if phase.output.suffix == ".flv" and "720p" not in phase.description
                      and phase.video.valid]
        if candidates:
            def repeat_rank(item: PhaseResult) -> tuple[int, int, float]:
                passes = (
                    int(video_quality_pass(item)) +
                    int(audio_quality_pass(item)) +
                    int(sync_quality_pass(item))
                )
                complete = int(passes == 3)
                return complete, passes, phase_score(item)

            best = max(candidates, key=repeat_rank)
            mode_map = {"Q04": ("current", "async1000", False),
                        "Q05": ("bgra-native", "async1000", False),
                        "Q06": ("bgra-clocked", "noasync", False),
                        "Q07": ("bgra-clocked", "async1", False),
                        "Q08": ("bgra-native", "async1000", True),
                        "Q12": ("d3d11-direct", "async1000", True),
                        "Q13": ("dual-default", "async1000", True)}
            if best.name in mode_map:
                video_mode, audio_mode, fifo = mode_map[best.name]
                repeat = run_real_phase(executable, endpoint_id, "Q11",
                    f"Repeat of highest-scoring 1080p path ({best.name})",
                    video_mode, audio_mode, fifo, report)
                phases.append(repeat)

        report.section("FINAL QUALITY VERDICT")
        full_1080 = [phase for phase in phases
                     if phase.name in {
                         "Q04", "Q05", "Q06", "Q07", "Q08", "Q11",
                         "Q12", "Q13",
                     }]
        solid_video = [phase for phase in full_1080 if video_quality_pass(phase)]
        clean_audio = [phase for phase in full_1080 if audio_quality_pass(phase)]
        good_sync = [phase for phase in full_1080 if sync_quality_pass(phase)]
        complete = [phase for phase in full_1080
                    if video_quality_pass(phase) and audio_quality_pass(phase)
                    and sync_quality_pass(phase)]
        repeat = next((phase for phase in phases if phase.name == "Q11"), None)
        repeated_original = None
        if repeat is not None:
            match = re.search(r"\((Q\d+)\)", repeat.description)
            if match:
                repeated_original = next((phase for phase in phases
                                          if phase.name == match.group(1)), None)
        repeated_solid = bool(repeat and repeated_original and
                              video_quality_pass(repeat) and
                              video_quality_pass(repeated_original))
        repeated_complete = bool(repeat and repeated_original and
                                 video_quality_pass(repeat) and
                                 audio_quality_pass(repeat) and
                                 sync_quality_pass(repeat) and
                                 video_quality_pass(repeated_original) and
                                 audio_quality_pass(repeated_original) and
                                 sync_quality_pass(repeated_original))

        report.line("At least one 1080p60 unique-frame cadence pass: " + ("PASS" if solid_video else "FAIL"))
        report.line("Same 1080p path repeated with solid cadence: " + ("PASS" if repeated_solid else "FAIL"))
        report.line("Crack/dropout-free real desktop audio: " + ("PASS" if clean_audio else "FAIL"))
        report.line("Stable low-drift A/V synchronization: " + ("PASS" if good_sync else "FAIL"))
        report.line("Repeated complete solid 1080p60 + clean audio path: " + ("PASS" if repeated_complete else "FAIL"))

        report.line()
        report.line("Phase ranking (higher is better):")
        for phase in sorted(full_1080, key=phase_score, reverse=True):
            report.line(
                f"  {phase.name}: score={phase_score(phase):.2f}; "
                f"unique={phase.video.unique_rate:.3f} FPS; "
                f"video={'PASS' if video_quality_pass(phase) else 'FAIL'}; "
                f"audio={'PASS' if audio_quality_pass(phase) else 'FAIL'}; "
                f"sync={'PASS' if sync_quality_pass(phase) else 'FAIL'}"
            )
        if repeated_complete and repeated_original is not None:
            report.line("RECOMMENDED IMPLEMENTATION PATH: " + repeated_original.name +
                        " — " + repeated_original.description +
                        " (passed both original and repeat runs)")
        else:
            report.line("RECOMMENDED IMPLEMENTATION PATH: none yet; no 1080p path passed all strict thresholds twice.")

        q01 = next((phase for phase in phases if phase.name == "Q01"), None)
        q02 = next((phase for phase in phases if phase.name == "Q02"), None)
        q03 = next((phase for phase in phases if phase.name == "Q03"), None)
        q09 = next((phase for phase in phases if phase.name == "Q09"), None)
        q10 = next((phase for phase in phases if phase.name == "Q10"), None)
        q12 = next((phase for phase in phases if phase.name == "Q12"), None)
        q13 = next((phase for phase in phases if phase.name == "Q13"), None)
        report.line()
        report.line("Automatic bottleneck interpretation:")
        if q01 and q01.video.valid and q01.video.unique_rate >= 59.5:
            report.line("- NVENC/AAC can produce true 60 FPS from a synthetic source; the encoder itself is not the primary limit.")
        if q02 and q03 and q02.video.valid and q03.video.valid:
            delta = q03.video.unique_rate - q02.video.unique_rate
            report.line(f"- Removing redundant scale/color work changed unique cadence by {delta:+.3f} FPS.")
        if q10 and q10.audio.valid and not audio_quality_pass(q10):
            report.line("- Audio-only control still shows continuity/helper defects, so the audio bridge must be fixed independently of video.")
        elif q10 and audio_quality_pass(q10):
            report.line("- Audio-only control is clean; any audio defect in full A/V phases is scheduling/contention between pipelines.")
        if q09 and q09.video.valid and video_quality_pass(q09) and not solid_video:
            report.line("- 720p60 passes while 1080p60 fails, indicating insufficient 1080p capture/readback/conversion headroom on this machine.")
        if q12 and q12.video.valid:
            if video_quality_pass(q12):
                report.line("- The exact live D3D11-direct/FIFO topology sustains 1080p60 without CPU readback.")
            elif (q12.video.width, q12.video.height) != (1920, 1080):
                report.line(
                    f"- D3D11 direct capture produced {q12.video.width}x{q12.video.height}; "
                    "the live zero-copy path cannot activate for a 1080p output on this monitor."
                )
            else:
                report.line("- The exact live D3D11-direct/FIFO topology did not sustain the strict 1080p60 cadence threshold.")
        if q13 and q13.video.valid:
            if video_quality_pass(q13):
                report.line("- The default simultaneous Twitch 1080p60 + YouTube 1440p60 local workload passes both output cadences.")
            else:
                report.line("- The default simultaneous Twitch 1080p60 + YouTube 1440p60 workload does not yet pass both output cadences.")
        if not solid_video:
            report.line("- Encoded 60/1 timestamps are not enough: no 1080p full-A/V path sustained at least 59 unique images per second.")
        if not clean_audio:
            report.line("- One or more real-audio paths inserted/dropped/stretched samples or exposed helper pacing defects; do not call audio fixed.")

        report.line()
        report.line("Strict acceptance thresholds used:")
        report.line(
            "- Video: expected dimensions, >=59.0 visually unique FPS "
            "(adaptive adjacent-luma difference), no duplicate "
            "run over 2 frames, no FFmpeg queue warning, settled speed >=0.98x."
        )
        report.line("- Audio: MMCSS active, zero decoded dropouts/phase jumps, zero helper silence/overflow/stale/pacing loss, packet gap <=30 ms, send <=5 ms.")
        report.line("- Sync: absolute median offset <=120 ms, jitter <=20 ms, drift <=20 ms.")
        report.line("Artifacts remain in: " + str(ARTIFACTS))
        report.line("Upload only this report unless a specific phase file is requested: " + str(REPORT_PATH))
        report.line(f"Finished: {time.strftime('%Y-%m-%d %H:%M:%S')}")
        report.save()
        return 0
    except Exception as error:
        report.section("DIAGNOSTIC FAILURE")
        report.line(type(error).__name__ + ": " + str(error))
        report.line("The partial report and any completed artifacts were preserved.")
        report.save()
        return 2
    finally:
        if test_card is not None and test_card_stderr is not None:
            stop_test_card(test_card, test_card_stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    focused = parser.add_mutually_exclusive_group()
    focused.add_argument(
        "--audio-only", action="store_true",
        help="run only the deterministic real-WASAPI decoded waveform control",
    )
    focused.add_argument(
        "--loaded-audio", action="store_true",
        help="headlessly verify audio during two real desktop/NVENC phases",
    )
    options = parser.parse_args()
    if options.audio_only:
        raise SystemExit(audio_only_main())
    if options.loaded_audio:
        raise SystemExit(loaded_audio_main())
    raise SystemExit(main())
