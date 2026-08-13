# Aurora Cut todo / complaints log

## 2026-08-13 — Aurora Cut: snap timeline items to playhead and other vertical markers
- [x] User: introduce the ability for timeline items to snap to the playhead or
      other vertical markers in the timeline.
- [x] Playhead + sequence start snapping already existed; extended to the other
      vertical markers in `source/auroracut/timeline.d`:
      - Work-area **In** marker (blue) and **Out** marker (orange) are now snap
        targets for both a clip's start edge and its tail edge (`snappedStart`)
        and for edge-resize previews (`snappedEdge`).
      - Clip edges on **every** track (cross-track), not only the destination
        row, are snap targets. `forEachNearbyClipMarker` scans each sorted
        track with a small binary-search window so long tracks stay responsive.
      - While a drag is snapped, a bright white guide rule is painted at the
        marker via `_snapGuideTime` + `drawSnapGuide`; it clears on mouse-up,
        Escape, and ghost clear. (At the playhead's own X the composited red
        playhead layer paints above the base guide, which is fine because the
        playhead line itself is the cue.)
- [x] Covered by `tests/editor_smoke.d`: In/Out marker snapping (start, tail,
      edge resize), cross-track clip-edge snapping (start, tail, edge resize),
      and a live drag that verifies `snapGuideTimeForTesting` points at the In
      marker, that a bright guide pixel is painted, and that the guide clears
      on mouse-up.
- [x] Verified: `dmd -i -version=AuroraHeadless ...` compile + run of
      `tests/editor_smoke.d` (passes) and `tests/layout_smoke.d` (passes) on
      Windows.

## 2026-08-13 — Aurora Cut: timeline rows appear over the ruler while scrolling
- [x] User: after the scrollbar became draggable, timeline rows appear above
      other UI when scrolling up/down the timeline with the scrollbar.
- [x] Diagnosed with a headless pixel probe (render → `savePpm` → scan rows):
      the change on scroll was confined to the timeline region (rows are clipped
      to the widget bounds), but a partially scrolled top row painted over the
      ruler band because `onPaint` draws the ruler before the tracks and only
      skips rows that are fully above the ruler.
- [x] Fixed in `source/auroracut/timeline.d`: track painting now uses a canvas
      clipped to the region below the ruler, so a partially scrolled row is cut
      off at the ruler's bottom edge instead of covering it.
- [x] Covered by `tests/editor_smoke.d`: a 6-track fixture is scrolled to the
      bottom via the vertical scrollbar, rendered standalone, and asserted to
      keep the ruler band free of any track-row color. The new assertion fails
      on the pre-fix code (verified) and passes with the fix.

## 2026-08-13 — Aurora Cut: timeline vertical scrollbar is too thin and not draggable
- [x] User: the timeline's vertical scrollbar is basically unusable — too thin
      and there is no way to grab it, so moving up/down the timeline only works
      with the mouse wheel.
- [x] Fixed in `source/auroracut/timeline.d`: widened the right-edge scrollbar
      from 4px to a 12px track with an opaque background and a left border, and
      made it a real input target. Left-click on the thumb drags the timeline
      vertically; a click on the track jumps the thumb to the pointer; hover
      shows the `hand` cursor; Escape cancels an active drag.
- [x] Covered by `tests/editor_smoke.d` (new vertical-scrollbar drag block: wide
      track, drag-to-bottom reaches `maxVerticalScrollForTesting`, mouse-up
      exits drag mode).
- [x] While fixing the smoke suite, two pre-existing stale failures were also
      repaired and verified against the clean base commit (both reproduce on
      HEAD before any of these changes):
      - `tests/editor_smoke.d` ListView scrollbar block: it asserted drag mode
        from a track click, but the vendored `Scrollbar` pages on a track click
        and drags only from the thumb. Rewritten to drive the thumb directly.
      - `tests/layout_smoke.d`: `status-progress` id was missing on the editor
        status-bar `ProgressBar` (restored in `source/auroracut/editor.d`), and
        the "centered" assertion never matched the anchor-right layout;
        renamed to `assertStatusProgressDocked`.
- [x] Verified: `dmd -i -version=AuroraHeadless ...` compile + run of
      `tests/editor_smoke.d` (passes, prints the final "smoke test passed"
      line) and `tests/layout_smoke.d` (passes) on Windows.

## 2026-08-12 — Aurora Cut: RUN-WINDOWS.bat exits immediately with "Program exited with code 1"
- [x] User: `RUN-WINDOWS.bat` builds and prints all startup stages then exits
      with `Error Program exited with code 1`; the editor window never stays.
- [x] Root cause: aurora-cut links as the Windows GUI subsystem
      (`/SUBSYSTEM:WINDOWS`), so when launched with no attached console
      (double-click, or a detached process) the CRT `stderr` handle is invalid.
      `reportStage` in `source/app.d` called `stderr.writeln(...)` on that
      invalid handle, which throws `StdioException`; `main`'s `catch
      (Throwable)` then tried `stderr.writeln(details)` and threw again, so the
      error escaped main entirely → the D runtime reported "Program exited
      with code 1" and never wrote `aurora-cut-startup.log` (diagnostic marker
      confirmed `main` entered but no catch message was ever logged).
- [x] Fixed with `safeStderrWriteln`: only writes to stderr when a console is
      actually attached (`GetStdHandle(STD_ERROR_HANDLE)`), otherwise skips,
      and wraps the write in try/catch. `reportStage` and main's error handler
      now use it, so a console-less launch starts the editor instead of dying
      on the first log line.
- [x] Verified: `aurora-cut.exe` launched detached stays ALIVE (was EXITED 1);
      `RUN-WINDOWS.bat` leaves aurora-cut running; both aurora-stream
      `application` + `titlebar` builds unaffected; aurora-cut `dub test`
      (33 modules) and aurora-stream `dub test` (38 modules) pass.

## 2026-08-12 — Aurora Stream: titlebar app crashed/disappeared on Start streaming (canvas mode)
- [x] User: pressing **Start streaming** with the Aurora program canvas enabled
      both popped up a stray command prompt and crashed/disappeared the whole
      app (aurora-stream-titlebar.exe, access violation 0xc0000005 at the same
      RVA in two dumps).
- [x] Console: `app_titlebar.d` had its own `main()`/`isDiagnosticCommand()` that
      still listed `--audio-rtp-helper`, so the WASAPI helper spawned with
      `Config.suppressConsole` still called `AllocConsole()` → stray prompt.
      Removed `--audio-rtp-helper` there too (app.d had the same fix earlier).
- [x] Crash: WER + minidump analysis (two dumps, deterministic RVA `0x12fe9`)
      located the fault in `std.stdio.File.rawWrite` (the "Wrote ... ubyte"
      errnoEnforce string) called only from `BroadcastWorker.runCanvasPump`.
      The phobos `File` object was passed across the thread boundary into the
      pump thread closure; `File` is @system with a heap-allocated, manually
      refcounted `_p` (Impl*) and can be seen with a null/garbage `_p` by the
      time `rawWrite` dereferences it.
- [x] Fixed by passing only the raw file descriptor (`pipes.stdin.fileno()`,
      an `int`) into the pump thread; the pump now builds its own `File` from
      the fd (`stdin.fdopen(stdinFd, "wb")`), so no phobos `File` object is
      shared across threads and `rawWrite` always sees a valid `_p`.
- [x] Verified: `dub test` 38 modules pass; `broadcast-model-smoke.exe` exit 0;
      both `application` and `titlebar` configs build; the titlebar app
      launches with its window and stays up; a standalone repro of the exact
      fd-based pump runs clean.

## 2026-08-12 — Aurora Stream: stray command prompt on Start streaming
- [x] User: pressing **Start streaming** opened a separate command prompt.
      Root cause: the broadcaster spawns the isolated WASAPI RTP helper as
      `aurora-stream.exe --audio-rtp-helper ...` with `Config.suppressConsole`
      (CREATE_NO_WINDOW), but `app.d`'s `isDiagnosticCommand()` listed
      `--audio-rtp-helper` and `main()` called `attachDiagnosticConsole()` →
      `AllocConsole()`, which created a visible console window for every
      stream start. The helper only communicates through status/metrics files
      and UDP (no stdout), so the console was useless.
- [x] Fixed by removing `--audio-rtp-helper` from `isDiagnosticCommand()`.
      Manual diagnostics that write to stdout (`--version`,
      `--list-audio-endpoints-json`, `--audio-bridge-session-test`,
      `--pacing-test`) still allocate a console on demand as before.
- [x] Verified with a GUI-subsystem probe: ffmpeg spawned exactly like the
      broadcast worker (`pipeProcess(..., Config.suppressConsole)`) has
      `MainWindowHandle=0` (no window); the audio helper spawned the same way
      has `MainWindowHandle=0` after the fix. `dub test` (38 modules) and both
      `application` + `titlebar` builds pass; the app launches with its window
      and no extra console.

## 2026-08-12 — Aurora Stream: Aurora-rendered program canvas (roadmap item)
- [x] Implemented the roadmap's "Aurora-rendered program canvas": Aurora now
      composites color/image/text sources into the common source canvas,
      replacing direct desktop capture while keeping the independent
      Twitch/YouTube output profiles.
- [x] New `source/aurorastream/programcanvas.d`: `ProgramSource` model
      (normalized rects, opacity, visibility), `paintProgramCanvas` compositor
      (works for both widget draw-list canvases and worker surface canvases),
      live `ProgramCanvasPreview` widget, compact `ProgramCanvasEditor` with
      add color/image/text + reorder + opacity + visibility, and JSON
      serialization.
- [x] Broadcast integration: `BroadcastSettings` gained `programCanvasEnabled`
      + `programCanvasSources`; `captureArguments` emits
      `-f rawvideo -pix_fmt bgra -s WxH -framerate 60 -i pipe:0` instead of
      ddagrab/gdigrab; `BroadcastWorker.run` spawns FFmpeg with stdin redirect
      in canvas mode and a dedicated paced frame-pump thread writes rendered
      BGRA frames; zero-copy D3D11 path and `videoPipelineLabel` are bypassed
      for canvas mode; the pacing diagnostic forces desktop capture.
- [x] UI: live **LIVE SOURCE CANVAS** preview panel + Program canvas settings
      section with the source editor; controls disable while streaming.
- [x] Settings schema 5 persists canvas state.
- [x] Verified: 38 modules pass `dub test` (incl. new programcanvas unittests),
      `broadcast-model-smoke.exe` passes new canvas-mode argument assertions,
      both `application` and `titlebar` configs build, the app launches and
      stays up.

## 2026-08-12 — GUI-subsystem apps must not write to stdout at runtime (crash)
- [x] User: double-clicking the titlebar to maximize shut down the whole app.
      Root cause: after switching aurora-stream to GUI-subsystem (no console), a
      `writeln` on the maximize action wrote to invalid stdout and crashed
      (verified with a minimal GUI-subsystem test: `writeln` without a console
      exits 1). Removed all GUI-path `writeln` calls from the titlebar variant
      (minimize/maximize/restore messages) and dropped the `stderr.writeln` in
      the startup catch (the file+MessageBox `recordStartupFailure` already
      reports). Only the `--version`/diagnostic paths still write, and only
      after `AllocConsole`.
- [x] Verified: aurora-stream `application` + `titlebar` configs build; the
      titlebar variant launches and stays up; no runtime stdout writes remain.

## 2026-08-12 — Enforce Windows GUI-subsystem for all Aurora windowed apps
- [x] Added `scripts/verify-windows-gui-subsystem.py` (top-level policy check,
      wired into the portable-windows CI workflow) that requires every DUB
      configuration whose main source constructs a `GuiWindow` to link with
      `lflags-windows: ["/SUBSYSTEM:WINDOWS", "/ENTRY:mainCRTStartup"]`.
      Headless test configs (`AuroraHeadless`) stay console for their stdout.
- [x] Applied the rule to every windowed app: aurora-cut, aurora-stream
      (`application` + `titlebar`), and the aurora-d demos (notepad,
      file-explorer, windows-file-manager, desktop, taskbar, titlebar,
      font-gallery). CLI diagnostics in aurora-cut/aurora-stream now allocate a
      console on demand (`AllocConsole` + `freopen`) for `--version` etc.
- [x] Rationale: a console-subsystem GUI app opens a console window on
      double-click that steals the taskbar button (exe-path title, no icon).
      GUI-subsystem keeps only the real window (with its icon) in the taskbar.
- [x] Verified: `python scripts/verify-windows-gui-subsystem.py` passes for all
      manifests; aurora unittest suite (30 modules), editor smoke, titlebar
      smoke, and aurora-cut + both aurora-stream + vendor demo builds all pass.

## 2026-08-12 — Aurora Stream custom-titlebar variant + taskbar icon (user request)
- [x] Added a separate `titlebar` dub configuration in aurora-stream (default
      `application` config untouched) with a frameless window wrapping the
      unchanged `StreamRoot` under the reusable `TitleBar` widget. New main
      `source/app_titlebar.d`, shared CLI helpers
      `source/aurorastream/entry.d`, launcher `RUN-WINDOWS-TITLEBAR.bat`.
- [x] `aurora.image` gained `loadIcoImage`/`decodeIcoImage` (parses the ICO
      container little-endian, decodes PNG-compressed and classic 24/32/8-bit
      BMP entries with AND-mask transparency); `TitleBar.setIconImage(RgbaImage)`
      shows a raster icon; the titlebar variant displays the real
      `aurora-stream.ico`.
- [x] Taskbar icon root cause: aurora-stream was console-subsystem, so
      double-clicking spawned a console window that took the taskbar slot with
      the exe-path title and no icon. Fixed by making the `titlebar` build
      GUI-subsystem (`/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup`, like
      aurora-opencode); the CLI diagnostics now allocate a console on demand
      (`AllocConsole`). The window/class icons are set (WM_SETICON +
      SetClassLongPtr GCLP_HICON/HICONSM) and re-applied after show via a
      one-shot timer.
- [x] Verified: aurora unittest suite (30 modules), titlebar smoke, both
      aurora-stream configs build; the titlebar variant launches with no console
      and shows the taskbar icon.

## 2026-08-12 — ffmpeg is 300MB and cannot be redistributed with the app
- [x] Diagnosed: the app only needs a small subset of ffmpeg; the 300MB build
      is the gyan.dev full build (236 encoders / 538 decoders / 555 filters).
- [x] Checked prebuilt alternatives (no trimming needed): gyan essentials
      33MB .7z but "contains all internal components" + 34 libs; BtbN win64
      lgpl-shared ~47MB zip. None are genuinely small. Verified via gyan.dev
      and the BtbN GitHub releases API.
- [x] Decided against installing a local toolchain (WSL + mingw) — user called
      it "a mess". Instead wrote a GitHub Actions workflow that cross-compiles
      a trimmed static ffmpeg.exe + ffprobe.exe on ubuntu runners (zero local
      setup), targeting ~15-30MB total.
- [x] Added `scripts/build-minimal-ffmpeg-win64.sh` (builds zlib, x264, lame,
      dav1d, nv-codec-headers, then ffmpeg n8.1 with --disable-everything and
      only Aurora Cut's codecs/filters; optional WINE smoke test using the
      verify-export.sh clip commands). Every encoder/decoder/filter/muxer/
      protocol name in the script was verified against the installed ffmpeg
      component lists.
- [x] Added `.github/workflows/minimal-ffmpeg.yml` (workflow_dispatch; builds,
      runs wine smoke test, verifies inventory, uploads artifact).
- [x] CI iteration fixed: postproc removed in ffmpeg 8.x (dropped the flag),
      libx264 needs --enable-gpl, dav1d + ffnvcodec + libvpl need their .pc
      dirs in PKG_CONFIG_LIBDIR, and h264_nvenc must use nv-codec-headers
      pinned to n12.2.72.0 (ffmpeg n8.1's nvenc.c uses countingType, renamed
      to countingTypeLSB in n13.1).
- [x] GPU-encode capability is preserved in the minimal build, matching the
      full build: h264_nvenc (NVIDIA), h264_qsv (Intel, via cross-built
      libvpl/oneVPL) and h264_amf (AMD, header-only SDK) are all enabled
      because media.d probes nvenc -> qsv -> amf as primary encoders before
      libx264. Decode hwaccels d3d11va + dxva2 are included; cuda decode is
      omitted (d3d11va already covers NVIDIA decode, probed first).
- [ ] Not yet run successfully: workflow must be triggered from the Actions tab.
      Expected artifact: `ffmpeg-minimal-win64` (~15-30MB) containing
      ffmpeg.exe + ffprobe.exe. Verify in the running GUI: import/playback,
      MP4 + MP3 export, GPU encode fallback, yt-dlp normalization.
- [ ] Not yet decided: whether the app ships the minimal build in `vendor/`
      and stops requiring ffmpeg on PATH; aurora-stream's extra needs
      (ddagrab, fifo, udp/rtp/sdp, flv) would need a second configure.
- [ ] Not yet verified: whether `-hwaccel d3d11va/dxva2` and `h264_nvenc`
      actually work in the trimmed build (they are compiled in, but only the
      wine smoke test ran on CI without a GPU).

## 2026-08-12 — Titlebar: no custom cursor + centered search text (user feedback)
- [x] "I don't like how we use custom cursor": during titlebar drags the
      synchronized-pointer path hid the native cursor and drew Aurora's vector
      cursor. The demo now sets `WindowOptions.synchronizedDragPointer = false`
      so the native pointer stays visible during drags (the synchronized cursor
      is meant for dragging retained compositor layers, not native window
      moves).
- [x] "make sure to center 'Search clips, tracks, effects…'": added
      `TextEditor.setContentCentered(bool)` — single-line content that fits the
      viewport is centered (paint, caret, selection, and hit-testing all use
      the same `contentOriginX`), overflowing text falls back to normal
      scrolling. The demo search box now uses an empty `TextField` with a
      centered grey placeholder.
- [x] titlebar smoke, module unittests, full aurora suite, demo + app builds
      all pass.

## 2026-08-12 — Titlebar drag: black window, snap white border, window shake (user feedback)
- [x] "while dragging the entire window becomes black": the OS caption move
      loop (`beginSystemMove`, `WM_NCLBUTTONDOWN HTCAPTION`) on a frameless
      `WS_POPUP|WS_THICKFRAME` window runs a modal loop that arms the resize
      proxy; the proxy snapshot ALIASED the software renderer's live surface,
      which `_renderer.resize` then reallocates in place → stale/garbage
      frames (black). Fixed: `refreshResizeProxyFromScene` now COPIES the
      renderer surface's pixels into the privately-owned `_resizeSnapshot`
      instead of aliasing.
- [x] "drag to top, release, white border appears above then resolves": the OS
      caption loop triggers aero-snap maximize, which flashes the native
      (system-light) frame. The demo no longer uses the OS move loop: it now
      drags owner-side via `onDragStarted`/`onDragMoved` +
      `GuiWindow.setWindowPosition` (SetWindowPos), so no snap artifacts.
- [x] "entire window and program shaking while dragging": the owner-driven drag
      originally mixed Aurora's window-relative pointer positions with screen
      bounds, so after each SetWindowPos the synthesized WM_MOUSEMOVE in the
      moved window produced a different absolute position → the window hunted
      between two spots. Fixed by dragging with the pointer DELTA from the drag
      start (`windowOrigin + (pointer − startPointer)`); deltas are identical
      in window-relative and screen space, so the feedback loop closes with
      zero delta.
- [x] Verified: titlebar smoke, module unittests, full aurora suite (30
      modules), demo + aurora-cut builds all pass.

## 2026-08-12 — Titlebar: drag down to exit maximized state (user request)
- [x] User: "Do you think we could make it possible to click and drag down to
      enter off the maximized state."
- [x] `TitleBar` now restores-on-drag: press the title while maximized and
      drag past the 5px threshold → fires `onRestoreRequested(pointer,
      pressPointer)`, clears the bar's maximized state, re-anchors the drag to
      the current pointer/position, and keeps moving. Works for in-canvas
      (self/owner) drags and native system move (`systemMoveOnDrag`), where the
      OS move loop is now deferred until real movement when maximized so the
      owner can restore first.
- [x] Added `NativeWindow.setWindowPosition(Point)` +
      `GuiWindow.setWindowPosition` (Win32 `SetWindowPos`; headless/base return
      false). The demo's `restoreFromDrag` exits fullscreen and re-anchors the
      window so the grabbed titlebar spot stays under the pointer before the
      OS move loop resumes.
- [x] Smoke test covers restore-on-drag for both in-canvas self-move
      (re-anchor math asserted) and system-move modes; module unittests, full
      aurora suite, demo + desktop + aurora-cut builds all pass.

## 2026-08-12 — Titlebar double-click maximize + random white border (user feedback)
- [x] User: "Double clicking the titlebar does not make it maximize." Root
      cause: in `TitleBar.onMouseDown` the `systemMoveOnDrag` branch ran before
      the double-click branch, so the second press of a double-click started
      another native move loop instead of maximizing. Reordered (double-click
      wins) and dropped the stale logical capture around `beginSystemMove`
      (the OS caption loop owns capture and swallows the mouse-up). Regression
      test added: double-click still maximizes/restores with
      `systemMoveOnDrag` enabled.
- [x] User: "we have some weird stuff where a white rectangular border
      surrounds the window randomly… appears when I click and it gains focus…
      sometimes gets stuck… random white border blink." Root cause: frameless
      resizable windows are `WS_POPUP | WS_THICKFRAME`; DWM draws a 1px frame
      which was styled with the system-LIGHT theme (white) because
      `applyDarkTitleBar` only ran for decorated windows, and it repainted on
      activation changes. Fixed in `aurora.platform.win32`: apply the dark DWM
      frame attributes whenever `darkTitleBar` is set or the window is
      frameless, and return `TRUE` from `WM_NCACTIVATE` for frameless windows
      so DWM never repaints the frame on activation changes.
- [x] All verification passes: titlebar smoke, module unittests, full aurora
      suite (30 modules), demo + aurora-cut builds.

## 2026-08-12 — Native tools are the main; Legacy tools moved to Settings with tooltip (user request)
- [x] User: "Let's have Tools named as Legacy Tools and move into settings as
      separate option in the settings with a tooltip. Native tools are the
      main now."
- [x] The toolbar now has a single "Tools" checkbox (native D tools) that is
      ON by default. The legacy bash/cmd/powershell shell tool is no longer in
      the toolbar.
- [x] Added a "Legacy tools" checkbox in Settings with a "(?)" hover tooltip
      explaining it adds the shell tool on top of the native tools. New
      `Settings.legacyTools` bool (default off); old `nativeTools` setting is
      migrated (native-only users get legacy off).
- [x] Tool selection: tools on → native tool set; tools on + legacy → native +
      shell (builtin). System prompt reflects the mode. Covered by the Pro
      smoke test (checkbox + tooltip present, legacy off by default). Baseline
      + Pro debug/release builds pass.

## 2026-08-12 — Aurora GUI TitleBar widget, completely customizable (user request)
- [x] User: "I wonder if we could do aurora gui titlebar widget. A completely
      customizable titlebar. Let's try."
- [x] Added `aurora.widgets.titlebar.TitleBar`, exported from `aurora` package.
      Customizable: title/icon/show-icon/title-align, per-button show/hide and
      width, bar height, corner radius, all colors (background / inactive /
      border / text / muted / button hover / pressed / close hover / pressed),
      active & maximized states, drag behavior (in-canvas self-move, owner
      `onDragMoved`, or native OS move via `setSystemMoveOnDrag`), double-click
      maximize, right-click system menu (`onSystemMenu(Point)`), custom content
      widget slot + fixed title width.
- [x] Added `WidgetHost.beginSystemMove()` / `Widget.beginSystemMove()` so a
      frameless window's TitleBar can start the native OS move loop
      (`GuiWindow` already had the method, now an override).
- [x] Added `demos/titlebar.d` (frameless window demo) + `titlebar` dub config
      + `RUN-AURORA-D-TITLEBAR.cmd`. Builds with `dub build --config=titlebar`.
- [x] Added `tests/titlebar_smoke.d` headless smoke test (caption buttons,
      double-click, system menu, self/owner drag, customization, hover) with
      pixel-verified screenshots (titlebar background, window background, close
      hover = danger). Module unittests + full aurora unittest suite (30
      modules) + `dub build` of aurora-cut all pass.
- [ ] Not yet manually launched as a real window by the user (demo + visual
      drag feel need a human check).

## 2026-08-12 — Duplicate message Copy button (user feedback)
- [x] User: "we have copy button for messages in the context menu, then why we
      have duplicate copy on the right side for each message." Removed the
      per-message "Copy" pill (top-right of every bubble); Copy now lives only
      in the right-click context menu. Code-block copy pills remain (they copy
      just the code, distinct from the message).

## 2026-08-12 — Empty tool-call wrapper bubble still visible (user complaint)
- [x] User: "you removed [the pill/tokens] but the ui empty bubbles are still
      there." The assistant message that requested tools rendered as an empty
      gray bubble when it had no content or reasoning.
- [x] Tool-call wrappers (assistant + toolCalls + no content/reasoning) are now
      hidden: they keep their slot (index mapping intact) but measure to zero
      height and paint nothing. `handleToolCalls` rebuilds the column so the
      wrapper re-renders hidden; `rebuildMessageColumn` hides wrappers on
      restore too.
- [x] Verified: wrapper bubble height = 0, hidden = true, no pill, no usage.
      Covered by the Pro smoke test; baseline + Pro debug/release builds pass.

## 2026-08-12 — Tool-call wrapper showed Regenerate + token count (user complaint)
- [x] User: "the ui of regenerate and tokens item appears after each tool call,
      fix it it should not be there." The assistant message that merely
      requested tools (the tool-call wrapper) kept the streamed usage text and
      sometimes a Regenerate pill, appearing as a spurious footer item.
- [x] Tool-call wrappers (assistant role + `toolCalls` + empty content) are now
      excluded from the action pill and from token-usage display. `handleToolCalls`
      clears the wrapper's usage text when it finalizes, `refreshBubbleActions`
      skips wrappers, and rebuild only attaches usage to the latest real reply.
- [x] Covered by the Pro smoke test: after a tool loop, every assistant wrapper
      has no pill and no usage text. Baseline + Pro debug/release builds and
      all tests pass.

## 2026-08-12 — Only latest reply shows Regenerate + token count; right-click menu (user request)
- [x] User: "why we have separate chat items of having regenerate button and
      amount of tokens to the right side" — every bubble showed a pill + usage.
- [x] Only the latest assistant reply now shows the action pill (Regenerate,
      or Retry when failed) and the token-usage footer. Older bubbles are
      clean.
- [x] Right-click on any message now opens a context menu with Copy message
      and, depending on role, Regenerate (assistant) or Edit & resend (user).
      The right-click edit path was previously only wired to user messages.
- [x] Covered by the Pro smoke test: pills only on the latest assistant reply,
      and context-menu Edit & resend targets the right message (no foreach
      capture bug). Baseline + Pro debug/release builds and all tests pass.

## 2026-08-12 — First answer "feels smarter" in original opencode (user feedback)
- [x] User: "in the original opencode, the first answer to prompt always feels
      better… it starts with git log, then grouped ('Explored 2 reads')… our
      implementation just spam random shell commands."
- [x] Root cause found by reading opencode's source: its system prompt is a
      full behavior spec — identity, tone/style contract, an ENVIRONMENT block
      (working directory, "Is directory a git repo: yes/no", platform, today's
      date), a tool-usage policy, and "think about the task before beginning".
      Our old prompt was a 2-line nudge, so the model improvised and spammed
      shell commands.
- [x] Replaced `toolSteeringPrompt` with `buildSystemPrompt(nativeOnly,
      workspace, platform)` mirroring opencode's structure: identity, `<env>`
      block with git-repo detection + real date, tone/style, tool policy, and
      "think before beginning" guidance.
- [x] Verified live in the real repo: default mode now does `dshell where` →
      `dshell list` → reads → `bash git log` + `git status` (like opencode);
      native mode does `dshell where` + `run git status` + `dshell list` in
      parallel and finishes in 3 rounds. No more random shell spam. All tests
      and baseline + Pro debug/release builds pass.

## 2026-08-12 — Console window flashes on every tool call (user complaint)
- [x] User: "another window is being opened on execution of dshell or maybe
      something else." Root cause: `runProcess` called `spawnProcess` with
      `Config.none`, so Windows created a console window for the child
      (cmd.exe / powershell.exe / the run target) on every bash/run/dshell
      call — a visible flash.
- [x] Fixed with `Config.suppressConsole` (CREATE_NO_WINDOW on Windows), so
      child processes run headless with no flash. Tools test (bash/run/dshell)
      and Pro smoke pass with the change; baseline + Pro debug/release builds
      pass.

## 2026-08-12 — Runaway tool loop ("where we are at" looped until the limit) (user complaint)
- [x] User: asked "where we are at" and the app kept doing tool calls until it
      hit the round limit. Reproduced the intermittent loop in probes: the
      model sometimes keeps calling list/read without settling on an answer.
- [x] The original opencode handles this with a `doom_loop` recovery: when the
      SAME tool call repeats with identical input 3 times, it stops and asks
      the user. Our previous behavior just hit a hard 12-round cap and stopped
      with a status line — no final answer.
- [x] Implemented doom-loop recovery: repeated identical tool-call signatures
      are tracked; after 3 identical repeats the loop breaks and a recovery
      message is injected asking the model to answer directly with what it has
      learned. The 12-round cap now also injects a final "stop and answer"
      message instead of silently stopping.
- [x] Covered by the Pro smoke test: three identical tool injections accumulate
      a repeat count and the third triggers the recovery message. Baseline +
      Pro debug/release builds and all tests pass.

## 2026-08-12 — Collapse thinking visually with animated progress (user request)
- [x] Studied the original opencode app: the web app renders reasoning as a
      plain streamed text part (`PacedMarkdown`) behind a `showReasoningSummaries`
      toggle (/thinking in the TUI hides/shows thinking blocks); tools render
      as collapsible cards. No full-spinner animation — the closest is a
      typing reveal and shimmer on running tool titles.
- [x] Implemented the same pattern: thinking/reasoning now renders as a slim
      collapsed header `▸ Thinking` (muted, clickable, same style as the tool
      headers), with the full reasoning text shown only when expanded. While
      the assistant is still working the header shows an animated pulsing
      `▌/▐` indicator (advanced every frame by the root tick, repainting only
      on phase change). When the answer arrives the indicator freezes.
- [x] Verified by Pro smoke test: thinking blocks start collapsed, expand and
      collapse on toggle. Baseline + Pro debug/release builds and all tests
      pass.

## 2026-08-12 — Tool collapse UX: no scroll jump + command/output in one element (user feedback)
- [x] User: "clicking it scrolls me down to the bottom of chat" and "command
      and output should be under singular ui element, you click and you see
      output, click again it hides".
- [x] Fixed the scroll jump: the `onSizeChanged` handler was forcing
      `_messagesScroll.follow = true`, which snapped to the bottom on every
      expand/collapse. It now only invalidates the column + scroll so the
      viewport is preserved. Regression: scroll up, expand, assert the offset
      stays put.
- [x] Reworked the tool result bubble into ONE element: a header showing the
      command (`▸ ⚙ name(args)`, args parsed from the JSON and compacted) that
      is always visible, with the output below it shown only when expanded
      (▸/▾ indicator). Removed the separate tool-call chips from assistant
      bubbles (the command now lives in the result header). `toolArgs` is
      persisted so restored sessions render the command too.
- [x] Verified by Pro smoke test: tool bubbles start collapsed, expand and
      collapse, and preserve scroll position. Baseline + Pro debug/release
      builds and all tests pass.

## 2026-08-12 — Collapse tool-use outputs by default, click to expand (user request)
- [x] Tool result bubbles (`tool` role) now start collapsed: a compact header
      pill shows "⚙ <name> · <first line of output> ▾" instead of the full
      (often large) output.
- [x] Clicking the header expands the full output; clicking again collapses.
      The bubble fires `onSizeChanged`, the message column re-lays out, and the
      scroll view re-measures and re-follows, so expanding a big listing
      doesn't jump the viewport.
- [x] Collapsed state is per-bubble and not persisted (always starts collapsed
      on rebuild); restored sessions render collapsed too.
- [x] Verified by the Pro headless smoke test: tool bubbles start collapsed,
      toggle open and closed with repaint + reflow. Baseline + Pro debug/release
      builds and all tests pass.

## 2026-08-12 — Model still reached for legacy words (pwd/ls/stat); advertise only natural words (user feedback)
- [x] User asked "where we are now?" and saw `where`, `list`, and `pwd`. The
      `pwd`/`ls`/`stat` were reaching the model because the dshell tool
      DESCRIPTION taught the aliases ("where prints the workspace path (alias
      `pwd`)") and the JSON schema enum listed them as valid command values.
- [x] The advertised dshell schema now lists ONLY the natural words
      (`where`/`list`/`info`) and the description no longer mentions the
      legacy abbreviations. The dispatcher still accepts pwd/ls/dir/stat as a
      runtime safety net so calls never fail, but the model is no longer
      taught them.
- [x] Steering prompt explicitly says "Never use shell command words such as
      pwd, ls, dir, or stat".
- [x] Verified live: "where are we now?" now calls only `dshell where` (+ a
      helpful `list`), never `pwd`/`ls`, in both modes. Tools test asserts the
      advertised schema contains no legacy words. Baseline + Pro debug/release
      builds and smoke tests pass.

## 2026-08-12 — Tool output must be valid UTF-8 for session persistence (bug)
- [x] Found in the app log: `restore sessions failed: Invalid UTF-8 sequence`.
      The lenient OEM-codepage decode wrote bytes 0x80-0xFF directly into a
      `string` (invalid UTF-8 continuation bytes). When a tool result with
      those bytes (e.g. `dir`'s free-space comma) was persisted to
      `sessions.json`, the JSON was invalid UTF-8 and restore crashed on the
      next launch.
- [x] Fixed: the decode now maps each raw byte to its own `dchar` and UTF-8
      encodes it (`toUTF8`), so every tool output is always valid UTF-8 and
      safe to persist/restore. Verified `dir` output is valid UTF-8, the tools
      test validates it, and a clean app restart produces zero log errors.

## 2026-08-12 — dshell uses natural words, not legacy shell abbreviations (user feedback)
- [x] User: "our entire idea with dshell was to have short single words
      commands instead of legacy obscure letters made words for commands so
      it's easy to read in natural english language what is going on."
- [x] Reworked `dshell` so its canonical commands are natural English words:
      `where` (workspace path, was `pwd`), `list` (directory listing, was
      `ls`/`dir`), `info` (file/directory metadata, was `stat`). The legacy
      words (pwd/ls/dir/stat) still work as aliases so calls never fail.
- [x] Updated the tool description and the steering prompt to present the
      natural words; verified live that the model calls `dshell where` +
      `dshell list` (not pwd/ls). Tools test covers the natural words + alias
      fallback; baseline + Pro debug/release builds and smoke tests pass.

## 2026-08-12 — dshell: D-native replacement for pwd/ls/stat (user request)
- [x] User: "the last missing piece would be to have dshell so we don't use
      all these pwd and other commands." The model still reached for bash for
      plain directory introspection (pwd/ls/dir/stat) in default mode.
- [x] Added the D-native `dshell` tool: `pwd` (print workspace path), `ls`/`dir`
      (list a directory with `[f]`/`[d]` tags and sizes via `SpanMode.shallow`),
      and `stat` (file/directory type, size, modified time). Implemented
      entirely in D with `std.file` — no external shell is ever spawned.
- [x] `dshell` is advertised in BOTH the default and native-only toolsets, and
      the steering prompt tells the model to prefer it for pwd/ls/stat instead
      of bash/cmd/powershell.
- [x] Verified live (both modes): "where am I and what's in the workspace?"
      now calls `dshell pwd` + `dshell ls` then `read`, in 3 rounds with zero
      bash attempts; native mode uses `dshell ls` directly. Tools test covers
      dshell pwd/ls/stat + toolset membership; baseline + Pro debug/release
      builds and all smoke tests pass.

## 2026-08-12 — Model defaults to bash for file ops; native D tools instead (user feedback)
- [x] Reproduced the exact case: "what files are in the workspace?" made the
      model burn 5–6 rounds on `bash dir` variants. Root cause was TWO things:
      (1) cmd's `dir` emits the OEM codepage, so strict UTF-8 `readText` threw
      and the shell tool swallowed real output as "(no output)"; (2) bash was
      the model's default reflex and nothing steered it to the native tools.
- [x] Fixed the shell-output bug: stdout/stderr are now read as raw bytes and
      decoded leniently, so `dir`/`echo %CD%` return real listings. Verified:
      `dir` now returns the actual directory listing instead of "(no output)".
- [x] Added the D-native `run` tool (`program` + `args` array + `workdir` +
      `timeout`) that spawns a process directly — no shell, no quoting, fully
      cross-platform. This is the "our own tools instead of bash/cmd/powershell"
      replacement.
- [x] Added a system-prompt steering message sent with every tools-enabled
      request that directs the model to the native tools (glob/read/write/grep)
      and reserves bash for executables the native tools cannot run.
- [x] Added a "Native tools" toggle (off by default, `Settings.nativeTools`):
      when enabled the bash tool is not advertised at all and the model only
      sees run/read/write/glob/grep, plus the "no shell" steering prompt.
- [x] Verified live: native mode answers "what files are in the workspace?"
      with glob → read in 3 rounds (no shell). Default mode with steering now
      completes the same task in 3 rounds too. Pro tools/smoke tests, baseline
      + Pro debug and release builds all pass.

## 2026-08-12 — Cross-platform tool support (user question)
- [x] Answered the design question with how the original opencode app does it:
      BOTH native host-language tools AND a shell-aware shell tool. The file /
      content tools (read/write/glob/grep) are native D, so they are
      cross-platform by construction (no shell dependency). The single shell
      tool ("bash") is shell-aware per platform instead of being a separate
      cmd / powershell tool.
- [x] The `bash` tool now accepts `shell` (`auto`/`bash`/`cmd`/`powershell`/
      `pwsh`), `workdir`, and `timeout` parameters, and its description carries
      per-platform usage notes so the model writes valid syntax (dir/type/%VAR%
      on cmd, Get-ChildItem/$env: on PowerShell, ls/cat/$VAR on bash).
- [x] Execution switched from `spawnShell` (which silently wrapped everything
      in cmd /c) to `spawnProcess(argv)` with stdout/stderr redirected to a
      temp file and an explicit `workDir` — no per-shell quoting fragility, and
      hanging commands are still killed on timeout.
- [x] Verified on Windows: cmd, powershell, and workdir all round-trip; the
      live model loop now reads/globs correctly instead of emitting `ls -la`
      that fails on cmd. Pro tools test + smoke test, baseline + Pro debug and
      release builds pass.

## 2026-08-12 — Aurora OpenCode Pro "Edit & resend" stopped working (user complaint)
- [x] Diagnosed: the action-pill delegates were created inline inside the
      `foreach` over `_messageColumn.children()` in `refreshBubbleActions` (and
      the right-click `onEditRequested` in `rebuildMessageColumn`). D captures
      the reused `foreach` loop slot by reference, so EVERY bubble's pill was
      bound to the final message index. Clicking "Edit & resend" on an early
      user bubble silently targeted the last message (role mismatch → no-op).
- [x] Reproduced with a headless probe: `onMouseDown` on the pill returned
      `handled=true` but the callback edited the wrong message. Confirmed the
      D behavior with a minimal closure test (even a `const` local copy in the
      loop still captures the shared slot; only a factory function works).
- [x] Fixed with delegate factories `regenerateAction(sessionIndex,
      messageIndex)` and `editResendAction(...)` that bind the indices as
      parameters, mirroring the font-menu fix already documented in
      `AURORA-PATCHES.md`.
- [x] Added regression coverage that invokes a bubble's pill through the real
      captured delegate (`invokeBubbleActionForTesting`) and asserts it edits
      that bubble's own message. Pro smoke test, baseline + Pro debug/release
      builds pass.

## 2026-08-12 — portable-release link fails on this machine (libcmt.lib missing)
- [ ] `dub build --build=portable-release` fails with
      `lld-link: error: could not open 'libcmt.lib'` for **both** baseline and
      Pro (identical configs). `libcmt.lib` (MSVC static CRT) is not installed
      anywhere under `C:\D`. Debug builds and the headless/tool smoke tests
      (compiled with dmd -i) all pass. To restore release builds either
      install the MSVC Build Tools/CRT so `libcmt.lib` is findable, or change
      the `-mscrtlib=libcmt` policy in the `portable-release` buildTypes.

## 2026-08-12 — Aurora OpenCode Pro context-usage meter (user request)
- [x] Researched how the real opencode app meters context usage
      (`anomalyco/opencode`): it uses the **exact** provider `usage` object per
      assistant message (`tokens: {input, output, reasoning, cache:{read,
      write}}`) shown as `total / model.limit.context` percent, updating per
      step-finish — there is no live mid-stream estimate. The only local
      approximation is `chars/4` (`packages/core/src/util/token.ts`) used for
      compaction/overflow and the estimated breakdown bar. The context limit
      comes from provider metadata.
- [x] Pro toolbar now has a small rectangular `ContextUsageBadge` (fill bar +
      percent of the model's context window) that opens a hover
      `ContextUsageTooltip` with the full breakdown (model, limit, used,
      prompt, completion). The tooltip never steals the pointer (its `hitTest`
      reports the badge while hovered).
- [x] Shared client pushes a live `usage` event when the provider reports token
      counts mid-stream; the `done` event records final
      prompt/completion/total on `ChatMessage` (persisted in `sessions.json`).
      `contextLimitForModel()` in core mirrors `model.limit.context` from the
      **official opencode catalog** (`https://models.opencode.ai/api.json`,
      what the CLI itself fetches): deepseek-v4-flash/pro = 1M (user caught the
      old 128K fallback), gpt-5.6-luna 1.05M, qwen3.8-max/glm-5.2 1M, grok-4.5
      500K, kimi-k3 1,048,576, minimax-m3 512K, mimo-v2.5-pro 1,048,576,
      hy3 256K, unknown 128K.
- [x] Badge refreshes on `usage`/`done`, session switch, model picker, restore,
      and delete; shows `ctx` until usage is recorded. Covered by the Pro
      headless smoke test (empty state, 37% at 47213/128000, hover tooltip
      rows, leave dismissal, follows active session) + pixel-verified
      screenshot.

## 2026-08-12 — Aurora OpenCode Pro tool use support
- [x] Studied the original opencode app's tool architecture (built-in tools:
      bash/shell, read, write, glob, grep, webfetch, websearch, question, task,
      todo, skill, apply_patch, lsp, plan; registry + permission model) and
      confirmed the exact wire format the `/chat/completions` endpoint uses
      with a live probe: tool calls arrive as `delta.tool_calls` fragments
      (index, id, function.name, streamed function.arguments) and end with
      `finish_reason: "tool_calls"`; results are sent back as `role: "tool"`
      messages with `tool_call_id` and the loop repeats until `finish_reason:
      "stop"`.
- [x] Core client (`aurora-opencode-core/opencode_client.d`) now supports
      tools: `startChatMessages` (structured `ChatRequestMessage`[] +
      `OpenCodeToolDef`[]), SSE `delta.tool_calls` accumulation across
      fragments, a `toolCalls` terminal event, and `pushLocalEvent` so tool
      results ride the same event queue the UI drains each tick.
- [x] Shared data model extended: `OpenCodeToolCall`, `OpenCodeToolDef`,
      `ChatRequestMessage`, `ChatMessage.toolCalls/toolCallId/toolName`,
      `Settings.toolsEnabled/workspace` (persisted).
- [x] Pro tools module (`aurora-opencode-pro/auroraopencode/tools.d`):
      bash (cmd shell, 60 s kill timeout, temp-file output capture),
      read, write, glob (`**` recursive via own glob→regex), grep, all with
      opencode-mirroring JSON schemas.
- [x] Pro UI tool loop (`appui.d`): "Tools" checkbox in the toolbar, workspace
      path in Settings, tool-call chips on assistant bubbles, `tool` role
      result bubbles, a worker thread executes the batch and feeds results
      back, history (assistant tool_calls + tool results) is re-sent until the
      model answers with text (12-round cap), session persistence + export
      include tool calls/results.
- [x] Baseline client unchanged in behavior: it never advertises tools, and its
      `final switch` handles the new event kinds as no-ops.
- [x] Tests: `aurora-opencode-core/tests/tool_sse_test.d` (fragment
      accumulation + body serialization), `aurora-opencode-pro/tests/
      tools_test.d` (executors), Pro headless smoke extended to run the loop
      offline. Verified live: real API tool loop returns the expected result
      (`sum(1,2) -> 3`; workspace glob→read→summary) with clean `errors.log`.
      Baseline + Pro debug/release builds and smoke tests pass.

## 2026-08-12 — Aurora OpenCode Pro chat-quality actions
- [x] Regenerate/Retry: the last assistant bubble drops the reply and re-runs
      the request with the remaining history ("Retry" when it failed).
- [x] Edit & resend: user bubbles (footer pill or right-click) truncate the
      conversation at that message and prefill the input.
- [x] `ChatMessage.failed` persisted; shutdown-induced request cancellations
      are no longer logged as errors. Covered by the pro smoke test; baseline +
      Pro release builds pass.

## 2026-08-12 — Aurora OpenCode must use the real opencode API, not the demo
- [x] Clarified that `opencode-api.boqsc.eu` is only a test/demo web client;
      the real backend is the opencode API itself (`https://opencode.ai`).
- [x] Pointed the shared core at the real Go-plan endpoint
      (`https://opencode.ai/zen/go/v1`), read the key from the real opencode
      CLI auth store (`~/.local/share/opencode/auth.json`), added a browser
      `User-Agent` (Cloudflare returns 1010 otherwise), and switched thinking
      off to the standard `reasoning_effort: "none"` (the demo proxy used to
      translate a `thinking: false` boolean the real API rejects).
- [x] Removed the loopback/demo-proxy fallback that was built on the wrong
      assumption. Verified live: the smoke test's real chat returns the exact
      `AURORA-OPENCODE-GUI-OK` reply with a clean `errors.log`; baseline + Pro
      debug/release builds and smoke tests pass.

## 2026-08-12 — Aurora OpenCode must not depend on the public opencode-api host
- [x] Diagnosed `WinINet error 12029/12002`: the public `opencode-api.boqsc.eu`
      is unreachable from inside the LAN (NAT hairpin / firewall) even though
      the local `web_webserver` serves the same domain on `0.0.0.0:443` and
      DNS resolves to the machine's own public IP.
- [x] Integrated the local `opencode-api` mirror into the shared client
      (`aurora-opencode-core/opencode_client.d`): every request first tries a
      loopback mirror (`127.0.0.1`, same port/path, real `Host:` header, TLS
      hostname errors ignored for that attempt only), then falls back to the
      configured public host. HTTP/stream errors never trigger the fallback.
- [x] Verified live: the smoke test's chat now returns the exact expected reply
      with zero entries in `errors.log`; debug + release builds of baseline and
      Pro pass.

## 2026-08-12 — Aurora OpenCode runtime error logging (user request)
- [x] Added a shared thread-safe `auroraopencode.logging` module writing
      timestamped entries to `<state dir>\logs\errors.log`, with a per-launch
      banner line so each launch is easy to inspect.
- [x] Both clients wire it up at startup; chat/models request failures (e.g.
      WinINet 12029 cannot-connect), settings load/save failures, and session
      persist/restore failures are all logged. Verified by the smoke runs:
      the live API calls logged 12002 timeouts, confirming the reported 12029
      is a server-connectivity issue with `opencode-api.boqsc.eu`, not a bug.

## 2026-08-11 — Aurora OpenCode baseline vs extended version (structure)
- [x] Split Aurora OpenCode into `aurora-opencode-core` (shared library:
      `opencode_client.d`, `markdown.d`, `core.d`), `aurora-opencode`
      (baseline, unchanged UI), and `aurora-opencode-pro` (extended client with
      its own `appui.d`). Both clients depend on the core package by path.
- [x] Registered `aurora-opencode-pro` in `scripts/build-portable-windows.py`
      and the portable-windows CI artifact list; both new `dub.json` manifests
      carry the portable-release CRT policy.
- [x] Baseline debug/release builds and the headless smoke test pass with the
      new layout.
- [x] Layered the first Pro-only batch into `aurora-opencode-pro`: conversation
      delete (context menu + Delete key), rename dialog, title filter box,
      per-message and code-block Copy buttons, clickable Markdown links,
      message timestamps, token-usage status, and `.md` export. Covered by the
      new `headless_pro_smoke.d` test.
- [ ] Still ahead for Pro: conversation search across content, table Markdown,
      system prompt / temperature / max-token settings, multiple API profiles,
      retry/regenerate, syntax highlighting, tray support, and theme/font
      settings. Keep `aurora-opencode` as the standalone basic client.

## 2026-08-11 — Aurora OpenCode startup conversation scrollbar (user complaint)
- [x] Diagnosed the restored active conversation being selected before the
      sidebar had a real viewport. Selection visibility used height zero and
      initialized the conversation list offset near its bottom.
- [x] Restored the active selection without pre-layout auto-reveal and added a
      regression covering 25 restored sessions with the last one active.

## 2026-08-11 — Aurora-wide scrolling and native drag/drop
- [x] Enabled extended Windows scroll input and native range semantics by
      default; native scroll commands activate the retained scroll target under
      the pointer before reading its range.
- [x] Migrated `ScrollView`, `ListView`, and multiline `TextEditor` to real
      retained child `Scrollbar` widgets.
- [x] Added a platform-neutral rich drag/drop payload, action negotiation,
      widget dispatch, outbound API, and deterministic test-driver support.
- [x] Added Windows OLE inbound/outbound files, Unicode text, URI list,
      HTML/custom MIME, and copy/move/link support. File Manager transitions to
      the OS drag session when a file drag crosses its host-window boundary.
- [ ] Fundamental widgets (`RadioButton`/group, `ComboBox`, `TabView`,
      `TreeView`, `TableView`/data grid, tooltip, menu bar) are deliberately
      deferred until Aurora has an agreed styling/perspective. Revisit directly
      after the scrolling/drag-drop stabilization pass; do not let this remain
      an open-ended postponement.

## 2026-08-11 — Windows File Manager mouse/touchpad scroll (user complaint)
- [x] Added a real reusable `aurora.widgets.scrollbar.Scrollbar` widget.
- [x] Replaced the file manager's embedded list/sidebar scrollbar painting and
      drag logic with retained child scrollbar widgets.
- [x] Added Win32 wheel, pointer-wheel, gesture, and `WM_VSCROLL` input paths.
- [x] Added a synchronized native scroll-range contract for legacy drivers;
      `WM_NCCALCSIZE` leaves no visible native scrollbar area, so Aurora's
      custom widget remains the only rendered control.
- [x] Kept ordinary click-to-focus behavior and removed hover activation,
      synthetic focus input, raw-input duplication, and registry workarounds.
- [x] Added deterministic widget/file-manager tests and a native focus/range/
      exact-delta probe. Release build and both verification paths pass.


## 2026-08-11 — Window resize: stretched image / white blinking / freeze (user complaint)
- [x] Diagnosed the complete OpenCode path rather than only the native border
      message. Three independent problems were involved: the Windows launcher
      selected a debug build, long Markdown/code conversations took about
      650 ms to reflow, and Vulkan treated the expected live-resize
      `VK_SUBOPTIMAL_KHR` result as a request to recreate the swapchain.
- [x] `aurora.window`:
  - `WM_SIZE` stays constant-time, while timer-driven exact layout/paint frames
    reflow the newest size at a 60 Hz target on scaling-capable Vulkan drivers.
  - WSI keeps the last complete frame covering the surface between exact
    frames, so there is no unpainted/white client area.
  - Application polling/ticks remain outside Win32's modal sizing loop.
- [x] `aurora.render.vulkan`:
  - `recreateSwapchain()` no longer calls `waitForSubmittedFrames()` (was a GPU
    stall / freeze on every resize frame) and no longer destroys the old
    swapchain's present semaphores/framebuffers/views while a present is in
    flight (was the white flash). Old swapchain resources are now *retired*
    and reclaimed only after a newer swapchain has presented (`oldSwapchain`
    passed to `vkCreateSwapchainKHR`).
  - Geometry buffers are versioned (fresh allocation per revision, old buffers
    reclaimed after in-flight frames pass) so a live resize no longer forces
    `availableFrame(requireAllIdle=true)` → `vkWaitForFences(ulong.max)`.
  - Reduced post-recreation acquire timeout 16 ms → 2 ms.
  - `VK_SUBOPTIMAL_KHR` is accepted during scaling-enabled live resize instead
    of invalidating and recreating the swapchain inside the drag.
  - The exact final frame is presented immediately through the valid scaling
    swapchain; native-resolution recreation waits for presentation fences to
    become idle, avoiding the driver's occasional 100–450 ms release stall.
- [x] OpenCode Markdown flow is now width-independent at the shaping layer;
      fenced-code line layouts and Markdown output storage persist across
      widths. Measured reflow dropped from about 652 ms to normal 1–4 ms scene
      builds, with the observed live maximum below 8.5 ms.
- [x] `RUN-WINDOWS.bat` and `RUN-WINDOWS-SOFTWARE.bat` now launch release builds.
- [x] Final automated human-paced Vulkan resize: 97 exact live frames over 120
      size changes; resize p95 6.61 ms, max 9.40 ms, zero calls above 16 ms;
      post-resize p95 0.31 ms and max 14.10 ms.
- [ ] Final feel still needs confirmation from the user's real mouse drag and
      monitor/driver combination.

## 2026-08-10 — Sequence resolution matched to a timeline item
- [x] Implemented context-menu command "Set sequence resolution to NxN" on
      video clips (crop-aware), updating the composition/output resolution.
- [x] Verified via headless editor smoke test (menu wiring + action) and
      `dub build --force`; all editor/model/gpu-decode smoke tests pass.
- [x] Output resolution auto-follows the sequence resolution (MP4 export uses
      the composition canvas); preview quality stays a separate responsiveness
      cap. Design answer: yes, output defaults to the sequence resolution.
- [ ] Not yet manually tested in the running GUI / with Playwright screenshot.
- [ ] Not yet manually tested with a non-16:9 or portrait clip in export.

## Notes / open items found while working
- Pre-existing uncommitted work in the working tree (NOT mine):
  - `source/auroracut/ytdlp.d` + `source/auroracut/editor.d`: yt-dlp download
    progress labels ("Download X%", "Processing…", "Normalizing X%").
  - `aurora-opencode/source/auroraopencode/opencode_client.d`.
  - Untracked `aurora-image-viewer/` directory.
  Confirm whether these should be committed/continued.

## 2026-08-10 — Aurora Image Viewer (aurora-image-viewer)
- [x] Built a standalone image viewer in `aurora-image-viewer/` using Aurora-D
      and a custom mipmapped CPU scaler (performant pan/zoom, no aliasing on
      zoom-out, opaque retained compositor layer).
- [x] Complaint addressed: "avoid ffmpeg and it be standalone" — replaced the
      ffmpeg/ffprobe decode path with pure-D decoders for PNG (Aurora-D),
      BMP (24/32/16/8/4/1 bpp + BITFIELDS + RLE8/RLE4), TGA (truecolor/gray/
      colormap + RLE), PNM (P2/P3/P5/P6/P7) and GIF (first frame, LZW).
      No ffmpeg/ffprobe/pipeProcess anywhere in the app now.
- [x] Fixed: ffmpeg decode inside the loader thread crashed the headless UI
      test (process exited 0 silently). Removing the subprocess decode fixed it.
- [x] Headless smoke test passes (scaler + all decoders + UI wheel/fit/drag/
      drop/screenshot). `--screenshot` renders correctly (verified pixel
      colors: bright image center, dark UI chrome).
- [ ] Not yet manually launched as a real window / Playwright screenshot.
- [ ] JPEG/WebP/TIFF not supported (standalone constraint). If needed later,
      implement native decoders or add a documented opt-in ffmpeg path.
- [ ] Checkerboard/alpha, rotate, slideshow, EXIF orientation not yet added.

## Notes / open items found while working
- Preview decode surface is fixed 16:9 (`recommendedDecodeSize`), so a
  non-16:9 composition can appear stretched in the live preview even though
  export renders the correct canvas. Existing limitation, not introduced here.
