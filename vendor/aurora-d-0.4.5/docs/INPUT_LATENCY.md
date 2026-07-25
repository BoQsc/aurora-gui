# Input-to-presentation latency

Aurora-D 0.4.2 treats pointer-driven movement as a presentation problem rather than a widget repaint problem. Floating windows remain Aurora-rendered layers inside one host surface, but a normal drag does not rebuild their content. The interaction path preserves native pointer precision, samples the newest pointer immediately before composition, and presents a frame-synchronized Aurora pointer with the moved layer on Windows.

## Interaction target

The library cannot remove mouse-device, display-scanout, or panel latency. Its enforceable target is that Aurora adds no avoidable content work or stored interaction queue between the newest sampled pointer and the submitted compositor frame.

For an already-rendered retained window, one drag frame has this contract:

```text
widget layout                 0
widget paint traversal        0
text shaping                  0
glyph rasterization           0
primitive tessellation        0
vertex/index upload           0
layer-order rebuild           0
native pointer samples        1
captured-layer transforms     0 or 1
compositor submissions        1
```

A transform changes only device-space placement. Content is rebuilt only when the window's controls, text, dimensions, theme, DPI-dependent local surface, or glyph atlas actually change.

## Why a retained window could still appear behind the cursor

The operating system can update its hardware cursor independently of an application-rendered swapchain. Even a fast compositor frame can therefore appear one refresh behind that cursor, making the window seem detached during circular motion.

Aurora 0.4.2 handles that visual comparison explicitly on Win32:

1. Mouse capture begins on the Aurora title bar.
2. Aurora hides the host cursor in the client area.
3. Aurora draws a small vector pointer as the topmost retained layer.
4. The pointer and floating window consume the same late-latched native position.
5. Both are submitted in the same Vulkan or software compositor frame.
6. The native cursor is restored when capture ends.

The visible pointer can no longer be one Aurora frame ahead of the window because both are part of the same scene. Set `WindowOptions.synchronizedDragPointer = false` or `AURORA_SYNC_DRAG_POINTER=0` to compare against the ordinary hardware-cursor path.

## Subpixel logical coordinates

Win32 reports pointer positions in physical client pixels. At 125% or 150% display scaling, converting each update immediately to an integer 96-DPI coordinate discards motion:

```text
physical x = 101, 102, 103
150% logical x = 67.333, 68.000, 68.667
integer-only path = 67, 68, 68
```

Aurora now stores pointer and retained-layer positions as `PointF` until the final logical-to-physical transform. Every physical pointer pixel can therefore produce a corresponding physical layer movement.

```d
PointF precise = event.preciseGlobalPosition;
floating.setPrecisePosition(PointF(precise.x - grabOffset.x,
    precise.y - grabOffset.y));
```

Integer `Point` and `Rect` APIs remain available for ordinary layout. Subpixel position is compositor state rather than local content geometry.

## Late latching

A queued `WM_MOUSEMOVE` describes the pointer position when Windows created that message. Aurora still uses those events for hit testing, capture, button state, and normal widget dispatch, but a transform drag gets a newer sample at presentation time.

The Vulkan path is:

```text
process available native input
    → retain newest drag state
    → obtain a reusable frame context
    → acquire a swapchain image with timeout 0
    → GetCursorPos + ScreenToClient
    → update captured layer and synchronized pointer transforms
    → record dynamic viewport/scissor commands
    → submit and present
```

Sampling occurs after successful image acquisition, which is the last practical point before command recording. No widget layout or paint runs in the latch callback. The software compositor performs the same sample immediately before copying/compositing retained surfaces.

Microsoft documents `GetCursorPos` as returning the current cursor position in screen coordinates, while `WM_MOUSEMOVE` carries the coordinates associated with a delivered message:

- <https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-getcursorpos>
- <https://learn.microsoft.com/windows/win32/inputdev/wm-mousemove>

## Continuous interaction frames

A frame can become available between two native motion messages. While a captured widget requests continuous pointer frames, Aurora keeps a presentation opportunity pending and late-latches the pointer again instead of waiting for another `WM_MOUSEMOVE`.

The Win32 loop does not place that pending drag behind a nominal one-millisecond sleep. It checks for input without blocking, yields the current thread quantum, and immediately retries. This busy-yield path is active only while low-latency presentation remains pending; an idle Aurora window still sleeps and wakes through the native message queue.

Consecutive queued `WM_MOUSEMOVE` messages are also collapsed to the newest one without crossing button, keyboard, resize, or other message boundaries.

## Vulkan presentation and synchronization

### Present mode

With `vsync = true` and `lowLatency = true`, Aurora prefers `VK_PRESENT_MODE_MAILBOX_KHR`. MAILBOX has one pending presentation entry, and a newer present replaces that pending entry. When surface limits permit, Aurora requests three swapchain images: one displayed, one pending, and one available to render the replacement.

If MAILBOX is unavailable, Aurora tries `VK_PRESENT_MODE_FIFO_RELAXED_KHR` and then required FIFO. With `vsync = false`, it prefers IMMEDIATE, then MAILBOX, then FIFO.

The Vulkan specification defines the queueing behavior of these modes:

- <https://registry.khronos.org/vulkan/specs/latest/man/html/VkPresentModeKHR.html>

### Frame resources

MAILBOX and IMMEDIATE use two frame contexts so CPU command recording and GPU execution can overlap. FIFO and FIFO-relaxed deliberately use one submit context to avoid adding an ordered application-side queue.

Each frame context owns:

```text
command buffer
image-acquired semaphore
submission fence
```

Each swapchain image owns its own render-finished/present semaphore. Reusing a present-wait semaphore based only on a frame fence is unsafe because queue presentation is not covered by that fence. Khronos documents the per-swapchain-image reuse pattern here:

- <https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html>

Retained vertex/index buffers and atlas resources are shared across frame contexts. Transform-only frames only read them. Before a content revision rewrites or destroys one of those resources, Aurora requires every in-flight frame fence to be idle.

### No stored drag-frame queue

Aurora stores the current scene state, not a sequence of past pointer positions. A busy fence or unavailable image returns control to the native loop. The next successful submission records the then-current transform. `RendererStats.frameDeferrals` counts these nonblocking retries.

## Configuration

```d
WindowOptions options;
options.renderer = RendererPreference.vulkan;
options.lowLatency = true;
options.vsync = true;
options.synchronizedDragPointer = true;
```

Windows PowerShell:

```powershell
$env:AURORA_RENDERER = "vulkan"
$env:AURORA_LOW_LATENCY = "1"
$env:AURORA_SYNC_DRAG_POINTER = "1"
$env:AURORA_VSYNC = "1"

dub clean
dub run --build=release --config=desktop --force
```

To test the tearing-permitted path:

```powershell
$env:AURORA_VSYNC = "0"
dub run --build=release --config=desktop --force
```

`AURORA_VSYNC=0` is a presentation-policy comparison, not a prerequisite for the retained or late-latched architecture.

## Diagnostics

```d
window.resetCompositorStats();
window.resetRendererStats();

// Perform a drag, then inspect:
auto ui = window.compositorStats();
auto gpu = window.rendererStats();

writeln(ui.lateLatchSamples);
writeln(ui.lateLatchUpdates);
writeln(ui.baseBuilds);
writeln(ui.layerBuilds);
writeln(gpu.geometryUploads);
writeln(gpu.frameDeferrals);
```

`tests/latency.d` supplies a new native pointer position without delivering another mouse event. It requires the late-latched floating window to move at subpixel precision, the synchronized pointer to be composited, and all content/layout/upload counters to remain zero. `tests/compositor.d` separately moves a retained window through 96 positions and verifies the zero-rebuild contract. `tests/vulkan_smoke.d` verifies persistent Vulkan geometry across live presented transformations.

## Platform coverage

The precision and scene APIs are renderer-neutral. Win32 implements current-position sampling and host-cursor hiding for the complete synchronized-drag path. The headless backend implements deterministic equivalents for regression tests. Other native adapters preserve precise event coordinates and keep their ordinary host cursor until their query/hide integration is added; their retained content path is unchanged.

Native Windows behavior still depends on the installed Vulkan driver, DWM mode, monitor refresh, mouse polling, and display. The release can prove that Aurora does not rebuild or queue stale content; direct input-to-photon measurement requires the target Windows machine.
