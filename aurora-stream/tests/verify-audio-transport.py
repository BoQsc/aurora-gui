#!/usr/bin/env python3
"""Static acceptance checks for Aurora Stream 0.4.9's A/V redesign and quality diagnostic."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WASAPI = (ROOT / "source/aurorastream/wasapi.d").read_text(encoding="utf-8")
BRIDGE = (ROOT / "source/aurorastream/audiobridge.d").read_text(encoding="utf-8")
BROADCAST = (ROOT / "source/aurorastream/broadcast.d").read_text(encoding="utf-8")
DIAGNOSTIC = (ROOT / "source/aurorastream/pacingdiagnostic.d").read_text(encoding="utf-8")
APP = (ROOT / "source/app.d").read_text(encoding="utf-8")
FULL_DIAGNOSTIC = (ROOT / "tests/run-all-diagnostics.py").read_text(encoding="utf-8")
FULL_DIAGNOSTIC_BAT = (ROOT / "RUN-ALL-DIAGNOSTICS.bat").read_text(encoding="utf-8")
NETWORK_ISOLATION = (ROOT / "tests/verify-network-output-isolation.py").read_text(encoding="utf-8")
QUALITY_DIAGNOSTIC = (ROOT / "tests/run-quality-diagnostic.py").read_text(encoding="utf-8")
QUALITY_DIAGNOSTIC_BAT = (ROOT / "RUN-QUALITY-DIAGNOSTIC.bat").read_text(encoding="utf-8")


def block_after(source: str, marker: str) -> str:
    start = source.find(marker)
    if start < 0:
        raise AssertionError(f"missing marker: {marker}")
    brace = source.find("{", start)
    if brace < 0:
        raise AssertionError(f"missing body for: {marker}")
    depth = 0
    i = brace
    state = "code"
    while i < len(source):
        ch = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""
        if state == "code":
            if ch == '"':
                state = "string"
            elif ch == "'":
                state = "char"
            elif ch == "`":
                state = "raw"
            elif ch == "/" and nxt == "/":
                state = "line_comment"
                i += 1
            elif ch == "/" and nxt == "*":
                state = "block_comment"
                i += 1
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return source[brace + 1 : i]
        elif state == "string":
            if ch == "\\":
                i += 1
            elif ch == '"':
                state = "code"
        elif state == "char":
            if ch == "\\":
                i += 1
            elif ch == "'":
                state = "code"
        elif state == "raw":
            if ch == "`":
                state = "code"
        elif state == "line_comment":
            if ch == "\n":
                state = "code"
        elif state == "block_comment":
            if ch == "*" and nxt == "/":
                state = "code"
                i += 1
        i += 1
    raise AssertionError(f"unterminated body for: {marker}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


helper = block_after(WASAPI, "private int runWasapiRtp(")
synthetic = block_after(WASAPI, "private int runSyntheticRtp(")
ring = block_after(WASAPI, "private struct PcmFrameRing")
capture_inputs = block_after(BROADCAST, "private string[] captureArguments(")
diagnostic_args = block_after(BROADCAST, "string[] pacingDiagnosticArguments(")
run_phase = block_after(DIAGNOSTIC, "private PhaseResult runPhase(")
direct_probe = block_after(BROADCAST, "private bool directD3D11NvencWorks(")
zero_copy = block_after(BROADCAST, "bool usesD3D11ZeroCopyVideo(")

require('--audio-rtp-helper' in APP, "same-executable audio helper mode is missing")
require("spawnProcess(arguments" in BRIDGE,
        "desktop audio is not isolated in a separate process")
require("L16/48000/2" in BRIDGE and "a=ptime:20" in BRIDGE,
        "SDP does not declare timestamped 20 ms PCM RTP")
require("reserveLocalRtpReceiverPair" in BRIDGE and
        "rtpSocket.bind" in BRIDGE and "rtcpSocket.bind" in BRIDGE,
        "RTP and RTCP receiver ports are not reserved as an adjacent pair")
require("SetHandleInformation" in BRIDGE and
        "HANDLE_FLAG_INHERIT" in BRIDGE and
        "auto handle = cast(HANDLE) cast(size_t) socket.handle;" in BRIDGE and
        "SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0U)" in BRIDGE and
        "const handle = cast(HANDLE)" not in BRIDGE and
        "preventSocketInheritance" in BRIDGE,
        "receiver reservation sockets can still be inherited by the audio helper")
require("validateReceiverReservationHandoff" in BRIDGE and
        "Closing and immediately reacquiring the same pair proves" in BRIDGE,
        "the helper-to-FFmpeg receiver-port handoff is not verified at runtime")
require("a=rtcp:%s IN IP4 127.0.0.1" in BRIDGE,
        "SDP does not declare the reserved RTCP port explicitly")
require("releaseReceiverReservations" in BRIDGE and
        "desktopBridge.releaseReceiverReservations()" in BROADCAST and
        "bridge.releaseReceiverReservations()" in DIAGNOSTIC,
        "receiver reservations are not held through helper source binding and released before FFmpeg")
require("desktopBridge.validateReceiverReservationHandoff" in BROADCAST and
        DIAGNOSTIC.count("bridge.validateReceiverReservationHandoff") == 2 and
        "bridge.validateReceiverReservationHandoff" in APP,
        "live, diagnostic, and self-test paths do not verify receiver-port handoff")
require("DESKTOP AUDIO PORT HANDOFF FAILURE" in BROADCAST and
        "handoff verified. RTP=%s RTCP=%s" in BROADCAST and
        "_startupFailureReason = handoffError" in BROADCAST,
        "receiver-port ownership failures are not preserved in the startup log/UI")
require('socket.bind(new InternetAddress("127.0.0.1"' in WASAPI and
        "InternetAddress.PORT_ANY" in WASAPI and
        "rtp_source_port" in WASAPI,
        "the RTP sender is not explicitly bound to a distinct local source port")
require("outputChunkFrames = 960" in WASAPI and
        "outputIntervalMicroseconds = 20_000" in WASAPI,
        "helper is not using one fixed 20 ms / 960-frame output interval")
require("new ubyte[ringCapacityFrames * 4]" in ring,
        "audio queue is not preallocated")
require("discardOldest" in ring and "recoverNearRealTime" in ring and
        "ringRecoveryFrames - frames" in ring,
        "bounded drop-oldest recovery does not return near real time")
require("audioClientStreamFlagEventCallback" in helper and
        "IAudioClient.SetEventHandle" in helper and
        "WaitForSingleObject" in helper,
        "WASAPI helper is not event-driven")
require("Thread.sleep" not in helper,
        "real WASAPI helper still polls or sleeps in its capture/output loop")
require(helper.count("sender.sendChunk(outputChunk[]") == 1,
        "real helper has more than one RTP output site and may burst")
require(synthetic.count("sender.sendChunk(silence[]") == 1,
        "synthetic helper has more than one RTP output site and may burst")
require("reanchorOutputClock" in helper and "pacingFramesSkipped" in helper,
        "late intervals are not re-anchored without catch-up delivery")
require("socket.blocking = false" in WASAPI,
        "RTP transport is not explicitly nonblocking")
require(helper.find("sender.initialize(port, frequency, metrics)") <
        helper.find('publishStatus(statusPath, "ready")'),
        "real helper publishes ready before binding its RTP source socket")
require(synthetic.find("sender.initialize(port, frequency, metrics)") <
        synthetic.find('publishStatus(statusPath, "ready")'),
        "synthetic helper publishes ready before binding its RTP source socket")
require("packet = new ubyte[12 + outputChunkFrames * 4]" in WASAPI,
        "RTP packet storage is not preallocated for one 20 ms datagram")
require("maximum_send_duration_us" in WASAPI and
        "consecutiveSendFailures >= 5" in WASAPI,
        "RTP completion timing or persistent-send failure handling is missing")

for old_symbol in (
    "WasapiLoopbackSource",
    "PcmPacketRing",
    "startWriterThread",
    "writerThread",
    "dTransportSilence",
):
    require(old_symbol not in WASAPI + BRIDGE + DIAGNOSTIC + BROADCAST,
            f"retired 0.3.x transport remains active: {old_symbol}")

require('"-f", "sdp", "-i", desktopAudio.sdpPath' in capture_inputs,
        "FFmpeg does not ingest the isolated helper through SDP/RTP")
require('"-use_wallclock_as_timestamps"' not in
        capture_inputs.split("if (settings.microphoneDevice", 1)[0],
        "desktop RTP incorrectly rebuilds timestamps from wall clock")
for raw_format in ('"f32le"', '"s16le"'):
    require(raw_format not in capture_inputs,
            f"raw PCM side-channel input remains active: {raw_format}")
require("aresample=48000:async=1000:first_pts=0" in BROADCAST and
        "asetpts=PTS-STARTPTS" in BROADCAST,
        "RTP sample timestamps are not preserved into the audio graph")
require('"-f", "flv", outputPath' in diagnostic_args and
        '"-f", "fifo"' not in diagnostic_args,
        "local diagnostic still hides timing behind the FIFO output muxer")
require("AudioPhaseMode.isolatedRtpSilence" in DIAGNOSTIC and
        "AudioPhaseMode.wasapiLoopback" in DIAGNOSTIC,
        "three-phase helper/WASAPI isolation is incomplete")
require("packets_captured" in DIAGNOSTIC,
        "diagnostic does not reject a zero-packet real-audio phase")
require(DIAGNOSTIC.count("private string jsonString(") == 1 and
        DIAGNOSTIC.count("private JSONValue runJson(") == 1,
        "pacing diagnostic JSON helpers are missing or duplicated")
require(DIAGNOSTIC.count("runJson([") == 3,
        "pacing diagnostic ffprobe JSON calls are incomplete")
require("buffers queued" in run_phase,
        "FFmpeg queue warnings are not counted")
require("bridge.failure()" in run_phase,
        "FFmpeg is not stopped when the isolated helper fails")
require("ddagrab=output_idx=0:framerate=60" in direct_probe and
        '"-c:v", "h264_nvenc"' in direct_probe and
        '"-preset", "p3"' in direct_probe and
        '"-b:v", "6000k"' in direct_probe,
        "direct D3D11/NVENC support is not tested with the real live profile")
require("d3d11DirectProbeAttempted" in BROADCAST and
        "d3d11DirectSupported" in zero_copy,
        "direct hardware input is not capability-gated")
require("capture.nativeWidth == qualityWidth" in zero_copy and
        "capture.nativeHeight == qualityHeight" in zero_copy,
        "matching capture dimensions are not required for direct D3D11 output")
require("CPU compatibility path" in BROADCAST and
        'if (!keepVideoOnGpu) source ~= ",hwdownload,format=bgra"' in capture_inputs,
        "a failed direct-input probe does not select the CPU compatibility path")

require('"-f", "fifo", "-fifo_format", "flv"' in BROADCAST and
        '"-queue_size", "360"' in BROADCAST and
        '"-drop_pkts_on_overflow", "1"' in BROADCAST and
        "Network output must never own the capture/encode thread" in BROADCAST,
        "live RTMP output is not isolated behind a bounded FIFO worker")
require('"-f", "flv", outputPath' in diagnostic_args,
        "local file diagnostics must remain direct FLV")
require("captureActive()" in BRIDGE and
        'publishStatus(statusPath, "capturing")' in WASAPI and
        "Desktop audio packets are now being captured" in BROADCAST,
        "live audio capture-state supervision is incomplete")
require("StalledRtmpServer" in NETWORK_ISOLATION and
        '"-f", "fifo", "-fifo_format", "flv"' in NETWORK_ISOLATION and
        "Direct RTMP stalled before progress" in NETWORK_ISOLATION,
        "localhost stalled-RTMP regression is incomplete")
require("startupDeadlineTicks" in BROADCAST and
        "monitorProcess" in BROADCAST and
        "FFmpeg startup timed out" in BROADCAST,
        "live FFmpeg startup is not independently bounded")
require("inspectDesktopAudio(bridge)" in BROADCAST,
        "audio-helper failure monitoring still depends only on FFmpeg progress")
require("aurora-stream-startup.log" in BROADCAST and
        "appendArgumentLog" in BROADCAST and
        "Desktop audio final metrics" in BROADCAST,
        "sanitized single-file live startup logging is incomplete")

require("--list-audio-endpoints-json" in APP and
        "--audio-bridge-session-test" in APP,
        "full diagnostic helper CLI modes are missing")
require("CRITICAL_REPEATS = 3" in FULL_DIAGNOSTIC and
        "PORT_STRESS_ITERATIONS = 12" in FULL_DIAGNOSTIC,
        "full diagnostic does not repeat critical paths or stress port ownership")
for required_case in (
    "V02 Desktop Duplication CPU + NVENC + FFmpeg silence",
    "S03 Receiver-first synthetic RTP A/V",
    "S04 Current helper-first synthetic RTP A/V",
    "W01 Real WASAPI helper standalone",
    "W04 Receiver-first real A/V repeat",
    "W05 Current helper-first real A/V repeat",
    "W08 Helper-first real A/V FIFO comparison",
):
    require(required_case in FULL_DIAGNOSTIC,
            f"full diagnostic matrix is missing: {required_case}")
require("aurora-stream-all-diagnostics.txt" in FULL_DIAGNOSTIC_BAT and
        "run-all-diagnostics.py" in FULL_DIAGNOSTIC_BAT,
        "one-click diagnostic does not produce the single aggregate report")
require("stream keys are neither read nor transmitted" in FULL_DIAGNOSTIC.lower(),
        "full diagnostic privacy statement is missing")


require("aurora-stream-quality-diagnostic.txt" in QUALITY_DIAGNOSTIC and
        "quality-diagnostic-artifacts" in QUALITY_DIAGNOSTIC,
        "deterministic quality diagnostic output/report paths are missing")
require("ffplay" in QUALITY_DIAGNOSTIC and "testsrc2=size=1920x1080:rate=60" in QUALITY_DIAGNOSTIC and
        "997" in QUALITY_DIAGNOSTIC and "4000" in QUALITY_DIAGNOSTIC,
        "quality diagnostic lacks synchronized deterministic video/audio markers")
for required_phase in (
    "Q01", "Q02", "Q03", "Q04", "Q05", "Q06", "Q07", "Q08",
    "Q09", "Q10", "Q11",
):
    require(f'"{required_phase}"' in QUALITY_DIAGNOSTIC,
            f"quality diagnostic matrix is missing {required_phase}")
require("framemd5" in QUALITY_DIAGNOSTIC and "unique_rate" in QUALITY_DIAGNOSTIC and
        "phase_jumps" in QUALITY_DIAGNOSTIC and "A/V sync" in QUALITY_DIAGNOSTIC,
        "quality diagnostic does not measure unique video cadence, audio cracks, and A/V sync")
require("GetProcessTimes" in QUALITY_DIAGNOSTIC and "nvidia-smi" in QUALITY_DIAGNOSTIC,
        "quality diagnostic does not measure CPU/GPU efficiency")
require("passed all strict thresholds twice" in QUALITY_DIAGNOSTIC and
        "repeated_complete" in QUALITY_DIAGNOSTIC,
        "quality diagnostic can recommend an unrepeatable one-off result")
for forbidden in ("numpy", "scipy", "cv2", "psutil", "pandas"):
    require(forbidden not in QUALITY_DIAGNOSTIC.lower(),
            f"quality diagnostic introduced a third-party dependency: {forbidden}")
require("run-quality-diagnostic.py" in QUALITY_DIAGNOSTIC_BAT and
        "aurora-stream-quality-diagnostic.txt" in QUALITY_DIAGNOSTIC_BAT,
        "one-click quality runner does not produce the single aggregate report")

print("Aurora Stream 0.4.9 audio/video redesign and quality checks passed")
