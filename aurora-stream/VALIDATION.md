# Aurora Stream validation

Aurora Stream version: 0.66.0

## 0.66.0 D3D11 game/window capture release gate

All autonomous tests must remain background-only: do not open the fullscreen
visual quality card. A release candidate is accepted for manual YouTube testing
only after all of these checks pass:

1. `dub test --compiler=dmd --force` reports all 45 modules passing, and debug
   builds of both `application` and `notitlebar` configurations link.
2. Build `gamecaphook.dll` with DMD `-m64 -shared -betterC -O -release -inline
   -boundscheck=off`, `/NODEFAULTLIB`, and `/ENTRY:gamecaphookEntry`.
3. Run the minimized/background `gamecap_test` matrix for BGRA8, RGBA8, and
   RGB10A2. Every format must pass two hook injection/unload/reinjection rounds
   plus one real `GameCaptureSession` round at 1920×1080. Packets must stay in
   order, pixels must be non-black/changing/color-correct, and the bounded-drop
   thresholds must pass. The production session must receive at least 220
   frames in four seconds; its consumer intentionally keeps only the newest
   frame while the broadcaster repeats the held image at exact output cadence.
4. `verify-audio-transport.py`, `verify-rtp-sdp.py`, and
   `verify-network-output-isolation.py` must pass. The headless
   `run-quality-diagnostic.py --loaded-audio` run must encode 720/720 frames in
   both 12-second phases with MMCSS active and no RTP loss, pacing skip, send
   failure, queue warning, or overrun.
5. Run the portable staging helper and the complete `--single-exe` workflow.
   The local DMD distribution may stop only at its known missing `libcmt.lib`;
   the official `windows-latest` release workflow, which supplies the static
   runtime and verified minimal FFmpeg artifact, is the packaging authority and
   must pass before tagging.

Current local result (2026-08-14): all compile/unit/audio/network checks pass.
The final shared-memory game-capture runs passed at 236–237 manual frames and
238–239 production-received frames per four seconds, with ordered/color-correct
output. The last production round for each format reported zero sequence gaps
and zero hook drops. The full single-exe build reached the final link and was
blocked locally only by the absent `libcmt.lib`; authenticated YouTube ingest
and fullscreen-exclusive/anti-cheat behavior remain manual post-release tests.

## Unreleased loaded-audio regression

Run `python tests/run-quality-diagnostic.py --loaded-audio` for a headless, silent stress check of both the live compatibility graph and the lower-overhead BGRA graph. Each 12-second phase must encode 720 frames with no FFmpeg RTP-loss, maximum-delay, overrun, or output-queue warning; MMCSS must be active; and the sender must report no pacing skip or send failure. This test does not replace the audible decoded-waveform control or the full visual 60 FPS diagnostic.

## 0.4.9 deterministic quality acceptance

Run `RUN-QUALITY-DIAGNOSTIC.bat` with Aurora Stream closed. The runner builds the Windows executable, opens its own synchronized full-screen 1080p60/audio source, executes the complete local path matrix, decodes every result, and writes `aurora-stream-quality-diagnostic.txt`.

A solid implementation is not accepted unless the same 1080p path passes twice with all of the following:

- at least 59.0 decoded unique images per second;
- no visually near-identical-frame run longer than two frames;
- no FFmpeg `buffers queued` warning;
- settled FFmpeg speed at least 0.98×;
- no decoded audio dropout window or 997 Hz phase jump;
- Windows MMCSS audio scheduling active;
- no helper-inserted silence, stale-frame discard, overflow drop, pacing skip, or RTP send failure;
- maximum audio packet gap no greater than 30 ms and send completion no greater than 5 ms;
- median A/V marker offset within 120 ms, jitter within 20 ms, and drift within 20 ms.

The test also records CPU, RAM, NVIDIA utilization, power, and temperature so a barely real-time result is not mistaken for reliable headroom.

## 0.4.8 decision from the Windows `-10048` log

The 0.4.6 live log proved that output FIFO isolation was no longer the immediate blocker. FFmpeg failed while opening the SDP input because RTP 51034 remained owned after Aurora Stream reported that it had released the receiver reservations. The helper source was correctly distinct at 51036.

The source defect was reservation-handle inheritance across `spawnProcess`. Version 0.4.8 therefore requires all three conditions before FFmpeg launch:

1. The RTP and RTCP reservation handles are explicitly marked non-inheritable.
2. The helper binds a separate source socket and reports transport readiness.
3. Aurora Stream closes and reacquires the exact destination pair, keeps it reserved, then releases it immediately before FFmpeg starts.

The live, pacing-diagnostic, and bridge-self-test paths all execute the same handoff proof. Any failure is logged and stops startup before FFmpeg.

## 0.4.6 decision from the live startup log

The 0.4.5 Windows startup log proved that the remaining failure was outside the local A/V path:

- FFmpeg used direct RTMPS for the one enabled Twitch destination.
- The helper initialized and sent hundreds of timestamped RTP packets.
- FFmpeg printed no encoded frame or valid output timestamp before the 12-second deadline.
- The only FFmpeg line was an unrelated `sc_threshold` option warning.
- Final helper metrics showed no send failure; the selected endpoint simply had not produced real packets during that attempt, so bounded silence was sent.

A direct RTMP/RTMPS output performs network connection and handshake work synchronously before normal frame processing. Successful direct **local FLV files** therefore did not validate direct **network output**.

Version 0.4.6 changes the live boundary:

1. Every Twitch or YouTube network destination uses a separate bounded FIFO output worker.
2. The queue is capped at 1200 packets with recovery and keyframe restart enabled, without drop-on-overflow.
3. Local diagnostics remain direct FLV so local timing is still measured without a network queue.
4. The helper reports `transport-ready` separately from `capturing` real WASAPI packets.
5. The monitor records the first real packet transition or a three-second silent-endpoint notice without stopping video.
6. The 12-second first-frame deadline and sanitized `aurora-stream-startup.log` remain active.
7. After startup, a live watchdog stops the attempt if progress reports, output time, or speed prove the live output is stalled.
8. CPU-only `libx264` systems use GDI capture by default instead of Desktop Duplication readback.
9. Desktop Duplication `AcquireNextFrame failed` and frozen encoded-video frame counters are treated as capture failures, even if audio output time continues.

## Validation completed in this environment

1. `tests/verify-audio-transport.py` confirms helper-first RTP, bounded live FIFO output, direct local diagnostic FLV, independent helper monitoring, capture-state supervision, and the startup deadline.
2. `tests/verify-network-output-isolation.py` uses only localhost and the Python standard library. A fake server accepts TCP but never answers the RTMP handshake. Direct RTMP emits no progress; the bounded FIFO path continues encoding.
3. `tests/verify-rtp-sdp.py` produces exactly 180 video frames at 60/1 plus AAC for direct diagnostic FLV and FIFO/FLV integration.
4. `tests/run-all-diagnostics.py` includes the new stalled-RTMP isolation test and the helper-first real-WASAPI FIFO comparison.
5. `dub.json` parses as valid JSON and reports version 0.4.8.
6. All D sources pass delimiter, string, and comment lexical checks in this package.
7. No public destination or stream key is used by the local tests.

## Required Windows check

1. Extract the package and run `RUN-WINDOWS.bat` with Twitch enabled.
2. The status must show encoder progress within 12 seconds even if Twitch connection setup is slow.
3. Keep audible desktop playback active. The startup log must record `Desktop audio capture became active`, and final metrics must show nonzero `packets_captured` and `captured_frames_queued`. Initial silence is acceptable only before playback begins or across a genuine endpoint gap.
4. Confirm Twitch receives video and audible synchronized desktop audio for at least five minutes.
5. Confirm there is no long output-time freeze followed by catch-up processing.
6. If the network destination is unavailable before startup, capture/encoding should continue behind the bounded FIFO and the log should show output recovery warnings instead of an encoder-start timeout.
7. If the connection or computer cannot keep up after startup, Aurora Stream should stop with `Live output stalled` and the startup log should contain a `LIVE OUTPUT FAILURE` line instead of leaving Twitch on a black buffering player.
8. Upload only `aurora-stream-startup.log` if the live attempt still fails; stream keys remain sanitized.
9. Do not call the original smoothness issue fixed until the local 15-second A/B/C pacing diagnostic also passes three times with equivalent continuous motion.

## Environment limitation

This container can execute FFmpeg and the localhost network-isolation tests, but it cannot run Windows DMD/DUB, WASAPI, Desktop Duplication, NVENC, or Twitch ingest. Version 0.4.8 fixes the demonstrated receiver-handle inheritance defect; Windows live acceptance is still required.

## 0.4.2 Windows runtime correction

The first 0.4.1 Windows launch reached FFmpeg but failed before streaming. The status panel reported `D3D11 direct hardware frames → NVENC`, followed by `Error while opening encoder` and FFmpeg exit code -2. This proved that encoder availability with a CPU test frame and matching dimensions were insufficient evidence for direct D3D11 input support.

Version 0.4.2 adds a separate exact probe using `ddagrab` hardware frames and the live 6000 kbps NVENC profile. `usesD3D11ZeroCopyVideo` now requires the probe result. When the probe fails, command construction includes `hwdownload,format=bgra` and uses the CPU compatibility filter chain before the live process starts.

## Direct Windows evidence that forced the redesign

The completed 0.3.3 diagnostic is treated as a failed-release result, not as acceptance:

- Phase A (`anullsrc`): 900 frames, 96 exact decoded duplicates, 53.601 effective unique images/s.
- Phase B (D-generated transport silence): 900 frames, 215 duplicates, 45.668 unique images/s.
- Phase C (named as WASAPI ring): 900 frames, 104 duplicates, 53.068 unique images/s.
- Phase C captured zero WASAPI packets, delivered zero captured frames, and replaced 100% of its output with silence.
- Phase C's maximum writer completion was 40.106 ms, more than two 60 FPS video intervals.
- The active video path still reported D3D11 capture followed by CPU readback/scaling.

This proves two distinct defects: the 0.3.3 D transport-only path could disturb desktop motion without WASAPI, and the supposed real-audio phase could complete while never capturing real audio.

## 0.4.1 compile correction

The 0.4.0 package accidentally omitted the local `jsonString` and `runJson` helpers from `pacingdiagnostic.d` while retaining their callers. Version 0.4.1 restores the implementations that were already present in 0.3.3.


## 0.4.1 architecture under validation

```text
Main Aurora Stream process
  └─ FFmpeg desktop capture, video encode, AAC encode, mux, destinations

Separate same-executable audio helper process
  └─ event-driven WASAPI shared loopback
     → automatic PCM16 48 kHz stereo conversion
     → preallocated 200 ms queue
     → drop-oldest recovery toward 40 ms
     → one absolute-clock 20 ms / 960-frame output interval
     → one nonblocking RTP L16/48000/2 localhost datagram
     → FFmpeg SDP/RTP input using the 48 kHz RTP sample clock
```

The active design contains no desktop-audio named pipe, raw-PCM UDP input, GUI-process PCM ring, GUI-process pacing thread, or desktop `-use_wallclock_as_timestamps`. A late interval becomes an explicit RTP timestamp gap and a re-anchored next deadline; it is never emitted as a catch-up packet burst.

Phase B launches an isolated synthetic-RTP helper process. Phase C launches the real WASAPI helper. The local diagnostic writes FLV directly rather than through the reconnecting FIFO network wrapper. Phase C is marked failed when `packets_captured=0`, even if the helper kept FFmpeg alive with silence.

## Validation completed in this environment

1. `tests/verify-audio-transport.py` confirms the separate helper mode, process launch, SDP/RTP format, event-driven WASAPI setup, preallocated queue, one 20 ms send site, nonblocking socket, no raw PCM input, no desktop wall-clock timestamp reconstruction, direct diagnostic FLV output, zero-packet Phase C rejection, and exact-dimension matching D3D11/NVENC selection.
2. The Windows module contains a ring-buffer unit test that fills the 200 ms queue, triggers overflow, and verifies recovery to the 40 ms target before dequeue.
3. Every D source file passed balanced delimiter and unterminated string/comment checks.
4. `dub.json` parses as valid JSON and reports version 0.4.8.
5. `tests/verify-rtp-sdp.py` used only the Python standard library plus installed FFmpeg/ffprobe. It sent one 3,852-byte L16 RTP packet every 20 ms and produced exactly 180 video frames at 60/1 with AAC in both direct-FLV diagnostic mode and live-style FIFO/FLV mode.
6. The RTP integration test reproduced a mux failure with the former `max_interleave_delta=100000` policy because AAC begins with encoder delay. The current `max_interleave_delta=0` policy completed without a queue warning or mux error.
7. No Twitch/YouTube destination or stream key is used by either local validation path.

## Not executable in this environment

This container has FFmpeg and ffprobe but no DMD, LDC, DUB, Windows Core Audio, Desktop Duplication, NVENC, or Twitch ingest. The Windows COM/WASAPI code and D3D11 path therefore remain uncompiled and unexecuted here. Version 0.4.8 must not be called fixed on the strength of static or Linux RTP validation alone.

## Required Windows acceptance

1. Build the x86_64 Windows package and run `CHECK-STREAM-PACING.bat` while audible sound is continuously playing through the selected endpoint.
2. Keep the same continuously moving game/camera view for Phases A, B, and C. Repeat the complete A/B/C run at least three times.
3. Confirm Phase B is within 2 unique images/s of Phase A in every comparable run. A Phase B regression still isolates the helper/RTP/FFmpeg scheduling boundary.
4. Confirm Phase C is within 2 unique images/s of Phase A and B. A Phase C-only regression isolates WASAPI, endpoint/driver behavior, conversion, or helper capture scheduling.
5. Confirm Phase C reports nonzero `packets_captured`, `captured_frames_queued`, and `event_wakeups`. Zero packets invalidates the run and makes the diagnostic exit nonzero.
6. Confirm `send_failures=0`, `FFmpeg queue warnings: 0`, and no output-time freeze followed by greater-than-1.1x catch-up.
7. Confirm maximum capture and RTP-send durations remain below 16.7 ms. Investigate any overflow, stale-frame, or pacing-skip counter instead of hiding it.
8. Confirm the report states either `D3D11 direct hardware frames → NVENC` after a passed exact probe or `D3D11 capture → CPU compatibility path → NVENC` after a failed probe. Neither outcome may cause FFmpeg startup failure.
9. Confirm real desktop audio is audible and synchronized locally.
10. Test private Twitch playback only after all three local phases pass repeatedly.

## Historical attempts retained for reference

## 0.3.3 decoupled audio-transport acceptance

The latest 0.3.2 Windows diagnostic is the regression baseline for this release:

- Phase without real audio: 900 frames, 40 exact consecutive duplicate images, about 57.335 unique images/s.
- Real desktop audio: 900 frames, 81 exact consecutive duplicates, about 54.601 unique images/s.
- The old 281 ms named-pipe block and `100 buffers queued` stall were absent, confirming that localhost UDP removed the original reverse-pressure failure.
- The capture thread still performed each UDP send itself, and maximum local send duration reached 16 ms.
- The tested video path still reported D3D11 capture followed by CPU readback/scaling; zero-copy activation remains a separate task.

Version 0.3.3 changes the architecture rather than another timestamp setting:

- WASAPI packet collection only timestamps and copies into preallocated queue slots.
- The producer never calls the socket transport and uses nonblocking queue admission.
- A dedicated output thread sends fixed approximately 10 ms chunks. Missing portions stay zero-filled; delayed queued frames are discarded rather than burst-delivered.
- The queue is capped at 250 ms. Overflow drops oldest data until depth returns near 100 ms, records the dropped frame count, marks a discontinuity, and re-anchors the writer.
- Phase B generates D silence through the same queue/writer/UDP/raw-PCM path without opening WASAPI.

Static validation completed in this source package:

1. `tests/verify-audio-transport.py` confirms the capture packet loop contains queue insertion but no UDP/socket send or allocation, and confirms transport ownership in the writer.
2. The verifier confirms all three diagnostic modes, FFmpeg queue-warning detection, and required ring/writer/capture metrics.
3. The Windows-only ring unit test verifies bounded overflow drops old packets, recovery re-anchors to the newest retained packet, and silent slots remain covered without being counted as real sample data.
4. JSON and source-delimiter validation pass.
5. A three-second localhost-UDP pacing test sent one 480-frame f32le stereo chunk every 10 ms into FFmpeg 7.1.3 and produced exactly 180 video frames at 60/1 with no `buffers queued` warning. This validates the transport shape, not the Windows thread implementation.

Required Windows checks before calling the issue fixed:

1. Build with the project DMD x86_64 toolchain and run `CHECK-STREAM-PACING.bat`.
2. Use the same continuously moving game view and audible endpoint for Phase A, B, and C; repeat the complete test at least three times.
3. Confirm Phase B remains within two unique images/s of Phase A. A regression here isolates the paced transport or FFmpeg input.
4. Confirm Phase C remains within two unique images/s of Phase B and the no-real-audio baseline. A regression only in C isolates WASAPI/endpoint handling.
5. Confirm `FFmpeg queue warnings: 0` in every phase and no long output-time freeze followed by greater-than-1.1x catch-up.
6. Confirm maximum WASAPI capture duration remains below 16.7 ms and the capture thread reports zero transport writes by construction.
7. Confirm overflow, producer-contention, stale-audio, pacing-skip, re-anchor, silence-replacement, and UDP-drop counters are understood; unexpected nonzero values fail acceptance until explained.
8. Confirm audio is audible and synchronized.
9. Test Twitch separately only after local A/B/C files pass.
10. Treat D3D11 zero-copy activation as separate: the report must state the path that actually ran, but audio acceptance does not depend on claiming zero-copy.

## 0.3.2 nonblocking desktop-audio transport acceptance

The 0.3.1 Windows diagnostic provides direct regression evidence:

- Silent phase: 900 frames, about 57.5 unique images/s.
- Real desktop-audio phase: 900 frames, about 47.8 unique images/s.
- The WASAPI capture thread blocked for 281 ms while writing into FFmpeg's named pipe.
- FFmpeg reported `100 buffers queued in out_#0:0`, then processed the accumulated backlog at up to 1.36x speed.
- The proposed D3D11 direct path had not activated; the diagnostic correctly reported CPU readback/scaling.

Version 0.3.2 removes the demonstrated reverse-pressure path. WASAPI now sends aligned PCM over nonblocking localhost UDP; an unavailable or slow FFmpeg receiver drops a bounded audio datagram and records it instead of suspending the capture thread. The URL configures an 8,192-byte receive packet size and a 1 MiB socket buffer and an 8,192-unit FFmpeg receive FIFO. The D3D11/NVENC direct path remains an optional capability and must never be claimed when its startup probe fails.

Required Windows checks for 0.3.2:

1. Play continuous sound through the exact endpoint selected in Aurora Stream.
2. Run `CHECK-STREAM-PACING.bat` with the same continuously moving scene in both phases.
3. Confirm the real-audio FFmpeg command uses a `udp://127.0.0.1:...` input containing `pkt_size=8192`; it must not contain `\\.\pipe\aurora-stream-loopback`.
4. Confirm `maximum local transport send` stays near zero and `local UDP frames dropped` remains zero after startup.
5. Confirm the raw FFmpeg log contains no `100 buffers queued` warning and no long period where output time remains frozen before a faster-than-real-time catch-up burst.
6. Compare effective unique-image FPS. The real-audio result should remain within two FPS of the silent baseline for the same genuinely moving scene.
7. Confirm FFmpeg output frame timestamps remain monotonic at 60/1 and AAC remains 48 kHz stereo.
8. The header may report either `D3D11 zero-copy → NVENC` or the CPU-readback compatibility path. Zero-copy is beneficial but is not required for validating the audio fix.
9. If any UDP frames are dropped, the report must expose the count instead of hiding it.

## 0.3.0 event-driven desktop-audio acceptance

The first completed A/V pacing report is treated as direct regression evidence:

- Silent baseline: 900 frames, 32 exact consecutive image duplicates, about 57.9 unique images per second.
- Desktop-audio path: 900 frames, 150 exact consecutive image duplicates, about 50.0 unique images per second.
- Desktop-audio transport: zero real WASAPI packets and 100% synthetic silence.

This proves that the former polling/silence-pipe path could reduce unique captured desktop frames even without processing real audio. Version 0.3.0 therefore replaces polling rather than applying another FFmpeg bitrate, resampler, or muxer adjustment.

Required Windows checks:

1. Build and launch on Windows 10 19045 or newer.
2. Play continuous audible sound through the exact playback endpoint selected in Aurora Stream.
3. Run `CHECK-STREAM-PACING.bat` while keeping the same continuously moving game scene during both phases.
4. Confirm the real-audio phase reports nonzero WASAPI packets and real captured frames.
5. Confirm event wakeups are nonzero while audio is active and idle timeouts remain bounded.
6. Confirm average/minimum/maximum interval and settled-speed fields no longer print `nan`.
7. Compare effective unique-image FPS. The real-audio result should remain within two FPS of the silent baseline and should normally exceed 57 unique images per second for a genuinely changing 60 FPS scene.
8. Start a private Twitch stream and confirm the status log does not warn that only silence is reaching FFmpeg while audible sound is playing through the selected endpoint.
9. Confirm stopping a stream wakes and joins the event-driven audio thread without delay or a leaked handle.
