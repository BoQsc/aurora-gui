# Aurora retained compositor

Aurora-D 0.4.2 keeps the Desktop Environment inside one native host window while rendering every internal window, taskbar, menu, control, icon, and glyph through Aurora. The host operating system supplies only the top-level surface, input events, DPI/window lifecycle, and final presentation.

Internal Aurora windows are not `HWND`, `NSWindow`, or X11 child windows. They are retained Aurora layers in one in-process compositor.

## Performance contract

A position-only drag of an already-rendered `FloatingWindow` has this contract:

```text
widget layout                 0
widget paint traversal        0
text shaping                  0
glyph rasterization           0
primitive tessellation        0
vertex/index upload           0
layer-order rebuild           0
native pointer sample         1
layer transform update        0 or 1
compositor submission         1
```

The renderer still records a small command sequence and submits/presents a frame. The expensive content path is not executed. The captured pointer is sampled again at the last practical moment; if it changed, only `deviceBounds` is updated. If no frame context or swapchain image is immediately available, Aurora defers without blocking input and retries with the current transform rather than storing an obsolete drag frame.

Aurora exposes the counters used by its regression tests:

```d
CompositorStats ui = window.compositorStats();
RendererStats gpu = window.rendererStats();

writeln(ui.baseBuilds);
writeln(ui.layerBuilds);
writeln(ui.layerOrderBuilds);
writeln(ui.transformOnlyFrames);
writeln(ui.lateLatchSamples);
writeln(ui.lateLatchUpdates);
writeln(gpu.geometryUploads);
writeln(gpu.geometryUploadBytes);
writeln(gpu.frameDeferrals);
```

`tests/compositor.d` presents 96 retained-window positions in the deterministic headless path—including partially off-screen positions—and requires zero base, layer-content, and layer-order rebuilds, zero child layouts, and zero child paints during the movement stream. `tests/latency.d` changes the native test pointer without sending another motion event and requires a subpixel late-latched move, a frame-synchronized pointer layer, and zero content work. `tests/vulkan_smoke.d` lets native map/resize warm-up finish, resets all counters, then moves, hides, and restores a real Vulkan layer across presented frames while requiring zero base/layer content rebuilds and zero geometry uploads during the measured interaction.

## Scene model

```text
Widget tree
    │
    ├── non-composited widgets ──► base DrawList (revision B)
    │
    ├── FloatingWindow A ────────► local DrawList (revision A)
    ├── FloatingWindow B ────────► local DrawList (revision C)
    ├── Start menu ──────────────► local DrawList (revision M)
    ├── Taskbar ─────────────────► local DrawList (revision T)
    └── drag pointer ────────────► local DrawList (revision P, active drag only)
                                      │
                                      ▼
                                  RenderScene
                         content revision + device bounds
```

Each layer's geometry is local to its own width and height. Its `deviceBounds.x` and `deviceBounds.y` are compositor state, not baked into the geometry. A content revision changes only when the layer is repainted.

`Widget.setComposited(true)` promotes a widget subtree to a retained layer. `FloatingWindow` and `Taskbar` do this automatically. Desktop Environment's Start menu is also promoted.

## Invalidation classes

Aurora distinguishes three kinds of change:

### Content invalidation

Examples: text changes, hover/pressed appearance, editor changes, theme changes, or a control being resized.

Only the nearest composited ancestor is marked dirty. On the next frame Aurora lays out and paints that layer into its local `DrawList`, increments the layer revision, and lets the renderer refresh that layer's retained resource.

### Transform invalidation

Examples: moving a composited window without changing its size.

Aurora requests a frame but does not mark base or layer content dirty. The next `RenderScene` references the same draw list and revision with a new `deviceBounds` origin.

### Composition invalidation

Examples: raising a window, showing/hiding a retained layer, adding/removing a retained layer.

Aurora rebuilds only its cached painter-ordered layer array. Existing content revisions remain valid.

## Precise transforms and late latching

A composited widget can retain its position as `PointF` rather than reducing every native physical pixel to an integer logical coordinate. Its integer `bounds` remain available to existing layout and hit-test code, while `preciseGlobalOrigin()` supplies the compositor transform.

During a captured transform drag, the scene installs a late-latch callback. Vulkan invokes it after successful image acquisition and before command recording; software invokes it before retained-surface composition. The callback queries the current native pointer, calls the captured widget's `onPointerLatch`, and refreshes only matching scene-layer origins.

On Win32, Aurora also hides the host cursor and adds a topmost vector pointer layer. The moved window and visible pointer therefore share the same sample and submitted scene. See [Input-to-presentation latency](INPUT_LATENCY.md).

## Vulkan path

The Vulkan backend owns one `GpuLayerGeometry` cache per layer ID:

```text
layer ID
  ├── content revision
  ├── local viewport size
  ├── atlas dimensions
  ├── persistent mapped vertex buffer
  ├── persistent mapped index buffer
  └── index count
```

Geometry is converted to normalized local coordinates once. During composition, Vulkan sets a dynamic viewport to the layer's current device bounds, translates each local clip rectangle into a dynamic framebuffer scissor, binds the retained buffers, and issues indexed draws.

A drag frame therefore changes command-buffer state but does not rewrite the layer's buffers. The common glyph atlas is uploaded only when its own revision changes.

Painter order remains explicit: base first, then retained layers in widget z-order. Aurora does not reorder layers or batches in ways that could change alpha-blending semantics.

## Software path

The software renderer keeps:

- one cached base ARGB surface keyed by base revision;
- one transparent ARGB surface per retained layer keyed by layer revision.

A transform-only frame copies the cached base and alpha-composites each cached layer at its current device origin. It does not rerasterize the layer's triangles or text.

This path is deterministic and remains the reference implementation for screenshots and headless tests. Vulkan is the intended high-performance interactive backend.

## Input scheduling

The Win32 adapter paints a latency-sensitive invalidation before draining another full message batch and collapses consecutive queued `WM_MOUSEMOVE` records to the newest position while preserving ordering around button, keyboard, resize, and other messages.

A captured `FloatingWindow` requests continuous pointer frames. Even between motion messages, Aurora keeps a render opportunity pending so the next available swapchain image can use a current `GetCursorPos` sample. A pending low-latency frame uses a zero-timeout message check and thread yield rather than a coarse timer sleep. Mouse capture continues to deliver button-up and ordinary movement outside the original window bounds.

Vulkan uses two frame contexts only for MAILBOX/IMMEDIATE modes, one context for ordered FIFO modes, and one present semaphore per swapchain image. Aurora stores a current transform, never a sequence of drag states.

## What remains host-native

Aurora intentionally uses the host only for operations that cannot be replaced by drawing into a swapchain:

- creation and lifetime of the one top-level host window;
- keyboard, pointer, focus, resize, DPI, and display events;
- cursor selection;
- Vulkan WSI surface creation or software bitmap presentation;
- final desktop composition and scanout performed by the operating system/display stack.

Window decorations, internal title bars, move/resize logic, taskbar, menus, controls, text, and all Desktop Environment contents remain Aurora-rendered.

## Interaction guidance on Windows

Use an optimized Vulkan build when assessing interaction:

```powershell
$env:AURORA_RENDERER = "vulkan"
$env:AURORA_LOW_LATENCY = "1"
$env:AURORA_SYNC_DRAG_POINTER = "1"
$env:AURORA_VSYNC = "1"
dub clean
dub run --build=release --config=desktop --force
```

The title must report `Vulkan`. `AURORA_VSYNC=0` selects immediate presentation when the driver exposes it and is useful for diagnosing presentation scheduling, but it may tear. It does not change the retained-content contract.
