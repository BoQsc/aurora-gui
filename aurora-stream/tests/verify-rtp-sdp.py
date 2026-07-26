#!/usr/bin/env python3
"""Validate Aurora Stream's 20 ms RTP L16 input against local FFmpeg.

Uses only the Python standard library. It does not exercise Windows WASAPI or
Desktop Duplication. It validates SDP parsing, 3,852-byte localhost RTP packets,
AAC/FLV muxing, timestamp cadence, direct diagnostic FLV, and the live FIFO/FLV
wrapper.
"""

from __future__ import annotations

import json
from pathlib import Path
import random
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        raise SystemExit(f"ERROR: {name} was not found on PATH")
    return path


def reserve_udp_pair() -> tuple[int, int, socket.socket, socket.socket]:
    for _ in range(128):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.bind(("127.0.0.1", 0))
            rtp_port = int(probe.getsockname()[1]) & ~1
        if rtp_port < 1024 or rtp_port > 65534:
            continue
        rtp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        rtcp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            rtp.bind(("127.0.0.1", rtp_port))
            rtcp.bind(("127.0.0.1", rtp_port + 1))
            return rtp_port, rtp_port + 1, rtp, rtcp
        except OSError:
            rtp.close()
            rtcp.close()
    raise RuntimeError("could not reserve an RTP/RTCP pair")


def send_silence(
    port: int, stop: threading.Event, sock: socket.socket
) -> None:
    sequence = random.randrange(0x10000)
    timestamp = random.randrange(0x100000000)
    ssrc = random.randrange(0x100000000)
    payload = bytes(960 * 4)
    deadline = time.perf_counter() + 0.20
    try:
        while not stop.is_set():
            now = time.perf_counter()
            if now < deadline:
                stop.wait(deadline - now)
                continue
            late = now - deadline
            if late > 0.002:
                timestamp = (timestamp + round(late * 48_000)) & 0xFFFFFFFF
                deadline = now
            packet = struct.pack(
                "!BBHII", 0x80, 96, sequence, timestamp, ssrc
            ) + payload
            sock.sendto(packet, ("127.0.0.1", port))
            sequence = (sequence + 1) & 0xFFFF
            timestamp = (timestamp + 960) & 0xFFFFFFFF
            deadline += 0.020
    finally:
        sock.close()


def output_arguments(output: Path, fifo: bool) -> list[str]:
    if not fifo:
        return [
            "-max_interleave_delta", "0", "-flush_packets", "1",
            "-flvflags", "no_duration_filesize", "-f", "flv", str(output),
        ]
    return [
        "-f", "fifo", "-fifo_format", "flv", "-queue_size", "1200",
        "-format_opts",
        "max_interleave_delta=0:flush_packets=1:flvflags=no_duration_filesize",
        "-attempt_recovery", "1", "-recovery_wait_time", "1",
        "-restart_with_keyframe", "1",
        str(output),
    ]


def validate_output(ffprobe: str, output: Path) -> None:
    if not output.exists() or output.stat().st_size == 0:
        raise AssertionError("FFmpeg produced no FLV output")
    probe = subprocess.run(
        [ffprobe, "-v", "error", "-count_frames", "-show_entries",
         "stream=index,codec_type,avg_frame_rate,nb_read_frames",
         "-of", "json", str(output)],
        check=True, capture_output=True, text=True,
    )
    streams = json.loads(probe.stdout).get("streams", [])
    video = next((stream for stream in streams
                  if stream.get("codec_type") == "video"), None)
    audio = next((stream for stream in streams
                  if stream.get("codec_type") == "audio"), None)
    if video is None or audio is None:
        raise AssertionError("FLV did not contain both video and audio")
    if video.get("avg_frame_rate") != "60/1":
        raise AssertionError(f"unexpected video rate: {video}")
    frames = int(video.get("nb_read_frames") or 0)
    if frames != 180:
        raise AssertionError(f"expected 180 video frames, found {frames}")


def run_case(ffmpeg: str, ffprobe: str, root: Path, fifo: bool) -> None:
    mode = "fifo-flv" if fifo else "direct-flv"
    last_error = ""
    for attempt in range(1, 6):
        port, rtcp_port, rtp_reservation, rtcp_reservation = reserve_udp_pair()
        sender_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sender_socket.bind(("127.0.0.1", 0))
        source_port = int(sender_socket.getsockname()[1])
        if source_port in (port, rtcp_port):
            sender_socket.close()
            rtp_reservation.close()
            rtcp_reservation.close()
            continue

        sdp = root / f"audio-{mode}-{attempt}.sdp"
        output = root / f"result-{mode}-{attempt}.flv"
        sdp.write_text(
            "v=0\r\n"
            "o=- 0 0 IN IP4 127.0.0.1\r\n"
            "s=Aurora Stream RTP validation\r\n"
            "c=IN IP4 127.0.0.1\r\n"
            "t=0 0\r\n"
            f"m=audio {port} RTP/AVP 96\r\n"
            "a=rtpmap:96 L16/48000/2\r\n"
            f"a=rtcp:{rtcp_port} IN IP4 127.0.0.1\r\n"
            "a=ptime:20\r\n"
            "a=recvonly\r\n",
            encoding="ascii",
        )

        command = [
            ffmpeg, "-y", "-hide_banner", "-loglevel", "warning", "-nostdin",
            "-re", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=60",
            "-protocol_whitelist", "file,udp,rtp", "-thread_queue_size", "64",
            "-f", "sdp", "-i", str(sdp),
            "-filter_complex",
            "[1:a]aresample=48000:async=1000:first_pts=0,"
            "aformat=sample_rates=48000:channel_layouts=stereo,"
            "asetpts=PTS-STARTPTS[a]",
            "-map", "0:v", "-map", "[a]",
            "-r:v", "60", "-fps_mode:v", "cfr",
            "-c:v", "libx264", "-preset", "ultrafast",
            "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-ac", "2",
            "-t", "3",
        ] + output_arguments(output, fifo)

        rtp_reservation.close()
        rtcp_reservation.close()
        # Windows can transiently retain a just-closed UDP reservation. A fresh
        # pair retry is preferable to turning that race into a false regression.
        time.sleep(0.03)
        process = subprocess.Popen(
            command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True
        )
        stop = threading.Event()
        sender = threading.Thread(
            target=send_silence, args=(port, stop, sender_socket), daemon=True
        )
        sender.start()
        try:
            stderr = process.communicate(timeout=15)[1]
        finally:
            stop.set()
            sender.join(timeout=2)
            if process.poll() is None:
                process.kill()
                process.wait(timeout=2)

        if process.returncode == 0:
            if "buffers queued" in stderr:
                raise AssertionError(f"{mode} emitted a buffers-queued warning")
            validate_output(ffprobe, output)
            print(
                f"RTP/SDP {mode} passed on attempt {attempt}: "
                "180 video frames at 60/1 plus AAC"
            )
            return

        last_error = stderr
        bind_race = "-10048" in stderr or "bind failed" in stderr
        if not bind_race:
            raise AssertionError(
                f"FFmpeg {mode} validation exited {process.returncode}:\n{stderr}"
            )

    raise AssertionError(
        f"FFmpeg {mode} hit a UDP bind race on all five fresh port pairs:\n"
        f"{last_error}"
    )

def main() -> int:
    ffmpeg = require_tool("ffmpeg")
    ffprobe = require_tool("ffprobe")
    with tempfile.TemporaryDirectory(prefix="aurora-stream-rtp-") as folder:
        root = Path(folder)
        run_case(ffmpeg, ffprobe, root, fifo=False)
        run_case(ffmpeg, ffprobe, root, fifo=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
