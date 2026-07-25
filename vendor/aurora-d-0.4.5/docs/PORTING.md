# Porting Aurora-D

Aurora isolates operating-system window/event code from widgets, Unicode layout, font parsing, and renderer-neutral geometry. A new platform can first provide software presentation, then expose native handles to Vulkan or another draw-list backend.

## NativeWindow contract

Implement `aurora.platform.base.NativeWindow`:

```d
abstract class NativeWindow
{
    abstract void show();
    abstract int run();
    abstract void invalidate();
    abstract void present(const(uint)[] pixels, int width, int height);
    abstract void setTitle(string title);
    abstract void setCursor(CursorKind cursor);
    abstract void setFullscreen(bool value);
    abstract bool fullscreen() const;
    abstract void close();
    abstract Size clientSize() const;       // 96-DPI logical units
    Size framebufferSize() const;             // native pixels
    DisplayScale displayScale() const;

    NativeSurfaceInfo nativeSurfaceInfo();
}
```

Translate native events to `aurora.event.Event` and call the associated `NativeWindowSink`.

Required lifecycle:

1. Create the native window and client surface.
2. Emit logical client size, physical framebuffer size, and display scale after showing.
3. Call `onNativePaint()` on invalidation or exposure. It returns `false` when the renderer deliberately deferred a nonblocking frame or when a captured transform requests continuous presentation; keep that paint pending, continue processing input, and retry without placing it behind a coarse frame-length sleep.
4. Call `onNativeTick()` often enough for caret and clock animation.
5. Send key/navigation events separately from committed Unicode text input.
6. Ask `onNativeCloseRequested()` before closing.
7. Call `onNativeShutdown()` before destroying native handles used by a renderer.
8. In software mode, copy the physical-size ARGB buffer supplied to `present()` into the client area without resampling.
9. Implement monitor fullscreen without changing Aurora's logical-coordinate contract, and restore the prior window state on exit where the platform supports it.
10. Ensure invalidation or queued input can wake a sleeping event loop; avoid unbounded input draining that starves `onNativePaint()`.
11. Implement `queryPointerPosition` from current native state when possible. For frame-synchronized drag pointers, implement `setPointerVisible` so Aurora can hide the host cursor during captured transform interaction.

## Events

A complete port should map:

- key down/up and modifiers;
- committed Unicode text input;
- mouse move/down/up and click counts;
- horizontal and vertical wheel deltas;
- focus enter/leave;
- resize/expose;
- close requests;
- pointer cursor changes;
- precise pointer positions in `Event.precisePosition`/`preciseGlobalPosition` when the native API provides fractional or physical-pixel precision.

Aurora editors already handle grapheme boundaries and bidi layout after text reaches the common event layer. Native IME composition/preedit ranges are not yet represented; a port can initially emit only committed text, matching the existing adapters.

## Native surface handles

`NativeSurfaceInfo` is opaque outside platform and renderer code:

```d
enum NativeSurfaceKind { none, xlib, win32, metal }

struct NativeSurfaceInfo
{
    NativeSurfaceKind kind;
    void* handleA;
    void* handleB;
    ulong value;
}
```

Current conventions:

| Kind | `handleA` | `handleB` | `value` |
|---|---|---|---|
| `xlib` | `Display*` | optional `xcb_connection_t*` | X11 window ID |
| `win32` | `HINSTANCE` | `HWND` | unused |
| `metal` | `CAMetalLayer*` | unused | unused |
| `none` | unused | unused | unused |

A platform without supported Vulkan WSI should return `none`; automatic selection then uses software.

## Platform selection

Add the adapter to `aurora.platform.select` with D `version` conditions. Do not import native API declarations into widgets, `Canvas`, the draw list, or text modules.

If the new platform is supported by Vulkan but not by the current renderer, add:

- a `NativeSurfaceKind` and handle convention;
- the required Vulkan structures/function declarations in `aurora.vulkan.api`;
- extension selection and surface creation in `aurora.render.vulkan`;
- runtime smoke tests for resize, minimize/restore, and surface loss.

## Software-first checklist

Validate before acceleration:

- client-size and coordinate mapping;
- invalidation/exposure behavior;
- ARGB channel order and top-to-bottom row direction;
- key versus text-input separation;
- non-ASCII committed input;
- mouse capture and cursor changes;
- focus transitions and close veto;
- decorated, borderless, resizable, fixed-size, maximized, fullscreen, and always-on-top windows;
- fullscreen entry/exit from both normal and maximized state, including monitor-scale changes;
- continuous pointer-driven painting and native live resize without input-queue starvation;
- repeated resize and shutdown without use-after-destroy.

The headless backend is the smallest lifecycle reference. X11, Win32, and AppKit show full event translation.

## Vulkan checklist

- Verify `VK_KHR_surface` plus the platform WSI extension.
- Keep the native handle alive through `onNativeShutdown()`.
- Verify graphics and presentation queue support independently.
- Exercise initial creation, exposure, resize, minimize/restore, and out-of-date swapchains.
- Test FIFO VSync and the no-VSync preference fallback order.
- Run with `VK_LAYER_KHRONOS_validation` during development.
- Test automatic software fallback with the loader, extension, and device intentionally unavailable.
- Do not call `NativeWindow.present()` in Vulkan mode; the swapchain is the presentation path.

## High-DPI behavior

Aurora 0.4.2 exposes a common logical/physical split through `DisplayScale`. Widget bounds and native input events are in 96-DPI logical units. `framebufferSize()` and renderer extents are physical pixels. A resize event must populate `event.size`, `event.framebufferSize`, and `event.displayScale`; identity-scale ports may set both sizes equal.

Convert rectangle boundaries rather than scaling width and origin independently, so adjacent logical rectangles retain a shared physical edge. Convert native pointer coordinates back to logical units before dispatch and preserve the unrounded value in `PointF`; retained transforms should not discard physical pointer pixels at fractional DPI. Rasterize or select glyphs at physical pixel size and present software pixels 1:1.

The Win32 adapter is the monitor-change reference: it declares Per-Monitor-V2 awareness, handles `WM_DPICHANGED`, applies the suggested rectangle, and emits synchronized metrics. On macOS, coordinate conversion must agree with backing scale, `CAMetalLayer.drawableSize`, and the Core Graphics fallback surface. X11 ports may remain identity-scale until a desktop-scale policy is implemented. See [High-DPI rendering](HIGH_DPI.md).

## Fullscreen and interactive scheduling

Every native adapter implements `setFullscreen(bool)` and `fullscreen()`. `WindowOptions.startFullscreen` must work before the first visible map/show operation, while runtime transitions must preserve enough native state to restore the prior decorated, maximized, positioned, and topmost window. Aurora fullscreen is a monitor-filling window state; ports should not change resolution, refresh rate, or color mode unless a separate exclusive-fullscreen API is introduced.

A fullscreen transition normally changes both logical client size and physical framebuffer extent. Emit one coherent resize event after the native transition has settled, keep input coordinates in logical units, and recreate renderer resources from `framebufferSize()`. Avoid exposing intermediate style-change sizes as separate application layouts.

The native event loop must not drain an unbounded input stream before painting. Process a bounded batch, advance timers before the frame they invalidate, and use an input-woken wait primitive rather than an unconditional sleep where the platform provides one. During platform-owned modal move/resize loops, arrange periodic paint/tick delivery so live resize does not freeze. Mouse capture fixes the drag target, so ports should preserve capture until the widget releases it or focus/capture is lost.

A captured transform can request continuous frames even without a new native motion event. `queryPointerPosition` should return the current client-space position, not merely the last delivered event, so `RenderScene.lateLatch()` can update the transform immediately before composition. A backend that successfully hides the host cursor enables Aurora's frame-synchronized pointer layer; otherwise Aurora keeps the ordinary native cursor.

For Vulkan, `lowLatency = true` prefers MAILBOX with three images when supported, FIFO-relaxed/FIFO fallbacks when synchronized, and IMMEDIATE when tearing is allowed. Replacement/non-ordered modes can use two frame contexts; ordered FIFO modes should retain one submit context. Present-wait semaphores must be reused according to swapchain-image lifecycle, not merely a frame fence. Treat present-mode choices as policies rather than guarantees: a compositor or driver can still add queueing.

Add fullscreen acceptance tests for initial state, runtime enter/leave, shortcut handling, restoration from normal and maximized states, monitor changes, DPI changes, renderer resize, and shutdown while fullscreen. See [Input-to-presentation latency](INPUT_LATENCY.md) and [Fullscreen and interaction latency](FULLSCREEN_AND_LATENCY.md).

## Fonts and Unicode

Font parsing, shaping, fallback, Unicode algorithms, and glyph rasterization are platform-neutral and require no native font library.

Port-specific font work is limited to adding useful path candidates in `SystemFonts` and `FontCollection.system`. Candidates may contain:

- TrueType `glyf` outlines; or
- static CFF1 outlines.

Do not assume every system font is supported: CFF2 variable fonts, bitmap-only emoji faces, and color-only faces are intentionally rejected in 0.4.2. Keep the bitmap emergency face as the final fallback.

For reliable application typography, prefer explicit, appropriately licensed font paths over relying exclusively on candidate discovery.

Unicode property data needs no port. It is compiled into `aurora.text.unicode.properties` and regenerated only when updating Unicode versions.

## Build integration

Add only the operating-system libraries required by the native adapter. Vulkan is dynamically loaded, so a Vulkan SDK include directory or Vulkan link flag should not be required.

When adding macOS frameworks, ensure the DUB library and every executable configuration receive equivalent linker flags.

The headless configurations use `version (AuroraHeadless)` and should remain free of native GUI link dependencies.

## Validation matrix

Record at least:

- compiler, architecture, operating-system version, and native SDK/runtime;
- library and every demo build;
- unit, text-system, text-boundary, and Unicode conformance suites;
- software native runtime smoke tests;
- Vulkan runtime smoke tests with device and driver named;
- resize, minimize/restore, close, and repeated font-switching lifecycle;
- custom TrueType and static-CFF loading;
- mixed LTR/RTL input and grapheme deletion;
- compile-only architectures clearly separated from native runtime results;
- unsupported or untestable features.

See `docs/VALIDATION.md` for the release's recorded matrix.
