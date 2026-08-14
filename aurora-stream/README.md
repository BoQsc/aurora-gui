# Aurora Stream 0.60.0

Aurora Stream is a separate side project inside the Aurora Cut archive. It does **not** import Aurora Cut's editor, timeline, preview, model, or export code. Its only shared component is the vendored Aurora-D graphics and GUI library at:

```text
../vendor/aurora-d-0.4.5/source
```

## Unreleased desktop-audio reliability fixes

The live Windows desktop-audio helper now runs in the MMCSS `Audio` class, preserves samples across scheduler stalls shorter than 100 ms, and gives FFmpeg substantially larger localhost RTP receive and reorder queues. Older settings with an empty desktop-audio endpoint now select the active Windows default after enumeration; an explicit **Disabled** selection remains disabled.

For a non-interactive transport stress check that opens no window and plays no sound, run:

```text
python tests/run-quality-diagnostic.py --loaded-audio
```

This complements the audible real-WASAPI waveform control by running the live desktop-capture, NVENC, AAC, FIFO, and timestamped RTP receiver paths against Aurora Stream's internal synthetic sender.

## 0.4.9 deterministic quality diagnostic

Version 0.4.9 adds a separate one-click quality harness without changing the live streaming path. Run:

```text
RUN-QUALITY-DIAGNOSTIC.bat
```

The harness opens a synchronized full-screen 1920×1080p60 test card through FFplay. The card contains continuous frame-by-frame motion, a steady 997 Hz tone, and simultaneous one-second video/audio markers. It then exercises synthetic encoding, the current Desktop Duplication path, lower-overhead BGRA candidates, the D3D11-direct single-output path, the default simultaneous Twitch 1080p plus YouTube 1440p workload, multiple RTP audio-resampling policies, live-style FIFO output, a 720p60 headroom control, an audio-only control, and a repeated best-path run.

Every output is decoded and measured rather than trusted from nominal FFmpeg FPS. The report includes exact hashes plus visually near-identical adjacent images, effective unique-image FPS, duplicate-run length, expected dimensions, timestamp cadence, decoded audio dropout windows, sine-phase discontinuities, MMCSS state, helper queue/pacing losses, A/V offset/jitter/drift, CPU/RAM/GPU use, FFmpeg queue warnings, and strict pass/fail thresholds. A path is recommended only after the same 1080p candidate passes both its original and repeated run.

The complete result is written to one file:

```text
aurora-stream-quality-diagnostic.txt
```

No stream key is read and no public network destination is contacted. Local phase files remain under `quality-diagnostic-artifacts` for manual playback when needed.

## 0.4.8 Windows RTP handle-inheritance correction

The 0.4.6 startup log showed that FFmpeg still failed before opening the SDP input:

```text
[udp] bind failed: Error number -10048 occurred
```

The helper had correctly bound source port 51036, while FFmpeg was trying to own RTP/RTCP 51034/51035. The remaining owner was the reservation socket duplicated into the child helper when it was spawned. Closing the parent copy therefore did not release the Windows UDP endpoint.

Version 0.4.8 marks both reservation handles non-inheritable before creating the helper. It also performs a runtime proof instead of trusting the flag: once the helper is ready, Aurora Stream closes and immediately reacquires the same RTP/RTCP pair. A successful reacquire proves no duplicate child handle remains. The refreshed reservations stay bound until immediately before FFmpeg launch.

A failed proof aborts locally with a precise `DESKTOP AUDIO PORT HANDOFF FAILURE` entry in `aurora-stream-startup.log`; FFmpeg is not launched into another known `-10048` failure.

## 0.4.6 live RTMP/TLS isolation correction

The 0.4.5 live startup log exposed a boundary that the local FLV tests did not exercise. FFmpeg launched with a direct RTMPS destination, printed only an unrelated encoder-option warning, and produced no `frame` or `out_time` progress before the 12-second deadline. The audio helper continued sending timestamped RTP silence, so the input process was alive. A local direct FLV file had never tested TCP, TLS, or the RTMP handshake.

A direct RTMP/RTMPS muxer opens the network destination synchronously before FFmpeg enters its normal capture/encode loop. A slow or stalled handshake can therefore make healthy video and audio inputs appear dead. Version 0.4.6 isolates **every live network destination** behind FFmpeg's bounded FIFO muxer:

```text
Isolated helper-first WASAPI capture
→ bounded 20 ms RTP sample-clock transport
→ FFmpeg Desktop Duplication CPU compatibility path
→ NVENC + AAC
→ bounded FIFO output worker per Twitch/YouTube destination
→ RTMP/RTMPS network connection
```

The output queue is limited to 1200 packets. It retries failed destinations and restarts from a keyframe after recovery, but it does not drop arbitrary packets into a live destination. If the queue fills because the encoder, computer, or upload path cannot keep up, FFmpeg back-pressures and Aurora Stream stops the attempt with a live-output stall message instead of feeding Twitch a damaged stream that can turn into a black buffering player. Local pacing diagnostics still write direct FLV files because no network handshake exists there.

A new localhost-only test deliberately accepts TCP but withholds the RTMP handshake. It verifies that direct RTMP emits no frame progress while the FIFO-isolated encoder continues. This reproduces the exact startup class without using Twitch, YouTube, a stream key, or the public network.

Audio-helper readiness is now split into two states. `transport-ready` means the helper initialized WASAPI, bound its RTP source, and can keep FFmpeg alive with silence. The helper publishes `capturing` once the first real WASAPI packet arrives. `aurora-stream-startup.log` records that transition, or records a clear notice when the selected endpoint has not produced packets yet.

The 12-second encoder startup deadline remains. With FIFO isolation, it now measures capture/encode startup rather than an unrelated network handshake. Every live attempt continues to write one sanitized file beside the executable:

```text
aurora-stream-startup.log
```

It contains the selected capture/encoder/output path, every FFmpeg argument with stream keys replaced, FFmpeg stderr/progress, the exit code, timeout or exception reason, audio capture-state transitions, and final helper metrics.

## Historical 0.4.5 path selection

The 0.4.4 one-click Windows diagnostic established that helper-first real WASAPI/RTP is the correct local A/V order: its three repeated full A/V runs reached 58.000, 58.667, and 56.333 effective unique images/s with real packets and no RTP send failures. Receiver-first repeatedly emitted `100 buffers queued`. Version 0.4.5 correctly retained helper-first ordering and added bounded startup supervision, but it incorrectly treated successful **local-file** direct FLV tests as proof that direct **network** RTMP output was safe. Version 0.4.6 corrects only that live output boundary.

## 0.4.3 Windows RTP port-ownership correction

Version 0.4.2 could stop before streaming with two FFmpeg UDP bind failures and Windows socket error `-10048` (`WSAEADDRINUSE`). The helper was launched before FFmpeg and its unbound UDP sender could be auto-assigned the same recently released dynamic port that the SDP told FFmpeg to use as its RTP receiver. FFmpeg then could not bind its RTP/RTCP input.

Version 0.4.3 reserves an adjacent even/odd RTP and RTCP receiver pair and keeps both sockets bound while the isolated helper explicitly binds a distinct local source port. Only after the helper reports ready are the receiver reservations released immediately before FFmpeg starts. The SDP also declares the RTCP port explicitly. This removes Aurora Stream's self-collision while retaining the process-isolated 20 ms timestamped RTP architecture.

The UI now reports the reserved RTP/RTCP pair during startup, and helper shutdown metrics include the actual RTP source and destination ports.

## 0.4.2 process-isolated A/V redesign

Version 0.3.3 is rejected as a fix. Its three-phase Windows diagnostic produced:

```text
Phase A — FFmpeg synthetic audio:          53.601 unique images/s
Phase B — D-generated transport silence:  45.668 unique images/s
Phase C — claimed WASAPI ring path:        53.068 unique images/s
```

Phase B regressed by nearly eight unique images/s even though it opened no WASAPI endpoint. Phase C captured **zero** WASAPI packets, replaced 100% of its audio with silence, and recorded a 40.106 ms writer completion. It therefore was not a valid real-audio pass and proved that the 0.3.3 GUI-process raw-PCM sender architecture still disturbed capture.

Version 0.4.2 removes that architecture rather than applying another timestamp or resampler adjustment:

```text
Aurora Stream UI process
  └─ FFmpeg owns desktop video, encode, mux, and destinations

Isolated low-priority audio helper process
  └─ event-driven WASAPI shared loopback
     → preallocated bounded PCM queue
     → one absolute-clock 20 ms output interval
     → one nonblocking RTP L16/48000/2 datagram
     → SDP/RTP input with explicit 48 kHz sample timestamps
     → FFmpeg AAC/mux
```

There is no desktop-audio pipe, raw PCM UDP input, GUI-process audio pacing thread, or `-use_wallclock_as_timestamps` on desktop audio. A late helper interval advances the RTP sample timestamp and re-anchors the next deadline instead of sending catch-up packets. Queue overflow drops old samples and recovers near real time. The helper continues sending silence when the selected endpoint is idle so FFmpeg never waits indefinitely for an audio stream.

The diagnostic now uses direct local FLV output rather than FFmpeg's reconnecting FIFO output wrapper. Phase B launches an isolated synthetic-RTP helper, and Phase C launches the real WASAPI helper. Phase C is marked failed when it captures zero packets; a silent substitute can no longer be presented as real-audio success.

The matching single-output Desktop Duplication/NVENC path is selected only when the monitor dimensions exactly match the source and destination **and** an exact startup probe proves that this FFmpeg build and NVIDIA driver can encode real `ddagrab` D3D11 frames with the live NVENC profile. When that probe fails, Aurora Stream selects the CPU readback/scaling compatibility path before the stream starts instead of launching an invalid direct path.

This source package is a redesign candidate, not a claim that the Windows/Twitch problem is fixed. The three local phases must pass three repeated moving-scene runs before live Twitch acceptance.

### 0.4.2 D3D11/NVENC startup correction

Version 0.4.1 could advertise `D3D11 direct hardware frames → NVENC` merely because the monitor and output dimensions matched. On the tested Windows/FFmpeg/NVIDIA combination, FFmpeg then failed while opening `h264_nvenc` and stopped with exit code -2. Version 0.4.2 probes the actual `ddagrab` hardware-frame input through the live NVENC profile first. A failed probe is not fatal: the stream uses `hwdownload,format=bgra` and the normal compatibility filter chain instead.

## Historical 0.3.2 video-path correction

The second completed Windows A/B diagnostic disproved the idea that event-driven WASAPI alone resolved the motion problem. With the same 15-second Twitch-equivalent output, the silent baseline produced about **58.1 unique images per second**, while enabling real desktop audio produced about **49.3 unique images per second**. Both files still carried 900 frames with normal 60/1 timestamps, so nominal output FPS was hiding repeated desktop images.

The exact command showed that Desktop Duplication already supplied D3D11 hardware frames, but Aurora Stream immediately downloaded every frame to system memory, passed it through software scaling twice for the normal Twitch-only 1080p case, converted it, and then uploaded it again for NVIDIA encoding. Even the silent baseline completed at only about 0.996x real time. Audio did not need to consume much bandwidth to expose this lack of processing headroom.

Version 0.3.2 therefore probes and prefers this path whenever one destination exactly matches the monitor and common source resolution:

```text
Desktop Duplication D3D11 frame
→ timestamp/cadence metadata only
→ NVIDIA NVENC
```

For a normal 1920×1080 monitor with source 1080p and Twitch-only output, the direct path has no GPU-to-CPU `hwdownload`, software scale, or re-upload before NVENC **only when the exact D3D11-to-NVENC startup probe passes**. A failed probe now selects the CPU compatibility path before FFmpeg starts. Scaling, multiple outputs, non-NVENC encoding, unknown capture dimensions, and dimension mismatches also select that compatibility path. The active path and probe result are printed in the UI diagnostics and in the A/V pacing diagnostic.

That historical release still used an in-process paced raw-audio transport. Version 0.4.2 replaces it with an isolated RTP helper carrying an explicit 48 kHz sample clock. Only the independently clocked DirectShow microphone retains FFmpeg wall-clock timestamping and bounded drift correction.

## New independent-output model

Aurora Stream now treats the source canvas, Twitch output, and YouTube output as three separate layers.

Default configuration:

```text
Common source canvas: 1920×1080 at 60 FPS
        ├─ Twitch: 1920×1080 at 60 FPS, 6000 kbps
        └─ YouTube: 1920×1080 at 60 FPS, 12000 kbps
```

Twitch and YouTube never share one encoded video stream. Each enabled destination receives its own scaling filter, H.264 encoder instance, bitrate control, AAC encoder, FLV muxer, and network output. Every enabled live destination receives its own bounded non-dropping FIFO recovery wrapper so network setup and reconnects cannot own the capture/encode thread, plus a live watchdog that fails visibly when sustained output stalls would make viewers buffer.

YouTube defaults to normal 1080p60 at 12 Mbps so a default broadcast uses roughly a quarter of the upload bandwidth; 1440p60 (24 Mbps) and 4K60 (35 Mbps) are selectable higher profiles. This means a 1080p source can remain normal 1080p60 for Twitch and, when a higher profile is selected, be upscaled to 1440p60 or 4K60 for YouTube. Upscaling does not invent genuine source detail, but it gives YouTube the requested higher-resolution ingest profile rather than forcing both platforms to use Twitch's constrained output.

## Windows desktop capture and cursor stability

Aurora Stream probes FFmpeg's **Desktop Duplication** source when the program starts. Desktop Duplication returns D3D11 hardware frames and captures the hardware cursor without using FFmpeg's older GDI cursor handling.

When FFmpeg cannot use a hardware H.264 encoder and falls back to CPU `libx264`, Aurora Stream uses the GDI compatibility capture path by default. That avoids the fragile Desktop Duplication readback path on CPU-only machines, where FFmpeg can report `AcquireNextFrame failed` and then continue sending audio while the video frame counter is frozen.

Desktop Duplication also loses its output when the display changes around you — **alt-tab to/from a fullscreen-exclusive application**, a resolution change, the lock screen, or a UAC prompt. Aurora Stream treats that loss as recoverable and automatically relaunches FFmpeg up to 3 times (the FIFO output muxer reconnects), so an alt-tab away and back no longer kills the stream. Only when the capture does not recover after those relaunches is the stream stopped with a clear "Desktop capture failed (did not recover after 3 relaunches)" message, and a manually pressed Stop during the recovery window is always respected. A watchdog also stops any run where encoded video frames stop advancing while output time continues.

For one matching NVENC destination, Aurora Stream keeps those frames on the GPU:

```text
Windows Desktop Duplication (D3D11)
→ cadence/timestamp normalization
→ NVIDIA NVENC
```

When scaling, multi-destination output, a non-NVIDIA encoder, unknown or mismatched capture dimensions, or another requirement needs software processing, Aurora Stream selects the compatibility path before launch:

```text
Windows Desktop Duplication (D3D11)
→ hwdownload to BGRA
→ common source/output scaling
→ encoder
```

The selected capture backend and active video path are shown beside the encoder in the status panel.

If the installed FFmpeg build or current Windows session cannot initialize Desktop Duplication, Aurora Stream falls back to `gdigrab` with mouse drawing disabled. That fallback continues streaming the screen but intentionally omits the cursor from the broadcast so it cannot make the real Windows pointer flicker or disappear.

Aurora Stream also disables Aurora's synchronized drag-pointer hiding because this broadcaster does not need a frame-synchronized custom drag cursor.

## Window / game capture

Settings → **CAPTURE SOURCE** lets you stream **only one game or app window** so
viewers never see the rest of your desktop. Choose **Entire desktop** to capture
everything (the default, unchanged behavior) or pick any visible titled window;
the list is re-enumerated every time the dropdown opens and includes a
**Refresh window list** item so games launched after startup appear immediately.
Each window is shown as `process.exe — Window Title`, and the selection is
saved in `aurora-stream-settings.json` (schema 6).

A captured window is streamed through FFmpeg's `gdigrab hwnd=` path at the same
60 FPS, scaled into the selected source canvas and each destination exactly like
the desktop capture, so all existing quality/bitrate/audio behavior is
unchanged. The status panel shows `Window capture (GDI) → CPU processing →
encoder` because window capture is a GDI path (the D3D11 zero-copy handoff
applies only to full-desktop Desktop Duplication). The **LIVE SOURCE CANVAS**
preview also switches to the selected window so what you see matches what
viewers see.

Notes:

- A window is captured as it appears on screen, so keep it visible and **not
  minimized**. A minimized window has a 0×0 client area that FFmpeg's `gdigrab`
  cannot capture: minimized windows are marked `(minimized — not capturable)`
  in the CAPTURE SOURCE list, Start refuses a minimized selection with a clear
  message, and if the captured window is minimized (or closed) **during** a
  stream, Aurora Stream stops it immediately ("Window capture stopped — the
  captured window was minimized/closed") instead of leaving viewers on a frozen
  last frame. The LIVE SOURCE CANVAS preview likewise keeps its last good frame
  while the selected window is minimized.
- The window handle is only valid in the Windows session it was chosen. A saved
  selection that is closed, or carried from an earlier session, is detected at
  Start and reported clearly instead of silently streaming the desktop.
- Borderless-windowed games work well. Exclusive-fullscreen games already cover
  the whole desktop, so window capture is not needed for them.

## Simplified server controls and native-style text menus

The editable Twitch and YouTube server URL fields are hidden on startup because the normal defaults rarely need to be changed. The top toolbar contains a compact **Settings** dropdown immediately before the source/output summary. Its checked **Unhide streaming servers** item reveals both server labels and fields; selecting it again conceals them without changing their saved values. Revealing the fields explicitly relays out the settings viewport and brings the Twitch server control into view.

Every server and stream-key text field provides **Cut**, **Copy**, **Paste**, and **Select all** from a right-click menu. Text-field menus open with their top-left corner at the actual pointer position, matching the placement expected from a normal input field instead of using Aurora's timeline-style upward anchor.

## Common source canvas

The source selection appears above both destination profiles as one dropdown:

- **1080p60 — default:** 1920×1080
- **1440p60 / 2K:** 2560×1440
- **2160p60 / 4K:** 3840×2160

When scaling is required, FFmpeg normalizes the captured Windows desktop into the selected shared source canvas and derives each destination from it. A single matching D3D11/NVENC destination bypasses pixel scaling entirely, and a software fallback no longer repeats a second scale when source and output resolutions already match.

The **LIVE SOURCE CANVAS** panel on the right is a real live recording preview: a background thread grabs the primary monitor in-app at ~30 FPS so you can see exactly what the stream is recording before and during a broadcast.

Examples:

- Source 1080p → Twitch 1080p + YouTube 1440p upscale
- Source 1440p → Twitch 1080p downscale + YouTube 1440p
- Source 4K → Twitch 1080p downscale + YouTube 1440p downscale
- Source 4K → Twitch 1080p downscale + YouTube 4K

## Twitch output

Twitch is deliberately fixed to its normal supported profile in this milestone:

- 1920×1080
- 60 FPS
- 6000 kbps CBR H.264
- High Profile, level 4.2
- Two-second keyframe interval
- Two B-frames
- AAC stereo, 48 kHz, 160 kbps

Twitch has its own encoder instance even when YouTube is enabled.

## YouTube output

YouTube defaults to:

- 1920×1080
- 60 FPS
- 12000 kbps H.264
- High Profile, level 4.2
- Two-second keyframe interval
- AAC stereo, 48 kHz, 160 kbps

The YouTube quality dropdown on the same row as **Stream to YouTube** offers **1080p60** (default), **1440p60 / 2K**, and **2160p60 / 4K**:

- 1440p60 / 2K: 2560×1440, 24000 kbps, High Profile level 5.1
- 2160p60 / 4K: 3840×2160, 35000 kbps, High Profile level 5.2

Twitch remains 1080p60 at 6000 kbps regardless of the YouTube selection.

## Simultaneous behavior

```text
Windows desktop + desktop audio + microphone
                    ↓
       common selected source canvas
                    ↓
          video and audio are split
          ├─ Twitch-specific scaling
          │  Twitch-specific H.264/AAC encode
          │  Twitch FIFO + RTMP/RTMPS output
          │
          └─ YouTube-specific scaling
             YouTube-specific H.264/AAC encode
             YouTube FIFO + RTMP/RTMPS output
```

Configured media targets, including each 160 kbps AAC track but excluding small protocol overhead:

- Twitch only: 6.16 Mbps
- YouTube 1080p60 only: 12.16 Mbps
- Twitch + YouTube 1080p60: 18.32 Mbps
- YouTube 1440p60 only: 24.16 Mbps
- Twitch + YouTube 4K60: 41.32 Mbps

The video sent to both services is already H.264-compressed. Desktop PCM is raw only inside the local WASAPI-to-FFmpeg bridge and is converted to 160 kbps AAC before upload. A Windows or FFmpeg metric near hundreds of Mbps therefore describes an internal capture/processing path or a different counter, not the configured Twitch network output.

The selected encoder backend must support the number and resolution of simultaneous encoding sessions. If both destinations are active, Aurora Stream intentionally creates two encoder instances.

## A/V clock and smoothness

The desktop capture, desktop-audio bridge, and microphone are independent live clocks. Aurora Stream now normalizes them before encoding instead of allowing the arrival rhythm of raw PCM packets to become FFmpeg's effective stream clock:

```text
Desktop video → Desktop Duplication D3D11 clock → NVENC when directly compatible
Desktop audio → isolated helper → 20 ms RTP packets → explicit 48 kHz sample timestamps
Microphone    → DirectShow wall clock → bounded drift correction → 48 kHz timeline
```

The isolated helper always advances a continuous audio timeline, including silence when no endpoint packet is available. FLV output uses `max_interleave_delta=0`; local RTP validation showed the prior 100 ms limit could reject AAC's initial encoder-delay packet as improperly interleaved. Because the helper never intentionally stops producing audio, FFmpeg can wait for both streams without accumulating an unbounded delayed-audio burst.

The live metric row now shows:

- **FPS** and **Speed** for total processing performance.
- **Duplicated** and **Dropped** video frames for capture/encoder pressure.
- **Output time** for verifying that the media clock advances at approximately wall time.

Healthy streaming should remain close to `60 FPS`, `1.0x`, and zero or nearly zero duplicated/dropped frames. A sustained speed below approximately `0.95x` indicates genuine processing overload; growing duplicate/drop counts with speed near `1.0x` indicates capture timing or frame delivery trouble.

The 0.2.9 diagnostic first showed that nominal 60 FPS could conceal repeated source images. Version 0.3.2 removed the demonstrated 281 ms named-pipe backpressure, but 0.3.3 still regressed in its transport-only Phase B and did not capture any real Phase C audio packets. Version 0.4.2 therefore isolates all desktop-audio capture, buffering, timing, silence, and RTP delivery in a separate process. The three-phase local diagnostic and decoded unique-image rate—not aggregate FFmpeg FPS—remain the acceptance test.

## Saved settings

Every field and toggle is automatically restored from the settings file. By
default Aurora Stream keeps it in the current user's per-user application-data
folder, so an installed copy does not need write access next to the executable:

```text
Windows: %APPDATA%\Aurora Stream\aurora-stream-settings.json
macOS:   ~/Library/Application Support/Aurora Stream/aurora-stream-settings.json
Linux:   $XDG_CONFIG_HOME/Aurora Stream/aurora-stream-settings.json
```

Running with the `--portable-config` argument instead keeps the settings file
beside the folder Aurora Stream is launched from (the historical portable
behavior):

```text
aurora-stream-settings.json
```

The settings file includes:

- Common source resolution
- Twitch enabled state, server, stream key, and output profile
- YouTube enabled state, server, stream key, and 1440p/4K selection
- Desktop-audio device
- Microphone device

Version 0.3.0 continues using settings schema 3. Existing destination, key, quality, and microphone settings migrate automatically. The old desktop-audio value is intentionally cleared once because versions through 0.1.9 mistakenly stored a DirectShow capture/microphone identifier in that field.

- Existing destination states, servers, keys, and microphone selection are retained
- The obsolete pre-0.2 desktop-audio selection is cleared and must be selected once from the new playback-endpoint dropdown
- Common source becomes 1080p60
- Twitch becomes 1080p60
- YouTube becomes 1080p60 by default
- A previously selected 4K mode remains YouTube 4K60

Changes save automatically after a short pause, immediately before streaming, and when the program closes. The file contains stream keys in plain text. Keep it private and do not commit or share it.

## Destination setup

Aurora Stream places a quick browser shortcut beside each destination heading:

- **Open Twitch settings** opens `https://dashboard.twitch.tv/settings/stream`
- **Open YouTube Live** opens `https://studio.youtube.com/channel/UC/livestreaming`

The operating system opens each address in the current default browser. These shortcuts do not read, retrieve, or modify stream keys.

Both stream-key fields are rendered as password inputs, so the actual key is not visible in the normal interface. A small **paste** button beside each field replaces its entire value from the Windows clipboard. Standard keyboard clipboard shortcuts continue to work.

Every server and stream-key input also has a standard right-click menu with **Cut**, **Copy**, **Paste**, and **Select all**. The menu uses the native Windows clipboard through Aurora Stream's text-field wrapper; stream keys remain masked while editing.

A destination cannot be enabled while its stream key is empty. Typing or pasting a non-empty key automatically checks the matching **Stream to** option; deleting the key unchecks and disables it. Once a key exists, the destination can still be manually unchecked to keep that key saved while streaming only to the other service; editing the key checks it again.

Masking is only a UI privacy measure. `aurora-stream-settings.json` still contains the real stream keys in plain text so they can autoload at startup.

### Twitch

Default server:

```text
rtmps://ingest.global-contribute.live-video.net/app
```

Paste only the Twitch stream key into the key field.

### YouTube

Default editable server:

```text
rtmp://a.rtmp.youtube.com/live2
```

Paste the YouTube stream key separately. The server can be replaced with the RTMPS URL shown by YouTube Live Control Room.

## Audio

Aurora Stream now uses two genuinely different Windows audio backends:

```text
Desktop audio dropdown → Windows Core Audio render endpoints → WASAPI loopback
Microphone dropdown    → FFmpeg DirectShow capture endpoints
```

The **Desktop audio (Windows WASAPI loopback)** dropdown lists active playback endpoints such as Speakers and Headphones. Selecting one captures the sound currently being rendered through that endpoint. Aurora Stream launches an isolated helper process, opens the render endpoint through event-driven WASAPI shared loopback, and sends timestamped 48 kHz stereo PCM to FFmpeg as private localhost RTP described by SDP.

The **Microphone (FFmpeg DirectShow)** dropdown separately lists recording/capture inputs reported by FFmpeg. Duplicate visible names remain distinct because Aurora Stream stores FFmpeg's alternative DirectShow identifier.

Both dropdowns start with **Disabled** and can be used independently:
- Both disabled: silent stereo AAC is generated so the stream still has a valid audio track.
- Desktop only: game/system playback from the selected Speakers or Headphones endpoint.
- Microphone only: the selected DirectShow recording input.
- Both enabled: Aurora Stream resamples and mixes both inputs to 48 kHz stereo before encoding.

The helper uses event-driven shared-mode loopback and one preallocated 200 ms PCM queue. One helper thread waits on the Windows audio event until the next absolute 20 ms output deadline, drains every available endpoint packet, and sends exactly one RTP packet for that interval. Missing frames remain silent; overflow and late scheduling discard stale audio rather than blocking or burst-delivering it. Only the independently clocked DirectShow microphone uses FFmpeg wall-clock timestamps.

Use **Refresh audio devices** after connecting, removing, or changing hardware. The selected Windows render-endpoint ID and DirectShow microphone ID are saved in `aurora-stream-settings.json`. A temporarily missing endpoint remains visible as **Saved but unavailable** with its cached name (a persistent device-ID → name cache is saved in the settings file, so it survives restarts). Aurora Stream also registers with Windows Core Audio (`IMMNotificationClient`) and automatically rescans both lists whenever audio devices are added, removed, or change state, so the selectors stay current while the program is running.

### Audio-device diagnostic

Run:

```bat
CHECK-AUDIO-DEVICES.bat
```

It writes `audio-device-diagnostic.txt` and compares FFmpeg DirectShow capture devices with Windows playback and recording devices. The report contains no stream keys and does not install or change anything. `LIST-AUDIO-DEVICES.bat` remains a raw FFmpeg diagnostic fallback.

## Encoder selection

Aurora Stream probes encoders in this order:

1. NVIDIA NVENC
2. Intel Quick Sync
3. AMD AMF
4. CPU libx264

Dual output is intended for hardware encoding. The exact-match single-output NVENC path keeps Desktop Duplication frames on the GPU. Existing common-canvas scaling, independent destination scaling, multi-output, and non-NVENC paths still download BGRA frames for software filters, so high source resolutions can increase CPU and memory-bandwidth usage even when H.264 encoding itself runs on hardware.

## Installation dependencies

See `installation.txt` for the required FFmpeg Winget command and the official D language download page. Aurora Stream does not automatically install or resolve either dependency.

## Run on Windows

From the `aurora-stream` folder:

```bat
BUILD-WINDOWS.bat
```

Later launches:

```bat
RUN-WINDOWS.bat
```

Aurora UI software-rendering fallback:

```bat
RUN-WINDOWS-SOFTWARE.bat
```

Required commands:

```bat
dmd --version
dub --version
ffmpeg -version
```

Those ordinary local builds need only DMD and DUB. To make a standalone
distributable executable, use `dub build --build=portable-release`. This
optional build needs the MSVC x64/x86 tools and Universal CRT SDK individual
components, not the complete **Desktop development with C++** workload. The
resulting executable does not need those tools or the Visual C++ Redistributable
at runtime.

## Not implemented yet

- Editable Twitch output resolutions beyond the locked normal 1080p60 profile
- Twitch Enhanced Broadcasting or Twitch 2K output (intentionally out of scope)
- Screen/window/game, camera, browser sources, and per-source position/scale/crop editing
- Zero-copy scaling, multi-destination composition, and Windows Graphics Capture path
- Native Windows microphone capture without FFmpeg DirectShow
- Per-destination encoder backend selection
- OAuth or automatic retrieval of stream keys
- Local recording

## Specifications used

See [`SOURCES.md`](SOURCES.md) for the direct Twitch, YouTube, FFmpeg, and D documentation used for this implementation.

## A/V pacing diagnostic

Repeated live testing showed that enabling a real audio input can make motion less smooth even when FFmpeg reports approximately 60 FPS, near-1.0x speed, and no output-level duplicated or dropped frames. The local files can still contain repeated desktop images, so aggregate progress counters are not accepted as proof of motion cadence.

Run:

```bat
CHECK-STREAM-PACING.bat
```

The same test is available from **Settings → Run A/V pacing diagnostic** while streaming is stopped. It never contacts Twitch or YouTube and does not print or transmit stream keys.

The diagnostic records three 15-second Twitch-equivalent local FLV files while the user keeps the same moving game view visible:

1. **Phase A — FFmpeg synthetic audio:** `anullsrc`; no Aurora audio helper.
2. **Phase B — isolated RTP silence helper:** a separate low-priority process sends one timestamped 20 ms L16 packet per interval; no WASAPI endpoint is opened.
3. **Phase C — WASAPI through isolated RTP helper:** the same helper process captures the selected render endpoint into its bounded queue and sends the same RTP format.

Interpretation:

```text
A smooth, B uneven → helper-process scheduling or FFmpeg RTP ingestion
A and B smooth, C uneven → WASAPI capture, endpoint, conversion, or driver
Any Phase C with zero captured packets → invalid real-audio test
All smooth locally → proceed to a separate RTMP/Twitch test
```

All phases use the same desktop-capture backend, source canvas, Twitch 1080p60 output, H.264 encoder, 6000 kbps CBR profile, AAC encoder, and direct FLV mux policy. The diagnostic deliberately omits the reconnecting network FIFO wrapper so local timing failures cannot be hidden behind an additional queue.

The generated report includes:

- Per-frame display timestamps and interval distribution.
- Exact consecutive decoded-image duplicates, duplicate ratio, longest run, and effective unique-image FPS.
- Final/minimum/average encode speed and output duplicated/dropped counters.
- AAC packet gaps and overlaps.
- FFmpeg `buffers queued` warning count.
- Helper RTP packets, captured/queued frames, silence frames, maximum queue depth, overflow drops, stale drops, pacing skips, event wakeups/timeouts, discontinuities, send failures, output intervals, maximum capture duration, and maximum RTP send duration.

Generated files are placed in:

```text
stream-pacing-diagnostic/
```

Run the complete A/B/C diagnostic at least three times with the same continuously moving scene. Acceptance requires Phase C to remain within two unique images/s of the comparable baseline, no FFmpeg queue warning, no capture operation reaching 16.7 ms, no long stall followed by catch-up processing, and audible synchronized output. Twitch is tested only after local files pass.
