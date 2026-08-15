## Portable Windows CRT linkage

- Every Aurora DUB package provides a `portable-release` build type that passes
  `-mscrtlib=libcmt` for Windows DMD and LDC builds.
- Portable release executables therefore contain the Microsoft C runtime instead of
  importing `MSVCR120.dll` or requiring the Visual C++ Redistributable.
- Ordinary local builds remain compatible with standalone DMD. Portable builds
  need only the individual MSVC x64/x86 tools and Universal CRT SDK components;
  the complete Desktop development workload is unnecessary.
- `scripts/verify-windows-portability.py` enforces the manifest setting and can
  inspect final PE imports.
- `scripts/build-portable-windows.py` provides the same build-and-verify path
  locally and in the manually triggered GitHub Actions workflow.

## Aurora GUI-subsystem link (no attached console window)

- DMD links executables as console-subsystem binaries by default, so Windows
  attaches a cmd/console window to every Aurora GUI program on launch.
- GUI packages should link with `/SUBSYSTEM:WINDOWS` **and** keep
  `/ENTRY:mainCRTStartup` so `main(string[] args)` still runs (without the
  explicit entry, the linker looks for `WinMain` and fails).
- Documented in the top-level `README.md`; applied in `aurora-opencode/dub.json`
  and `aurora-opencode-pro/dub.json`.
- Console-subsystem CLI/tests stay console so their stdout still works.

## Aurora Windows GUI-subsystem policy (taskbar icon)

Every windowed Aurora app must link as the Windows GUI subsystem
(`lflags-windows: ["/SUBSYSTEM:WINDOWS", "/ENTRY:mainCRTStartup"]`). A
console-subsystem GUI app opens a console window on double-click that claims
the taskbar button with an exe-path title and no icon, even though the real
window's icon is set via WM_SETICON/class icons. GUI-subsystem keeps only the
real window in the taskbar.

- `scripts/verify-windows-gui-subsystem.py` enforces this across every DUB
  recipe (headless `AuroraHeadless` test configs are exempt and stay console).
  Wired into the portable-windows CI workflow.
- Applied to aurora-cut, aurora-stream (`application` + `titlebar`), and the
  aurora-d demos. Apps that also need stdout for CLI diagnostics
  (`--version`, audio-bridge/pacing tests) call `AllocConsole` + `freopen` on
  demand instead of keeping the console subsystem.
- `aurora.platform.win32` additionally publishes the loaded icon to the window
  class (`SetClassLongPtr GCLP_HICON/GCLP_HICONSM`) and re-applies the icons
  after the window is shown via a one-shot timer, so Explorer picks up the
  application icon for the taskbar button.

## Aurora frameless-window drag fixes

- `aurora.window.refreshResizeProxyFromScene` now copies the software
  renderer's surface pixels into the privately-owned `_resizeSnapshot` instead
  of aliasing the live surface. The resize proxy previously presented garbage/
  black frames during the modal move/resize loop once the renderer reallocated
  that surface for the next framebuffer size.
- Frameless windows should move owner-side (`onDragMoved` +
  `setWindowPosition`) rather than through the OS caption loop
  (`beginSystemMove`): the caption loop's aero-snap flashes the native frame on
  drag-to-top, and it armed the fragile proxy path during the move. The demo
  (`demos/titlebar.d`) now drags with a pointer-DELTA formulation
  (`windowOrigin + (pointer − startPointer)`) because Aurora pointer positions
  are window-relative while window bounds are screen positions; the delta-based
  form keeps the synthesized WM_MOUSEMOVE feedback loop at zero delta (no
  shaking).

## Aurora TitleBar restore-on-drag (drag down to leave maximize)

- `aurora.widgets.titlebar.TitleBar` now supports restore-on-drag: pressing the
  title while `_maximized` and dragging past the movement threshold fires
  `onRestoreRequested(pointer, pressPointer)` (owner leaves maximized/
  fullscreen), clears the bar's maximized state, re-anchors the drag to the
  current pointer/position, and continues moving. Works for both in-canvas
  owner/self-move drags and native system move (`systemMoveOnDrag`): the system
  move loop is now deferred until real movement when the bar is maximized so it
  can restore first.
- Added `NativeWindow.setWindowPosition(Point)` / `GuiWindow.setWindowPosition`
  (Win32 `SetWindowPos`, headless/base return false) so the owner can re-anchor
  a restored window under the pointer before the move loop resumes.

## Aurora frameless-window white frame border

Frameless resizable Aurora windows are created as `WS_POPUP | WS_THICKFRAME`
(WS_THICKFRAME is required for native borderless resize). DWM therefore draws a
1px frame around the window, and because `applyDarkTitleBar` was only invoked
for decorated windows, that frame used the **system-light** border color
(white on light themes). It repainted on every activation change
(`WM_NCACTIVATE`), producing a random-looking white border / blink around the
window on click-focus.

- `aurora.platform.win32` now applies the dark DWM frame attributes
  (`DWMWA_USE_IMMERSIVE_DARK_MODE`, `DWMWA_BORDER_COLOR`, `DWMWA_CAPTION_COLOR`,
  `DWMWA_TEXT_COLOR`) whenever `darkTitleBar` is set **or** the window is
  frameless, so the border is a stable dark color instead of the light frame.
- `WM_NCACTIVATE` returns `TRUE` for frameless windows, telling DWM not to
  repaint the frame on activation changes (the Aurora surface paints
  active/inactive state itself).

## Aurora custom TitleBar widget

- Added `aurora.widgets.titlebar` with the fully customizable `TitleBar`
  widget: title/icon/title-align, per-button caption controls (minimize /
  maximize / close, each showable independently), drag (in-canvas self-move,
  owner `onDragMoved`, or native OS move), double-click maximize, right-click
  system menu, custom content widget slot, and full color control. Exported
  from `aurora.package`.
- `aurora.widget.WidgetHost` gained `bool beginSystemMove()` and
  `Widget.beginSystemMove()` so a titlebar in a frameless window can start the
  OS move loop; `GuiWindow` now exposes it as an `override`.
- Demo: `demos/titlebar.d` (`dub build --config=titlebar`), launcher
  `RUN-AURORA-D-TITLEBAR.cmd`.
- Headless coverage: `tests/titlebar_smoke.d` in the aurora-gui app.

## Aurora TitleBar drag-to-snap

- `aurora.widgets.titlebar.TitleBar` now provides aero-style drag snapping.
  While a titlebar drag is active the widget samples the real screen pointer
  (`queryPointerScreenPosition`) against the monitor work area
  (`queryWorkArea`, `MonitorFromPoint` + `GetMonitorInfoW` `rcWork`), and maps
  it to a `TitleBarSnapTarget`: top = maximize, left/right = half-screen,
  corners = quadrants, bottom edge alone never snaps (platform standard). A
  `snapThreshold` (default 8 logical px) sets the edge-engagement distance and
  `setSnapEnabled(false)` disables the whole engine.
- New delegates `onSnapChanged(target, bounds)` (fires on every target change
  including back to `none`, for showing/hiding a preview) and
  `onSnapApplied(target, bounds)` (fires on release over a live zone; the owner
  applies `bounds` and updates its maximize/restore state). Releasing over a
  zone skips the final drag-move so the window never lands on the last pointer
  position first.
- New reusable `TitleBarSnapPreview` overlay widget (translucent rounded
  preview) exported from `aurora.package`. IMPORTANT: it is created
  **disabled** (`setEnabled(false)`) so it paints on top but is transparent to
  hit testing (`Widget.hitTest` skips disabled widgets). A full-size, enabled
  overlay added as the last child of the root would swallow every click meant
  for the titlebar/content beneath it — this exact regression is covered by
  `tests/titlebar_smoke.d` (caption buttons and drag must still work with the
  preview present).
- New platform plumbing for snap: `NativeWindow.queryWorkArea(Point, out Rect)`
  + `setWindowBounds(Rect)` (Win32 `SetWindowPos` size+move, headless
  records), `GuiWindow.queryWorkArea`/`setWindowBounds`, and
  `WidgetHost.queryPointerScreenPosition`/`queryWorkArea` (with `Widget`
  helpers) so the widget can sample the cursor and monitor without an owner
  lookup. System-move drags (`systemMoveOnDrag`) intentionally leave snapping
  to the OS move loop.
- Wired into `demos/titlebar.d` and the Aurora Stream custom-titlebar app
  (`aurora-stream/source/app_titlebar.d`).
- Restore-on-drag (drag a maximized window down to unmaximize) is hardened:
  after `onRestoreRequested` the widget sets `_snapSuppressed` +
  `_snapSuppressedZone` so releasing inside the zone the window just restored
  from cannot snap it straight back to maximized (snapping resumes as soon as
  the pointer leaves that zone). Both apps save the pre-maximize bounds and
  restore to them whether the window was maximized via caption/double-click
  fullscreen or drag-snap-to-top (work-area only, never fullscreen), instead of
  blindly calling `toggleFullscreen()`.
- Headless coverage: `tests/titlebar_smoke.d` exercises left-edge, top-edge
  (maximize), preview-clear, disabled, the input-transparency regression, the
  no-snap-back-after-restore regression, and `TitleBarSnapPreview` paint
  through `UiTestDriver.setTestWorkArea` / `setTestScreenPointerPosition`; the
  widget module unittest covers the pure target/bounds mapping including
  corners and non-zero work-area origins.

## Aurora live-resize proxy improvements (distorted frame while resizing)

The stretched/distorted frame shown while dragging a border on the Software (or
Vulkan-without-present-scaling) renderer path was pre-existing: the live-resize
proxy presented one frozen snapshot stretched with `StretchDIBits` (nearest-
neighbor) for the whole drag. Two improvements to that fallback:

- `aurora.platform.win32` `presentScaledResizeFrame` now uses `HALFTONE` stretch
  mode with a `SetBrushOrgEx` origin reset, so the stretched preview is
  interpolated rather than blocky.
- `aurora.window` schedules exact frames during resize on the non-scaling path
  too: `onNativeTick` / `scheduleLiveResizeExactFrame` no longer gate on
  `liveResizeScalingSupported()`, keeping the same 1/60 s cadence; after each
  exact frame the proxy snapshot is re-armed from that frame so proxy frames
  show current content instead of the pre-resize frame.

The Vulkan path with native WSI surface scaling is unchanged (the driver
stretches the last image itself and no proxy frame is presented).

## Aurora Cut 0.13.3 title-layer opacity

- Title opacity is now represented explicitly as final layer opacity.
- Fill, stroke, shadow, underline, and box share that layer value.
- Repeated stroke/shadow passes use inverse source-over alpha distribution so they do not accumulate back toward opaque.
- Export applies opacity once after Aurora rasterizes the complete title layer.

## Aurora Cut 0.13.2 title-selection cleanup

- Live title character selection now collapses on focus loss, on direct-edit completion, and when the Composition Preview background is clicked outside the title.
- Canvas-title selection painting is additionally gated by active focus, so retained logical state cannot leak a blue selection highlight into the read-only composition view.
- Read-only title synchronization defensively clears stale ranges.

## Aurora Cut 0.13.1 title renderer build fix

- Added the missing selective import for `max`, used to position title underlines.
- No fallback to the old double-render text path was introduced.

## Aurora Cut 0.13.0 live-title renderer

- Removed `PreviewFrameRole`, title-free editing-frame cache identities, delayed reveal, and final-frame title swaps.
- `PreviewWidget` permanently receives text-free RGB video/image backgrounds and owns persistent `PreviewTitleEditor` children for active title clips.
- A title layer remains the same widget object in display and editing states. Editing only enables its existing `TextEditor` input, caret, selection, and hit-testing behavior.
- Added `aurora.text.titlepaint`, shared by live preview titles and worker-side export rasterization.
- Added `auroracut.titlelayer`, which resolves the exact authored font, shapes the title through Aurora `TextLayoutEngine`, paints effects into a transparent `Surface`, and writes straight-alpha PAM for FFmpeg overlay.
- Extended `aurora.widgets.texteditor` with canvas-title mode, selected font/pixel size, title paint effects, complete content measurement, and non-scrolling direct-canvas behavior.
- Extended `aurora.surface` with RGBA PAM output and `aurora.canvas` with an explicit worker-local `FontSystem` constructor.
- Interactive FFmpeg commands skip all generated text. Final export prepares Aurora title rasters and contains no FFmpeg `drawtext` filters.

## Aurora Cut 0.11.6 font-selection state repair

- Replaced font-menu delegates created directly in `foreach` loops with callback factories. D captures the reused loop slot, which caused every font item to invoke the final `Sans` selection.
- Both the Composition Preview and Inspector font menus now retain independent family values.
- Inspector font dropdown text and checkmarks are synchronized from the selected text clip in the model.
- Added UI regression coverage for selecting Arial, retaining its checkmark, then selecting Impact.

# Aurora-D integration patches

Aurora Cut vendors the supplied Aurora-D 0.4.5 source and applies a small set of application-level extensions. No replacement GUI or media library is introduced.

The patched Aurora modules are:

- `aurora.event`, `aurora.widget`, `aurora.window`, `aurora.platform.win32`, and `aurora.testing`: native multi-file drop events, Windows `WM_DROPFILES` handling, normal widget bubbling, and headless test injection.
- `aurora.widgets.listview`: public item hit-testing and scroll-offset access needed for Project Media dragging.
- `aurora.widgets.splitpane`: immediate subtree relayout while dragging and bounded child sizing.
- `aurora.widgets.contextmenu`: cursor-adjacent top-left anchoring, compact 22-pixel rows, reduced menu width, and scrolling for long menus near window edges.
- `aurora.widgets.texteditor`: direct canvas-title mode, per-editor font/size/color, shared title effects, content measurement, caret/selection/hit testing, and non-scrolling live-title editing.
- `aurora.canvas`, `aurora.render.drawlist`, `aurora.render.software`, and `aurora.render.vulkan`: retained RGB24 image commands used for internal video preview. The software renderer provides exact-size RGB-to-ARGB conversion and fixed-point nearest/bilinear scaling. The Vulkan backend safely skips the CPU-only RGB batch.

`vendor/aurora-d-0.4.5/MANIFEST.sha256` is regenerated from the vendored files after these changes, so it validates the exact source shipped with Aurora Cut rather than the untouched upstream archive.

## Font-file integration

Aurora Cut resolves each built-in Windows title family to an exact system font
file. The live Composition Preview title and Aurora export rasterizer load that
same file, avoiding family-name fallback where multiple choices could otherwise
render through one default face. Per-user Windows fonts and explicit `.ttf`,
`.otf`, or `.ttc` paths are checked first.
