#!/usr/bin/env python3
"""Aurora Stream one-click Windows diagnostic matrix.

Uses only Python's standard library and the tools already required by Aurora
Stream. It never reads, prints, or transmits stream keys. Every command,
result, timeout, helper status, RTP metric, FFmpeg error, and automatic
conclusion is written to one report file.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import datetime as _datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from typing import Iterable, Sequence


REPORT_VERSION = "1"
CAPTURE_SECONDS = 3
PROCESS_TIMEOUT_SECONDS = 18
HELPER_READY_SECONDS = 6
CRITICAL_REPEATS = 3
PORT_STRESS_ITERATIONS = 12
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


@dataclasses.dataclass
class Result:
    name: str
    status: str
    seconds: float
    detail: str = ""
    category: str = ""


class Report:
    def __init__(self, path: Path, root: Path) -> None:
        self.path = path
        self.root = root
        self.results: list[Result] = []
        self._file = path.open("w", encoding="utf-8", newline="\n")

    def close(self) -> None:
        self._file.flush()
        self._file.close()

    def line(self, text: str = "") -> None:
        clean = self.sanitize(text)
        print(clean, flush=True)
        self._file.write(clean + "\n")
        self._file.flush()

    def raw(self, text: str) -> None:
        for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
            self.line(line)

    def section(self, title: str) -> None:
        self.line()
        self.line(title)
        self.line("=" * len(title))

    def command(self, command: Sequence[str]) -> None:
        self.line("Command: " + self.sanitize_command(command))

    def add(self, name: str, status: str, seconds: float,
            detail: str = "", category: str = "") -> None:
        self.results.append(Result(name, status, seconds, detail, category))
        suffix = f" — {detail}" if detail else ""
        self.line(f"RESULT {status}: {name} ({seconds:.3f} s){suffix}")

    def sanitize_command(self, command: Sequence[str]) -> str:
        sanitized: list[str] = []
        hide_next = False
        for item in command:
            if hide_next:
                sanitized.append("<WASAPI_ENDPOINT_ID>")
                hide_next = False
                continue
            sanitized.append(item)
            if item == "--endpoint":
                hide_next = True
        return subprocess.list2cmdline(sanitized)

    def sanitize(self, text: str) -> str:
        # The diagnostic never reads streaming keys. These replacements are a
        # final safeguard for unexpected FFmpeg or environment output.
        result = text
        home = str(Path.home())
        if home:
            result = result.replace(home, "%USERPROFILE%")
        result = re.sub(
            r"(?i)(stream[_ -]?key\s*[:=]\s*)\S+",
            r"\1<REDACTED>", result,
        )
        result = re.sub(
            r"(?i)(rtmps?://[^\s/]+/[^\s/]+/)[^\s]+",
            r"\1<REDACTED>", result,
        )
        result = result.replace("\x00", "<NUL>")
        return result


@dataclasses.dataclass
class Completed:
    returncode: int | None
    stdout: str
    stderr: str
    timed_out: bool
    seconds: float


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
    synthetic: bool
    ready_status: str = ""


@dataclasses.dataclass
class RtpCaseOutcome:
    completed: Completed
    helper_status: str
    helper_metrics: str
    helper_returncode: int | None
    output_summary: str
    output_ok: bool
    packet_bind_seen: bool


def which(name: str) -> str | None:
    return shutil.which(name)


def run(command: Sequence[str], timeout: float = 30,
        cwd: Path | None = None, env: dict[str, str] | None = None) -> Completed:
    started = time.perf_counter()
    try:
        process = subprocess.run(
            list(command), cwd=str(cwd) if cwd else None, env=env,
            text=True, capture_output=True, timeout=timeout,
            creationflags=CREATE_NO_WINDOW,
        )
        return Completed(process.returncode, process.stdout, process.stderr,
                         False, time.perf_counter() - started)
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or ""
        stderr = error.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
        return Completed(None, stdout, stderr, True,
                         time.perf_counter() - started)
    except Exception as error:
        return Completed(None, "", f"Could not start command: {error}", False,
                         time.perf_counter() - started)


def log_completed(report: Report, completed: Completed) -> None:
    report.line(f"Return code: {completed.returncode}")
    report.line(f"Timed out: {'yes' if completed.timed_out else 'no'}")
    report.line(f"Wall time: {completed.seconds:.3f} s")
    if completed.stdout.strip():
        report.line("--- stdout ---")
        report.raw(completed.stdout.rstrip())
    if completed.stderr.strip():
        report.line("--- stderr ---")
        report.raw(completed.stderr.rstrip())


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while True:
            block = source.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def reserve_udp_pair() -> tuple[int, int, socket.socket, socket.socket]:
    for _ in range(256):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.bind(("127.0.0.1", 0))
            port = int(probe.getsockname()[1]) & ~1
        if not 1024 <= port <= 65534:
            continue
        rtp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        rtcp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            rtp.bind(("127.0.0.1", port))
            rtcp.bind(("127.0.0.1", port + 1))
            return port, port + 1, rtp, rtcp
        except OSError:
            rtp.close()
            rtcp.close()
    raise RuntimeError("Could not reserve an adjacent RTP/RTCP port pair")


def port_is_bound(port: int) -> bool:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.bind(("127.0.0.1", port))
        return False
    except OSError:
        return True
    finally:
        probe.close()


def wait_port_bound(port: int, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if port_is_bound(port):
            return True
        time.sleep(0.025)
    return port_is_bound(port)


def write_sdp(path: Path, port: int, rtcp_port: int) -> None:
    path.write_text(
        "v=0\r\n"
        "o=- 0 0 IN IP4 127.0.0.1\r\n"
        "s=Aurora Stream full diagnostic\r\n"
        "c=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\n"
        f"m=audio {port} RTP/AVP 96\r\n"
        "a=rtpmap:96 L16/48000/2\r\n"
        f"a=rtcp:{rtcp_port} IN IP4 127.0.0.1\r\n"
        "a=ptime:20\r\n"
        "a=recvonly\r\n",
        encoding="ascii",
        newline="",
    )


def wait_helper_status(helper: Helper, timeout: float) -> str:
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        if helper.status_path.exists():
            try:
                last = helper.status_path.read_text(encoding="utf-8", errors="replace").strip()
            except OSError:
                last = ""
            if last == "ready" or last.startswith("error:"):
                helper.ready_status = last
                return last
        if helper.process.poll() is not None:
            break
        time.sleep(0.02)
    if helper.status_path.exists():
        with contextlib.suppress(OSError):
            last = helper.status_path.read_text(encoding="utf-8", errors="replace").strip()
    helper.ready_status = last
    return last


def start_helper(executable: Path, folder: Path, port: int, rtcp_port: int,
                 synthetic: bool, endpoint_id: str) -> Helper:
    token = f"helper-{port}-{time.time_ns()}"
    status = folder / f"{token}.status"
    stop = folder / f"{token}.stop"
    metrics = folder / f"{token}.metrics"
    stdout_path = folder / f"{token}.stdout.txt"
    stderr_path = folder / f"{token}.stderr.txt"
    stdout_file = stdout_path.open("w", encoding="utf-8")
    stderr_file = stderr_path.open("w", encoding="utf-8")
    command = [
        str(executable), "--audio-rtp-helper",
        "--port", str(port),
        "--status", str(status),
        "--stop", str(stop),
        "--metrics", str(metrics),
    ]
    if synthetic:
        command.append("--synthetic")
    else:
        command += ["--endpoint", endpoint_id]
    process = subprocess.Popen(
        command, cwd=str(executable.parent), text=True,
        stdout=stdout_file, stderr=stderr_file,
        creationflags=CREATE_NO_WINDOW,
    )
    return Helper(process, status, stop, metrics, stdout_path, stderr_path,
                  stdout_file, stderr_file, port, rtcp_port, synthetic)


def stop_helper(helper: Helper) -> tuple[int | None, str, str, str]:
    with contextlib.suppress(OSError):
        helper.stop_path.write_text("stop\r\n", encoding="ascii")
    try:
        helper.process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        helper.process.terminate()
        try:
            helper.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            helper.process.kill()
            helper.process.wait(timeout=2)
    helper.stdout_file.close()
    helper.stderr_file.close()
    metrics = ""
    stdout = ""
    stderr = ""
    with contextlib.suppress(OSError):
        metrics = helper.metrics_path.read_text(encoding="utf-8", errors="replace").strip()
    with contextlib.suppress(OSError):
        stdout = helper.stdout_path.read_text(encoding="utf-8", errors="replace").strip()
    with contextlib.suppress(OSError):
        stderr = helper.stderr_path.read_text(encoding="utf-8", errors="replace").strip()
    return helper.process.returncode, metrics, stdout, stderr


def helper_metric(metrics: str, key: str) -> int | None:
    match = re.search(rf"(?m)^{re.escape(key)}=(\d+)\s*$", metrics)
    return int(match.group(1)) if match else None


def ffmpeg_common() -> list[str]:
    return [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "warning",
        "-nostdin", "-stats_period", "0.5", "-progress", "pipe:2",
    ]


def video_input(mode: str) -> list[str]:
    if mode == "testsrc":
        return ["-re", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=60"]
    if mode == "ddagrab-cpu":
        return [
            "-thread_queue_size", "512", "-f", "lavfi", "-i",
            "ddagrab=output_idx=0:framerate=60:draw_mouse=1:dup_frames=1,"
            "hwdownload,format=bgra",
        ]
    if mode == "ddagrab-direct":
        return [
            "-thread_queue_size", "512", "-f", "lavfi", "-i",
            "ddagrab=output_idx=0:framerate=60:draw_mouse=1:dup_frames=1",
        ]
    if mode == "gdigrab":
        return [
            "-thread_queue_size", "512", "-f", "gdigrab",
            "-framerate", "60", "-draw_mouse", "0", "-i", "desktop",
        ]
    raise ValueError(mode)


def cpu_video_filter(audio_input_index: int, rtp_audio: bool) -> str:
    audio = (
        f"[{audio_input_index}:a]aresample=48000:async=1000:first_pts=0,"
        "aformat=sample_rates=48000:channel_layouts=stereo,"
        "asetpts=PTS-STARTPTS[a]"
        if rtp_audio else
        f"[{audio_input_index}:a]aresample=48000:first_pts=0,"
        "aformat=sample_rates=48000:channel_layouts=stereo,"
        "asetpts=N/SR/TB[a]"
    )
    return (
        "[0:v]fps=fps=60:start_time=0:round=near,settb=AVTB,"
        "setpts=N/(60*TB),"
        "scale=1920:1080:force_original_aspect_ratio=decrease:flags=bicubic,"
        "pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[v];"
        + audio
    )


def output_args(output: Path, fifo: bool, encoder: str = "h264_nvenc") -> list[str]:
    video = [
        "-r:v", "60", "-fps_mode:v", "cfr",
        "-c:v", encoder,
    ]
    if encoder == "h264_nvenc":
        video += [
            "-preset", "p3", "-tune", "ll", "-rc", "cbr",
            "-b:v", "6000k", "-maxrate", "6000k", "-bufsize", "12000k",
            "-profile:v", "high", "-level:v", "4.2", "-g", "120",
            "-keyint_min", "120", "-bf", "2",
        ]
    else:
        video += ["-preset", "ultrafast", "-b:v", "6000k", "-g", "120"]
    audio = [
        "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-ac", "2",
        "-max_muxing_queue_size", "2048", "-flags", "+global_header",
        "-t", str(CAPTURE_SECONDS),
    ]
    if not fifo:
        mux = [
            "-max_interleave_delta", "0", "-flush_packets", "1",
            "-flvflags", "no_duration_filesize", "-f", "flv", str(output),
        ]
    else:
        mux = [
            "-f", "fifo", "-fifo_format", "flv", "-queue_size", "120",
            "-format_opts",
            "max_interleave_delta=0:flush_packets=1:flvflags=no_duration_filesize",
            "-attempt_recovery", "1", "-recovery_wait_time", "1",
            "-drop_pkts_on_overflow", "1", "-restart_with_keyframe", "1",
            str(output),
        ]
    return video + audio + mux


def synthetic_av_command(output: Path, video_mode: str, fifo: bool,
                         encoder: str = "h264_nvenc") -> list[str]:
    command = ffmpeg_common() + video_input(video_mode)
    command += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
    if video_mode == "ddagrab-direct":
        command += [
            "-map", "0:v", "-map", "1:a", "-fps_mode:v", "passthrough",
            "-c:v", "h264_nvenc", "-preset", "p3", "-tune", "ll",
            "-rc", "cbr", "-b:v", "6000k", "-maxrate", "6000k",
            "-bufsize", "12000k", "-profile:v", "high", "-level:v", "4.2",
            "-g", "120", "-keyint_min", "120", "-bf", "2",
            "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-ac", "2",
            "-t", str(CAPTURE_SECONDS), "-f", "flv", str(output),
        ]
        return command
    command += [
        "-filter_complex", cpu_video_filter(1, False),
        "-map", "[v]", "-map", "[a]",
    ]
    command += output_args(output, fifo, encoder)
    return command


def rtp_av_command(output: Path, sdp: Path, video_mode: str, fifo: bool,
                   tuning: str, encoder: str = "h264_nvenc") -> list[str]:
    command = ffmpeg_common() + video_input(video_mode)
    command += ["-protocol_whitelist", "file,udp,rtp"]
    if tuning == "fast-probe":
        command += [
            "-analyzeduration", "0", "-probesize", "32",
            "-fflags", "+nobuffer", "-max_delay", "0",
            "-reorder_queue_size", "0",
        ]
    elif tuning == "bounded-probe":
        command += [
            "-analyzeduration", "1000000", "-probesize", "32768",
            "-rw_timeout", "5000000",
        ]
    command += [
        "-thread_queue_size", "64", "-f", "sdp", "-i", str(sdp),
        "-filter_complex", cpu_video_filter(1, True),
        "-map", "[v]", "-map", "[a]",
    ]
    command += output_args(output, fifo, encoder)
    return command


def rtp_audio_only_command(output: Path, sdp: Path, tuning: str) -> list[str]:
    command = ffmpeg_common() + ["-protocol_whitelist", "file,udp,rtp"]
    if tuning == "fast-probe":
        command += [
            "-analyzeduration", "0", "-probesize", "32",
            "-fflags", "+nobuffer", "-max_delay", "0",
            "-reorder_queue_size", "0",
        ]
    elif tuning == "bounded-probe":
        command += ["-analyzeduration", "1000000", "-probesize", "32768",
                    "-rw_timeout", "5000000"]
    command += [
        "-thread_queue_size", "64", "-f", "sdp", "-i", str(sdp),
        "-map", "0:a", "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2",
        "-t", str(CAPTURE_SECONDS), "-f", "wav", str(output),
    ]
    return command


def probe_output(path: Path, expect_video: bool, report: Report) -> tuple[bool, str]:
    if not path.exists() or path.stat().st_size == 0:
        return False, "no output file"
    command = [
        "ffprobe", "-v", "error", "-count_frames", "-show_entries",
        "format=duration,size:stream=index,codec_type,codec_name,avg_frame_rate,"
        "sample_rate,channels,nb_read_frames", "-of", "json", str(path),
    ]
    completed = run(command, timeout=20)
    if completed.returncode != 0:
        return False, "ffprobe failed: " + completed.stderr.strip()
    try:
        data = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        return False, f"invalid ffprobe JSON: {error}"
    streams = data.get("streams", [])
    audio = next((stream for stream in streams if stream.get("codec_type") == "audio"), None)
    video = next((stream for stream in streams if stream.get("codec_type") == "video"), None)
    if audio is None:
        return False, "output has no audio stream"
    if expect_video and video is None:
        return False, "output has no video stream"
    summary = {
        "format": data.get("format", {}),
        "audio": audio,
        "video": video,
    }
    report.line("ffprobe summary: " + json.dumps(summary, sort_keys=True))
    if expect_video:
        frame_count = int((video or {}).get("nb_read_frames") or 0)
        if frame_count < 120:
            return False, f"too few decoded video frames: {frame_count}"
    return True, f"{path.stat().st_size} bytes"


def duplicate_analysis(path: Path, report: Report) -> str:
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(path),
        "-map", "0:v:0", "-f", "framemd5", "-",
    ]
    completed = run(command, timeout=30)
    if completed.returncode != 0:
        return "duplicate analysis failed: " + completed.stderr.strip()
    previous = None
    frames = 0
    duplicates = 0
    longest = 1
    current = 1
    for line in completed.stdout.splitlines():
        if not line or line.startswith("#") or "," not in line:
            continue
        digest = line.rsplit(",", 1)[-1].strip()
        if not re.fullmatch(r"[0-9a-fA-F]{32}", digest):
            continue
        frames += 1
        if digest == previous:
            duplicates += 1
            current += 1
            longest = max(longest, current)
        else:
            current = 1
        previous = digest
    if frames == 0:
        return "no frame hashes"
    unique_rate = (frames - duplicates) / CAPTURE_SECONDS
    text = (f"frames={frames}, consecutive_duplicates={duplicates}, "
            f"longest_identical_run={longest}, effective_unique_rate={unique_rate:.3f} fps")
    report.line("Decoded image analysis: " + text)
    return text


def netstat_for_ports(ports: Iterable[int]) -> str:
    completed = run(["netstat", "-ano", "-p", "udp"], timeout=10)
    if completed.returncode not in (0, None):
        return completed.stderr.strip()
    port_tokens = {f":{port}" for port in ports}
    lines = [line for line in completed.stdout.splitlines()
             if any(token in line for token in port_tokens)]
    return "\n".join(lines) if lines else "(no matching UDP entries)"


def run_simple_case(report: Report, name: str, command: list[str],
                    output: Path | None, expect_video: bool,
                    category: str) -> bool:
    report.section(name)
    report.command(command)
    completed = run(command, timeout=PROCESS_TIMEOUT_SECONDS)
    log_completed(report, completed)
    output_ok = True
    detail = ""
    if output is not None:
        output_ok, detail = probe_output(output, expect_video, report)
        if output_ok and expect_video:
            detail += "; " + duplicate_analysis(output, report)
    passed = completed.returncode == 0 and not completed.timed_out and output_ok
    report.add(name, "PASS" if passed else ("TIMEOUT" if completed.timed_out else "FAIL"),
               completed.seconds, detail, category)
    return passed


def run_helper_standalone(report: Report, executable: Path, folder: Path,
                          endpoint_id: str, synthetic: bool, name: str) -> bool:
    report.section(name)
    port, rtcp_port, rtp, rtcp = reserve_udp_pair()
    rtp.settimeout(0.1)
    report.line(f"Reserved destination RTP={port}, RTCP={rtcp_port}")
    helper = start_helper(executable, folder, port, rtcp_port, synthetic, endpoint_id)
    report.command([
        str(executable), "--audio-rtp-helper", "--port", str(port),
        "--status", str(helper.status_path), "--stop", str(helper.stop_path),
        "--metrics", str(helper.metrics_path),
    ] + (["--synthetic"] if synthetic else ["--endpoint", endpoint_id]))
    started = time.perf_counter()
    status = wait_helper_status(helper, HELPER_READY_SECONDS)
    report.line("Helper status: " + (status or "(missing)"))
    packets = 0
    valid_packets = 0
    deadline = time.monotonic() + CAPTURE_SECONDS
    while status == "ready" and time.monotonic() < deadline:
        try:
            packet, _ = rtp.recvfrom(65535)
            packets += 1
            if len(packet) == 3852 and packet[:1] == b"\x80":
                valid_packets += 1
        except socket.timeout:
            pass
    rtp.close()
    rtcp.close()
    returncode, metrics, stdout, stderr = stop_helper(helper)
    report.line(f"RTP packets received by Python: {packets}")
    report.line(f"Valid 3,852-byte RTP packets: {valid_packets}")
    report.line(f"Helper return code: {returncode}")
    if metrics:
        report.line("--- helper metrics ---")
        report.raw(metrics)
    if stdout:
        report.line("--- helper stdout ---")
        report.raw(stdout)
    if stderr:
        report.line("--- helper stderr ---")
        report.raw(stderr)
    captured = helper_metric(metrics, "packets_captured")
    passed = status == "ready" and valid_packets > 0 and returncode == 0
    if not synthetic:
        passed = passed and captured is not None and captured > 0
    detail = f"status={status or 'missing'}, valid_rtp={valid_packets}, packets_captured={captured}"
    report.add(name, "PASS" if passed else "FAIL", time.perf_counter() - started,
               detail, "helper")
    return passed


def run_rtp_case(report: Report, executable: Path, folder: Path,
                 endpoint_id: str, *, name: str, synthetic: bool,
                 ordering: str, video_mode: str | None, fifo: bool,
                 tuning: str) -> RtpCaseOutcome:
    report.section(name)
    port, rtcp_port, rtp_reservation, rtcp_reservation = reserve_udp_pair()
    sdp = folder / f"{re.sub(r'[^A-Za-z0-9_.-]+', '-', name)}.sdp"
    extension = ".wav" if video_mode is None else ".flv"
    output = folder / f"{re.sub(r'[^A-Za-z0-9_.-]+', '-', name)}{extension}"
    write_sdp(sdp, port, rtcp_port)
    report.line(f"RTP destination={port}, RTCP={rtcp_port}, ordering={ordering}, tuning={tuning}")

    if video_mode is None:
        command = rtp_audio_only_command(output, sdp, tuning)
    else:
        command = rtp_av_command(output, sdp, video_mode, fifo, tuning)
    report.command(command)

    helper: Helper | None = None
    process: subprocess.Popen[str] | None = None
    started = time.perf_counter()
    ffmpeg_stdout = ""
    ffmpeg_stderr = ""
    timed_out = False
    packet_bind_seen = False
    helper_status = ""
    helper_metrics = ""
    helper_returncode: int | None = None
    helper_stdout = ""
    helper_stderr = ""

    try:
        if ordering == "helper-first-current":
            helper = start_helper(executable, folder, port, rtcp_port,
                                  synthetic, endpoint_id)
            helper_status = wait_helper_status(helper, HELPER_READY_SECONDS)
            report.line("Helper status before FFmpeg: " + (helper_status or "(missing)"))
            report.line("UDP state while reservations are held:")
            report.raw(netstat_for_ports([port, rtcp_port]))
            rtp_reservation.close()
            rtcp_reservation.close()
            process = subprocess.Popen(
                command, cwd=str(executable.parent), text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                creationflags=CREATE_NO_WINDOW,
            )
        elif ordering == "receiver-first":
            rtp_reservation.close()
            rtcp_reservation.close()
            process = subprocess.Popen(
                command, cwd=str(executable.parent), text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                creationflags=CREATE_NO_WINDOW,
            )
            packet_bind_seen = wait_port_bound(port, 3.0)
            report.line(f"FFmpeg RTP port became bound before helper: {'yes' if packet_bind_seen else 'no'}")
            report.line("UDP state before helper launch:")
            report.raw(netstat_for_ports([port, rtcp_port]))
            helper = start_helper(executable, folder, port, rtcp_port,
                                  synthetic, endpoint_id)
            helper_status = wait_helper_status(helper, HELPER_READY_SECONDS)
            report.line("Helper status after FFmpeg: " + (helper_status or "(missing)"))
        else:
            raise ValueError(ordering)

        try:
            ffmpeg_stdout, ffmpeg_stderr = process.communicate(timeout=PROCESS_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.kill()
            ffmpeg_stdout, ffmpeg_stderr = process.communicate(timeout=3)
    except Exception as error:
        ffmpeg_stderr += f"\nDiagnostic orchestration error: {error}\n"
    finally:
        with contextlib.suppress(OSError):
            rtp_reservation.close()
        with contextlib.suppress(OSError):
            rtcp_reservation.close()
        if helper is not None:
            helper_returncode, helper_metrics, helper_stdout, helper_stderr = stop_helper(helper)

    completed = Completed(
        process.returncode if process is not None else None,
        ffmpeg_stdout, ffmpeg_stderr, timed_out,
        time.perf_counter() - started,
    )
    log_completed(report, completed)
    report.line(f"Helper final status: {helper_status or '(missing)'}")
    report.line(f"Helper return code: {helper_returncode}")
    if helper_metrics:
        report.line("--- helper metrics ---")
        report.raw(helper_metrics)
    if helper_stdout:
        report.line("--- helper stdout ---")
        report.raw(helper_stdout)
    if helper_stderr:
        report.line("--- helper stderr ---")
        report.raw(helper_stderr)
    report.line("Final UDP state:")
    report.raw(netstat_for_ports([port, rtcp_port]))

    output_ok, output_summary = probe_output(output, video_mode is not None, report)
    if output_ok and video_mode is not None:
        output_summary += "; " + duplicate_analysis(output, report)
    captured = helper_metric(helper_metrics, "packets_captured")
    sent = helper_metric(helper_metrics, "rtp_packets_sent")
    send_failures = helper_metric(helper_metrics, "send_failures")
    valid_helper = helper_status == "ready" and helper_returncode == 0
    if not synthetic:
        valid_helper = valid_helper and captured is not None and captured > 0
    passed = (completed.returncode == 0 and not completed.timed_out and
              output_ok and valid_helper and (sent is None or sent > 0) and
              (send_failures is None or send_failures == 0))
    detail = (
        f"ordering={ordering}, helper={helper_status or 'missing'}, "
        f"captured={captured}, sent={sent}, send_failures={send_failures}, "
        f"output={output_summary}"
    )
    report.add(name, "PASS" if passed else ("TIMEOUT" if timed_out else "FAIL"),
               completed.seconds, detail, "rtp")
    return RtpCaseOutcome(completed, helper_status, helper_metrics,
                          helper_returncode, output_summary, output_ok,
                          packet_bind_seen)


def parse_endpoints(executable: Path, report: Report) -> tuple[str, list[dict[str, object]]]:
    command = [str(executable), "--list-audio-endpoints-json"]
    report.command(command)
    completed = run(command, timeout=15, cwd=executable.parent)
    report.line(f"Return code: {completed.returncode}")
    report.line(f"Timed out: {'yes' if completed.timed_out else 'no'}")
    report.line(f"Wall time: {completed.seconds:.3f} s")
    if completed.stderr.strip():
        report.line("--- endpoint enumeration stderr ---")
        report.raw(completed.stderr.rstrip())
    report.line("Endpoint IDs are intentionally omitted from this report.")
    if completed.returncode != 0:
        return "", []
    try:
        data = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        report.line(f"Endpoint JSON parse error: {error}")
        return "", []
    endpoints = data.get("endpoints", [])
    error = str(data.get("error", ""))
    if error:
        report.line("WASAPI enumeration warning: " + error)
    selected = ""
    for index, endpoint in enumerate(endpoints, 1):
        label = str(endpoint.get("label", ""))
        is_default = bool(endpoint.get("default", False))
        report.line(f"Endpoint {index}: {label}; default={'yes' if is_default else 'no'}")
        if is_default and not selected:
            selected = str(endpoint.get("id", ""))
    if not selected and endpoints:
        selected = str(endpoints[0].get("id", ""))
    return selected, endpoints


def source_audit(root: Path, report: Report) -> None:
    report.section("Static startup-path audit")
    broadcast = (root / "source" / "aurorastream" / "broadcast.d").read_text(encoding="utf-8")
    bridge = (root / "source" / "aurorastream" / "audiobridge.d").read_text(encoding="utf-8")
    findings: list[tuple[str, bool, str]] = [
        (
            "FFmpeg has a bounded startup timeout",
            "startupDeadlineTicks" in broadcast and "monitorProcess" in broadcast,
            "The worker must terminate a pre-progress FFmpeg stall instead of remaining on Connecting indefinitely.",
        ),
        (
            "Helper failures are polled independently of FFmpeg stderr",
            "monitorProcess" in broadcast and "inspectDesktopAudio(bridge)" in broadcast,
            "The helper must be inspected even when FFmpeg emits no progress lines.",
        ),
        (
            "Helper transport readiness is distinct from real packet capture",
            "transport-ready" in broadcast and "captureActive()" in bridge,
            "The helper reports transport readiness first and real WASAPI packet capture separately.",
        ),
        (
            "Live RTMP/TLS output is isolated from capture and encoding",
            '"-f", "fifo", "-fifo_format", "flv"' in broadcast and
            '"-drop_pkts_on_overflow", "1"' in broadcast,
            "A stalled RTMP/TLS handshake must not prevent FFmpeg from capturing and encoding frames.",
        ),
        (
            "RTP and RTCP are explicitly paired",
            "reserveLocalRtpReceiverPair" in bridge and "a=rtcp:" in bridge,
            "Adjacent RTP/RTCP reservation is present.",
        ),
        (
            "Receiver reservation sockets cannot leak into the helper process",
            "SetHandleInformation" in bridge and
            "HANDLE_FLAG_INHERIT" in bridge and
            "validateReceiverReservationHandoff" in bridge and
            "desktopBridge.validateReceiverReservationHandoff" in broadcast,
            "Reservation sockets are non-inheritable and the same RTP/RTCP pair is closed and reacquired before FFmpeg launch.",
        ),
    ]
    for title, passed, explanation in findings:
        status = "PASS" if passed else "DESIGN RISK"
        report.line(f"{status}: {title}")
        report.line("  " + explanation)
        report.results.append(Result("Audit: " + title, status, 0.0,
                                     explanation, "audit"))


def dshow_loopback_candidates(listing: str) -> list[str]:
    candidates: list[str] = []
    in_audio = False
    pending: str | None = None
    for raw in listing.splitlines():
        line = raw.strip()
        if "DirectShow audio devices" in line:
            in_audio = True
            continue
        if "DirectShow video devices" in line:
            in_audio = False
            continue
        quoted = re.search(r'"([^"]+)"', line)
        if not quoted:
            continue
        name = quoted.group(1)
        typed_audio = "(audio)" in line
        if "Alternative name" in line and pending:
            if re.search(r"(?i)stereo mix|what u hear|wave out mix|virtual-audio-capturer|loopback", pending):
                candidates.append(name)
            pending = None
            continue
        if in_audio or typed_audio:
            pending = name
            if re.search(r"(?i)stereo mix|what u hear|wave out mix|virtual-audio-capturer|loopback", name):
                candidates.append(name)
    return list(dict.fromkeys(candidates))


def run_dshow_candidate(report: Report, folder: Path, input_name: str) -> bool:
    name = "OPTIONAL DirectShow loopback candidate"
    output = folder / "dshow-loopback.wav"
    command = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "warning", "-nostdin",
        "-f", "dshow", "-audio_buffer_size", "50", "-i", "audio=" + input_name,
        "-t", str(CAPTURE_SECONDS), "-c:a", "pcm_s16le", "-ar", "48000",
        "-ac", "2", "-f", "wav", str(output),
    ]
    return run_simple_case(report, name, command, output, False, "alternative")


def summarize(report: Report) -> None:
    report.section("FINAL SUMMARY")
    counts: dict[str, int] = {}
    for result in report.results:
        counts[result.status] = counts.get(result.status, 0) + 1
    report.line("Result counts: " + ", ".join(f"{key}={value}" for key, value in sorted(counts.items())))
    report.line()
    for result in report.results:
        suffix = f" — {result.detail}" if result.detail else ""
        report.line(f"[{result.status}] {result.name}{suffix}")

    by_name = {result.name: result for result in report.results}
    report.section("AUTOMATIC INTERPRETATION")
    helper_real = by_name.get("W01 Real WASAPI helper standalone")
    current_real = [result for result in report.results if result.name.startswith("W05 Current helper-first real A/V")]
    receiver_real = [result for result in report.results if result.name.startswith("W04 Receiver-first real A/V")]
    synthetic_current = by_name.get("S04 Current helper-first synthetic RTP A/V")
    synthetic_receiver = by_name.get("S03 Receiver-first synthetic RTP A/V")
    baseline = by_name.get("V02 Desktop Duplication CPU + NVENC + FFmpeg silence")
    network_isolation = by_name.get("B06 Stalled RTMP output isolation")

    if (current_real and all(item.status == "PASS" for item in current_real) and
            network_isolation and network_isolation.status == "PASS"):
        report.line("PRIMARY: helper-first real WASAPI A/V is operational, and the stalled-RTMP test proves live network output must remain behind the bounded FIFO worker.")
    elif current_real and all(item.status == "PASS" for item in current_real):
        report.line("PRIMARY: helper-first real WASAPI A/V passed every repeated local run. Resolve the first failing network-isolation/startup test before changing capture again.")
    elif current_real and any(item.status == "PASS" for item in current_real):
        report.line("PRIMARY: helper-first real WASAPI A/V works but is intermittent. Keep helper-first ordering and fix live startup supervision/output wrapping before changing capture again.")
    elif current_real and all(item.status != "PASS" for item in current_real) and receiver_real and any(item.status == "PASS" for item in receiver_real):
        report.line("PRIMARY: receiver-first works while helper-first fails. Reverse startup ownership only in that case.")
    elif synthetic_current and synthetic_current.status != "PASS" and synthetic_receiver and synthetic_receiver.status == "PASS":
        report.line("PRIMARY: helper-first RTP is broken even with generated silence; WASAPI is not the cause.")
    elif baseline and baseline.status != "PASS":
        report.line("PRIMARY: video capture/encoder baseline fails without external audio. Resolve capture/NVENC before audio integration.")
    elif helper_real and helper_real.status != "PASS":
        report.line("The short standalone helper test captured no packets, but this is not conclusive unless audio was continuously active. Prefer the full real A/V results.")
    else:
        report.line("No single cause was proven automatically. Use the first failing dependency in the summary and its complete stderr/metrics above.")

    report.line()
    report.line("Expected live implementation after this diagnostic:")
    report.line("- Keep the helper-first real-WASAPI/RTP order proven by the repeated W05 runs.")
    report.line("- Use bounded FIFO isolation for every live RTMP/RTMPS destination; direct FLV is local-diagnostic-only.")
    report.line("- Enforce a startup deadline and monitor helper failures independently of FFmpeg progress.")
    report.line("- Persist sanitized FFmpeg arguments, stderr, exit code, and helper metrics in aurora-stream-startup.log.")
    report.line()
    report.line("This report contains no stream keys. Localhost and local files were used only.")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    root = Path(args.root).resolve()
    report_path = Path(args.report).resolve()
    report = Report(report_path, root)
    try:
        report.line("Aurora Stream full diagnostic")
        report.line("=============================")
        report.line(f"Diagnostic schema: {REPORT_VERSION}")
        report.line(f"Started: {_datetime.datetime.now().astimezone().isoformat()}")
        report.line(f"Python: {sys.version.replace(chr(10), ' ')}")
        report.line(f"Working directory: {root}")
        report.line("Privacy: stream keys are neither read nor transmitted.")
        report.line("Scope: build, source audit, FFmpeg capabilities, capture, NVENC, RTP/RTCP, helper process, WASAPI, startup order, muxing, timeout behavior, and optional DirectShow loopback.")

        report.section("Tool and system inventory")
        inventory_commands = [
            ["cmd", "/c", "ver"],
            ["where", "dub"],
            ["where", "dmd"],
            ["where", "ffmpeg"],
            ["where", "ffprobe"],
            ["dub", "--version"],
            ["dmd", "--version"],
            ["ffmpeg", "-version"],
            ["ffmpeg", "-hide_banner", "-buildconf"],
            ["ffmpeg", "-hide_banner", "-devices"],
            ["ffmpeg", "-hide_banner", "-hwaccels"],
            ["ffmpeg", "-hide_banner", "-encoders"],
            ["ffmpeg", "-hide_banner", "-protocols"],
            ["nvidia-smi"],
            ["powershell", "-NoProfile", "-Command", "Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,AdapterRAM | Format-List"],
            ["sc", "query", "Audiosrv"],
            ["sc", "query", "AudioEndpointBuilder"],
            ["netsh", "int", "ipv4", "show", "dynamicport", "udp"],
            ["netsh", "int", "ipv4", "show", "excludedportrange", "protocol=udp"],
            ["netstat", "-ano", "-p", "udp"],
            ["ffmpeg", "-hide_banner", "-h", "encoder=h264_nvenc"],
            ["ffmpeg", "-hide_banner", "-h", "filter=ddagrab"],
            ["ffmpeg", "-hide_banner", "-h", "demuxer=dshow"],
            ["ffmpeg", "-hide_banner", "-h", "demuxer=wasapi"],
            ["wevtutil", "qe", "Application", "/q:*[System[(Level=2) and TimeCreated[timediff(@SystemTime) <= 3600000]]]", "/c:20", "/rd:true", "/f:text"],
            ["tasklist", "/FI", "IMAGENAME eq aurora-stream.exe"],
        ]
        required_missing = False
        for command in inventory_commands:
            report.command(command)
            completed = run(command, timeout=20, cwd=root)
            log_completed(report, completed)
            if command[0] in ("dub", "dmd", "ffmpeg") and completed.returncode not in (0,):
                if command[:2] in (["dub", "--version"], ["dmd", "--version"], ["ffmpeg", "-version"]):
                    required_missing = True
        for required_tool in ("dub", "dmd", "ffmpeg", "ffprobe"):
            if which(required_tool) is None:
                report.line(f"REQUIRED TOOL MISSING: {required_tool}")
                required_missing = True

        report.section("Prior Aurora Stream diagnostic artifacts")
        startup_log = root / "aurora-stream-startup.log"
        if startup_log.exists():
            report.line("--- aurora-stream-startup.log ---")
            report.raw(startup_log.read_text(encoding="utf-8", errors="replace"))
        else:
            report.line("aurora-stream-startup.log: (not present)")
        temp_root = Path(tempfile.gettempdir())
        stale_files = sorted(temp_root.glob("aurora-stream-audio-*"), key=lambda item: item.stat().st_mtime, reverse=True)[:40]
        if stale_files:
            for stale in stale_files:
                report.line(f"--- stale helper artifact: {stale.name} ---")
                if stale.suffix in (".status", ".metrics"):
                    with contextlib.suppress(OSError):
                        report.raw(stale.read_text(encoding="utf-8", errors="replace"))
        else:
            report.line("No stale aurora-stream-audio-* helper artifacts found in %TEMP%.")

        source_audit(root, report)

        report.section("Build and source tests")
        build_commands = [
            ("B01 DUB clean", ["dub", "clean"], 60),
            ("B02 Debug build", ["dub", "build", "--build=debug"], 180),
            ("B03 D unit tests", ["dub", "test"], 180),
            ("B04 Static A/V architecture checks", [sys.executable, str(root / "tests" / "verify-audio-transport.py")], 60),
            ("B05 RTP/SDP standard-library integration", [sys.executable, str(root / "tests" / "verify-rtp-sdp.py")], 60),
            ("B06 Stalled RTMP output isolation", [sys.executable, str(root / "tests" / "verify-network-output-isolation.py")], 45),
        ]
        build_ok = True
        for name, command, timeout in build_commands:
            report.section(name)
            report.command(command)
            completed = run(command, timeout=timeout, cwd=root)
            log_completed(report, completed)
            passed = completed.returncode == 0 and not completed.timed_out
            report.add(name, "PASS" if passed else ("TIMEOUT" if completed.timed_out else "FAIL"),
                       completed.seconds, category="build")
            if name == "B02 Debug build" and not passed:
                build_ok = False

        executable = root / "aurora-stream.exe"
        if not executable.exists():
            candidates = list(root.glob("**/aurora-stream.exe"))
            if candidates:
                executable = candidates[0]
        if executable.exists():
            report.line(f"Built executable: {executable}")
            report.line(f"Executable SHA-256: {sha256(executable)}")
            version = run([str(executable), "--version"], timeout=10, cwd=root)
            log_completed(report, version)
        else:
            report.line("ERROR: aurora-stream.exe was not produced.")
            build_ok = False

        if required_missing or not build_ok:
            report.line("Runtime matrix cannot continue because required tools or the build are unavailable.")
            summarize(report)
            return 2

        report.section("Audio endpoint enumeration")
        endpoint_id, endpoints = parse_endpoints(executable, report)
        if not endpoint_id:
            report.add("E01 WASAPI endpoint enumeration", "FAIL", 0.0,
                       "No active playback endpoint ID was returned", "endpoint")
        else:
            report.add("E01 WASAPI endpoint enumeration", "PASS", 0.0,
                       f"{len(endpoints)} active endpoint(s); default selected", "endpoint")

        report.section("DirectShow enumeration")
        dshow = run([
            "ffmpeg", "-hide_banner", "-list_devices", "true",
            "-f", "dshow", "-i", "dummy",
        ], timeout=20)
        log_completed(report, dshow)
        loopback_candidates = dshow_loopback_candidates(dshow.stderr + "\n" + dshow.stdout)
        report.line("Potential DirectShow loopback candidates: " +
                    (", ".join(loopback_candidates) if loopback_candidates else "(none)"))

        with tempfile.TemporaryDirectory(prefix="aurora-stream-full-diagnostic-") as temporary:
            folder = Path(temporary)

            # Baseline capture/encode paths.
            run_simple_case(report, "V01 Synthetic video + NVENC + FFmpeg silence",
                            synthetic_av_command(folder / "v01.flv", "testsrc", False),
                            folder / "v01.flv", True, "video")
            run_simple_case(report, "V02 Desktop Duplication CPU + NVENC + FFmpeg silence",
                            synthetic_av_command(folder / "v02.flv", "ddagrab-cpu", False),
                            folder / "v02.flv", True, "video")
            run_simple_case(report, "V03 Desktop Duplication direct D3D11 + NVENC probe",
                            synthetic_av_command(folder / "v03.flv", "ddagrab-direct", False),
                            folder / "v03.flv", True, "video")
            run_simple_case(report, "V04 GDI capture + NVENC compatibility",
                            synthetic_av_command(folder / "v04.flv", "gdigrab", False),
                            folder / "v04.flv", True, "video")
            if "libx264" in run(["ffmpeg", "-hide_banner", "-encoders"], 20).stdout:
                run_simple_case(report, "V05 Desktop Duplication CPU + software H.264 control",
                                synthetic_av_command(folder / "v05.flv", "ddagrab-cpu", False, "libx264"),
                                folder / "v05.flv", True, "video")

            # Port ownership stress uses the actual D helper executable.
            report.section("P01 RTP/RTCP ownership stress")
            stress_passes = 0
            stress_started = time.perf_counter()
            for iteration in range(1, PORT_STRESS_ITERATIONS + 1):
                port, rtcp_port, rtp, rtcp = reserve_udp_pair()
                helper = start_helper(executable, folder, port, rtcp_port, True, "")
                status = wait_helper_status(helper, HELPER_READY_SECONDS)
                rc, metrics, out, err = stop_helper(helper)
                source_port = helper_metric(metrics, "rtp_source_port")
                collision = source_port in (port, rtcp_port)
                passed = status == "ready" and rc == 0 and source_port not in (None, 0) and not collision
                stress_passes += int(passed)
                report.line(
                    f"Iteration {iteration}: status={status or 'missing'}, rc={rc}, "
                    f"destination={port}/{rtcp_port}, source={source_port}, collision={'yes' if collision else 'no'}"
                )
                if err:
                    report.raw(err)
                rtp.close()
                rtcp.close()
            stress_ok = stress_passes == PORT_STRESS_ITERATIONS
            report.add("P01 RTP/RTCP ownership stress", "PASS" if stress_ok else "FAIL",
                       time.perf_counter() - stress_started,
                       f"{stress_passes}/{PORT_STRESS_ITERATIONS} iterations passed", "port")

            run_simple_case(
                report, "P02 D AudioBridgeSession synthetic self-test",
                [str(executable), "--audio-bridge-session-test", "--synthetic"],
                None, False, "port")
            if endpoint_id:
                run_simple_case(
                    report, "P03 D AudioBridgeSession real WASAPI self-test",
                    [str(executable), "--audio-bridge-session-test", "--endpoint", endpoint_id],
                    None, False, "port")

            run_helper_standalone(report, executable, folder, "", True,
                                  "S01 Synthetic RTP helper standalone")
            if endpoint_id:
                run_helper_standalone(report, executable, folder, endpoint_id, False,
                                      "W01 Real WASAPI helper standalone")

            # Synthetic helper matrix.
            run_rtp_case(report, executable, folder, "", name="S02 Receiver-first synthetic RTP audio-only",
                         synthetic=True, ordering="receiver-first", video_mode=None,
                         fifo=False, tuning="default")
            run_rtp_case(report, executable, folder, "", name="S03 Receiver-first synthetic RTP A/V",
                         synthetic=True, ordering="receiver-first", video_mode="ddagrab-cpu",
                         fifo=False, tuning="default")
            run_rtp_case(report, executable, folder, "", name="S04 Current helper-first synthetic RTP A/V",
                         synthetic=True, ordering="helper-first-current", video_mode="ddagrab-cpu",
                         fifo=False, tuning="default")
            run_rtp_case(report, executable, folder, "", name="S05 Receiver-first synthetic RTP A/V fast-probe",
                         synthetic=True, ordering="receiver-first", video_mode="ddagrab-cpu",
                         fifo=False, tuning="fast-probe")
            run_rtp_case(report, executable, folder, "", name="S06 Current helper-first synthetic RTP A/V FIFO",
                         synthetic=True, ordering="helper-first-current", video_mode="ddagrab-cpu",
                         fifo=True, tuning="default")

            if endpoint_id:
                run_rtp_case(report, executable, folder, endpoint_id,
                             name="W02 Receiver-first real WASAPI audio-only",
                             synthetic=False, ordering="receiver-first", video_mode=None,
                             fifo=False, tuning="default")
                run_rtp_case(report, executable, folder, endpoint_id,
                             name="W03 Current helper-first real WASAPI audio-only",
                             synthetic=False, ordering="helper-first-current", video_mode=None,
                             fifo=False, tuning="default")

                for iteration in range(1, CRITICAL_REPEATS + 1):
                    run_rtp_case(report, executable, folder, endpoint_id,
                                 name=f"W04 Receiver-first real A/V repeat {iteration}",
                                 synthetic=False, ordering="receiver-first",
                                 video_mode="ddagrab-cpu", fifo=False, tuning="default")
                    run_rtp_case(report, executable, folder, endpoint_id,
                                 name=f"W05 Current helper-first real A/V repeat {iteration}",
                                 synthetic=False, ordering="helper-first-current",
                                 video_mode="ddagrab-cpu", fifo=False, tuning="default")

                run_rtp_case(report, executable, folder, endpoint_id,
                             name="W06 Receiver-first real A/V fast-probe",
                             synthetic=False, ordering="receiver-first",
                             video_mode="ddagrab-cpu", fifo=False, tuning="fast-probe")
                run_rtp_case(report, executable, folder, endpoint_id,
                             name="W07 Receiver-first real A/V bounded-probe FIFO",
                             synthetic=False, ordering="receiver-first",
                             video_mode="ddagrab-cpu", fifo=True, tuning="bounded-probe")
                run_rtp_case(report, executable, folder, endpoint_id,
                             name="W08 Helper-first real A/V FIFO comparison",
                             synthetic=False, ordering="helper-first-current",
                             video_mode="ddagrab-cpu", fifo=True, tuning="default")
            else:
                report.line("Real WASAPI matrix skipped because endpoint enumeration failed.")

            if loopback_candidates:
                run_dshow_candidate(report, folder, loopback_candidates[0])
            else:
                report.add("OPTIONAL DirectShow loopback candidate", "SKIP", 0.0,
                           "No Stereo Mix/What U Hear/loopback capture device was exposed", "alternative")

        summarize(report)
        failed = [item for item in report.results if item.status in ("FAIL", "TIMEOUT")]
        return 1 if failed else 0
    except BaseException as error:
        report.section("UNHANDLED DIAGNOSTIC ERROR")
        report.line(repr(error))
        import traceback
        report.raw(traceback.format_exc())
        summarize(report)
        return 3
    finally:
        report.line()
        report.line(f"Finished: {_datetime.datetime.now().astimezone().isoformat()}")
        report.close()


if __name__ == "__main__":
    raise SystemExit(main())
