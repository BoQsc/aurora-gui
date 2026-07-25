# Aurora-D architecture

Aurora-D separates native windows, retained widgets, text layout, draw-list construction, and rendering. Platform code owns window/event handles; text code produces positioned glyphs; renderers execute geometry. No widget imports a native windowing or Vulkan module.

## Layer map

```text
Application / demos
        │
        ▼
Retained widgets and layouts
        │
        ├───────────────┐
        ▼               ▼
Unicode/OpenType      Canvas primitives
text layout             │
        │                │
        └──────┬─────────┘
               ▼
 base DrawList + retained layer DrawLists
        + window-local GlyphAtlas
               │
               ▼
           RenderScene
  content revisions + transforms + z-order
               │
       ┌───────┴────────┐
       ▼                ▼
VulkanRenderer     SoftwareRenderer
persistent layer   cached layer ARGB
GPU buffers        surfaces
       │                │
       └───────┬────────┘
               ▼
         host presentation
```

Important dependency direction:

- platform adapters depend on neutral platform/event interfaces;
- renderers depend on `RenderScene`, `DrawList`, atlas bytes, and opaque WSI handles;
- widgets depend on `Canvas`, theme, layout, and neutral events;
- text layout depends on Unicode tables, font collections, and OpenType tables;
- renderers never perform shaping or bidi resolution;
- internal desktop windows remain Aurora widgets rather than host-native child windows.

## Ownership

A `GuiWindow` owns:

- one top-level `NativeWindow` adapter;
- one selected `RenderBackend`;
- one base `DrawList`;
- one `RenderScene`;
- one revisioned `DrawList` cache for each composited widget subtree;
- one cached painter-ordered layer array;
- one window-local `FontSystem`;
- one retained root widget;
- focus, hover, capture, click-counting, and invalidation state.

`FontSystem` owns:

- primary UI and monospace faces;
- ordered UI and monospace `FontCollection` objects;
- one `TextLayoutEngine`;
- one `GlyphAtlas` shared by every base/layer draw list in the window.

A `FontFace` owns the bytes of one selected sfnt/TTC face, its table directory, outline decoder, metrics, cmap, and legacy kerning data. A `TextLayout` owns an immutable copy of source text plus positioned layout records; it does not own atlas allocations.

## Invalidation and frame lifecycle

Aurora has three invalidation classes:

- **content** — dirties the nearest composited ancestor, or the base when no composited ancestor exists;
- **transform** — requests a frame while preserving content revisions;
- **composition** — rebuilds only visible layer ordering after visibility, insertion/removal, or z-order changes.

For a normal content frame:

1. The native adapter delivers an input/paint/invalidation event.
2. Dirty base or layer subtrees run layout and paint into their local draw lists.
3. Text calls request cached/new `TextLayout` records; new glyphs enter the common A8 atlas.
4. Dirty draw lists increment their content revisions.
5. `GuiWindow` builds `RenderScene` from the base revision, retained layers, transforms, and cached painter order.
6. Vulkan refreshes only geometry whose revision/size/atlas dimensions changed; software rerasterizes only changed cached surfaces.
7. The selected renderer composites in painter order and presents.

For a position-only `FloatingWindow` drag:

1. Mouse capture enables continuous pointer frames and precise `PointF` compositor state.
2. Native motion events update the current transform without changing content revisions.
3. `RenderScene` reuses the cached layer order and draw lists.
4. After a presentation slot is available, the renderer late-latches the current native pointer and refreshes only captured-layer and synchronized-pointer origins.
5. Vulkan records dynamic viewport/scissor state and reuses persistent buffers; software composites cached surfaces at their current origins.
6. The frame is presented.

This path performs zero widget layout, paint, shaping, glyph rasterization, tessellation, content upload, or layer-order rebuild. On Win32, the visible drag pointer is an Aurora layer submitted in the same frame. See [Input-to-presentation latency](INPUT_LATENCY.md) and [Retained compositor](RETAINED_COMPOSITOR.md).

## Canvas and draw-list model

A `Canvas` tracks:

- surface-space translation;
- an intersected surface-space clip rectangle;
- either a direct `Surface` target or a `DrawList` target;
- the owning `FontSystem`.

The public API looks immediate, but a GUI canvas records geometry:

| Canvas operation | Draw-list representation |
|---|---|
| rectangle | two indexed triangles |
| vertical gradient | colored quad |
| thick line | oriented quad |
| circle | triangle fan |
| circle stroke | indexed ring |
| rounded rectangle | convex perimeter fan |
| glyph | atlas-textured quad |

A layer draw list uses coordinates local to its composited widget. The scene separately stores physical device bounds, so movement never requires rewriting those vertices.

The draw list preserves painter order. Aurora does not reorder opaque or translucent geometry because doing so can change widget overlap semantics.

### Vertex and texture model

Each `DrawVertex` contains pixel-space local position, atlas UV, and straight RGBA color. Solid geometry samples a permanent white atlas texel; glyph geometry samples grayscale coverage. One pipeline and descriptor set draw both.

### Clipping

Each `DrawBatch` records a local `Rect`. Vulkan translates layer clips to framebuffer-space dynamic scissors. Software intersects them while building the cached layer surface. Nested clipping therefore has identical source data on both backends.

## Text architecture

Text is shaped before rendering:

```text
UTF-32 source
    ├── grapheme segmentation
    ├── bidi levels / visual order
    ├── script itemization
    ├── cluster-level font fallback
    ├── GDEF / GSUB / GPOS
    ├── line-break opportunities
    └── line placement
            ▼
        TextLayout
```

### Unicode tables

`tools/generate_unicode.py` converts official Unicode 17 data into coalesced property ranges. The runtime binary-searches those ranges; it does not depend on ICU or platform Unicode APIs.

The implemented algorithms are in:

- `aurora.text.unicode.grapheme` — UAX #29 extended grapheme clusters;
- `aurora.text.unicode.bidi` — UAX #9 through L2;
- `aurora.text.unicode.linebreak` — UAX #14 opportunities;
- `aurora.text.unicode.properties` — generated properties, scripts, joining types, brackets, and mirrors.

### Font fallback and itemization

`TextLayoutEngine` first creates grapheme ranges, resolves paragraph bidi levels, assigns scripts, and selects one `FontFace` per complete cluster. Runs split when font, script, bidi level, or paragraph context changes.

Common and inherited script characters are associated with neighboring runs where possible. OpenType script tags are generated from Unicode script values.

### OpenType shaping

`OpenTypeShaper` consumes logical `ShapeInput` records and preserves source cluster ranges through GDEF/GSUB/GPOS. It implements common substitution and positioning lookup types, nested contextual lookups, lookup flags, mark filtering, Arabic joining masks, and legacy-kern fallback.

Shaped glyphs remain in logical order until the paragraph layout layer orders runs and glyphs visually. This keeps source mapping stable.

### Layout records

A `TextLayout` contains:

- `PositionedGlyph[]` with font, glyph ID, source range, baseline position, advance, bidi level, and line;
- `GlyphRun[]` with script, font, direction, logical range, glyph range, and geometry;
- `TextLine[]` with logical/paragraph ranges, baseline, metrics, and visual width;
- `VisualCluster[]` used for selection and caret placement;
- `CaretPosition[]` including upstream/downstream affinity.

The renderers only need `PositionedGlyph[]` and atlas entries. Widgets and the editor use the other records for interaction.

### Glyph rasterization and atlas

`FontFace` accepts either TrueType `glyf` outlines or static CFF1 Type 2 outlines. Both become flattened edges filled with a nonzero winding rule and 4×4 supersampling.

`GlyphAtlas` shelf-packs one-pixel-padded A8 bitmaps and grows while preserving coordinates. Its key includes face identity, glyph ID, pixel size, reserved rendering flags, and a reserved variation hash.

## Vulkan backend

`VulkanRenderer` uses the declaration subset in `aurora.vulkan.api` and dynamically loads every entry point.

Initialization:

1. Open the Vulkan loader.
2. Enumerate instance extensions and choose the platform WSI path.
3. Create the instance, optionally enabling validation/portability enumeration.
4. Create the native surface.
5. Select graphics/presentation queue families and a physical device.
6. Create a logical device and swapchain.
7. Create render pass, pipeline, descriptors, sampler, commands, and synchronization objects.
8. Create framebuffers and the device-local R8 atlas image.

Per retained scene:

1. Recreate the swapchain if resize or out-of-date state requires it.
2. Select an idle frame context without waiting; MAILBOX/IMMEDIATE may use two, ordered FIFO modes use one.
3. Acquire an image with zero timeout; defer rather than block when none is immediately available.
4. Late-latch the captured pointer and update only scene-layer origins.
5. Ensure the common glyph atlas is current.
6. For the base and each retained layer, compare content revision, local viewport, and atlas dimensions; upload geometry only when one changed.
7. Retire GPU caches for layers no longer present.
8. Record one render pass: base first, then layers in cached painter order, using dynamic viewport/scissor transforms.
9. Signal the acquired image's present semaphore, submit, and present.

Aurora retains current scene state rather than an application-side sequence of drag frames. Present semaphores are per swapchain image. Transform-only frames can overlap because retained geometry is immutable; content/atlas mutation requires every in-flight frame fence to be idle. Fence/image unavailability produces a short frame deferral, not an input-thread wait.

### WSI paths

- X11: Xlib surface, with XCB fallback when the driver exposes only XCB WSI.
- Windows: Win32 surface.
- macOS: `CAMetalLayer` with `VK_EXT_metal_surface` through a loader such as MoltenVK.

No Vulkan SDK header or link library is needed at build time.

## Coordinate spaces and DPI

Aurora public geometry is logical at 96 DPI. `NativeWindow` reports a logical client size, a physical framebuffer size, and `DisplayScale`; resize events carry the same triplet. `GuiWindow` lays out widgets logically and resets `DrawList` with both extents. Draw-list primitives convert their boundaries and scissors to physical pixels. Shaped glyph origins are scaled and snapped, while glyph bitmaps are generated directly at the physical pixel size. Renderers therefore consume only framebuffer coordinates and never scale a finished application image. The Win32 backend implements Per-Monitor-V2 transitions; other adapters currently report identity scale.

## Software backend

`SoftwareRenderer` consumes the same scene, vertices, indices, UVs, colors, and clip batches. It caches the base surface by base revision and each transparent layer surface by layer revision. Content builds evaluate edge functions, interpolate attributes, nearest-sample 1:1 A8 coverage, and alpha-blend into 32-bit ARGB. Transform-only frames copy/composite the cached surfaces without rerasterizing controls or text.

It serves as:

- automatic fallback;
- headless/CI renderer;
- deterministic screenshot path;
- behavioral reference for Vulkan geometry and text placement.

Direct `Canvas(Surface)` remains available for small standalone drawing. It uses specialized software primitives but shares `FontSystem` layout and atlas data.

## Widget and editor model

Widgets store local bounds, parent/children, host, visibility, enablement, focus/hover state, cursor, layout hints, and an optional compositor-layer flag. Paint traversal translates and clips a child canvas; hit testing walks children in reverse paint order. `FloatingWindow` and `Taskbar` are composited by default, and applications can promote another subtree with `setComposited(true)`.

Native adapters translate events into `aurora.event.Event`. `GuiWindow` owns focus transitions, mouse capture, click counts, cursor updates, and tab traversal.

`TextEditor` stores UTF-32 source and a logical cursor/anchor plus caret affinity. It obtains layouts from the host window's `FontSystem`, so rendering, selection, mouse hit testing, wrapping, fallback, and arrow navigation use the same geometry. Clipboard content remains process-local in 0.4.2.

## Failure handling

Automatic renderer selection catches Vulkan initialization/runtime failures, records the reason, and executes the current draw list through software. Explicit Vulkan mode surfaces the exception.

During shutdown, the native event loop notifies `GuiWindow` before platform handles are destroyed. Vulkan waits idle and releases surface-dependent resources while those handles remain valid.

Malformed font and OpenType offsets are range-checked and throw exceptions. `FontFace.tryLoad` converts those failures to `null` for optional discovery/fallback paths.

## Threading

The current implementation is single-threaded:

- native events, layout, shaping, glyph rasterization, paint recording, and presentation occur on the UI thread;
- widget/font objects are not synchronized for concurrent mutation;
- one window thread owns its Vulkan queues and resources.

Stable `TextLayout` and finished `DrawList` boundaries are natural future handoff points for worker shaping or a render thread.

## Extension points

A new renderer implements `RenderBackend` and consumes both direct `DrawList` rendering and retained `RenderScene` composition. A new native platform implements `NativeWindow` and exposes opaque WSI handles. A new outline format can implement the same glyph-bitmap boundary used by `FontFace`. A new script-specific shaping stage can transform `ShapeInput` before generic OpenType lookup execution without changing the atlas or renderer APIs.

Likely future work:

- variable-font instances and CFF2;
- TrueType hinting modes;
- color glyphs;
- specialized Indic/Southeast Asian syllable engines;
- vertical text and richer typography;
- carefully latency-bounded multi-frame Vulkan resource rings;
- Wayland WSI;
- native IME, clipboard, accessibility, and drag/drop integration.
