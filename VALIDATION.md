# Aurora Cut validation record

The existing baseline validation below was run for earlier revisions with generated MP4/MP3 fixtures, the supplied Aurora-D 0.4.5 library, FFmpeg, and LDC. Aurora Cut 0.13.3 retains the live-title architecture, keeps the 0.13.2 focus-selection cleanup, and adds source/unit regressions for final title-layer opacity and repeated stroke/shadow alpha composition. This packaging environment does not contain DMD, LDC, or DUB, so a successful 0.13.3 application compilation is not claimed here.

## Behavior covered

- Empty-project construction, layout, paint, startup logging, and shutdown.
- Absence of redundant Stop, Import, and Add-selected buttons.
- Windows-style multi-file import routing, duplicate filtering, unsupported-file rejection, and direct File Explorer drop onto a timeline track/time.
- Background FFprobe import, pending timeline placement, and cache-only source-frame warming.
- Project Media to V/A drag, horizontal and cross-track movement, and dynamic track creation.
- Ctrl+C copy, Ctrl+V paste at playhead, Ctrl+D duplicate, and context-menu equivalents.
- Clip-edge resizing for text and media, collision/source limits, unique IDs, and absolute-time keyframe preservation.
- Timeline-only Composition Preview: selecting Project Media cannot replace or lock the monitor to source playback.
- Playhead consistency for ruler clicks, tools, scrub commit, pause, playback completion, Inspector evaluation, and frame requests.
- Plain one-video timeline direct passthrough without a composition-render wait.
- Live multi-layer composition without a pre-rendered playback proxy.
- Static scrub and live timeline rendering use title-free RGB backgrounds; persistent Aurora title layers use the same shaping/paint code as the RGBA title rasters prepared for export.
- Contextual per-item Inspector sections, visible property/value rows, explicit Reset and ◇ Key / ◆ Key controls, individual defaults, complete effect reset, continuous-edit copy-on-write behavior, and bounded undo history.
- Timeline keyframe markers, remove command, Linear/Bezier/Hold interpolation, and automatic additional keyframes on animated properties.
- Text duration-drag placement, no creation from click-only input, real keyboard text entry without duplicate items, Space-key shortcut suppression while typing, existing-item selection, green text-item rendering with ellipsis, timeline/Preview double-click editing, single-surface direct Preview title editor and B/I/U/font/size/color controls, checked Preview font dropdown, hidden duplicate Inspector content input, and Preview canvas dragging.
- `.auroracut` project JSON round-trip for media metadata, text family/style/color, track height, keyframes/interpolation, playhead, work range, and Preview quality.
- Double-click-and-drag timeline marquee selection across multiple items while preserving ordinary single-drag playhead scrubbing.
- Position, scale, rotation, opacity, gain, and text-size keyframes.
- Blur, stroke, drop shadow, fade-in/fade-out, fonts, text colors, and text box graph generation.
- dB gain and mute on audio clips and video clips containing embedded audio.
- Optional embedded-audio display on the matching A track, plus real audio detachment preserving trim/gain/fades/volume keyframes while muting duplicate embedded audio.
- Rapid seek/scrub coalescing, settled background graph refresh, stale-process cancellation, split/move gap audio-boundary scheduling, and one automatic retry for an immediately failing preview-audio process.
- Internal RGB video display, MP3 waveform display, and 1080p frame conversion.
- H.264/AAC MP4 and MP3 sequence exports.
- Compact 22-pixel context-menu rows and bounded menu width.
- Timeline hit-testing and visible-range paint on a 20,000-clip track.

## Acceleration boundary

Aurora Cut runs a real tiny FFmpeg encode to select `h264_nvenc`, `h264_qsv`, or `h264_amf`; it otherwise uses `libx264`. A failed hardware job receives one CPU fallback attempt.

The current FFmpeg overlay/effect composition graph is CPU-based. Aurora-D 0.4.5 switches RGB video-frame presentation to its software compositor because the current Vulkan backend does not draw that RGB image batch. This release therefore claims hardware H.264 encoding only—not full-GPU composition or display.

## Commands used

```sh
DC=ldc2 ./scripts/verify-model.sh
DC=ldc2 ./scripts/verify-renderer.sh
DC=ldc2 ./scripts/verify-playback-stress.sh
DC=ldc2 ./scripts/verify-headless.sh
DC=ldc2 ./scripts/verify-export.sh
dub clean
dub build --compiler=ldc2 --build=debug
dub build --compiler=ldmd2 --build=debug
```

The complete imported source graph is also compiled for `x86_64-pc-windows-msvc`. Native Windows File Explorer dropping, Windows audio output, actual hardware-encoder selection, and the final linked GUI executable still require execution on a Windows desktop.

## 0.11.0 validation

- Linux LDC debug build completed successfully.
- Multi-track model smoke test passed.
- Retained 1080p RGB renderer smoke test passed.
- Rapid playback/still-request coalescing stress test passed.
- Full headless editor interaction smoke test passed.
- H.264/AAC MP4 and MP3 export smoke test passed.
- New project format v2 retains reverse and speed fields while loading v1 projects.


## 0.11.1 validation

- Added a project-save regression test containing NaN and positive/negative Infinity in playhead, work range, media metadata, clip transform, and keyframe data.
- Confirmed the saved project remains standard JSON and reloads with finite values.
- Confirmed the visible preview transport labels are single words.


## 0.11.2 validation

- Verified that moving a timeline item during active sequence playback leaves playback active and starts no replacement video-decoder process.
- Verified that the edited model revision is deferred while the active immutable playback snapshot continues, then is adopted on Pause/Resume or a new Play.
- Verified Composition Preview’s context menu contains Add text.
- Verified timeline item selection does not change the playhead.
- Verified the timeline context menu is positioned upward from the pointer using its bottom-left anchor.
- Verified tooltips for Selection, Cut, Text, and Transition.
- Verified Effects / Properties contains no Slider widgets and that direct horizontal value scrubbing changes the selected item property.
- Re-ran model, retained renderer, playback stress, full editor interaction, H.264/AAC MP4, and MP3 tests.
- Rebuilt with LDC and LDMD compatibility mode and compiled the complete imported source graph for `x86_64-pc-windows-msvc`.


## 0.11.3 validation

- Added an editor interaction regression that sends Space key-down while the inline title field is focused, verifies playback remains stopped, then delivers the printable space text-input event.
- Added an interaction regression for the Composition Preview font dropdown, including Arial, Tahoma, and Verdana selection coverage.
- Added export regressions comparing otherwise-identical frames with and without generated-title shadow, and comparing two selected font faces.
- Direct FFmpeg frame checks confirmed the corrected shadow graph changes 16,186 bytes and two distinct font files change 10,506 bytes in the generated 320×180 PPM fixture.
- Regenerated the vendored Aurora-D manifest after the TextEditor extension.
- The D compiler was unavailable in this repair environment, so the full D smoke suite remains to be executed with `scripts/verify-headless.sh` and `scripts/verify-export.sh` on a configured LDC/DMD machine.

## 0.11.6 font-selection validation

The font selection path was re-audited from both dropdowns through the selected
`TimelineClip.fontName`, project serialization, `ExportClip.fontName`, exact
Windows font-file resolution, and FFmpeg `drawtext` graph generation.

The failure was in the two menu-building loops: their delegates captured the
reused D `foreach` variable, so every row executed the final `Sans` action.
Both menus now create each action in a separate factory call frame. The editor
smoke test now selects Arial, verifies that Arial remains checked after model
synchronization, then selects Impact and verifies that both the UI and model
change to Impact.

A source-level path verification passed for menu callback isolation, model
storage, project save/load, export request copying, and exact Windows font-file
mapping. A full D compilation could not be run in this Linux container because
no D compiler is installed and package-network access is unavailable.

## 0.13.0 live-title architecture validation

- Checked all project and vendored D files for balanced delimiters, unique module declarations, and resolvable project-local imports.
- Confirmed the source tree contains no `PreviewFrameRole`, delayed title-background/commit state, `PreviewInlineTextField`, or FFmpeg `drawtext` filter.
- Added a preview unit regression proving one title keeps the exact same `TextEditor` object before editing, while editing, and after Done, and that it is not a nested compositor surface.
- Added export assertions proving interactive frame/stream commands contain no PAM/title input while compatibility/final render paths prepare Aurora RGBA title rasters.
- Added a raster-output regression comparing two selected font faces and a title-shadow on/off pair.
- Validated the generated PAM/FFmpeg scale, alpha, animation, rotation, and overlay filter syntax against the installed FFmpeg 7.1.3 executable.
- Regenerated and verified the complete vendored Aurora-D SHA-256 manifest.
- DMD/DUB are unavailable in this container; run `BUILD-WINDOWS.bat` on the target Windows system for the compiler/linker verification.


## 0.13.4 timeline scrollbar validation

- Added a dedicated compact horizontal scrollbar widget below the sequence tracks.
- Added editor smoke coverage requiring the control to remain at most 12 logical pixels high.
- Added coverage that zooms into a fitted sequence, pans to half of the available range, and verifies the thumb becomes shorter than the track and moves away from the origin without changing pixels-per-second.
- Verified synchronization hooks for Fit, zoom, playhead auto-follow, horizontal wheel scrolling, drag-edge auto-scroll, timeline bounds changes, label-column resizing, and sequence-duration changes.
- Re-ran live-title architecture source checks, project delimiter checks, project-local module/import resolution, and the complete 142-file vendored Aurora-D SHA-256 manifest.
- DMD/DUB are unavailable in this container, so the linked Windows executable still requires native verification through `RUN-WINDOWS.bat`.


## 0.13.5 Out-first export-zone validation

- Added an editor smoke regression that sets Out before In and requires both work-area markers to become active.
- Verified the implicit In value is exactly the timeline start while the requested Out value is preserved.
- Verified keyboard O, the export context-menu action, and timeline requests all use the same `setWorkOut` path.
- Added project-load normalization for older Out-only work areas.
- DMD/DUB are unavailable in this container, so native Windows compilation still requires `RUN-WINDOWS.bat`.


## 0.13.5 yt-dlp native-resolution download validation

- Confirmed the download normalization previously padded every yt-dlp video onto a fixed canvas
  (`pad=1920:1080:(ow-iw)/2:(oh-ih)/2`), so a source with a small native width (or a non-16:9
  aspect) was delivered at the selected ceiling's frame size instead of its own resolution.
- Removed the `pad` from `ytDlpVideoNormalizeFilterForHeight`; the scale filter now only downscales
  when a dimension exceeds the selected ceiling and otherwise keeps the source resolution and aspect.
- Verified with real FFmpeg encodes that 640×360, 720×1280 portrait, 2560×1440, and 1024×768
  sources now produce 640×360, 608×1080, 1920×1080, and 1024×768 outputs respectively — never
  upscaled, never letterboxed, always divisible by two.
- Updated `tests/ytdlp_format_smoke.d` to assert the filter contains no `pad=` and that the optional
  end-to-end normalization run must never upscale the input and must stay within the ceiling.
- Rebuilt with DMD/DUB on Windows and ran the updated smoke test against all four fixture videos.


## 0.13.5 yt-dlp download progress validation

- The download service previously ran yt-dlp with --no-progress and only surfaced a final result, so the UI never showed progress.
- Removed --no-progress (keeping --newline) and parse each '[download] NN%' stdout line in the worker, pushing YtDlpDownloadProgress samples through a mutex-guarded queue.
- The editor drains the progress queue each tick and updates the shared status-bar ProgressBar with 'Download NN%'; it returns the bar to Idle once the queue drains (unless an export job is using it).
- Verified with a real download: 11 monotonic progress samples reaching 100.0%, then a successful normalized MP4 import. Added tests/ytdlp_progress_smoke.d for this.
- DMD/DUB native Windows build succeeds; the pre-existing editor-smoke compression assertion failure at line 432 is unrelated and reproduces on the clean base commit.
