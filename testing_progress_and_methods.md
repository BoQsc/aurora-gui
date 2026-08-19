# Testing Progress and Methods (Aurora Cut)

## Released v0.66.6 STILL "waiting for audio": stale locked ffmpeg cache (2026-08-19)

- User: "it keeps on saying it's waiting for audio before playback starts. So
  there is absolutely no progress yet."
- **Root cause (final)**: v0.66.6 DID embed the corrected FFmpeg
  (`--enable-muxer=pcm_s16le`, verified by extracting the embedded ffmpeg
  from the published exe and running `-f s16le` -> 192,000 bytes of valid
  PCM). But the extracted-file cache in `%TEMP%\Aurora-Cut-ffmpeg\ffmpeg.exe`
  was the OLD broken build (size 13,479,936, `--enable-muxer=...s16le...`,
  timestamp 13:03). When the user launched v0.66.6 at 15:51, the app tried to
  overwrite the cache (new embedded ffmpeg is 13,480,464 bytes, size differs
  by 528 so `writeIfDifferent` WOULD write), but the still-running v0.66.5
  process held `ffmpeg.exe` locked, so `write` threw and the `catch
  (Exception) {}` silently swallowed it. v0.66.6 then put the OLD directory
  first on PATH and used the OLD broken ffmpeg -> audio decode produced no
  samples -> "Waiting for audio output before playback starts."
- **Evidence**:
  1. `tasklist` showed BOTH `aurora-cut-v0.66.5.exe` (PID 10672, started
     14:34) and `aurora-cut-v0.66.6.exe` (PID 7156, started 15:51) running.
  2. The cached `%TEMP%\Aurora-Cut-ffmpeg\ffmpeg.exe` could not be opened
     ("being used by another process") - locked by the v0.66.5 instance.
  3. The cached file's config still showed the old `s16le` muxer flag.
  4. Extracted the v0.66.6 embedded ffmpeg (PE at offset 3722608, length
     13,480,464; ffprobe at 17203072, length 13,836,224): config shows
     `pcm_s16le` and `-f s16le` produces valid PCM.
- **Fix** (`source/auroracut/ffmpegbundle.d`): extraction is now
  content-keyed - each distinct bundle (by embedded ffmpeg/ffprobe sizes)
  extracts into `%TEMP%\Aurora-Cut-ffmpeg\ffmpeg-<ffmpegSize>-<ffprobeSize>\`
  instead of overwriting one shared `ffmpeg.exe`. A newer release never
  collides with an older build's files, a locked file from a concurrent
  instance cannot block a correct extraction (the keyed dir already has the
  right bytes), and every instance uses its own build's ffmpeg. A fallback to
  the plain root directory remains if the keyed directory fails.
- **How to verify**: close ALL Aurora Cut instances, delete
  `%TEMP%\Aurora-Cut-ffmpeg`, launch the fixed release, and confirm the cache
  gains `Aurora-Cut-ffmpeg\ffmpeg-13480464-13836224\ffmpeg.exe` (or matching
  sizes) with a `pcm_s16le` config.
- **Gotcha for users**: never keep an older Aurora Cut running while testing a
  newer one - the old instance locks the shared temp cache. With the
  content-keyed fix this no longer matters, but stale running instances also
  run stale code.

## aurora-browser: desktop browser shell on aurora-web (2026-08-19)

A new executable `aurora-browser/` wraps the `aurora-web` engine in an
Aurora-D `GuiWindow` with real browser chrome. It is the first end-to-end use
of the web engine from a desktop app.

**Files:**

- `aurora-browser/dub.json` — executable; sourcePaths include
  `source`, `../vendor/aurora-d-0.4.5/source`, `../aurora-web/source`;
  libs-windows `user32 gdi32 shell32 wininet`, lflags-windows
  `/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup`, portable-release buildType, v0.66.3.
- `aurora-browser/source/app.d` — entry point: `GuiWindow` + `BrowserRoot`;
  `--screenshot <path>` runs a software-render paint-and-save cycle.
- `aurora-browser/source/aurorabrowser/appui.d` — `BrowserRoot` (VBox):
  toolbar (Back/Forward/Reload buttons, `AddressField`, Go, New tab), tab strip
  label, `WebPageView` content widget, status bar. `WebPageView` overrides
  `Widget.onPaint(ref Canvas)` and calls `page.layout()` + `page.paint(canvas,0,0)`.
- `aurora-browser/RUN-WINDOWS.bat` — `dub run --build=release`.
- `aurora-browser/tests/headless_smoke.d` — UiTestDriver smoke test (12 checks).

**How to build and test:**

```
cd aurora-browser
dub build --compiler=dmd            # debug build: succeeds, exe in aurora-browser/
dub build --compiler=dmd --build=release
aurora-browser.exe                  # interactive; software renderer fallback ok
aurora-browser.exe --screenshot out.ppm   # exit 0, writes PPM
dmd -i -version=AuroraHeadless -Isource -I..\vendor\aurora-d-0.4.5\source -I..\aurora-web\source tests\headless_smoke.d -of=build\aurora-browser-headless-smoke.exe
build\aurora-browser-headless-smoke.exe   # prints headless_smoke: ALL PASSED
```

**Real Aurora-D APIs used (verified in `vendor/aurora-d-0.4.5/source`):**

- `WindowOptions` (`aurora.platform.base`) with `title/width/height/resizable/
  darkTitleBar/renderer`; `RendererPreference.software`.
- `GuiWindow(WindowOptions, Theme)`; `setRoot(Widget)`; `run()`; `close()`;
  `saveScreenshot(string)`; `surface()`; `setTitle(string)`.
- `Theme.light()`; `UiTestDriver(GuiWindow)` with `resize(Size)`/`paint()`/
  `text(dstring)`/`pressKey(Key, uint)`/`tickTree` (via root).
- `Widget` (`aurora.widget`): `add(T)`/`onLayout`/`onPaint(ref Canvas)`/
  `onBoundsChanged`/`onKeyDown(ref Event)`/`setEnabled`/`setBounds`/`size()`/
  `setId`/`id`/`children`; `layoutTree()`/`paintTree` internals.
- `HBox`/`VBox`/`Panel`/`Spacer` (`aurora.layout`), `layoutHints().flex/
  preferredWidth/preferredHeight`.
- `Button` (`aurora.widgets.button`): `setIconSize(int)`, `onClick`,
  `setAccent(bool)`.
- `TextField`/`TextArea`/`TextEditor` (`aurora.widgets.texteditor`):
  `textUtf8()`, `setText(string, bool)`, `setPlaceholder`, `onSubmitted`,
  `requestFocus()`, `selectAll()`. Single-line: `TextField("")`.
- `Label` (`aurora.widgets.label`): `setText`, `setScale`.
- `Canvas`: `fillRect`, `drawTextInRect`, `layoutText`, `drawLayout`,
  `translated`, `clipped`.
- `Key`/`KeyModifier`/`Event` (`aurora.event`): `Key.enter/left/right/t`,
  `event.control()/alt()`, `KeyModifier.control/alt`.
- `WebPage` (`auroraweb/package.d`): `setHtml(string)`, `executeScripts()`,
  `layout()`, `paint(Canvas,int,int)`, `paint(Surface)`, `root()`, `resize(int,int)`.
- `Element` (`auroraweb.dom`): `tag`, `elements`, `textContent()`, `box`.

**Methods / gotchas learned:**

- A `WebPage` is constructed with a fixed viewport (`WebPage(int,int)`); there
  was NO way to resize it. The browser shell constructs pages before the first
  layout (content size 0), so pages laid out at width 1 and text wrapped to a
  single column. Fix: added `WebPage.resize(int width, int height)` (+
  `width()/height()`) in `aurora-web/source/auroraweb/package.d`, and
  `WebPageView.onBoundsChanged` calls `page.resize` before `layout()`.
- Browser shortcuts (Alt+Left, Ctrl+L) typed while the address field has focus
  were swallowed by the base `TextField` (caret movement). Fix: subclass
  `AddressField : TextField` and intercept the shortcuts in `onKeyDown`.
- The JS interpreter threw `Expected ')'` for `for (var i=0; i<n; i++)`:
  `parseFor()` in `aurora-web/source/auroraweb/js.d` parsed the init clause but
  never consumed the terminating `;` before parsing the test expression. Fixed
  with `match(";")` after both the var-decl and expression init paths.
  Confirmed with the aurora-web `dub test` (35 modules still pass).
- `dub build --compiler=dmd --build=portable-release` fails on this machine for
  EVERY package (including aurora-notepad): `-mscrtlib=libcmt` needs MSVC's
  `libcmt.lib`, and only DMD's mingw libs are installed. Debug and plain
  `--build=release` both work. Not a regression from this work.
- Backtick string literals are `` `...` `` — there is NO `q` prefix form in D
  (that's D's `q"..."` delimited strings). `return q`...`` does not compile.
- `std.algorithm.startsWith` is required for string prefix checks; D string
  UFCS does not include it by default.

## aurora-web first milestone: own HTML/CSS/layout/paint + from-scratch JS engine (2026-08-19)

A new DUB library `aurora-web/` implements the first full browser-core
pipeline on top of Aurora-D, with **no third-party engine**:

- HTML tokenizer/parser -> DOM (`auroraweb.html`, `auroraweb.dom`)
- CSS parser + selector matching + cascade/specificity (`auroraweb.css`)
- Block/inline layout + box model + explicit heights (`auroraweb.layout`)
- Paint to Aurora Canvas (backgrounds, text via Aurora TextLayout, borders)
  (`auroraweb.paint`)
- A from-scratch JS engine in D: lexer -> parser (AST) -> tree-walking
  interpreter with numbers/strings/bools/null/undefined/objects/arrays/
  functions/closures/prototypes, arithmetic/equality/logical/ternary,
  var/let/const, if/else, while, for, for-in, function decls, return,
  throw/try-catch (`auroraweb.js`)
- DOM bindings exposed to JS: `document`, `getElementById`, `querySelector`,
  `createElement`, `appendChild`, `textContent`, `addEventListener`,
  `dispatchEvent` (`auroraweb.dombind`)
- Public entry `WebPage` (`auroraweb/package.d`) with
  `setHtml/setStylesheet/runScript/layout/paint`.

**How to build and test:**

```
dub build --compiler=dmd            # in aurora-web/
dub test  --compiler=dmd            # 35 modules pass unittests
dmd -i -version=AuroraHeadless -Isource -Iaurora-web\source -Ivendor\aurora-d-0.4.5\source tests\auroraweb_render_smoke.d -of=build\auroraweb-smoke.exe
build\auroraweb-smoke.exe           # "auroraweb render smoke: ALL PASSED"
```

**Methods / gotchas learned:**

- D keyword collisions: `function`, `scope`, `float` cannot be used as enum
  members/parameter/field names. Renamed `JsKind.function`->`JsKind.func`,
  `scope` param -> `sc`, `ComputedStyle.float` -> `floatStyle`.
- D has no `int?`/`Color?` nullable syntax. Use sentinel (`-1`) or a struct
  with a `present` flag (`NullableColor`).
- `indexOf` returns `ptrdiff_t` (long); assigning into `int` fails. Use
  `ptrdiff_t` for colon/semi positions in CSS decl parsing.
- `key in aa` returns a pointer; write `(key in aa) !is null`, not
  `key in aa !is null`.
- `execNode` originally used AST node *indices*; switching to a `Node` class
  (by reference) removed an entire class of index/type bugs.
- Tree-walking return propagation: a `return` inside a function body was
  silently dropped. Fixed with `rt.returned`/`rt.returnValue` flags that the
  block/if/while/for executors check after each child.
- Method calls: `arr.push(4)` must bind the receiver as `this`. The `call`
  node now detects a `member` callee and passes `children[0]` of the member
  as `thisArg`. Without it, `arr.push` silently failed (arrlen stayed 3).
- `Canvas.layoutText` takes `const(dchar)[]`, so UTF-8 `string` must be
  converted to `dchar[]` before shaping.
- parseCompound infinite loop: after consuming `.`/`#`, the scanner must
  advance `i = start` before scanning the ident; otherwise it re-reads the
  same `.`/`#` forever.

## Released v0.66.5 STILL no audio: CI embedded a stale minimal ffmpeg (2026-08-19)

- User: "Absolutely no improvement in the release."
- **Root cause**: v0.66.5 DID rebuild the minimal FFmpeg with the corrected
  `--enable-muxer=pcm_s16le` flag (minimal-ffmpeg run `32247401685` succeeded,
  built from the fixed commit). But the portable single-exe workflow
  (`portable-windows.yml`) downloads the minimal ffmpeg artifact with:
  `gh run list --workflow minimal-ffmpeg.yml --status success --limit 1` -
  i.e. the LATEST SUCCESSFUL run regardless of commit. The two workflows run
  in parallel on the same push:
  - minimal-ffmpeg rebuild: started 11:24:13, COMPLETED 11:32:05 (~8 min)
  - portable build: started 11:24:16, COMPLETED 11:26:14 (~2 min)
  The portable build finished 6 minutes BEFORE the rebuild, so it embedded the
  OLD artifact (still `--enable-muxer=s16le`, no s16le raw PCM muxer). Audio
  remained broken.
- **Verification method**:
  1. Extracted the embedded ffmpeg from the published `aurora-cut-v0.66.5.exe`
     (PE at offset 17202560, 13,836,224 bytes). Its config still showed
     `--enable-muxer='...s16le...'` - the OLD flag.
  2. Ran `-f s16le` against it: "Requested output format 's16le' is not
     known" / no output produced.
  3. Queried the GitHub Actions API: confirmed the minimal-ffmpeg rebuild ran
     and succeeded but the portable run downloaded the stale artifact because
     of the parallel scheduling.
- **Fix** (`portable-windows.yml`): the download step now looks up a
  successful minimal-ffmpeg run built from the EXACT current commit
  (`gh run list --workflow minimal-ffmpeg.yml --commit "$SHA"`). If none
  exists, it dispatches `gh workflow run minimal-ffmpeg.yml` and polls
  (90 x 20 s) until that commit's run succeeds, THEN downloads it. This
  guarantees the single-exe embeds the ffmpeg built from the released commit,
  never a stale artifact.
- **Confirmed `pcm_s16le` flag mapping**: extracting muxer component names
  from `libavformat/allformats.c` extern declarations at the pinned FFmpeg
  commit yields exactly `pcm_s16be` and `pcm_s16le` (not `s16le`). FFmpeg's
  `--enable-muxer=NAME` builds the exact glob `NAME_muxer`, so only
  `--enable-muxer=pcm_s16le` matches `pcm_s16le_muxer`; `s16le` matches
  nothing. The build-script fix is correct.
- **How to verify the next release**: extract the embedded ffmpeg from the
  published exe and run `ffmpeg.exe -hide_banner -formats | findstr s16le`
  (must show `s16le`) and a `-f s16le` decode-to-file (must produce bytes).

## Released v0.66.4 "waiting for audio output": bundled ffmpeg lacks s16le muxer (2026-08-19)

- User: "just like before this release, it's keeping on waiting for audio
  output or anything else, nothing like how it is before we release."
- **Root cause**: the portable single-exe release embeds a minimal
  cross-compiled FFmpeg. The app's audio playback decodes to raw s16le PCM
  via `-f s16le pipe:1` (`PcmAudioPlayer.decodeArguments` in `playback.d`
  and `compositeAudioArguments` in `exporter.d`). The minimal FFmpeg build
  config used `--enable-muxer=s16le`, which in FFmpeg's configure matches
  NOTHING: `find_things_extern` names the raw PCM muxer component
  `pcm_s16le_muxer`, and `--enable-muxer=s16le` creates the glob
  `s16le_muxer` which does not match `pcm_s16le_muxer` (no `*` wildcard).
  So the binary genuinely lacks the `s16le` raw PCM format/muxer:
  `ffmpeg -f s16le` fails with "Requested output format 's16le' is not
  known."
- **Symptom chain**: audio FFmpeg process launches (returns "success"),
  immediately errors on the missing muxer, produces no PCM, no audio clock
  is ever published. The transport enters `_playbackAwaitingAudioClock` and
  shows "Waiting for audio output before playback starts." for up to
  `playbackAudioClockFallbackSeconds` (5 s) before playing muted - and with
  prewarm/loop/restart it re-triggers, feeling permanently stuck. The full
  FFmpeg (RUN-WINDOWS.bat `dub run`) has the s16le format, so it works.
- **Diagnosis method (verified empirically)**:
  1. Ran the app's exact audio decode command against the bundled
     `%TEMP%\Aurora-Cut-ffmpeg\ffmpeg.exe`:
     `ffmpeg -i <webm> -vn -ac 2 -ar 48000 -sample_fmt s16 -f s16le -y out.raw`
     -> "Error initializing the muxer ... Invalid argument", no output.
     Same command with the full `C:\ffmpeg\bin\ffmpeg.exe` produced
     574,752 bytes of valid PCM.
  2. `-f pcm_s16le` also fails on the minimal build. `-formats` on the
     minimal build lists NO raw PCM formats; the full build lists
     `DE s16le`.
  3. Traced FFmpeg configure: `find_things_extern muxer FFOutputFormat
     libavformat/allformats.c` emits `pcm_s16le_muxer` from
     `ff_pcm_s16le_muxer`; the `--enable-muxer=` handler builds the exact
     glob `s16le_muxer` (no `*`), which does not equal `pcm_s16le_muxer`,
     so the option silently matched nothing (configure warns "did not match
     anything"). The correct flag is `--enable-muxer=pcm_s16le`.
- **Fix 1 (build)**: `scripts/build-minimal-ffmpeg-win64.sh` now uses
  `--enable-muxer=mp4,mp3,image2,rawvideo,pcm_s16le,null,flv,fifo`.
- **Fix 2 (app robustness)**: even with a correctly built FFmpeg, if the
  audio worker produces no samples (any cause), the transport must fail fast
  to muted playback instead of waiting 5 s repeatedly.
  - `playback.d` `playRequest`: after the PCM read loop, if `clockPublished`
    is still false (no PCM ever reached the sink), call
    `publishAudioFailure("The audio output produced no samples (FFmpeg
    exited N).")`.
  - `editor.d` onTick `_playbackAwaitingAudioClock`: if
    `_audioPlayer.error()` is non-empty after 0.35 s, stop audio, clear the
    wait flags, reset the clock, and set "Playing video without audio:
    <error>" immediately.
- **How to verify**: `dub test` -> 35 modules; editor-smoke full run passes.
  The definitive check is a fresh CI minimal-ffmpeg build: run
  `ffmpeg.exe -hide_banner -formats | findstr s16le` and
  `ffmpeg -f lavfi -i sine=... -f s16le -y out.raw` against the artifact.
- **Gotcha**: `-f s16le` is the OUTPUT format name (`.p.name`), while the
  configure component is `pcm_s16le_muxer`; the encoder is `pcm_s16le`. Do
  not confuse the three namespaces.

## Released v0.66.3 "playback/export" vs RUN-WINDOWS.bat difference (2026-08-19)

- User: "the released version of aurora cut does not behave or work properly
  like the one we do via simple RUN-WINDOWS.bat. I mostly see that playback
  have problems."
- **Root cause**: the portable single-exe release embeds the MINIMAL
  cross-compiled FFmpeg (git-2026-08-14 `c48230e`, `--enable-small`), while
  RUN-WINDOWS.bat (`dub run`) uses the FULL FFmpeg n7.1 from `C:\ffmpeg\bin`.
  The modern minimal build REMOVED the deprecated `-filter_complex_script`
  option (full n7.1 still has it). The app used it in exactly two export
  paths:
  - `exporter.d` `performComposition()` — every MP4/MP3 export.
  - `exporter.d` `renderCompositeFrame()` — composed single-frame render.
  On the release build those fail instantly:
  `Unrecognized option 'filter_complex_script'`. Live playback paths use
  inline `-filter_complex` and worked correctly with the bundled build.
- **Diagnosis method (all verified empirically, not guessed)**:
  1. Compared the extracted bundle (`%TEMP%\Aurora-Cut-ffmpeg\ffmpeg.exe`) to
     the release exe's embedded bytes (the bundle's first 1001 bytes appear at
     offset 11166528 inside `aurora-cut-v0.66.3.exe`) - same ffmpeg.
  2. `-h full | findstr filter_complex`: full n7.1 lists
     `-filter_complex_script`; the minimal build only lists `-filter_complex`
     and `-filter_complex_threads`.
  3. Ran the SAME export graph via `-filter_complex_script` (fails on
     minimal: `Unrecognized option`) vs inline `-filter_complex` (succeeds on
     BOTH builds, produced a valid MP4).
  4. Playback/scrub/live-composition verified working on the minimal build:
     basic h264 decode, `-hwaccel d3d11va` h264 (non-black raw dump), AV1
     `libdav1d` on the user's portrait 720x960 webm (all 648000 pixels
     non-black), and the app's own `playback_black_screen_repro` headless test
     in release mode (brightness 142-162 during Play, not black). The export
     failure was the only functional difference.
- **Fix**: `exporter.d` now passes the graph inline via `-filter_complex`
  instead of writing a `.ffgraph` file and using `-filter_complex_script`
  (the same approach the live playback/compositor already used). Removed the
  now-unused `std.file.write` import and the workspace `.ffgraph` writes.
  Command-line length is not a regression: Windows `CreateProcessW` caps at
  32767 chars and the inline playback paths already passed full graphs.
- **How to verify**: `dub test` -> 35 modules; editor-smoke full run passes;
  export-smoke produces composed.mp4/mp3 + title rasters with exit 0. Direct
  proof the minimal bundle now exports: the same inline `-filter_complex`
  graph run against `%TEMP%\Aurora-Cut-ffmpeg\ffmpeg.exe` produces a valid
  MP4 (12,180 bytes).
- **Gotcha for local single-exe builds**: `--build=portable-single-exe` /
  `--build=portable-release` fail on THIS dev machine with
  `lld-link: error: could not open 'libcmt.lib'` - the static MS CRT import
  library is only present on CI's windows-latest (VS toolchain). To locally
  build the release exe, install the MSVC build tools / static CRT or rely on
  CI. The debug `dub build` is unaffected.
- Gotcha: `aurora-cut.log` is append-only in the CWD, so it accumulates old
  `filter_complex_script` lines; always check the NEWEST run, not a raw count.

## yt-dlp normalize GPU NVENC (2026-08-19)

- User: "what does normalizing mean and why it takes so long?" -> normalization
  is a full CPU re-encode (libx264) into an editor-friendly MP4. It was ~1.1x
  realtime (117.9s for a 128s 1080p clip) while the exporter already used GPU
  h264_nvenc.
- **Fix**: normalization now uses `_tools.h264Encoder` from the tool scan
  (NVENC/QSV/AMF when available, libx264 fallback). Plumbed through
  `YtDlpDownloadRequest.videoEncoder` -> `enqueue` -> `downloadOne` ->
  `normalizeDownloadedVideo` -> `ytDlpNormalizedVideoArguments`. Per-encoder
  rate control: NVENC `-preset p4 -tune hq -rc vbr -cq 20 -b:v 0`; QSV
  `-preset medium -global_quality 20`; AMF `-quality balanced -rc cqp
  -qp_i 20 -qp_p 20`; libx264 `-preset veryfast -crf 20`. GOP keyframe flags
  (`-g 15 -keyint_min 15 -sc_threshold 0`) kept for all encoders.
- **Benchmark (this machine, 128s 1080p clip, ffmpeg 2026-08-19)**: NVENC
  `h264_nvenc -preset p4 -tune hq -rc vbr -cq 20 -b:v 0` = 27.6s (~4.6x
  realtime); libx264 `-preset veryfast -crf 20` = 117.9s (~1.1x realtime).
  ~4.3x faster. Output verified as valid h264 via ffprobe.
- **How to test in-app**:
  1. Launch aurora-cut, open the yt-dlp download dialog, download a YouTube
     video at 1080p.
  2. Watch the status bar: after "Download 100%" the "Normalizing X%" phase
     should now complete several times faster than before (NVENC on this GPU).
  3. Confirm the imported media plays and scrubs smoothly in the timeline.
  4. On a machine without a hardware encoder it falls back to libx264 (same
     result, slower) - verify no crash on a CPU-only box.
- Manual in-app confirmation still pending from the user.

## yt-dlp 403 throttling + retry/backoff + logging (2026-08-19)

- User: "ytdlp failed to start downloading a video, can you check why if there
  is anything in the logs about error".
- **Root cause**: YouTube 403-throttles the video-data stream mid-download on
  this network. The yt-dlp binary (2026.07.04) is the latest release, so
  updating it does not help. `--simulate` metadata fetch works; the actual
  `f137`/`136` stream dies after ~15% (~10 MB) with
  `ERROR: unable to download video data: HTTP Error 403: Forbidden`.
- **Diagnostic gap**: yt-dlp failures only went to the GUI status bar via
  `setStatus`; nothing was written to `aurora-cut.log`, so the log file gave no
  clue. Leftover `.part` file in the Downloads folder was the only trace.
- **Fixes**:
  1. `ytdlp.d` `downloadOne`: up to 3 attempts, backoff 2s/4s, **only for
     transient failures** (`ytDlpTransientFailure`: HTTP 403/429/5xx, timeouts,
     connection resets). Permanent errors (private/removed video, bad URL) fail
     fast. yt-dlp resumes leftover `.part` files on retry.
  2. `editor.d` `drainDownloadedMedia`: both success and failure are logged via
     `appLog` (failure includes URL + error tail).
- **How to test retry/backoff** (real network):
  1. Launch `aurora-cut.exe`, open the yt-dlp download dialog (Download with
     yt-dlp), paste a YouTube URL (e.g. The Offspring - You're Gonna Go Far,
     Kid), pick 1080p.
  2. Expect status-bar "Retrying in 2 s…" / "Retrying in 4 s…" if the first
     attempt 403s; if a retry succeeds the media is imported.
  3. Check `aurora-cut.log` for `yt-dlp download failed for '<url>': ...` on
     total failure, or `yt-dlp download complete: <path>` on success.
  4. Confirm no `.part` files remain in
     `%LOCALAPPDATA%\Aurora Cut\Downloads\` after success.
- Manual real-network retry is still to be confirmed by the user; the live 403
  reproduction and latest-version check are documented above.

## Open button merge + project media undo/redo (2026-08-19)

- User requests:
  1. Remove the separate Open button and rename the Recent button to Open, i.e.
     the Recent dropdown should carry the Open button's name/icon.
  2. Make undo/redo history include project media actions so an accidental
     media remove/unlink can be quickly undone/redone.
- Toolbar merge (editor.d):
  - Deleted the `Recent ▾` button (id `recent-projects`, field
    `_recentProjectsButton`).
  - The `Open` button (id `open-project`, `_openProjectButton`) now shows
    `Open ▾`, keeps the folder icon, and its onClick opens the recent-projects
    dropdown (`showRecentProjectsMenu`). "Browse project…" inside that menu
    opens the classic file dialog (unchanged).
- Media undo/redo (model.d / editor.d / project.d):
  - `TimelineSnapshot` gained a `MediaAsset[] assets` field so every history
    entry carries the full project-media asset array it references.
  - `MediaAsset.cloneAsset()` and `EditorModel.snapshotAssets()` /
    `restoreAssets()` deep-copy the array (metadata + proxy paths) so undoing
    a removal can never alias into the live model.
  - `captureTimelineSnapshot()` now includes `_model.snapshotAssets()`;
    `applyTimelineSnapshot()` restores it before the tracks.
  - `removeMedia()` commits history ("Remove media" / "Remove media and
    sequence clips") instead of `clearHistory()`. Undo restores the asset and
    any clips that referenced it.
  - Media imports (drop/import dialog/yt-dlp/paste-screenshot) commit a single
    "Import media" undo entry per batch: a "before" snapshot is lazily captured
    in `drainImportedMedia()` on the first actual asset add and committed once
    in `finishImportBatchIfIdle()`.
  - `newProject()`/`openProject()` reset `_importHistoryCaptured` /
    `_importHistoryBefore` so a stale cross-project snapshot cannot be committed.
  - project.d: `snapshotToJson`/`snapshotFromJson` serialize/deserialize the
    snapshot asset array; `assetFromJson()` extracted from `loadProjectFile`.
    `validHistorySnapshots()` now validates clips against the snapshot's own
    asset count (falling back to the project asset count for older files).
- Tests (tests/editor_smoke.d):
  - Open button assertions: text `Open ▾`, directly right of Save, no
    `recent-projects` widget, dropdown anchored below it, and "Browse project…"
    reopens the file dialog.
  - Media delete undo/redo: delete an unused media item via the Delete key,
    then Ctrl+Z restores the asset (and list), Ctrl+Y removes it again.
  - History-popup row indices shifted: the import step is now row 3; the
    disabled-step skip test walks through Import media and Place clip.
- project.d unittest: snapshot assets round-trip (path/duration) and stale
  snapshots referencing removed assets are still dropped.
- Verification:
  - `dub test` → 35 modules passed.
  - Headless `editor-smoke.exe` → "Aurora Cut multi-track editor smoke test
    passed." (exit 0).
  - `model_smoke` and `project-test` pass.

## Delete on media, empty-sequence playhead, In/Out in timeline menu (2026-08-19)

- User reported three timeline/editor issues:
  1. Delete on a selected Project Media item said "Select a sequence clip to
     delete".
  2. A new project with an empty sequence could not move the playhead on the
     timeline ruler.
  3. In/Out buttons should move into the timeline context menu.
- Root causes:
  1. `deleteSelected()` (editor.d) only handled timeline clips/transitions. When
     the media list owned keyboard focus, Delete still hit `_model.removeClip`
     and failed.
  2. `TimelineWidget.setPlayhead` clamped the new value to
     `[0, sequenceDuration()]`; on an empty sequence `sequenceDuration() == 0`
     so every scrub pinned the playhead to 0.
  3. Dedicated `In×`/`Out×` clear buttons sat in the sequence header (the
     "move in and out buttons" ask) while the actual Set In/Out commands lived
     only in the Export context menu.
- Fixes:
  1. `deleteSelected()` now checks `_mediaList.focused()` first; when the media
     list is focused and an item is selected, it calls `removeMedia(index,
     false)` (which refuses if the asset is used by sequence clips, with a clear
     status message). Focus is the reliable discriminator because clicking a
     media item calls `requestFocus()` on the list and clicking a timeline clip
     focuses the timeline.
  2. `setPlayhead` only clamps to the sequence maximum when the duration is
     positive; on an empty sequence the raw value is accepted so the playhead
     can scrub the ruler freely. (A positive duration still clamps normally.)
  3. Removed the `In×`/`Out×` header buttons and added "Set export In at
     playhead" (I), "Set export Out at playhead" (O), and "Clear export
     In/Out" (Shift+I/O) to the timeline context menu in
     `showTimelineContextMenu`. Removed the now-dead `clearWorkIn`/`clearWorkOut`
     helpers.
- Tests added to `tests/editor_smoke.d`:
  - Empty-sequence ruler click moves the playhead beyond 0 (after the initial
    layout assertions, before any media is imported).
  - Timeline context menu exposes Set export In/Out and Clear export In/Out
    (extended the existing clip context menu block).
  - The sequence header no longer has dedicated In/Out clear buttons
    (`timeline-in-clear` / `timeline-out-clear` ids absent).
  - Delete on a focused unused media item removes it from the project (after
    the persisted-history block). Added `syncMediaListForTesting()` to editor.d
    so the test can add an asset directly and refresh the bin.
- Verification:
  - `dub build` clean.
  - Headless `editor-smoke.exe base-av.mp4 overlay.mp4 audio.mp3` → "Aurora Cut
    multi-track editor smoke test passed." (exit 0).
  - `model_smoke` and `layout_smoke` pass.
- Command for editor-smoke on Windows (same as before):
  `dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source
  tests\editor_smoke.d -of=build\headless-smoke\editor-smoke.exe
  user32.lib gdi32.lib shell32.lib winmm.lib wininet.lib`
  then run the exe with the three fixture media files.

## Dropdown buttons toggle closed on a second click (2026-08-19)

- User: buttons like History should close their dropdown if the dropdown is
  already open when the button is clicked a second time (toggle behavior).
- The framework already provides the exact mechanism:
  - `PopupOverlay.setConsumeAnchorPress(bool)` (`aurora-d-0.4.5/.../popup.d:207`)
  - `ContextMenu.setConsumeAnchorPress(Rect globalAnchor)`
    (`aurora-d-0.4.5/.../contextmenu.d:110`)
  - `window.d` `dismissOutsidePopups` calls `dismissPopupForPointer` on every
    mouseDown; when the press lands inside the anchor rect and consume is set,
    the popup is dismissed AND the press is swallowed so the button's own
    onClick does NOT immediately reopen it. (Button activation needs a matched
    mouseDown + mouseUp pair; the consumed down means `_pressed` never sets.)
- Applied to every dropdown/toggle button in `source/auroracut/editor.d` and
  `source/auroracut/preview.d`:
  1. History popup — `_historyPopup.setConsumeAnchorPress(true)` (editor.d ~3564)
  2. Composition resolution popup — `_resolutionPopup.setConsumeAnchorPress(true)` (1510)
  3. Compress previous output popup — `_compressOutputPopup.setConsumeAnchorPress(true)` (1632)
  4. yt-dlp download dialog — `_downloadPopup.setConsumeAnchorPress(true)` (2850)
  5. Recent Projects menu (`showContextMenuBelow`) — `menu.setConsumeAnchorPress(Rect of button globalOrigin/size)` (2654)
  6. Inspector font presets menu (`showFontContextMenu`) — same (5663)
  7. Preview quality menu (`showQualityContextMenu`) — same (8646)
  8. yt-dlp quality menu inside the download dialog (`showYtDlpQualityMenu`) — same (2725)
  9. Inline text font menu in `preview.d` (`showInlineFontMenu`) — same (1604)
- For context menus (anchor keyed by global rect) the anchor rect is built from
  `button.localToGlobal(Point(0,0))` + `button.bounds().width/height`; the demo
  (`vendor/.../demos/windows_file_manager.d:5119`) confirms that pattern.
- Regression tests added to `tests/editor_smoke.d` after the history popup block
  (~1219): reopen History via the button, click the button again, assert
  `history-list` and `history-popup` are gone; then reopen Recent Projects,
  click the button again, assert `findOpenContextMenu(editor)` is null.
- Verification: rebuilt `aurora-cut.exe` (no errors) and ran the headless
  editor-smoke (`dmd -i -version=AuroraHeadless ... editor_smoke.d ...` then
  `editor-smoke.exe base-av.mp4 overlay.mp4 audio.mp3`) — "Aurora Cut multi-track
  editor smoke test passed." (exit 0), including the new toggle asserts.

## Timeline item clickability gap at the bottom (2026-08-19)

- User: after resizing the window there is a "gap" on timeline item
  clickability at the bottom of the item/row — resizing seems to shift where
  the mouse clicks land vs where the item is painted.
- Decided **upstream vs downstream** first: traced the framework's pointer
  pipeline (`aurora-d-0.4.5`): `window.d` `handleMouseDown` →
  `updateHover`/`targetAt` → `hitTest` → `dispatchToBubble` sets
  `event.position = current.globalToLocal(event.globalPosition)`; the OS
  pointer is converted via `DisplayScale.physicalToLogical`
  (`win32.d:1714`/`1848`/`2312`). That conversion is internally consistent
  (`types.d` round-trips at `types.d:335-338`), so the framework is NOT the
  culprit. The bug is downstream, in aurora-cut's `timeline.d`.
- Root cause: two row-geometry helpers disagreed by the constant
  `NewTrackDropGap = 8`:
  - **Paint** `trackRect()` (`timeline.d:874`):
    `y = rulerHeight() + NewTrackDropGap + rowTop(row) - _verticalScroll`.
  - **Hit-test** `trackAtY()` (`timeline.d:996`):
    `localY = y - rulerHeight() + _verticalScroll` (missing the 8 px gap).
  With a default 24 px track: painted row y∈[32,56), hit-tested row y∈[24,48).
  The bottom ~8 px of every painted clip body is a dead zone where
  `trackAtY` fails → `clipAtPoint` returns -1 → the click falls through to the
  playhead-scrub branch. `clipAtPoint` also gates on
  `trackRect(address).contains(point)` (the *painted* origin), so the two paths
  contradicted each other inside the same click handler. Resizing re-runs
  clamp/zoom and lands the clip body's bottom edge into that zone, which is why
  it looked resize-dependent. The earlier test helper `clipCenter()` clicked
  only the middle of clips, so no test ever touched the dead zone.
- Fix: `trackAtY()` now subtracts `NewTrackDropGap`
  (`localY = y - rulerHeight() - NewTrackDropGap + _verticalScroll`).
- Regression test (`tests/editor_smoke.d`, after the "selecting a timeline item
  moved the playhead" block): build the global point from
  `clipRectForTesting` at `bottom()-4` (inside the body, below the ±3 px
  track-resize band at `resizeTrackAtY`), deselect first, `driver.click`, then
  assert `selectedTrack()==v1 && selectedIndex()==0` and that a second click
  does not move the playhead.
- Verification workflow (proves the test catches the bug):
  1. With the fix: compile + run editor-smoke → passes.
  2. `copy timeline.d timeline.d.fixed`, `git checkout timeline.d` (revert fix
     only), rebuild editor-smoke → the new assert fails ("Clicking the bottom
     edge of a timeline item did not select it"), confirming the test detects
     the exact regression.
  3. `move timeline.d.fixed timeline.d` (restore fix), rebuild, re-run → passes.
  4. Full gate: `dub test --compiler=dmd --force` → 35 modules pass.
- Commands (same as other smokes):
  `dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source
  tests\editor_smoke.d -of=build\headless-smoke\editor-smoke.exe
  -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32
  -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet`
  then
  `build\headless-smoke\editor-smoke.exe
  build\headless-smoke\media\base-av.mp4
  build\headless-smoke\media\overlay.mp4
  build\headless-smoke\media\audio.mp3`.

## Timeline edits visible during live playback (2026-08-19)

- Previously, moving/resizing a clip while the playhead was playing only set
  `_sequenceRefreshDeferred = true`; the running FFmpeg snapshot kept showing
  the pre-edit timeline until pause/resume or a new Play command. The user
  reported this as "does not show changes/results in the playback".
- Fix in `source/auroracut/editor.d`:
  - `markTimelineChanged()` now also sets `_sequenceRefreshPending = true`
    while running, routing the edit through the existing 0.14 s debounce even
    during playback (rapid edits still coalesce).
  - `refreshSequenceAfterEdit()` no longer bails when running; instead it
    clears `_sequenceRefreshDeferred`, consumes the model revision, and calls
    `refreshPlaybackStreamsForEdit()`.
  - `refreshPlaybackStreamsForEdit()` re-anchors the clock to the current
    position and calls `startPlaybackStreams()` (the same in-place restart
    path as `loopPlaybackRestart`), so video + audio rebuild from the current
    playhead without stopping the transport.
- How it is verified:
  - `tests/editor_smoke.d` "non-blocking edits" block was updated: moving a
    clip during active playback must (a) keep the transport running
    (`sequencePlaybackForTesting()`), (b) rebuild the video compositor
    (`videoStatsForTesting().requests` increases — use `requests`, not
    `processesStarted`, because `requests` increments synchronously in
    `startCommand` while `processesStarted` increments on the worker thread),
    (c) clear the deferred flag and match the model revision.
  - Build/run:
    `dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source
    tests\editor_smoke.d -of=build\headless-smoke\editor-smoke.exe
    -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32
    -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet`
    then
    `build\headless-smoke\editor-smoke.exe
    build\headless-smoke\media\base-av.mp4
    build\headless-smoke\media\overlay.mp4
    build\headless-smoke\media\audio.mp3`
  - Full gate on this host: `dub test --compiler=dmd --force` → 35 modules;
    editor-smoke; static-sequence-playback-smoke (`still.png audio.mp3`);
    synced-playback-preroll-smoke (`base-av.mp4`);
    playback-seek-resilience-smoke (`base-av.mp4 overlay.mp4 audio.mp3`);
    playback-stress (`base-av.mp4`). All exit 0 with the fix.

## Crash when moving a clip during playback (2026-08-19, follow-up fix)

- After the live-refresh feature above, the user reported "absolutely crashed
  entire program i tried to move timeline item while playback was happening."
- Root cause: `refreshPlaybackStreamsForEdit()` called `startPlaybackStreams()`
  WITHOUT a try/catch. If the edit left the playhead past every clip's end
  (e.g. the sequence shrank below the playhead), the compositor throws
  "The selected export range is empty." (`normalizeExportRange`,
  `exporter.d:710`) and that exception propagated out of `onTick` → hard crash.
  The `aurora-cut.log` tail also showed `startPlaybackPrewarm()` failing every
  tick with the same exception (caught, but logged ~16×/s → frozen/laggy UI).
- Fix:
  1. `refreshPlaybackStreamsForEdit()` now wraps `startPlaybackStreams()` in
     try/catch; on failure it stops the transport cleanly (leaves the last
     visible frame) and sets status "Playback stopped: the edit left nothing to
     render at this point."
  2. New `_playbackPrewarmFailures` counter: after 3 consecutive prewarm start
     failures, `updatePlaybackPrewarm()` stops retrying (avoids the log flood /
     UI freeze). Reset in `notePlaybackPrewarmDirty()` on any playhead move/edit.
- New regression test `tests/playback_edit_crash_repro.d`:
  - Setup: one asset (duration 0.5) as clip A on V1 [0,0.5] and clip B on V2
    [0.6,1.1]; start live playback with the playhead at 0.7 (inside B).
  - Action: `editor.moveClipForTesting(v2, 0, v2, 0.0)` while playing → B now
    ends at 0.5, sequence shrank below the playhead → compositor empty range.
  - Assert: no crash; `sequencePlaybackForTesting()` is false after the
    debounced refresh (transport stopped gracefully).
  - Build/run:
    `dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source
    tests\playback_edit_crash_repro.d -of=build\headless-smoke\playback-edit-crash-repro.exe
    -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32
    -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet`
    then `build\headless-smoke\playback-edit-crash-repro.exe
    build\headless-smoke\media\base-av.mp4` → "passed (no crash on empty
    render range)."
- **Follow-up complaint (playback stops at old end):** "why playback stops at
  timeline last item end position before I start moving on the timeline instead
  of very last item after I move timeline item while playback is going." The
  live refresh restarted the compositor but left `_playbackEnd`/`_playbackFullEnd`
  at the PRE-EDIT sequence length, so the transport hit
  `_playbackPosition >= _playbackEnd - 0.001` (editor.d onTick) and called
  `finishPlayback()` at the old boundary. Fix: `refreshPlaybackStreamsForEdit()`
  now re-derives the bounds from `_model.sequenceDuration()` before restarting
  (updates `_playbackFullEnd`, `_playbackEnd`, `_playbackStart`, re-applies loop
  bounds, and refreshes `_playbackAsset.duration` for live composition).
  `tests/playback_edit_crash_repro.d` now also asserts the extend case: after
  moving the last clip forward during playback, `playbackEndForTesting()` grows
  and playback keeps running.
- `aurora-cut.exe` rebuild: `dub build --compiler=dmd --force`. NOTE if the app
  is currently running, the linker cannot overwrite the exe ("Access is
  denied") — close the app first, then rebuild.
- Gotcha: `editor-smoke` is currently failing at the History popup redo test
  (~line 1111) because the OTHER concurrent opencode session's history refactor
  is mid-flight — NOT related to this playback work. Re-check `git diff`
  before attributing failures.

## Suggested export names + title-based yt-dlp download names (2026-08-18)

- The Export MP4/MP3 dialog now suggests a name instead of a hardcoded
  `aurora-cut-export.mp4`:
  1. **Saved project's name** (`_projectPath` base name without extension) —
     the most recognizable handle; `fall of fallout.auroracut` → `fall of
     fallout.mp4`.
  2. **First media clip's source name** for unnamed projects (first video clip
     on the first video track for MP4, first audio clip for MP3, falling back
     to the other kind for media-only projects). A yt-dlp download therefore
     suggests the source title.
  3. **`aurora-cut-export`** when there is no media at all.
  - The stem strips the extension AND a trailing `.normalized` so a downloaded
    `Title [id].normalized.mp4` suggests `Title [id].mp4`.
  - **Dedup**: the suggested name is checked against the default
    `applicationExportDirectory()` and suffixed `-2`, `-3`, … up to 999 when it
    exists (same style as `compressedOutputPath`), so repeated exports never
    silently overwrite. `uniqueExportFileName` returns the base name only; the
    dialog combines it with the folder.
  - Editor hooks: private `suggestedExportName(ExportKind)`,
    `mainClipExportStem(ExportKind)`, static `exportNameStem`,
    `uniqueExportFileName`; public `suggestedExportNameForTesting()`.
- yt-dlp downloads now name files by **`%(title)s [%(id)s]`** instead of
  `aurora-<uuid>`:
  - `--restrict-filenames` was dropped so titles stay readable
    (`Rick Astley - Never Gonna Give You Up [dQw4w9WgXcQ].mp4`).
  - `--trim-filenames 120` keeps long titles under Windows path limits.
  - The rendered name is unknown before yt-dlp fetches metadata, so
    `--print-to-file after_move:filepath <marker>` has yt-dlp write the final
    post-processed path to a per-run marker file in `tempDir()`
    (`aurora-cut-ytdlp-<uuid>.txt`); `downloadedPathFromMarker` reads it and
    only accepts a supported-media path inside the Downloads folder (stale
    markers, wrong folders, or unsupported extensions are rejected).
  - `downloadedStem` turns the downloaded name into the normalized-copy prefix:
    `Title [id].mp4` → `Title [id].normalized.mp4`.
  - `ytDlpTitleOutputTemplate()` is public; `downloadArguments` gained a
    `markerFile` param (param named `titleTemplate` — `template` is a reserved
    D keyword).
- How it is verified:
  - `tests/editor_smoke.d`:
    - Export dialog (named project): open the Export MP4 dialog and assert the
      `file-dialog-name` field equals the stem of `recentOpenB` + `.mp4`, and
      the path field still equals `applicationExportDirectory()`.
    - Unnamed project, no media: `suggestedExportNameForTesting()` ==
      `aurora-cut-export.mp4` (right after Ctrl+N).
    - Unnamed project with a clip: drop `base-av.mp4` on V1, wait for the clip,
      assert `suggestedExportNameForTesting()` == `base-av.mp4`.
    - Dedup: write `base-av.mp4` into the test export folder and assert the
      suggestion becomes `base-av-2.mp4`.
  - `ytdlp.d` unittest (runs in `dub test`): `downloadArguments` for video AND
    audio produce the `%(title)s [%(id)s]` `-o` template, include
    `--print-to-file`/`after_move:filepath` and `--trim-filenames 120`, and do
    NOT include `--restrict-filenames`; `downloadedPathFromMarker` accepts an
    in-folder supported file, rejects out-of-folder/unsupported/missing
    markers; `downloadedStem` strips only the final extension.
  - Live yt-dlp probe (YouTube returns HTTP 403 from this network, so it was
    validated against a local `python -m http.server`): `yt-dlp
    --trim-filenames 120 --print-to-file after_move:filepath <marker> -o
    "<dir>/%(title)s [%(id)s].%(ext)s" -f b http://127.0.0.1:8123/base-av.mp4`
    produced `base-av [base-av].mp4` and the marker contained its exact path.
  - Full gate: `dub test --compiler=dmd --force` → 35 modules pass;
    editor-smoke full run; model/export/gpu-decode-args/recompress/layout/
    static-sequence smokes exit 0.
- Gotchas:
  - **This repo is shared across concurrent opencode sessions.** The other
    session was editing `editor.d`/`ytdlp.d`/`editor_smoke.d` at the same time
    (history-step toggle feature + focus ring). Their `template`-keyword fix
    and `extension` import landed inside this session's edits. Always verify
    with a fresh compile + `dub test` + editor-smoke at the END; check
    `git diff` before/after editing.
  - The standard smoke build uses **dmd** on this host
    (`dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source
    tests\editor_smoke.d -of=build\headless-smoke\editor-smoke.exe
    -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32
    -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet`); `ldc2` is NOT installed and
    `tail` is not a cmd.exe command (earlier `| tail` invocations silently
    swallowed compiler output).

## New Project button + Ctrl+N (2026-08-18)

- `EditorRoot.newProject()` (called by the `new-project` toolbar button and
  Ctrl+N) discards the current project into a fresh blank one. It autosaves the
  active project FIRST (to `_projectPath`, or the unnamed autosave
  `%LOCALAPPDATA%\Aurora Cut\Autosaves\untitled-autosave.auroracut` via
  `unnamedProjectAutosavePath()`), then: stops playback, cancels proxy work,
  clears `_model.assets`, restores one empty V1+A1 track
  (`_model.restoreTimeline([], [])`), clears work range, preview quality →
  720, composition → 1920×1080, clears `_undo`/`_redo` + clipboard, playhead →
  0, and re-syncs media list / timeline / inspector / title / scrubber
  (`syncTimelineRange` makes an empty scrubber max 0.001, not 0).
- Test hooks added: `newProjectForTesting()`, `projectDirtyForTesting()`.
- How it is verified (headless `tests/editor_smoke.d`, after the persisted
  history block): New button exists, labeled "New", left of Save; make a dirty
  project (`setWorkOutForTesting(1.5)`), click New, assert path==“”, not dirty,
  no assets, exactly V1+A1 empty, undo/redo==0 (Undo disabled), no work range,
  1920×1080 + 720p, scrubber range reset, and that `loadProjectFile(recentOpenB)`
  (the previously open project file) contains workOut 1.5 — proving the autosave
  preserved the work. Then setWorkOut(2.5), press Ctrl+N, assert the same reset
  and that the UNNAMED autosave (`unnamedProjectAutosavePath()`) now holds
  workOut 2.5.
- Gotcha: after the first New, `_projectPath` is empty, so the second autosave
  goes to the unnamed autosave, NOT the recent project file — verify each with
  the correct path.
- Commands: same editor-smoke compile/run as the History popout section below;
  `dub test --compiler=dmd --force`; app link check via temp output.

## App-state output/export + undo/redo history in the project file (2026-08-18)

- `auroracut.util`:
  - `applicationExportDirectory()` → `%LOCALAPPDATA%\Aurora Cut\Exports`
    (Windows; per-OS analogues for OSX/Linux), created on demand, with a
    `setApplicationExportDirectoryForTesting` override. This is the default
    folder for the Export MP4/MP3 dialog.
  - `projectAutosaveDirectory()` moved from `%TEMP%\Aurora Cut\Autosaves` to
    `%LOCALAPPDATA%\Aurora Cut\Autosaves` (temp is volatile), with a
    `setProjectAutosaveDirectoryForTesting` override.
- `FileDialogController.showSave(ext, suggested, accepted, startPath = "")`
  opens at `startPath` (validated directory; falls back to CWD). `showOpenProject`
  shortcut button is now `open-project-autosaves` ("AppData autosaves").
- **Undo/redo history lives in the project file** (user: "maybe the undo redo
  history should be part of project file?"). This replaced the earlier
  app-state `History/` file approach (`historystore.d` was deleted):
  - `project.d`: `ProjectData` gained `undo`/`redo`; `saveProjectFile(..., undo,
    redo)` (trailing optional params) writes `"history": { "undo": [...],
    "redo": [...] }`; `loadProjectFile` parses it and drops snapshots whose
    media clips reference assets outside the loaded asset array
    (`validHistorySnapshots`). Old v2 files without history load empty stacks.
    `TimelineSnapshot` lives in `model.d`; `snapshotToJson`/`snapshotFromJson`
    live in `project.d`.
  - `editor.d`: `writeProject` and `autoSaveProjectOnExit` pass the live
    `_undo`/`_redo`; `openProject` restores them from `ProjectData` after the
    project loads. History durability == project save frequency (autosave on
    exit covers clean closes).
  - Because the unnamed autosave is a real `.auroracut` file in
    `%LOCALAPPDATA%\Aurora Cut\Autosaves`, the unnamed project's history is
    stored in appdata too — satisfying the original "history in appdata"
    request for unnamed work while named projects keep history beside their own
    data.
- How it is verified (headless `tests/editor_smoke.d`):
  - After a clip exists, click `export-mp4` and assert `file-dialog-path`
    equals `applicationExportDirectory()`; Esc dismisses it.
  - At the end: `saveProjectForTesting(recentOpenB)`, then
    `loadProjectFile(recentOpenB)` and assert `undo.length ==
    editor.undoCountForTesting()` and same for redo; then
    `openProjectForTesting(recentOpenB)` and assert both counts were restored
    and the Undo button is enabled.
  - Test setup redirects recent projects, autosaves, and exports to temp dirs
    (each created with `mkdirRecurse` so dialog `navigate` finds them) and
    cleans them up.
- `project.d` unittest covers: history round-trip through a real file
  (selection/playhead/work-range preserved), out-of-range snapshot dropping,
  and legacy files without history.
- Test gotchas:
  - The autosave/export test dirs must EXIST before the dialog navigates;
    `navigate` rejects a missing directory and leaves the path field at the CWD.
  - `tempDir()` returns the 8.3 short path (`C:\Users\WINDOW~2\...`), so paths
    compared against dialog-normalized values must be normalized the same way
    (`absoluteNormalized`); the dialog's `buildNormalizedPath` does not expand
    short names either, so they match.
  - `member()` in project.d returns `const(JSONValue)*`; pass `*ptr` when
    feeding it back into `member()`.
  - editor-smoke has playback-timing assertions that are flaky when the 4-core
    host is loaded (a concurrent build/agent). If it fails on
    "Direct video decoder never reached the end of its range", re-run; it is
    not related to history persistence.
- Pre-existing test fixes bundled here (both were failing on the untouched
  baseline after commit `ea3a12d`, which restricts hardware decode to known
  H.264/HEVC): `tests/export_smoke.d` and `tests/gpu_decode_args_smoke.d` now
  declare `videoCodec = "h264"` on the accelerated-preview clips;
  `tests/recompress_smoke.d` builds an absolute output path (the job reports an
  absolute path, the test compared a relative one).

## History step toggling (right-click context menu, 2026-08-18)

- User: "add right click context menu for items so we could toggle history item
  on and off... item of history could take affect or not depending on if they
  are on or off."
- Vendored `ListView` changes in
  `vendor/aurora-d-0.4.5/source/aurora/widgets/listview.d`: new generic
  `onContextMenuRequested(int index, Point globalPosition)` fired on
  right-click in `onMouseDown`; new `ListItem.dimmed` flag that mutes the row
  (uses `palette.disabled`) but stays clickable, and keyboard navigation skips
  dimmed rows. (`disabled` stays non-clickable; `dimmed` is used when the click
  must still be acted on.)
- History popup (`source/auroracut/editor.d`):
  - `_historyActionEnabled` parallels `_historyActionLabels`; `refreshHistoryList`
    preserves flags by index (a committed edit appends an enabled step; the
    discarded redo tail drops its flags). Flags are session-only, reset with
    history on New/Open/Clear, and are kept in sync even while the popup is
    closed so Undo/Redo always know which steps to skip.
  - `applyHistoryView` dims disabled rows (`row.dimmed = true`) with secondary
    "Disabled — right-click to enable" (current row: "You are here — disabled")
    and the hint now says "right-click a step to toggle it".
  - Disabled steps are NEVER landed on. Undo/Redo are refactored into physical
    `stepUndo`/`stepRedo` helpers plus `nearestEnabledPosition(from, direction)`;
    `undo()`/`redo()` (toolbar + Ctrl+Z/Y) compute the nearest enabled state and
    physically step to it, and `jumpToHistory` snaps the clicked row the same way
    and calls `updateHistoryButtons()` after the jump.
  - Toggling is an IMMEDIATE action (the user's key requirement — "should act
    like the Undo/Redo buttons"): `showHistoryContextMenu`'s `Enabled` check
    calls the shared `navigateTo(rawTarget)` (extracted from `jumpToHistory`).
    Disabling a step navigates right away to the nearest enabled step before it
    (reverting that step and any steps after it); re-enabling navigates forward
    to `lastEnabledPosition()` (the furthest enabled step) to restore the full
    state. `Enable all steps` navigates to `lastEnabledPosition()`;
    `Disable all steps` navigates to Initial state (row 0).
  - `showHistoryContextMenu` builds the menu (`Enabled` check + `Enable all
    steps`/`Disable all steps`) and opens it via `showHistoryContextMenuPopup`
    — a copy of `showContextMenu` WITHOUT `dismissTransientPopups`, because that
    call would dismiss the History popup itself (it is a root-level
    `TransientPopup`). This is the key gotcha for menus anchored inside popups.
- Regression (`tests/editor_smoke.d`, end of the history block): right-click
  row 2, assert the menu (`Enabled` checked + bulk commands), click `Enabled`,
  and assert the toggle acts IMMEDIATELY: the clip is gone, the highlight lands
  on row 1 (`selectedIndex == setRangeRow`), row 2 is dimmed with the disabled
  secondary, and the History popup is still open
  (`findById(editor, "history-list") !is null`). Then press Ctrl+Y/Ctrl+Z and
  assert Undo/Redo skip the disabled step (clip back on Place clip, then removed
  again on Set export range out, row 2 stays dimmed), right-click again (menu now
  shows `Enabled` UNCHECKED — assert `!`checked), click it and assert the full
  state restores (clip back on Place clip, row 2 no longer dimmed), assert clicks
  on rows 2 then 3 jump normally, then `Disable all steps` (timeline returns to
  Initial, `selectedIndex == 0`, all rows dimmed) and `Enable all steps`
  (timeline restored, no rows dimmed), Esc to close.
- Note: clicking a TOOLBAR undo/redo button while the popup is open dismisses
  the popup (pointer outside the panel), so the test verifies Undo/Redo skip via
  Ctrl+Z/Ctrl+Y to keep the popup open and inspect its view.
- Flakiness (pre-existing, unrelated to this feature): `tests/editor_smoke.d`
  intermittently fails the real-decode playback test ("Direct video decoder
  never reached the end of its range", a simulated-clock vs real-decode
  deadline) and rarely crashes with an access violation and no output. Observed
  ~2/34 runs while validating; the history block passed every run; a `-g` build
  passed 6/6; LocalDumps/WER captured nothing. Load/timing dependent.
- Gotcha: editing the UTF-8 test file with PowerShell `Get-Content`/`Set-Content`
  (ANSI default) mangles every non-ASCII char (`▶` → `â–¶` mojibake). Recover
  from git and re-apply only the intended edits; never round-trip the file
  through PS without `-Encoding UTF8`.

## Clicked-button focus ring (2026-08-18)

- User: "unclicked buttons turn half blue... due to being focused after
  unclicking button like snap on button." Root cause: `Button.onMouseDown` calls
  `requestFocus()`, and `onPaint` drew a blue accent ring for any focused
  widget. Clicking the gray "Snap Off" toggle left it focused with a blue
  outline. Same pattern existed on `ListView` (which requests focus on row
  click).
- Fix (standard Windows convention) in
  `vendor/aurora-d-0.4.5/source/aurora/widgets/button.d` and `listview.d`: a
  `_focusedByPointer` flag is set in `onMouseDown` and cleared in
  `onFocusChanged(false)`; the focus ring is drawn only when
  `focused() && !_focusedByPointer`. So mouse clicks never show the ring,
  keyboard/Tab focus (`cycleFocus` in window.d) still does, and the widget keeps
  focus after the click.
- Regression (in `tests/editor_smoke.d`, after the snap accent block): click the
  Snap button off (gray + pointer-focused), sample the pixel on the ring line
  (button local y+2) and the plain fill below it (y+4), assert the two are
  identical and that the ring-line pixel is not blue (`(pixel & 0xff) >
  ((pixel >> 16) & 0xff) + 40`), then assert the button still `focused()`, then
  click it back on. Pixel helper: move pointer to (0,0), paint, sample
  `surface.pixels()[y * width + x]` at `displayScale().logicalToPhysical(...)`.
- Unrelated: an in-progress external refactor (persistent undo/redo store
  `source/auroracut/historystore.d`, `TimelineSnapshot` moved from editor.d to
  `model.d`) had broken the build and the unittest suite. Fixed: add
  `TimelineSnapshot` to editor.d's `auroracut.model` import; add `mkdirRecurse`
  to historystore.d's `std.file` import; replace historystore.d's self-referential
  unittest dir initializer (`&directory` inside its own declaration) with a
  static counter; give `workIn`/`workOut` explicit `0.0` defaults in `model.d`
  `TimelineSnapshot` (they defaulted to `double.init` = NaN, and `std.json`
  throws "Cannot encode NaN" in `saveHistoryStacks` — visible in `aurora-cut.log`
  since the catch calls `appLog`). `dub test` now passes 34 modules.
- Commands: same editor-smoke build/run as the History popout section above;
  `dub test --compiler=dmd --force`; app link check via temp output
  (`aurora-cut-check.exe`) because a running `aurora-cut.exe` locks the target.

## Undo/Redo history popout (2026-08-18)

- New toolbar `History ▾` button (`id="history"`) opens a `PopupOverlay`
  (`history-popup`, 440x400) beside Undo/Redo. The `ListView` (`history-list`)
  is a standard flat numbered list: an `Initial state` row, then each timeline
  action oldest-first (`1. …`, `2. …`, `…`). The current state's row is
  highlighted ("You are here"); past rows read "Click to undo N steps" and
  future rows "Click to redo N steps", with direction icons (refresh = undo,
  clock = current, chevron = redo).
- The list is FROZEN for the popup session: `jumpToHistory` loops
  `undo()`/`redo()` the required steps but only moves the highlighted row and
  re-styles icons/step text — the row order and positions never change. The
  list is rebuilt only by `commitHistory`/`clearHistory` (a new edit appends a
  row, discarding undone future rows, standard behavior). Toolbar/keyboard
  Undo/Redo call `moveHistoryHighlight(∓1)` instead of rebuilding, so rows never
  jump around. `updateHistoryButtons` no longer rebuilds the list; the rebuild
  is explicit in commit/clear, and highlight moves are explicit in undo/redo.
- Listing reworks: v1 flat+ambiguous → v2 section headers (rebuilt on every
  click, reordering rows) → v3 standard flat numbered list frozen for the
  session. The user reported v1/v2 as confusing, overlapping, and reordering on
  click.
- How it is verified (headless, `tests/editor_smoke.d`, after the global
  Undo/Redo block): open the popup, assert the Initial state row, numbered
  oldest-first actions, highlighted current row, and exact step counts; snapshot
  the row texts, click a past row to undo to the empty timeline, assert the row
  texts are IDENTICAL (no reordering) and the future row now reads "Click to
  redo 1 step"; click it to redo back, assert row texts are again identical, and
  press Esc to confirm dismissal (`findById(editor, "history-list") is null`).
  Row lookups use `rowIndexForText` / `rowIndexContaining` helpers.
- Gotchas discovered (both fixed in
  `vendor/aurora-d-0.4.5/source/aurora/widgets/listview.d`):
  (1) `_scrollOffset` could stay above `maxScroll()` after a resize, scrolling
  every row out of view (blank popup); `synchronizeScrollbar()` now re-clamps.
  Symptom in a test: `scrollOffset=136` while `maxScroll=0` and
  `contentHeight=136`, making `mediaRowPoint` click 136 px too high.
  (2) two-line rows painted the secondary line 8 px past a 34 px row, overlapping
  the next row; the paint now splits the row height between the two lines.
  Use a row height of at least 44 for two-line rows so both lines are readable.
- Compile: `dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source
  tests\editor_smoke.d -of=build\headless-smoke\editor-smoke.exe
  -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32
  -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet`
- Run: `set AURORA_RENDERER=software&& set SDL_AUDIODRIVER=dummy&&
  build\headless-smoke\editor-smoke.exe build\headless-smoke\media\base-av.mp4
  build\headless-smoke\media\overlay.mp4 build\headless-smoke\media\audio.mp3`
- Note: when a live `aurora-cut.exe` is running, `dub build` cannot overwrite it
  ("Access is denied"); verify the app links via a temp output instead, e.g.
  `dmd -i -Isource -Ivendor\aurora-d-0.4.5\source source\app.d
  -of=%TEMP%\aurora-cut-check.exe -L/SUBSYSTEM:WINDOWS -L/ENTRY:mainCRTStartup
  -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32
  -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet`.

## Aurora Notepad visual review (2026-08-15)

- Launched the current release build and captured `aurora-notepad/build/visual-review.ppm` (converted to PNG for inspection).
- Visual review passed: small titlebar icon, aligned File/Edit/Format/View/Help menu bar, 1 px edge border, white borderless editor, and gray status bar with no clipping or overlap.
- Opened File through the headless interaction path and inspected `notepad-smoke-filemenu.png`: New/Open/Save/Save As/Exit rows, shortcuts, icons, hover treatment, and dropdown bounds render correctly.
- The original 814x820 icon rendered with hard gray/blue edge blocks at 16 px. Fully transparent source pixels contain black RGB, and Aurora's straight-alpha linear sampling exposed that during the extreme reduction.
- Added `aurora-notepad-title.png`, a 64x64 Lanczos-prefiltered derivative generated from `aurora-notepad.png`; the titlebar now uses it while preserving the original source asset. The enlarged crop shows smoother rings and a clean right edge.
- The remaining gray strip was confirmed in the source artwork and the 64px derivative. The title derivative is now a purpose-built flat notebook variant with that external outline/shadow removed; `build/icon-flat-crop.png` shows the clean result. Details are recorded in `aurora-notepad/ICON-RENDERING-IMPROVEMENT.txt`.
- Shadow cannot appear in the client-area screenshot; the DPI-aware live probe separately confirmed the 1 px border plus DWM shadow gradient on all four sides. Left/top are intentionally subtler than right/bottom, matching Windows 10 DWM behavior.

## Aurora Notepad — custom downstream titlebar (2026-08-15)

New downstream app `aurora-notepad/`. Frameless window whose top strip is the
custom `NotepadTitleBar` (`source/auroranotepad/titlebar.d`), a subclass of the
vendored `TitleBar` that owns all window chrome: styling, owner-driven
drag/restore-on-drag, work-area maximize via `setWindowBounds`, the system
menu, and aero drag-snap (preview via `onSnapPreview`, applied on release).

Layout: slim 28 px titlebar → 30 px classic Win10 **menu bar**
(`File Edit Format View Help`, flat text items, dropdowns via
`showContextMenuBelow`, 1 px bottom hairline) → borderless editor
(`setShowBorder(false)` + `setFocusDecoration(false)`,
`setPixelSizeOverride(14)` for Consolas 11 pt) → 28 px status band (Panel,
`0xf0f0f0` light / `0x2b2b2b` dark) with a 1 px `0xd6d6d6` top hairline
(Separator added after the band so it paints over the top edge) and 8 px
left-padded text.

Themes: full Win10 palette — accent `0x0078d4`, danger `0xe81123` (close
hover), neutral hover grays, `cornerRadius = 3`, `controlHeight = 32`,
`fontScale = TextScale.caption` (13 px UI text). Titlebar colors live in
`NotepadTitleBar.setDarkMode(bool)`: white / `0x202020`, Win10 red close,
neutral caption-button hover.

- Build: `cd aurora-notepad && dub build --build=release`.
- Headless smoke:
  `dmd -version=AuroraHeadless -i -Isource -I..\vendor\aurora-d-0.4.5\source tests\headless_smoke.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\headless-smoke.exe`
  then run `build\headless-smoke.exe`. It drives the real UiTestDriver path:
  caption callbacks, work-area maximize (set `setTestWorkArea` then click
  maximize → `lastWindowBounds` == work area), double-click maximize toggle,
  left-edge drag-snap (set `setTestScreenPointerPosition` then drag; release
  applies 960x1040), preview show/hide + input transparency (disabled overlay
  must never block a caption click), document-title dirty/clean updates, the
  22 px bar, toolbar presence, and editor focus. The snap only evaluates on
  the move AFTER the drag threshold (a second moveTo after crossing), so a
  snap test needs two moves post-mouseDown. Drag presses must target the
  middle row of the slim bar (e.g. y=14 for the 28 px bar), not its bottom
  edge.
- No-focus-border pixel check: the smoke saves `notepad-smoke-focused.ppm`
  while the editor is focused; the editor top edge (logical y=66 now, 28 px
  bar + 38 px toolbar) must be pure white `(255,255,255)` with zero
  accent-blue `(36,107,253)` pixels.
- Win10 toolbar checks: `notepad-smoke-toolbar-hover.ppm` is saved while the
  pointer hovers the first menu item — the menu bar is white with a `0xd6d6d6`
  hairline and the hovered item shows the `0xe5e5e5` highlight.
  `notepad-smoke-filemenu.ppm` is saved while the File dropdown is open — the
  white menu panel shows dark labels (New/Open/Save/Save As/Exit) with accent
  `0x0078d4` icons and a `0xe5e5e5` hover.
- Window shadow (upstream, `aurora.platform.win32`): the class carries
  `CS_DROPSHADOW` (DWM SysShadow appears), frameless windows without an
  explicit position are centered on the monitor work area (fixes
  `CW_USEDEFAULT`→(0,0) clipping the left/top shadow), and
  `DwmExtendFrameIntoClientArea({1,1,1,1})` gives the full DWM frame + drop
  shadow. `GuiWindow.setFrameDark(bool)` re-applies light/dark frame colors on
  theme toggle (the DWMWA border/caption/text attributes are Win11-only and
  fail silently on Win10, so the system theme decides there).
- Window border: the notepad draws its own 1 px `theme.border` (`WindowBorder`
  overlay, disabled/input-transparent, painted last). Headless pixel check:
  the saved `notepad-smoke.ppm` must have `0xd6d6d6` (214,214,214) at
  (0,midY), (w-1,midY), (midX,0), (midX,h-1).
- DPI-aware live probe (how to verify the real window): the probe process must
  call `SetProcessDpiAwarenessContext(-4)` FIRST, otherwise `GetWindowRect`
  returns virtualized logical pixels while `ImageGrab` reads physical pixels
  and every edge read is garbage. Minimize unrelated windows (restore after),
  `SetForegroundWindow` the notepad, then sample a strip crossing each edge:
  expect shadow gradient → `(214,214,214)` border → white content.
- Live screenshot: `aurora-notepad.exe --screenshot build\notepad-live.ppm`
  (PPM; convert to PNG with PIL to view; the real window is physical DPI, so
  at 125% a 1080x680 logical window screenshots as 1350x850).
- Launch: `RUN-WINDOWS.bat` (automatic renderer) / `RUN-WINDOWS-SOFTWARE.bat`.
- Registration: `scripts/version.py`, `scripts/build-portable-windows.py`,
  `.github/workflows/portable-windows.yml` now build/ship `aurora-notepad.exe`.

- Icon sizes: upstream `TitleBar.setIconSize(int)` (notepad uses 16) and
  `Button.setIconSize(int)` (default lowered 22 → 18). Button size is
  text-measured and never follows the icon size. To pixel-verify a button
  icon, render a `Button("Open", IconKind.open)` and check the icon row
  spans exactly the configured size; the button's preferred width stays
  `max(controlHeight, text + horizontalChrome)`.

## Aurora Stream: real composed-window capture replacement (2026-08-15)

- **v0.66.1 is rejected for VLC/window capture.** The user's release screenshot
  still showed VLC's malformed Qt/GDI paint surface (black video plus a white
  unpainted region). The previous visible-desktop crop was not a dependable
  per-window capture implementation and must not be treated as a passed release.
- Root cause in the live canvas: selecting Game capture did not create a
  `GameCaptureSession`; preview still called `GetDC(hwnd)`. The current D3D11
  hook also connects to VLC 3.0.20 but receives no Present frames from any of
  its top-level/Direct3D child HWNDs. VLC can therefore use neither PrintWindow,
  HWND GDI, nor Aurora's game hook.
- Standard window capture now uses FFmpeg's `gfxcapture` source with the selected
  HWND, cursor/border disabled, and an explicit D3D11-to-BGRA download. This is
  Windows Graphics Capture, so VLC's Direct3D video plane, menu, progress bar,
  and controls arrive as one compositor-owned frame even while the target is
  covered. VLC selection forcibly disables PrintWindow and Game capture.
- The live canvas uses the same HWND source in a persistent low-resolution
  preview process. A 2.5-second pipe timeout prevents shutdown deadlocks when a
  target is minimized; a failed source clears the canvas instead of retaining a
  stale desktop/window frame, logs the reason, and keeps the failure visible in
  the status panel.
- Exact background-only VLC proof: direct compositor capture returned 60/60
  complete 1920x876 frames. The isolated Aurora UI test then selected a separate
  non-activating VLC process and deliberately loaded `gameCaptureMode=true`.
  Aurora persisted both incompatible modes as false, kept the same HWND, and
  displayed the complete SMPTE/VLC frame. Repeated simultaneous direct-frame
  comparisons differed by only 1.916-2.136 mean RGB levels (0-255). A stricter
  rerun sampled the OS foreground owner throughout and proved Aurora was never
  activated. A separate minimized-VLC run showed a blank canvas plus the explicit
  timeout instead of stale pixels and shut down cleanly.
- The final POSIX-thread FFmpeg artifact from Actions run `31870550684`
  (artifact `9243361794`, ZIP SHA-256
  `95344aa73403d09608221a030efec7452e88b47c9427b6fb902184dbc341feb6`)
  passed the real local Windows HWND probe: 780x401 with 104,260 red, green,
  and blue pixels each, foreground unchanged. It also captured the separate
  VLC test window at 60/60 frames and encoded a five-second MP4 containing
  exactly 300 H.264 frames at 60/1 plus 48 kHz stereo AAC; both streams and the
  container reported exactly 5.000 seconds. The decoded recording frame was
  86.4% non-black and covered the full 0-255 range on all RGB channels. The
  final 300-frame run used Aurora's exact `hwdownload,format=bgra`, FPS,
  timestamp, scale, pad, and YUV420 conversion graph rather than a simplified
  raw-source test.
- The final isolated Aurora/VLC comparisons using that artifact measured
  2.076-2.170 mean RGB error. Aurora remained at the bottom of the Z order and
  never owned the foreground window. The user's existing VLC was left minimized
  and untouched; its isolated run showed the explicit timeout/blank canvas,
  never malformed or stale window pixels.
- GitHub's hosted Windows VM cannot create FFmpeg's required hardware D3D11
  video device. The runtime gate now distinguishes that host prerequisite from
  a broken artifact: it may explicitly report `skipped` only when an independent
  D3D11 hardware probe fails and FFmpeg reports device creation failure. On a
  machine with D3D11, any capture/thread/pixel failure remains fatal. The local
  hardware-backed run is therefore still required and passed.
- Single-exe extraction no longer trusts file size as cache identity. Embedded
  FFmpeg/FFprobe now extract into a content-addressed directory and every cached
  file is byte-verified before use, matching the already content-addressed game
  hook. A same-size older executable therefore cannot mask a new release build;
  extraction/verification failure leaves bundled FFmpeg disabled instead of
  silently adding a bad cache directory to PATH.
- Feature-branch portable Actions run `31870945690` passed the complete DMD,
  D-only hook, GUI-subsystem, static-runtime, WGC runtime-gate, and single-exe
  build workflow. Artifact `9243407740` was downloaded with its exact GitHub
  ZIP SHA-256
  `af5d29f252f9e38c3ea9b5e3c9cadb4d11bbfc62a821ad3913e7805f85732c29`.
  Its packaged `aurora-stream.exe` passed version output, synthetic RTP audio
  transport, real audio-endpoint JSON, and the isolated VLC UI test while no
  external FFmpeg was present in the app PATH. The previously absent
  content-addressed cache was created, and both extracted tools were byte-for-byte
  identical to the validated minimal-FFmpeg artifact (`ffmpeg.exe` SHA-256
  `bf856221eae66d8abb106dcfb64e07c406e0154ecd69cfc9f1f282984f88f15c`,
  `ffprobe.exe` SHA-256
  `a6f15432ea983d680566754b879d3d71478ba9cdb3776dd0f8c0458ea332db6e`).
  The packaged preview measured 2.121 mean RGB error with foreground ownership
  unchanged; its separate minimized-window test also passed the blank/timeout
  contract without activation.
- The final main-branch gates passed before tagging. Minimal-FFmpeg run
  `31871356491` produced artifact `9243597409` (ZIP SHA-256
  `56ca305a168977504019ead5898b2c79b6a403f1df7225c2def43b3e8e1ef21b`).
  Its freshly rebuilt binaries passed the real 780x401 D3D11/WGC color probe,
  then captured VLC through Aurora's exact production graph into 300/300 H.264
  frames at 60/1 plus 48 kHz stereo AAC, with both streams and the container at
  exactly 5.000 seconds. Main portable run `31871356484` produced artifact
  `9243518191` (ZIP SHA-256
  `1e0576eafc95fa0dc0371df9cdc72fe96a9944380187fb2c6f761672b89981e3`).
  Its `0.66.2` single EXE passed synthetic audio transport and bundled VLC
  preview with 2.063 mean RGB error, foreground unchanged, and no activation.
- Release tag workflows also passed: portable/publish run `31871848599` and
  clean minimal-FFmpeg run `31871848613`. The public release is
  `v0.66.2`; asset `aurora-stream-v0.66.2.exe` is 30,425,004 bytes with
  SHA-256 `d573bda61176166a1cd448aba805d3c6b3f8d64027bb16929e75c0dac4d5f152`.
  A stale repository-wide version initially gave this already-correct 0.66.2
  binary a 0.66.1 filename. The correctly named, digest-identical asset was
  uploaded and verified before the misleading entry was removed; the workflow
  now reads `aurora-stream/VERSION.txt`, and follow-up main run `31871987081`
  passed.
- The binary was downloaded again through its final public URL. It reported
  `Aurora Stream 0.66.2`, passed the static-CRT check, synthetic RTP transport,
  real endpoint JSON, and byte-identical bundled FFmpeg extraction. Its live
  VLC comparison measured 2.386 mean RGB error while foreground ownership stayed
  unchanged and Aurora was never activated. A separate public-binary minimized
  test passed the explicit blank/timeout contract under the same foreground
  invariants. Authenticated YouTube streaming remains the user's manual gate.
- The production pacing diagnostic passed three complete repetitions, each with
  three 15-second phases. Every phase encoded 900 H.264 frames at 1920x1080 and
  60/1, with zero duplicated/dropped progress frames, no timestamp interval above
  17 ms, no queue warnings, and 705 contiguous AAC packets covering 15.039
  seconds. The real WASAPI phases captured 1,542-1,604 packets and
  740,160-769,920 frames, with zero discontinuities, overflows, stale frames,
  pacing skips, or send failures. The final repetition inserted one 10 ms silent
  startup block before real endpoint samples arrived; the earlier valid run
  inserted none.
- D-only game capture remains separate and passed the minimized background
  BGRA8, RGBA8, and RGB10A2 hook/session matrix after the window-capture change.
  The harness still performs two unload/reinject rounds plus the production
  `GameCaptureSession`; all accepted frames were non-black, changing, and
  color-correct with zero sequence gaps.
- The packaged FFmpeg is pinned to commit
  `c48230eb86ff02246f6a14fa1475a0d9398363b4`, the verified revision containing
  the HWND `gfxcapture` source. The feature-branch portable payload gate passed;
  the versioned main/tag workflows and published-asset retest remain mandatory
  release gates. No authenticated YouTube stream or foreground/fullscreen test
  has been run.

## Aurora Stream: VLC composed-window correction (2026-08-14)

> Historical failed approach: this section records the visible-desktop crop
> shipped in v0.66.1. The 2026-08-15 release screenshot invalidated it.

- User's 0.66.0 screenshot proved that the supposed VLC "screen" fallback still
  used the HWND GDI surface: VLC chrome painted, the Direct3D video stayed black,
  and an unpainted child/UI area stayed white.
- VLC selection now routes preview and broadcast to its visible client rectangle
  on the composed desktop. The rectangle is clipped to the virtual screen (the
  observed VLC restore geometry was x=-4 and extended below 1080p), then captured
  through a Desktop Duplication region or cropped `gdigrab desktop` fallback.
- The headless clipped-GDI probe returned the exact 1532×710 BGRA byte count
  (4,350,880) with 31.8% non-black pixels. D unittests exercise VLC selection,
  DDA/GDI argument construction, black-frame probe rejection, label matching,
  geometry failures, and the preview's visible-screen-DC branch.
- The bundled 0.66.0 FFmpeg exposed the packaging bug: `ddagrab` was configured
  as an input device even though FFmpeg implements it as a source filter. The
  build flag, Actions inventory assertion, and portable payload gate are fixed.
- `dub test --compiler=dmd --force` passes all 45 modules; forced x64 debug
  `application` and `notitlebar` builds pass. Direct/FIFO RTP+SDP, transport,
  output isolation, synthetic audio, GUI/static-CRT policies, and both 720-frame
  loaded A/V phases pass. The rebuilt minimized BGRA/RGBA/RGB10 hook matrix also
  passes with zero production drops/gaps.
- Minimal-FFmpeg Actions run #16 (`31833093268`) compiled `vsrc_ddagrab.o`,
  passed the explicit inventory, and produced artifact SHA-256
  `17c51737afb30eec18b4d4dd20498183672be9b16636740cf3cce56f1a3cdf55`.
  Portable Windows run #39 (`31833093342`), attempt 2, accepted that new
  payload, rebuilt the D-only hook and all single-exe applications, passed the
  static-CRT checks, and produced artifact SHA-256
  `67bffc2a7e926cfec23ad9ca6c6ffa150716f1564779497d99989c468bbd9e53`.
- Tag workflow run #40 (`31833961645`) passed from commit `8edd708`, including
  the FFmpeg inventory, optimized D-only hook build, and all portable PE checks,
  then published five v0.66.1 assets. The downloaded 29,929,900-byte
  `aurora-stream-v0.66.1.exe` matched SHA-256
  `9f6d26c119029536c4d697f17f91d41d1bdebe88933cc3933dfbef8911f09602`;
  `--version` and `--audio-bridge-session-test --synthetic` both exited zero.
  The synthetic release-binary run sent 152 RTP packets with no overflow,
  pacing skips, discontinuities, or send failures.

## Aurora Stream: D3D11 game-capture release integration (2026-08-14)

- `dub test --compiler=dmd --force` passed all 45 modules. Forced x64 debug
  builds passed for both `application` and `notitlebar`.
- The optimized standalone D-only hook built with `-betterC`,
  `/NODEFAULTLIB`, and `/ENTRY:gamecaphookEntry`; no C compiler is involved.
- The final background-only 1920×1080 harness matrix passed BGRA8, RGBA8, and
  RGB10A2. Each format completed two injection → capture → restore → self-unload
  rounds and a third round through the production `GameCaptureSession`. Manual
  rounds delivered 236–237 non-black/color-correct frames in four seconds; the
  production reader received 238–239. Final production metrics had zero hook
  drops and zero sequence gaps for every format.
- The 72-byte v2 protocol covers ready/frame/error messages, QPC timestamps,
  source DXGI format, cumulative drops, sequence validation, and bounded shared
  BGRA8 slots. The named pipe carries headers only. Settings cover persisted mutually-exclusive game
  and PrintWindow modes; broadcaster tests require raw BGRA stdin.
- Present submits reusable asynchronous GPU copies and performs only a
  nonblocking readback/CPU-slot handoff. Channel conversion and named-pipe I/O
  run on the hook worker. Both hook and host use bounded latest-frame queues;
  Aurora duplicates the held image on exact 60 FPS cadence for A/V stability.
- The portable staging helper passed. A verified minimal-FFmpeg Actions artifact
  (SHA-256 matched GitHub's artifact digest) allowed the complete local
  `--single-exe` workflow to reach the final link. This DMD installation lacks
  `libcmt.lib`. Official Windows Actions run #37 (`31830461788`, commit
  `081ece8`) supplied the release toolchain, built the optimized D-only hook and
  all single-exe applications, passed every PE static-runtime check, and
  produced the 27.4 MB `aurora-windows-portable` artifact (SHA-256
  `b2c53367506888071127fa1ef89aaea0bf0eb00add4f0bf5f55b2b827abd2730`).
- No authenticated YouTube stream or fullscreen foreground test was run.

## Standard-flow verification and non-interference rule (2026-08-14)

- Headless checks passed: `verify-audio-transport.py`, `verify-rtp-sdp.py`
  (direct + FIFO FLV), `verify-network-output-isolation.py`,
  `--audio-bridge-session-test --synthetic`, endpoint JSON parsing, and
  `dub test` (44 modules).
- `run-quality-diagnostic.py --loaded-audio` passed both phases: 720 frames
  each, final speeds 1.020x and 0.996x, no queue/RTP/pacing/send failures.
- Actual VLC validation was performed without fullscreen: the existing VLC
  HWND playing a real video was captured through the normalized gdigrab chain;
  1920×1080, 60/1, 300 frames, exactly 5.000 seconds, and no timestamp
  warnings. The raw unnormalized probe produced repeated DTS warnings; the
  production `fps/settb/setpts/scale/pad` chain removed them.
- GUI diagnostic stdout was fixed to preserve inherited subprocess pipes;
  endpoint JSON now parses and the loaded-audio diagnostic completes normally.
- The full visual harness was stopped because it opens a fullscreen test card
  and interferes with normal desktop use. It is not accepted as passed. Future
  autonomous validation must be headless or explicitly backgrounded/minimized;
  no fullscreen interactive test may be launched without user approval.

## Aurora Stream: improved always-on activity logging (2026-08-14)

User request: "can we improve logging so that final release of aurora stream
would show exactly what errors and what problems happen and what actions are
taken, so we know exactly how to resolve things once problems appear or target
things faster and resolve faster."

Implemented: the always-on `aurora-stream-activity.log` (beside the exe, same
folder as `aurora-stream-startup.log`) is now the single session-spanning
record of what happened and what the app did about it. Every line carries a
severity tag:

- `[INFO]` normal lifecycle: version at startup, encoder/capture selection,
  settings load/save, stream start (with destinations + encoder + capture),
  FFmpeg launch attempts, update available, audio device inventory.
- `[WARNING]` recoverable problems: D3D11-direct-to-NVENC probe fail (CPU path
  fallback), audio scan errors, UDP -10048 bind race, FFmpeg warning lines,
  silent audio endpoint, stale/minimized capture-window fallback.
- `[ERROR]` failures with the exact reason: stream start rejected, FFmpeg
  startup timeout, live-output stall, desktop-capture stall, captured window
  closed or minimized mid-stream, Desktop Duplication output lost, audio-helper
  failure, bind-race give-up, unexpected FFmpeg exit.
- `[ACTION]` what the app did in response: FFmpeg terminated, capture relaunch
  (recovery N of 3), FFmpeg launch retry, settings fallback to defaults,
  capture reset to desktop, updater launched, update install.

Where the lines come from:
- `BroadcastWorker` (`broadcast.d`) now takes the `ActivityLog` and mirrors its
  failure reasons + actions into it. Before, those details only went to
  `aurora-stream-startup.log`, which is reset on every stream start.
- `StreamRoot` (`root.d`) logs startup/encoder/capture/settings/audio/update/
  browser/tray events. The Settings menu gained a "View activity log" entry
  that opens the file with the OS default handler (`openLocalFile` in
  `browser.d`).
- User actions are logged as `[INFO]`: capture source, source/YouTube quality,
  YouTube bitrate, Twitch/YouTube enable toggles, window-content capture, live
  source preview, streaming-server fields, minimize-to-tray / close-to-tray,
  desktop audio / microphone selection (friendly name only), audio refresh,
  browser quick-link opens, browser choice, settings menu opens. **Stream keys
  and server URLs are NEVER logged** — text fields record only the
  populated/cleared transition (`logFieldPopulatedChange` in `root.d`), never
  the content.
- `ActivityLog` (`activitylog.d`) gained `info/warning/error/action` helpers
  (tagged `note` lines); app-authored text is ASCII, file is UTF-8.
- Environment + settings block at startup (`aurorastream/environment.d`):
  `[INFO] OS: <name> <edition> (build NNNNN) (arch).`, `[INFO] CPU: <model>
  (<N> logical processors).`, `[INFO] RAM: <GB>.`, `[INFO] GPU: <adapter>
  (\\.\DISPLAYn). Display <W>x<H> @<Hz>.`, `[INFO] FFmpeg: <version line>.`,
  then `[INFO] Settings: ...` lines covering destinations, encoder, capture,
  qualities/bitrate, audio devices, window-content capture, live preview,
  tray options, browser, config mode, and stream-key PRESENCE only. OS/CPU come
  from the registry (`RegGetValueW` on `HKLM`, requires `advapi32` in
  `dub.json` libs); GPU/display from `EnumDisplayDevicesW`/
  `EnumDisplaySettingsW`; RAM from `GlobalMemoryStatusEx`. Keys and server URLs
  are never written (a unittest asserts the report never contains them).

Verify (no stream keys needed):
1. `dub test` in `aurora-stream` (43 modules pass; new unittest asserts the
   four severity helpers write tagged lines).
2. `dub build` (application) and `dub build --config=notitlebar` both link.
3. Launch `aurora-stream.exe`, wait ~8 s, kill it, then read the tail of
   `aurora-stream-activity.log`: expect `[INFO] Aurora Stream 0.63.0 (build
   dev) starting.`, `[INFO] Encoder: ...`, `[INFO] Capture backend: ...`,
   `[INFO] Settings file: ...`, `[INFO] Loaded settings ...`, `[INFO] Found N
   Windows playback endpoints ...`.
4. To exercise failure/action lines, start a stream with a bad Twitch/YouTube
   key: expect `[INFO] Stream start: ...`, `[INFO] FFmpeg launched ...`,
   FFmpeg `[WARNING]` lines, then on failure `[ERROR] Stream failed: <exact
   reason>` + `[ACTION] Action taken: FFmpeg was terminated.` and a final
   `[ERROR] Stream session ended with failure: ...`. An alt-tab away/back on a
   Desktop-Duplication capture logs `[ERROR] Desktop capture output lost ...`
   + `[ACTION] Action taken: relaunching FFmpeg ... (recovery 1 of 3)`.
5. Settings menu -> "View activity log" opens the file in the default editor.
6. User-action lines: change any dropdown/checkbox in the UI and watch the log
   for `[INFO] <control> ...`; type/paste a stream key and confirm the log only
   says "Twitch stream key entered." / "pasted" — the key itself never appears.
   On first launch with no saved desktop-audio selection, the auto-selected
   default endpoint logs `[INFO] Desktop audio device set to <name>`.
7. Environment block: the first session in a log shows `[INFO] OS: ...`,
   `[INFO] CPU: ...`, `[INFO] RAM: ...`, `[INFO] GPU: ...`, `[INFO] FFmpeg: ...`
   and the `[INFO] Settings: ...` lines, with stream keys reported only as
   "configured (hidden)" / "not configured". Verify the FFmpeg line matches the
   bundled build (version.py / single-exe) or the PATH ffmpeg.

## Aurora Stream: OBS-style game capture via D3D11 render hook — implemented (2026-08-14)

User: "We want to stream a window even if it's minimized or out of focus or not
here. That's the main point." and then "we need just like obs per game render
hooks." The proper fix is OBS Game Capture-style render hooks: inject a DLL into
the game that hooks `IDXGISwapChain::Present` and captures the back buffer at the
render-API level, so it works even when the game is minimized, exclusive-
fullscreen, or covered. Decided to build it **entirely in D** (no C toolchain on
this machine: no MSVC `cl.exe`, no Windows SDK headers, only a stubbed VS 2019
and `dmd`).

### What was built and VERIFIED working
- `aurora-stream/source/aurorastream/d3d11.d` — raw D3D11/DXGI COM bindings as
  explicit vtable-struct layouts (`extern(C)` function-pointer fields). D
  `interface` types are NOT used because they do not dispatch through the native
  COM vtable. The test surface verified: `D3D11CreateDeviceAndSwapChain`,
  `IDXGISwapChain` (GetBuffer/Present/GetDesc), `ID3D11Device`
  (CreateTexture2D/CreateRenderTargetView), `ID3D11DeviceContext`
  (ClearRenderTargetView), and Release. 16,684 frames presented in the test app.
- `aurora-stream/gamecaphook.d` — the injected hook DLL, built as
  `-betterC` with a **custom entry point** (`/ENTRY:gamecaphookEntry`) and
  `/NODEFAULTLIB`, so no CRT startup runs in the foreign process. This is
  mandatory: a normal DMD `-shared` DLL (msvcrt120 or betterC-with-CRT) crashes
  in a foreign process (verified `0xC0000409` STATUS_STACK_BUFFER_OVERRUN even
  for a trivial DLL). The hook reads a config file
  (`%TEMP%\aurora-gamecap-<pid>.cfg`, `hwnd=` + `pipe=`), creates a dummy
  D3D11 device+swapchain to obtain the process-shared `IDXGISwapChain` vtable,
  replaces the `Present` slot (index 8) with `hookPresent`, and publishes
  captured BGRA frames through the shared-memory ring.
- Injection + transport (`tests/gamecap_test.d`, `tests/inject_notepad.d`):
  `CreateRemoteThread(GetProcAddress(kernel32,"LoadLibraryW"))`. CRITICAL:
  `&LoadLibraryW` in D resolves to THIS EXE's import thunk, NOT the kernel32
  function (verified: 0x14000BED0 vs 0x7FFD...) — always use GetProcAddress for
  the injected function pointer. Verified the hook DLL injects into notepad AND
  the D3D11 test app (returns a valid HMODULE), reads config, patches the vtable
  ("setup: vtable patched"), and connects the pipe ("setup: pipe connected").
  `hookPresent` is reached, `isTargetSwapchain` matches, and `captureFrame`
  runs.

### Resolved capture and integration details
- [RESOLVED] `ID3D11Device::GetImmediateContext` — the D3D11 device vtable has
  `GetCreationFlags` (slot 38) and `GetDeviceRemovedReason` (slot 39) BEFORE
  `GetImmediateContext`, so its real slot is **40**, not 38 (my original layout
  was missing those two methods). Verified by fetching the authoritative
  mingw-w64 `d3d11.h` and re-checking. `GetImmediateContext` now returns the
  real context. The probe that found it: create a plain device with
  `D3D11CreateDevice`, read the vtable, call each slot with
  `void(this, void**)` + a sentinel (0x12345678) and find the one that writes
  the known context — but the vtable dump + header comparison is what settled it.
- [RESOLVED] **Frame capture works end-to-end**: the hook copies the back
  buffer through a reusable asynchronous staging ring, performs nonblocking
  readback, and delivers versioned BGRA frames on a dedicated worker. The final
  minimized 1920×1080 matrix covered BGRA8, RGBA8, and RGB10A2 with two restart
  rounds and the production session for each. Two earlier pitfalls fixed:
  (a) moving multi-megabyte frames through a named pipe consumed roughly
  500 MB/s at 1080p60 and was load-sensitive; pixels now use a three-slot
  shared-memory ring and the 64 KiB pipe carries only framed control headers;
  (b) releasing a COM object must go through ITS OWN vtable slot 2 as an
  `extern(C)` call (`comRelease` helper) — releasing through another object's
  vtable, or via a `extern(D)` function pointer, crashes/hangs.
- [RESOLVED] The test target now uses a minimized, never-activated 1920×1080
  swap chain paced by a high-resolution waitable timer at 250 FPS. It stresses
  a 60 FPS capture without monopolizing the GPU or opening a foreground window.
- [RESOLVED] Aurora persists `gameCaptureMode`, injects with the real kernel32
  `LoadLibraryW`, continuously drains the pipe into a bounded latest-frame
  queue, reports structured metrics, aspect-fits non-native frames with a
  reusable HALFTONE DIB, and feeds the existing exact-cadence rawvideo input.
- [RESOLVED] The portable single-exe workflow builds the optimized hook before
  DUB embeds it. Extraction uses a content-derived filename and verifies bytes,
  preventing a same-size stale or locked DLL from being reused.
- Remaining inherent limits: x64/D3D11 only; anti-cheat/elevated processes may
  block injection; D3D12/Vulkan/OpenGL/HDR16 need separate hooks. Authenticated
  YouTube ingest is the next manual release test.

### Build/verify commands
```
dmd -m64 -shared -betterC -O -release -inline -boundscheck=off gamecaphook.d source\aurorastream\d3d11.d -Isource -I..\vendor\aurora-d-0.4.5\source -of=embedded\gamecaphook.dll -L/NODEFAULTLIB -L/ENTRY:gamecaphookEntry -L/OPT:REF -L/OPT:ICF -L"C:\D\dmd2\windows\lib64\mingw\kernel32.lib" -L"C:\D\dmd2\windows\lib64\mingw\user32.lib" -L"C:\D\dmd2\windows\lib64\mingw\gdi32.lib" -L"C:\D\dmd2\windows\lib64\mingw\ucrtbase.lib"
dmd -m64 -O -release -i -Isource -I..\vendor\aurora-d-0.4.5\source tests\gamecap_test.d -of=gamecap_test.exe
```
`hookDebug` is compiled out unless `GameCaptureDebug` is explicitly enabled.
The harness writes `gamecap_test_trace.txt` and owns/terminates its background
test target; it does not need a foreground process-control wrapper.

### Hard-won facts (recorded so they are not rediscovered)
- `dmd -shared` D DLLs default to `msvcrt120` (missing on this system) and do
  NOT export `extern(C)` symbols automatically — use `export` (D-mangled) or
  `-L/EXPORT:name` for clean names.
- An injectable DLL must skip the CRT startup: `-betterC` + custom `/ENTRY` +
  `/NODEFAULTLIB`, linking kernel32/user32/gdi32/ucrtbase import libs explicitly.
  Link `ucrtbase.lib` for `memcpy`/`memcmp`/`strlen` (present on the system);
  `libcmt`/`libucrt` import libs are NOT in this dmd distribution.
- `-betterC` globals must be `__gshared` (no TLS runtime → `_tls_index` is
  undefined otherwise). No D runtime/GC: use HeapAlloc, raw Win32, fixed buffers.
- String/format helpers written by hand are a trap: "aurora-gamecap-" is 15
  chars, not 16 — a hardcoded `+16` offset left the config path truncated
  (null at 52, pid orphaned at 53). Always use `enum prefix; ... prefix.length`.

## Aurora Stream: minimize to tray — implementation + verification method (2026-08-14)

Feature: `Settings → Minimize to tray when streaming starts` (auto-hide on
Start), `Settings → Close button hides to tray instead of exiting`, and a tray
icon whose **single-click** toggles Start/Stop streaming, **double-click**
restores the window, and **right-click** opens a custom dark menu
(Show window / Start-Stop / Status / Exit). Persisted as
`minimizeToTrayOnStart` / `closeToTray` (settings schema 8). **Minimize-to-tray
defaults to OFF** (auto-hiding while streaming is confusing), **close-to-tray
defaults to ON**; an explicitly saved value is respected.

### Implementation notes
- `aurora-stream/source/aurorastream/trayicon.d` (new): `Shell_NotifyIcon`
  backed by a hidden top-level Win32 window (`CreateWindowExW`, class
  `AuroraStreamTrayWindow`). Its messages are pumped by the main Aurora loop on
  the same thread, so no extra message thread is needed. Single-click uses a
  `GetDoubleClickTime()` timer so the first click of a double-click never
  toggles; the trailing UP of a real double-click is suppressed by remembering
  the DBLCLK tick. Menu is a native `TrackPopupMenu(TPM_RETURNCMD)` because
  Aurora's in-app menus are invisible while the window is hidden.
- aurora-d backend: `NativeWindow.setVisible(bool)` (win32 SW_SHOW/SW_HIDE).
  Rendering is gated on `_visible` in `paintNow` so a tray-hidden app stops
  rasterizing (energy), and show re-presents immediately.
- `StreamRoot` gates `onCloseRequested` via `closeRequested()`: close-to-tray
  hides and returns false (window stays alive); `_forceExit` (tray Exit / the
  update-restart path) returns true.
- The tray right-click menu is a **fully custom self-drawn popup**
  (`TrayContextMenu` in trayicon.d), not a native menu: a borderless topmost
  window rendered with GDI in the app's dark gray palette. It opens at the
  cursor, highlights on hover, closes on item click / Escape (registered
  hotkey) / outside click, and delivers the chosen command to the owner tray
  window via `wmMenuAction` (WM_APP+0x40). A previous
  `SetPreferredAppMode(ForceDark)` attempt was removed — it does not darken
  native menus on this machine (verified: the native menu rendered light).
- **Outside-click dismissal lesson:** `SetCapture` alone does NOT deliver a
  click that lands on the desktop/taskbar to the captured window (reproduced in
  the real app via a real-input driver: the menu stayed open and the menu
  window never received `WM_LBUTTONDOWN`; the standalone probe masked this
  because its outside clicks landed on a test form instead of the shell). The
  menu now shows activated (`SW_SHOW` + `SetForegroundWindow`) so an outside
  click deactivates it (`WM_ACTIVATE WA_INACTIVE` → close) AND installs a
  `WH_MOUSE_LL` low-level hook while open that closes it on any press outside
  its rectangle (posted as `wmMenuCloseRequest` to avoid reentrancy). Keep
  those layers if a custom menu is ever revisited.

### How to verify
1. `dub test` in `aurora-stream` → 43 modules pass (trayicon menu-structure
   unittest: idle/live menu labels + disabled status row; settings schema-8
   round-trip unittest).
2. `dub build` + `dub build --config=notitlebar` link.
3. Standalone tray probe (no GUI), from `aurora-stream/`:
   ```
   dmd -i -Isource build\trayicon_probe.d -of=build\trayicon_probe.exe user32.lib shell32.lib gdi32.lib winmm.lib ole32.lib avrt.lib
   build\trayicon_probe.exe
   ```
   Creates a real tray icon, then drives the callback window with synthesized
   messages: a WM_LBUTTONUP → exactly one toggle; UP, DBLCLK, UP → one
   window-show and NO toggle (guards the trailing-UP regression). Tooltip and
   balloon calls are exercised; remove()/shutdown() clean up. Exit 0 = pass.
   NOTE: the probe leaves a tray icon on the screen briefly.
4. Custom tray menu probe (drives the real `TrayContextMenu`):
   ```
   dmd -i -Isource build\tray_darkmenu_probe.d -of=build\tray_darkmenu_probe.exe user32.lib shell32.lib gdi32.lib winmm.lib ole32.lib avrt.lib
   build\tray_darkmenu_probe.exe
   ```
   Right-clicks the icon, verifies the menu window opens, clicks the Exit row
   (row center y=121 at 96 DPI) and asserts exit dispatches exactly once and
   the window is destroyed, then verifies Escape (WM_HOTKEY) and an
   outside-click dismiss without an action. Exit 0 = pass.
   To verify the menu's dark rendering, launch the probe under a solid-red
   fullscreen topmost form and screenshot the region around the cursor: the
   non-red pixels (the menu) should be ~96% dark, avg RGB ≈ (45,52,60)
   (`#252c34`), NOT the OS light menu.
4. Real-app close-to-tray test (PowerShell driver `verify-tray.ps1`, kept
   under `%TEMP%`): back up
   `%APPDATA%\Aurora Stream\aurora-stream-settings.json` first; add
   `closeToTray:true` + `minimizeToTrayOnStart:true` (write WITHOUT a UTF-8 BOM
   — a BOM makes `parseJSON` fail and the app silently overwrites settings with
   defaults on shutdown!); launch `aurora-stream.exe`; find the main window by
   pid; send WM_CLOSE → assert process alive AND `IsWindowVisible` false; find
   the `AuroraStreamTrayWindow` and PostMessage the registered
   `AuroraStreamTrayCallback` message with wParam=1 and
   lParam=WM_LBUTTONUP / WM_LBUTTONDBLCLK / WM_LBUTTONUP (80 ms apart) → assert
   the window is visible again. Kill the process and RESTORE the settings file.
5. `aurora-stream-activity.log` records "Window hidden to the system tray." and
   "Window restored from the system tray.".
6. **Refined behavior — "once the tray icon exists, X and minimize keep it in
   the tray"** (user request): verify A) with no tray feature enabled X still
   exits and minimize still taskbar-minimizes; B) with closeToTray on, X hides
   to tray; C) after a tray exists (restore via double-click), pressing X again
   hides to tray and never exits; D) with a tray present, `ShowWindow(SW_MINIMIZE)`
   (taskbar/Alt+Space minimize) is converted to a tray-hide on the next tick
   (window hidden, process alive). The titlebar/system-menu minimize path is
   covered by unit-tested routing through `requestMinimize()`.

### Gotchas learned while testing
- **A launched app rewrites the settings file** — on save (dirty timer) and on
  shutdown `saveSettingsNow()` always writes schema 8 from its in-memory state.
  Any probe that launches the app therefore leaves `%APPDATA%\Aurora
  Stream\aurora-stream-settings.json` rewritten (e.g. stream keys/browser
  choice can be lost if the app loaded different values). ALWAYS restore the
  exact original bytes afterward — a fresh `ConvertFrom-Json` round-trip is
  fine, but do not rely on a backup that was itself re-written. Keep the keys
  (Twitch `twitchKey`, YouTube `youtubeKey`) and `browserChoice` in the restore.
- `Write-Content`/`Set-Content -Encoding UTF8` in Windows PowerShell adds a
  UTF-8 BOM; the app's `parseJSON` then fails and it silently falls back to
  defaults (which later get saved). Write settings with
  `[System.IO.File]::WriteAllText(path, json, (New-Object System.Text.UTF8Encoding($false)))`.

### Known limits / follow-ups
- Auto-hide on Start was verified through the same `hideToTray()` path as
  close-to-tray, but not with a real stream running (that would push a live
  stream to the user's key during testing).
- The custom tray menu is mouse + Escape driven (no arrow-key navigation yet);
  layout is DPI-scaled from a 100% baseline.
- **Notifications are disabled by default** (user request): `showBalloon` is a
  no-op while `TrayIcon.notificationsEnabled` is false. To verify balloons at
  some point, set that flag true, rebuild, and trigger a tray-hide / tray
  toggle; the balloon appears next to the tray icon. Otherwise nothing is
  posted to the notification center.

## Aurora Stream: capture source red/stuck + window-content capture for covered/minimized windows (2026-08-14)

### Follow-up: VLC partial render / A/V mismatch
- Diagnosis: PrintWindow was using the outer `GetWindowRect` dimensions while
  VLC's DPI-virtualized client content was rendered at a different logical
  size. The result was a correctly rendered left portion plus an oversized
  untouched/white region. The slow PrintWindow cadence also previously
  compressed rawvideo timestamps and made video run ahead of audio.
- Fix: `windowcontent.d` now uses `GetClientRect`, requests
  `PW_CLIENTONLY | PW_RENDERFULLCONTENT`, clears the source DIB before each
  print, and `runWindowContentPump` duplicates held frames into missed cadence
  slots. `dub test` passes 44 modules.
- Required live acceptance: capture a visible VLC window again with
  window-content mode enabled, inspect the full client area for correct
  geometry, and compare audio/video timing. Use the default gdigrab mode for
  hardware-accelerated VLC if its video surface remains incomplete through
  PrintWindow.

User: "capture source feature seems to have trouble with selecting windows and
also keeps entire option highlighted as red all the time", then "We want to
stream a window even if it's minimized or out of focus or not here. That's the
main point."

### Diagnosis (all verified empirically, not guessed)
- The published version's saved settings selected a **minimized** cmd.exe
  window (`windowCaptureHwnd: 3867700`). The dropdown turns red
  ("Window (minimized): …") the moment the window list refreshes, because a
  minimized window cannot be captured — and it stayed red until changed.
- A busy desktop is mostly minimized windows (this machine: 54 of 69), so the
  CAPTURE SOURCE list was ~73 rows with most flagged
  "(minimized — not capturable)", making it effectively impossible to pick a
  usable window.
- Hard technical limits verified with real Win32/FFmpeg tests:
  - `ffmpeg -f gdigrab -i hwnd=<minimized>` → `I/O error`.
  - `PrintWindow(PW_RENDERFULLCONTENT)` on a truly minimized window returns only
    a 159×27 taskbar stub, not the window's content. A minimized window has no
    rendered surface, so **no capture API** (gdigrab, PrintWindow, or Windows
    Graphics Capture) can capture it.
  - `PrintWindow(PW_RENDERFULLCONTENT)` IS occlusion-immune: a deterministic
    probe (red window fully covered by a black window, Z-order forced) returned
    86,480 red pixels — the window's own content, not the cover.
- Headless UI probes (the aurora `UiTestDriver` + a real `GuiWindow`) drove the
  actual `CaptureSourceDropdown`: opening the menu, real clicks on rows,
  verifying captions/danger state. These confirmed selection works and that the
  red came only from the minimized saved selection.

### Fixes
- `windowsources.d`: `capturableWindows()` filters minimized windows out of the
  list; `updateCaption` keeps the red minimized warning for a selection that
  isn't in the (filtered) list; the saved-minimized row is labeled
  "Saved window (minimized — not capturable)"; an all-minimized desktop shows
  "All visible windows are minimized — restore one to capture it".
- `root.d`: startup self-heal — a saved capture window that is closed or
  minimized falls back to "Entire desktop" with a status message, persisted
  (schema 7), so the dropdown can never be stuck red across launches.
- `windowcontent.d` (new): `WindowContentCapturer` uses
  `PrintWindow(PW_RENDERFULLCONTENT)` → BGRA DIB, scaled to target, straight
  through to FFmpeg `-pix_fmt bgra` (DIB bytes are already BGRA little-endian).
  Returns false while the window is minimized/closed so the caller holds the
  last frame.
- `broadcast.d`: content-capture mode switches `captureArguments` from
  `gdigrab hwnd=` to `-f rawvideo -pix_fmt bgra -video_size WxH -framerate N -i
  pipe:0`, launches FFmpeg with stdin redirected, runs `runWindowContentPump`
  (writes raw BGRA via the CRT `_write` on the raw fd — never shares the Phobos
  `File` across threads), re-sends the held frame while minimized, and the
  monitor no longer stops on minimize in content mode (only on window close).
- `settings.d`: schema 7 adds `windowContentCapture` (opt-in; GPU/games can
  render black through PrintWindow). `root.d` adds the "Capture window content"
  checkbox (enabled only when a window is selected and not streaming).

### How to verify
1. `dub test` in `aurora-stream` → 42 modules pass (added windowcontent,
   settings round-trip, and broadcast content-capture-arguments tests).
2. `dub build` + `dub build --config=notitlebar --force` link; the default app
   launches and closes cleanly.
3. Standalone `WindowContentCapturer` probe: visible window → green pixels
   captured; minimized → `capture()` false; restored → true.
4. End-to-end pipe probe (mirrors the broadcaster's pump): create a colored
   window, pipe `PrintWindow` frames into
   `ffmpeg -f rawvideo -pix_fmt bgra -video_size 320x180 -framerate 30 -i
   pipe:0 -c:v libx264 ... out.flv` for 3 s, minimize at 1.3 s, restore at
   2.2 s. Asserts ffmpeg exit 0 and both the t=1.6 s (minimized, held frame)
   and t=2.6 s (restored, live) frames show the window's real content
   (signalstats SATAVG≈62.5, blue-dominant). Rebuild this probe from the
   deleted `tests/pipecontent_probe.d` pattern if needed.
5. The deterministic occlusion probe (red window under a black window →
   PrintWindow returns the red content) is the proof that content capture is
   occlusion-immune.

### Known limits (documented, not silently hidden)
- Truly minimized windows cannot be captured by any API (no rendered surface);
  the content pump keeps streaming the last good frame instead and resumes on
  restore. A minimized selection is still rejected at Start (no first frame).
- GPU/DirectX-rendered windows can render black through PrintWindow; hence the
  opt-in checkbox. A Windows.Graphics.Capture (WinRT) engine would handle
  those when occluded, but druntime has no WinRT types and no Win10 SDK is
  installed here — that is a separate hand-written-WinRT project.
- Method note: `schema_probe.d` and the app save wrote schema 7; a manual probe
  run once overwrote the user's settings with defaults — restore the real
  values (stream keys/browser/cache) before finishing, and verify with
  `Select-String` on `%APPDATA%\Aurora Stream\aurora-stream-settings.json`.

## Aurora Stream: "stops when I alt-tab" + one-time freeze — activity log + alt-tab capture recovery (2026-08-14)

Two user reports: the stream stops when alt-tabbing, and the app froze once.
Plan agreed with the user: "we will start logging to understand freeze and will
look into alt tab problem". Two changes:

### 1. Freeze logging — `aurora-stream-activity.log` + UI-thread stall detector

New `aurora-stream/source/aurorastream/activitylog.d` (class `ActivityLog`):
- Persistent, timestamped, thread-safe log written beside the executable
  (same folder as `aurora-stream-startup.log`): `aurora-stream-activity.log`.
- Records UI heartbeats, window events (focus gained/lost, minimized/restored),
  stream start/stop, and UI stalls. Rotated/truncated after 4 MiB.
- Stall detection runs on a dedicated watchdog thread (not the UI thread), so a
  fully frozen UI can still write the stall record. Threshold: no UI tick for
  > 3 s; checks every 0.5 s; records the stall start (at the LAST heartbeat, so
  the reported duration is the true freeze length), the last published stream
  state (status + metrics), and the resolution once ticks resume.

Wiring in `root.d` (`StreamRoot`):
- `_activityLog` created + `start()` in the constructor; `heartbeat()` at the
  top of every `onTick`; `onHostFocusChanged` logs "Window focus lost (possible
  alt-tab)" / gained; minimize/restore transitions logged; stream
  started/stopped transitions logged; the live snapshot (stream on/off, status,
  FPS/Speed/dup/drop/time) published via `setSnapshot` for stall context;
  `shutdown()` stops the watchdog and writes a final line.

How to verify the stall detector without the GUI:
```
dmd -i -Isource -I..\vendor\aurora-d-0.4.5\source build\activitylog_probe.d -of=build\activitylog-probe.exe user32.lib gdi32.lib shell32.lib winmm.lib ole32.lib avrt.lib -L/SUBSYSTEM:CONSOLE
```
(probe: heartbeat ~1 s, stop, wait ~4.5 s, resume, shutdown) → the log shows
`UI STALL DETECTED ... 3.1 s` then `UI STALL RESOLVED after 4.6 s`, and prints
`ACTIVITYLOG PROBE PASSED`. Note: `Thread.join()` in this DMD has no `Duration`
overload — use a plain `join()` (the watchdog sleeps at most 0.5 s between
checks, so it returns promptly once `_shutdown` is set).

### 2. Alt-tab stream stop — recoverable Desktop Duplication loss

Root cause: alt-tab to/from a fullscreen-exclusive app, a resolution change,
the lock screen, or a UAC prompt makes Desktop Duplication lose its output.
FFmpeg's `ddagrab` prints `AcquireNextFrame failed` and the capture input dies.
Before this change `parseLine` treated that first line as a permanent
`VIDEO CAPTURE FAILURE` and killed FFmpeg instantly.

Change in `aurora-stream/source/aurorastream/broadcast.d`:
- `parseLine`: an `AcquireNextFrame failed` line sets `_captureLossRecoverable`
  (recoverable) instead of `_videoCaptureFailed` (fatal). Kills FFmpeg (the
  input is already dead), status becomes "Desktop capture lost — reconnecting…",
  startup log gets `DESKTOP CAPTURE OUTPUT LOST` + the exact line.
- `monitorProcess`: returns early when `_captureLossRecoverable` is set (same as
  process-gone / user-stop / shutdown), so the launch loop can act promptly.
- `run()` launch loop: after the process exits, if the loss is recoverable AND
  the user still wants the stream (`_requestedRunning`, not `_shutdown`) AND the
  relaunch budget (`maxCaptureRelaunches = 3`, 300 ms apart) remains, it resets
  the per-run flags and relaunches FFmpeg (`RELAUNCH ... recovery N of 3`). The
  bounded FIFO muxer reconnects the Twitch/YouTube destination. Only when the
  budget is exhausted is it reported as a permanent capture failure (status
  "Desktop capture failed (did not recover after 3 relaunches)"). A user Stop
  during the recovery window is respected — no relaunch.

How to verify (automated):
- `dub test` → 41 modules pass. A new broadcast unittest drives `parseLine`
  with `AcquireNextFrame failed` and asserts: recoverable flag set, NOT
  `_videoCaptureFailed` (not fatal yet), status "Desktop capture lost —
  reconnecting…", a second loss line doesn't re-diagnose, clearing the flag
  works, and the monitor exit condition triggers on capture loss AND on user
  stop (`_requestedRunning` false).
- `python tests/verify-audio-transport.py`, `verify-rtp-sdp.py`,
  `verify-network-output-isolation.py` still pass.
- `dub build` (application/titlebar) + `dub build --config=notitlebar` link.
- Manual: launch the app, start a stream, alt-tab to/from a
  fullscreen-exclusive app. Expected: `aurora-stream-startup.log` shows
  `DESKTOP CAPTURE OUTPUT LOST` + `RELAUNCH ... recovery 1 of 3`, the status
  briefly reads "Desktop capture lost — reconnecting…", then live metrics
  resume. If the desktop stays unavailable for > 3 relaunches, the stream stops
  with the "did not recover after 3 relaunches" message. `aurora-stream-activity.log`
  shows the matching focus-loss line and stream-stop transition.

### Known limitation
- The relaunch gap is a few seconds (FFmpeg restart + FIFO reconnect); viewers
  see a brief interruption, not a dead stream. This is the intended trade-off
  for surviving alt-tab.
- `gdigrab` fallback capture has no `AcquireNextFrame` line, so a permanent
  gdigrab failure is still a normal capture failure (no relaunch). Only the
  Desktop Duplication backend is auto-recovered.

## Aurora Stream: settings file location — per-user by default, `--portable-config` opt-in (2026-08-14)

The settings file (`aurora-stream-settings.json`) previously lived in the
current working directory (`getcwd()`), i.e. "beside the folder the app is
launched from". That is wrong for an installed app: settings could land
anywhere (Start-menu shortcuts, other working directories) and the install
directory may not be writable.

New behavior:
- Default (installed): `%APPDATA%\Aurora Stream\aurora-stream-settings.json`
  on Windows; `~/Library/Application Support/Aurora Stream/` on macOS;
  `$XDG_CONFIG_HOME/Aurora Stream/` (else `~/.config/...`) on Linux. The
  directory is created on first save (`mkdirRecurse`).
- `--portable-config` argument: keeps the old behavior (file beside the launch
  folder). Parsed in both entry points (`app.d`, `app_titlebar.d`).
- One-time migration: `loadSettings` moves an existing CWD-relative settings
  file (or its `.bak`) into the per-user location when that file does not yet
  exist, in default mode only. Never overwrites a newer per-user file.

Key code:
- `aurora-stream/source/aurorastream/settings.d`:
  `setPortableConfigMode`, `portableConfigMode`, `userConfigDirectory`,
  `settingsFilePath`, `ensureSettingsDirectory`, `migrateLegacySettings`.
- `aurora-stream/source/app.d` + `app_titlebar.d`: `--portable-config` loop.

How to verify:
- `dub test` in `aurora-stream` → 38 modules pass (a new unittest toggles
  portable mode and asserts per-user != portable path).
- Build both configs: `dub build --config=application` (needs the running
  `aurora-stream.exe` stopped first — the exe locks its own file) and
  `dub build --config=notitlebar`.
- Launch the rebuilt exe: the status row shows the settings path; it must be
  under `%APPDATA%\Aurora Stream\`. Launch with `--portable-config` to confirm
  the path reverts to the launch folder.
- Existing CWD settings file migrates once on first default-mode launch.

## Aurora Stream: game/window capture (CAPTURE SOURCE) — stream only a window (2026-08-14)

User: "would be nice a setting for only game capture so they can't see desktop
xd". Aurora Stream now streams **only the selected window** when a window is
chosen in the new **CAPTURE SOURCE** dropdown (top of the settings panel), so
viewers never see the rest of the desktop.

Key code:
- `aurora-stream/source/aurorastream/windowsources.d` — `WindowSource`
  (`hwnd`/`title`/`processName`), `enumerateWindows()` (Win32 `EnumWindows` +
  `GetWindowTextW` + `QueryFullProcessImageNameW`; filters the shell window,
  tool windows, owned dialogs, title-less windows, and Aurora Stream's own
  process), `windowExists()`, `hwndFromText()`, and the `CaptureSourceDropdown`
  widget (lists "Entire desktop" + windows, re-enumerates on open, has a
  "Refresh window list" item).
- `aurora-stream/source/aurorastream/broadcast.d` — `captureArguments` emits
  `-f gdigrab -framerate 60 -draw_mouse 0 -i hwnd=<handle>` for window capture;
  `usesD3D11ZeroCopyVideo` is false for it (CPU path); `videoPipelineLabel`
  shows `Window capture (GDI) → CPU processing → encoder`;
  `validateBroadcastSettings` rejects a stale/closed window handle with a clear
  message instead of silently streaming the desktop.
- `aurora-stream/source/aurorastream/settings.d` — schema 6 keys
  `windowCaptureHwnd` (decimal handle) + `windowCaptureLabel` (cached
  `process — title`), persisted and round-tripped.
- `aurora-stream/source/aurorastream/root.d` — CAPTURE SOURCE section, live
  video-path label, and the preview window target.
- `aurora-stream/source/aurorastream/desktoppreview.d` — `setWindowTarget` lets
  the LIVE SOURCE CANVAS preview capture the selected window's client area
  instead of the primary monitor.

How to verify (automated):
1. `dub test` in `aurora-stream` → 40 modules pass (includes new
   `windowsources.d` tests and broadcast/settings round-trip + gdigrab-hwnd
   argument tests). The windowsources unittest requires, on an interactive
   desktop, that enumeration finds non-empty-titled windows with unique handles
   and that a freshly enumerated handle passes `windowExists` — this catches the
   callback-convention regression that emptied the list (see below).
2. `dub build` (application/titlebar) and `dub build --config=notitlebar --force`
   link.
3. End-to-end FFmpeg window capture (mirrors `broadcastArguments` for one
   destination, video-only, local FLV):
   ```
   ffmpeg -f gdigrab -framerate 60 -draw_mouse 0 -i hwnd=<HWND> \
     -filter_complex "[0:v]fps=fps=60:start_time=0:round=near,settb=AVTB,setpts=N/(60*TB),scale=1920:1080:force_original_aspect_ratio=decrease:flags=bicubic,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1[vsource];[vsource]format=yuv420p[vtwitch]" \
     -map "[vtwitch]" -r:v 60 -fps_mode:v cfr -c:v libx264 -preset veryfast \
     -b:v 6000k -maxrate 6000k -bufsize 12000k -profile:v high -level:v 4.2 \
     -g 120 -keyint_min 120 -bf 2 -sc_threshold 0 -max_interleave_delta 0 \
     -flush_packets 1 -flvflags no_duration_filesize -f flv -t 5 out.flv
   ```
   Expect ~300 frames at 60/1 and non-black frames (e.g.
   `ffmpeg -ss 3 -i out.flv -frames:v 1 -vf signalstats,metadata=print:file=- -f null -`
   → `YAVG` well above ~16).
   Get an HWND: `powershell "Get-Process | ? { $_.MainWindowTitle } | select Id,MainWindowHandle,MainWindowTitle"`.

Gotcha that WILL bite you (2026-08-14, fixed):
- Win32 callbacks passed to functions like `EnumWindows` must be declared
  `extern (Windows)`. A plain D `BOOL cb(HWND, LPARAM)` function casts fine but
  DMD's default convention reads the arguments from the wrong place, so every
  `HWND` arrives as **null** and every window is filtered out (the dropdown
  showed "No capturable windows"). Use
  `private extern (Windows) BOOL cb(HWND hwnd, LPARAM lParam)`.

Minimized windows cannot be captured (2026-08-14):
- A minimized window's client area is 0×0; `gdigrab` fails to open it (start)
  or stops producing fresh frames while encoder timestamps keep advancing
  (mid-stream) → the stream sits on a frozen last frame forever, and the frame
  counter can keep advancing so no watchdog fires. Handle it explicitly:
  - `windowsources.windowIsMinimized` (IsIconic); the dropdown labels such
    windows `(minimized — not capturable)` and the caption shows
    `Window (minimized): …`.
  - `validateBroadcastSettings` rejects a minimized selection at Start.
  - The broadcast monitor (`monitorProcess`) is passed `windowCaptureHwnd` and
    stops the stream within ~0.1 s the moment the captured window is minimized
    or closed, with a clear status/diagnostic, instead of freezing.
  - `DesktopPreviewCapturer.capture()` returns false for an iconic window so the
    preview keeps its last good frame.
- How to verify (automated): minimize a window
  (`[ShowWindow](hwnd, 6)` from PowerShell), then `windowIsMinimized(hwnd)`
  must be true, `validateBroadcastSettings` with that hwnd must return the
  minimized message, and `captureDesktopPreview`/`DesktopPreviewCapturer.capture`
  must return false for it.

Manual (GUI):
- Launch Aurora Stream → CAPTURE SOURCE dropdown lists visible windows
  (`process.exe — Window Title`) plus Entire desktop; open a game/app after
  startup and the dropdown shows it after **Refresh window list** (or on the
  next open).
- Pick a window, start streaming: status row shows `Capture: Window capture:
  <label> • Window capture (GDI) → CPU processing → encoder`. The LIVE SOURCE
  CANVAS preview shows the window, not the desktop.
- Close the selected window, restart the app, Start → rejected with "The
  selected capture window is no longer open ...".
- Switch back to Entire desktop → desktop capture (ddagrab/NVENC) returns
  (`Desktop Duplication (cursor-safe)` label / `D3D11` path when hardware
  supports it).

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
the smoke test. `FFMPEG_TAG` overrides the pinned revision; the current default
is `c48230eb86ff02246f6a14fa1475a0d9398363b4`, verified for the Windows
Graphics Capture HWND source.

The build enables ONLY what the two apps use (audited call-site by call-site;
all names cross-checked against ffmpeg's `-encoders/-decoders/-filters/
-formats/-protocols/-devices`):
- aurora-cut surface: mov/mkv/webm/mp3/wav/flac/ogg/image2/gif demuxers,
  mp4/mp3/image2/rawvideo/s16le/null muxers, libx264+nvenc+qsv+amf+aac+
  libmp3lame+ppm+rawvideo+pcm_s16le encoders, ~35 decoders incl. images +
  wrapped_avframe/rawvideo (lavfi + raw pipe), the compositor filter graph,
  d3d11va/dxva2 decode hwaccels, file/pipe protocols.
- aurora-stream surface: gfxcapture/ddagrab filters plus gdigrab/dshow/lavfi
  input devices,
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
  -devices and asserts the `gfxcapture` HWND/border options plus
  ddagrab/dshow/gdigrab/udp/rtmp/rtmps.
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

## Aurora TitleBar drag-to-snap (2026-08-15)

Aero-style drag snapping is now built into `aurora.widgets.titlebar.TitleBar`
as the foundation for the new standard Notepad. While a titlebar drag is
active, the widget samples the real screen pointer against the monitor work
area and reports a `TitleBarSnapTarget` + target bounds.

Behavior (platform standard): top edge = maximize to the work area, left/right
edges = half-screen, corners = quadrants, bottom edge alone never snaps, and
`snapThreshold` (default 8 logical px) sets the edge-engagement distance.
`onSnapChanged(target, bounds)` fires on every target change (including back to
`none`) so the owner can show/hide a preview; `onSnapApplied(target, bounds)`
fires on release over a live zone and the owner applies `bounds`
(`GuiWindow.setWindowBounds`). Releasing over a zone skips the final drag-move.

The reusable `TitleBarSnapPreview` overlay (translucent rounded rect) must be
added as the LAST child of a frameless window root so it paints above content;
drive it from `onSnapChanged`, mapping screen bounds to local coordinates with
the window origin.

### CRITICAL gotcha — the preview must be input-transparent

`TitleBarSnapPreview` is created **disabled** (`setEnabled(false)`). This is
what keeps it a pure paint layer: `Widget.hitTest` (widget.d) walks children
from last to first and returns the topmost **enabled** widget at the point, so
a full-size enabled overlay added as the last child would receive every
mouse-down and bubble to its ancestors only — the titlebar (a sibling, earlier
in paint order) would NEVER get clicks, breaking dragging and every caption
button on the live window. This exact regression broke the live demo originally
and is covered headlessly by `tests/titlebar_smoke.d`: with the full-size
preview present, the close/minimize/maximize buttons must still fire and the
bar must still drag.

### Platform plumbing added

- `NativeWindow.queryWorkArea(Point screenPoint, out Rect)` — Win32
  `MonitorFromPoint` + `GetMonitorInfoW` `rcWork` converted to logical units.
- `NativeWindow.setWindowBounds(Rect)` — Win32 `SetWindowPos` move+resize.
- `WidgetHost.queryPointerScreenPosition` + `queryWorkArea` (with `Widget`
  helpers) so the titlebar can sample the cursor/monitor without an owner.
- Headless `PlatformWindow.setTestWorkArea(Rect)` /
  `setTestScreenPointerPosition(PointF)` / `lastWindowBounds`; exposed through
  `UiTestDriver.setTestWorkArea` / `setTestScreenPointerPosition` /
  `lastWindowBounds` so headless tests can inject the monitor + cursor.

### How to build / test

```
# Headless smoke test (same command as the existing titlebar smoke):
dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source tests\titlebar_smoke.d -of=build\headless-smoke\titlebar-smoke.exe -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32 -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet
set AURORA_RENDERER=software&& set SDL_AUDIODRIVER=dummy&& build\headless-smoke\titlebar-smoke.exe

# Widget module unittests (covers pure target/bounds mapping incl. corners):
dmd -i -version=AuroraHeadless -unittest -main -Isource -Ivendor\aurora-d-0.4.5\source vendor\aurora-d-0.4.5\source\aurora\widgets\titlebar.d -of=build\headless-smoke\titlebar-module.exe -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32 -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet

# Real apps (exercise the Win32 work-area path):
aurora-stream\dub build --compiler=dmd          # custom titlebar app
vendor\aurora-d-0.4.5\dub build --config=titlebar --compiler=dmd
```

The smoke test injects a 1920x1080 work area at the origin and a screen
pointer, then drags the titlebar to the left edge (expects `left` + bounds
`0,0,960,1080`), to the top edge (expects `top` + full work area), verifies a
mid-drag move off the edge clears the preview and the release applies nothing,
verifies `setSnapEnabled(false)` never engages, and verifies the caption
buttons + drag still work with the full-size preview overlay present. Manual
verification: run the titlebar demo or Aurora Stream, drag the window to the
top / sides / corners and release — the window must maximize / half-screen /
quadrant with a translucent preview shown while dragging.

### Gotchas

- `event.globalPosition`/`preciseGlobalPosition` on Win32 are WINDOW-RELATIVE
  (`fillMouseEvent` copies `position`), so snap must query `GetCursorPos`
  (`queryPointerScreenPosition`) instead of trusting the event.
- Snap is evaluated on the move AFTER the drag threshold is crossed: the first
  move after a press arms the drag; only the `_dragging` branch re-samples the
  snap zone.
- `systemMoveOnDrag` intentionally has no Aurora snap: the OS move loop owns the
  drag and already provides native aero-snap.
- Headless `queryPointerScreenPosition` returns false until a test pointer is
  injected, so existing headless tests can never spuriously snap.
- Live-click automation on this host is unreliable: a fullscreen window
  (e.g. maximized Edge) covers the demo and intercepts `WindowFromPoint` /
  clicks. Verify interactively (Alt+Tab to the demo first) rather than by
  synthetic screen clicks.

### Drag-to-unmaximize fixes (2026-08-15, user complaint)

Dragging a maximized window's titlebar down sometimes "didn't unmaximize."
Two root causes were fixed:

1. **Snap-back after restore.** The snap engine re-engaged the top-edge zone
   right after restore-on-drag, so releasing while the pointer was still near
   the top snapped the window straight back to maximized. `TitleBar` now sets
   `_snapSuppressed` (plus `_snapSuppressedZone` = the zone at restore time)
   and holds snapping only while the pointer stays in that same zone; leaving
   it (into another zone or the center) resumes snapping immediately.
   Regression in `tests/titlebar_smoke.d`: restore from maximized with the
   pointer still in the top zone must not fire `onSnapApplied(top)`, and a
   following drag to the left edge must snap normally.
2. **App restore used `toggleFullscreen()` unconditionally.** Drag-snap-to-top
   only fills the work area and never enters fullscreen, so the old
   `restoreFromDrag` toggled fullscreen ON instead of restoring. Both
   `demos/titlebar.d` and `aurora-stream/source/app_titlebar.d` now save the
   pre-maximize bounds in `_restoredBounds` (on caption/double-click maximize
   and on snap-to-top) and restore to them: if `_window.fullscreen()` is set
   they toggle fullscreen off, otherwise they `setWindowBounds(_restoredBounds)`
   — then the existing grab-point re-anchor keeps the drag under the cursor.

Manual check: maximize (button, double-click, or drag to the top edge and
release), then drag the titlebar down a little and release quickly — the window
must stay restored (no snap-back). Drag down and out to a side edge — it must
snap to the half-screen target.

### Distorted frame while resizing (2026-08-15, user report)

NOT a regression from the titlebar/snap work — the resize code is untouched by
that commit. The distorted/stretched frame is the **software live-resize proxy**:
during a native resize, `window.presentNativeResizeProxyFrame` →
`win32.presentScaledResizeFrame` → `StretchDIBits` stretches a cached snapshot
of the last frame to the current window size. It only runs when
`liveResizeScalingSupported()` is false, i.e. the Software renderer or a Vulkan
renderer without swapchain present-scaling (`RendererPreference.automatic`
falls back from Vulkan to Software on failure). On the Vulkan-with-scaling path
WSI stretches the last image itself and no proxy frame ever shows.

Improvements made to the fallback experience:
- `win32.d` uses `HALFTONE` stretch mode (+ `SetBrushOrgEx` reset) instead of
  `COLORONCOLOR`, so the stretched preview is interpolated instead of blocky.
- `window.d` now schedules **exact** frames during resize on the non-scaling
  path too (`onNativeTick` / `scheduleLiveResizeExactFrame` no longer gate on
  `liveResizeScalingSupported()`), bounded by the same 1/60 s accumulator. After
  each exact frame it re-arms the stretched snapshot from that frame
  (`refreshResizeProxyFromScene`), so the window shows current content at the
  new size between proxy frames instead of freezing on the pre-resize frame.

Verify: run `aurora-stream\RUN-WINDOWS.bat` (automatic renderer) and drag a
window border — content should track the size (interpolated, not one frozen
blocky stretch). `AURORA_RESIZE_PROFILE=1` prints per-frame scene/render times
in the window title for tuning.

### Minimize-to-tray is no longer the default (2026-08-15, user complaint)

Pressing the titlebar minimize button used to hide the app into the system tray
once the tray icon existed. It now performs a plain taskbar minimize by default;
hiding to the tray on minimize is opt-in:

- New `minimizeToTray` broadcast setting, **off by default**, persisted in the
  settings JSON (schema 8) and covered by the settings round-trip unittests
  (`settings.d`): default off, explicit on/off respected, JSON key
  `minimizeToTray`.
- `StreamRoot.requestMinimize()` (titlebar button + system menu) and the
  `onTick` auto-conversion of any native minimize (taskbar click, Alt+Space)
  into a tray-hide are both gated on `minimizeToTray` (`root.d`).
- Checkbox in the settings menu: "Minimize button hides to tray instead of
  minimizing to taskbar". Startup settings line reports it
  (`environment.d`).

Verify: run the app, press the titlebar minimize — the window should minimize
to the taskbar. Enable the checkbox and press minimize — it hides to the tray
(tray icon appears). Close-to-tray behavior is unchanged.

### Aurora Notepad drag-down restore kept the maximized size (2026-08-15, user complaint)

The new Notepad (`aurora-notepad/`) did not return to its initial window size
after dragging the titlebar down out of maximization. Root cause:
`NotepadTitleBar.restoreFromDrag` guarded on the vendored widget's
`maximized()`, but the vendored `TitleBar` clears its own `_maximized` flag
BEFORE firing `onRestoreRequested` — so the guard always bailed and the restore
never ran. The stream app tracks its own state, which is why it wasn't hit.

Fix (`aurora-notepad/source/auroranotepad/titlebar.d`):
- The notepad now tracks its own `_maximized`, kept in sync with the widget via
  `setMaximized`, and uses it everywhere (`toggleMaximize`, `restoreFromDrag`,
  `applySnap`, `showSystemMenu`, `maximizedState`).
- `restoreFromDrag` always forces `setWindowBounds(_restoredBounds)` after
  leaving fullscreen (same fix as the stream app).

Also: headless `PlatformWindow` (`vendor/aurora-d-0.4.5/.../platform/headless.d`)
now reports `windowBounds` (initial = requested size, updated by
`setWindowBounds`), so headless tests verify restore/maximize bookkeeping
exactly like the live platform. Regression in `aurora-notepad/tests/headless_smoke.d`:
maximize → drag down → assert the window returns to its initial size and the
maximized state clears.

Test-order gotcha: the drag-restore press reused the snap test's titlebar point,
which made the snap test's press read as a double-click (clickCount 2 →
`toggleMaximize` instead of dragging). A `resetClickState` between the two
fixes it.

### Stream app drag-down restore kept the maximized size (2026-08-15, user complaint)

Not every drag-down out of maximization returned the aurora-stream window to
its initial size; sometimes it stayed at the maximized extent. Root cause: the
app's restore relied on the OS fullscreen placement or `_restoredBounds`, and
`_restoredBounds` could be stale/desynced when maximize states were mixed
(snap-to-top fills the work area without entering fullscreen; a subsequent
caption-maximize then toggled the wrong flag).

Fix (in both `aurora-stream/source/app_titlebar.d` and
`vendor/aurora-d-0.4.5/demos/titlebar.d`):
- `_restoredBounds` is captured only when the window is genuinely restored
  (`applySnap` guards on `!_window.fullscreen()`, `toggleMaximize` captures it
  only in the maximize branch).
- `toggleMaximize` is state-based: `_maximized || _window.fullscreen()` →
  restore (leave fullscreen if set, then force `setWindowBounds(_restoredBounds)`);
  otherwise maximize (capture bounds, set `_maximized`, enter fullscreen).
- `restoreFromDrag` always forces `setWindowBounds(_restoredBounds)` after
  leaving fullscreen (was `else if`, which skipped the resize whenever the
  window was fullscreen — the OS placement could then leave the maximized size).

Manual check: maximize via button, double-click, and drag-to-top, then drag
down repeatedly — the window must return to its pre-maximize size every time.

### Close button honors the close-to-tray setting (2026-08-15, user complaint)

The Close button (X / Alt+F4 / system menu) went to the tray even after
disabling "Close button hides to tray". Root cause: `StreamRoot.closeRequested()`
had a hard `if (_tray !is null)` override that ran before the `closeToTray`
check, so once the tray icon existed X always hid to the tray. The override is
removed; `closeToTray` alone decides (enabled → tray, disabled → real exit; the
tray is removed in `shutdown()`). Verify: uncheck close-to-tray, press X — the
app exits; recheck it — X hides to the tray.

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

## Aurora Cut playback rework: readiness gate, prewarm keep-alive, instant warm steps (2026-08-14)

User request: make playback performant and non-blocking, never play unless
ready, always smooth by prewarming/caching after moving the playhead, and make
per-frame playhead movement instant.

### What changed and why (verified against `editor.d` onTick + `playback.d`)

Phase 1/2 - readiness gate and audio decoupling (`editor.d`):
- `playbackReady()` is the single predicate: not awaiting first frame, not
  awaiting the audio clock, not video-buffering, and the monotonic clock valid.
  Exposed as `playbackReadyForTesting()`.
- The audio device clock is no longer a hard gate:
  - If audio cannot start (`startPlaybackAudio` fails), the buffered video
    plays muted on the monotonic clock with a status instead of retrying
    forever in `_playbackAwaitingFirstFrame`.
  - If the audio clock never becomes readable within
    `playbackAudioClockFallbackSeconds` (5 s), the transport falls back to the
    monotonic clock and plays muted instead of hanging on "Waiting for audio
    output...".
- First-frame readiness is bounded: `_playbackFirstFrameWait` accumulates while
  `_playbackAwaitingFirstFrame`; after `playbackFirstFrameTimeoutSeconds`
  (12 s) `failPlaybackStart` stops the streams and reports a failure instead of
  leaving the transport preparing forever.
- `playback.d` headless clock now freezes while paused (`_transportPaused` or
  the new `_prerollPaused`), mirroring `waveOutPause` freezing the device
  sample counter. This fixes the pre-existing `audio_clock_smoke.d` failure
  ("Paused PCM preview audio advanced before resume") and stops preroll
  buffering time leaking into the transport position.

Phase 3 - robust prewarm keep-alive and adoption (`editor.d`):
- A complete, unchanged prewarm stays alive (quiescent; the decoder blocks
  once its 16-slot queue is full). This removes the 45 s cancel/restart churn
  at the same position that the app log showed every ~45 s.
- `notePlaybackPrewarmDirty(position)` only cancels when the playhead leaves
  `_playbackPrewarmForwardWindow` (≈ two slot-queues, `32/fps` seconds) ahead
  of the prewarm start, or when the model revision changes.
- A prewarm that decoded to the end of its range (finished, no ready frames)
  is cancelled instead of being adopted dead; `startPlaybackPrewarm` skips
  positions with < 0.4 s remaining so it cannot churn at the range end.
- Direct-mode video/audio signatures dropped the launch position and duration
  (now stored separately as `_playbackPrewarm*Position/Remaining`); adoption
  matches identity + playhead-inside-forward-window + remaining-not-exceeded,
  so scrubbing or stepping within the window before Play still adopts the warm
  streams instead of respawning FFmpeg.

Phase 4 - instant forward stepping from the warm stream (`editor.d`,
`playback.d`):
- `VideoFrameStream.canTakeReadyAtOrAfter` / `takeReadyAtOrAfter` let a paused
  sequence step consume the buffered stream directly (dropping only obsolete
  frames strictly before the target), so no FFmpeg spawn and no still-renderer
  request happens for in-window forward steps.
- `tryStepSequenceFromPrewarm(value)` in `playheadChanged` serves those steps
  (guarded by `_seekPending` clear, stream running, and target >= displayed
  frame). Backward/out-of-window steps still fall back to the seek/still path.
- The first-frame handler now prefers `takeReadyAtOrAfter(playhead)` when the
  adopted decoder is ahead of the playhead, so playback starts at the playhead
  instead of the prewarm start position.

Phase 5 - non-blocking audit (`playback.d`):
- Removed the caller-thread `waveOutReset` calls from `PcmAudioPlayer`
  enqueue/stop/shutdown. The worker resets and closes the previous
  generation's sink on the worker thread when it observes the generation bump,
  so no device call can stall the event thread.

### How to verify
- `tests/editor_smoke.d`: direct playback EOF-while-buffering regression,
  prewarm adoption (no new video/audio processes on Play) all pass unchanged.
- `tests/audio_clock_smoke.d` (was failing on headless): now passes - the
  paused clock is frozen, and it advances only after resume.
- `tests/synced_playback_preroll_smoke.d` (was failing at line 112 on base):
  repaired the pre-existing wrong assertions (frame steps are debounced, not
  synchronous; a cache hit still dispatches a request but spawns no process).
  Added a warm-step block: pause -> prewarm re-warms -> step forward in-window
  -> asserts no `_seekPending`, no preview-request delta, and the buffered
  stream frame displays.
- Gate on this host: `dub test` (33 modules), editor-smoke, playback-stress,
  audio-clock-smoke, seek-resilience-smoke, static-sequence-smoke,
  synced-preroll-smoke, layout-smoke, export-smoke, gpu-decode-smoke,
  model-smoke, playback-proxy-smoke; `dub build` links the GUI app.
- Build the smoke tests on Windows (dmd, not ldc): dmd uses `-version=X` (not
  `-d-version=X`) and needs the system libs as file args:
  `dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source
  -Luser32.lib -Lgdi32.lib -Lshell32.lib -Lwinmm.lib -Lwininet.lib tests\<name>.d
  -of=build\<name>.exe` then run with `AURORA_RENDERER=software` and
  `SDL_AUDIODRIVER=dummy`.

## Timeline playback: never stop, never desync, prewarm/cache (2026-08-18)

User: playback feels burdened/unpredictable and stops for performance reasons;
want prewarming+caching so playback, playhead moves, and the wait after a move
never stop or desync, at efficient perfect playhead playback with no latency.

### What changed and why (verified against `editor.d` onTick + `playback.d`)

1. **Hard "Buffering video…" stop removed (`editor.d`).** The old transport
   entered `waitForVideoBuffer()` whenever the displayed frame lagged the audio
   clock by > `playbackVideoLagToleranceSeconds` (0.075), which PAUSED audio
   and the transport, then re-prerolled. That pause is the "randomly stopping"
   experience. The whole `_playbackVideoWaiting` state machine was deleted
   (fields, `waitForVideoBuffer`/`resumeAfterVideoBuffer`/
   `advancingVideoWaitClock`, the waiting branch in onTick, the EOF-while-
   waiting block, `playbackReady()`'s `!_playbackVideoWaiting`, the
   `simulateVideoBufferWaitForTesting` hook). The transport now keeps the audio
   clock running and the display catches up by fast-forwarding stale frames via
   the ordinary `takeReadyAtOrBefore(clock + lead)` pull, so it never pauses
   for video performance.
2. **Deeper video frame queue (`playback.d`).** `videoFrameSlotCount` 16 → 24
   (≈0.8 s at 30 fps), absorbing ordinary decode jitter. The prewarm keep-alive
   forward window widened `32/fps` → `48/fps` (two slot-queues) in
   `startPlaybackPrewarm`.
3. **Adaptive decode height (`editor.d`).** ~~During steady playback, if the
   frame queue stays empty ≥ 0.30 s the decode/composite height steps down one
   ladder rung (1080→720→540→480→360→240) and the video stream restarts at the
   current audio position, stepping back up after 12 s stable.~~ **REVERTED**
   — this mid-playback stream restart was the cause of the black screen on Play
   in the real GUI (see the follow-up section below). Playback now never
   restarts a stream mid-flight; a slow decoder simply holds the last frame and
   catches up by dropping stale frames.
4. **Prewarm immediacy (`editor.d`).** `playbackPrewarmDelaySeconds` 0.10 →
   0.06; a committed paused seek sets `_playbackPrewarmPrompt` so
   `updatePlaybackPrewarm` starts the warm decoder on the next tick instead of
   waiting out the settle debounce again. All prewarm/prepare/still paths use
   `liveDecodeHeight()`, so prewarm always matches what Play would start.
5. **Concurrent paused audio (`editor.d`).** `startPlaybackStreams` calls
   `startPlaybackAudio(true)` at the same time the video decoder spawns, so
   time-to-sound overlaps the video spawn. The first-frame handler still gates
   presentation on the prerolled frame and resumes the paused audio.
6. **Live compositor efficiency + aspect parity (`editor.d`).** Live playback
   previously built `ExportPreset.previewForHeight(renderHeight)` (fixed 16:9)
   and let `compositeStreamArguments` force-scale to the decode size — wasted
   pixels AND stretched portrait/square sequences. New
   `previewPlaybackPreset(Size decode)` builds the preset directly from the
   decode size, so the `[vout]scale=` tail is elided (no double render) and the
   aspect matches. `requestPlaybackStill`/`dispatchPendingPreview` follow the
   same decode height, so pause/scrub and play agree.

### How to verify (headless, deterministic)

- `tests/editor_smoke.d` EOF regression: after the decoder finishes, playback
  must continue and complete at `_playbackEnd` with no "Video decoder
  ended before the next frame was ready" status. Direct-playback audio
  assertions now expect a PAUSED audio request at Play (concurrent spawn) with
  presentation still gated on the first prerolled frame.
- `tests/synced_playback_preroll_smoke.d`: same concurrent-paused-audio
  assertion update.
- Gate on this host: `dub test` (33 modules), editor-smoke (3x), synced-
  preroll-smoke, static-sequence-smoke, seek-resilience-smoke (with
  base-av.mp4), playback-stress, audio-clock-smoke, playback-proxy-smoke, and
  `dub build`. Build/run on Windows with dmd as documented above.
- Pre-existing (also fails on the base commit, unrelated to this change):
  `playback_seek_resilience_smoke.d` line 115 fails when its video arg is
  `stress.mp4` (2.0 s real file declared 3.0 s); it passes with `base-av.mp4`.
  Worth a follow-up on the media/duration mismatch.
- Manual GUI pass still worthwhile on this 4-CPU host: play a multi-clip live
  timeline under load (status must never show "Buffering video…", playback must
  not stop), and scrub then press Play quickly to confirm the warm stream is
  adopted.

### Follow-up: black screen on Play in the real GUI (2026-08-18, reverted)

User reported that after the rework, pressing Play in the real app showed only
a black screen. Evidence-based diagnosis and resolution:

1. **The user's real session log** (`aurora-cut.log`, 20:05:58, Vulkan,
   `raiserfredposts.auroracut` = portrait 720x960 shorts project, webm VP9
   source + text overlays) showed "Adaptive playback decode switched to
   320x420" / "320x360" firing THREE times in ~40 s. Every downgrade ran
   `restartPlaybackVideoAtPlaybackClock()` — a mid-playback stream teardown +
   FFmpeg respawn while the audio clock kept running. On this slow machine the
   respawned lower-resolution composite could not catch the already-running
   audio clock, so the transport held the last frame while re-prerolling; the
   preview stayed frozen/black while audio played on.
2. **Headless reproduction proves the frames are correct**: new
   `tests/live_portrait_playback_repro.d` drives a real `EditorRoot` with the
   user's actual proxy mp4 AND the actual VP9 webm, a portrait 720x960
   composition, a V1 transform and a text overlay (forcing the live composition
   path), then samples an 8x8 grid of preview pixels every 250 ms. Average
   brightness stays ~40-80 across a 10 s run at a 320x390 decode — NON-BLACK.
   Command (Windows):
   `dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source
   tests\live_portrait_playback_repro.d -of=build\repro.exe -Luser32.lib
   -Lgdi32.lib -Lshell32.lib -Lwinmm.lib -Lwininet.lib` then run with
   `AURORA_RENDERER=software SDL_AUDIODRIVER=dummy build\repro.exe <media>`.
3. **Resolution**: removed the entire adaptive-decode mechanism (fields,
   ladder constants, `downgradePlaybackDecode`/`upgradePlaybackDecode`/
   `restartPlaybackVideoAtPlaybackClock`, the `_playbackRestartPending`
   first-frame branch, the onTick queue-empty detector, test hooks, and the
   editor-smoke adaptive regression). All decode-height call sites restored to
   `liveDecodeHeight()`. Playback never restarts a stream mid-flight now; a
   slow decoder only holds the last frame and catches up by dropping stale
   frames (original "never stop, never desync" behavior) with no resolution
   churn. Kept the safe fixes: 24-slot queue, prewarm prompt + 60 ms debounce,
   48/fps prewarm window, concurrent paused audio, no hard "Buffering video…"
   stop, aspect-correct `previewPlaybackPreset`.
4. **Verified** after the revert: `dub test` 33 modules, `dub build`,
   editor-smoke, synced-preroll-smoke, static-sequence-smoke, seek-resilience
   -smoke (with base-av), playback-stress, audio-clock-smoke, playback-proxy
   -smoke all pass; the portrait live-composition repro plays non-black with
   the user's exact webm.
5. If the black screen persists in the real GUI after this build, the remaining
   suspects are GUI-only and need a screenshot/debug session, not headless
   assertions: the Vulkan renderer's `drawRgbImage`, the real waveOut clock
   interacting with concurrent-paused audio, or the hardware-decode path.

### REAL root cause of the black screen: H.264-probed hardware decode forced onto AV1 (2026-08-18, 3rd pass)

The black screen persisted after the adaptive revert, so the previous diagnosis
was wrong. Definitively reproduced and fixed:

1. **Reproduction.** Added `openProjectForTesting` to `EditorRoot` and
   `tests/playback_black_screen_repro.d` which opens the user's real project
   (`raiserfredposts.auroracut`), scrubs, presses Play, and samples both the
   raw preview frame (`preview.pixelForTesting`) and the rendered window
   surface (`window.surface().pixels()`), saving BMP snapshots. With the user's
   project headless:
   - Scrub still: RAW brightness 91 (visible).
   - After Play: RAW avgRGB **0,0,0** the whole run — the composite stream
     emitted pure black frames. Window surface ~46% near-black.
   - ffmpeg stderr: `Decode error rate 1 exceeds maximum 0.666667` (AV1).
2. **Root cause.** The user's source is an **AV1 .webm** (720x960) whose stored
   `videoCodec` is **empty** (stale project file; ffprobe does report `av1`).
   Hardware decode (`-hwaccel d3d11va/dxva2/cuda`) is probed at startup
   `decoderWorks()` against an **H.264 sample only** (`writeDecodeProbeSample`
   encodes `testsrc2` with `libx264`). But `appendInputArguments` (exporter.d)
   and `playbackDecodeInputOptions` (editor.d) applied those options to ANY
   input whose stored codec wasn't exactly `"av1"`. Forcing the H.264-validated
   accelerator onto AV1 fails the AV1 decode → the compositor graph outputs its
   `color=c=black` canvas → pure black playback. Scrub looked fine only because
   the PreviewService returned a cached still.
3. **Fix.** In `appendInputArguments` (exporter.d): the probed decode options are
   zeroed unless the input codec is a known `h264`/`hevc`/`h265`; detected
   `av1` (and huge empty-codec downloads) still get `-c:v libdav1d`; any other
   or unknown codec decodes on the CPU where FFmpeg auto-selects the right
   decoder. Same rule applied in `playbackDecodeInputOptions` (editor.d).
4. **Verification.** `playback_black_screen_repro.d` on the user's project now
   shows RAW brightness ~130-140 during Play (real video), no AV1 errors.
   `dub test` 33 modules, `dub build`, and the full playback battery pass.
5. **How to re-run the reproduction** (headless, software renderer):
   `dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source
   tests\playback_black_screen_repro.d -of=build\blackscreen.exe -Luser32.lib
   -Lgdi32.lib -Lshell32.lib -Lwinmm.lib -Lwininet.lib`, then
   `AURORA_RENDERER=software SDL_AUDIODRIVER=dummy build\blackscreen.exe
   <project.auroracut> software`. BMPs land in `%TEMP%\black-screen-*.bmp`.
6. Follow-up (perf, not black): live-composition playback decodes the ORIGINAL
   AV1 webm on the CPU instead of the 540x720 H.264 playback proxy. Consider
   proxy substitution in the playback composite request (`enablePlaybackDecode`),
   mirroring `playbackAssetForPreview` in the direct path.

### Loop playback with work-area In/Out marks (2026-08-18, 4th pass)

Requirement: with loop active and In/Out markers set, the transport must loop
between the markers.

1. **Already worked at Play time:** `startPlayback` clamps `_playbackStart`/
   `_playbackEnd` to `[_workIn, _workOut]` when `_loopEnabled`, falls back to
   the full sequence without markers, `loopPlaybackRestart` rewinds to
   `_playbackStart`, and the onTick end-check wraps. editor-smoke has a
   loop test (marks → enable loop → play → wrap at Out → return to In).
2. **Gap = order of operations.** Toggling loop ON mid-playback, or changing
   the marks mid-playback, did not re-derive the bounds (it kept looping the
   whole sequence). Fixed with:
   - `_playbackFullEnd`: the un-clamped sequence range recorded in
     `startPlayback` (reset in `stopPlayback`).
   - `applyLoopRangeToBounds()`: the mark-clamp math, extracted from the inline
     block in `startPlayback`.
   - `applyLoopPlaybackBounds()`: called from `toggleLoop` (loop-ON), and from
     `setWorkIn`/`setWorkOut`/`clearWorkRange`; only acts while sequence
     playback is running and loop is on — re-derives bounds from the current
     marks, pulls the playhead inside the range (wraps to In if past Out).
     Loop-OFF leaves the current bounds untouched (matches prior behavior).
3. **Test:** editor-smoke block: start playback loop-OFF (assert full-sequence
   bounds), toggle loop on mid-flight (bounds instantly [0.5, 0.9], wraps at
   Out), move Out to 0.7 while looping (wrap point re-bounds live). All pass.
4. **Follow-up bug (user report): resume path skipped the loop bounds.**
   Sequence: play once WITHOUT loop → pause → enable loop + set marks → Play
   again. The resumed transport kept the stale `[0, full-sequence]` bounds and
   `loopPlaybackRestart` rewound to the sequence start instead of the In
   marker. Two causes: `resumePlayback` never called `applyLoopPlaybackBounds`,
   and that helper early-returned while `!_playbackRunning`. Fixed: the helper
   now guards on `_playbackAsset is null` (works while paused/idle too), and
   `resumePlayback` calls it after pending-seek handling. editor-smoke
   regression: play loop-off → pause → enable loop+marks → resume → bounds
   become [0.5, 0.9] and wrap at Out. Passes.
5. **How to test live in the GUI:** set I/O marks (Shift+I / Shift+O at the
   playhead), enable Loop, press Play → playback confines to the markers and
   wraps. Toggling Loop or moving the markers during playback re-bounds it
   immediately. To exercise the resume path: play without loop, pause, enable
   loop + set marks, press Play again.

### Undo/redo for In/Out marks + free playhead drag (2026-08-18, 5th pass)

Two user requirements: (1) Undo/Redo must track removal/restoration of the
timeline In/Out marks; (2) the timeline playhead must be draggable outside the
bounds of playback.

1. **Undo/redo of marks.** `TimelineSnapshot` now stores the work-area state
   (`hasWorkIn/workIn/hasWorkOut/workOut`). `captureTimelineSnapshot` reads it,
   `applyTimelineSnapshot` restores it (re-syncing `_timeline.setWorkArea` and
   re-deriving loop bounds via `applyLoopPlaybackBounds`). `setWorkIn`,
   `setWorkOut`, and `clearWorkRange` capture a snapshot BEFORE mutating and
   call `commitHistory`, so every mark change becomes one undo step. Note this
   makes marks part of the regular undo stack — any test that assumed the
   stack was empty after a single undo of a clip edit must be updated.
2. **Free playhead drag.** The playhead is a free cursor limited only by the
   full sequence:
   - `seekPlayback`: clamp is now `[0, _playbackFullEnd]` (full sequence),
     never `[_playbackStart, _playbackEnd]`.
   - `commitPendingSeek`: a target outside the active playback range (e.g.
     dragged past the loop Out marker) parks the transport there — stops
     playback and shows a still — instead of clamping/wrapping it into the
     range.
   - onTick end-of-playback check: guarded with `!_seekPending` so a mid-drag
     position past the Out marker never wraps the playhead mid-gesture.
   - Pressing Play from a parked outside position re-enters the loop range via
     `applyLoopPlaybackBounds` (position wraps to the In marker).
3. **Test method (editor-smoke):** mark undo/redo is exercised with
   `setWorkInForTesting`/`setWorkOutForTesting`/`clearWorkRangeForTesting` then
   clicking the real Undo/Redo buttons and asserting `hasWorkInForTesting`/
   `workInForTesting`/`workOutForTesting`. Free-playhead is exercised with
   `seekForTesting` + `tickTree` to let the pending seek auto-commit, then
   asserting the parked position is kept outside the loop range.
4. **Verified:** `dub test` 33 modules, editor-smoke, synced-preroll-smoke,
   static-sequence-smoke all pass; `aurora-cut.exe` rebuilt at the repo root.

### Snap toggle button blue accent (2026-08-18, 6th pass)

The sequence header's snap toggle now shows its active state with the blue
accent background, matching the Loop transport button.

1. `_snapButton` (id `timeline-snap`) is stored as a field; `updateSnapButton()`
   applies `setAccent(snappingEnabled)` on every toggle and once after the
   timeline is built (snapping starts enabled, so it is blue from launch).
2. **Pixel-level test method:** the button accent is verified by sampling a
   background pixel just above the vertically-centered text against the dark
   theme accent `0x4f8cff`. Gotcha: after `driver.click`, the pointer stays
   over the button so it paints `accentHover` — call `driver.moveTo(Point(0,0))`
   before sampling to get the plain accent.
3. Test asserts: blue while on → not blue after toggle-off → blue again after
   re-enable, plus `snappingEnabledForTesting()` and the On/Off label.
