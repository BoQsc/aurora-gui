# Testing Progress and Methods (Aurora Cut)

## Aurora OpenCode startup conversation scrollbar (2026-08-11)

The OpenCode headless smoke test now creates an isolated persisted state with
25 conversations and the last conversation selected before constructing the
window. It paints the initial tree and asserts the restored selection remains
selected while the conversation `ListView` scroll offset is still zero. Run:

```
dmd -version=AuroraHeadless -i -Isource -I..\vendor\aurora-d-0.4.5\source tests\headless_smoke.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\headless-smoke.exe
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
