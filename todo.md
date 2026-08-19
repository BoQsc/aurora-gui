# Aurora Cut todo / complaints log

## 2026-08-19 - Aurora Designer: visual UI designer on Aurora-D (feature, done)

- [x] User: "Would it be possible to gather all the best practices and have
      aurora designer program." → agreed scope: a visual UI designer tool for
      building Aurora-D GUIs, built following this repo's documented best
      practices (frameless Aurora window + custom titlebar, portable-release
      dub.json, vendored Aurora-D on sourcePaths, headless UiTestDriver smoke).
- [x] Created `aurora-designer/`:
  - `dub.json` mirrors `aurora-notepad/dub.json` (GUI-subsystem
    `/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup`, portable-release buildType,
    libs-windows user32/gdi32/shell32/wininet, version 0.66.7).
  - `source/app.d` — GuiWindow + DesignerRoot, `--screenshot <path>` mode.
  - `source/auroradesigner/model.d` — `DesignDocument`/`Node`/`NodeKind`
    model, line-per-node `.aurora` text serialization (round-trips), and
    idiomatic D codegen (`Widget buildDesignedUi()`).
  - `source/auroradesigner/appui.d` — `DesignerRoot` (palette / artboard /
    inspector split), `DesignCanvas` (click-select, drag-move, corner-handle
    resize, marquee, right-click context menu, hover outline), inspector
    property rows, toolbar (New/Open/Save/Code/Undo/Redo/Delete/theme),
    Code popup with a real `TextField`-editable generated source preview +
    Copy-to-clipboard (Win32 CF_UNICODETEXT).
  - `source/auroradesigner/titlebar.d` — `DesignerTitleBar`, the Notepad
    frameless-chrome pattern (owner-driven drag, work-area maximize/restore,
    restore-on-drag, drag-snap preview, system menu).
  - `tests/headless_smoke.d` — covers model round-trip, codegen sanity,
    undo/redo, delete, pointer selection, drag, and a real palette-button
    click (by id) through `UiTestDriver`.
- [x] Verified: `dub build --compiler=dmd` links; headless smoke passes
      ("Aurora Designer headless smoke passed."); generated code compiles
      against the vendored Aurora-D; `--screenshot` renders the three-pane
      layout (pixel-analyzed); interactive window launches and stays running;
      `verify-windows-portability.py` still passes (designer dub.json conforms).
- [x] Registered the app in `scripts/build-portable-windows.py` APPLICATIONS.
- [ ] Manual: launch `aurora-designer\RUN-WINDOWS.bat`, place a few widgets,
      drag/resize them, edit properties in the inspector, click Code and copy
      the generated D into a fresh Aurora-D app.

## 2026-08-19 - aurora-notepad: toolbar dropdowns open instantly (fixed)

User: "check why toolbar dropdowns are not instantly opening and takes some
time".

Root cause: `MenuBarItem` opened the context menu from `Button.onClick`, which
fires on MOUSE-UP (release). Native Windows 10 menus open on MOUSE-DOWN
(press), so the dropdown appeared one click-phase later and felt delayed.

Fix: `auroranotepad/menubar.d` `MenuBarItem` now opens the dropdown in
`onMouseDown` (press) and consumes the release. Verified with a headless probe:
the popup exists immediately after mouse-down, switching menus keeps a single
popup, and clicking outside dismisses it. Headless smoke test still passes.

## 2026-08-19 - Prove the released exes are portable / self-contained (question, answered)

- [x] User: "how could we test that exe like aurora cut is actually portable
      and independent and does not need msvc or other."
- [x] Verified on the released v0.66.7 assets:
  - PE import scan (`scripts/verify-windows-portability.py --skip-manifests`)
    on all 6 exes: only Windows system DLLs, no msvcr/msvcp/vcruntime/
    ucrtbase/api-ms-win-crt. aurora-cut imports ADVAPI32, GDI32, KERNEL32,
    SHELL32, USER32, WININET, WINMM, ole32.
  - Embedded ffmpeg imports only Windows system DLLs (msvcrt.dll is the
    built-in Windows CRT, not the MSVC redistributable).
  - Ran the exe from an empty folder with PATH=C:\Windows\System32: GUI
    launched and the bundled ffmpeg extracted to
    `%TEMP%\Aurora-Cut-ffmpeg\ffmpeg-13480464-13836224\`.
- [x] Documented the repeatable 3-layer test procedure in
      testing_progress_and_methods.md.

## 2026-08-19 - aurora-notepad: match native Windows 10 Notepad UI metrics (done)

User: "check the windows 10 notepad original size of toolbar and ui text
sizes. we need to try to apply them to our aurora notepad."

Measured real `notepad.exe` (Win10 22H2, 120 DPI, per-monitor DPI aware) via
Win32 (GetMenu/GetMenuItemRect/GetWindowRect/FindWindowEx/GetDpiForWindow/
NONCLIENTMETRICS/SM_*), converted to 96-DPI logical units:

- menu bar height = 20 logical px (SM_CYMENU 25 @120 / 1.25)
- status bar height = 23 logical px (msctls_statusbar32 29 @120 / 1.25)
- caption button width = 36 logical px (SM_CXSIZE 46 @120)
- caption bar height = 23 logical px (SM_CYCAPTION 29 @120)
- caption / menu / status font = Segoe UI 9 pt = 12 px EM logical
- editor font = Consolas 10.8 pt (11 pt logical)

Applied to aurora-notepad:

- `auroranotepad/notepadsize.d` (new): shared constants for all of the above.
- `appui.d`: menu bar and status band heights, status label 12 px.
- `menubar.d`: 20 px bar, menu items measured + painted at 12 px.
- `titlebar.d`: bar height 23, caption button width 36, title 12 px.
- Vendored `aurora-d` additions (compatible, tests still pass):
  - `widgets/titlebar.d`: `setTitleFontSize` (fixed-pixel title).
  - `widgets/label.d`: `setPixelSize` (fixed-pixel status label).
  - `widgets/button.d`: `setTextPixelSize` (fixed-pixel menu items).
- Verified via `--screenshot` band/bbox analysis: title bar 23, menu 20,
  content at 43, status 23, all UI text 12 px logical (matching native 9 pt).
- headless smoke + aurora-d unittests (32 modules) all pass.

## 2026-08-19 - Released v0.66.6 STILL "waiting for audio": stale locked ffmpeg cache (complaint, fixed)

- [x] User: "it keeps on saying it's waiting for audio before playback starts.
      So there is absolutely no progress yet."
- [x] Root cause: v0.66.6 embedded the CORRECT ffmpeg (pcm_s16le), but the
      extraction cache `%TEMP%\Aurora-Cut-ffmpeg\ffmpeg.exe` held the OLD
      broken build because the still-running v0.66.5 instance locked the
      file, so v0.66.6's overwrite threw, was silently swallowed, and the app
      put the old (broken) directory first on PATH.
- [x] Fix: `ffmpegbundle.d` extracts into a content-keyed directory
      `Aurora-Cut-ffmpeg\ffmpeg-<ffmpegSize>-<ffprobeSize>\` so a newer
      release never collides with or is blocked by an older build's files.
- [x] Verified: the v0.66.6 embedded ffmpeg (extracted, config `pcm_s16le`)
      produces valid `-f s16le` PCM (192,000 bytes for 1 s); the user's stale
      cache was deleted and running instances were closed so the next launch
      extracts fresh.
- [x] Re-released (0.66.7) and the user confirmed: "yeah seems to be fine."
      Audio playback works in the released single-exe build.

## 2026-08-19 - aurora-browser: desktop web browser shell on aurora-web (feature, done)

Created `aurora-browser/`, a working desktop browser shell that renders pages
with the `aurora-web` engine inside Aurora-D windows:

- `aurora-browser/dub.json` — executable mirroring `aurora-notepad/dub.json`
  (name `aurora-browser`, targetName `aurora-browser`, sourcePaths source +
  vendor aurora-d + aurora-web, libs/lflags-windows, portable-release buildType,
  version 0.66.3).
- `aurora-browser/source/app.d` — slim entry point (GuiWindow + BrowserRoot,
  plus `--screenshot <path>` software-render mode).
- `aurora-browser/source/aurorabrowser/appui.d` — the browser chrome:
  `BrowserRoot` (VBox), `WebPageView` (renders a `WebPage` from a widget's
  `onPaint`), `AddressField`, tab model. Back/Forward/Reload buttons, address
  TextField + Go, tab strip label, status bar; window title = page title.
- `aurora-browser/RUN-WINDOWS.bat` — mirrors `aurora-notepad/RUN-WINDOWS.bat`
  (dub run --build=release).
- `aurora-browser/tests/headless_smoke.d` — headless UiTestDriver smoke test.

Behavior:
- Offline-first navigation: a built-in `auroraweb:` scheme serves constant HTML
  test pages (`auroraweb:hello`, `auroraweb:css`, `auroraweb:js`,
  `auroraweb:search`). Plain words -> `auroraweb:search?q=<word>`. HTTP/HTTPS
  (WinINet) is a known gap.
- Multi-tab: array of `WebPage` + per-tab history stack + active index;
  Ctrl+T new tab, Ctrl+W close, Ctrl+L focus address, Alt+Left/Right back/forward.
- `WebPage` engine fix (aurora-web): added `resize(int,int)` + `width()/height()`
  so the page viewport follows the widget (engine was otherwise stuck at the
  construction size; the shell constructs pages before the first layout).
- aurora-web JS parser fix: `for (init; test; update)` never consumed the `;`
  after the init clause, so `for (var i=0; i<n; i++)` threw `Expected ')'`.
  Fixed in `auroraweb/js.d` `parseFor()`; `dub test` (35 modules) still passes.

Build/run:
```
cd aurora-browser
dub build --compiler=dmd              # debug build, succeeds
dub build --compiler=dmd --build=release
aurora-browser.exe                    # interactive window (software fallback ok)
aurora-browser.exe --screenshot out.ppm
dmd -i -version=AuroraHeadless -Isource -I..\vendor\aurora-d-0.4.5\source -I..\aurora-web\source tests\headless_smoke.d -of=build\aurora-browser-headless-smoke.exe
build\aurora-browser-headless-smoke.exe   # "headless_smoke: ALL PASSED"
```
NOTE: `--build=portable-release` fails on this machine for ALL packages
(aurora-notepad too) because it needs MSVC `libcmt.lib` (`-mscrtlib=libcmt`)
and only DMD's mingw toolchain is installed. Not a browser-specific issue.

Known gaps (milestone 3 closed): real HTTP/HTTPS fetch now exists (net.d),
`<img>` loading wired, bookmark bar + per-tab close + scrollable pages added
to the shell. Remaining: HTTPS/TLS policy hardening, JS `async/await` full
suspension semantics, CSS grid `fr` edge cases, `@media` screen types.

## 2026-08-19 - aurora-web milestone 3: remaining gaps closed (feature, done)

- [x] User: wants a cross-platform standards browser, fully controllable,
      <50MB, no dependence on each OS's engine, no bundled Chromium/WebKit.
- [x] Decision: build our own minimal engine on Aurora-D (accepting a defined
      web subset). Confirmed the three constraints can't all be met with a
      bundled engine; user chose "own minimal engine".
- [x] Created `aurora-web/` DUB library: HTML parser, CSS parser+cascade,
      block/inline layout, paint to Aurora Canvas, from-scratch JS interpreter
      in D, DOM bindings (`document`, query APIs, events, mutation).
- [x] `dub build` and `dub test` pass; headless render smoke
      (`tests/auroraweb_render_smoke.d`) passes end-to-end.
- [x] Auto-extract `<style>`/`<script>` from HTML in `WebPage.setHtml`;
      `executeScripts()` runs inline JS in the page runtime (parseInto/
      runProgram).
- [x] Networking: `auroraweb.net` WinINet HTTP/HTTPS with redirects;
      `WebPage.navigate(url)`, `fetchText`/`fetchBytes`, JS `fetch().then(cb)`
      shim; image loader wired (PNG decode via Aurora).
- [x] Layout depth: margin collapsing, percentage lengths, min/max-width/height,
      absolute positioning, flexbox rows (flex-grow/justify/align/gap),
      per-side borders, real inline text positions.
- [x] JS breadth: `++/--`, compound ops, var hoisting, `this` + call/apply,
      String/Array prototype methods, Object helpers, JSON, Error types,
      real `new`/prototype/instanceof.
- [x] Browser shell `aurora-browser/`: tabs (Ctrl+T/W), back/forward + history,
      address bar, reload, status bar, window title = page title, `--screenshot`
      mode; headless smoke (19 checks) passes.
- [x] Bookmark bar (★ toggle + per-URL buttons) / page scrolling (wheel +
      clamped) / per-tab close (Ctrl+W) in the shell.
- [x] Layout: tables, `box-sizing:border-box`, CSS Grid (`grid-template-columns`
      with `fr`), rgba/hsl colors, `em`/`rem`/`vh`/`vw` units, `@media`
      queries, direct-text block height measurement.
- [x] JS: template literals, arrow functions, Promise + then/catch/resolve,
      setTimeout/setInterval + pumpTimers, Set/Map, `async` flag.
- [x] DOM bindings: innerHTML getter/setter, classList, style object with
      setProperty/getPropertyValue, parentNode/firstChild/children/childNodes,
      event bubbling.
- [x] Milestone 4 honest re-audit: real continuation-based `async/await`
      (await parsed, resume via microtask + order-skip re-entry preserving
      scope state; verified sequence `before-await,after-await,10,20,done:21`);
      grid `grid-template-rows` + content-based auto rows; real float wrapping
      (FloatRect list + lineLeft/lineRight shaping). Added `auroraweb:async`
      page + 2 headless checks. headless_smoke now 21 checks, all PASS.
- [x] Milestone 5 (parallel subagents, 4/4 succeeded with marker files +
      coordinator re-verify): `@media` screen/print media types; child `>` /
      adjacent `+` / attribute `[attr=value]` selectors; browser real
      http(s) navigation via WinINet; `<a>` link click handling + hit-testing
      + `auroraweb:links`; JS for-of, coercion edge cases, instanceof/bind,
      more Array/String/Object methods; CSS `background-image`/`background-size`
      + `<img>` intrinsic sizing. headless_smoke now 29 checks, all PASS.
- [x] Milestone 6 (user: "the web browser is nonsense the rendering makes no
      sense"): diagnosed and fixed THREE rendering defects — (1) layout
      measured text at `length*8` px instead of real shaping; (2) HTML parser
      auto-closed every block ancestor so `<div><p>` split into siblings;
      (3) paint passed a pixel size into `Canvas.layoutText` which treats it
      as a typographic SCALE -> every text run shaped at 102px and drawn
      ~36px below its box. Fixes: paint shapes via
      `textEngine.layout(text, options)` with `options.pixelSize` (same call
      layout uses); html auto-close only self-closing tags; layout skips
      whitespace-only text and measures real wrapped heights. Verified with a
      diagnostic page + a new smoke regression (red h1 in top 40 rows). All
      green: 39 modules, engine smoke, browser smoke (29 checks).
- [x] Milestone 7 (user: "why i see overlapping text"): `layoutDirectText`
      had dropped the horizontal cursor, so every direct text node in a block
      was placed at the same x and inline elements (`<b>`, `<i>`) got 0x0
      boxes. Fixed: `layoutDirectText` lays out direct text + inline children
      on one shared line with a real cursor and real measurement; `layoutChildren`
      skips direct inline children. Verified `<p>Hello <b>bold</b> world
      <i>italic</i> tail</p>` has strictly increasing x per run and no overlap;
      added a smoke regression. All green (39 modules, both smokes).
- [x] Milestone 8 (user: "it's clearly overlapping and impossible to read"):
      root cause was the FIRST-FRAME viewport. `WebPageView` is created before
      the widget has bounds, so the page laid out at 1px wide (every char wraps
      to its own line -> all text piles up unreadably). `onPaint` re-laid-out
      but never resized the page to the real widget size. Fix: `onPaint`
      resizes the page to the actual `size()` before every layout. Verified on
      interactive/Vulkan (1080x680) AND software (1350x850): clean separated
      bands, no overlap; 39 modules + both smokes green.
- [ ] Remaining (recorded honestly): grid `fr` units in `grid-template-rows`,
      sandboxing/TLS policy hardening for remote content, true event-loop
      integration (timers driven by a real loop rather than explicit
      `pumpTimers` calls), and `@media` `min/max-device-width` variants.
- [ ] Long-term: full Chrome/Firefox parity is a multi-year effort; the
      foundation is now structurally sound and testable (39 modules,
      headless_smoke 21 checks).

## 2026-08-19 - Released v0.66.5 STILL no audio: CI embedded stale ffmpeg artifact (complaint, fixed)

- [x] User: "Absolutely no improvement in the release."
- [x] Root cause: the portable-windows workflow downloads the minimal ffmpeg
      artifact with `gh run list --status success --limit 1` (latest
      successful run, ANY commit). The minimal-ffmpeg rebuild for the fixed
      commit ran in parallel and took 8 min while the portable build finished
      in 2 min, so the single-exe embedded the OLD artifact (still missing
      the s16le muxer). Verified by extracting the embedded ffmpeg from the
      published v0.66.5 exe: config still showed `--enable-muxer='...s16le...'`
      and `-f s16le` produced nothing.
- [x] Fix: portable-windows.yml now finds a successful minimal-ffmpeg run for
      the EXACT current commit; if none exists it dispatches the build and
      polls (90 x 20 s) until that commit's run succeeds, then downloads it.
- [x] Confirmed the build-script flag fix is correct: muxer component names
      from allformats.c are `pcm_s16be`/`pcm_s16le`, so only
      `--enable-muxer=pcm_s16le` matches.
- [x] Re-released (0.66.6) and VERIFIED: the published `aurora-cut-v0.66.6.exe`
      embeds an ffmpeg whose config shows `--enable-muxer=...pcm_s16le...`,
      and `-f s16le` decode of the user's real webm produces 574,752 bytes of
      valid PCM (identical to the full ffmpeg). The portable workflow waited
      for the fresh ffmpeg build (11 min) instead of racing ahead (2 min).

## 2026-08-19 - Released v0.66.4 "waiting for audio output" (complaint, fixed)

- [x] User: "just like before this release, it's keeping on waiting for audio
      output or anything else, nothing like how it is before we release."
- [x] Root cause: the minimal bundled FFmpeg's `--enable-muxer=s16le` flag
      matched NOTHING in FFmpeg configure (component is `pcm_s16le_muxer`,
      glob `s16le_muxer` misses it), so `-f s16le` (raw PCM out) is missing.
      Audio decode starts, produces no PCM, no clock -> transport waits up
      to 5 s then plays muted, re-triggering on prewarm/loop = "keeps
      waiting for audio output".
- [x] Fix 1: build script uses `--enable-muxer=pcm_s16le`.
- [x] Fix 2: app fails fast to muted playback when the audio worker produced
      no samples (playback.d publishes a failure; editor.d falls back after
      0.35 s instead of waiting 5 s).
- [x] Verified: `dub test` 35 modules; editor-smoke passes.
- [ ] Rebuild minimal ffmpeg in CI and confirm `-f s16le` works in the
      artifact before/after the portable build.
- [ ] Re-release (0.66.5) and confirm audio in the released single-exe build.

## 2026-08-19 - Released v0.66.3 export broken: bundled ffmpeg lacks -filter_complex_script (complaint, fixed)

- [x] User: "for some reason the released version of aurora cut does not
      behave or work properly like the one we do via simple RUN-WINDOWS.bat I
      mostly see that playback have problems."
- [x] Root cause: release = `portable-single-exe` embeds the MINIMAL
      cross-compiled FFmpeg (git-2026-08-14 `c48230e`); RUN-WINDOWS.bat
      (`dub run`) uses the FULL FFmpeg n7.1. The minimal build removed the
      deprecated `-filter_complex_script` option. Both export call sites
      (`performComposition`, `renderCompositeFrame`) used it -> export failed
      with `Unrecognized option 'filter_complex_script'` on the release.
      Playback itself (inline `-filter_complex`) was verified working on the
      bundled build, including the user's portrait AV1 project.
- [x] Fix: exporter.d passes the graph inline via `-filter_complex` (same as
      the live compositor), removed the `.ffgraph` file writes and the unused
      `std.file.write` import.
- [x] Verified: `dub test` -> 35 modules; editor-smoke full run passes;
      export-smoke produced composed.mp4/mp3 + title rasters (exit 0);
      inline `-filter_complex` export graph run directly against
      `%TEMP%\Aurora-Cut-ffmpeg\ffmpeg.exe` produces a valid MP4.
- [ ] Rebuild the release after the fix and confirm exports in the released
      single-exe build on a machine with the VS static CRT.
- [ ] Consider pinning the minimal ffmpeg build to a revision that still
      supports `-filter_complex_script`, or documenting that exports now use
      inline graphs.

## 2026-08-19 - yt-dlp normalize uses GPU NVENC when available (feature)

- [x] User: "what does normalizing mean and why it takes so long?"
- [x] Explanation: normalization is a full re-encode (not a fast copy) into an
      editor-friendly MP4: libx264 CPU re-encode, resolution cap to the selected
      height (default 1080), forced 30fps, keyframe every 0.5s for instant
      timeline scrubbing, yuv420p, AAC audio, +faststart.
- [x] Problem: the yt-dlp normalize step hardcoded CPU `libx264 -preset veryfast
      -crf 20`, so a 2-minute 1080p video took ~2 minutes to normalize
      (~1.1x realtime) while the exporter already used GPU h264_nvenc.
- [x] Fix: normalization now uses `_tools.h264Encoder` (NVENC/QSV/AMF when the
      tool scan found a working hardware encoder, falling back to libx264).
      `YtDlpDownloadRequest` gained `videoEncoder`; `enqueue` gained the
      param; `ytDlpNormalizedVideoArguments`/`normalizeDownloadedVideo` pass it
      through with the correct rate-control flags per encoder (NVENC p4/hq/vbr
      cq20, QSV medium global_quality 20, AMF balanced cqp 20).
- [x] Verified: `dub test --compiler=dmd --force` -> 35 modules pass (new
      unittest covers libx264 vs h264_nvenc argument construction and that GOP
      flags survive). Live benchmark on this machine: 128s clip -> NVENC 27.6s
      (~4.6x realtime) vs libx264 117.9s (~1.1x realtime), ~4.3x faster; output
      is valid h264. Manual in-app download still to be confirmed by the user.

## 2026-08-19 - yt-dlp downloads stall/fail with HTTP 403 (complaint, fixed)

- [x] User: "ytdlp failed to start downloading a video, can you check why if
      there is anything in the logs about error"
- [x] Diagnosis: `aurora-cut.log` had **no yt-dlp entries** - yt-dlp failures
      only went to the status bar (`setStatus`), never to `appLog`. Hard
      evidence in the Downloads folder: a leftover
      `The Offspring - You're Gonna Go Far, Kid (Official Music Video.f137.mp4.part`
      (10,364,226 bytes, stalled at 12:20:58, never grew). Reproduced with the
      app's exact command: yt-dlp downloads to ~15.9% (approx 10 MB) then dies
      with `ERROR: unable to download video data: HTTP Error 403: Forbidden`.
      Affects 720p (136+140) and 1080p (137+140) H.264 formats. Metadata
      fetch works fine; only the video-data stream is throttled. Installed
      yt-dlp 2026.07.04 IS the latest release (GitHub confirmed), so not an
      updatable-binary problem. This is the known YouTube 403/throttling issue
      (docs already noted "YouTube 403s from this network").
- [x] Fix 1 - retry with backoff (`ytdlp.d`): `downloadOne` now runs up to 3
      attempts with 2s/4s backoff for **transient** failures only. New
      `ytDlpTransientFailure(output)` matches HTTP 403/429/5xx, timeouts, and
      connection resets; permanent failures (bad URL, private/removed video)
      fail fast. yt-dlp resumes leftover `.part` files on retry, so the partial
      download carries forward. `runAttempt` closure streamlines the old
      inline process-handling; marker file now survives the retry loop so the
      successful attempt's path is readable. Progress reports "Retrying in N s"
      between attempts.
- [x] Fix 2 - diagnostic logging (`editor.d` `drainDownloadedMedia`): both
      yt-dlp success and failure now write to `aurora-cut.log` via `appLog`
      (failure includes the URL and the tail of the error output), so future
      failures are visible in the log file, not just the status bar.
- [x] Verified: `dub test --compiler=dmd --force` -> 35 modules pass; new
      unittest covers `ytDlpTransientFailure` (403/429/5xx/reset -> transient;
      private/unavailable/unsupported -> permanent). Live 403 reproduction and
      latest-version check documented above. Manual real-network retry still
      to be confirmed by the user.

## 2026-08-19 - Timeline item clickability gap at the bottom after resize (complaint, fixed)

- [x] User: "there is a bug where if you resize window there appears a gab on
      timeline item clickability at the bottom of item, maybe it's for entire
      row/track I think that resizing affects the mouse pointer where we are
      clicking instead of being accurate and correct no matter what."
- [x] Decision (upstream vs downstream): **downstream** — the framework's
      pointer→local conversion (`window.d` `globalToLocal` + `DisplayScale`) is
      correct; the mismatch is entirely inside aurora-cut's own `timeline.d`.
- [x] Root cause: two row-geometry functions disagree by the constant
      `NewTrackDropGap` (8 px):
  - **Paint**: `trackRect()` (`timeline.d:874`) →
    `y = rulerHeight() + NewTrackDropGap + rowTop(row) - _verticalScroll`, so
    rows paint starting at ruler+8 px.
  - **Hit-test**: `trackAtY()` (`timeline.d:996`) →
    `localY = y - rulerHeight() + _verticalScroll` — **forgets the 8 px gap**.
  With the default 24 px track, the painted row spans y∈[32,56) but hit-testing
  treats it as y∈[24,48). A click on the bottom ~8 px of a painted clip body
  fails `trackAtY` → `clipAtPoint` returns -1 → the press falls through to the
  playhead-scrub branch (dead zone). Resizing just moves the clip body so its
  bottom edge lands in that always-present zone, which is why it "appears after
  resize". Also note `clipAtPoint` gates on `trackRect(address).contains(point)`
  which uses the *painted* origin — so the two paths disagreed inside the very
  same click handler.
- [x] Fix: `trackAtY()` now subtracts `NewTrackDropGap` too:
  `localY = y - rulerHeight() - NewTrackDropGap + _verticalScroll`. Hit-testing
  and painting now share the exact same row origin.
- [x] Regression in `tests/editor_smoke.d` (after the "selecting a timeline
      item" block): click the clip body 4 px from its painted bottom edge
      (inside the body, clear of the ±3 px track-resize band), assert it selects
      the clip (not deselect/scrub) and that the playhead does not move.
      Verified it FAILS against the pre-fix build (assert "did not select it")
      and PASSES with the fix.
- [x] Verified: editor-smoke full run passes; `dub test --compiler=dmd --force`
      → 35 modules pass.
- [ ] Manual (live app): resize the Aurora Cut window and click near the bottom
      edge of timeline items — they must select normally with no dead zone.

## 2026-08-19 — Timeline edits invisible during playback (complaint, fixed)

- [x] User: "Moving timeline items while playhead is doing playback: does not
      show changes/results in the playback, you need to stop playback to see
      changes. Fix it."
- [x] Root cause: during active sequence playback, `markTimelineChanged()`
      (via `afterTimelineMutation` ← `moveClipRequested`/`resizeClipRequested`
      etc.) only set `_sequenceRefreshDeferred = true` and never rebuilt the
      compositor, so the running FFmpeg snapshot kept showing the pre-edit
      timeline until pause/resume or a new Play.
- [x] Fix (`source/auroracut/editor.d`):
  - `markTimelineChanged()`: while running, now also set
    `_sequenceRefreshPending = true` so the debounced
    `refreshSequenceAfterEdit()` (0.14 s) fires even during playback.
  - `refreshSequenceAfterEdit()`: when running, rebuild the live compositor in
    place via the new `refreshPlaybackStreamsForEdit()` instead of deferring;
    clears `_sequenceRefreshDeferred` and marks the model revision consumed.
  - `refreshPlaybackStreamsForEdit()`: re-anchors the clock to the current
    position and calls `startPlaybackStreams()` (mirrors `loopPlaybackRestart`),
    so video + audio rebuild from the current playhead without stopping the
    transport. Status becomes "Playback refreshed to show the edit."
  - The `_sequenceRefreshDeferred` flag is still set during the pending window
    to block the separate source-audio refresh from racing the compositor
    rebuild.
- [x] Updated `tests/editor_smoke.d` "non-blocking edits" block: moving a clip
      during playback must now (a) keep the transport running, (b) rebuild the
      video compositor (`videoStats.requests` increases), (c) clear the
      deferred flag and adopt the model revision.
- [x] **Crash regression (same feature, user retested):** "absolutely crashed
      entire program i tried to move timeline item while playback was
      happening." Two follow-up hardening fixes in `source/auroracut/editor.d`:
  1. `refreshPlaybackStreamsForEdit()` now wraps `startPlaybackStreams()` in
     try/catch. Moving a clip can leave the playhead past every clip's end
     (sequence shrank below the playhead), making the compositor throw
     "The selected export range is empty." That exception was previously
     UNCAUGHT on the edit-refresh path → whole-program crash. It now stops the
     transport cleanly ("Playback stopped: the edit left nothing to render at
     this point.") and shows the last frame.
  2. Background prewarm loop: after such an edit, `startPlaybackPrewarm()`
     failed every tick with the same empty-range exception (caught, but logged
     ~16×/s with full stack traces → frozen/laggy app). Added
     `_playbackPrewarmFailures`; after 3 consecutive failures retries are
     suppressed (reset on any playhead move/edit via `notePlaybackPrewarmDirty`).
- [x] **Follow-up complaint:** "why playback stops at timeline last item end
      position before I start moving on the timeline instead of very last item
      after I move timeline item while playback is going." Cause: the refresh
      restarted the compositor but `_playbackEnd`/`_playbackFullEnd` still held
      the pre-edit sequence length, so the transport hit `_playbackPosition >=
      _playbackEnd - 0.001` and called `finishPlayback()` at the OLD last item.
      Fix in `refreshPlaybackStreamsForEdit()`: before restarting, re-derive
      `_playbackFullEnd`/`_playbackEnd`/`_playbackStart` from the current
      `_model.sequenceDuration()` (and re-apply loop bounds when loop is on),
      updating `_playbackAsset.duration` for live composition. Playback now
      continues to the edited sequence's real end.
- [x] New `tests/playback_edit_crash_repro.d`: two video clips on separate
      tracks (A on V1 [0,0.5], B on V2 [0.6,1.1]); start live playback inside
      B, move B back to start 0.0 during playback so the sequence shrinks below
      the playhead. Asserts the transport stops gracefully instead of crashing.
      ALSO covers the extend case: reset the layout, play, move B forward to
      2.6 during playback, assert `playbackEndForTesting()` grows past the
      pre-edit end and playback keeps running.
      Build/run:
      `dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source
      tests\playback_edit_crash_repro.d -of=build\headless-smoke\playback-edit-crash-repro.exe
      -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32
      -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet`
      then `build\headless-smoke\playback-edit-crash-repro.exe
      build\headless-smoke\media\base-av.mp4` → "passed (no crash on empty
      render range)."
- [x] Verified: `dub test --compiler=dmd --force` → 35 modules pass;
      `aurora-cut.exe` rebuilt (`dub build`); playback-edit-crash-repro passes;
      static-sequence-playback-smoke, synced-preroll-smoke,
      playback-seek-resilience-smoke, and playback-stress all pass.
- [ ] NOTE: `editor-smoke` currently fails at the History popup redo test
      (~line 1111) because the OTHER concurrent opencode session's
      history-step-toggle refactor (`_historyJumping` removal + `stepUndo`/
      `stepRedo`/`nearestEnabledPosition`) is mid-flight and its test
      expectations are ahead of the implementation. Unrelated to this feature;
      re-check `git diff` before blaming playback code.

## 2026-08-19 — Suggested export names + title-based yt-dlp download names (feature)

- [x] User: "how could we name exported mp4 so it does not collide... sequence
      name + main video name... what about project name... fix ytdlp download
      names with title names of source like youtube" → agreed on: project name
      → main clip name → fallback, plus dedup suffix.
- [x] **Export dialog suggestion** (`editor.d` `suggestedExportName`): saved
      project name (stem of `_projectPath`) → first media clip's source name
      (first V1 video clip for MP4, first A1 audio clip for MP3, falling back
      to the other kind) → `aurora-cut-export`. The stem strips the extension
      and a trailing `.normalized` (so downloaded `Title [id].normalized.mp4`
      suggests `Title [id].mp4`). `uniqueExportFileName` deduplicates against
      the default Exports folder (`-2`, `-3`, … to 999, matching the compress
      style), so repeated exports never silently overwrite.
- [x] **yt-dlp download names** (`ytdlp.d`): files are now named
      `%(title)s [%(id)s]` instead of `aurora-<uuid>`. Removed
      `--restrict-filenames` for readable titles; added `--trim-filenames 120`
      for Windows path limits; yt-dlp reports the final post-processed path
      through `--print-to-file after_move:filepath <marker>` and
      `downloadedPathFromMarker` accepts only an in-folder supported-media
      path. The normalized copy becomes `Title [id].normalized.mp4`
      (`downloadedStem`). The `[id]` keeps same-title videos from colliding in
      the shared Downloads folder.
- [x] Verified: `dub test --compiler=dmd --force` → 35 modules pass (new
      ytdlp.d unittest covers downloadArguments template/marker/trim flags for
      video+audio, marker path validation, stem); editor-smoke full run asserts
      the export-dialog name (named project = project stem, unnamed empty =
      `aurora-cut-export.mp4`, unnamed with clip = `base-av.mp4`, dedup =
      `base-av-2.mp4`); model/export/gpu-decode-args/recompress/layout/
      static-sequence smokes exit 0. Live yt-dlp probe (YouTube 403s from this
      network) against a local http server produced `base-av [base-av].mp4` and
      the marker contained its exact path.
- [ ] Manual (real app, real network): download a YouTube video and confirm the
      media-bin name reads `Title [id].normalized.mp4`; export once (suggested
      project name), export again (suggested name gets `-2`); export an
      unnamed project with one clip (suggests the clip/source title).
- Note: the other concurrent session's history-step-toggle feature and focus
      ring are uncommitted in the same files; the working tree compiles and
      passes as a whole right now.

## 2026-08-18 — Concurrent opencode sessions edited the same files (developer issue)

- [x] While the New Project feature was being built/verified (above), a SECOND
      opencode session was simultaneously editing `source/auroracut/editor.d`,
      `source/auroracut/ytdlp.d`, and `tests/editor_smoke.d`. Its changes
      landed on top of this session's (both sets are now present in the tree).
- [x] The other session's `ytdlp.d` refactor used `template` as a function
      parameter name, which is a reserved D keyword → the whole repo failed to
      compile (`found template when expecting )`). Fixed by renaming the
      parameter to `titleTemplate` (`downloadArguments`). Its `editor_smoke.d`
      export-dialog-name assertion also used `std.path.extension` without
      importing it → added `extension` to the existing `import std.path`
      line. Both are minimal, behavior-preserving fixes.
- [x] Lesson for future sessions: this repo is shared across several opencode
      windows at once. Before compiling/testing, `git diff`/`git status` to see
      whether another session is mid-edit; after editing, re-check that no
      external writer replaced the file. Do not assume the working tree is
      stable while other sessions are running. Verify with a fresh compile +
      `dub test` + editor-smoke at the END, not just after your own edits.
- [x] Verified after the fixes: `dub test` → 35 modules pass; editor-smoke
      full run passes; model-smoke passes; app links; New Project regression
      block (button + Ctrl+N + autosave checks) passes inside editor-smoke.

## 2026-08-18 — New Project button (feature)

- [x] User: "let's add new button to the aurora cut for creating new project."
- [x] Added a **New** toolbar button (`id="new-project"`, `IconKind.newDocument`,
      placed before Save) and a **Ctrl+N** shortcut in
      `source/auroracut/editor.d`.
- [x] `EditorRoot.newProject()` discards the current project and starts a blank
      one: stops playback, cancels proxy/import work, clears Project Media, one
      empty V1 + A1 track (via `_model.restoreTimeline([], [])`), clears the
      export range, resets preview quality and composition resolution to
      defaults, clears undo/redo history and clipboard, resets the playhead and
      Preview scrubber, and refreshes media list / timeline / inspector / title.
      The Preview shows "Import MP4 or MP3 media to begin".
- [x] **Safety**: the active project is autosaved FIRST (to its own file, or the
      app-state unnamed autosave `untitled-autosave.auroracut` when never
      saved), matching the existing autosave-on-exit contract, so creating a new
      project never loses the on-screen work. Logged via `appLog`.
- [x] Test hooks: `newProjectForTesting()`, `projectDirtyForTesting()`.
- [x] Regression block in `tests/editor_smoke.d`: New button exists/labeled/left
      of Save; a dirty project's New click resets path/dirty/media/tracks/
      history/export-range/resolution/quality/scrubber and autosaves the
      previous work into its project file; Ctrl+N (with an unnamed dirty
      project) resets the same state and autosaves into the unnamed autosave.
- [x] Verified: `dub test` → 34 modules pass; editor-smoke (full run) passes;
      model-smoke passes; the app links (temp output, since the running exe
      locks the target).
- [ ] Manual: launch Aurora Cut, edit a project, click New / press Ctrl+N, and
      confirm the blank timeline appears and the previous work is recoverable
      (from its project file or `%LOCALAPPDATA%\Aurora Cut\Autosaves`).

## 2026-08-18 — Output/export defaults to app-state folder + undo/redo history lives in the project file

- [x] User: "make aurora cut output/export folder by default to a subfolder on
      appdata", "make sure the redo and undo history is being saved in the
      appdata folder too", "do you think maybe projects should be saved there
      too?", then "maybe the undo redo history should be part of project file?"
- [x] **Exports**: the Export MP4/MP3 dialog now defaults its folder to
      `%LOCALAPPDATA%\Aurora Cut\Exports`
      (`auroracut.util.applicationExportDirectory`, created on demand).
      `FileDialogController.showSave` gained a `startPath` argument so any save
      dialog can open at a directory instead of the CWD; `openExportDialog`
      passes the Exports folder. Compressed output copies still land beside the
      last export (now inside Exports).
- [x] **Projects recommendation (my answer to the user's question)**: user-saved
      projects stay user-facing (Documents, wherever the user picks) — they are
      documents. But the *unnamed autosave* was living in
      `%TEMP%\Aurora Cut\Autosaves`, which Windows can wipe at any time; it now
      lives in `%LOCALAPPDATA%\Aurora Cut\Autosaves`
      (`projectAutosaveDirectory`). The Open-Project dialog's shortcut button
      (renamed `open-project-autosaves`, label "AppData autosaves") follows it.
      Because the autosave is a real project file, the unnamed project's undo/
      redo history rides inside it — so it IS stored in appdata for unnamed
      projects, and in the user-chosen folder for named projects.
- [x] **Undo/redo history — in the PROJECT FILE (per the user's follow-up)**: the
      `_undo`/`_redo` stacks are serialized into the `.auroracut` file itself
      (`"history": { "undo": [...], "redo": [...] }`), written atomically with
      the assets they reference. This replaces the earlier
      `%LOCALAPPDATA%\Aurora Cut\History` file approach (module `historystore.d`
      was deleted): history now travels with the project, cannot go stale
      against the asset array (saved together), and leaves no orphaned
      path-hash files when a project moves/renames. Tradeoff accepted: history
      is as durable as the project save itself (same crash window as edits).
  - `project.d`: `ProjectData` gains `undo`/`redo`; `saveProjectFile` gained
    trailing `undo`/`redo` params (default empty, so existing callers/tests
    still compile); `loadProjectFile` parses the optional `"history"` object
    and drops any snapshot whose media clips reference assets outside the
    loaded asset array (corrupt/hand-edited files). Old v2 files without
    history load with empty stacks. `TimelineSnapshot` stays in `model.d`;
    `snapshotToJson`/`snapshotFromJson` live in `project.d`.
  - `editor.d`: `writeProject` and `autoSaveProjectOnExit` pass the live
    `_undo`/`_redo`; `openProject` restores them from `ProjectData` right after
    loading (the `clearHistory` inside open still runs first). The appdata
    history-flush debounce, key tracking, and shutdown flush were removed.
  - The autosave-on-exit path saves the named project (with its history) to
    `_projectPath`, or the unnamed project to the appdata Autosaves file, so a
    clean close followed by reopen always restores undo/redo.
- [x] Verified: `dub test` → 34 modules pass (new project.d unittest covers
      history round-trip through the file, out-of-range-snapshot dropping, and
      legacy files without history); editor-smoke (2 runs) now asserts the
      saved project file's undo/redo stacks match the live editor and that
      reopening the project restores them; model-smoke, export-smoke,
      gpu-decode-args, recompress, layout, static-sequence pass; the app links
      (temp output, since the running exe locks the target). Obsolete
      `%LOCALAPPDATA%\Aurora Cut\History` data from the earlier approach was
      removed.
- [x] Also fixed two pre-existing stale tests the history work surfaced:
      `export_smoke` and `gpu_decode_args_smoke` asserted hardware-decode args
      on clips with no codec, but commit `ea3a12d` now only applies hardware
      decode to known H.264/HEVC sources — the accelerated-preview clips now
      declare `videoCodec = "h264"`. `recompress_smoke` compared the job's
      absolute output path against a relative one — it now builds an absolute
      path. (The hardware-decode failures were reproduced on the untouched
      baseline first.)
- [ ] Manual: export a project and confirm the dialog opens in
      `%LOCALAPPDATA%\Aurora Cut\Exports`; edit a project, quit, reopen, and
      confirm Undo/Redo still work; check a saved `.auroracut` file contains a
      `"history"` block; confirm the unnamed autosave is recoverable from
      `%LOCALAPPDATA%\Aurora Cut\Autosaves`.

## 2026-08-18 — Undo/Redo history popout window (new feature)

- [x] User: add a new popout window + toolbar button to Aurora Cut listing the
      undo/redo history; clicking an item undoes or redoes straight to that state.
- [x] Added a `History ▾` toolbar button (`id="history"`) directly after Redo in
      `source/auroracut/editor.d` (`buildToolbar`). It opens a centered-below
      `PopupOverlay` (`history-popup`, 440x400) with a `ListView`
      (`history-list`) showing a standard flat, numbered history: an `Initial
      state` row followed by each timeline action oldest-first
      (`1. …`, `2. …`, `…`), with the current state's row highlighted. Every row
      states the exact direction and step count ("Click to undo 2 steps",
      "Click to redo 1 step", "You are here") and carries a direction icon
      (refresh = undo, clock = current, chevron = redo).
- [x] Single click (or double-click / Enter) on a row jumps the timeline to that
      state via `jumpToHistory` (loops `undo()`/`redo()` the required steps). The
      list is FROZEN for the whole popup session: jumping only moves the
      highlighted row and re-styles each row's icon/step text; the item order and
      positions never change. The list is rebuilt only when history changes
      structurally (new edit commits or history is cleared via
      `commitHistory`/`clearHistory`). Toolbar/keyboard Undo/Redo move the
      highlight by one row via `moveHistoryHighlight` instead of rebuilding, so
      rows never jump around. The hint (`history-hint`) reports the live
      "Undo: N available • Redo: M available" counts.
- [x] Listing reworks (user: "the listing is confusing", then "make it standard
      items listing, it's confusing, overlapping items, items change positions
      if you click"): v1 was a flat ambiguous list; v2 added section headers and
      rebuilt on every click (reordering rows); v3 is a standard flat numbered
      list frozen for the session (no reordering) with no section headers.
- [x] Fixed two pre-existing vendored `ListView` bugs the popup exposed:
      (1) `_scrollOffset` could stay larger than `maxScroll()` after a resize,
      silently scrolling every row out of view (blank popup);
      `synchronizeScrollbar()` now re-clamps the offset. (2) two-line rows painted
      the secondary line 8 px past the 34 px row height, overlapping the next
      row; the paint now splits the row height between the two lines so text
      never crosses the row boundary. Both in
      `vendor/aurora-d-0.4.5/source/aurora/widgets/listview.d`.
- [x] Regression block in `tests/editor_smoke.d` (after the global Undo/Redo
      test): opens the popup, verifies the Initial state row, the numbered
      oldest-first actions, the highlighted current row, and the exact step
      counts; clicks a past row to undo to the empty timeline and a future row to
      redo back, proving the row order is IDENTICAL before and after each click
      (the "no reordering" guarantee), and verifies Esc closes it.
- [x] Verified: `dub test` (33 modules), editor-smoke (multiple runs),
      model-smoke, layout-smoke, and the full app compile/link (via a temp
      output, since the running `aurora-cut.exe` locks the normal target) all
      pass.
- [x] Right-click a history step to toggle whether it takes effect: the
      `ListView` gained a generic `onContextMenuRequested` (right-click → index +
      global point) in `vendor/aurora-d-0.4.5/source/aurora/widgets/listview.d`
      plus a `ListItem.dimmed` flag (muted but still clickable; keyboard
      navigation skips dimmed rows). The History popup wires it to
      `showHistoryContextMenu`: a per-step `Enabled` check (checked = active)
      toggles `_historyActionEnabled[row-1]`, with `Enable all steps` /
      `Disable all steps` bulk commands. The menu is shown via a popup-safe
      helper (`showHistoryContextMenuPopup`) because `showContextMenu` would
      dismiss the History popup itself (`dismissTransientPopups`).
- [x] A disabled step no longer takes effect: the row is dimmed with secondary
      "Disabled — right-click to enable" (the current row reads
      "You are here — disabled"), and it is never landed on. Clicks, jumps,
      AND toolbar/keyboard Undo/Redo (Ctrl+Z/Y) skip disabled steps: a press
      steps over disabled steps to the nearest enabled state (or Initial state).
      Undo/Redo are refactored into physical `stepUndo`/`stepRedo` helpers plus a
      `nearestEnabledPosition` that composes the landing target; `jumpToHistory`
      uses the same helpers and updates the undo/redo buttons after a jump.
      Toggles are preserved across popup opens and `refreshHistoryList` rebuilds
      (a new committed edit appends enabled; the dropped redo tail drops its
      flags), are kept in sync even while the popup is closed so Undo/Redo always
      know which steps to skip, and reset with the history on New/Open/Clear.
      The flags are session-only (not written into the persisted project-file
      history).
- [x] Toggling is an IMMEDIATE action (the user's key requirement — "disabling
      or re-enabling a history item should act like the Undo/Redo buttons"):
      disabling a step navigates the timeline right away to the nearest enabled
      step before it, reverting that step's effect (and any steps after it);
      re-enabling restores the full enabled state by navigating forward to the
      furthest enabled step (`lastEnabledPosition`). `Enable all steps` /
      `Disable all steps` act immediately too (to the last enabled step / the
      Initial state). Implemented via a shared `navigateTo(rawTarget)` used by
      both the popup rows and the context-menu actions.
- [x] Regression test in `tests/editor_smoke.d` (end of the history block):
      right-click a row, assert the `Enabled` check + bulk commands, click it
      off and assert the timeline IMMEDIATELY reverts (clip removed, highlight on
      the nearest enabled step, row dimmed, popup still open), press
      Ctrl+Y/Ctrl+Z and assert Undo/Redo skip the disabled step (clip
      returns/removes), re-enable and assert the full state restores (clip back,
      row no longer dimmed), assert jumps work normally again, then Disable all
      (timeline returns to Initial) / Enable all (timeline restores) and Esc
      closes.
- [x] Note: `tests/editor_smoke.d` is intermittently flaky in the video-decode /
      playback area independent of the history feature — "Direct video decoder
      never reached the end of its range" (a simulated-clock vs real-decode
      deadline) occasionally fails and rarely an access violation with no output
      occurs (~2/34 runs observed while validating this feature; the history
      block and everything else passed in every run). It is load/timing
      dependent, not a logic regression. LocalDumps diagnostics and debug-info
      runs did not reproduce a dump; a `-g` build passed 6/6.
- [ ] Manual: restart Aurora Cut (the running instance predates the recent
      rework), open the History popup, confirm the flat listing reads clearly,
      rows never move when clicked, jumps land correctly in both directions,
      and that right-clicking a step toggles it off (dimmed) and skips its
      effect on the next click.
- [x] Clicked buttons no longer keep a blue focus ring after the press is
      released (user: "unclicked buttons turn half blue... due to being focused
      after unclicking button like snap on button"). Root cause: buttons and
      lists call `requestFocus()` in `onMouseDown`, and their paint drew a blue
      accent ring for ANY focused widget, so e.g. clicking "Snap On" (turning it
      off / gray) left a persistent blue outline. Fix (Windows convention):
      `Button` and `ListView` in
      `vendor/aurora-d-0.4.5/source/aurora/widgets/{button,listview}.d` now track
      `_focusedByPointer` (set in `onMouseDown`, cleared in `onFocusChanged(false)`)
      and suppress the focus ring for pointer-acquired focus. Keyboard/Tab focus
      still shows the ring, and the widget still retains focus after a click.
- [x] Regression test in `tests/editor_smoke.d`: after clicking the Snap button
      off (plain gray + pointer-focused), a pixel sampled on the ring line
      (local y+2) must equal the plain fill below it (y+4) and carry no blue
      tint; also asserts the button retains focus. Keyboard focus ring behavior
      is covered by the existing logic (Tab/`cycleFocus` never sets the flag).
- [x] Fixed unrelated build breakage from an in-progress external refactor
      (persistent undo/redo history store `source/auroracut/historystore.d` +
      `TimelineSnapshot` moved to `auroracut.model`): added `TimelineSnapshot` to
      editor.d's `auroracut.model` import, added the missing `mkdirRecurse` import
      in historystore.d, fixed historystore.d's self-referential unittest dir
      initializer (`&directory` in its own declaration), and gave `workIn`/
      `workOut` explicit `0.0` defaults in `model.d`'s `TimelineSnapshot` (they
      defaulted to `double.init` = NaN, which `std.json` refuses to encode, so
      `saveHistoryStacks` always failed). Also changed `const restoredHistory` to
      `auto` at the `loadHistoryStacks` call site in editor.d (a `const` struct
      variable makes `restoredHistory.undo` `const(TimelineSnapshot[])`, which
      cannot assign into the mutable `_undo`/`_redo` fields). Verified via
      `dub test` (34 modules), editor-smoke, model-smoke, layout-smoke, and the
      app link check — all pass.

## 2026-08-15 — Aurora Notepad visual screenshot review

- [x] Launched the release build and captured/inspected `build/visual-review.png`.
- [x] No rendering problems found: titlebar icon, menu bar, editor, status bar, and 1 px border align correctly without clipping or overlap.
- [x] Opened the File dropdown through the headless interaction path and inspected its screenshot: all five commands, shortcuts, icons, hover treatment, and menu bounds are correct.
- [x] Live shadow verification remains separate from client screenshots: the DPI-aware probe confirmed the DWM gradient on all sides, with the expected weaker left/top shadow.

## 2026-08-15 — Aurora Notepad title icon prefilter

- [x] Diagnosed the source/render difference: the original 814x820 PNG is detailed artwork with transparent black RGB; direct linear reduction to the 16 px title icon produced hard gray/blue blocks at the rings and right shadow.
- [x] Replaced the intermediate derivative with a purpose-built clean 64x64 flat notebook title icon: blue header, four rings, page rules, no external side/bottom shadow. The original PNG remains the source/native asset; the native ICO is unchanged.
- [x] Verified `build/icon-flat-crop.png` has no left-side artifact; headless smoke still passes.
- [x] Documented the source-vs-renderer diagnosis in `aurora-notepad/ICON-RENDERING-IMPROVEMENT.txt`.
- [ ] Manual: inspect the final flat title icon in the live window.

## 2026-08-15 — Aurora Notepad drag-down restore keeps the maximized size (user complaint)

- [x] User: the new Aurora Notepad does not return to its initial window size
      after being dragged out of maximization. Root cause: `NotepadTitleBar`
      used the vendored widget's `maximized()` as its source of truth, but the
      vendored `TitleBar` clears its OWN maximized flag BEFORE firing
      `onRestoreRequested` — so `restoreFromDrag` bailed on `if (!maximized())
      return;` and never restored (the window stayed at the work-area extent).
      The stream app avoided this by tracking its own state.
- [x] Fix in `aurora-notepad/source/auroranotepad/titlebar.d`: the notepad now
      tracks its own `_maximized` (kept in sync via `setMaximized`) and uses it
      in `toggleMaximize` / `restoreFromDrag` / `applySnap` /
      `showSystemMenu` / `maximizedState`. `restoreFromDrag` also always forces
      `setWindowBounds(_restoredBounds)` after leaving fullscreen (same fix as
      the stream app).
- [x] Headless `PlatformWindow` now reports `windowBounds` (init = requested
      size, updated by `setWindowBounds`), so headless tests can verify
      restore/maximize bookkeeping the way the live platform behaves.
- [x] Regression test in `aurora-notepad/tests/headless_smoke.d`: maximize to
      the work area, drag the titlebar down, and assert the window returns to
      its initial size and the maximized state clears. (Test-order gotcha: the
      drag-restore press reused the snap test's titlebar point, which read as a
      double-click; a `resetClickState` between the two fixed it.)
- [x] Verified: notepad headless smoke passes, notepad `dub test` = 32 modules,
      notepad app links, aurora-gui titlebar smoke passes, vendored aurora-d
      `dub test` = 32 modules. Manifest regenerated.
- [ ] Manual: maximize the Notepad (button/double-click/drag-to-top), then drag
      down repeatedly — it must return to its initial size every time.

## 2026-08-15 — Drag-down restore sometimes keeps the maximized size (user complaint)

- [x] User: not every drag-down out of maximization returns the window to its
      initial size; sometimes it stays at the maximized extent. Root cause: the
      app's restore relied on the OS fullscreen placement OR `_restoredBounds`,
      and `_restoredBounds` could be stale/desynced when maximize state was
      mixed (snap-to-top sets the work-area size without entering fullscreen,
      then caption-maximize toggled the wrong flag). Fix in both
      `app_titlebar.d` and `demos/titlebar.d`: `_restoredBounds` is captured
      only when the window is genuinely restored, `toggleMaximize` is
      state-based (`_maximized || fullscreen` → restore, else maximize), and
      restore (drag and button) ALWAYS forces `setWindowBounds(_restoredBounds)`
      after leaving fullscreen — so the window reliably returns to its initial
      size.
- [x] Verified: aurora-stream application + notitlebar link; `dub test` = 46
      modules pass; vendor titlebar demo links; titlebar smoke test passes.
      Manifest regenerated.
- [ ] Manual: maximize (button, double-click, drag-to-top), then repeatedly
      drag down — the window must return to its pre-maximize size every time.

## 2026-08-15 — New Aurora Notepad project + custom downstream titlebar

- [x] Scaffolded a new downstream app `aurora-notepad/` on the vendored
      Aurora-D, mirroring the aurora-image-viewer pattern: DUB recipe with
      `portable-release` + GUI-subsystem policy, `RUN-WINDOWS.bat` /
      `RUN-WINDOWS-SOFTWARE.bat` launchers, `source/app.d` with a
      `--screenshot` headless mode. Registered in `scripts/version.py`,
      `scripts/build-portable-windows.py`, and
      `.github/workflows/portable-windows.yml` so CI builds/ships it.
- [x] `NotepadTitleBar` (`aurora-notepad/source/auroranotepad/titlebar.d`):
      the custom downstream titlebar. Subclasses the vendored `TitleBar` and
      owns ALL window chrome as one reusable widget: Notepad light styling,
      owner-driven drag (`onDragStarted`/`onDragMoved` through
      `setWindowPosition`, not the OS caption loop), restore-on-drag that
      re-anchors the grabbed spot under the pointer, work-area
      maximize/restore via `GuiWindow.setWindowBounds` (never native
      fullscreen, so the taskbar stays visible), the right-click system menu,
      and aero-style drag snapping that broadcasts preview bounds through
      `onSnapPreview` and applies the target on release.
- [x] `NotepadRoot` (`auroranotepad/appui.d`) hosts the titlebar over a
      minimal editor + status strip, plus the input-transparent
      `TitleBarSnapPreview` overlay (created disabled, so it paints on top
      without swallowing clicks — the same fix as the vendor titlebar).
- [x] Headless smoke (`aurora-notepad/tests/headless_smoke.d`) drives the real
      `UiTestDriver` dispatch path: caption callbacks, work-area maximize
      (test work area → `lastWindowBounds`), double-click maximize toggle,
      left-edge drag-snap applying 960x1040, preview show/hide + input
      transparency, document-title dirty/clean updates, and a saved screenshot.
- [x] Verified: debug + release builds link; headless smoke passes; the live
      `--screenshot` mode of the real exe works; a pixel check confirms the
      custom titlebar renders (background `0xf7f9fc`, dark title text, red
      close glyph); `verify-windows-gui-subsystem.py` and
      `verify-windows-portability.py` both pass for the new recipe.
- [ ] Manual (live): run `aurora-notepad\RUN-WINDOWS.bat`, drag the titlebar
      to top/sides/corners, use the caption buttons and the right-click system
      menu, double-click to maximize, and drag down from maximized. Next
      milestones: real File/Edit menus, a tab strip in the titlebar content
      slot, open/save dialogs, and the editor polish.

## 2026-08-15 — Aurora Notepad: smaller icons (titlebar + buttons)

- [x] Upstream: added `TitleBar.setIconSize(int)` and `Button.setIconSize(int)`;
      Button's default icon size lowered 22 → 18. Button width is text-measured
      (`horizontalChrome` independent of `_iconSize`), so icons shrink without
      resizing the buttons.
- [x] Notepad titlebar icon is now 16 px (`setIconSize(16)`), Win10-style.
- [x] Verified: headless smoke passes; screenshot shows the titlebar icon bbox
      at exactly 16×16 logical; a headless probe confirms a text+icon Button
      still measures 94×38 (unchanged) while its icon row spans exactly 18 px.
      Vendor `MANIFEST.sha256` regenerated.

## 2026-08-15 — Aurora Notepad: real 1 px border + DWM frame/shadow

- [x] Diagnosed with a DPI-aware screen probe (the earlier pixel reads were
      wrong: the probe was DPI-unaware so `GetWindowRect` returned logical
      coords while `ImageGrab` read physical pixels): the window had NO 1 px
      border (every edge went shadow→content) and DWM's shadow was present but
      asymmetric (strong right/bottom, subtle left/top — authentic Win10).
- [x] Added a theme `WindowBorder` overlay (input-transparent, painted last) so
      every frameless notepad window draws a 1 px `theme.border` border on all
      four sides regardless of DWM.
- [x] Upstream (`aurora.platform.win32`): frameless windows now call
      `DwmExtendFrameIntoClientArea(hwnd, {1,1,1,1})` for the full DWM frame +
      drop shadow; `applyDarkTitleBar` became `applyFrameStyle(hwnd, dark)`
      (light/dark border colors; the DWMWA color attributes are Win11-only and
      silently fail on Win10); added `GuiWindow.setFrameDark(bool)` so the
      notepad re-colors the frame on theme toggle. Notepad now starts
      `darkTitleBar=false` (light frame) and calls `setFrameDark(_dark)`.
- [x] Verified: headless smoke passes; the headless screenshot shows the
      `0xd6d6d6` border at x=0/w-1/y=0/h-1; a clean DPI-aware live probe shows
      the border (214,214,214) on all four edges plus the DWM shadow
      (right/bottom strong, left/top subtle).
- [ ] Manual (live): the window should now read like a real Win10 window — a
      1 px light-gray border on all sides and a drop shadow. The left shadow
      is intentionally subtle (DWM's standard Win10 asymmetry; real Win10
      windows are identical). If you still want a stronger left shadow, that
      needs a transparent-margin/Aurora-drawn approach (bigger change).

## 2026-08-15 — Aurora Notepad: real Win10 Notepad menu bar + window shadow

- [x] Replaced the button toolbar with the authentic Windows-10-Notepad menu
      bar: `File  Edit  Format  View  Help` flat text items on the window
      background with a 1 px bottom hairline (`aurora-notepad/…/menubar.d`).
      Each opens a dropdown `ContextMenu` below itself
      (`showContextMenuBelow`).
- [x] Wired menus: File = New/Open/Save/Save As/Exit; Edit = Undo/Redo/Cut/
      Copy/Paste/Delete/Select All/Time-Date (F5 inserts a Win10-style
      timestamp); Format = Word Wrap (check); View = Status Bar (check) +
      Dark Theme (check); Help = About.
- [x] Added public editor menu commands to the vendored `texteditor.d`
      (`cutToClipboard`, `copyToClipboard`, `pasteFromClipboard`,
      `deleteSelectionCommand`, `insertTextAtCursor`).
- [x] Window shadow: frameless windows got `CS_DROPSHADOW` in
      `aurora.platform.win32` (DWM now draws the transparent drop shadow), and
      frameless windows without an explicit position are centered on the
      monitor's work area instead of `CW_USEDEFAULT` → (0,0), which had been
      clipping the left/top shadow at the screen corner.
- [x] Verified: debug + release build; headless smoke passes (5 menu items,
      File dropdown opens, hover highlight); pixel checks confirm the menu bar
      text row (File/Edit/Format/View/Help groups) and the File dropdown
      (New/Open/Save/Save As/Exit with accent icons + hover); the vendor
      `MANIFEST.sha256` was regenerated.
- [ ] Manual (live): click each menu and try the items (New/Open/Save, wrap,
      theme, time/date, status bar toggle), drag the titlebar, and confirm the
      window now shows the drop shadow on all sides when centered.

## 2026-08-15 — Aurora Notepad: full Windows-10 look

- [x] Entire app re-skinned as Windows 10:
      - Titlebar: white (light) / `0x202020` (dark), Win10 red close
        `0xe81123`, neutral hover grays, 28 px.
      - Command band: light gray `0xf0f0f0` (dark `0x2b2b2b`) with compact
        flat text-only buttons.
      - Editor: borderless white / `0x1e1e1e`, Consolas 11 pt size via
        `setPixelSizeOverride(14)`.
      - Status bar: gray `0xf0f0f0` band (Panel) with a 1 px `0xd6d6d6` top
        hairline (`Separator` painted over the band edge) and left-padded text.
      - Theme: Win10 palette (accent `0x0078d4`, danger `0xe81123`, neutral
        hover grays, corner radius 3, control height 32, `fontScale =
        TextScale.caption` = 13 px UI text).
- [x] Verified: builds link; headless smoke passes; live screenshot pixel check
      confirms white titlebar → `0xf0f0f0` command band → white editor →
      `0xf0f0f0` status band with the `0xd6d6d6` hairline and status text.
- [ ] Manual (live): check the whole window reads like Windows 10 Notepad in
      both light and dark (F6 / the Dark button), hover the caption and
      toolbar buttons, and confirm the status hairline.

## 2026-08-15 — Aurora Notepad: true Windows-10 toolbar (band + flat compact buttons)

- [x] Toolbar now looks like Windows 10: a visible gray command band
      (`0xf0f0f0` light / `0x20262e` dark) holding compact flat text-only
      buttons. The band's own padding (`HBox(4, Insets(6, 4))`) keeps buttons
      ~30 px tall and vertically centered instead of ballooning to full
      control height.
- [x] Removed the big icons from the toolbar buttons; all buttons are flat
      (`setFlat(true)`) with a neutral Win10 hover highlight — the light theme
      hover is `0xe5e5e5` / pressed `0xd4d4d4` and the dark theme
      `0x3a3a3a` / `0x2e2e2e` (no blue tint), corner radius 4.
- [x] `toggleTheme` re-paints the toolbar band and re-styles the titlebar.
- [x] Verified: builds link; headless smoke passes; live pixel check shows the
      28 px titlebar, the `0xf0f0f0` toolbar band with text-only buttons, and
      a `0xe5e5e5` hover highlight on the first button while the editor stays
      borderless white.
- [ ] Manual (live): hover the flat buttons for the subtle gray highlight and
      confirm the band + compact buttons read like Windows 10.

## 2026-08-15 — Aurora Notepad: Windows-10-style flat toolbar + taller titlebar

- [x] Titlebar raised 22 → 28 logical px (`setBarHeight(28)`).
- [x] Toolbar buttons converted to Windows-10 casual flat style: every button
      uses `setFlat(true)` (transparent background, no border, only a subtle
      rounded hover/pressed highlight). The Save accent was removed so the
      toolbar reads as one flat Win10 command bar.
- [x] Verified: builds link, headless smoke passes (bar height assertion, drag
      at the middle row y=14), live screenshot pixel check confirms the
      titlebar is 28 px with its `0xc8d2dd` bottom border and the toolbar row
      shows only text/icons (accent glyphs + text on the transparent window
      background) — no button chrome until hover.
- [ ] Manual (live): hover the flat toolbar buttons to see the subtle Win10
      highlight, and confirm the taller bar drags comfortably.

## 2026-08-15 — Aurora Notepad: slim titlebar, toolbar, borderless editor

- [x] Titlebar height halved 44 → 22 logical px (`setBarHeight(22)`); the
      Notepad toolbar takes over the action buttons.
- [x] Added a 38 px toolbar (`HBox`) between the titlebar and the editor with
      New / Open / Save (accent) / Wrap / Dark buttons, wired to real
      open/save dialogs, wrap toggle, light/dark theme toggle (also re-styles
      the titlebar via the new `NotepadTitleBar.setDarkMode(bool)`), and
      Ctrl+N/O/S shortcuts. Dark theme added (`darkNotepadTheme()`).
- [x] Editor is borderless: `setShowBorder(false)` + `setFocusDecoration(false)`
      so the text area never paints the accent field focus ring.
- [x] Smoke updated for the 22 px bar (drag press at the middle row), toolbar
      assertions, editor focus/refocus, and a focused-editor screenshot. Pixel
      checks: titlebar row is `0xf7f9fc` with the `0xc8d2dd` bottom border,
      toolbar shows buttons (17 distinct colors), editor top edge is pure
      white with zero accent-blue pixels while focused.
- [ ] Manual (live): confirm the slim bar still drags comfortably and the
      toolbar Open/Save dialogs work on the real window.

## 2026-08-15 — Close button ignored the close-to-tray setting (user complaint)

- [x] User: after setting the setting, pressing the Close button still went to
      the tray. Root cause: `StreamRoot.closeRequested()` had a hard
      "once the tray icon exists, X never exits" override that ran BEFORE the
      `closeToTray` check, so even with close-to-tray disabled the Close button
      hid to the tray. Removed the override; `closeToTray` now fully decides
      (enabled default → tray; disabled → real exit, tray removed on shutdown).
- [x] Verified: aurora-stream application links; `dub test` = 46 modules pass.

## 2026-08-15 — Minimize-to-tray no longer default (user complaint)

- [x] User: minimize kept the app in the tray instead of minimizing to the
      taskbar, which was annoying. Minimize-to-tray is now opt-in: a new
      `minimizeToTray` setting (off by default, persisted in the settings JSON
      schema 8) gates the titlebar/system-menu minimize AND the onTick
      auto-conversion of any native minimize into a tray-hide. Plain minimize
      to the taskbar is the default again. Exposed as a checkbox in the
      settings menu ("Minimize button hides to tray instead of minimizing to
      taskbar") and reported in the startup settings line.
- [x] Verified: aurora-stream application + notitlebar link; `dub test` = 46
      modules pass, including the extended schema-8 settings round-trip tests
      (minimizeToTray round-trips, defaults off, explicit on/off respected).

## 2026-08-15 — Distorted single frame while resizing (user report)

- [x] Diagnosed: NOT a regression from the titlebar/snap work — that commit
      never touches the resize path. The distortion is the pre-existing
      software live-resize proxy (`presentScaledResizeFrame` →
      `StretchDIBits`), used whenever `liveResizeScalingSupported()` is false
      (Software renderer, or Vulkan without swapchain present-scaling). The
      proxy presented ONE frozen pre-resize snapshot stretched with
      nearest-neighbor for the whole drag. User runs aurora-stream via
      `aurora-stream\RUN-WINDOWS.bat` (`RendererPreference.automatic`).
- [x] Improved the fallback: `StretchDIBits` now uses `HALFTONE` (interpolated)
      with a `SetBrushOrgEx` reset; `onNativeTick`/`scheduleLiveResizeExactFrame`
      no longer gate exact frames on `liveResizeScalingSupported()`, so the
      window re-renders real content during resize at the same bounded 1/60 s
      cadence and re-arms the proxy snapshot from each exact frame. Vulkan with
      WSI scaling is untouched.
- [x] Verified: titlebar smoke test + widget module unittests (17) pass; vendor
      `dub test` = 32 modules pass; aurora-stream application + notitlebar,
      aurora-cut, and the vendor titlebar demo all link. Manifest regenerated.
- [ ] Manual: drag a border of aurora-stream and confirm content tracks the
      size smoothly instead of one frozen blocky stretch. `AURORA_RESIZE_PROFILE=1`
      prints scene/render times in the window title for tuning.

## 2026-08-15 — TitleBar drag-to-snap (new standard Notepad foundation)

- [x] Built aero-style drag snapping into `aurora.widgets.titlebar.TitleBar` as
      the foundation the new standard Notepad will be built on. While a
      titlebar drag is active, the widget samples the real screen pointer
      against the monitor work area and reports a `TitleBarSnapTarget`: top =
      maximize, left/right = half-screen, corners = quadrants, bottom alone
      never snaps; `snapThreshold` (8 logical px) sets edge engagement.
- [x] New `onSnapChanged(target, bounds)` (fires on every target change incl.
      back to `none`, for preview show/hide) and `onSnapApplied(target,
      bounds)` (fires on release over a live zone; owner applies bounds via
      `GuiWindow.setWindowBounds`). Release over a zone skips the final
      drag-move so the window never lands on the last pointer position first.
- [x] New reusable `TitleBarSnapPreview` translucent overlay widget. **Fixed
      regression:** it is created disabled (`setEnabled(false)`), so it paints
      on top but is transparent to hit testing (`Widget.hitTest` skips disabled
      widgets). The first version was an enabled full-size last child that
      swallowed every mouse-down, which made the live titlebar (buttons + drag)
      completely unresponsive — reverted by the user, then re-done with this
      fix. Covered by a headless regression: caption buttons + drag must still
      work with the full-size preview present.
- [x] Platform plumbing: `NativeWindow.queryWorkArea` (Win32 MonitorFromPoint +
      GetMonitorInfoW rcWork), `NativeWindow.setWindowBounds` (SetWindowPos),
      `WidgetHost`/`Widget` `queryPointerScreenPosition` + `queryWorkArea`,
      `GuiWindow` passthroughs. Headless PlatformWindow + `UiTestDriver` gained
      `setTestWorkArea`/`setTestScreenPointerPosition`/`lastWindowBounds`.
- [x] Wired into `demos/titlebar.d` and the Aurora Stream custom-titlebar app
      (`app_titlebar.d`).
- [x] Fixed drag-to-unmaximize (user complaint: "the states of drag titlebar to
      unmaximize are not perfect... it didn't happen multiple times"). Two root
      causes: (1) releasing a just-restored window while the pointer was still
      inside the top-edge snap zone snapped it straight back to maximized —
      the widget now suppresses snap until the pointer leaves the zone it
      restored from, then snapping resumes (regression test covers restore →
      no snap-back → snap re-engages on the left edge); (2) the apps' restore
      used `toggleFullscreen()`, which entered fullscreen when the window was
      maximized by drag-snap-to-top (work-area bounds, never fullscreen) — the
      apps now save the pre-maximize bounds and restore to them regardless of
      how the window was maximized.
- [x] Verified: titlebar smoke test (left-edge, top-edge/maximize, preview
      clear, disabled, input-transparency regression, snap-back regression,
      preview paint) passes; widget module unittests cover the pure target/
      bounds mapping incl. corners and non-zero work-area origins; vendored
      aurora-d `dub test` = 32 modules pass; `dub build` links for aurora-stream
      (application + notitlebar — the earlier application link was only blocked
      while `aurora-stream.exe` was running and locking the file), aurora-cut,
      aurora-opencode, aurora-opencode-pro, aurora-image-viewer, and every
      vendor demo config.
- [ ] Not yet interactively dragged in the real GUI on this host; live-click
      automation is unreliable here because a fullscreen window (e.g. maximized
      Edge) covers the demo and intercepts clicks. Verify manually: Alt+Tab to
      the demo first, then drag to top/sides/corners and use the buttons.
      Deferred TitleBar polish (caption-button tooltips, icon left-click /
      right-click-caption system menu) stays open.

## 2026-08-15 — Aurora Stream VLC/window capture v0.66.1 rejection and replacement

- [x] Marked v0.66.1 window capture failed after the release screenshot showed
      the same black/white VLC GDI surface.
- [x] Proved the current game hook is not a VLC fallback: it connects/injects
      into VLC 3.0.20 but receives zero Present frames from the top-level and
      Direct3D child HWNDs.
- [x] Replaced standard window capture with Windows Graphics Capture through the
      selected HWND (`gfxcapture`); disabled cursor, yellow border, and capture
      border; retained the existing 60 FPS scale/pad/timestamp normalization.
- [x] Replaced the live canvas HWND-GDI path with persistent compositor preview.
      VLC disables PrintWindow and Game capture, and the UI persists the corrected
      modes. A minimized target clears the canvas, reports/logs a bounded timeout,
      and no longer deadlocks application shutdown.
- [x] Added a background-only integration check that launches Aurora without
      activation, uses isolated portable settings, captures Aurora itself through
      WGC, and optionally compares its canvas against a direct static VLC frame.
      Repeated comparison MAE: 1.916-2.136 RGB levels. A stricter rerun sampled
      the foreground owner throughout and proved Aurora was never activated.
- [x] Made the GUI integration launch itself non-activating at the native Aurora
      window layer. The final test kept foreground ownership unchanged while
      validating a complete 1600x975 Aurora canvas; packaged-app tests can also
      remove external FFmpeg from the app's PATH so embedded-tool extraction is
      exercised rather than masked.
- [x] Tested the exact POSIX-thread Actions FFmpeg artifact on real Windows:
      colored HWND probe passed, VLC delivered 60/60 compositor frames, and a
      five-second H.264/AAC recording contained exactly 300 video frames at
      60/1 with both streams exactly 5.000 seconds. The decoded frame was 86.4%
      non-black with full RGB extrema.
- [x] Hardened single-exe extraction: FFmpeg/FFprobe use a content-addressed,
      byte-verified cache, so a stale same-size binary cannot be mistaken for
      the new bundled payload and locked old tools do not block an upgrade.
- [x] Three complete local production A/V repetitions passed. Every 15-second
      phase produced 900/900 1080p60 frames, zero progress drops/duplicates and
      queue warnings, and 705 contiguous AAC packets. The real WASAPI phases
      captured 1,542-1,604 packets with no transport failures or discontinuities.
- [x] D3D11 hook regressions passed independently for BGRA8, RGBA8, and RGB10A2;
      tests stayed minimized/background-only.
- [x] Minimal pinned-FFmpeg CI run `31870550684` exposed `gfxcapture` and its
      HWND/border options and uploaded artifact `9243361794` (ZIP SHA-256
      `95344aa73403d09608221a030efec7452e88b47c9427b6fb902184dbc341feb6`).
      Its exact executables passed the real local WGC/VLC and 300-frame A/V
      recording checks.
- [x] Portable Windows CI run `31870945690` embedded that FFmpeg payload,
      rebuilt the D-only hook, passed PE/static-runtime checks, and produced
      artifact `9243407740` (ZIP SHA-256
      `af5d29f252f9e38c3ea9b5e3c9cadb4d11bbfc62a821ad3913e7805f85732c29`).
      The downloaded single EXE passed bundled extraction, VLC preview,
      minimized-window, synthetic audio transport, and endpoint diagnostics.
- [x] Bumped Aurora Stream to 0.66.2 only after the local and feature-branch
      portable gates passed.
- [x] Fast-forwarded `main`; final main minimal-FFmpeg run `31871356491` and
      portable run `31871356484` passed. Their downloaded artifacts repeated
      the real WGC, exact 300-frame production encode, single-exe VLC preview,
      and synthetic transport checks without foreground activation.
- [x] Tagged and published v0.66.2. Tag portable run `31871848599`, tag
      minimal-FFmpeg run `31871848613`, and the corrected asset-label workflow
      run `31871987081` passed. The final public `aurora-stream-v0.66.2.exe`
      (SHA-256
      `d573bda61176166a1cd448aba805d3c6b3f8d64027bb16929e75c0dac4d5f152`)
      repeated version, static-CRT, bundled extraction, synthetic transport,
      endpoint JSON, normal VLC preview, and minimized VLC tests without
      foreground activation.
- [ ] User performs the first authenticated YouTube test. No autonomous task
      has stream credentials.

## 2026-08-14 — Aurora Stream VLC still black/white in 0.66.0

- [x] User screenshot confirmed the VLC safeguard was incomplete: PrintWindow
      was disabled, but normal capture and the live canvas still read VLC's HWND
      GDI surface, which cannot contain its independently composed D3D11 video.
- [x] VLC now uses a clipped visible client rectangle from the composed desktop:
      DDA region when available, cropped `gdigrab desktop` otherwise. Preview and
      broadcast share the same geometry; preview preserves aspect ratio.
- [x] Partly off-screen geometry is clipped before capture. Verified the observed
      1532×710 visible region through the shipped GDI fallback: exact 4,350,880
      BGRA bytes and 31.8% non-black pixels, without a fullscreen test.
- [x] Fixed minimal FFmpeg: `ddagrab` moved from `--enable-indev` to
      `--enable-filter`. Actions and portable packaging now fail if the expected
      DDA/GDI/audio capture inventory is missing.
- [x] Desktop Duplication selection now rejects successful all-black BGRA probes.
- [x] Minimal-FFmpeg CI run #16 passed with `ddagrab`/`hwdownload` and
      `gdigrab`/`dshow`/`lavfi` present. Portable run #39 attempt 2 accepted the
      new payload, built all single-exe applications, and passed static-CRT
      checks. Release run #40 published v0.66.1 with five assets. The downloaded
      Aurora Stream asset matched its published SHA-256 and passed headless
      version plus synthetic audio-bridge checks.

## 2026-08-14 — Development-process complaint: tests disturbed desktop use
- [x] User complaint: a fullscreen quality diagnostic interfered with normal
      computer use and was closed. From now on, do not run fullscreen or
      foreground interactive diagnostics autonomously. Prefer headless tests;
      launch unavoidable GUI tests minimized/backgrounded, track their process,
      and terminate them cleanly. Do not repeat a fullscreen harness without an
      explicit user request. Headless transport/RTP/network/loaded-audio tests
      were repeated afterward and passed.

## 2026-08-14 — Aurora Stream standard-flow verification
- [x] Headless checks passed: `verify-audio-transport.py`, `verify-rtp-sdp.py`
      (direct + FIFO FLV), `verify-network-output-isolation.py`,
      `--audio-bridge-session-test --synthetic`, endpoint JSON parsing, and
      `dub test` (44 modules).
- [x] Loaded-audio diagnostic passed both phases: 720 encoded frames each,
      final speed 1.020x/0.996x, no RTP loss/overrun, no pacing skips, no send
      failures, and no queue warnings.
- [ ] Full visual quality harness was intentionally stopped because it opens a
      fullscreen interactive test card and disturbed normal desktop use. It is
      not marked passed; redesign it as a headless/offscreen visual source
      before using it for autonomous acceptance.

## 2026-08-14 — Aurora Stream: improved always-on activity logging — DONE
- [x] User: "improve logging so that final release of aurora stream would show
      exactly what errors and what problems happen and what actions are taken,
      so we know exactly how to resolve things once problems appear or target
      things faster and resolve faster."
- [x] `ActivityLog` gained severity-tagged helpers (`info`/`warning`/`error`/
      `action`) + a `path()` accessor; documented the tag format in the module
      doc comment. The always-on `aurora-stream-activity.log` is now the single
      session-spanning problem/action record.
- [x] `BroadcastWorker` receives the `ActivityLog` and mirrors exact failure
      reasons + actions: stream start rejected, FFmpeg startup timeout, live
      output stall, desktop capture stall, window closed/minimized mid-stream,
      Desktop Duplication loss + relaunch (recovery N of 3), audio-helper
      failure, UDP -10048 bind race retry/give-up, unexpected exit, and a final
      session-end line. FFmpeg warning lines are mirrored as `[WARNING] FFmpeg:`
      (secret-sanitized).
- [x] `StreamRoot` logs startup version, encoder/capture detection (incl.
      D3D11-direct fallback warning), settings load/save results, capture-window
      fallback, audio device inventory (deduplicated on change) and scan errors,
      update check/install, browser-open failures. `toggleStreaming` logs the
      user start/stop request as `[ACTION]`.
- [x] Settings menu -> "View activity log" opens the file with the OS default
      handler (`openLocalFile` added to `browser.d`).
- [x] User actions are logged too (user: "do we log what user does too? yeah
      but don't expose stuff like stream keys or sensitive data"): capture
      source, source/YouTube quality, YouTube bitrate, Twitch/YouTube enable
      toggles, window-content capture, live source preview, streaming-server
      fields, minimize-to-tray / close-to-tray, desktop audio / microphone
      selection (friendly name only), audio refresh, browser quick-link opens,
      browser choice, settings menu opens. **Stream keys are NEVER logged** —
      text fields log only populated/cleared transitions via
      `logFieldPopulatedChange` (content stays out of the log; paste success is
      reported without the key).
- [x] Environment + settings report (user: "i hope log include settings/options
      and os and other things we might need"): new `aurorastream/environment.d`
      logs a startup `[INFO]` block with OS name/build/edition + architecture
      (from the registry, reliable on Win10/11), CPU model + logical processor
      count (registry), RAM, GPU adapter(s) + current display mode via
      `EnumDisplayDevicesW`/`EnumDisplaySettingsW`, the FFmpeg build actually
      in use, and a safe settings summary (destinations, encoder, capture,
      qualities/bitrate, audio devices, window-content capture, live preview,
      tray options, browser, config mode, and stream-key *presence* only).
      Stream keys and server URLs never appear. Added `advapi32` to
      `dub.json` libs for the registry read (`RegGetValueW`).
- [x] Verified: `dub test` (44 modules pass, incl. the environment settings-
      report unittest asserting no key leakage), `dub build` (application) and
      `dub build --config=notitlebar` link, and a live launch logged the full
      OS/CPU/RAM/GPU/FFmpeg + Settings block in `aurora-stream-activity.log`.

## 2026-08-14 — Aurora Stream: OBS-style game capture (D3D11 render hook) — IMPLEMENTED
- [x] User: "We want to stream a window even if it's minimized or out of focus
      or not here. That's the main point." → then "we need just like obs per
      game render hooks." The proper fix = OBS Game Capture-style render hooks
      (hook `IDXGISwapChain::Present` inside the game, capture the back buffer),
      built entirely in D (no C toolchain on this machine).
- [x] Built `aurorastream/d3d11.d`: raw D3D11/DXGI COM bindings (explicit
      vtable-struct layouts; D `interface` does NOT dispatch through native COM
      vtables). Verified device/swapchain/RTV/clear/present in a D test app
      (16,684 frames).
- [x] Built `gamecaphook.d`: an injectable `-betterC` DLL with a custom entry
      (`/ENTRY`, `/NODEFAULTLIB`) — a normal DMD DLL crashes in a foreign
      process (0xC0000409, verified). Reads `%TEMP%\aurora-gamecap-<pid>.cfg`,
      patches the shared `IDXGISwapChain` vtable Present slot, connects a named
      pipe. VERIFIED: injects into notepad + a D3D11 app, patches, connects the
      pipe, and `hookPresent` reaches `captureFrame`.
- [x] Injector + transport (`tests/gamecap_test.d`, `inject_notepad.d`).
      CRITICAL gotcha: `&LoadLibraryW` in D = this exe's import thunk, NOT the
      kernel32 function — must use
      `GetProcAddress(GetModuleHandleW("kernel32"),"LoadLibraryW")`.
- [x] **BLOCKER RESOLVED — D3D11 vtable layout was wrong.** The device vtable has
      `GetCreationFlags` (38) and `GetDeviceRemovedReason` (39) BEFORE
      `GetImmediateContext`, so the real slot is **40**, not 38. Verified against
      the authoritative mingw-w64 `d3d11.h` (fetched). `GetImmediateContext` now
      returns the real context (`match=true`).
- [x] **Frame capture works end-to-end.** Hook → back-buffer GetBuffer →
      asynchronous staging ring → nonblocking Map → BGRA → worker-owned shared
      ring/control pipe → bounded host reader. Final minimized 1920×1080 tests cover BGRA8,
      RGBA8, and RGB10A2, two unload/reinject rounds plus the production session
      per format. Final shared-memory rounds delivered 236–237 non-black, changing,
      color-correct frames in four seconds; production received 238–239 with
      ordered protocol sequences.
      - named-pipe frame payloads consumed roughly 500 MB/s at 1080p60; pixels
        now cross a three-slot shared-memory ring and a 64 KiB pipe carries only
        versioned control/frame headers.
      - releasing COM objects must go through the OBJECT's own vtable with an
        `extern(C)` call (`comRelease`); releasing through another object's
        vtable (or `extern(D)`) crashes.
      - `scope(exit)` cleanup in the betterC hook was unreliable → explicit
        cleanup.
      - hook rate-limits on QPC to 60 fps; the background test target uses a
        high-resolution waitable timer at 250 fps instead of monopolizing the
        GPU with an unbounded minimized swapchain.
- [x] Aurora Stream now persists a separate `gameCaptureMode`, exposes a
      mutually-exclusive Game capture (D3D11 render hook) option beside the
      selected window, creates the shared ring/control pipe/config, injects through the
      real kernel32 `LoadLibraryW` export + `CreateRemoteThread`, parses the
      versioned 72-byte protocol, aspect-fits through a reusable HALFTONE DIB,
      and reuses the exact-cadence rawvideo pump with held-frame duplication.
- [x] `gamecaphook.dll` is embedded/extracted for `portable-single-exe`; the
      portable Windows script builds/stages it with DMD only. The hook debug
      file body is version-gated behind `GameCaptureDebug`, so release builds
      do not emit `C:\temp\gamecaphook_dbg.txt`.
- [x] Verified with all 45 D unittests, x64 debug application + notitlebar
      builds, the three-format framed hook/session matrix, audio/RTP/network
      scripts, and both 720-frame loaded A/V phases. Screen gdigrab and
      PrintWindow remain separate paths. x64-only; anti-cheat games can still
      block injection (same operational limitation as OBS).
- [ ] Not tested: a real authenticated network stream using the new mode; no
      autonomous test has stream keys.
- [x] Official portable single-exe CI result: Windows Actions run #37
      (`31830461788`, commit `081ece8`) built the optimized D-only hook and all
      single-exe applications, passed the PE static-runtime checks, and produced
      the 27.4 MB `aurora-windows-portable` artifact with SHA-256
      `b2c53367506888071127fa1ef89aaea0bf0eb00add4f0bf5f55b2b827abd2730`.

## 2026-08-14 — Aurora Stream: minimize to tray (auto-hide on start + close-to-tray + tray icon controls)
- [x] User: "let's consider if we could do 'minimize to tray' for aurora stream.
      and add option 'if we click start stream' it would minimize to tray icon
      with options of stop stream or exit entirely or show up window back. I also
      wonder if we could just make it possible to single click tray and toggle
      between start stream and stop stream. Double clicking would show up window
      back."
- [x] `aurorastream/trayicon.d` (new, Windows): a real `Shell_NotifyIcon` tray
      icon owned by a small hidden Win32 window whose messages are pumped by the
      main Aurora loop (a normal hidden top-level window, not HWND_MESSAGE, for
      shell compatibility). Loads the app icon (`applicationIconPath`), tooltip
      reflects Idle/Streaming, balloon notifications (`NIF_INFO`) report
      tray-triggered outcomes, and it re-adds the icon on Explorer restart
      (`TaskbarCreated`).
  - **Single click** = toggle Start/Stop streaming, deferred through a
    `GetDoubleClickTime()` timer so the first click of a double-click cannot
    toggle; **double click** = restore the window (the trailing UP of a real
    double-click is suppressed via a DBLCLK timestamp).
  - **Right click = a fully custom, self-drawn tray menu** (user: "I asked for
    custom tray context menu just like steam tray have ... completely
    customized"). `TrayContextMenu` is a borderless topmost popup window
    rendered with GDI in the app's dark gray palette (`#252c34` bg, `#2b333d`
    hover, separators, bold default item, disabled status row, 1 px border) —
    never the OS (light) menu. It opens at the cursor (clamped to the work
    area), highlights on hover, and posts the chosen command (`wmMenuAction`)
    to the owner tray window so the action runs after the window is gone.
    Replaces the earlier TrackPopupMenu version AND the SetPreferredAppMode
    (ForceDark) attempt (which did not actually darken native menus on this
    machine).
  - **Menu did not close on outside click (user report "tray context never
    closes unless you click item").** Reproduced in the real app: Escape closed
    the menu but a real click on the desktop left it open. Root cause (debug
    log): `SetCapture` does NOT reliably deliver clicks on shell/desktop
    windows to the captured window — the menu received no `WM_LBUTTONDOWN` at
    all. Fix: the menu now (a) shows ACTIVATED (`SW_SHOW` +
    `SetForegroundWindow`) so an outside click deactivates it and
    `WM_ACTIVATE WA_INACTIVE` closes it, and (b) installs a `WH_MOUSE_LL`
    low-level mouse hook while open that closes the menu on any press outside
    its rectangle (posted via `wmMenuCloseRequest` to avoid reentrancy). The
    hook is the guaranteed path for desktop/taskbar clicks; capture + the
    Escape hotkey remain as additional layers. Verified with a real-input
    driver against the running app: Escape closes, outside click closes.
- [x] Settings (schema 8): `minimizeToTrayOnStart` ("Minimize to tray when
      streaming starts" — pressing Start hides to the tray) and `closeToTray`
      ("Close button hides to tray instead of exiting"), both toggleable from
      the Settings menu, both persisted. **Minimize-to-tray defaults to OFF**
      (auto-hiding while streaming is confusing), **close-to-tray defaults to
      ON**; an explicitly saved value is respected, while fresh installs and
      older files without the keys fall back to those defaults.
- [x] `StreamRoot` wiring: `hideToTray()` (create tray lazily, SW_HIDE, balloon,
      activity-log note; falls back to a plain minimize if the shell refuses the
      icon), `showWindowFromTray()` (restore + SW_SHOW + SetForegroundWindow),
      `toggleStreamingFromTray()` (toggle + outcome balloon; `toggleStreaming`
      now returns an error string), `exitFromTray()` (force-exit even while
      streaming or with close-to-tray on), `closeRequested()` gate for the
      entry points. The live source preview idles while tray-hidden; the tray
      tooltip tracks stream state; the update-restart path force-exits so the
      updater still relaunches.
- [x] aurora-d backend: new `NativeWindow.setVisible(bool)` (base default
      false) implemented on win32 via ShowWindow(SW_SHOW/SW_HIDE); rendering is
      paused while hidden (`_visible` gate in `paintNow`) and re-presented
      immediately on show; `GuiWindow.setVisible` forwards it.
- [x] Both entry points (`app_titlebar.d`, `app.d`) now route `onCloseRequested`
      through `root.closeRequested()` so X/Alt+F4 honors close-to-tray.
- [x] Refinement (user: "if tray is already there, then make sure that pressing
      x to shutdown or minimize would not shutdown or minimize and instead
      remain as tray"): once the tray icon exists, the app can never be closed
      or taskbar-minimized — X hides to the tray (`closeRequested`), the
      titlebar/system-menu minimize routes through the new `requestMinimize()`
      (tray-hide when the icon is present), and a taskbar/Alt+Space minimize is
      converted to a tray-hide in `onTick`. The only way out is the tray menu's
      Exit. With no tray feature enabled the old behavior is unchanged (X exits,
      minimize minimizes).
- [x] Windows toast/balloon notifications disabled for now (user: "I would
      prefer to have windows notifications disabled for now ... don't remove it,
      just make sure it's disabled so we can make it sensible in the future").
      `TrayIcon.notificationsEnabled` defaults to `false`; `showBalloon` and all
      call sites stay in place, so re-enabling later is one flag.
- [x] Verified:
  - `dub test` → 43 modules pass (new trayicon menu-structure + settings
    round-trip tests).
  - `dub build` (application) and `dub build --config=notitlebar` link.
  - Standalone `build/trayicon_probe.d`: real tray icon created; synthesized
    WM_LBUTTONUP → exactly one toggle; UP/DBLCLK/UP → one window-show and NO
    toggle (regression fixed: the trailing UP of a double-click re-armed the
    single-click timer, so a double-click toggled the stream too).
  - Standalone `build/tray_darkmenu_probe.d` against the real custom menu:
    right-click opens the menu window; clicking the Exit row dispatches exit
    exactly once and destroys the window; Escape (hotkey) and outside-click
    dismiss without an action. Rendering verified with a solid-red fullscreen
    backdrop: the menu pixels are 96% dark with avg RGB (45,52,60) — the
    intended dark gray, not the OS light menu.
  - Real-app run (settings pre-set to closeToTray/minimizeToTrayOnStart=true):
    WM_CLOSE hid the window and kept the process alive; a simulated tray
    double-click (PostMessage to the tray window with the registered callback
    message) restored the window. `aurora-stream-activity.log` records
    "Window hidden to the system tray." / "Window restored from the system
    tray.".
  - Refinement runtime checks (PowerShell driver, settings pre-set per phase):
    A) no tray feature → X exits the app normally; B) closeToTray on → X hides
    to tray; C) tray present → X hides to tray (never exits); D) tray present →
    ShowWindow(SW_MINIMIZE) converts to a tray-hide (window hidden, process
    alive).
  - User settings were backed up before the probe runs and restored afterward
    (a launched app rewrites the settings file on save/shutdown, so the exact
    original bytes were restored, including the Twitch/YouTube keys and the
    `firefox` browser choice).
- [ ] Not yet tested: a real live stream started with minimizeToTrayOnStart
      (auto-hides after a successful Start; uses the already-verified
      `hideToTray()` path but needs a real stream to confirm the handoff
      sequence). The native right-click menu's real interaction (menu opens,
      item commands dispatch) was not desktop-automated.

## 2026-08-14 — Aurora Stream: capture source "trouble selecting windows" + "keeps entire option red all the time"
- [x] User: "capture source feature seems to have trouble with selecting windows
      and also keeps entire option highlighted as red all the time." Then: "We
      want to stream a window even if it's minimized or out of focus or not
      here. That's the main point."
- [x] **Diagnosed (verified, not guessed)** with headless UI probes driving the
      real `CaptureSourceDropdown` and Win32/FFmpeg tests:
  - The published version's saved settings selected a **minimized** cmd.exe
    window (`windowCaptureHwnd: 3867700`). A minimized window cannot be
    captured (0×0 client area), so once the dropdown refreshed it showed the
    red "Window (minimized): …" danger caption and stayed red until changed.
  - The window list is dominated by minimized windows on a busy desktop (this
    machine: 54 of 69), each flagged "(minimized — not capturable)", burying
    the usable rows — that is the "trouble selecting windows".
  - Verified empirically: `gdigrab hwnd=` on a minimized window → `I/O error`;
    `PrintWindow(PW_RENDERFULLCONTENT)` on a truly minimized window only
    recovers a 159×27 taskbar stub (no rendered surface exists — no capture API
    can fix a window that is not rendering).
- [x] **Fixes (windowsources.d / root.d / settings.d):**
  - `capturableWindows()` filters minimized windows out of the CAPTURE SOURCE
    list; a saved minimized selection is shown as one "Saved window (minimized
    — not capturable)" row so the user can switch away. Menu now lists 15 clean
    capturable windows instead of 69 rows with 54 minimized flags.
  - Startup self-heal: a saved capture window that is closed or minimized falls
    back to "Entire desktop" with a status message, persisted (schema 7), so
    the dropdown can no longer be stuck red on every launch.
- [x] **New feature — window-content capture** (the "main point"): a
      `WindowContentCapturer` (`windowcontent.d`) uses
      `PrintWindow(PW_RENDERFULLCONTENT)` to grab the window's OWN content
      instead of the on-screen pixels. Proven occlusion-immune with a
      deterministic probe (a red window fully covered by a black window still
      PrintWindow-captures 86k red pixels). Wired into the broadcaster as a
      rawvideo-pipe input (pump → FFmpeg stdin), opt-in via the new "Capture
      window content" checkbox:
  - Covered/background windows now stream their real content.
  - While minimized, the pump re-sends the last good frame, so the stream stays
    alive (encoder healthy) and resumes automatically on restore — instead of
    the old hard stop. Verified end-to-end: 3 s rawvideo-pipe run, minimize +
    restore mid-run; frames at both t=1.6 s (minimized, held) and t=2.6 s
    (restored) show the window's real content (SATAVG≈62.5), ffmpeg exit 0.
  - Caveat documented in UI/CHANGELOG: GPU/DirectX games may render black
    through PrintWindow, so it is opt-in; a truly minimized window still has no
    first frame, so Start still rejects a minimized selection (now with a
    content-aware message).
- [x] Verified: `dub test` → 42 modules pass (was 41); `application` +
      `notitlebar` configs build; default app launches/closes cleanly; settings
      round-trip + broadcast-arguments tests cover the new key and pipe args.
- [x] **BUGFIX (user: VLC capture — "huge mismatch and unsynced video and
      audio")**: `PrintWindow` on a large/composited window (VLC) can take
      several frame intervals, so the content pump delivered fewer frames/sec
      than the configured `-framerate`; FFmpeg's rawvideo demuxer stamps frames
      by COUNT at that rate, so the video stream's stamped duration compressed
      and ran ahead of the wall-clock WASAPI audio. Fixed in
      `runWindowContentPump`: the pump now duplicates the last good frame into
      every missed slot, keeping the delivered rate at ~fps frames per real
      second (picture may repeat when capture is slow, but no longer drifts
      ahead of audio). `dub test` → 43 modules pass.
- [x] **BUGFIX (user supplied VLC screenshot: partial UI + large blank side
      region)**: window-content capture was allocating the DIB from the outer
      `GetWindowRect`, while VLC/PrintWindow rendered its DPI-virtualized
      client content at a different logical size. The capturer now sizes from
      `GetClientRect`, requests `PW_CLIENTONLY | PW_RENDERFULLCONTENT`, and
      clears the source DIB before each print so untouched regions are black,
      not stale/white pixels. `dub test` → 44 modules pass; live VLC release
      verification remains the next acceptance check.
- [x] **VLC compatibility fallback**: VLC's hardware video child surface is
      not a reliable PrintWindow composition. Selecting VLC now automatically
      disables window-content mode and uses visible screen capture, preserving
      the complete VLC video and UI. The activity log records the fallback.
      Render-hook capture remains the proper future path for background or
      minimized VLC.
- [x] **Actual VLC validation** (not synthetic): captured the existing VLC HWND
      playing a real video through the exact normalized gdigrab chain. Result:
      no timestamp warnings, 1920×1080 output, 60/1, 300 frames, exactly 5.000
      seconds. The raw unnormalized probe exposed repeated DTS warnings; the
      production normalization chain removed them.
- [x] **Headless diagnostic stdout**: GUI-subsystem builds now preserve an
      inherited stdout pipe for Python diagnostics instead of replacing it with
      a new console. Endpoint JSON parsing and loaded-audio diagnostics pass.
- [x] NOTE: the user's real VLC capture left `aurora-stream-activity.log`
      containing an invalid UTF-8 sequence, which made the `activitylog`
      unittest fail on `readText` (it appended to the existing real log). Made
      the unittest start from a clean file AND fixed the root cause:
      `windowsources.windowTitle` now replaces lone UTF-16 surrogates (some
      apps expose malformed titles) with U+FFFD, and `activitylog.note`
      sanitizes every line through a tolerant UTF-8 decode so no invalid
      sequence can ever reach the log file.
- [ ] Remaining/possible follow-ups: a Windows.Graphics.Capture (WinRT) engine
      would also capture GPU/DirectX window content when occluded (the
      industry-standard OBS/Xbox-Game-Bar approach), but druntime has no WinRT
      types and no Win10 SDK is installed here, so that is a separate
      hand-written-WinRT project. Minimized windows remain uncapturable by any
      API (no rendered surface); only per-game render hooks (OBS Game Capture)
      can do that.

## 2026-08-14 — Aurora Stream self-update feature (release builds only)
- [x] appupdate.d: GitHub releases latest-version check via WinINet HTTPS (with
      User-Agent header; GitHub API 403s without one), asset download, and a
      `--apply-update` mode that archives the current exe to
      `%APPDATA%\Aurora Stream\versions\<version>\` (rollback, last 3 kept),
      replaces it with the staged exe via a temp-copy updater, and relaunches.
- [x] Settings menu shows "Update available: vX.Y.Z — install & restart" only
      when a newer release exists AND the build is a release build
      (appBuildId != "dev"); dev builds never poll.
- [x] Verified end-to-end locally: detects v0.61.0 from an older version,
      downloads the 29.6MB asset, and the apply-update flow archives OLD +
      installs NEW. `--apply-update` added to both app.d and app_titlebar.d
      mains; wininet added to both stream configs.
- [ ] Not yet tested as a real upgrade on a release build (needs a newer
      release to exist while an older release exe runs).
- [ ] aurora-cut does not have the updater yet (only aurora-stream); port the
      module if desired.

## 2026-08-14 — Aurora Stream: "stops when I alt-tab" + one-time freeze (logging + alt-tab recovery)
- [x] User: "some user of aurora stream reported 'it stops when i alt tab' and
      it happened to freeze 1 time" — plan agreed: "we will start logging to
      understand freeze and will look into alt tab problem".
- [x] **Freeze logging** (new `source/aurorastream/activitylog.d`): a persistent
      `aurora-stream-activity.log` beside the exe records timestamped UI
      heartbeats, window events (focus gained/lost, minimized/restored), stream
      start/stop, and UI stalls. A watchdog thread runs off the UI thread, so
      even a fully frozen UI still logs the stall start, the last known stream
      state, and — once ticks resume — the total stall duration (threshold 3 s,
      checks every 0.5 s, log truncated after 4 MiB).
  - `StreamRoot` (`root.d`) drives it: `heartbeat()` each onTick,
    `onHostFocusChanged` logs alt-tab focus loss, minimize/restore transitions
    logged, stream state + metrics published as the stall-context snapshot,
    `shutdown()` stops the watchdog.
  - Verified with a standalone probe: a stopped heartbeat produced
    `UI STALL DETECTED ... no UI tick for 3.1 s` then `UI STALL RESOLVED after
    4.6 s`; the real app launched and wrote focus gained/lost + start/stop lines.
- [x] **Alt-tab stream stop** (root cause): when you alt-tab to/from a
      fullscreen-exclusive app, a resolution change, the lock screen, or a UAC
      prompt, Desktop Duplication loses its output. FFmpeg prints
      `AcquireNextFrame failed` and the capture input dies. The old code treated
      that first line as a permanent `VIDEO CAPTURE FAILURE` and killed the
      stream instantly.
  - Fix in `broadcast.d`: an `AcquireNextFrame failed` line is now flagged
    `_captureLossRecoverable` (not a fatal `_videoCaptureFailed`), the monitor
    returns on that flag, and the launch loop relaunches FFmpeg up to 3 times
    (300 ms apart) so the stream survives the alt-tab; the FIFO muxer reconnects
    the destination. Only when the relaunch budget is exhausted is it reported
    as a permanent capture failure. A user Stop during the recovery window is
    respected (no relaunch). Startup log records
    `DESKTOP CAPTURE OUTPUT LOST` + `RELAUNCH ... (recovery N of 3)`.
  - Regression unittest: `parseLine` on `AcquireNextFrame failed` sets
    recoverable (not fatal), a second line doesn't re-diagnose, clearing works,
    and the monitor exit condition triggers on capture loss as well as user stop.
- [x] Verified: `dub test` → 41 modules pass (was 40); `application` +
      `notitlebar` configs build; `verify-audio-transport.py`,
      `verify-rtp-sdp.py`, `verify-network-output-isolation.py` still pass; the
      default titlebar app launches and writes the activity log.

## 2026-08-14 — Aurora Stream: browser picker always opened the LAST browser (Firefox)
- [x] User: "I switch third time and it keeps opening last one firefox. annoying
      always." (the right-click browser picker on the Twitch/YouTube quick links).
- [x] Root cause: `buildBrowserMenuItems` built each `ContextMenuItem` action as
      `delegate() { choose(captured); }` where `captured` was `const captured =
      choice;` inside the `foreach`. D closures capture variables by reference
      and loop-body variables are hoisted to shared storage, so EVERY menu item
      closed over the same variable, which held the LAST iteration's value —
      every picker entry fired `choose(firefox)`, so whatever the user clicked,
      Firefox opened. (Verified standalone: the pattern printed `3 3 3 3`;
      the fixed pattern prints `0 1 2 3`.)
- [x] Fix: each entry is now built by `browserPickerItem(choice, ...)`, where
      `choice` is a function parameter — each call gets its own storage, so each
      closure fires its own value. This matches the (correct) helper-function
      pattern the concurrent window-capture dropdown already used.
- [x] Regression test: the `buildBrowserMenuItems` unittest now invokes every
      item's action and asserts the fired choices are exactly
      `[defaultBrowser, chrome, firefox]` (would fail on the pre-fix code with
      `[firefox, firefox, firefox]`).
- [x] Verified: `dub test` 40 modules pass; `application` + `notitlebar` build.

## 2026-08-14 — Aurora Stream: right-click the Twitch/YouTube quick links to pick the browser
- [x] User: "add ability to right click context on either 'open twitch settings' or
      'open youtube live' so it can be set to launch either default browser or
      detected google chrome or edge or firefox."
- [x] `browser.d`: added `BrowserChoice` (`defaultBrowser`/`chrome`/`edge`/`firefox`),
      `browserChoiceLabel`/`browserChoiceKey`/`browserChoiceFromKey`,
      `browserExecutablePath` (probes `%ProgramFiles%`/`%ProgramFiles(x86)%`/
      `%LOCALAPPDATA%` well-known install paths), `isBrowserDetected`,
      `availableBrowserChoices()` (display order, concrete choices filtered to
      what is installed), and `openUrlInBrowser(url, choice, error)` which spawns
      the detected exe with the URL, falling back to the OS default handler
      (`explorer.exe`/`open`/`xdg-open`) for `defaultBrowser`.
- [x] Persistence: `BroadcastSettings.browserChoice` + settings schema field
      `"browserChoice"` (`settings.d` round-trip + invalid-key fallback tests);
      `root.d` loads it at startup and saves it via `collectSettings`.
- [x] UI (`root.d`): new `BrowserQuickLinkButton` (right-click shows a context
      menu of detected browsers with the current choice checked; left-click keeps
      opening in the default handler). Both quick links now use it and
      `chooseBrowser()` persists the pick while `openBrowserIn()` opens the URL in
      the chosen browser and reports it in the status line. Menu building is the
      testable `buildBrowserMenuItems()` (labels + checked state unit-tested for
      full and partial installed lists).
- [x] Verified: `dub test` 40 modules pass (was 38 + the concurrent window-capture
      module + the new root.d unittest); `application` + `notitlebar` build. On the
      test machine Chrome + Firefox are detected (Edge absent → omitted from the
      menu). Functional check: the menu opened on right-click and a selection
      persisted to `aurora-stream-settings.json` (`"browserChoice": "firefox"`),
      then reset to `default`.

## 2026-08-14 — Aurora Stream: settings file in per-user app-data by default, `--portable-config` opt-in
- [x] User: settings file should be placed "in installed way" — by default in
      the user's app-data directory, not the current working directory.
- [x] `settings.d`: `setPortableConfigMode`/`portableConfigMode`,
      `userConfigDirectory()` (Windows `%APPDATA%\Aurora Stream`, macOS
      `~/Library/Application Support/Aurora Stream`, Linux
      `$XDG_CONFIG_HOME/Aurora Stream`), `settingsFilePath()` resolves there by
      default and to `getcwd()` under `--portable-config`; `ensureSettingsDirectory`
      creates the per-user folder on first save.
- [x] `app.d` + `app_titlebar.d`: both entry points parse `--portable-config`.
- [x] One-time migration `migrateLegacySettings()`: an existing CWD-relative
      settings file (or its `.bak`) is copied into the per-user location on the
      first default-mode launch, so stream keys are never silently lost.
- [x] Verified: `dub test` 40 modules pass; application + notitlebar configs
      build; default launch saves to `%APPDATA%\Aurora Stream\`, `--portable-config`
      saves beside the launch folder, and the old CWD file migrated with keys
      intact.
- [x] Fixed pre-existing uncommitted compile errors in `windowsources.d`
      (missing `lastIndexOf` import, const-cast `IsWindow`, `FALSE`→`0`,
      `QueryFullProcessImageNameW` casing/import) that blocked any rebuild.

## 2026-08-14 — Aurora Stream: "would be nice a setting for only game capture so they can't see desktop xd"
- [x] User requested a setting to stream **only the game window** so viewers
      never see the desktop.
- [x] Implemented **CAPTURE SOURCE** (top of the settings panel): a
      `CaptureSourceDropdown` that lists **Entire desktop** plus every visible
      titled top-level window (`process.exe — Window Title`), re-enumerated each
      time the menu opens with a **Refresh window list** item
      (`windowsources.d`: Win32 `EnumWindows` + `GetWindowTextW` +
      `QueryFullProcessImageNameW`; filters shell/tool/owned/title-less windows
      and Aurora Stream's own window).
- [x] Selected window is streamed through FFmpeg `gdigrab hwnd=<handle>` at the
      same 60 FPS into the existing source-canvas/destination pipeline
      (`broadcast.d` `captureArguments`). Persisted as `windowCaptureHwnd` +
      `windowCaptureLabel` (settings schema 6). A stale handle (closed window or
      an earlier Windows session) is rejected at Start with a clear message
      (`validateBroadcastSettings` + `windowExists`) instead of silently
      capturing the desktop.
- [x] Window capture always uses the CPU path: `usesD3D11ZeroCopyVideo` returns
      false for it and `videoPipelineLabel` shows `Window capture (GDI) → CPU
      processing → encoder`; the D3D11 direct handoff still applies to full
      desktop Duplication.
- [x] The **LIVE SOURCE CANVAS** preview follows the selection:
      `DesktopPreviewCapturer` gained `setWindowTarget` and captures the
      window's client area instead of the primary monitor, so the preview
      matches what is streamed.
- [x] BUGFIX (user reported "Shows 'no capturable windows'"): the
      `EnumWindows` callback in `windowsources.d` was a plain D function, so
      DMD's default calling convention made every `HWND` arrive as **null**
      (a Win32 callback must be `extern (Windows)`). Every window was filtered
      out → empty list. Fixed the declaration; the dropdown now lists the
      user's windows/games. Verified with a diagnostic that `enumerateWindows()`
      returned 0 before the fix and 70 real windows (7-Zip, Notepad++, Paint,
      Media Player, Steam, games, browsers) after. Added a regression assertion:
      enumeration must find non-empty-titled windows with unique handles and a
      freshly enumerated handle must pass `windowExists`.
- [x] Verified: `dub test` → 40 modules pass; `dub build` (application/titlebar)
      and `dub build --config=notitlebar --force` link; end-to-end ffmpeg window
      capture (gdigrab `hwnd=` → source scale → 1080p60 H.264 FLV) produced 300
      frames / 5 s at 60 FPS with non-black content (YAVG≈193). The fixed app is
      rebuilt and relaunched.
- [x] NOTE: another agent session was concurrently editing this repo during
      implementation (browser.d/root.d quick-link refactor + the portable-config
      settings-location feature above). Re-verified all builds/tests after its
      edits; the features coexist (`dub test` 40 modules pass, both build
      configs link).

## 2026-08-14 — Aurora Stream: minimized captured window shows a frozen frame
- [x] User: "if window is minimized it will show last frozen frame instead of
      minimized captured window. Seems like a bug. can we be sure we support
      minimized windows?"
- [x] Diagnosed: a minimized window's client area is 0×0, so FFmpeg `gdigrab`
      fails to open it at Start (`I/O error`, verified) and, when minimized
      mid-stream, stops producing fresh frames while encoder timestamps keep
      advancing — so the stream freezes on the last frame and even the frame
      counter can keep advancing (no watchdog fires). Minimized windows
      genuinely cannot be captured (GDI/Graphics-Capture limitation), so
      "support" = explicit detection + clear action instead of a silent freeze.
- [x] `windowsources.d`: added `windowIsMinimized` (IsIconic). The dropdown
      marks minimized windows as `(minimized — not capturable)` and the caption
      shows `Window (minimized): …` (danger styling).
- [x] `broadcast.d`:
  - `validateBroadcastSettings` rejects a minimized selection at Start with
    "The selected capture window is minimized. Restore it before starting…".
  - `monitorProcess` now receives `windowCaptureHwnd` and stops the stream
    within ~0.1 s the moment the captured window is minimized or closed:
    status "Window capture stopped — the captured window was minimized/closed",
    a clear diagnostic, and a startup-log entry (instead of freezing). The final
    `_captureFailureStatus` is preserved (was overwritten by the generic
    "Desktop capture failed" message).
- [x] `desktoppreview.d`: `capture()` returns false for an iconic window so the
      LIVE SOURCE CANVAS preview keeps its last good frame.
- [x] Verified: `dub test` → 40 modules pass; both build configs link. With a
      real minimized Notepad: `windowIsMinimized` true, enumeration flagged 43
      of 65 windows as minimized, and `validateBroadcastSettings` returned the
      minimized message. Also empirically confirmed `gdigrab hwnd=` fails on a
      minimized window (0×0 → I/O error) and stalls when the window is
      minimized mid-capture.

## 2026-08-13 — Aurora Stream: "something went wrong immediately stopped streaming"
- [x] User reported streaming stopped immediately. Log showed FFmpeg failing at
      launch: `[udp @ ...] bind failed: Error number -10048 occurred` then
      `Error opening input file ...sdp.` — the Windows UDP RTP/RTCP port was
      transiently still in use right after the reservation was released.
- [x] The handoff proof passed (ports proven free), so this is the known
      transient close→re-bind `-10048` race that `verify-rtp-sdp.py` retries
      with fresh pairs but the LIVE path did not.
- [x] Fix in `broadcast.d` `run()`: the FFmpeg launch is now retried up to 4
      times when it exits within a 2.5 s health window with a `-10048`/`bind
      failed` line. Stderr is drained by a background reader (pipe can never
      fill), the watchdog monitor starts only after health is confirmed, and a
      clear "FFmpeg could not bind the audio UDP port (transient Windows
      -10048)" status is shown if all retries fail. Non-bind-race early exits
      are not retried.
- [x] Verified: `dub test` 38 modules pass; application + notitlebar configs
      build; the default app launches.

## 2026-08-13 — Aurora Stream: dub.json "defaultConfig" warning
- [x] User: "what is this warning, do we need fixing: ... defaultConfig: Key is
      not a valid member of this section."
- [x] `"defaultConfig": "application"` is not a valid dub.json root key in this
      dub version, and it is redundant: dub already uses the FIRST configuration
      as the default, and `application` (titlebar) is first. Removed the key; the
      build now runs without the warning and still defaults to the titlebar
      `aurora-stream.exe`.

## 2026-08-13 — Aurora Stream: UI didn't reflect settings (header showed Twitch when off)
- [x] User: "this time it worked out, but I feel like maybe the settings were
      not reflective on UIs after program was run... are there fixes to be
      made now?"
- [x] The settings WERE applied correctly (that's why 1080p60 to YouTube
      worked). The UI confusion came from the top header always printing
      "Source 1080p60 • Twitch 1080p60 • YouTube 1080p60" regardless of whether
      Twitch/YouTube were actually enabled.
- [x] Fixed: the header now reflects the enabled destinations only
      ("Source 1080p60 • YouTube 1080p60" when Twitch is off) in both the
      constructor initial text and `updateQualitySummary`.
- [x] Verified: `dub test` 38 modules pass; `notitlebar` config builds; the
      default `aurora-stream.exe` needs a rebuild after the running app is
      closed (it was locked).

## 2026-08-13 — Aurora Stream: 1080p60 to YouTube — tested, root cause = dual-encode
- [x] User: "do a few tests for 15 seconds to see which works and if 1080p60
      would even work" and "we are only testing youtube, don't test twitch ever
      for now".
- [x] Live tests against the user's YouTube key (synthetic testsrc2, 15 s):
  - 1080p60 @ 12 Mbps → exit 0, 900 frames, YouTube accepted.
  - 1080p60 @ 24 Mbps → exit 0, 900 frames, YouTube accepted.
  - 1440p60 @ 24 Mbps → exit 0, 900 frames, YouTube accepted.
  So YouTube does NOT reject 1080p or want more Mbps; the bitrate was never the
  problem.
- [x] Real pipeline test: desktop-capture (ddagrab) + single NVENC 1080p60 @
      12 Mbps → YouTube: exit 0, 900 frames, ~61 fps, speed 1.01-1.02x. The PC
      handles 1080p60 easily.
- [x] Root cause of the earlier stops: the app was encoding **Twitch + YouTube
      simultaneously** (two NVENC instances) plus desktop-capture readback —
      that overloads this 4-core/GTX 1060 host (1440p run stalled at 19 s; the
      dual 1080p run exited at 7 s). Single-encode 1080p60 is sustainable.
- [x] Settings updated: `twitchEnabled: false` (YouTube-only), `youtubeQuality:
      "1080p"`, `youtubeBitrateKbps: 0` (auto → 12 Mbps). Added a
      `BitrateDropdown` so the Mbps can be overridden independently (the 
      earlier feature request) — works but is not required for 1080p60.

## 2026-08-13 — Aurora Stream: YouTube stream stopped + showed 1440p not 1080p
- [x] User: "the stream stopped and youtube didn't even recognized 1080p for
      some reason, maybe because we need separate dropdown for selecting the
      streaming mbps."
- [x] Diagnosed from `aurora-stream-startup.log`: the run encoded YouTube at
      **1440p60/24000k** (`scale=2560:1440`, `-b:v 24000k`) because the saved
      `youtubeQuality: "2k"` overrode the new 1080p default — so YouTube showed
      1440p. The stream then stalled: ~59 fps for 14 s, video froze at ~19 s
      (frame 1140), audio helper had a 16 s packet gap, speed dropped to
      ~0.55x, and the watchdog stopped it ("Live output speed stayed below
      0.95x").
- [x] Root cause is encoder/GPU overload: two NVENC encodes (1080p Twitch +
      1440p YouTube) plus desktop-capture readback exceeds this 4-core/GTX 1060
      host. At 1080p60 the load is sustainable. Bitrate is not the bottleneck
      (NVENC cost is resolution-bound, not bitrate-bound), so a separate Mbps
      dropdown would not fix this stall.
- [x] Set the saved `aurora-stream-settings.json` `youtubeQuality` to `"1080p"`
      so the next stream is actually 1080p60/12 Mbps; the 1080p default from the
      recent change now applies. (Stream keys untouched.)

## 2026-08-13 — Aurora Stream: YouTube stream should default to 1080p60
- [x] User: "the streaming of youtube 1440p60 should not be default. Let's make
      1080p60 the default and 1440p60 and other option optionals... we stream
      at 1080p 60fps by default but not lower the internet streaming quality."
- [x] Changed the YouTube output default from 1440p60 (24 Mbps) to **1080p60**
      (12 Mbps) in `BroadcastSettings.youtubeQuality`; 1440p60 and 4K60 stay
      available. The YouTube quality UI was a binary 4K checkbox (1440p↔4K with
      no 1080p option), so it's now a `SourceQualityDropdown` with
      1080p/1440p/4K, defaulting to 1080p.
- [x] Updated the settings guard (invalid YouTube values now fall back to 1080p,
      valid are 1080p/1440p/4K), the legacy shared-quality migration (old 1080p
      → 1080p instead of 1440p), validation, the profile/header labels
      ("Default: 1920×1080 • 60 FPS • 12000 kbps"), and the affected unittests.
      Saved YouTube qualities in existing settings are preserved.
- [x] Verified: `dub test` 38 modules pass; application + notitlebar configs
      build; the default titlebar app launches.

## 2026-08-13 — Aurora Stream: clarified "recording" vs streaming quality
- [x] User thought YouTube's 1440p output was a "recording" and suggested a
      1080p-default recording with higher optional, keeping streaming highest.
- [x] Verified: Aurora Stream has NO local recording feature — it only streams
      (YouTube 1440p60 default / 4K option, Twitch 1080p60, 1080p source
      canvas). User chose **Keep as-is, no recording**; no changes made.

## 2026-08-13 — Aurora Stream: make the custom titlebar the default build
- [x] User: "Make the titlebar the default option and notitlebar suffix for no
      titlebar that is currently active as default."
- [x] `dub.json`: the default `application` configuration now builds the custom
      titlebar (`source/app_titlebar.d`) as `aurora-stream.exe`; the plain
      OS-titlebar build is the new `notitlebar` configuration
      (`source/app.d`, target `aurora-stream-notitlebar`); `defaultConfig`
      is `application`.
- [x] Scripts/artifacts: removed `RUN-WINDOWS-TITLEBAR.bat` and the tracked
      `aurora-stream-titlebar.exe` (the titlebar build now outputs the default
      `aurora-stream.exe`, which is gitignored); added
      `RUN-WINDOWS-NOTITLEBAR.bat` and `/aurora-stream-notitlebar*` gitignore
      entries; updated `app_titlebar.d` comments and the testing-progress /
      changelog docs.
- [x] Verified: `dub build` links `aurora-stream.exe`, `dub build
      --config=notitlebar` links `aurora-stream-notitlebar.exe`, `dub test`
      38 modules pass, and the default titlebar exe launches.

## 2026-08-13 — Aurora Stream: remove the "Program canvas" feature
- [x] User: "remove the option of settings: 'Program canvas' this is outdated
      and useless."
- [x] Removed the feature end to end: deleted `source/aurorastream/programcanvas.d`
      (sources/compositor/preview/editor), removed the Settings menu item, the
      PROGRAM CANVAS settings section, and the editor/checkbox from `root.d`,
      dropped `programCanvasEnabled`/`programCanvasSources` from
      `BroadcastSettings` and the settings serialization, removed the
      broadcaster's raw-BGRA canvas frame-pump path (`captureArguments` pipe:0
      branch, `runCanvasPump`, `loadCanvasImages`, validation guard, canvas
      video-pipeline label, `Redirect.stdin`), and trimmed the canvas tests from
      `tests/broadcast_model_smoke.d` and the program-canvas docs (README,
      ROADMAP, VALIDATION).
- [x] The **LIVE SOURCE CANVAS** panel stays, now purely a live desktop-recording
      preview (`LiveSourceCanvasPreview` inline widget showing the capture frame).
      Streaming is always desktop capture.
- [x] Verified: `dub test` 39 modules pass; application + titlebar configs
      build; the app launches without the canvas section.

## 2026-08-13 — Aurora Stream titlebar: minimize + restore rendering
- [x] User: "check if minimization is implemented in titlebar of aurora, maybe
      we missed it upstream" → taskbar click didn't minimize, and the titlebar
      minimize button did nothing.
- [x] Upstream gap confirmed: the `TitleBar` widget has a minimize button and
      `onMinimize` callback, but `GuiWindow` had NO minimize API. Added
      `minimize()/restore()/isMinimized()` to the aurora-d window abstraction
      (`platform/base.d` default-false, `platform/win32.d` ShowWindow
      SW_MINIMIZE/SW_RESTORE + `_minimized` cached from WM_SIZE, `window.d`
      forwarding).
- [x] Taskbar click-to-minimize didn't work because frameless windows used
      `WS_POPUP` without `WS_MINIMIZEBOX` (the shell ignores it). Added
      `WS_MINIMIZEBOX | WS_MAXIMIZEBOX` to frameless windows.
- [x] `app_titlebar.d` wired `_titleBar.onMinimize = _window.minimize()` and
      added a **Minimize** system-menu item; `root.d` pauses the live
      source-canvas preview while `_window.isMinimized()`.
- [x] Restore showed distorted content for a few frames: while minimized the app
      rendered 1×1 frames, so the restore animation scaled a solid box up. The
      win32 `WM_SIZE` handler now keeps the last full-size framebuffer while
      minimized and `paintNow` skips rendering until SIZE_RESTORED, so the
      restore animation scales real content and rendering is paused (energy).
- [x] Verified: titlebar + main configs build, `dub test` 39 modules pass; the
      titlebar app launches and minimize/restore (button, system menu, taskbar)
      behave cleanly.

## 2026-08-13 — Aurora Stream: device stayed "Unavailable" after reconnecting
- [x] User: "I don't know I reinserted the headphones device and it keeps
      visibly showing as unavailable."
- [x] Diagnosed: a WASAPI state dump showed the headphones ACTIVE with the same
      endpoint ID, and the app's own `AudioDeviceScanner` returned them — so a
      rescan WOULD clear the state. The periodic rescan simply never ran.
- [x] Root cause (found via temporary instrumentation): `_audioRescanTimer` was
      D-default **NaN** (D floats initialize to NaN, not 0.0), so
      `_audioRescanTimer += deltaSeconds` stayed NaN and `NaN >= 8.0` was never
      true → the 8 s safety-net rescan never triggered. Fixed with explicit
      `= 0.0` initialization.
- [x] Also hardened the scanner: `AudioDeviceScanner.start()` now recovers a
      wedged scan thread (clears `_running` if the thread died without
      resetting it) and `runScan` wraps enumeration in try/catch so `_running`
      always resets — a stuck scan can no longer block all future rescans.
- [x] Verified: `dub test` 39 modules pass; with the fix the app spawns the
      periodic ffmpeg DirectShow scans every ~8 s (3 unique ffmpeg PIDs in 22 s
      of 100 ms sampling); app + titlebar build; clean `CloseMainWindow()`.

## 2026-08-13 — Aurora Stream: no indication when a selected device is disconnected
- [x] User: "I just disconnected headphones and no indication that it is no
      longer available."
- [x] Diagnosed with a standalone WASAPI state dump: the selected desktop
      endpoint `{0.0.0.00000000}.{5d7a565c-...}` ("Headphones (High Definition
      Audio Device)") became **UNPLUGGED** (state 0x8) and dropped out of the
      active-only enumeration (only Speakers remained). So Windows DID report
      the change; the app's auto-rescan simply never ran — the Core Audio
      IMMNotificationClient path was not delivering a rescan trigger.
- [x] Fixes:
  - **Guaranteed detection**: `root.d` now runs a periodic safety-net
    audio rescan every 8 s (`_audioRescanTimer` → `_pendingAudioRescan` →
    `refreshAudioDevices(false, true)`), so device removals are reflected
    within the interval even if `AudioDeviceNotifications` is unavailable.
    Background rescans are silent (no Refresh-button flicker) via the new
    `background` parameter.
  - **Visible indication**: `AudioDeviceDropdown.updateCaption` now renders an
    unavailable selection as "Unavailable — <cached name>" and calls
    `setDanger(true)` so the selector turns red until the device returns.
- [x] Verified: `dub test` 39 modules pass; app + titlebar configs build; app
      stable across multiple 8 s rescan cycles (~10.6% of one core incl. the
      periodic ffmpeg dshow enumeration); clean `CloseMainWindow()`.

## 2026-08-13 — Icons embedded in the single-exe releases (aurora-cut + aurora-stream)
- [x] Runtime icon: `bundledicon.d` (auroracut/aurorastream) embeds the app's
      `.ico` bytes (`version (BundledFfmpeg)` + stringImportPaths `assets`),
      extracts to `%TEMP%\<App>-assets` on first use; `applicationIconPath()`
      returns it so the window/taskbar/titlebar icon works without an assets
      folder next to the exe. Verified standalone (real .ico extracted).
- [x] PE/Explorer icon: `scripts/patch-pe-icon.py` appends a `.rsrc` section to
      the linked exe (correct data RVAs) and updates the PE headers — works
      with any linker. `build-portable-windows.py --single-exe` runs it after
      `dub build`.
- [x] BUG FOUND + FIXED: the resource data-entry RVAs were off by the size of
      the data-entry region (112 bytes), so the RT_ICON data pointers were
      wrong and Windows could NOT decode the icon (LoadImageW failed even
      though FindResource/SizeofResource looked right). Verified the fix with a
      direct Win32 probe: LoadLibraryExW + FindResourceW(RT_GROUP_ICON) +
      LoadImageW now returns a valid HICON, and the 90-byte group data is
      correct (reserved=0 type=1 count=6, ids 1..6 matching the PNG images).
- [x] Release assets are now versioned (aurora-cut-v0.60.3.exe) so the
      Explorer icon cache can't serve a stale default icon for a new build.
- [ ] Final visual check on a clean machine: v0.60.3 release files show the app
      icon in Explorer and the running window/taskbar/titlebar use it.

## 2026-08-13 — Aurora Stream: cache audio device names + auto-refresh on device changes
- [x] User: "we probably need to cache device names like audio so we keep
      correct names when they are unavailable or disconnected. We probably need
      to have ability to receive notification about newly connected devices so
      we don't become stale on devices while program is running."
- [x] Persistent device-name cache: `BroadcastSettings.deviceDisplayNameCache`
      (identifier → friendly name) saved in the settings file
      (`settings.d` load/save, round-trip unittest incl. invalid-entry
      tolerance). `root.d` fills it from every successful scan (`remember` in
      the generation-change handler) and passes it to the dropdowns
      (`AudioDeviceDropdown.setNameCache`), so a disconnected selection shows
      "Unavailable — Headphones (High Definition Audio Device)" / "Saved but
      unavailable: <name>" instead of the raw backend ID, even across restarts.
- [x] Auto-refresh on device changes: `AudioDeviceNotifications` (wasapi.d)
      implements a minimal `IMMNotificationClient` (raw COM vtable) registered
      on a dedicated STA thread with a small message pump; OnDeviceAdded/
      Removed/StateChanged/DefaultDeviceChanged/PropertyValueChanged set a flag
      the UI thread polls each tick (`consumeChanged` → `_pendingAudioRescan`
      → `refreshAudioDevices(false)`), so newly connected/disconnected devices
      are picked up while running. Best-effort: failures fall back to the
      startup scan + manual Refresh button.
- [x] Verified: `dub test` 39 modules pass; application + titlebar configs
      build. Runtime: launched app, settings file gained a real cache
      (`@device_cm_...\wave_...` → "Microphone (...)", `{0.0.0.00000000}.{...}`
      → "Headphones/Speakers (High Definition Audio Device)"); app stable
      (~10% of one core incl. the notification listener's 250 ms wake loop)
      and `CloseMainWindow()` joins cleanly.
- [x] Note: caught and fixed an AA `RangeError` in `remember` (`aa[key]` reads
      throw on missing keys; must use `in`).

## 2026-08-13 — Aurora Stream: live preview looks blurred
- [x] User: "looks blured, was it expected?" Yes — the preview captured at a
      fixed 480×270 (a quarter of the screen) and then upscaled it to fill the
      panel, so it was inherently soft.
- [x] The capture now tracks the preview panel size: `updateLiveSourcePreview`
      computes a 16:9 target from `_canvasPreview.bounds()` (clamped to
      320×180 … 1280×720) under the mutex, the capture thread passes it to
      `DesktopPreviewCapturer.setTargetSize` (DIB recreated only on size
      change) and resizes the reusable buffer/RgbaImage, so the frame is drawn
      near 1:1 and sharp.
- [x] Measured: ~10.9% of one core (~2.7% of all cores) at 30 FPS with the
      panel-sized capture; app builds, launches, closes cleanly.
- [x] `dub test` 39 modules pass; application + titlebar configs build.

## 2026-08-13 — Aurora Stream: live preview saturates the CPU
- [x] User: "the preview takes all of cpu right now horrible performance, no
      idea why it's so expensive for no reason".
- [x] Root causes found in the renderer + capture paths:
  - The capture thread created a NEW `RgbaImage` (new id) every frame, so the
    renderer's texture cache grew unboundedly and a fresh GPU texture was
    created/destroyed at 30 FPS (`ensureImageTexture` keys on `image.id()`).
  - `StretchBlt` ran in `HALFTONE` mode, which performs expensive software
    dithering on every downscale.
  - The preview widget was a plain widget, so each live frame set `_baseDirty`
    and the software renderer redrew the ENTIRE 1280×780 UI at 30 FPS.
  - Per-frame GDI object churn (CreateCompatibleDC/CreateDIBSection/Delete…).
- [x] Fixes:
  - `desktoppreview.d` rewritten around a persistent `DesktopPreviewCapturer`
    that creates the memory DC + DIB once (recreated only on screen-size
    change) and uses `COLORONCOLOR` (no dithering); `captureDesktopPreview`
    remains as a one-shot test convenience.
  - `root.d` capture thread reuses ONE `RgbaImage` via `reset()` (same id →
    same GPU texture, just a re-upload) and one reusable pixel buffer; new
    frames are detected by `revision()` instead of identity.
  - `_canvasPreview.setComposited(true)` + `setCompositedOpaque(true)` make the
    preview a retained layer, so live updates repaint only the preview area.
- [x] Measured: with the fix the app uses ~8.3% of one core (~2.1% of all
      cores) at 30 FPS vs saturating before. `dub test` 39 modules pass;
      application + titlebar configs build; app launches, preview runs, and
      graceful `CloseMainWindow()` exits cleanly.

## 2026-08-13 — True single portable exe (ffmpeg embedded) for aurora-cut + aurora-stream
- [x] Minimal ffmpeg build (covers both apps) is green: run #15 of the
      `minimal-ffmpeg.yml` workflow; artifact `ffmpeg-minimal-win64` ~10MB
      (ffmpeg.exe + ffprobe.exe). Includes cut's codecs/filters/GPU encoders
      AND stream's ddagrab/dshow/gdigrab + udp/rtp/rtmp/rtmps + flv/fifo.
- [x] Single-exe mechanism: new `aurorastream.ffmpegbundle` /
      `auroracut.ffmpegbundle` embeds ffmpeg.exe+ffprobe.exe at compile time
      (`version (BundledFfmpeg)` + `stringImportPaths: ["embedded"]`), extracts
      them on first run to `%TEMP%\Aurora-Stream-ffmpeg` / `Aurora-Cut-ffmpeg`
      (size-cached, idempotent) and prepends that dir to PATH so every bare
      "ffmpeg"/"ffprobe" invocation resolves to the bundle. Zero call-site
      changes needed.
- [x] Both apps link as single exes with embedded copies (verified locally with
      placeholder files: aurora-cut.exe + aurora-stream.exe compile+link under
      `dub build --build=portable-single-exe`); extract+PATH mechanism verified
      with a standalone smoke program.
- [x] CI wired: `portable-windows.yml` now downloads the latest successful
      `ffmpeg-minimal-win64` artifact, stages the binaries into each app's
      `embedded/`, and builds via `build-portable-windows.py --single-exe`.
      `build-portable-windows.py` gained `--single-exe` (validates embedded
      files exist, uses `portable-single-exe` build type).
- [x] `embedded/` is gitignored except `.gitkeep`; dev builds (no
      `BundledFfmpeg`) are unaffected.
- [x] CI green: "Portable Windows executables" run #7 (commit 9a3240c) built
      everything with the REAL minimal ffmpeg embedded; artifact
      `aurora-windows-portable` (26.8MB zip) contains the single-exe
      aurora-cut.exe + aurora-stream.exe. (Iteration fixes: GH_TOKEN for gh,
      positional run id, recursive artifact staging, aurora-cut embedded dir
      is repo-root `embedded/`, build failures surfaced as annotations.)
- [ ] Not yet tested: download run #7's `aurora-windows-portable` artifact and
      on a machine with NO ffmpeg installed launch aurora-cut.exe /
      aurora-stream.exe — confirm they extract ffmpeg to `%TEMP%` and
      import/export/stream work.

## 2026-08-13 — Aurora Stream: live preview was ~8 FPS and brown-tinted
- [x] User: "why is it low fps and brown color mainly."
- [x] Low FPS: the preview deliberately captured only ~8 FPS on the UI thread.
      Moved capture to a dedicated background thread (`previewCaptureLoop`) that
      grabs the primary monitor at ~30 FPS, publishes the newest frame under a
      `Mutex`, and idles when the program canvas replaces desktop capture; the
      UI thread only swaps the latest frame into the widget (`updateLiveSourcePreview`).
      The thread is stopped and joined in `shutdown()`.
- [x] Brown tint: the DIB→RGBA conversion had red and blue swapped. 32bpp DIB
      memory bytes are B,G,R,undefined-alpha on little-endian, but the canvas
      consumes R,G,B,A, so the old loop wrote BGRA words and every dark
      blue-gray UI surface rendered brown. Extracted the byte-order transform
      into `dibPixelToRgbaWord` and added a deterministic regression test
      (pure red/green/blue DIB words map to the correct RGBA words; gray stays
      gray).
- [x] Verified: `dub test` 39 modules pass (incl. the byte-order regression);
      `dub build` (application) and titlebar link; app launches and stays
      stable with the 30 FPS background capture running; graceful
      `CloseMainWindow()` exits with the capture thread joined.

## 2026-08-13 — Aurora Stream: LIVE SOURCE CANVAS now previews the actual recording
- [x] User: "i thought the program canvas was suppose to show what we are
      actually recording, wasn't that the idea?" → chose "Build a real live
      recording preview".
- [x] Before: the LIVE SOURCE CANVAS panel only painted the Aurora scene
      compositor sources; in the default desktop-capture mode it showed a
      static "Aurora program canvas is empty" placeholder and never the real
      capture.
- [x] Added `source/aurorastream/desktoppreview.d`: an in-app Windows GDI
      capture (`GetDC` + `CreateDIBSection` + `StretchBlt` HALFTONE) of the
      primary monitor into a small 480x270 RGBA `RgbaImage`, with top-down DIB,
      BGRA→RGBA channel swap, and forced opaque alpha. New unittest
      (`captureDesktopPreview`) plus a standalone dmd run saved a frame and
      ffmpeg→PNG pixel analysis confirmed real content (255 unique red values,
      avg 101.5, all opaque).
- [x] `ProgramCanvasPreview` gained `setLiveFrame`/`clearLiveFrame` and paints
      the live frame letterboxed instead of the sources when one is present.
- [x] `StreamRoot` (`updateLiveSourcePreview` in onTick): desktop-capture mode
      refreshes the preview ~8 FPS via `captureDesktopPreview`; program-canvas
      mode keeps the in-app composite (exactly the recorded frames). The panel
      is always visible; only the program-canvas settings section stays behind
      the Settings menu (`setProgramCanvasVisible` no longer hides the preview).
- [x] Verified: `dub test` 39 modules pass; `dub build` (application) links.

## 2026-08-13 — Aurora Stream: move the whole Program canvas section into the Settings menu
- [x] User: "let's move entire section to settings, I doubt anyone should use it"
      (the Aurora program canvas section).
- [x] The **PROGRAM CANVAS** settings section (separator + title + checkbox +
      hint + source editor) is now wrapped in `_programCanvasGroup` and hidden
      by default; the dedicated **LIVE SOURCE CANVAS** preview panel is hidden
      with it and the status panel flexes to fill the monitor column. Both are
      revealed by the new toolbar **Settings → Program canvas** check item
      (`setProgramCanvasVisible`, mirroring the streaming-servers toggle).
      When a saved session has the canvas enabled it is revealed automatically
      so an active canvas config stays visible.
- [x] Verified: `dub test` 38 modules pass; `dub build` (application) and
      `dub build --config=titlebar` link.

## 2026-08-13 — Aurora Stream: YouTube stream shows only a black screen
- [x] User: "Nothing is being streamed, only black screen" — then "the aurora
      render canvas is enabled by default for no reason I don't even know why
      we have it".
- [x] Verified root cause from `aurora-stream-startup.log` + code: the last
      live stream ran with the **Aurora program canvas** as the video source
      (`Video source: Aurora program canvas`, `-f rawvideo -pix_fmt bgra -i
      pipe:0`) while `programCanvasSources` was empty. `runCanvasPump` clears
      the surface to black each frame and `paintProgramCanvas` draws nothing,
      so FFmpeg/NVENC encoded healthy black frames (~59 FPS, speed ~0.99) — no
      encoder failure, hence no `Live output stalled`, just a black picture.
- [x] It is NOT on by default: `BroadcastSettings.programCanvasEnabled`
      defaults to false and the saved settings have it false. It was left
      checked from an earlier canvas-mode session (2026-08-12 todo entry). The
      feature exists as the delivered roadmap milestone "Aurora scene
      compositor": Aurora composites color/image/text sources into the source
      canvas instead of capturing the desktop, as the first step toward
      window/game/camera/browser sources.
- [x] Guard added in `validateBroadcastSettings` (broadcast.d): Start streaming
      is now rejected when the program canvas is enabled but has no visible
      (enabled) source, with an explicit message to add a source or disable the
      program canvas to stream the desktop. New unittest covers baseline, empty
      canvas, all-disabled sources, and one-enabled-source.
- [x] Verified: `dub test` 38 modules pass; `dub build` application links.

## 2026-08-13 — Background playback prewarm: playhead changes start loading immediately
- [x] User: "so i expect that after playhead changes we immediately try to start
      loading in the background instead of having bad experience on actual
      playback."
- [x] Implemented a paused background prewarm in `source/auroracut/editor.d`:
      while the timeline is paused (`_playbackKind == none` or a paused
      sequence), after the playhead settles for `playbackPrewarmDelaySeconds`
      (0.10 s) the editor starts decoding the EXACT stream Play would start at
      the playhead — direct source decode or the live composition graph — plus
      a paused PCM audio stream. Frames buffer unseen; the retained static
      frame stays visible.
- [x] On Play, `startPlaybackStreams`/`startPlaybackAudio` compare an opaque
      signature (mode + path + position + decode size + fps + decode options +
      graph args, which embed the model revision) against the prewarm and ADOPT
      the running streams instead of spawning new FFmpeg processes. The video
      first frame and the audio clock are therefore ready immediately.
  - `PcmAudioPlayer.reanchorClock()` re-anchors the headless fallback clock on
    adoption so the time spent buffering while paused is not reported as
    playback position.
  - `startPlayback` computes `prewarmMatchesPlayback(...)` before its
    `stopPlayback(false)` teardown and skips the teardown when the prewarm
    matches, otherwise the teardown would kill the warm streams first.
- [x] Lifecycle: playhead moves and model edits reset the debounce/cancel the
      prewarm (`notePlaybackPrewarmDirty` from `playheadChanged`; the onTick
      revision/position checks catch model edits); pause/seek/stop cancel it;
      an idle prewarm is released after `playbackPrewarmIdleSeconds` (45 s) so
      a paused editor does not hold FFmpeg processes forever. A signature match
      also requires the prewarmed video stream to still be running.
- [x] Regression test in `tests/editor_smoke.d`: after a playhead change while
      paused, waits for the prewarm to activate and spawn video+audio FFmpeg,
      waits for buffered video frames, then presses Play and asserts NO new
      video or audio process was spawned (adoption) and the transport runs.
- [x] Verified: `dub test` (33 modules), `tests/editor_smoke.d`,
      `tests/playback_stress.d`, `tests/playback_seek_resilience_smoke.d`,
      `tests/static_sequence_playback_smoke.d`, `tests/playback_proxy_smoke.d`,
      `tests/layout_smoke.d`, `tests/gpu_decode_args_smoke.d`,
      `tests/model_smoke.d`, `tests/export_smoke.d` all pass; the prewarm
      smoke block passed on 3 consecutive runs (loaded 4-core host).

## 2026-08-13 — "Video decoder ended before the next frame was ready" must never halt playback
- [x] User: "First fix the 'video decoder ended before the next frame was
      ready' this should never happen."
- [x] Root cause in `source/auroracut/editor.d` onTick: whenever the video
      stream reported `finished()` while the transport was in the
      `_playbackVideoWaiting` buffering state, the editor called
      `haltPlaybackForSync("Video decoder ended before the next frame was
      ready.")` and stopped playback. Reaching the last frame of the requested
      range is the normal completion of that range, not a failure, so a clean
      EOF while buffering (e.g. a slow decoder that caught up right at the end
      on a loaded machine) was misreported as a broken decoder and aborted the
      session.
- [x] Fix:
  - `playback.d`: added `VideoFrameStream.hasReadyFrames()` so callers can tell
    "stream finished but tail frames are still queued" from "nothing left to
    display".
  - `editor.d` `displayedVideoBehindPlaybackClock()`: returns false once the
    stream is finished with no ready frames — a finished decoder cannot catch
    up further, so the transport must not re-enter buffering (this also breaks
    a potential resume→re-pause loop for a decoder that stopped early).
  - `editor.d` halt block: clean EOF while waiting now RESUMES
    (`resumeAfterVideoBuffer()`, or lets the waiting branch keep draining the
    queued tail) so playback completes at the range end. A genuine FFmpeg
    error (`error()` non-empty) is surfaced as a status message only, never a
    halt. The `haltPlaybackForSync` audio-start failure path is unchanged.
- [x] Regression test in `tests/editor_smoke.d` (deterministic, no decode-speed
      dependence): start direct playback, wait until the decoder reaches the
      end of its range normally, force `waitForVideoBuffer()` (the production
      buffering state), tick, then run to completion. Asserts playback reaches
      `_playbackEnd` and the status never contains "Video decoder ended before
      the next frame was ready". Verified: FAILS on the pre-fix code (playback
      halts early at line 1176), PASSES with the fix.
- [x] Verified: `dub test` (33 modules) passes; `tests/editor_smoke.d`,
      `tests/playback_stress.d`, `tests/playback_seek_resilience_smoke.d`,
      `tests/static_sequence_playback_smoke.d`, `tests/playback_proxy_smoke.d`,
      `tests/layout_smoke.d`, `tests/gpu_decode_args_smoke.d`,
      `tests/model_smoke.d`, `tests/export_smoke.d` all pass on Windows.
- [ ] Note (pre-existing, NOT caused by this fix): `tests/synced_playback_preroll_smoke.d`
      fails at line 112 ("Frame-step playhead movement did not request preview
      immediately") identically on the base commit before any of these changes.
      The test asserts `setPlayhead(...)` synchronously increments the preview
      request counter, but the editor dispatches previews through the 0.06 s
      debounce in `scheduleTimelineFrame`/`dispatchPendingPreview`, so the
      assertion cannot hold. It is not part of any verification script. Either
      repair it (assert after a tick, or wire frame-step to
      `dispatchPendingPreviewNow`) or remove it.

## 2026-08-13 — Aurora Cut: consolidate "Move to V*" context menu into one "Move to track…" dialog
- [x] User: "replace multiple lots of context menu 'Move to V*' with a single
      context menu item 'Move to track' that opens dialog."
- [x] `source/auroracut/editor.d`: removed the per-lane `Move to V1/V2/…`
      entries from the timeline clip context menu (and the now-unused
      `addMoveTrackItem` helper), replacing them with one `Move to track…` item
      that opens `openMoveToTrackDialog(source, index)`. The direct
      `Move to new video track` / `Move to new audio track` commands are kept
      as context-menu items (user: "I do not see the new Move to new
      video/audio track context-menu in the context menu").
- [x] Text clips (no media asset) previously got NO move options; the move
      section was gated on `asset !is null && asset.hasVideo`. Diagnosed with a
      real-GUI headless probe (`tests/menu_probe.d`, deleted after): the media
      clip menu DID contain the move items, the text clip menu did not (user:
      "it's clearly not visible"). Extended the gating so text clips also offer
      `Move to track…` + `Move to new video track` (video-track layers only),
      and the dialog lists video tracks + `New video track` for them.
- [x] The dialog (`PopupOverlay`, centered, 360×420, ids
      `move-to-track-popup` / `move-to-track-list` / `move-to-track-apply` /
      `move-to-track-cancel`) lists every compatible destination: video tracks
      V1..Vn + `New video track` when the asset has video, audio tracks A1..An
      + `New audio track` when the asset has audio. The clip's current track
      row is disabled; the list preselects the first enabled option. Apply via
      the `Move` button or Enter/double-click (`onActivated`) runs
      `moveSelectedToTrack`, preserving the old per-item behavior (same
      selection + move path, `ensureTrack` creates new lanes).
- [x] Covered by `tests/editor_smoke.d`: menu no longer lists `Move to V1/V2`,
      still lists `Move to new video track` (and no `Move to new audio track`
      for the video-only overlay), the dialog opens and lists
      V1/V2/V3(disabled)/New video track for the video-only overlay clip,
      moving to V2 and back through the same dialog restores the clip on V3,
      a text clip's menu shows `Move to track…` + `Move to new video track`
      (no audio move), and the long-menu wheel-scroll check still runs on a
      freshly reopened menu.
- [x] Verified: `dmd -i -version=AuroraHeadless -Isource
      -Ivendor\aurora-d-0.4.5\source tests\editor_smoke.d ...` compiles and the
      editor smoke test passes on Windows.

## 2026-08-13 — Research: timeline playback is not always immediate / lacks performance
- [x] User: "research if we can do anything about aurora cut timeline
      performance/playback it is not always feeling immediate and lacking in
      performance."
- [x] Studied the whole playback pipeline end-to-end (code, not just bench):
      `VideoFrameStream`/`PcmAudioPlayer` in `source/auroracut/playback.d`,
      `PreviewService`/`PreviewWidget` in `preview.d`, the live compositor
      graph builders in `exporter.d`, and the transport/pacing logic in
      `editor.d`. Machine under test is 4 logical CPUs and was pinned near 100%
      load by background apps (explorer/steamwebhelper/nvcontainer), which is a
      large part of the "lacking performance" feel.
- [x] Findings, from highest to lowest impact:
  1. **Live playback stretches non-16:9 sequences (correctness).**
     `startPlaybackStreams` builds the live composition canvas with
     `ExportPreset.previewForHeight(renderHeight)` (fixed 16:9, e.g.
     1280x720) at `editor.d:6145`, while the decode canvas is sequence-aspect
     (`recommendedDecodeSize(..., _compositionWidth, _compositionHeight)` at
     `editor.d:6067`). `compositeStreamArguments` then force-scales
     `[vout]scale=outputW:outputH` (no aspect preservation) at
     `exporter.d:1093-1099`, so a portrait/square sequence is stretched during
     LIVE playback. The paused/scrub frame path already uses
     `previewCompositionPreset` (sequence aspect) at `editor.d:7998-8000`, so
     pause/scrub and play now disagree for non-16:9 compositions.
  2. **Live compositor renders at a fixed preset then downscales (perf).** The
     overlay graph (scale+overlay per layer, `geq` when opacity animated,
     `gblur` shadows) always runs at 1280x720 in Responsive mode, then the
     final `scale` downscales to the decode size (e.g. 960x540 when the preview
     widget is smaller). ~40-55% of compositor pixels are wasted for typical
     windows. Fixing #1 with the decode-sized `previewCompositionPreset`
     removes this double render at the same time.
  3. **Every clip in the timeline is opened+decoded even when out of range.**
     `collectInputs` (`exporter.d:1244-1276`) includes every non-disabled clip;
     `appendInputArguments` seeks each to `inPoint` with `-t` = full clip
     duration (`exporter.d:1307-1311`); the overlay chain uses
     `eof_action=pass:repeatlast=0:shortest=0`, so ffmpeg pulls/decode each
     input for the whole playback range even if its sequence window is outside
     `[rangeStart, rangeEnd]`. Playing a short section of a long multi-clip
     timeline therefore decodes clips that contribute nothing.
  4. **Audio process starts only after the first video frame.** In `onTick`
     the first-frame branch calls `startPlaybackAudio` (`editor.d:8091`) only
     after `hasBufferedDuration(preroll)` is satisfied, so audio process spawn
     is serialized behind video process spawn + first frames.
  5. **No warm/persistent decoder.** Every Play and every committed seek spawns
     one or two fresh FFmpeg processes (video + audio for live timeline). On
     Windows process spawn alone is ~50-150 ms before graph build + input open.
     This dominates the "not immediate" feel on press-Play/seek.
  6. Minor: audio queue is 6 chunks x 2048 frames (~256 ms) at
     `playback.d:43-51`; `-threads 2` decode on a 4-core box is conservative;
     no adaptive resolution exists (the Responsive/Balanced/Fidelity choice is
     manual and static).
- [ ] Not yet fixed/verified (open improvement candidates; implement + verify
      in the running GUI + Playwright):
      - Use the sequence-aspect, decode-sized preset for live playback
        (fixes #1 and #2; effect coords are normalized so visuals are
        unchanged; verify 16:9 and portrait/side sequences match pause frames).
      - Restrict live `collectInputs` to clips intersecting the playback range
        (handle straddling clips) to stop decoding out-of-range media.
      - Start audio (paused, `startPaused=true`) concurrently with video and
        unpause after video preroll, instead of after first frame.
      - Consider an "Auto" performance mode that lowers decode height if frames
        are being dropped (`_videoStream.stats().framesDropped`) and raises it
        again when headroom returns, for immediate-but-smooth playback.
      - Reduce live preroll 0.090 -> 0.055 s and/or audio queue depth.

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
      `source/aurorastream/entry.d`.
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

## 2026-08-14 — Aurora Cut playback rework: performant, gated, prewarm-keep-alive (user request)
- [x] User: playback has "huge problems"; wants it performant and non-blocking,
      never to play unless ready, always smooth by prewarming/caching after
      moving the playhead, and instant per-frame playhead movement.
- [x] **Readiness gate (Phase 1/2):** single `playbackReady()` predicate;
      audio device clock is no longer a hard gate — if audio cannot start or
      its clock never becomes readable (`playbackAudioClockFallbackSeconds`
      5 s) the buffered video plays muted on the monotonic clock with a status
      instead of hanging on "Waiting for audio output…". First-frame readiness
      is bounded (`playbackFirstFrameTimeoutSeconds` 12 s →
      `failPlaybackStart`), so a stuck decoder reports a failure instead of
      staying in "preparing" forever.
- [x] **Prewarm keep-alive (Phase 3):** a complete, unchanged prewarm stays
      alive while the playhead is inside its forward window (`32/fps` s ≈ two
      slot-queues), killing the 45 s cancel/restart churn seen every ~45 s in
      aurora-cut.log at the same position. Direct-mode video/audio signatures
      no longer embed position/duration; adoption now matches identity +
      playhead-inside-window + remaining-not-exceeded, so a scrub/step before
      Play still adopts the warm streams. End-of-range prewarms are skipped and
      finished dead ones cancelled (no churn at the range end).
- [x] **Instant warm steps (Phase 4):** `canTakeReadyAtOrAfter` /
      `takeReadyAtOrAfter` on `VideoFrameStream` + `tryStepSequenceFromPrewarm`
      in `playheadChanged` serve forward steps inside the buffered window with
      zero FFmpeg spawn and zero still-renderer request; the first-frame handler
      prefers the frame at the playhead when the adopted decoder is ahead.
- [x] **Non-blocking audit (Phase 5):** removed caller-thread `waveOutReset`
      from `PcmAudioPlayer` enqueue/stop/shutdown (worker resets/closes the
      previous generation's sink itself). Headless clock freezes while paused
      (`_prerollPaused`), fixing the pre-existing `audio_clock_smoke.d` failure
      and stopping preroll buffering time leaking into the transport position.
- [x] **Repaired `tests/synced_playback_preroll_smoke.d`** (failed at line 112
      on base): assertions were written for synchronous frame-step previews,
      but previews are debounced and a cache hit still dispatches a request
      (no new process). Rewrote to match real behavior and added a warm-step
      block (pause → re-warm → step → no seek, no preview request, buffered
      frame displays).
- [x] **Verified:** `dub test` 33 modules; editor/playback/audio-clock/
      seek-resilience/static-sequence/synced-preroll/layout/export/gpu-decode/
      model/proxy smoke tests all pass; `dub build` links. Full details in
      testing_progress_and_methods.md.
- [ ] Not yet manually played in the real GUI (headless + smoke verified); a
      human Play/Pause/scrub/step pass on this 4-CPU host is still worthwhile,
      especially live-mode composition playback and the muted-fallback path.

## 2026-08-18 — Aurora Cut timeline playback: never stop, never desync, prewarm/cache (user request)

- [x] User: playback feels burdened/unpredictable and stops for performance
      reasons; want prewarming+caching so playback, playhead moves, and the
      wait after a move never stop or desync, at efficient perfect playhead
      playback with no latency.
- [x] **Root causes found (end-to-end code review):**
  1. **Hard "Buffering video…" stop mid-playback.** When the displayed frame
     lagged the audio clock by >75 ms, `waitForVideoBuffer()` PAUSED audio and
     the transport, then re-prerolled — the "randomly stopping" experience.
  2. **Shallow 16-frame video queue** (~0.53 s at 30 fps) left little cushion
     for decode jitter, so #1 fired often under load.
  3. **No adaptive resolution.** When the compositor/decoder couldn't keep up
      at the chosen mode, nothing stepped the decode height down; it stalled.
     (NOTE: the adaptive solution attempted below was later REVERTED — see the
     2026-08-18 second pass — because its mid-playback stream restarts caused a
     black screen in the real GUI.)
  4. **Prewarm started only 100 ms after the playhead settled** and the keep
      window was only ~2 slot-queues, so Play right after a scrub was often cold.
  5. **Audio serialized behind the first video frame**, adding press-Play-to-
      sound latency (noted as an open item in the 2026-08-13 research).
  6. **Live compositor rendered at a fixed 16:9 preset then downscaled** to
      the decode size — wasted pixels and stretched non-16:9 sequences (open
      item #1/#2 from the 2026-08-13 research).
- [x] **Fixes implemented:**
  - **Never stop for video lag.** Removed the `waitForVideoBuffer` hard-stop
    and the whole `_playbackVideoWaiting` machinery. The transport keeps the
    audio clock running and lets the display catch up by fast-forwarding stale
    frames (standard A/V catch-up), so it never pauses for performance.
  - **Deeper frame queue:** `VideoFrameStream` slots 16 → 24 (≈0.8 s at
    30 fps) and the prewarm keep-alive window widened 32/fps → 48/fps.
  - ~~**Adaptive decode height:** when the frame queue stays empty ≥0.3 s during
    steady playback, the decode/composite height steps down one ladder rung
    (1080→720→540→480→360→240) and the video stream restarts at the current
    audio position while audio keeps playing (video-only restart, no audio
    re-gate). With ≥12 s of stable full queue it steps back up. 5 s cooldown
    after any change prevents oscillation. Status reports the step.~~
    **REVERTED (2nd pass): its mid-playback stream restart caused a black
    screen in the real GUI. See the "black screen on Play" section below.**
  - **Prewarm immediacy:** settle debounce 100 → 60 ms; a committed paused
    seek sets `_playbackPrewarmPrompt` so the warm decoder starts on the next
    tick; the whole prewarm/prepare path uses `liveDecodeHeight()` so prewarm
    always matches what Play would start.
  - **Concurrent audio:** `startPlaybackStreams` starts the audio transport
    PAUSED at the same time as the video decoder, so time-to-sound overlaps the
    video spawn. The first-frame handler still gates presentation on the
    prerolled frame.
  - **Live compositor efficiency + aspect parity:** live playback now builds
    the compositor preset directly from the decode size
    (`previewPlaybackPreset(decode)`), so `compositeStreamArguments` elides its
    final `scale` (no double render) and portrait/square sequences are no
    longer stretched onto 16:9. Pause/scrub and play now use the same aspect.
    `requestPlaybackStill`/`dispatchPendingPreview` follow the decode height.
- [x] **Tests updated/added:**
  - `editor_smoke.d`: EOF regression rewritten for the never-stop behavior
    (decoder end must not halt; playback completes at the sequence end; no
    "Video decoder ended…" status); direct-playback audio assertions updated
    for concurrent-paused audio. (The adaptive-downgrade block was added and
    then REMOVED with the adaptive mechanism — see the black-screen section.)
  - `synced_playback_preroll_smoke.d`: same concurrent-paused-audio assertion
    update.
  - Removed the obsolete `_playbackVideoWaiting`/buffering state machine
    (fields, `waitForVideoBuffer`/`resumeAfterVideoBuffer`/
    `advancingVideoWaitClock`, the waiting branch, the EOF-while-waiting block,
    and the `simulateVideoBufferWaitForTesting` hook).
- [x] **Verified:** `dub test` 33 modules pass; `dub build` links; editor-smoke
      (3x), synced-preroll-smoke, static-sequence-smoke, seek-resilience-smoke
      (with base-av media), playback-stress, audio-clock-smoke, playback-proxy-
      smoke all pass on Windows (DMD + `-version=AuroraHeadless`).
- [ ] Manual GUI pass on this 4-CPU host: play a multi-clip live timeline
      under load — the status must never show "Buffering video…" and playback
      must not stop; scrub then press Play quickly and confirm the warm stream
      is adopted (no visible process-start hitch).
- [ ] Pre-existing (unrelated to this change, reproduces on the base commit):
      `tests/playback_seek_resilience_smoke.d` fails at line 115 when given
      `stress.mp4` (a 2.0 s real file declared 3.0 s) — live composition never
      becomes ready within the test window. It passes with `base-av.mp4`
      (1.5 s real file declared 3.0 s). Worth a follow-up investigation of the
      media/duration mismatch.

## 2026-08-18 (2nd pass) — black screen on Play in the real GUI; adaptive mechanism reverted

- [x] User: after the rework, Play in the real app shows only a black screen.
- [x] **Diagnosis (evidence, not guesses):**
  - The user's real session log (`aurora-cut.log`, 20:05:58, Aurora Cut 0.66.1
    + Vulkan) shows "Adaptive playback decode switched to 320x420 / 320x360"
    firing THREE times in ~40 s while scrubbing a portrait 720x960 shorts
    project (`raiserfredposts.auroracut`, webm VP9 source + text overlays).
    Each downgrade ran `restartPlaybackVideoAtPlaybackClock()` — a mid-playback
    stream teardown + FFmpeg respawn while audio kept running. On a slow
    4-CPU machine the new lower-resolution composite cannot catch the already-
    running audio clock, so the transport holds the last presented frame
    (re-prerolling) and the preview stays frozen/black while audio plays on.
  - Wrote `tests/live_portrait_playback_repro.d` (headless, real ffmpeg, the
    user's actual proxy mp4 AND the actual VP9 webm, portrait 720x960
    composition, transform + text overlay forcing live composition). It plays
    the live composition at 320x390 and samples 8x8 grid pixels every 250 ms:
    average brightness stays ~40-80 (NON-BLACK) the whole 10 s run. So the
    decode/composite path is provably correct headless — the black screen is
    the mid-playback adaptive restart interacting with the real audio clock /
    Vulkan rendering, not the frame content.
- [x] **Action:** removed the entire adaptive-decode mechanism (fields,
      ladder, downgrade/upgrade helpers, `restartPlaybackVideoAtPlaybackClock`,
      the `_playbackRestartPending` first-frame branch, the onTick queue-empty
      detector, test hooks, and the editor-smoke adaptive regression). All
      decode-height call sites restored to `liveDecodeHeight()`. Playback now
      never restarts the stream mid-flight; on a slow machine it simply holds
      the last frame and catches up by dropping stale frames (the "never stop,
      never desync" behavior from the original ask) without any resolution
      churn. Kept: 24-slot frame queue, prewarm prompt + 60 ms debounce, 48/fps
      prewarm window, concurrent paused audio, no hard "Buffering video…" stop,
      and the aspect-correct live compositor preset (`previewPlaybackPreset`).
- [x] **Verified:** `dub test` 33 modules; `dub build` links; editor-smoke,
      synced-preroll-smoke, static-sequence-smoke, seek-resilience-smoke (with
      base-av), playback-stress, audio-clock-smoke, playback-proxy-smoke all
      pass; the portrait live-composition repro plays non-black with the user's
      exact webm.
- [ ] Give the user this build to confirm Play shows video again. If black
      persists, the remaining suspects are GUI-only (Vulkan `drawRgbImage`,
      the real waveOut clock interacting with the concurrent-paused audio, or
      hardware decode) — those need a screenshot and a debug GUI session, not
      headless assertions.

## 2026-08-18 (3rd pass) — REAL root cause of the black screen: hardware decode forced onto AV1

- [x] User still saw "instantly black" Play even after the adaptive revert —
      the previous diagnosis was wrong.
- [x] **Definitive reproduction:** added `openProjectForTesting` hook and
      `tests/playback_black_screen_repro.d` which opens the user's actual
      project (`raiserfredposts.auroracut`) headless, scrubs, then presses Play
      and samples BOTH the raw preview frame and the rendered window surface:
      - Scrubbed still: RAW brightness 91 (visible).
      - After Play: RAW avgRGB **0,0,0** — the composite stream emitted pure
        black frames the entire run. Window surface 46% near-black.
      - ffmpeg logged `Decode error rate 1 exceeds maximum 0.666667` (AV1).
- [x] **Root cause:** the user's source is an **AV1 .webm** (720x960), but its
      stored `videoCodec` is **empty** (stale project file). The hardware-decode
      options (`-hwaccel d3d11va/dxva2/cuda`) are probed at startup against an
      **H.264 sample only**, yet `appendInputArguments` (exporter.d) and
      `playbackDecodeInputOptions` (editor.d) applied them to ANY input whose
      stored codec wasn't exactly `"av1"`. Forcing the H.264-validated hwaccel
      onto AV1 makes the AV1 decode fail → the compositor graph outputs its
      black `color=c=black` canvas → pure black playback. The still/scrub path
      looked fine because the PreviewService served a cached frame.
- [x] **Fix (both call sites):** the probed hardware decode now applies ONLY to
      known H.264/HEVC codecs; any other/unknown codec decodes on the CPU where
      FFmpeg auto-selects the correct decoder, and detected AV1 still uses the
      deterministic `-c:v libdav1d`. This is the correct general rule: an
      H.264-validated accelerator must never be forced onto a stream whose codec
      is unknown or different.
- [x] **Verified:** re-ran `playback_black_screen_repro.d` on the user's project
      — playback RAW brightness is now ~130-140 (real video, no AV1 decode
      errors), window ~87. `dub test` 33 modules; `dub build` links; editor-
      smoke, synced/static/seek/stress/audio-clock/proxy smokes all pass.
- [x] New `aurora-cut.exe` built at the repo root with this fix. Launch and press
      Play — the preview should now show the actual timeline picture.
- [ ] Follow-up (perf, not black): live-composition playback decodes the ORIGINAL
      AV1 webm on the CPU (720x960) instead of the 540x720 H.264 playback proxy.
      On a 4-CPU host this will be choppy. Consider letting the playback
      composite request substitute `playbackAssetForPreview` (proxy) when
      `enablePlaybackDecode` is set, mirroring the direct path.

## 2026-08-18 (4th pass) — Loop playback with work-area In/Out marks

Request: "if loop is active and in and out marks exist, loop between the marks."

- [x] Verified this already worked at Play time: `startPlayback` clamps the
      transport to `[_workIn, _workOut]` when `_loopEnabled` (falls back to the
      whole sequence without markers), `loopPlaybackRestart` rewinds to
      `_playbackStart`, and the onTick end-check wraps. The editor-smoke loop
      test covers marks-set-then-loop-then-play.
- [x] **Gap:** the order of operations mattered. Toggling loop ON mid-playback
      (or setting/clearing the marks mid-playback) never re-derived the bounds,
      so it kept looping the whole sequence. Fixed:
  - New `_playbackFullEnd` keeps the un-clamped sequence range from
    `startPlayback` (reset in `stopPlayback`).
  - `applyLoopRangeToBounds()` centralizes the mark-clamp logic (was inline in
    `startPlayback`).
  - `applyLoopPlaybackBounds()` re-derives bounds mid-playback: on loop-ON
    (or marks change while loop is on and sequence playback is running) it
    re-clamps to the markers and pulls the playhead inside (wraps to In when
    past Out). Loop-OFF leaves the current bounds untouched.
  - Wired into `toggleLoop`, `setWorkIn`, `setWorkOut`, `clearWorkRange`.
- [x] **Test:** new editor-smoke block starts playback with loop OFF (asserts
      full-sequence bounds), clicks the loop button mid-flight (asserts bounds
      instantly become [0.5, 0.9] and it wraps at the Out marker), then moves
      the Out marker to 0.7 while looping (asserts the wrap point re-bounds
      live). Passes.
- [x] **Verified:** `dub test` 33 modules, editor-smoke, synced-preroll-smoke,
      static-sequence-smoke all pass; app source links clean.
- [x] `aurora-cut.exe` rebuilt at the repo root with both loop fixes. Play with
      loop + I/O marks to confirm the wrap between the markers.
- [x] **Follow-up breakage (user report):** after a session that first played
      WITHOUT loop, then paused, then enabled loop + set marks, pressing Play
      again looped from the SEQUENCE START instead of the In marker.
      - Root cause: `resumePlayback` never re-applied the loop bounds, and
        `applyLoopPlaybackBounds` early-returned while `_playbackRunning` was
        false — so a resume kept the stale `[0, full-sequence]` bounds and
        `loopPlaybackRestart` rewound to 0.
      - Fix: `applyLoopPlaybackBounds` now guards on `_playbackAsset is null`
        (not `_playbackRunning`), and `resumePlayback` calls it after the
        pending-seek handling so a resumed transport is re-confined to the
        markers. This also makes toggling loop on while PAUSED re-bound the
        idle transport.
      - Test: new editor-smoke block — play loop-off → pause → enable loop +
        marks → resume, asserting bounds become [0.5, 0.9] and it wraps at the
        Out marker. Passes.

## 2026-08-18 (5th pass) — Undo/redo for In/Out marks + free playhead drag

User request: (1) Undo/Redo must track removal/restoration of the timeline
In/Out marks; (2) the timeline playhead must be draggable outside the bounds of
playback.

- [x] **Undo/redo for marks:** `TimelineSnapshot` now carries the work-area
      state (`hasWorkIn/workIn/hasWorkOut/workOut`), captured in
      `captureTimelineSnapshot` and restored in `applyTimelineSnapshot`
      (re-syncing the timeline work area and re-deriving loop bounds).
      `setWorkIn`/`setWorkOut`/`clearWorkRange` now capture history before
      mutating, so every mark change is undoable/redoable.
- [x] **Free playhead drag:** the playhead is a free timeline cursor.
      - `seekPlayback` clamps to `[0, _playbackFullEnd]` (full sequence) instead
        of `[_playbackStart, _playbackEnd]` (the loop marks).
      - `commitPendingSeek` parks a target OUTSIDE the active playback range
        (playhead dragged past the loop markers) instead of clamping/wrapping
        it, stopping playback and showing the still there.
      - the onTick end-of-playback check is guarded with `!_seekPending` so a
        mid-drag position past the Out marker never triggers a wrap.
      - Pressing Play from a parked outside position re-enters the loop range
        via `applyLoopPlaybackBounds` (wraps to the In marker).
- [x] **Tests** (editor-smoke): mark undo/redo sequence (set In, set Out, clear,
      undo x3 restores In-only → no-marks → both, redo x2 restores forward);
      free-playhead block (drag to 1.2 past Out parks there, drag to 0.2 before
      In parks there, Play re-enters [0.5, 0.9]).
- [x] Adjusted one pre-existing assertion: the early clip-add undo test asserted
      the undo stack was empty after one undo; mark history now legitimately
      leaves prior entries, so it asserts redo-enables only.
- [x] **Verified:** `dub test` 33 modules, editor-smoke, synced-preroll-smoke,
      static-sequence-smoke all pass; `aurora-cut.exe` rebuilt at the repo root.

## 2026-08-18 (6th pass) — Snap toggle button shows active state in blue

User request: when timeline snapping is activated the corresponding button
must be blue (pressed/active accent), like the Loop transport button.

- [x] Stored the snap header button as `_snapButton` (id `timeline-snap`) and
      added `updateSnapButton()` which applies `setAccent(snappingEnabled)`,
      mirroring the Loop button's `setAccent(_loopEnabled)` pattern. Called on
      click and once after `_timeline` is constructed (snapping defaults ON, so
      the button starts blue).
- [x] Added `snappingEnabledForTesting()` hook.
- [x] **Test** (editor-smoke): samples a background pixel of the button (dark
      theme accent `0x4f8cff`) — asserts it is blue while snapping is on, not
      blue after toggling off, and blue again after re-enabling. Note: the
      pointer is moved off the button before sampling because a clicked button
      stays hovered and paints `accentHover`.
- [x] **Verified:** `dub test` 33 modules and editor-smoke pass;
      `aurora-cut.exe` rebuilt at the repo root.
