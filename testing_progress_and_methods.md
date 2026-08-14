# Testing Progress and Methods (Aurora Cut)

## TitleBar: cursor no longer changes to "move" while dragging the window (2026-08-14)

User: dragging the window by the custom titlebar should not change the cursor.

Root cause in `vendor/aurora-d-0.4.5/source/aurora/widgets/titlebar.d`: when a
real drag starts (`onMouseMove`, movement threshold crossed) the bar called
`setCursor(CursorKind.move)`, so the pointer flipped to the move cursor for the
whole drag. Dragging a window is not a resize/move cursor situation — the
pointer should stay an arrow (drag only starts from the title/icon area, which
already uses the arrow cursor, so the arrow is left untouched).

What changed:
- Removed the `setCursor(CursorKind.move)` call at drag start; the drag now
  leaves the existing arrow cursor in place.
- The comment in `onMouseMove`'s `_dragging` branch now says "keep the cursor
  and the hover visuals frozen" (the move-cursor rationale is gone).
- `setDraggable(false)` and `onMouseUp` still reset to `CursorKind.arrow`
  (unchanged — correct and harmless).

How to verify:
- `dub test` in `vendor/aurora-d-0.4.5` → all unit tests pass (the drag
  self-move unittest exercises the exact code path that used to set the move
  cursor).
- `dub build --config=application` in `aurora-stream` links.
- Manual: drag the titlebar; the cursor must stay the arrow and never flip to
  the move cursor. Caption-button hover (hand cursor) is unchanged.

## Single-exe PE icon (Explorer/taskbar) via post-link .rsrc patch (2026-08-13)

DMD's bundled lld-link is 9.0.0 (2019): it rejects `.res` files ("unknown file
type") and CRASHES on hand-built COFF resource objects (two-section
.rsrc$01/.rsrc$02 + @feat.00 + $R symbols + ADDR32NB relocations were emitted
correctly per llvm-cvtres, but LLD 9 still segfaults). So the icon is added
POST-LINK instead:

- `scripts/patch-pe-icon.py icon.ico exe [out]` appends a `.rsrc` section to
  the linked exe and updates the PE headers (NumberOfSections, section table,
  SizeOfImage, resource data directory). Resource data-entry RVAs are computed
  from the new section RVA, so no linker relocation support is needed.
- `scripts/build-portable-windows.py --single-exe` runs it after `dub build`
  for aurora-cut/aurora-stream.
- Resource tree layout is identical to llvm-cvtres (BFS, RT_ICON ids 1..N +
  RT_GROUP_ICON id 1, language 0x0409).

How to verify the icon is truly embedded (not just present in the directory):
`scripts/../temp tool` walk the .rsrc section and confirm every
IMAGE_RESOURCE_DATA_ENTRY.OffsetToData resolves to a real RVA inside .rsrc and
the DataSize matches the .ico image sizes (803/2449/4664/7566/24293/82423 +
90-byte group). DataRVAs left as section-relative offsets (the earlier bug)
means Windows cannot read the icon even though the directory lists RT_ICON.

Explorer icon cache: after re-downloading a fixed exe at the same path, Windows
may keep showing the cached default icon; rename the file or clear the icon
cache to confirm.

## True single portable exe with embedded ffmpeg (2026-08-13)

Goal: ship `aurora-cut.exe` / `aurora-stream.exe` as one self-contained file
that needs no installed ffmpeg.

Mechanism (both apps, mirrored):
- New module `aurorastream/auroracut.ffmpegbundle`: under `version
  (BundledFfmpeg)` it embeds `ffmpeg.exe` + `ffprobe.exe` via D string imports
  (`cast(ubyte[]) import("ffmpeg.exe")`), resolved through
  `stringImportPaths: ["embedded"]` in dub.json.
- At startup (`main()` in app.d / app_titlebar.d) `enableBundledFfmpeg()`
  extracts the two exes into `%TEMP%\Aurora-Stream-ffmpeg` (cut:
  `Aurora-Cut-ffmpeg`) — size-cached so it runs once — and prepends that dir to
  the process `PATH`. Every bare `"ffmpeg"`/`"ffprobe"` call (media.d,
  exporter.d, playback.d, preview.d, ytdlp.d, broadcast.d, ...) then resolves
  to the bundle with zero call-site changes. Dev builds (no BundledFfmpeg)
  fall back to system PATH.

Build:
- `dub build --build=portable-single-exe` (buildType adds
  `versions: [BundledFfmpeg]`, same `-mscrtlib=libcmt` static-CRT flags as
  portable-release).
- CI: `portable-windows.yml` downloads the latest successful
  `ffmpeg-minimal-win64` artifact (`gh run download`), copies ffmpeg.exe +
  ffprobe.exe into `aurora-stream/embedded/` and `aurora-cut/embedded/`, then
  runs `scripts/build-portable-windows.py --single-exe`.
- `embedded/` is gitignored (only `.gitkeep` is committed).

How to verify the mechanism (no GUI):
1. Drop placeholder (or real) `ffmpeg.exe`/`ffprobe.exe` into `embedded/`.
2. `dub build --build=portable-single-exe` in the app dir; confirm the exe
   links (local link needs MSVC's libcmt.lib — present on CI windows-latest;
   locally drop `-mscrtlib=libcmt` temporarily to link with DMD's default CRT).
3. Standalone: compile `ffmpegbundle.d` with `-version=BundledFfmpeg
   -Jembedded`, run a main that calls `enableBundledFfmpeg()`, assert the files
   landed in `%TEMP%\<App>-ffmpeg` with correct sizes and PATH is prepended;
   run twice to prove idempotency.

How to verify the REAL single exe (on a clean machine, no ffmpeg installed):
1. Build via the portable workflow, or locally with the real artifact binaries
   in `embedded/`.
2. Delete any system ffmpeg from PATH; launch the single exe.
3. aurora-stream: RUN-ALL-DIAGNOSTICS / a local .flv output stream; confirm
   `%TEMP%\Aurora-Stream-ffmpeg\ffmpeg.exe` appears on first run.
4. aurora-cut: import + export MP4/MP3; confirm `%TEMP%\Aurora-Cut-ffmpeg`.

## Background playback prewarm on playhead changes (2026-08-13)

User: "after playhead changes we immediately try to start loading in the
background instead of having bad experience on actual playback." Goal: pressing
Play feels immediate because the exact stream was already decoded in the
background while paused.

How it works in `source/auroracut/editor.d`:
- `updatePlaybackPrewarm` (called each onTick): when paused (`_playbackKind ==
  none`, or a paused sequence session) and no busy background job, after the
  playhead settles for `playbackPrewarmDelaySeconds` (0.10 s) it calls
  `startPlaybackPrewarm`.
- `startPlaybackPrewarm` resolves the same context Play would choose
  (direct sequence -> static visual -> live composition, mirroring
  `previewTimeline`), starts `_videoStream` + a PAUSED `_audioPlayer`, and
  stores opaque signatures:
  - `directVideoSignature(path, mediaPosition, duration, w, h, fps, opts,
    mediaOffset)` for direct source playback.
  - `"live\x1f" ~ join(compositeStreamArguments(...), "\x1f")` for the live
    compositor (the args embed position/model/decode/fps).
  - `"static"` for still-image visuals.
- On Play: `startPlayback` first evaluates `prewarmMatchesPlayback(...)` from
  the incoming arguments and skips its `stopPlayback(false)` teardown when the
  prewarm matches (otherwise the teardown kills the warm streams). Then
  `startPlaybackStreams` calls `adoptPlaybackVideoPrewarm()` (signature vs
  `buildCurrentVideoSignature()`, plus the stream must still be running) and,
  in the first-frame handler, `startPlaybackAudio` adopts the matching paused
  audio (calling `PcmAudioPlayer.reanchorClock()` first so the headless
  fallback clock ignores buffering time). No FFmpeg process is spawned on Play.
- Lifecycle: `notePlaybackPrewarmDirty` (from `playheadChanged`) and the
  onTick revision/position checks cancel/restart on any edit or playhead move;
  `cancelPlaybackPrewarm` is called from pause/seek/stop; an idle prewarm is
  released after `playbackPrewarmIdleSeconds` (45 s).

How to verify (headless, deterministic):
- `tests/editor_smoke.d` prewarm block: set the playhead while paused, wait for
  `playbackPrewarmActiveForTesting()` and for the video+audio process counters
  to increase and video frames to buffer, then press Play and assert
  `videoStatsForTesting().processesStarted` and
  `audioStatsForTesting().processesStarted` are UNCHANGED (adoption) and the
  transport reaches the running state.
- The block relies on the prewarm enqueuing the request immediately but
  spawning FFmpeg on the worker thread, so it waits (not asserts) for the
  process counters to move.
- Full gate: `dub test` (33 modules) + the editor/playback/layout/gpu/model/
  export smoke tests. Run `tests/editor_smoke.d` 2-3x on a loaded host to
  confirm the prewarm timing is not flaky.

## "Video decoder ended before the next frame was ready" no longer halts playback (2026-08-13)

User: this message should never appear. It was raised by `editor.d` onTick
whenever `_playbackVideoWaiting` (the transport had paused audio to let a
lagging decoder catch up) was true at the moment the stream reported
`finished()`. But reaching the last frame of the requested range is normal
completion, so a clean EOF while buffering was misreported as a decoder
failure and playback was stopped mid-range.

What changed:
- `playback.d`: `VideoFrameStream.hasReadyFrames()` — distinguishes "finished
  but tail frames still queued" from "nothing left to display".
- `editor.d` `displayedVideoBehindPlaybackClock()`: false once the stream is
  finished with no ready frames (a finished decoder can't catch up, so the
  transport must not re-enter buffering; also breaks a resume→re-pause loop).
- `editor.d` halt block: clean EOF while waiting resumes the transport
  (`resumeAfterVideoBuffer()`) or lets the waiting branch drain the tail;
  genuine FFmpeg errors surface as a status message only. The audio-start
  failure halt is unchanged.

How to verify (deterministic, no decode-speed dependence):
- `tests/editor_smoke.d` direct-playback regression block: after playback is
  active, wait until `videoStreamFinishedForTesting()` (decoder reached the end
  of its range during normal playback — no halt while not waiting), then force
  the exact production buffering state with `simulateVideoBufferWaitForTesting()`
  (which calls the real `waitForVideoBuffer()`), tick, and run to completion.
  Asserts `playbackPositionForTesting() >= playbackEndForTesting() - 0.03` and
  `statusTextForTesting()` never contains "Video decoder ended before the next
  frame was ready". The block fails on the pre-fix code (halt at
  `tests/editor_smoke.d` ~line 1176) and passes with the fix.
- Full gate: `dub test` (33 modules), `tests/editor_smoke.d`,
  `tests/playback_stress.d`, `tests/playback_seek_resilience_smoke.d`,
  `tests/static_sequence_playback_smoke.d`, `tests/playback_proxy_smoke.d`,
  `tests/layout_smoke.d`, `tests/gpu_decode_args_smoke.d`,
  `tests/model_smoke.d`, `tests/export_smoke.d`.
- `tests/synced_playback_preroll_smoke.d` fails at line 112 on the base commit
  too (pre-existing): it asserts `setPlayhead` synchronously increments the
  preview-request counter, but previews are debounced through
  `scheduleTimelineFrame`/`dispatchPendingPreview`. Not part of any verify
  script; repair (assert after a tick / wire frame-step to
  `dispatchPendingPreviewNow`) or remove.

Manual verification in the GUI (this host is 4 logical CPUs, often ~100%
loaded): play a short single-clip timeline to its end, and play a live
multi-clip timeline with audio while the machine is under load; the status must
never show the decoder-end failure and playback must complete at the sequence
end.

## Timeline playback performance / immediacy — analysis (2026-08-13)

End-to-end review of the playback pipeline. Two processes can exist per Play:
video (`VideoFrameStream`) and audio (`PcmAudioPlayer`), both spawning fresh
FFmpeg per play/seek. Live timelines use the compositor graph
(`compositeStreamArguments`) at a fixed 16:9 preset (e.g. 1280x720 in
Responsive) that is then force-scaled to the decode size; paused/scrub frames
use `previewCompositionPreset` at the sequence aspect. This is both a
correctness mismatch (non-16:9 stretched during playback) and a perf waste
(compositor runs at 720p then downscales).

Key measurement method (noisy machine, so use code reasoning + min-of-N):
- Raw decode/filter throughput is measured with ffmpeg writing to `NUL`
  (`-RedirectStandardOutput NUL` in PowerShell) to remove disk I/O; this host
  bounces 1.0-2.3 s for identical 1 s 720p workloads when the box is ~100%
  loaded (4 logical CPUs), so single runs are not trustworthy — take minimums
  and reason from the code.
- First-frame latency is the real "immediacy" metric: ffmpeg spawn + graph
  build + input open/seek + preroll wait (0.055 s direct / 0.090 s live) before
  `_playbackAwaitingFirstFrame` clears (`editor.d` onTick).

How to verify each fix later:
1. Live-vs-pause aspect parity: build a square or portrait sequence
   (e.g. 720x720 composition), press Play and Pause; assert both pause-frame
   and playback-frame use the same aspect (pixel probe / Playwright
   screenshots; compare against the sequence-aspect decode). Current code
   stretches playback for non-16:9.
2. Compositor cost: with the preset changed to the decode size, confirm the
   `[vout]scale=` tail is elided (`outputWidth==preset.width`) and
   `Process Explorer`/ffmpeg CPU for a 3-clip 720p timeline drops vs the
   1280x720-then-downscale baseline at the same decode size.
3. Range-restricted inputs: `collectInputs` should include only clips that
   intersect `[rangeStart, rangeEnd]`; verify a 10-clip timeline playing a
   2 s range starts ~immediately and spawns the same process count.
4. Audio concurrency: video + audio ffmpeg should both spawn at Play
   (`PcmAudioPlayer` paused via `startPaused=true`); verify no A/V desync and
   faster press-Play->sound.
5. Adaptive mode: with frames being dropped (`PlaybackWorkerStats.framesDropped`
   from `_videoStream.stats()`), decode height should step down and later step
   back up; verify `playback_stress.d` still passes.
6. Regression gate: `tests/playback_stress.d` (rapid seeks must coalesce,
   `processesStarted < requests/3`), `tests/synced_playback_preroll_smoke.d`,
   `tests/playback_seek_resilience_smoke.d`, `tests/static_sequence_playback_smoke.d`
   all pass.

## Timeline snapping: playhead, In/Out markers, and cross-track clip edges (2026-08-13)

Timeline items now snap to the playhead (already present), the work-area **In**
(blue) / **Out** (orange) markers, and clip edges on **every** track, plus the
sequence start. Both a clip's start edge and its tail (start + duration) can
snap, and edge-resize previews snap too.

Implementation notes in `source/auroracut/timeline.d`:
- `snappedEdge` / `snappedStart` now take an `out double guide` parameter that
  records the winning marker time (NaN when unsnapped). The `consider` closure
  for start-snaps knows whether the start edge or the tail edge aligned
  (`endEdge`), so the guide points at the marker itself, e.g. a tail snapping
  to the playhead still guides at the playhead.
- `forEachNearbyClipMarker(desired, duration, excludedClipId, visit)` visits
  clip start/end markers from every track using a small window around
  `lowerBoundByStart` (2 binary searches per track, ~7 clips), so 20k-clip
  tracks stay cheap during drags.
- `drawSnapGuide` paints a 1px bright-white rule at `_snapGuideTime` between
  the ruler and the drag overlays. The guide clears on mouse-up, Escape, and
  `clearGhost`. Note: at the playhead's exact X the composited red playhead
  layer is painted above the base guide, so the guide is visually covered there
  (the red line is the cue).

How to verify (headless, no GUI click needed):
- `tests/editor_smoke.d` contains four focused blocks:
  1. In/Out marker snapping: start edge, tail edge, and edge-resize preview.
  2. Cross-track clip-edge snapping: start, tail, and edge-resize preview.
  3. Snap-guide lifecycle: a simulated clip drag snaps to the In marker at
     3.0s, `snapGuideTimeForTesting()` equals 3.0, the rendered pixel at that X
     is bright (>120 per channel), and mouse-up resets it to NaN.
- Compile/run exactly as described in "Run the headless editor smoke test"
  below. Pass = `Aurora Cut multi-track editor smoke test passed.`

## Timeline rows painted over the ruler while scrolling (2026-08-13)

Follow-up to the draggable scrollbar: after making the scrollbar interactive, a
top row scrolled into view painted over the ruler's lower half, so timeline
content appeared on top of the ruler (its time labels/tick marks) while
scrolling up/down.

Root cause in `source/auroracut/timeline.d`: `onPaint` drew the ruler first,
then each track. A row whose top scrolled above `rulerHeight()` but whose
bottom was still below it was not skipped (`rect.bottom() <= rulerHeight()` is
false), so it drew from its unscrolled Y and covered the ruler band.

Fix (a clip, effectively a layer boundary): the track loop now draws into
`canvas.clipped(Rect(0, rulerHeight(), width, height - rulerHeight()))`, so a
partially scrolled row is clipped at the ruler's bottom edge instead of
painting over the ruler.

How to verify (headless):
1. `tests/editor_smoke.d` now renders a 6-track overflow fixture after dragging
   the vertical scrollbar to the bottom and asserts that no track-row color
   (`#1c2027` / `#1a2020` / label `#242930` / selected `#303844`) appears in
   the ruler band (y 0..22 at x=700). It fails on the pre-fix paint order and
   passes with the clip.
2. Pixel probe used during diagnosis: render the editor headlessly
   (`AuroraHeadless`, software renderer), scroll to max, save
   `window.surface().savePpm(...)`, and scan the rows below the timeline for
   row colors. Rows are clipped to the timeline bounds, so the only leak was
   the ruler band.

## Timeline vertical scrollbar: draggable, wider track (2026-08-13)

User complaint: the timeline's vertical scrollbar was a 4px painted thumb only —
you could not grab it, so moving up/down relied on the mouse wheel alone.

What changed in `source/auroracut/timeline.d`:
1. The right-edge scrollbar track is now 12px wide (`VerticalScrollbarWidth`)
   with an opaque track, a left border, and a proportionally sized thumb
   (`verticalScrollbarTrack` / `verticalScrollbarThumb`).
2. It is a real input target: `onMouseDown` grabs the thumb (drag mode),
   `onMouseMove`/`onMouseUp` drag it, hover changes the cursor to `hand`, and
   Escape cancels an active drag. Clicking the track jumps the thumb to the
   pointer (grab offset `thumb.height / 2` when not on the thumb).
3. Testing getters were added: `maxVerticalScrollForTesting`,
   `draggingVerticalScrollbarForTesting`, `verticalScrollbarTrackForTesting`,
   `verticalScrollbarThumbForTesting`.

How to verify (headless, no GUI click needed):
1. `tests/editor_smoke.d` now builds a 4-track fixture that overflows a 120px
   viewport and asserts: track is ≥10px wide and docked right, mouse-down on the
   thumb enters drag mode, dragging to the track bottom scrolls to
   `maxVerticalScrollForTesting`, and mouse-up leaves drag mode.
2. The stale `ListView` scrollbar assertion was rewritten to drive the vendored
   `Scrollbar` widget (drags from the thumb; a track click pages). This was
   pre-existing on the clean base commit — see todo.md.
3. `tests/layout_smoke.d` was stale too: the status-bar loading bar is anchored
   right (inside the 8px inset), not centered; the assertion was renamed
   `assertStatusProgressDocked`. `status-progress` id was missing on
   `_progress` in `source/auroracut/editor.d` and was restored.

Windows build/test commands (see also "Run the headless editor smoke test"):
```
dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source tests\editor_smoke.d -of=build\editor-smoke.exe -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32 -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet
dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source tests\layout_smoke.d -of=build\layout-smoke.exe -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32 -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet
```
Then run with the generated media (or `layout-smoke.exe` with no args). Pass =
`Aurora Cut multi-track editor smoke test passed.` and a silent exit for
layout-smoke. Note `dmd -of=` on Windows emits a file without `.exe` unless the
`.exe` suffix is included; cmd refuses to launch it otherwise.

## Aurora Stream canvas-pump crash: rawWrite on a cross-thread File (2026-08-12)

With the Aurora program canvas enabled, pressing Start streaming crashed the
titlebar app (access violation `0xc0000005`). Two crash dumps
(`aurora-stream-titlebar.exe.*.dmp` in `%LOCALAPPDATA%\CrashDumps`) both faulted
at the same RVA `0x12fe9`.

How it was diagnosed:
1. WER `Report.wer` → ExceptionCode `c0000005`, ExceptionOffset `0x12fe9`.
2. Minidump parse (hand-written Python with the stream directory) →
   exception address `0x140012fe9` (image base + `0x12fe9`), i.e. the fault is
   in the app itself, not a system DLL. The saved thread context pointed into
   ntdll only because the dump captures the exception dispatcher frame.
3. Disassembled the containing function with capstone → it dereferences
   `[rbp+0x10]` (`this`), then `[rax]` (`this._p`), then `[rcx]`
   (`this._p.handle`) and calls; a nearby `lea` references the
   `"Wrote ... instead of ... objects of type ubyte"` string from
   `phobos/std/stdio.d` line 1122 — i.e. **`File.rawWrite!ubyte`**.
4. Grep: the only `rawWrite` in aurora-stream is
   `BroadcastWorker.runCanvasPump` → `stdin.rawWrite(cast(ubyte[]) surface.pixels())`.

Root cause and fix: the phobos `File` (a `@system` struct with a heap-allocated,
manually refcounted `_p` Impl pointer) was captured by reference into the pump
thread's closure and passed by value to `runCanvasPump`. `File.rawWrite` can then
see a null/garbage `_p`. Fixed in `broadcast.d` by passing only the raw fd
(`pipes.stdin.fileno()`, an `int`) into the pump thread; the pump builds its own
`File` via `stdin.fdopen(stdinFd, "wb")` so each thread owns a valid `File`.

How to verify (no GUI click needed):
1. `dub test` in `aurora-stream` → 38 modules pass.
2. `dub build` (default `application` config = the custom titlebar) links.
3. Launch the titlebar app; it opens its window and stays up (no console, no
   crash).
4. Standalone repro: spawn ffmpeg with `Redirect.stderr | Redirect.stdin`,
   `int fd = pipes.stdin.fileno()`, pump thread does
   `File stdin; stdin.fdopen(fd, "wb"); stdin.rawWrite(frames)` — runs clean.

## Aurora Stream no-stray-console-on-stream-start (2026-08-12)

The broadcaster spawns the isolated WASAPI RTP helper as
`aurora-stream.exe --audio-rtp-helper ...` with `Config.suppressConsole`
(CREATE_NO_WINDOW). Previously `app.d` listed `--audio-rtp-helper` in
`isDiagnosticCommand()`, so `main()` called `attachDiagnosticConsole()` →
`AllocConsole()` and popped up a visible command prompt on every Start
streaming. The helper communicates only through status/metrics files and UDP
(no stdout), so `--audio-rtp-helper` was removed from the console-allocating
list.

How to verify (no GUI click needed):
1. Spawn ffmpeg exactly like the broadcast worker and confirm it gets no
   console window:
   ```
   pipeProcess([...], Redirect.stderr, null, Config.suppressConsole)
   ```
   then check the child's `MainWindowHandle` is 0.
2. Spawn the helper the same way the broadcaster does:
   ```
   powershell "$p = Start-Process .\aurora-stream.exe -ArgumentList '--audio-rtp-helper','--port',...,'--synthetic' -PassThru -WindowStyle Hidden; Start-Sleep 4; Get-Process -Id $p.Id | select MainWindowHandle"
   ```
   MainWindowHandle must be 0 (no console).
3. Manual diagnostics that print to stdout (`--version`,
   `--list-audio-endpoints-json`, `--audio-bridge-session-test`,
   `--pacing-test`) still call `AllocConsole` on demand and are expected to
   open a terminal.

## Aurora Stream Aurora-rendered program canvas (2026-08-12)

The roadmap's "Aurora-rendered program canvas" is implemented in
`aurora-stream` as a composited source canvas rendered by Aurora itself. When
**Aurora-rendered program canvas (replaces desktop capture)** is checked in
Settings → Program canvas, `BroadcastWorker` launches FFmpeg with
`-f rawvideo -pix_fmt bgra -s WxH -framerate 60 -i pipe:0` (stdin redirected)
and a dedicated paced frame-pump thread (`runCanvasPump`) composites the canvas
into a `Surface` each frame and writes the BGRA bytes to stdin. The existing
`sourceScaleGraph` (`fps=60:start_time=0:round=near`, `setpts=N/(60*TB)`)
normalizes CFR downstream, so the pump only needs approximate pacing.

Key modules/files:
- `aurora-stream/source/aurorastream/programcanvas.d` — `ProgramSource` model
  (normalized rects, opacity, visibility), `paintProgramCanvas` compositor,
  `ProgramCanvasPreview` widget, `ProgramCanvasEditor` (add color/image/text,
  reorder, opacity, visibility), JSON (de)serialization.
- `broadcast.d` — canvas fields on `BroadcastSettings`, raw-pipe capture args,
  `runCanvasPump`, zero-copy bypass, `videoPipelineLabel`.
- `settings.d` — schema 5 persistence.
- `root.d` — LIVE SOURCE CANVAS preview panel + Program canvas editor section.

How to verify (model level, no GUI needed):
1. `dub test` in `aurora-stream` → 38 modules pass; new programcanvas unittests
   cover color/image/text compositing into a `Surface` and JSON round-trips.
2. Rebuild and run the broadcast-model smoke:
   ```
   dmd -i -g -w -unittest -main -version=AuroraHeadless -Isource -I..\vendor\aurora-d-0.4.5\source tests\broadcast_model_smoke.d -of=build\broadcast-model-smoke.exe user32.lib gdi32.lib shell32.lib ole32.lib avrt.lib -L/SUBSYSTEM:CONSOLE -L/ENTRY:mainCRTStartup -g -L/LIBPATH:"C:\D\dmd2\windows\lib64\mingw" -L/DEFAULTLIB:msvcrt.lib -L/DEFAULTLIB:ucrtbase.lib
   build\broadcast-model-smoke.exe
   ```
   Exit 0. New assertions: canvas mode emits `rawvideo`/`bgra`/`1920x1080`/
   `pipe:0`, never `ddagrab=`/`gdigrab`/`-nostdin`, keeps the CFR cadence
   filters, `usesD3D11ZeroCopyVideo` false, correct `videoPipelineLabel`, and
   the pacing diagnostic forces desktop capture.
3. GUI launch: `dub run` (or RUN-WINDOWS.bat) opens StreamRoot; check the
   LIVE SOURCE CANVAS panel shows the composite and the Program canvas section
   edits sources; controls disable while streaming.

## Aurora Stream custom-titlebar variant + taskbar icon (2026-08-12)

The default `application` build in `aurora-stream` uses the custom `TitleBar`
widget (frameless window, drag/maximize/restore/system menu, real `.ico` in the
titlebar via `TitleBar.setIconImage` and `aurora.image.loadIcoImage`) hosting
the unchanged `StreamRoot`. The `notitlebar` configuration
(`dub run --config=notitlebar`, target `aurora-stream-notitlebar`) keeps the
plain OS-titlebar window.

**Taskbar icon:** the root cause was that aurora-stream was console-subsystem —
double-clicking the exe opened a console window that claimed the taskbar button
with the exe-path title and no icon (verified: the window/class icons were
already set via WM_SETICON/SetClassLongPtr). The default build is now
GUI-subsystem (`/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup`, like
aurora-opencode), so only the GUI window appears in the taskbar with its icon.
CLI diagnostics allocate a console on demand (`AllocConsole` + `freopen`).

Verify: `dub run` (default = custom titlebar, target `aurora-stream`) shows the
aurora-stream icon in the taskbar with no console window; double-clicking the
exe behaves the same. `dub run --config=notitlebar` runs the OS-titlebar build.

## Minimal ffmpeg for redistribution: build + test method (2026-08-12)

Goal: ship ffmpeg with the apps at ~15-30MB instead of 300MB. One static build
serves BOTH aurora-cut and aurora-stream.

How to build (CI only):
1. Push the repo (workflow auto-runs on any change to the build script or
   workflow; also available via Actions -> "Build minimal ffmpeg" -> Run).
2. Download artifact `ffmpeg-minimal-win64` (bin/ffmpeg.exe + bin/ffprobe.exe).

How to reproduce locally (Linux or WSL with mingw-w64 + nasm + meson/ninja +
cmake): `scripts/build-minimal-ffmpeg-win64.sh` — set `WINE=wine` to also run
the smoke test. FFMPEG_TAG env overrides the release (default n8.1).

The build enables ONLY what the two apps use (audited call-site by call-site;
all names cross-checked against ffmpeg's `-encoders/-decoders/-filters/
-formats/-protocols/-devices`):
- aurora-cut surface: mov/mkv/webm/mp3/wav/flac/ogg/image2/gif demuxers,
  mp4/mp3/image2/rawvideo/s16le/null muxers, libx264+nvenc+qsv+amf+aac+
  libmp3lame+ppm+rawvideo+pcm_s16le encoders, ~35 decoders incl. images +
  wrapped_avframe/rawvideo (lavfi + raw pipe), the compositor filter graph,
  d3d11va/dxva2 decode hwaccels, file/pipe protocols.
- aurora-stream surface: ddagrab/gdigrab/dshow + lavfi input devices,
  rawvideo + sdp demuxers (rawvideo pipe:0 canvas, sdp+udp/rtp audio),
  flv + fifo muxers, udp/rtp/rtmp/rtmps protocols (schannel TLS for rtmps),
  settb/asetpts/hwdownload filters, h264_nvenc/libx264/aac encoders.
- Internal codecs with no deps (wrapped_avframe, rawvideo, pcm_s16le, null)
  are NOT listed in configure docs but ARE needed at runtime and were enabled
  explicitly.

CI verification:
- smoke test under wine: the verify-export.sh lavfi commands (color+sine ->
  libx264+aac base-av.mp4, overlay.mp4, libmp3lame extra.mp3) + ffprobe.
- inventory step prints -version/-encoders/-decoders/-filters/-protocols/
  -devices so the run shows ddagrab/dshow/gdigrab/udp/rtmp/rtmps are present.
- configure failures dump ffbuild/config.log.

How to verify on the real machine (definitive — wine has no GPU/capture):
1. Put the minimal ffmpeg.exe + ffprobe.exe on PATH (ahead of any other).
2. aurora-cut: `scripts/verify-export.sh` and `scripts/verify-headless.sh`,
   `scripts/verify-playback-stress.sh`; then launch the GUI and do: import
   MP4/MKV/WebM/GIF/PNG, MP4 export (CPU + GPU), MP3 export, waveform
   preview, yt-dlp normalization. Watch aurora-cut.log for executed commands.
3. aurora-stream: `aurora-stream/RUN-ALL-DIAGNOSTICS.bat` +
   `RUN-QUALITY-DIAGNOSTIC.bat` (exercise ddagrab, fifo->flv, nvenc,
   sdp/udp audio). A local .flv output verifies the fifo/flv path without
   needing a real Twitch/YouTube key.

## Titlebar polish: native cursor + centered search text (2026-08-12)

- The demo disabled Aurora's synchronized (drawn) cursor during titlebar drags
  with `WindowOptions.synchronizedDragPointer = false`; the native pointer stays
  visible while dragging the window (the drawn cursor is meant for retained
  compositor-layer drags).
- `aurora.widgets.texteditor` gained `setContentCentered(bool)`: single-line
  content that fits the viewport is horizontally centered. `contentOriginX()`
  is the single source for paint, caret, selection, and hit-testing, so editing
  stays consistent; content wider than the viewport keeps normal
  `_padding - _scrollX` scrolling. The demo search box is now an empty
  `TextField` with a centered grey placeholder.

Verify: drag the titlebar (native cursor, no shake/black), and the search
placeholder is centered in the middle of the titlebar.

## Titlebar dragging: black window, snap border, shaking (2026-08-12)

Three drag artifacts were reported on the frameless demo and fixed:

1. **Black window while dragging.** The OS caption move loop (`beginSystemMove`)
   arms the resize proxy, whose snapshot ALIASED the software renderer's live
   surface. `_renderer.resize()` then reallocates that same surface in place,
   so the proxy presented garbage/black frames during the modal loop. Fix in
   `aurora.window.refreshResizeProxyFromScene`: the renderer surface's pixels
   are now COPIED into the privately-owned `_resizeSnapshot` surface instead of
   aliased.

2. **White border when dragging to the top and releasing.** The OS caption move
   loop triggers aero-snap maximize, which flashes the native (system-light)
   frame during the transition. The demo now drags owner-side instead of using
   the OS loop: `onDragStarted`/`onDragMoved` call
   `GuiWindow.setWindowPosition` (SetWindowPos), which never snaps.

3. **Entire window shaking while dragging.** Aurora mouse-event positions are
   window-relative (client) coordinates, but the first owner-drag mixed them
   with screen bounds. After each SetWindowPos, Windows synthesizes a
   WM_MOUSEMOVE inside the moved window; the recomputed absolute position then
   moved the window back → hunting/oscillation. Fixed by dragging with the
   pointer DELTA from the drag start:
   `windowOrigin + (pointer − startPointer)` — deltas are identical in
   window-relative and screen space, so the synthesized event yields zero delta
   and the loop is stable.

Verify manually in the demo: drag the titlebar (should be smooth, no black, no
shake), drag to the top edge and release (no white border / no snap), and
restore-on-drag (drag down from maximized) still works.

## TitleBar restore-on-drag: drag down to leave maximize (2026-08-12)

While a TitleBar is maximized, pressing the title and dragging past the 5px
movement threshold now leaves the maximized/fullscreen state and continues the
drag. Implementation: `TitleBar` fires `onRestoreRequested(pointer,
pressPointer)` at threshold crossing, clears its own `_maximized`, re-anchors
the drag (`_dragStartPointer`/`_dragStartPosition`) to the current pointer and
position, and proceeds. Two modes:

- **In-canvas** (self-move or owner `onDragMoved`): after restore the drag
  continues from the re-anchored pointer.
- **Native system move** (`systemMoveOnDrag`): while maximized the OS move loop
  is deferred until real movement (armed on mouse-down instead of calling
  `beginSystemMove()` immediately), so the owner can restore first; then
  `beginSystemMove()` starts the OS loop.

Added `NativeWindow.setWindowPosition(Point)` / `GuiWindow.setWindowPosition`
(Win32 `SetWindowPos`; base/headless return false). The demo's
`restoreFromDrag` exits fullscreen and re-anchors the window so the grabbed
titlebar spot stays under the pointer before the OS loop resumes.

Covered by `tests/titlebar_smoke.d`: in-canvas restore-on-drag asserts the
press pointer, the state clear, and the re-anchored final Y (start + 70 for a
40→120 downward drag); system-move restore-on-drag asserts the restore fires
and the state clears. Verify manually in the demo: maximize (double-click), then
click the titlebar and drag down — the window should restore and follow.

## Titlebar fixes: double-click maximize + white frame border (2026-08-12)

Two user-reported issues with the frameless TitleBar demo:

1. **Double-click did not maximize.** `TitleBar.onMouseDown` checked the
   `systemMoveOnDrag` branch before the double-click branch, so the second
   press of a double-click (clickCount >= 2) started another native move loop
   instead of maximizing. Fix: double-click branch now runs first. Also removed
   the `captureMouse()` before `beginSystemMove()` — the OS caption-drag loop
   owns capture and swallows the mouse-up, so the logical capture leaked.
   Covered by a smoke-test regression: with `setSystemMoveOnDrag(true)`, a
   double-click still maximizes and restores.

2. **Random white border / blink around the frameless window.** Frameless
   resizable windows are `WS_POPUP | WS_THICKFRAME`; DWM draws a 1px frame
   that was left at the system-LIGHT color (white) because `applyDarkTitleBar`
   only ran for `decorated` windows, and DWM repainted it on every activation
   change. Fix in `aurora.platform.win32`: apply the dark DWM frame attributes
   (`DWMWA_USE_IMMERSIVE_DARK_MODE`, `DWMWA_BORDER_COLOR`,
   `DWMWA_CAPTION_COLOR`, `DWMWA_TEXT_COLOR`) whenever `darkTitleBar` is set or
   the window is frameless, and return `TRUE` from `WM_NCACTIVATE` for
   frameless windows so DWM never repaints the frame on focus changes.

Verify: click/focus the demo window repeatedly and watch the border stay dark
and stable; double-click the titlebar to toggle fullscreen both ways. Headless
coverage = `tests/titlebar_smoke.d` double-click-with-system-move regression.

## Aurora OpenCode Pro native tools main; Legacy tools in Settings (2026-08-12)

The toolbar has one "Tools" checkbox (native D tools), on by default. The
legacy bash/cmd/powershell shell tool moved to a "Legacy tools" checkbox in
Settings with a "(?)" hover tooltip. New `Settings.legacyTools` (default off);
old `nativeTools` settings are migrated (native-only users → legacy off).

Verify: Pro smoke test opens Settings and asserts the Legacy tools checkbox
exists, is off by default, and its tooltip mentions the shell tool.

## Aurora Custom TitleBar widget (2026-08-12)

New reusable `aurora.widgets.titlebar.TitleBar` widget — a completely
customizable in-canvas title bar. Everything is configurable:

- `setTitle` / `setIcon` / `setShowIcon` / `setTitleAlign` (left/center/right)
- Caption buttons: `setShowMinimize/Maximize/Close`, `setCaptionButtonWidth`
- Drag: in-canvas self-move (default), owner-driven move (`onDragMoved`), or
  native OS move (`setSystemMoveOnDrag(true)` + new host `beginSystemMove()`)
- `setDoubleClickMaximizes`, `onDoubleClick`, `onSystemMenu(Point)`,
  `onMinimize/onMaximizeToggle/onClose`
- Visuals: `setBarHeight`, `setCornerRadius`, `setBackground`,
  `setInactiveBackground`, `setBorderColor`, `setTextColor`,
  `setMutedTextColor`, `setButtonHover/PressedColor`, `setCloseHover/
  PressedColor`, `setActive`, `setMaximized`
- `setContent(Widget)` puts an arbitrary widget (search box, tabs…) between the
  title and the caption buttons; `setTitleWidth` fixes the title region size.

Two framework hooks were added so the widget can drag a real frameless window:
`WidgetHost.beginSystemMove()` (interface) and `Widget.beginSystemMove()`;
`GuiWindow` already exposed it, now as an `override`.

### Build / run the demo

```
vendor\aurora-d-0.4.5\dub build --config=titlebar      # via dub
RUN-AURORA-D-TITLEBAR.cmd                               # repo-root launcher
```

The demo is a frameless window (`options.decorated=false`) whose whole top
strip is a TitleBar: native drag, custom colors, rounded top corners, a
`TextField` hosted in the bar, and a right-click system menu.

### Headless smoke test (tests\titlebar_smoke.d)

Compile exactly like the other editor smoke tests:

```
dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source tests\titlebar_smoke.d -of=build\headless-smoke\titlebar-smoke.exe -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32 -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet
set AURORA_RENDERER=software&& set SDL_AUDIODRIVER=dummy&& build\headless-smoke\titlebar-smoke.exe
```

Pass = prints `Aurora TitleBar smoke test passed.` Coverage (through the real
`UiTestDriver` dispatch path): caption-button callbacks, double-click maximize
toggle, right-click system menu, self-move drag by exact pointer delta,
owner-driven drag (`onDragMoved`/`onDragEnded`), hidden buttons, custom content
layout, fixed title width, active/maximized state, and two screenshots
(`titlebar-smoke.ppm` default state, `titlebar-smoke-hover.ppm` with the close
button hot). Pixel-verified with `build/headless-smoke/check_titlebar_pixels.d`
(titlebar background = `panelElevated`, window background = `windowBackground`,
close hover = `danger`).

Module unittests: `dmd -main -unittest -i -version=AuroraHeadless
-Ivendor\aurora-d-0.4.5\source vendor\aurora-d-0.4.5\source\aurora\widgets\titlebar.d
-of=build\headless-smoke\titlebar-module.exe -L/DEFAULTLIB:user32
-L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32 -L/DEFAULTLIB:winmm
-L/DEFAULTLIB:wininet`.

### Gotchas discovered while building it

- A drag must start only after a movement threshold (5 px): the first click of
  a double-click must not arm a drag. The plain-click path releases capture
  without moving.
- `_armDrag` MUST be cleared when the drag actually starts in `onMouseMove`,
  otherwise the next mouse-move over the bar re-arms a fresh drag and the bar
  never stops dragging (regression covered by the smoke test's hover step).
- PPM `savePpm` output is plain RGB; beware off-by-header-byte bugs when
  sampling screenshots (the header is `P6\n<w> <h>\n<max>\n`).

## Aurora OpenCode Pro per-message Copy pill removed (2026-08-12)

The top-right "Copy" pill on every message bubble was redundant with "Copy
message" in the right-click context menu; it was removed. Code-block copy
pills are unchanged (they copy just the code block).

## Aurora OpenCode Pro hidden tool-call wrapper (2026-08-12)

An assistant message that only requested tools (no content, no reasoning) no
longer renders as an empty bubble. `MessageBubble.setHidden` collapses it to a
zero-height, paint-nothing slot so the child↔message index mapping stays intact.
`handleToolCalls` rebuilds the column to hide the wrapper; `rebuildMessageColumn`
hides wrappers on session restore too.

Verify: Pro smoke test asserts every assistant wrapper is hidden, pill-free,
and usage-free. A probe confirms wrapper height = 0.

## Aurora OpenCode Pro tool-call wrapper cleanup (2026-08-12)

The assistant message that requests tools (the tool-call wrapper) is not a
reply, so it must not show a Regenerate pill or token usage. `handleToolCalls`
clears the wrapper's streamed usage text; `refreshBubbleActions` only pills the
latest assistant with no `toolCalls`; `rebuildMessageColumn` attaches usage
only to the latest real reply.

Verify in the Pro smoke test: after a read+grep tool loop, every assistant
wrapper bubble has no action pill and no usage text.

## Aurora OpenCode Pro latest-reply actions + message context menu (2026-08-12)

Only the latest assistant reply shows the Regenerate/Retry pill and the
token-usage footer; older bubbles are clean. Right-click on any message opens a
context menu with Copy message and, depending on role, Regenerate (assistant)
or Edit & resend (user).

Verify in the Pro smoke test: a user message has no pill, the latest assistant
reply has Regenerate; after regenerate the last bubble has no pill; the
right-click context menu Edit & resend truncates at the targeted message (the
foreach-closure regression is covered).

## Aurora OpenCode Pro opencode-style system prompt (2026-08-12)

Replaced the 2-line steering prompt with `buildSystemPrompt(nativeOnly,
workspace, platform)`, mirroring the original opencode app's system prompt
structure (from its source): identity, an `<env>` block with working
directory + "Is directory a git repo: yes/no" + platform + today's date, a
tone/style contract, a tool-usage policy, and "think about the task before
beginning work". This is what makes opencode's first answer feel deliberate.

Verify live with a temp probe against a real git repo: the model now gathers
context (git log/status/diff) and reads files instead of spamming shell
commands, and groups tool calls. Native mode runs `dshell where` + `run git
status` + `dshell list` in parallel.

## Aurora OpenCode Pro no console flash on tool calls (2026-08-12)

`runProcess` now calls `spawnProcess` with `Config.suppressConsole` (Windows
`CREATE_NO_WINDOW`), so the child process (cmd.exe / powershell.exe / a `run`
target) does not open a console window. Previously `Config.none` let Windows
flash a console for every bash/run/dshell tool call.

Verify: tools test still runs bash (`echo`), PowerShell, cmd, workdir, and the
D-native `run` tool successfully; Pro smoke passes.

## Aurora OpenCode Pro doom-loop recovery (2026-08-12)

User reported a runaway tool loop ("where we are at" kept calling tools until
the round limit). The original opencode app has a `doom_loop` permission: when
the same tool call repeats with identical input 3 times it stops and asks.

Our implementation: `handleToolCalls` builds a signature of each tool-call
batch (`name(arguments)`); when the same signature repeats 3× it breaks the
loop, injects a `user` recovery message ("You appear to be repeating the same
tool call... answer directly"), resets the counters, and runs one final request
so the model answers instead of looping. The 12-round cap now also injects a
"stop and answer" message rather than silently stopping.

Verify in the Pro smoke test: three identical `dshell list` injections
accumulate a repeat count (1, 2, 3) and the third triggers a recovery `user`
message.

## Aurora OpenCode Pro collapsed thinking with progress animation (2026-08-12)

Reasoning blocks now render as a slim collapsed `▸ Thinking` header (same
pattern as the tool result headers). Clicking toggles the full reasoning text.
While the assistant is still streaming, the header shows an animated pulsing
`▌`/`▐` indicator, driven by the root's per-frame tick (`tickThinking`), which
repaints only when the indicator phase changes (every ~0.5s), so the animation
is cheap. `finishAssistantMessage` freezes the indicator.

This mirrors the original opencode app: it renders reasoning as a streamed text
part behind a show/hide toggle (/thinking in the TUI) and tools as collapsible
cards — no full-spinner animation; the pulsing cursor is our lightweight
equivalent of the typing reveal.

Verify in the Pro smoke test: an assistant message with reasoning is created
via `addConversationForTestingWithReasoning`, starts collapsed, and toggles
open/closed on demand.

## Aurora OpenCode Pro tool collapse UX (2026-08-12)

A `tool` result bubble is now a single element: a header showing the command
(`▸ ⚙ name(args)`) that is always visible, with the output below shown only
when expanded (`▾` when open). Clicking the header toggles the output.

Two fixes shipped:
1. No scroll jump: the collapse/expand `onSizeChanged` handler no longer sets
   `_messagesScroll.follow = true`; it only invalidates the column + scroll, so
   the viewport is preserved when expanding a bubble above the fold.
2. Command + output unified: `toolArgs` (the command's JSON arguments) is
   stored on the tool message and persisted, and rendered compactly in the
   header (`key=value` pairs). The separate tool-call chips were removed from
   assistant bubbles.

Verify in the Pro smoke test: tool bubbles start collapsed; expand/collapse
toggles; and a scroll-position regression scrolls up, expands, and asserts the
offset does not snap to the bottom.

## Aurora OpenCode Pro collapsed tool outputs (2026-08-12)

`tool` role result bubbles start collapsed to a compact header
(`⚙ <name> · <first line> ▾`) and expand on click. The bubble calls
`onSizeChanged`, which invalidates the message column and scroll view so the
content re-measures, the scroll re-follows, and large outputs (e.g. `dir`
listings) don't blow up the conversation view by default.

Verify in the Pro smoke test: after the read+grep tool loop, the first tool
bubble is collapsed; `toggleFirstToolBubbleForTesting` expands then collapses
it with repaint + reflow each way. Screenshots of both states are written to
`%TEMP%\aurora-opencode-collapse-shots`.

## Aurora OpenCode Pro dshell advertises only natural words (2026-08-12)

The model sometimes emitted `pwd`/`ls`/`stat` because the dshell tool
description and JSON schema enum TAUGHT those aliases. Fixed:

- The advertised `dshell` schema `command` enum is now exactly
  `["where","list","info"]` and the description never mentions pwd/ls/stat.
- The runtime dispatcher still accepts pwd/ls/dir/stat as a safety net (calls
  never fail), but the model is never offered them.
- The steering prompt explicitly forbids shell command words.

Verify: `tools_test.d` runs `dir` through the shell tool, checks `where/list/
info` plus alias fallback, AND asserts the advertised schema/description
contain no legacy words (`dshell advertises only the natural words`). Live
probe: "where are we now?" calls `dshell where` (+ `list`) only, both modes.

## Aurora OpenCode Pro tool-output UTF-8 safety (2026-08-12)

The shell/run tools read console output as raw bytes (cmd emits the OEM
codepage, not UTF-8). A bug wrote those bytes straight into a `string`, which
is invalid UTF-8 and broke `sessions.json` persistence → `restore sessions
failed: Invalid UTF-8 sequence` on the next launch.

Fix in `runProcess`: each raw byte is mapped to its own `dchar` and UTF-8
encoded (`std.utf.toUTF8`), so tool output is always valid UTF-8.

Regression: `tools_test.d` runs `dir` (which emits the OEM thousands
separator), asserts `std.utf.validate` passes and the listing is complete.
Verified a clean app restart logs zero errors.

## Aurora OpenCode Pro dshell natural words (2026-08-12)

`dshell` deliberately uses short natural-English words instead of the legacy
shell abbreviations, so conversations read clearly:

- `where` — prints the workspace path (alias `pwd`).
- `list` — shows a directory with `[f]`/`[d]` tags and byte sizes (aliases
  `ls`/`dir`).
- `info` — file/directory metadata: type, size, modified time (alias `stat`).

Legacy words still work as aliases so a model that reaches for `ls`/`pwd`/
`stat` never fails. All implemented natively in D (`std.file`), no shell.

Verify with the tools test:
```
cd aurora-opencode-pro
dmd -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\tools_test.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\tools-test.exe
build\tools-test.exe
```
Pass = `D-native dshell where / list / info (+ aliases) OK`, `Default vs
native-only toolset shapes OK`, then `Aurora OpenCode Pro tools module test
passed.`

Live (temp probe): "where am I and what's in the workspace?" now answers via
`dshell where` + `dshell list` then `read` in 3 rounds — the model uses the
natural words.

## Aurora OpenCode Pro dshell tool (2026-08-12)

The model still reached for bash for plain directory introspection
(pwd/ls/dir/stat). Added a D-native `dshell` tool in
`aurora-opencode-pro/auroraopencode/tools.d`:

- `pwd` — prints the workspace path.
- `ls` / `dir` — lists a directory (`SpanMode.shallow`) with `[f]`/`[d]` tags
  and byte sizes.
- `stat` — file/directory type, size, and modified time.

It never spawns a shell; everything uses `std.file` (`dirEntries`, `getSize`,
`timeLastModified`). Advertised in both the default and native-only toolsets,
and the steering prompt directs the model to prefer it over bash for these
commands.

Verify with the tools test:
```
cd aurora-opencode-pro
dmd -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\tools_test.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\tools-test.exe
build\tools-test.exe
```
Pass = `D-native dshell pwd / ls / stat OK`, `Default vs native-only toolset
shapes OK`, then `Aurora OpenCode Pro tools module test passed.`

Live (temp probe): "where am I and what's in the workspace?" now answers via
`dshell pwd` + `dshell ls` then `read` in 3 rounds, no bash attempts. Native
mode uses `dshell ls` directly.

## Aurora OpenCode Pro native-tool mode (2026-08-12)

User feedback: the model defaulted to bash for file operations and fumbled
("list files" burned many rounds on `dir` variants). Two fixes shipped:

1. **Shell output capture bug** — cmd's `dir` emits the OEM codepage, which is
   not valid UTF-8; strict `readText` threw and the tool returned "(no
   output)". `runProcess` now reads stdout/stderr as raw bytes and decodes
   leniently, so `dir`/`echo %CD%` return real output.

2. **Native-tool mode** — a new D-native `run` tool (`program` + `args` array,
   spawned directly, no shell), a system-prompt steering message that directs
   the model to glob/read/write/grep, and a "Native tools" toggle (off by
   default). When enabled, the bash tool is not advertised and the model only
   sees run/read/write/glob/grep with a "no shell" prompt.

Verify with the tools test (covers run tool + toolset shapes + steering):
```
cd aurora-opencode-pro
dmd -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\tools_test.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\tools-test.exe
build\tools-test.exe
```
Pass = `D-native run tool executes a program directly`, `Default vs native-only
toolset shapes OK`, then `Aurora OpenCode Pro tools module test passed.`

Live probe (temp file `list_probe.d`): native mode answers "what files are in
the workspace?" with glob → read in 3 rounds, no shell. Default mode with the
steering prompt completes the same task in 3 rounds too.

## Aurora OpenCode Pro cross-platform tools (2026-08-12)

Design decision (mirrors the original opencode app): keep native D file/content
tools (`read`, `write`, `glob`, `grep`) — cross-platform by construction — and
make the one shell tool ("bash") shell-aware per platform rather than shipping
separate cmd / powershell tools.

- The bash tool schema now has `command` (required), `shell`
  (`auto|bash|cmd|powershell|pwsh`), `workdir`, and `timeout` (ms).
- The description embeds per-platform usage notes: on Windows it tells the
  model it runs in cmd.exe (or the chosen PowerShell) with the right commands,
  on Unix it says bash.
- Execution uses `spawnProcess(argv, stdin, outFile, outFile, null,
  Config.none, workdir)` — the shell binary is invoked directly with
  stdout/stderr redirected to a temp file, so no shell quoting is involved and
  a timeout can still kill the process.

Run the tools test (covers cmd, PowerShell, workdir):
```
cd aurora-opencode-pro
dmd -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\tools_test.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\tools-test.exe
build\tools-test.exe
```
Pass = `cmd / powershell / workdir shell selection OK` then
`Aurora OpenCode Pro tools module test passed.`

## Aurora OpenCode Pro action-pill foreach capture bug (2026-08-12)

User reported "I press edit & resend and nothing happens anymore". Root cause:
the Regenerate / Edit & resend pill callbacks were created inline inside the
`foreach` over `_messageColumn.children()` (`refreshBubbleActions`) and the
right-click `onEditRequested` (`rebuildMessageColumn`). D captures the reused
`foreach` loop slot by reference, so every closure was bound to the FINAL
message index; clicking a pill on any early bubble edited (or no-op'd against)
the last message instead.

Verification method:
```
dmd -version=AuroraHeadless -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\headless_pro_smoke.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\headless-pro-smoke.exe
build\headless-pro-smoke.exe
```
Pass = `Aurora OpenCode Pro headless smoke test passed.` The regression section
(`invokeBubbleActionForTesting`) drives the pill through the real captured
delegate on a mid-conversation user bubble and asserts it truncates at and
prefills that bubble's own message.

D gotcha confirmed independently: even `const int captured` / non-const locals
declared inside a `foreach` body capture the shared loop slot in DMD 2.112;
only a delegate factory function (binding indices as parameters) works. The
same pitfall and fix are documented in `AURORA-PATCHES.md` for font menus.

## Aurora OpenCode Pro tool use support (2026-08-12)

Studied the original opencode app's tool architecture (the tool registry in
`packages/opencode/src/tool`: bash/shell, read, write, glob, grep, webfetch,
websearch, question, task, todo, skill, apply_patch, lsp, plan) and confirmed
the exact wire format with a live probe against the real Go API:

- Tool calls stream as `choices[0].delta.tool_calls` fragments:
  `{index, id, type, function:{name, arguments}}` where `arguments` arrives in
  multiple fragments that must be concatenated.
- The stream ends with `finish_reason: "tool_calls"` (no text reply).
- Results are fed back as `role: "tool"` messages with `tool_call_id`
  (plus the assistant message with its `tool_calls`), and the loop repeats
  until the model returns a normal text reply.

The core client (`aurora-opencode-core/opencode_client.d`) gained
`startChatMessages(messages, tools, model, thinking)` with
`ChatRequestMessage`/`OpenCodeToolDef`, SSE `delta.tool_calls` accumulation,
a `toolCalls` terminal event, and `pushLocalEvent`. The Pro UI drives the
loop: Tools checkbox → workspace setting → tool-call chips + `tool` role
result bubbles → worker-thread batch execution → history re-sent until `stop`
(12-round cap).

### Tests

1. Core SSE parsing + body serialization:
```
cd aurora-opencode-core
dmd -i -Isource -I..\vendor\aurora-d-0.4.5\source tests\tool_sse_test.d wininet.lib -of=build\tool-sse-test.exe
build\tool-sse-test.exe
```
Pass = `aurora-opencode-core tool SSE tests passed.` Covers fragmented
`tool_calls` accumulation (id/name/arguments stitched), the `toolCalls`
terminal event, tools array serialization, and a tool-role message carrying
`tool_call_id`.

2. Pro tools executors:
```
cd aurora-opencode-pro
dmd -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\tools_test.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\tools-test.exe
build\tools-test.exe
```
Pass = `Aurora OpenCode Pro tools module test passed.` Covers read/write/glob
(`**` recursion)/grep/bash (echo) against a temp workspace, and unknown-tool
error handling.

3. Pro headless smoke (tool loop offline):
```
cd aurora-opencode-pro
dmd -version=AuroraHeadless -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\headless_pro_smoke.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\headless-pro-smoke.exe
build\headless-pro-smoke.exe
```
Pass = `Aurora OpenCode Pro headless smoke test passed.` The added section
injects a tool call (read + grep) with tools enabled, ticks the tree until the
worker results arrive, and asserts two `tool` role messages landed with the
right contents and the session history was preserved.

4. Live tool loop against the real API (verified): a sum tool request runs two
rounds (tool_calls → result → text `The result of adding 1 and 2 is 3.`), and
the built-in tool set (glob/read/bash) completes a workspace task with
`LIVE BUILTIN TOOL LOOP OK` and a clean `errors.log`.

## Aurora OpenCode Pro live context-usage meter (2026-08-12)

Pro shows the **exact API-reported token usage** as a percentage of the model's
context window in a small rectangular toolbar badge, with a hover tooltip that
breaks the usage down (mirrors how the real opencode app meters context):

- **How the real opencode meters context** (`anomalyco/opencode`): it uses the
  provider's `usage` object stored per assistant message
  (`tokens: {input, output, reasoning, cache:{read,write}}`), displayed as
  `total / model.limit.context` percent. There is **no live mid-stream
  estimate** in the real UI — the indicator updates at each `step-finish`. The
  only local approximation (`Math.round(chars/4)`) is used for compaction /
  overflow decisions and the estimated breakdown bar. The context limit comes
  from provider metadata (`model.limit.context`).
- **Implementation** in `aurora-opencode-pro/appui.d`: `ContextUsageBadge`
  (toolbar pill, fill bar + percent) + `ContextUsageTooltip` (hover panel,
  never steals the pointer — its `hitTest` reports the badge while hovered).
  The shared client pushes a live `usage` event when the provider reports token
  counts mid-stream (`opencode_client.d`, `_streamActive` guard), and the `done`
  event records the final `prompt/completion/total` on the `ChatMessage`
  (persisted in `sessions.json`).
- **Context limit**: `contextLimitForModel()` in `aurora-opencode-core/core.d`
  mirrors `model.limit.context` with the **official opencode model catalog**
  (`https://models.opencode.ai/api.json` — the exact source the opencode CLI
  fetches). Verified live against that catalog: deepseek-v4-flash and
  deepseek-v4-pro are 1,000,000 tokens, gpt-5.6-luna 1,050,000, qwen3.8-max
  and glm-5.2 1,000,000, grok-4.5 500,000, kimi-k3 1,048,576, minimax-m3
  512,000, mimo-v2.5-pro 1,048,576, hy3 256,000. Unknown models fall back to
  128K. The used-token count itself is always exact from the API.
- **Badge lifecycle**: updates live during streaming (`usage` event), on
  `done`, on session switch, model picker, restore, and delete. Shows `ctx`
  until usage is recorded.

Covered by `headless_pro_smoke.d`: initial empty state, 25% after recording
250000/1000000 (deepseek-v4-flash limit from the official catalog), hover
opens the tooltip (title/model/limit/used/prompt rows), leave dismisses it,
and the meter follows the active session. Verified visually via a PPM
screenshot (badge region: 24 distinct colors, tooltip region: 29).

## Aurora OpenCode Pro chat-quality actions (2026-08-12)

Pro-only chat quality (implemented in `aurora-opencode-pro/appui.d`, shared
`ChatMessage.failed` flag in core):

- **Regenerate / Retry** — the last assistant bubble shows a footer pill. It
  drops the last assistant reply and re-runs the request with the remaining
  history; labelled "Retry" when that reply failed.
- **Edit & resend** — a user bubble's footer pill (and right-click on any user
  bubble) truncates the conversation at that message and prefills the input so
  the edited text can be re-sent.

Covered by `headless_pro_smoke.d`: `editAndResendForTesting` truncates and
prefills, and `prepareRegenerateForTesting` removes the last assistant reply.

## Aurora OpenCode real API integration (2026-08-12)

The clients now talk to the **real opencode API** (`https://opencode.ai/zen/go/v1`,
the Go plan) instead of the demo proxy `opencode-api.boqsc.eu`:

- `defaultBaseUrl` in `aurora-opencode-core/core.d` points at
  `https://opencode.ai/zen/go/v1`.
- The API key is read from the real opencode CLI auth store
  (`~/.local/share/opencode/auth.json`, `opencode-go.key`, falling back to
  `deepseek.key`), then the legacy web-server key files, then
  `OPENCODE_API_KEY`.
- Every request sends a desktop-browser `User-Agent`. The real API sits behind
  Cloudflare and returns HTTP 1010 to non-browser clients otherwise.
- Thinking off is sent as the standard `reasoning_effort: "none"` (the demo
  proxy used to translate a custom `thinking: false` boolean, which the real
  API rejects).

Verified live: the smoke test's real chat returns exactly `AURORA-OPENCODE-GUI-OK`
(22 chars) with a clean `errors.log`. Debug + release builds of baseline and Pro
pass. The old loopback fallback to the local demo proxy was removed.

## Aurora OpenCode runtime error logging (2026-08-12)

Both OpenCode clients write runtime errors to
`%APPDATA%\Aurora OpenCode\logs\errors.log` (one shared file, appended). Each
launch writes a `========== <app> started ==========` banner, and every entry is
timestamped, so the latest session is easy to scan. The log directory is the
state directory plus `logs`; tests redirect it through the normal
`setOpencodeStateDirectoryForTesting` hook.

Captured sources:
- Chat and models request failures (WinINet errors such as 12029/12002) with
  the configured base URL, logged from the shared client worker threads.
- Settings load/save failures and session persist/restore failures.

A WinINet 12029 (`ERROR_INTERNET_CANNOT_CONNECT`) or 12002 (timeout) on
`chat request failed` means the API server was unreachable when the request was
sent, not a client bug.

## Aurora OpenCode Pro extended features (2026-08-11)

`aurora-opencode-pro` layers extended features on the shared core while the
baseline stays basic:

- Conversation **delete** (sidebar right-click menu + `Delete` key) and
  **rename** (context menu -> dialog).
- **Filter** box above the conversation list (title substring match).
- Per-message and **code-block Copy** buttons (hover the bubble or panel), and
  **clickable Markdown links** (open the default browser).
- **Message timestamps** (HH:MM) and **token usage** in the status line.
- **Export** the current conversation to a `.md` file under
  `%APPDATA%\Aurora OpenCode\exports`.

Run the Pro headless smoke test from `aurora-opencode-pro`:

```
dmd -version=AuroraHeadless -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\headless_pro_smoke.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\headless-pro-smoke.exe
build\headless-pro-smoke.exe
```

Pass = `Aurora OpenCode Pro headless smoke test passed.` Coverage: restored
sessions, filter narrowing/clearing, rename via the context menu, delete via the
list Delete hook, and Markdown code-block/link bubbles painting.

## Aurora OpenCode structure: baseline, core, and Pro (2026-08-11)

The OpenCode chat clients are split so the baseline stays small while the
extended version grows freely:

- `aurora-opencode-core` — DUB library (`targetType: library`) with the
  shared `auroraopencode.opencode_client`, `auroraopencode.markdown`, and
  `auroraopencode.core` modules. Both clients depend on it by path.
- `aurora-opencode` — the baseline client (thin `appui.d` on top of core).
- `aurora-opencode-pro` — the extended client with its own `appui.d`.

Build and run the baseline or Pro exactly like the other apps:

```
cd aurora-opencode
dub build --force
cd ..\aurora-opencode-pro
dub build --force
```

The headless tests compile with `dmd -i` and therefore need the core source
directory on the import path in addition to the app and Aurora-D sources.

## Aurora OpenCode startup conversation scrollbar (2026-08-11)

The OpenCode headless smoke test now creates an isolated persisted state with
25 conversations and the last conversation selected before constructing the
window. It paints the initial tree and asserts the restored selection remains
selected while the conversation `ListView` scroll offset is still zero. Run
from `aurora-opencode`:

```
dmd -version=AuroraHeadless -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\headless_smoke.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\headless-smoke.exe
build\headless-smoke.exe
```

The test also retains the existing OpenCode interaction, persistence, model
picker, message auto-follow, scrollbar drag, and scrolling shape-cache checks.

## Unified scrolling and rich drag/drop (2026-08-11)

Run the retained control and event-routing contracts:

```
cd vendor\aurora-d-0.4.5
dub run --config=widget-infrastructure-test --compiler=dmd
```

Pass = `Unified scrolling and rich drag/drop contracts passed.` Coverage
includes `ScrollView`, `ListView`, and `TextArea` using child `Scrollbar`
widgets, ordinary wheel and native absolute-position input, rich payload
enter/move/drop/leave dispatch, custom MIME preservation, and action
negotiation.

Run `dub test --compiler=dmd` on Windows to exercise the OLE data-object
round-trip for file paths, Unicode text, URI lists, and custom MIME bytes.

## Windows File Manager wheel / touchpad scrolling (2026-08-11)

The file manager now uses the reusable retained-mode
`aurora.widgets.scrollbar.Scrollbar` control for both its list and sidebar.
The widget owns range/value state, Aurora rendering, wheel accumulation,
keyboard input, page clicks, thumb hit-testing, and pointer capture. Aurora's
window host tracks the scrollable widget beneath the pointer and synchronizes
only that widget's range/value with Win32, so sibling list/sidebar controls
cannot overwrite one another. Windows does not draw the control or move the
file-manager content.

### 1. Deterministic widget and file-manager contracts
```
cd vendor\aurora-d-0.4.5
dub run --config=file-manager-scroll-test --compiler=dmd
```

Pass = `Windows file manager wheel/touchpad scroll contracts passed.` The test
covers standalone widget geometry, track paging, thumb capture/dragging,
standard wheel input, fine-grained touchpad deltas, native absolute scroll
commands, sidebar routing, ignored non-scroll areas, and independent windows.

### 2. Win32 focus, range, and exact-delta probe
```
cd vendor\aurora-d-0.4.5
python tools\file_manager_focus_scroll_probe.py ^
  aurora-windows-file-manager.exe build\fm-scroll-test
```

The probe checks that the HWND advertises a synchronized native scroll range,
a client click establishes foreground focus, `WM_VSCROLL` updates the real
widget, four standard notches move exactly 104 px, and twelve `-20` precision
deltas accumulate to exactly 52 additional px. Pass marker:
`NATIVE FOCUS + SCROLL VERIFIED`.

## Live resize verification (2026-08-11)

Use the checked-in Python probe to launch an app and drive the native window:

- `python vendor\aurora-d-0.4.5\tools\resize_latency_probe.py
  aurora-opencode\aurora-opencode.exe --renderer vulkan --iterations 120
  --step-delay 0.016 --profile-frame`
- The probe sends `WM_ENTERSIZEMOVE`, changes the window through
  `SetWindowPos`, and ends with `WM_EXITSIZEMOVE`. It reports median/p95/max
  native-call latency and the number of calls over 16 and 50 ms.
- `--profile-frame` reports final scene/layout/paint/render time plus the number
  of exact live-reflow frames completed during the drag.
- The default settle probe also reports p95/max message latency after
  `WM_EXITSIZEMOVE`, covering deferred native-resolution swapchain recreation.

OpenCode uses the automatic renderer (Vulkan by default when available).
`RUN-WINDOWS.bat` builds/runs release; `RUN-WINDOWS-SOFTWARE.bat` is the explicit
software fallback.

## How to build and test on Windows

### Build the app
- `dub build --force` (requires DMD/LDC + DUB, ffmpeg/ffprobe/ffplay on PATH).
- If the linker reports `aurora-cut.exe: Access is denied`, a previous instance
  is locking the file: `del aurora-cut.exe aurora-cut.pdb` and rebuild.
- Result: `aurora-cut.exe` in the repo root.

### Run the headless editor smoke test (editor_smoke.d)
The smoke test drives the real GUI headlessly (`RendererPreference.software`)
and needs three generated media files.

1. Generate media (mirrors `scripts/verify-headless.sh`):
   ```
   mkdir build\headless-smoke\media
   ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=blue:size=320x180:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 1.5 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 128k -shortest build\headless-smoke\media\base-av.mp4
   ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=red:size=160x90:rate=30" -t 1.2 -an -c:v libx264 -preset ultrafast -pix_fmt yuv420p build\headless-smoke\media\overlay.mp4
   ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=523.25:sample_rate=48000" -t 1.5 -c:a libmp3lame -q:a 4 build\headless-smoke\media\audio.mp3
   ```
2. Compile with the Windows system libs (Linux uses `-L-ldl` instead):
   ```
   dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source tests\editor_smoke.d -of=build\headless-smoke\editor-smoke.exe -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32 -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet
   ```
   (`dmd` uses `-version=X`, not `-d-version=X`; missing system libs surface as
   `lld-link: undefined symbol: IsClipboardFormatAvailable/GetClipboardData/...`.)
3. Run:
   ```
   set AURORA_RENDERER=software&& set SDL_AUDIODRIVER=dummy&& build\headless-smoke\editor-smoke.exe build\headless-smoke\media\base-av.mp4 build\headless-smoke\media\overlay.mp4 build\headless-smoke\media\audio.mp3
   ```
   Pass = prints `Aurora Cut multi-track editor smoke test passed.`

### Other smoke tests
- `model_smoke.d` and `gpu_decode_args_smoke.d` need no args; compile with the
  same `dmd -i -Isource -Ivendor\aurora-d-0.4.5\source` + system libs flags.
- `export_smoke.d` takes `<base-av.mp4> <overlay.mp4> <extra.mp3> <output-dir>`.
- Linux CI path: `scripts/verify-headless.sh`, `scripts/verify-export.sh`.

### Context menu / resolution feature notes (2026-08-10)
- Right-click a timeline video item -> "Set sequence resolution to NxN" matches
  the composition/output resolution to that item's source canvas (crop-aware).
- MP4 export uses the composition canvas, so output follows the sequence
  resolution automatically; the Preview quality control (720/1080/1440/2160)
  only caps the on-screen decode size for responsiveness.
- Covered by editor_smoke.d: menu wiring on V1 (320x180) and overlay (160x90)
  clips, plus the shared action via `matchClipResolutionForTesting`.

### Move-to-track dialog (2026-08-13)
- Timeline clip context menu has ONE `Move to track…` item instead of a
  per-lane `Move to V1/V2/…` list, but keeps the direct
  `Move to new video track` / `Move to new audio track` commands (user
  requested they stay in the context menu).
  `openMoveToTrackDialog` in `source/auroracut/editor.d` opens a centered
  `PopupOverlay` (`move-to-track-popup`, 360x420) with a `ListView`
  (`move-to-track-list`) listing every compatible destination: video tracks +
  `New video track` when the asset has video (or for text clips), audio tracks
  + `New audio track` when it has audio. The clip's current track row is
  disabled and the first enabled row is preselected. `Move`
  (`move-to-track-apply`) or Enter/double-click moves via
  `moveSelectedToTrack` (existing selection+move path; `ensureTrack` appends
  new lanes).
- Text clips (no media asset) get the move section too (`Move to track…` +
  `Move to new video track`, video-track layers only); previously they showed
  none. Verified with a throwaway real-GUI probe (`tests/menu_probe.d`, since
  deleted) that dumps the full context menu: media clip = all three move
  commands, text clip = the two video ones.
- How to test interactively: right-click a timeline clip -> `Move to track…` ->
  pick a row -> Move; the clip relocates and the status shows
  `Moved clip to Vn at …`.
- Covered by `tests/editor_smoke.d`: menu shows `Move to track…` + `Move to
  new video track` (no `Move to V1/V2`, no `Move to new audio track` for the
  video-only overlay), dialog lists `V1/V2/V3(disabled)/New video track` for
  the video-only overlay, move to V2 and back through the same dialog restores
  the clip on V3, a text clip menu shows `Move to track…` + `Move to new video
  track` (no audio move), and the long-menu wheel-scroll assertion still runs
  on a reopened menu. Menu-row clicks use `menuItemPoint(menu, label)` which
  maps a label to its row center accounting for separators (4px) vs rows
  (22px).

## Aurora Image Viewer (aurora-image-viewer)

Standalone viewer in `aurora-image-viewer/`. **No FFmpeg dependency** — decode
is pure D: PNG (Aurora-D built-in), BMP (24/32/16/8/4/1 bpp, BITFIELDS, RLE8/RLE4),
TGA (truecolor/gray/colormap, RLE, 16/24/32/8 bpp), PNM (P2/P3/P5/P6/P7), and
GIF (first frame, LZW, interlace, transparency). Rendering is a custom
mipmapped CPU scaler in `source/auroraimageviewer/scaler.d`: it picks the mip
level closest to screen scale and bilinear-samples only that level, so zooming
out on huge images is fast and aliasing-free. The ImageView widget is an
opaque retained compositor layer; pan/zoom re-render a reusable viewport RGB
buffer each paint.

### Build the app
```
cd aurora-image-viewer
dub build --force
```
Result: `aurora-image-viewer/aurora-image-viewer.exe` (GUI subsystem, no
console window). Run with `RUN-WINDOWS.bat` or `RUN-WINDOWS-SOFTWARE.bat`
(software renderer). CLI: pass an image path to open it directly.

### Headless smoke test (headless_smoke.d)
No media generation needed — the test writes its own PNG/BMP/TGA/PPM/PAM/GIF
files with pure D (std.zlib for PNG), so it also exercises the decoders
without any external tools.

```
cd aurora-image-viewer
dmd -version=AuroraHeadless -i -Isource -I..\vendor\aurora-d-0.4.5\source tests\headless_smoke.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\headless-smoke.exe
build\headless-smoke.exe
```
Pass = prints `Aurora Image Viewer headless smoke test passed.`
Coverage: scaler pyramid dimensions + 100%/50% render correctness, letterbox,
negative-offset panning, alpha-over-checker compositing, all decoders, and a
UI pass driving wheel zoom / fit / drag-pan / file drop / actual-size and
saving a screenshot PPM.

### Screenshot mode
`aurora-image-viewer.exe --screenshot <image> <out.ppm>` renders the default
window (fit zoom) headlessly and writes a PPM. Verify by converting to PNG:
`ffmpeg -i out.ppm out.png` (ffmpeg only needed for this local visual check,
not by the app).

### Key scaler details / gotchas
- Mip levels stop when min(w,h) <= 8; box-averaged with premultiplied alpha.
- Level pick keeps per-dest level zoom in [1,2) so bilinear never skips data.
- Fixed-point 32.32 sampling mirrors the software renderer, so exact-size
  blits are row copies.
- Letterbox is a solid color; transparency composites over an anchored
  16px checkerboard inside the image region only.
- D gotchas hit while building: `out` is a D keyword (use `output`/`buf`),
  `byte` is a D keyword (use `packedByte`), dmd uses `-version=X` (not
  `-d-version=X`), and system libs must be passed as `user32.lib ...` file
  args to lld-link (dub passes them automatically).
- Previous ffmpeg-based decode crashed inside the worker thread during the
  UI drop test; removing the subprocess path (standalone decode) fixed it.
