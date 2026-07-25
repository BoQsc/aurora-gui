# Fullscreen and interaction latency

Aurora-D 0.4.2 combines the existing renderer-independent fullscreen contract with a retained Aurora compositor and input scheduling designed for immediate pointer-driven presentation.

## Public API

```d
WindowOptions options;
options.startFullscreen = false;
options.enableFullscreenShortcut = true;
options.lowLatency = true;
options.vsync = true;

auto window = new GuiWindow(options);
window.setFullscreen(true);
window.toggleFullscreen();
assert(window.fullscreen());
```

The standard shortcuts are:

- F11: toggle fullscreen.
- Alt+Enter: toggle fullscreen.
- Escape: leave fullscreen.

Applications can disable Aurora's shortcut handling with `enableFullscreenShortcut = false`. The native state API remains available when shortcut handling is disabled.

Environment overrides accept `1`, `0`, `true`, `false`, `on`, `off`, `yes`, and `no`:

```text
AURORA_FULLSCREEN
AURORA_LOW_LATENCY
AURORA_SYNC_DRAG_POINTER
AURORA_VSYNC
```

## Platform behavior

### Windows

Aurora uses borderless monitor fullscreen without changing the display mode. Entering fullscreen saves the current Win32 style, extended style, and `WINDOWPLACEMENT`, removes the overlapped frame, applies `WS_POPUP`, and resizes to the nearest monitor's `rcMonitor`. Leaving fullscreen restores the saved placement and styles, including a prior maximized state. Per-Monitor-V2 scale changes continue to rebuild the physical software surface or Vulkan swapchain.

The Win32 loop processes a bounded message batch instead of draining an unlimited mouse-motion stream. When a pointer, resize, paint, wheel, or DPI message dirties the frame, low-latency mode stops the batch and paints the newest state immediately. `MsgWaitForMultipleObjectsEx` replaces the former unconditional sleep, so queued input or Aurora's private invalidation message wakes the loop immediately. While a transform drag has a pending presentation, the loop performs a zero-timeout message check and `SwitchToThread` rather than putting the frame behind a nominal one-millisecond timer.

Windows enters an internal modal loop while the user drags or resizes a top-level frame. Aurora handles `WM_ENTERSIZEMOVE` and `WM_EXITSIZEMOVE`, starts a 16 ms live-resize timer, and paints from `WM_TIMER`, `WM_SIZE`, and `WM_PAINT` during that modal interval.

### Linux/X11

Aurora uses the EWMH `_NET_WM_STATE_FULLSCREEN` state. A requested initial state is attached before mapping; a runtime transition sends the standard `_NET_WM_STATE` client message. Input batches are bounded and low-latency mode yields to painting after pointer motion dirties a frame.

### macOS

Aurora delegates fullscreen transitions to AppKit's `toggleFullScreen:` and observes enter/exit delegate notifications. Logical layout and physical framebuffer sizing continue to follow the backing scale.

### Headless

The headless backend records fullscreen state without changing its deterministic surface dimensions. This permits public API and shortcut tests without a window manager.

## Internal desktop-window dragging

Desktop Environment windows remain Aurora widgets inside one native host window. They are now independently retained compositor layers rather than geometry rebuilt into one transient desktop draw list.

For a position-only drag, `FloatingWindow.setPosition` emits a transform invalidation. The base desktop, window contents, text layouts, glyphs, and local geometry remain unchanged. Vulkan reuses persistent buffers and changes dynamic viewport/scissor state; software reuses a cached transparent window surface. Aurora also reuses its cached layer order.

The Win32 message loop collapses consecutive queued `WM_MOUSEMOVE` records to the newest position while preserving ordering around non-motion messages. Pointer events retain subpixel logical coordinates, so fractional DPI does not quantize several physical mouse pixels into one logical step.

During an active retained-window drag, Aurora keeps a presentation opportunity pending and samples `GetCursorPos` after Vulkan has acquired an image, immediately before command recording. That late sample changes only layer transforms. The Win32 host cursor is hidden and a vector Aurora pointer is drawn as the final retained layer, so the visible pointer and moved window enter the same submitted frame. `AURORA_SYNC_DRAG_POINTER=0` disables that comparison path.

The invariants are verified by `tests/compositor.d`, `tests/latency.d`, and the required-Vulkan smoke. See [Input-to-presentation latency](INPUT_LATENCY.md) and [Retained compositor](RETAINED_COMPOSITOR.md).

## Vulkan presentation policy

With `vsync = true` and `lowLatency = true`, Aurora selects `VK_PRESENT_MODE_MAILBOX_KHR` when the device and surface expose it, then FIFO-relaxed, then required FIFO. MAILBOX requests three images when surface limits permit so a pending image can be replaced while one image is displayed. With `vsync = false`, Aurora prefers immediate presentation, then mailbox, then FIFO.

MAILBOX and IMMEDIATE use two command/fence/acquire contexts for overlap; ordered FIFO modes use one submit context so Aurora does not deepen their queue. Render-finished semaphores are owned by swapchain image rather than frame context. Content/atlas mutation waits for every in-flight fence, while transform-only frames share immutable retained resources.

The policy avoids an Aurora-side queue of old interaction states. Final scanout still follows the selected Vulkan presentation mode and the host display stack. Aurora does not use exclusive fullscreen or alter the monitor refresh mode.

## Software renderer

The software path recognizes common axis-aligned quads and also retains one rasterized surface per compositor layer. A drag copies the base and composites the already-rasterized window at its new position. Content changes still use the common draw-list semantics, direct spans where applicable, and nearest A8 atlas coverage.

## Acceptance checks on Windows

Use optimized builds for interaction testing. DUB's default debug build retains bounds checks and deliberately favors diagnostics over software-rasterizer throughput. The Desktop Environment title reports the backend that was actually selected. Test both modes because automatic Vulkan fallback can vary by machine:

```powershell
dub clean
$env:AURORA_RENDERER = "software"
dub run --build=release --config=desktop --force

$env:AURORA_RENDERER = "vulkan"
dub run --build=release --config=desktop --force
```

Check F11, Alt+Enter, and Escape; enter fullscreen from both normal and maximized states; move the window between monitors with different scale factors; drag an Aurora floating window rapidly; and resize the native frame continuously. The restored window should return to its prior monitor placement and state. If required Vulkan initialization fails, Aurora reports the reason instead of silently measuring the software fallback.
