# Aurora Stream changelog

## Unreleased

- Added a persistent **activity log** (`aurora-stream-activity.log` beside the
  executable) plus a UI-thread **stall detector**. The log records UI
  heartbeats, window focus/minimize/restore events, stream start/stop, and any
  UI stall: a watchdog thread writes "UI STALL DETECTED … State: …" the moment
  the UI stops ticking for over 3 seconds and "UI STALL RESOLVED after … s" when
  it resumes, so a one-time freeze is now diagnosable from one file.
- **Alt-tab no longer kills the stream on Desktop Duplication loss.** Alt-tab
  to/from a fullscreen-exclusive application, a resolution change, the lock
  screen, or a UAC prompt makes Desktop Duplication lose its output
  (`AcquireNextFrame failed`). The stream previously stopped instantly on the
  first such line; it is now treated as recoverable and FFmpeg is relaunched up
  to 3 times (300 ms apart) so the stream survives the transition — the FIFO
  muxer reconnects the destination. Only after the relaunch budget is exhausted
  is it reported as a permanent capture failure, and a user Stop during the
  recovery window is respected. The startup log records `DESKTOP CAPTURE
  OUTPUT LOST` and `RELAUNCH … (recovery N of 3)`.
- Window/game capture now handles **minimized windows** explicitly. A minimized
  window has a 0×0 client area, so FFmpeg's `gdigrab` fails on it and the stream
  would otherwise sit on a frozen last frame while all encoder timers kept
  advancing (no watchdog could catch it). Now: the CAPTURE SOURCE list marks
  minimized windows as `(minimized — not capturable)`, the selector caption
  shows `Window (minimized): …`, Start rejects a minimized selection with a
  clear message, and the live worker stops the moment the captured window is
  minimized or closed ("Window capture stopped — the captured window was
  minimized/closed") instead of freezing. The LIVE SOURCE CANVAS preview also
  keeps its last good frame for a minimized window.
- Added a **game/window capture source** (Settings → **CAPTURE SOURCE**): pick a
  single game or app window from the dropdown and Aurora Stream streams **only
  that window** through FFmpeg's `gdigrab hwnd=` path, so viewers never see the
  rest of the desktop. The selection is persisted in the settings file (schema
  6); a saved window that is closed or belongs to an earlier Windows session is
  reported at Start instead of silently streaming the desktop. The **LIVE SOURCE
  CANVAS** preview follows the selection and shows the captured window too.
  Window capture always uses the CPU path (`Window capture (GDI) → CPU
  processing → encoder`); the D3D11 zero-copy handoff only applies to full
  desktop Duplication. The window list is re-enumerated every time the dropdown
  opens, and a **Refresh window list** item is included.
- The live stream now **retries the FFmpeg launch** (up to 4 attempts) when
  FFmpeg exits immediately with the transient Windows UDP bind race
  (`-10048`, `bind failed`) on the audio RTP port. The handoff already proved
  the port pair free, so this only affects the rare close→re-bind race that
  could otherwise stop streaming right after Start; the failure now surfaces a
  clear "FFmpeg could not bind the audio UDP port" status if all retries fail.
- YouTube output now **defaults to 1080p60** (12 Mbps) instead of 1440p60; the
  YouTube quality selector is a proper 1080p/1440p/4K dropdown (was a 4K-only
  checkbox), so 1440p60 and 4K60 remain selectable higher profiles that keep
  the highest internet streaming quality. Existing saved YouTube qualities are
  preserved.
- Made the custom-titlebar build the **default** configuration: `dub build` /
  `dub run` now produce `aurora-stream` with the `TitleBar`-style window. The
  plain OS-titlebar build moved to a `notitlebar` configuration
  (`aurora-stream-notitlebar`, launcher `RUN-WINDOWS-NOTITLEBAR.bat`); the old
  `RUN-WINDOWS-TITLEBAR.bat` and `aurora-stream-titlebar.exe` are gone.
- Removed the **Aurora-rendered program canvas** feature (the "Program canvas"
  Settings item, its settings section/editor, the settings keys, and the
  broadcaster's raw-BGRA canvas pump), as it is outdated and unused. The app
  always streams desktop capture; the **LIVE SOURCE CANVAS** panel remains as
  the live desktop-recording preview.
- Custom-titlebar build: the **minimize** button and system-menu item now
  actually minimize the window, and clicking the **taskbar** icon minimizes it
  again. Root cause: frameless windows were created with `WS_POPUP` but without
  `WS_MINIMIZEBOX`/`WS_MAXIMIZEBOX` (so the shell ignored taskbar
  click-to-minimize), the titlebar's `onMinimize` was wired to an empty
  delegate, and `GuiWindow` had no minimize API. Added
  `minimize()/restore()/isMinimized()` to the aurora-d window abstraction
  (`platform/base.d`, `platform/win32.d`, `window.d`) and wired the titlebar to
  it.
- Fixed distorted rendering for a few frames when restoring from the taskbar:
  while minimized the app kept rendering 1×1 frames, so the restore animation
  scaled a solid 1×1 box up. The window now keeps its last full-size
  framebuffer while minimized, pauses rendering until restore (also saves
  energy), and the live source-canvas preview also pauses while minimized.
- Fixed the periodic audio-device auto-rescan never running: `_audioRescanTimer`
  was D-default NaN (D floats initialize to NaN, not 0), so `NaN >= interval`
  was never true and disconnected/reconnected devices were not picked up while
  the app ran. The timer is now explicitly `0.0`; the audio-device lists refresh
  every 8 seconds (verified: ffmpeg DirectShow scans fire on schedule).
- A disconnected audio device now shows a clear **Unavailable** state: the
  device selectors turn the selected endpoint's caption into
  "Unavailable — <cached name>" and highlight it (danger style) as soon as a
  scan finds it missing. Detection is guaranteed by an 8-second safety-net
  auto-rescan that runs while the app is open (in addition to Core Audio
  `IMMNotificationClient` callbacks), so unplugging headphones or a mic is
  reflected within the interval even on systems where the notification path is
  unavailable.
- Audio device selectors now keep friendly names for disconnected devices: a
  persistent device-identifier → name cache is filled from every scan and
  saved in the settings file, so a temporarily unplugged speaker/mic still
  shows "Unavailable — Headphones (High Definition Audio Device)" instead of a
  raw backend ID, even across restarts.
- The app now listens for Windows audio device add/remove/state changes
  through Core Audio's `IMMNotificationClient` (`AudioDeviceNotifications` in
  wasapi.d) and auto-rescans the desktop/microphone lists while running, so
  newly connected or disconnected devices no longer leave the selectors stale;
  the manual Refresh button remains for edge cases.
- The **LIVE SOURCE CANVAS** live preview now captures at the preview panel's
  own resolution (tracked on resize, 16:9, capped at 1280×720) instead of a
  fixed 480×270 buffer, so the desktop is shown sharp at ~1:1 rather than
  upscaled and blurry. CPU stays low: ~11% of one core (~3% of all cores) at
  30 FPS with the panel-sized capture.
- Made the **LIVE SOURCE CANVAS** live preview cheap to run. The capture
  thread now reuses one persistent GDI memory DC + DIB section and the same
  `RgbaImage` (so the GPU texture is never recreated and the texture cache
  stops growing), switches `StretchBlt` from HALFTONE to COLORONCOLOR (no
  software dithering on every downscale), and the preview widget is a retained
  compositor layer so updating it repaints only the preview area instead of the
  whole window. Measured CPU dropped from saturating the machine to ~8% of one
  core (~2% of all cores) at 30 FPS.
- The **LIVE SOURCE CANVAS** panel is now a real live recording preview: in
  desktop-capture mode a background thread grabs the primary monitor at ~30 FPS
  through an in-app GDI capture (`desktoppreview.d`) so the panel shows exactly
  what the stream is recording without blocking the UI, and in program-canvas
  mode it continues to show the Aurora-rendered composite (which is precisely
  the recorded content). Fixed the DIB BGRA→RGBA channel conversion so the
  preview no longer shows red/blue swapped (a dark-blue theme appeared brown),
  with a deterministic byte-order regression test. The panel stays visible by
  default; only the program-canvas **settings** section remains behind the
  Settings menu.
- Moved the **Program canvas** settings section and the **LIVE SOURCE CANVAS**
  preview behind the toolbar **Settings → Program canvas** toggle, hidden by
  default (revealed automatically only when a saved session has the canvas
  enabled). The status panel fills the monitor column while the preview is
  hidden, keeping the default layout focused on desktop capture.
- Reject **Start streaming** when the Aurora program canvas is enabled but has
  no visible source, instead of streaming a pure-black canvas with healthy
  encoder stats. The settings now fail with an explicit message pointing to
  adding a color/image/text source or disabling the program canvas.
- Fixed the frame-pump crash on stop (heap corruption `0xc0000409` in
  MSVCR120): the pump wrote through the CRT `_write` on the pipe file
  descriptor, so no phobos `File` object crosses the thread boundary and the
  descriptor is closed exactly once by the worker that owns it.
- Fixed a crash when starting streaming with the Aurora program canvas enabled
  (access violation in `File.rawWrite`): the phobos `File` object was passed
  across the thread boundary into the canvas frame-pump thread, where its
  heap-allocated `_p` could be null/garbage by the time `rawWrite` ran. The
  pump now receives only the raw file descriptor and writes directly with the
  CRT `_write`.
- Fixed a stray command prompt opening on every **Start streaming**: the
  broadcaster spawns the isolated WASAPI RTP helper with `Config.suppressConsole`
  (CREATE_NO_WINDOW), but both `app.d` and `app_titlebar.d` still listed
  `--audio-rtp-helper` as a console-allocating diagnostic command, so
  `AllocConsole()` created a visible console window for the helper. The helper
  only communicates through status/metrics files and UDP, so
  `--audio-rtp-helper` no longer allocates a console; manual diagnostics that
  print to stdout still do.
- Added the **Aurora-rendered program canvas** (`programcanvas.d`): a composited source canvas rendered by Aurora itself that replaces direct desktop capture while keeping the independent Twitch/YouTube output profiles.
- Program canvas sources: color fills, PNG image sources, and live text sources, each with visibility, opacity, and stacking order.
- Added a live **LIVE SOURCE CANVAS** preview panel that renders the composite letterboxed to the selected source-canvas aspect ratio.
- The broadcaster now feeds the rendered canvas to FFmpeg over stdin as raw BGRA (`-f rawvideo -pix_fmt bgra -s WxH -framerate 60 -i pipe:0`) on a dedicated paced frame-pump thread; the existing CFR cadence filter (`fps=60:round=near`, `setpts=N/(60*TB)`) still normalizes timestamps.
- Program-canvas mode disables the direct D3D11/NVENC zero-copy path (canvas frames are CPU-composited) and reports `Aurora program canvas → CPU composite → encoder`.
- Persisted program-canvas state in settings schema 5 (`programCanvasEnabled`, `programCanvasSources`).
- The pacing diagnostic explicitly forces desktop capture so it never emits a raw pipe input that would hang without a frame pump.
- Fixed **Unhide streaming servers** reserving only a sliver of spacing: the Twitch and YouTube server groups now receive their full label-plus-input height when restored to the settings layout.
- Shortened the YouTube 4K toggle to **4K / 2160p60 highest-quality** to reduce horizontal crowding in the settings panel.
- Changed live RTMP/RTMPS FIFO output from drop-on-overflow to a larger non-dropping queue plus a post-startup watchdog, so a sustained Twitch/network stall stops with `Live output stalled` instead of feeding Twitch a damaged stream that can become a black buffering player.
- Avoided Desktop Duplication readback on CPU-only `libx264` machines by selecting the GDI compatibility capture path when no hardware H.264 encoder is available.
- Added immediate detection for Desktop Duplication `AcquireNextFrame failed` plus a frozen-video-frame watchdog, so audio-only progress cannot hide a dead video capture path.
- Stopped assigning the isolated audio helper below-normal process priority and registered its capture/pacing thread with Windows MMCSS `Audio` at high multimedia priority.
- Stopped converting ordinary Windows wake-up jitter and short scheduler stalls into explicit RTP timestamp gaps; the helper now preserves every sample and catches up locally for delays below 100 ms, skipping only longer unrecoverable delays.
- Added `mmcss_enabled` to helper metrics and made quality acceptance require that real-time scheduling was active.
- Separated the normal first-packet WASAPI discontinuity flag from true mid-stream discontinuities so diagnostics do not report a startup condition as an audible crack.
- Increased FFmpeg's local desktop-audio RTP thread queue, UDP receive buffer, and reorder queue so slow video initialization cannot discard otherwise clean WASAPI packets and create startup cracks/dropouts.
- Migrated older empty desktop-audio settings to the active Windows default endpoint while preserving an explicit schema-4 **Disabled** choice.
- Added a headless, silent loaded-audio regression that exercises desktop capture, NVENC, AAC, FIFO output, and timestamped RTP without covering the user's screen.
- Added a full A/V phase for the exact live D3D11-direct-to-NVENC path with the same 360-packet FIFO configuration used by network outputs.
- Added a two-output local phase matching the default Twitch 1080p60 plus YouTube 1440p60 scaling, bitrate, dual-NVENC, audio split, and FIFO workload.
- Changed the repeat selection to prefer a candidate that already passes video, audio, and synchronization instead of choosing on video-weighted score alone.
- Added visually near-identical adjacent-frame detection after H.264 decode, because exact frame hashes alone can miss repeated source images after lossy reconstruction.
- Added expected-dimension checks so a native-resolution direct capture cannot be mislabeled as a 1080p pass.

## 0.4.9

- Added `RUN-QUALITY-DIAGNOSTIC.bat`, a single-click deterministic 1080p60/audio quality matrix that does not contact Twitch or YouTube.
- Added a synchronized FFplay test card with frame-by-frame motion, a continuous 997 Hz tone, and simultaneous one-second video/audio markers.
- Added strict decoded-output measurements for unique-image FPS, exact duplicate frames, duplicate-run length, timestamp intervals, audio dropouts, sine-phase jumps, clipping, A/V offset/jitter/drift, FFmpeg queue warnings, and helper pacing/overflow counters.
- Added CPU, memory, NVIDIA GPU utilization, power, and temperature sampling using only Python's standard library and system tools.
- Added current-path, lower-overhead BGRA, no-async/gentle-async audio, FIFO, 720p60, audio-only, and repeated-best-path comparisons.
- A path is recommended only when the same 1080p implementation passes all strict video/audio/sync thresholds twice.
- No live streaming architecture changed in this diagnostic-only release.

## 0.4.8

- Fixed the Windows DMD compile error in `preventSocketInheritance`: `const handle` inferred `const(void*)`, which cannot be passed to `SetHandleInformation(HANDLE, DWORD, DWORD)`.
- The socket handle is now stored as mutable `HANDLE`, and the cleared flag value is explicitly `0U`.
- Added a static regression check for the exact Windows API call signature.
- No streaming, capture, RTP, FFmpeg, or UI behavior changed in this compile-only correction.

## 0.4.7

- Fixed the repeated Windows RTP/RTCP `-10048` startup failure caused by receiver reservation sockets surviving in the spawned audio-helper process.
- Marked both reservation socket handles non-inheritable with `SetHandleInformation(..., HANDLE_FLAG_INHERIT, 0)` before the helper is launched.
- Added a runtime handoff proof: after the helper binds its distinct RTP source, Aurora Stream closes and reacquires the exact RTP/RTCP destination pair. If either port is still owned, streaming is not launched and the precise ownership failure is written to `aurora-stream-startup.log`.
- Keeps the refreshed pair reserved until the instant before FFmpeg starts, preventing unrelated processes from taking it during command construction.
- Added the same handoff verification to live streaming, pacing diagnostics, and the one-click `AudioBridgeSession` self-tests.

## 0.4.6

- Restored bounded FFmpeg FIFO isolation for every live RTMP/RTMPS destination. A direct network muxer performs the TCP/TLS/RTMP handshake synchronously and can prevent the capture/encode loop from producing its first frame; local direct-FLV success did not prove live-network startup.
- Increased the bounded live output queue to 360 packets and kept drop-on-overflow, keyframe restart, and recovery enabled so reconnects return near real time rather than replaying stale data.
- Added a localhost-only regression that deliberately stalls an RTMP handshake and proves direct output emits no progress while the FIFO-isolated encoder continues.
- Separated audio-helper transport readiness from actual WASAPI packet capture. The helper publishes a one-time `capturing` state when the first real packet arrives; the live log records either that transition or a clear silent-endpoint notice while RTP silence keeps A/V running.
- Removed the known irrelevant NVENC `sc_threshold` option warning; the option remains only for libx264 where it is valid.
- Retained the 12-second encoder startup deadline and the complete sanitized `aurora-stream-startup.log`.

## 0.4.5

- Selected the helper-first real WASAPI/RTP path after it passed all three repeated full A/V direct-FLV runs in the Windows diagnostic.
- Changed one-service live output from the unproven FIFO wrapper to direct FLV, matching the successful real-audio test topology.
- Retained per-destination FIFO isolation only when Twitch and YouTube are both enabled.
- Added a monitor independent of FFmpeg stderr/progress that checks the audio helper every 100 ms.
- Added a hard 12-second first-frame/output-time startup deadline; a stalled process is terminated instead of remaining on `Connecting` indefinitely.
- Added `aurora-stream-startup.log` with sanitized FFmpeg arguments, stderr/progress, exit code, timeout/exception reason, and final helper metrics.
- Updated the full diagnostic interpretation so a short zero-packet standalone interval cannot override successful full real-A/V captures.
- Added the missing helper-first real-WASAPI FIFO comparison (`W08`).
- Made the standard-library RTP/SDP integration retry the demonstrated transient Windows `-10048` bind race with fresh port pairs.

## 0.4.4

- Added `RUN-ALL-DIAGNOSTICS.bat` and a standard-library diagnostic matrix that writes every command, error, timeout, helper status, RTP metric, FFmpeg log, output probe, and conclusion into one `aurora-stream-all-diagnostics.txt` file.
- Added build/unit/static checks, system and FFmpeg capability inventory, NVENC/Desktop Duplication/GDI/software controls, twelve RTP/RTCP ownership iterations, D `AudioBridgeSession` self-tests, synthetic and real WASAPI helper tests, audio-only and A/V RTP tests, helper-first versus receiver-first ordering, direct versus FIFO FLV, repeated real-audio runs, and optional DirectShow loopback testing.
- Added CLI-only endpoint enumeration and bridge-session test modes used by the diagnostic without opening the GUI or reading stream keys.
- Added automatic identification of the known indefinite-connecting defects: no FFmpeg startup watchdog, helper failure inspection tied to FFmpeg progress, and helper readiness preceding receiver readiness.
- No live streaming path was changed. This release exists to collect decisive Windows evidence before implementing another transport change.

## 0.4.3

- Fixed the Windows startup failure where FFmpeg reported two UDP `bind failed` messages with socket error `-10048` and exited before capture began.
- Reserve the adjacent RTP and RTCP receive ports together instead of reserving only one arbitrary UDP port.
- Keep both receiver reservations alive while the isolated helper explicitly binds its own distinct localhost source port; release the reservations only immediately before FFmpeg launch.
- Declare the RTCP port explicitly in SDP.
- Added source/destination RTP port metrics and static/integration regressions for port ownership and startup ordering.
- The D3D11 compatibility fallback and process-isolated WASAPI/RTP design are otherwise unchanged.

## 0.4.2

- Fixed the Windows runtime failure where the exact-match D3D11 frame path was selected solely from dimensions and encoder name, then `h264_nvenc` failed to open with exit code -2.
- Added an exact startup probe that sends real `ddagrab` D3D11 frames through the same NVENC profile used by the live stream.
- The direct path is now selected only after that probe succeeds. Unsupported FFmpeg/driver combinations automatically use the proven CPU readback/scaling compatibility path before the live FFmpeg process starts.
- Added visible probe diagnostics and unit coverage for both the direct path and the compatibility fallback.
- No desktop-audio RTP architecture was changed.

## 0.4.1

- Restored the `jsonString` and `runJson` helpers accidentally omitted from `pacingdiagnostic.d` in 0.4.0.
- Fixed the Windows DMD build failure before the pacing diagnostic could run.
- No A/V architecture or FFmpeg behavior changed from 0.4.0.

## 0.4.0

- Rejected 0.3.3 as a fix after its Windows A/B/C diagnostic showed Phase B falling from 53.601 to 45.668 unique images/s and Phase C capturing zero WASAPI packets while substituting 100% silence.
- Removed the GUI-process PCM queue, 10 ms output thread, raw UDP input, and desktop-audio wall-clock timestamp reconstruction from the active architecture.
- Added a same-executable `--audio-rtp-helper` mode launched as a separate low-priority process. The main Aurora Stream process now owns no desktop-audio capture or pacing work.
- Rebuilt WASAPI capture as event-driven shared-mode loopback with automatic conversion to 48 kHz stereo PCM16, a preallocated bounded queue, and one absolute-clock 20 ms output interval.
- Added timestamped RTP L16/48000/2 delivery through an SDP input. One 960-frame localhost datagram is sent per interval; late intervals become RTP timestamp gaps and a fresh deadline instead of catch-up bursts.
- Added explicit overflow, stale-frame, pacing-skip, discontinuity, event wake/timeout, send-failure, capture/send-duration, captured-packet, and queue-depth metrics.
- Phase B now uses a separate synthetic-RTP helper process. Phase C is invalidated when zero WASAPI packets were captured, preventing generated silence from masquerading as a real-audio result.
- Removed FFmpeg's reconnecting FIFO wrapper from local diagnostics and write the test FLV directly.
- Changed FLV `max_interleave_delta` to zero after local RTP validation reproduced an AAC negative-timestamp mux failure with the prior 100 ms limit.
- Selects the matching single-output Desktop Duplication-to-NVENC path only when probed capture dimensions exactly match the source and destination. The unreliable speculative direct-path startup probe was removed, and an unsupported selected direct path now fails visibly rather than being mislabeled as zero-copy.
- Added static architecture checks and a standard-library RTP/SDP-to-FLV integration test.

## 0.3.3 — rejected architecture

- Removed UDP delivery, silence generation, and FFmpeg pacing work from the WASAPI capture thread. The capture thread now only maps packet positions and copies packet data into a preallocated bounded queue.
- Added a dedicated audio-output thread that emits one fixed approximately 10 ms PCM chunk per interval, uses queued endpoint frames where available, and fills only uncovered frames with silence. It never drains a delayed backlog in a burst.
- Added a preallocated 250 ms packet ring with nonblocking producer admission. Overflow drops the oldest queued audio until latency returns near 100 ms, records the dropped frame count, and forces a writer timeline re-anchor.
- Kept localhost UDP as the final nonblocking FFmpeg transport, but confined every socket send to the output thread. Maximum capture duration and writer-completion duration are measured separately.
- Added the missing three-phase isolation diagnostic: FFmpeg `anullsrc`, D-generated silence through the exact paced transport, and real WASAPI capture through the ring buffer.
- Added queue-warning detection plus ring depth, overflow/contention/late drops, silence replacement, pacing skips, writer re-anchors, pending writes, capture duration, and writer duration to the generated report.
- Added a source-level architecture verifier and a Windows ring-buffer unit test.
- Kept the D3D11 zero-copy activation problem separate from the audio correction; the diagnostic continues to print the video path that actually ran.

## 0.3.2

- Replaced the synchronous WASAPI-to-FFmpeg named pipe with nonblocking localhost UDP PCM transport. FFmpeg can no longer backpressure or stall the Windows audio capture thread.
- Restored wall-clock timing and bounded async correction for the independently clocked desktop-audio input.
- Corrected the D3D11/NVENC capability probe so it tests direct Desktop Duplication surfaces without inserting software-only FPS filters.
- The matching 1080p single-destination path now maps D3D11 frames directly into NVENC without `hwdownload`, software scaling, or a CFR conversion filter.
- The pacing diagnostic reports local UDP transport delay and dropped PCM frames and now reveals whether the direct D3D11 path actually activated.

## 0.3.1

- Used the second completed A/V report as direct evidence that the event-driven WASAPI rewrite did not solve the visible motion regression: the silent baseline delivered about 58.1 unique images/s while the real-audio phase delivered about 49.3 unique images/s, despite both outputs carrying 900 frames with valid 60/1 timestamps.
- Identified the remaining architectural bottleneck in the exact FFmpeg command: `ddagrab` hardware frames were downloaded to system memory, software-scaled twice in the Twitch-only 1080p path, converted, and then uploaded again for NVENC. The silent baseline already ran at only 0.996x, leaving effectively no processing headroom.
- Added a startup probe for direct D3D11 Desktop Duplication surfaces into `h264_nvenc`.
- Added a zero-copy D3D11-to-NVENC video path for a single destination whenever the captured monitor size, common source resolution, and destination resolution match. Normal Twitch-only 1080p streaming on a 1080p monitor now uses this path when supported.
- Kept a compatibility fallback for systems where D3D11-to-NVENC negotiation fails, while removing one redundant software scale pass whenever source and destination resolutions already match.
- Removed FFmpeg wall-clock timestamping from Aurora Stream's native raw WASAPI PCM pipe. The bridge already produces a continuous sample-count timeline; only independently clocked DirectShow microphone input retains wall-clock timestamps and asynchronous drift correction.
- Removed the second asynchronous resampler after audio mixing; normalized inputs are mixed and rebuilt from the final 48 kHz sample count.
- Displayed the active video path in the main status panel and A/V pacing diagnostic.
- Fixed diagnostic floating-point fields that still printed `nan`; D floating-point values default to NaN, so all intended accumulators and metrics now initialize explicitly to `0.0`.
- Extended the zero-copy unit model check to reject any `hwdownload` or software scaling in the matching Twitch-only D3D11/NVENC path.

## 0.3.0

- Used the first completed A/V pacing report to isolate the actual failure: both phases encoded 900 frames at 60/1 timestamps and approximately real-time speed, but the audio-enabled phase contained 150 exact consecutive image duplicates versus 32 in the baseline—about 50.0 versus 57.9 unique images per second.
- Confirmed the tested desktop-audio phase captured zero WASAPI packets and wrote 100% synthetic silence, so the old audio transport itself—not AAC bitrate, Twitch upload, or real audio processing—was enough to expose repeated desktop frames.
- Replaced the 1–2 ms polling loop with Windows event-driven WASAPI loopback using `AUDCLNT_STREAMFLAGS_EVENTCALLBACK`, `IAudioClient.SetEventHandle`, and `WaitForSingleObject`.
- Changed event-driven shared-mode initialization to zero buffer duration and periodicity, matching the WASAPI contract.
- Removed per-pass silence allocation and zeroing. One fixed 20 ms zero buffer is allocated once and reused for the complete stream.
- Reduced idle wakeups to one event wait or 20 ms timeout instead of repeated `GetNextPacketSize` polling and `Sleep(1/2)`.
- Added live warning output when a selected desktop endpoint produces no real WASAPI packets for at least two seconds.
- Added final desktop-audio transport telemetry to the status log: packet count, real/silent frames, event wakeups, and timeouts.
- Extended the A/V diagnostic with event wakeup/timeout counts and effective unique-image FPS.
- Fixed diagnostic `nan` statistics by rejecting non-finite FFprobe/progress values instead of including them in interval and speed calculations.

## 0.2.9

- Fixed the A/V pacing diagnostic compilation failure by making its private settings copy mutable before forcing Twitch-only diagnostic output.
- No live streaming behavior was changed.


## 0.2.8

- Added a dedicated **A/V pacing diagnostic** instead of applying another unverified live-audio timing change.
- Added `CHECK-STREAM-PACING.bat` and the `--pacing-test` application mode.
- Added **Settings → Run A/V pacing diagnostic**; it refuses to launch while a stream is active and saves current settings before opening the separate terminal test.
- The diagnostic records two local 15-second Twitch-equivalent FLV files from the same moving scene: generated silent audio versus the currently selected real desktop/microphone inputs.
- Kept the capture backend, common source canvas, Twitch 1080p60 scaling, selected H.264 encoder, 6000 kbps profile, AAC output, CFR policy, FIFO/FLV muxing, and interleave settings identical between both phases.
- Added FFprobe analysis of frame display timestamps, interval distribution, AAC packet gaps/overlaps, stream rates, and duration.
- Added exact consecutive decoded-frame hashing through FFmpeg `framemd5`, including duplicate ratio and longest identical-frame run, to expose repeated image content that aggregate FPS counters can hide.
- Added live WASAPI transport instrumentation for packet count, real/silent frames, discarded overlap, discontinuities, timeline re-anchors, maximum packet arrival gap, maximum blocking named-pipe write, bytes written, and final wall-clock error.
- The generated report explicitly distinguishes local capture/encode failure from a downstream RTMP/Twitch ingest or player problem.
- No additional speculative audio correction was applied to the normal streaming path in this version.

## 0.2.7

- Replaced the standalone top-toolbar **Unhide streaming servers** checkbox with a compact **Settings** dropdown in the same position.
- Added **Unhide streaming servers** as a checked menu item inside Settings.
- Fixed server URL reveal by toggling both widget visibility and layout participation, explicitly relaying out the root/scroll viewport, and scrolling the Twitch server field into view when revealed.
- Kept both server URL controls hidden by default on every launch without changing their saved values.
- Moved YouTube's **4K / 2160p60 highest-quality output** checkbox onto the same row as **Stream to YouTube**.
- Kept all output, stream-key, audio, and saved-settings behavior unchanged.

## 0.2.6

- Reworked A/V synchronization after repeated live tests showed that enabling a real audio input could still make motion appear below 60 FPS even though video-only streaming remained smooth.
- Identified the missing layer in the previous fix: the native WASAPI named-pipe PCM and DirectShow microphone inputs were not explicitly stamped from the wall clock, so FFmpeg could treat bursty live-audio delivery as a different clock from desktop video.
- Added `-use_wallclock_as_timestamps 1` independently to every real audio input.
- Rebuilt the source video timeline as an exact 60 FPS clock with `fps ... start_time=0` and `setpts=N/(60*TB)`.
- Rebuilt each corrected 48 kHz audio timeline from consumed sample count with `asetpts=N/SR/TB` after asynchronous resampling.
- Forced CFR output explicitly for each Twitch and YouTube video stream.
- Limited each underlying FLV muxer to 100 ms of A/V interleave buffering and enabled immediate packet flushing, preventing a late audio packet from holding video for the default 10-second interleave window.
- Increased each independent output FIFO queue to 120 packets while retaining overflow dropping and recovery isolation.
- Added duplicated-frame and output-time telemetry beside FPS, speed, and dropped frames so the next live test can distinguish encoder overload from clock/interleave trouble.
- Added a startup diagnostic line describing the active A/V pacing policy.
- Reproduced the old behavior with a jittered raw-PCM pipe in a local FFmpeg test: the uncorrected graph finished six seconds of video with only about 4.4–4.7 seconds on the output clock, while the wall-clock-stamped and normalized graph finished at about 5.98 seconds and approximately real-time speed.

## 0.2.5

- Fixed text-input context menus so their top-left corner opens at the actual right-click position instead of placing the complete menu above the pointer.
- Reconstructed the menu position from the clicked field's local pointer coordinates, avoiding stale or differently transformed global coordinates.
- Added a top-toolbar **Unhide streaming servers** checkbox immediately to the left of the source/output summary.
- Hid the editable Twitch and YouTube server URL labels and fields by default to reduce normal UI complexity.
- Kept stream-key fields, destination controls, quick links, output profiles, and saved server values unchanged; the checkbox only reveals or conceals the advanced server URL controls.

## 0.2.4

- Replaced the normal live desktop path from FFmpeg `gdigrab` with an automatically probed Windows Desktop Duplication (`ddagrab`) path.
- Desktop Duplication keeps mouse capture enabled without using the GDI cursor path that can make the real Windows pointer flicker, disappear, or disturb focus during capture.
- Added a one-frame startup probe so Aurora Stream uses Desktop Duplication only when the installed FFmpeg build and current Windows session can initialize it successfully.
- Added a safe compatibility fallback to `gdigrab` with `-draw_mouse 0`. The fallback keeps streaming functional without touching the real cursor, but intentionally omits the cursor from the broadcast.
- Disabled Aurora's synchronized drag-pointer hiding in this application so Aurora Stream itself never intentionally hides the host pointer during startup or interaction.
- Displayed the selected capture backend beside the encoder backend and included it in stream diagnostics.
- Kept every Twitch, YouTube, audio, quality, and settings behavior unchanged.

## 0.2.3

- Replaced the two optional common-source resolution checkboxes with one compact dropdown containing **1080p60**, **1440p60 / 2K**, and **2160p60 / 4K**.
- Kept 1080p60 as the default and retained the existing `sourceQuality` settings value, so saved source resolutions autoload without migration.
- Added a standard right-click context menu to every Twitch and YouTube text input with **Cut**, **Copy**, **Paste**, and **Select all** plus their keyboard shortcuts.
- Kept stream-key rendering masked while allowing normal clipboard editing through the context menu.

## 0.2.2

- Rendered both Twitch and YouTube stream-key inputs as masked password fields so saved credentials are not exposed by the normal UI.
- Added a compact rectangular **paste** button to the right of each stream-key field. The button replaces the complete current key with Unicode text from the Windows clipboard.
- Kept normal `Ctrl+C`, `Ctrl+V`, `Ctrl+X`, and `Ctrl+A` behavior inside the masked fields.
- Made each **Stream to** checkbox unavailable while its key is empty. Removing a key unchecks the destination automatically.
- Typing or pasting a non-empty key checks the matching destination automatically. A destination with a saved key can still be manually unchecked, and that deliberate state remains saved until the key is edited again.
- Kept stream keys as their real values in `aurora-stream-settings.json`; masking protects the visible UI but does not encrypt the settings file.

## 0.2.1

- Fixed the first native WASAPI loopback pacing implementation after live testing showed smooth video with audio disabled but frame disruption with desktop audio enabled.
- Removed the old wall-clock silence behavior that could emit synthetic silence for a delayed time span and then emit the delayed real packet for the same span, advancing the audio clock too quickly.
- Added device-position-aware packet mapping, overlap removal, discontinuity re-anchoring, bounded gap filling, and a 20 ms safety window for late loopback packets.
- Increased FFmpeg audio timestamp correction from `aresample=async=1` to the documented practical `async=1000` compensation range.
- Reduced oversized input queues and the DirectShow microphone real-time buffer so a temporary audio stall cannot accumulate excessive latency as easily.
- Clarified the UI metric as **FFmpeg bitrate** and added explicit configured upload totals including AAC: 6.16 Mbps for Twitch, 24.16 Mbps for default YouTube, and 30.32 Mbps for the default simultaneous setup.
- Confirmed that the service outputs were already H.264/AAC-compressed; raw PCM exists only inside the local audio bridge before AAC encoding.

## 0.2.0

- Corrected the 0.1.9 audio architecture mistake: the desktop and microphone dropdowns no longer receive the same DirectShow capture-device array.
- Desktop audio now enumerates active Windows playback/render endpoints independently through Core Audio, so devices such as Speakers and Headphones appear in the desktop dropdown.
- Added native WASAPI shared-mode loopback capture for the selected playback endpoint.
- Added a private named-pipe bridge from D-owned WASAPI PCM capture into FFmpeg.
- Kept microphone enumeration and capture on the separate FFmpeg DirectShow path.
- Desktop audio and microphone can each remain **Disabled**, or can be enabled independently and mixed together.
- Migrated settings to schema 3. Pre-0.2 desktop selections are cleared because they contain the wrong DirectShow identifier type; all stream keys, destinations, qualities, and microphone settings remain intact.
- Updated the audio diagnostic and UI labels to describe the two separate backends accurately.
- Added Windows `ole32` linkage required by Core Audio COM interfaces.
- This milestone currently targets x86_64 Windows builds.

## 0.1.9

- Fixed audio-device enumeration with newer FFmpeg builds that print flat device entries tagged as `(audio)`, `(video)`, or `(none)` instead of separate DirectShow section headings.
- Kept compatibility with the older `DirectShow audio devices` section format.
- Preserved duplicate microphone devices by storing FFmpeg alternative device IDs internally instead of deduplicating identical display names.
- Numbered duplicate display names in the dropdown, for example **device 1** and **device 2**.
- Migrated older saved display-name selections to the matching alternative ID when devices are refreshed.
- Updated the standalone D diagnostic to capture FFmpeg stderr directly and understand both listing formats.
- Renamed the desktop selector to **Desktop audio / loopback input** and clarified that both selectors contain DirectShow capture endpoints; ordinary speakers/headphones still require Stereo Mix, a virtual capture endpoint, or future native WASAPI loopback support.

## 0.1.8

- Added compact **Open Twitch settings** and **Open YouTube Live** shortcuts beside their destination headings.
- Twitch opens `https://dashboard.twitch.tv/settings/stream` in the operating system's default browser.
- YouTube opens `https://studio.youtube.com/channel/UC/livestreaming` in the operating system's default browser.
- Browser launch success or failure is reported in the existing status panel.
- The links do not change, save, or expose stream keys and remain available while streaming.

## 0.1.7

- Added `CHECK-AUDIO-DEVICES.bat` and a standalone D diagnostic at `tests/audio-device-diagnostic.d`.
- The diagnostic runs FFmpeg's exact DirectShow enumeration command and preserves the complete raw output.
- It applies the same device-name parser used by Aurora Stream so parser failures can be distinguished from FFmpeg failures.
- It independently lists Windows playback/render and recording/capture devices through the built-in WinMM API.
- Added automatic diagnosis for missing DirectShow support, missing capture endpoints, parser mismatches, and the desktop-audio loopback limitation.
- The diagnostic writes `audio-device-diagnostic.txt`, which contains no stream keys or saved settings.
- Documented that normal playback devices do not generally appear as DirectShow capture inputs; native WASAPI loopback remains the planned reliable desktop-audio path.
- Kept Twitch fixed at normal 1080p60; Twitch Enhanced Broadcasting and Twitch 2K remain intentionally out of scope.

## 0.1.6

- Replaced the desktop-audio and microphone free-text fields with Aurora-native dropdown selectors.
- Added automatic background enumeration of FFmpeg DirectShow audio devices at program startup.
- Added **Disabled** as the first option for each audio input; both disabled continues to generate silent stereo AAC.
- Added an in-app **Refresh audio devices** action for devices connected after launch.
- Both selectors use the same enumerated DirectShow audio-device list so the user can choose the appropriate loopback and microphone endpoints.
- Existing saved device names are restored automatically and remain visible as **Saved but unavailable** when temporarily disconnected.
- Device selections continue to save in `aurora-stream-settings.json` without changing the settings schema.
- Kept `LIST-AUDIO-DEVICES.bat` as a manual diagnostic fallback only; typing device names is no longer required in the normal UI.

## 0.1.5

- Added `installation.txt` with the two required external dependencies.
- Documented the exact Windows Winget command for installing Gyan FFmpeg.
- Documented the official D language website for installing a D compiler and DUB.
- Dependency installation remains manual; no dependency-resolution or installation script was added.

## 0.1.4

- Replaced the shared-encode shortcut with independent Twitch and YouTube output chains.
- Twitch now always receives its own 1920×1080 60 FPS, 6000 kbps CBR H.264/AAC encode.
- YouTube now defaults to its own 2560×1440 60 FPS, 24000 kbps H.264/AAC encode.
- Kept YouTube 4K60 as an optional highest-quality output at 3840×2160 and 35000 kbps.
- Added a common source-canvas selector: 1080p by default, optional 1440p or 4K.
- Added explicit per-destination scaling from the selected common source canvas.
- Each enabled destination now has its own video encoder, audio encoder, FLV muxer, FIFO recovery queue, and endpoint.
- Removed FFmpeg tee output from simultaneous Twitch + YouTube streaming.
- Added settings schema 2 with separate source, Twitch, and YouTube quality fields.
- Added automatic migration from the old shared `quality` field; old 1080p/2K settings become YouTube 1440p, while old 4K remains YouTube 4K.
- Updated UI summaries so the source resolution and both destination profiles are always visible.

## 0.1.3

- Added automatic persistence of every current broadcaster setting in `aurora-stream-settings.json`.
- Settings are loaded before the controls are created, so destinations, keys, quality, and audio devices are restored at startup.
- Text and checkbox changes are saved after a short debounce; starting a broadcast and closing the program also force a save.
- Added temporary-file and backup recovery so an interrupted write does not discard the previous valid settings file.
- Invalid settings files are reported and left untouched while the application starts with defaults.
- Added `rtmp://a.rtmp.youtube.com/live2` as the default editable YouTube server.
- Added a side-project `.gitignore` entry so the credentials-bearing settings file is not accidentally committed.

## 0.1.2

- Added optional **2K / 1440p60** and **4K / 2160p60** YouTube output toggles.
- Both high-resolution toggles are off by default and mutually exclusive.
- Kept the original 1080p60/6000 kbps one-encode tee pipeline unchanged as the default.
- Added 24,000 kbps H.264 level 5.1 output for YouTube 2K60.
- Added 35,000 kbps H.264 level 5.2 output for YouTube 4K60.
- When Twitch and high-resolution YouTube are enabled together, one capture is split into a 1080p60 Twitch encode and a separate 2K60/4K60 YouTube encode.
- Added independent FIFO recovery queues for the two service-specific high-resolution outputs.
- Prevented 2K/4K mode from starting without YouTube enabled.
- Added UI summaries showing the active resolution, bitrate, and whether one or two encoders will be used.
- Added model tests for default 1080p, YouTube-only 2K, dual-service 4K, and unsupported Twitch-only high-resolution selection.

## 0.1.1

- Added native Windows Unicode clipboard support to every text input.
- `Ctrl+C`, `Ctrl+X`, `Ctrl+V`, and `Ctrl+A` now work with text copied from or to other applications.
- Added short clipboard-open retries so another process briefly holding the clipboard does not randomly lose a paste.

## 0.1.0

- Initial focused 1080p60 Twitch and YouTube broadcaster milestone.
