# Changelog

## 0.4.5 — Pointer-locked taskbar reordering

- Replaced slot-bound task dragging with a root-level retained `TaskDragProxy` that displays the actual icon, label, running state, and active state under the pointer.
- Preserved the exact original grab offset and subpixel pointer position, including late-latched samples, so the task proxy and synchronized Aurora cursor move in the same submitted scene.
- Deferred model mutation until mouse-up. During motion, the source task is omitted from taskbar painting and neighbouring tasks are projected around an insertion gap; release commits at most one stable-ID move and one persistence callback.
- Added midpoint hysteresis to prevent target-slot chatter while the pointer circles or trembles near a boundary.
- Made host-focus loss, taskbar resize, entry removal, programmatic reordering, and Escape remove the proxy without committing a partial order.
- Added public drag diagnostics, deterministic arbitrary-grab/subpixel/focus-loss coverage, a visual drag-preview regression, and release-asset markers that reject the old mutate-on-motion path.

## 0.4.4 — Desktop-shell correctness and popup discipline

- Replaced the fixed-height Start-menu column with a dedicated measured `StartMenu`: searchable and scrollable application content, fixed system/power footer, client-edge clamping, complete keyboard navigation, and a shutdown row that cannot be clipped by application content.
- Added a root-level transient-popup lifecycle. Outside presses dismiss the topmost popup and are re-hit-tested against the underlying control; Escape and host focus loss use the same detached-subtree cleanup path.
- Added stable `TaskEntryId` identities, identity-preserving pointer drag state, complete order snapshots, validated persisted-order restoration, and one reorder callback per completed drag.
- Added `UiTestDriver`, which sends input through `GuiWindow` pre-dispatch, hit testing, capture, focus, bubbling, and click counting instead of invoking widget handlers directly.
- Added structural layout auditing for negative geometry, viewport escape, undersized controls, and malformed full-client overlays.
- Added deterministic shell visual coverage, Start-menu size-matrix checks, click-away redispatch checks, focus-loss and Escape dismissal, search behavior, and a 320-drag taskbar reorder stress regression.

## 0.4.3 — Desktop interactions and shell menus

- Added reusable Aurora-rendered `ContextMenu` overlays with command, check, separator, icon, shortcut, disabled-state, outside-click dismissal, client-edge clamping, and complete keyboard traversal behavior.
- Added `LayoutHints.excludeFromLayout` so popup overlays retain explicit bounds instead of becoming rows or columns in `HBox` and `VBox` roots.
- Made desktop shortcuts selectable and draggable with a threshold, pointer capture, late-latched compositor movement, drop-target highlighting, collision-free grid snapping, free positioning, arrangement, removal, and an application-defined consumed-drop contract.
- Added explicit child painter-order movement and a wallpaper icon stratum, so shortcuts created or dragged after floating windows never remain above those windows.
- Added shortcut and wallpaper context menus for Open, Rename, Delete, Properties, Refresh, Arrange, Align to grid, New, Display settings, and Personalize, plus Enter/Space, F2, Delete, F5, and Shift+F10 keyboard paths.
- Made task entries reorderable by dragging left or right across task midpoints, exposed programmatic order and persistence callbacks, and added active/minimized state handling, mouse-wheel switching, keyboard traversal, and Show Desktop restoration.
- Added task-button, Start, clock, empty-taskbar, and floating-title-bar context menus with restore, minimize, maximize, close, move, remove, fullscreen, settings, and date/time commands.
- Expanded the Desktop Environment and Taskbar demos with real trash drops, generated shortcuts, task-order feedback, window/task synchronization, and shell command callbacks.
- Added a dedicated desktop-shell integration configuration and regressions for immediate grab offsets, consumed drops, popup actions and dismissal, flex-root overlays, drag reordering, and task context menus.

## 0.4.2 — Readable desktop typography

- Replaced the former small arithmetic font sequence with semantic `TextScale` tiers: 13 logical pixels for captions, 17 for body text, 22 for headings, and 30 for display text.
- Made the 17-pixel body tier the default `Theme.fontScale` while retaining integer-scale source compatibility through `fontPixelSize` and `fontScaleForPixelSize`.
- Increased standard control, text-field, list-row, desktop-icon, floating-title-bar, caption-button, taskbar, toolbar, and status-bar metrics to fit the larger typography without clipping.
- Changed button preferred-width calculation from a character-count estimate to the actual shaped `TextLayout` measurement, including icon chrome and the active UI font.
- Updated Notepad, File Explorer, Desktop Environment, Taskbar, Font Gallery, and headless demo layouts and screenshots around the new typography ramp.
- Added public typography regression assertions and `docs/TYPOGRAPHY.md`, while preserving 96-DPI logical layout and physical monitor-pixel glyph rasterization.

## 0.4.1 — Late-latched Windows dragging and synchronized presentation

- Added subpixel logical pointer coordinates and retained-layer positions so 125%, 150%, and other fractional DPI scales preserve every physical mouse pixel instead of quantizing drag movement through integer 96-DPI units.
- Added last-moment native pointer latching. Vulkan samples the current pointer after a swapchain image becomes available and immediately before command recording; the software compositor samples immediately before composition.
- Added continuous interaction frames while a transform-drag owns capture, so presentation opportunities use the newest pointer even when no additional `WM_MOUSEMOVE` has reached the queue.
- Added a frame-synchronized Aurora drag pointer on Win32. Aurora hides the host cursor during a retained-window drag and draws its own vector pointer in the same compositor frame as the moved window, removing the visible one-frame separation between a hardware cursor and application-rendered content.
- Preserved the zero-rebuild drag contract: late latching changes only layer transforms and performs no widget layout, paint traversal, text shaping, glyph rasterization, tessellation, or geometry upload.
- Replaced the Win32 pending-frame one-millisecond wait with a message-aware busy-yield path active only during low-latency presentation, avoiding coarse timer quantization while still processing input immediately.
- Reworked Vulkan interaction synchronization around two reusable frame contexts for MAILBOX/IMMEDIATE presentation, while ordered FIFO modes remain single-submit to avoid deepening their queue.
- Requested three swapchain images for MAILBOX when surface limits permit, allowing the pending mailbox image to be replaced while another image is displayed.
- Replaced the single render-finished semaphore with one present semaphore per swapchain image, and gated rare retained-buffer/atlas mutations on all in-flight fences.
- Added `AURORA_SYNC_DRAG_POINTER`, public late-latch diagnostics, and a deterministic latency regression proving subpixel movement without a mouse-move event, zero retained-content rebuilds, and synchronized window/cursor composition.

## 0.4.0 — Aurora-rendered retained compositor

- Added `RenderScene` and `RenderLayer`, separating retained layer content revisions from layer position, visibility, and painter order.
- Promoted Desktop Environment floating windows, taskbar, and Start menu to independently retained Aurora layers while keeping one native host window; no native child windows or operating-system window compositor are used for internal Aurora windows.
- Split widget invalidation into content, transform, and composition-order paths. A position-only move of a composited widget no longer runs widget layout, paint traversal, text shaping, tessellation, or content-buffer upload.
- Added a cached compositor layer order so repeated drag frames do not walk the widget tree or allocate a new layer list.
- Added persistent per-layer Vulkan vertex/index buffers keyed by content revision. Layer movement changes dynamic viewport/scissor state and reuses the same GPU geometry.
- Added retained software surfaces for each layer, keeping the deterministic fallback transform-only as well.
- Added consecutive Win32 `WM_MOUSEMOVE` coalescing so presentation consumes the newest queued pointer position instead of replaying stale positions.
- Made Vulkan frame-fence and image acquisition nonblocking in low-latency operation; a busy frame is deferred while native input continues, then retried with the newest scene state rather than stalling or queueing old positions.
- Removed per-frame live-layer scratch allocation from both retained renderers and stopped rebuilding the minute-precision taskbar clock when its text has not changed.
- Added public compositor and renderer work counters, a deterministic headless transform-only invariant test, and a required-Vulkan smoke that resets after native resize warm-up and proves zero content rebuilds and zero geometry uploads across move, hide, and restore frames.
- Added the retained-compositor architecture and performance contract to release documentation and verification gates.

## 0.3.4 — Fullscreen and interactive-latency hardening

- Added a cross-platform fullscreen API through `WindowOptions.startFullscreen`, `GuiWindow.setFullscreen`, `GuiWindow.toggleFullscreen`, and `GuiWindow.fullscreen`.
- Added F11 and Alt+Enter fullscreen shortcuts, Escape-to-exit behavior, an opt-out switch, and `AURORA_FULLSCREEN` deployment override.
- Added monitor-aware borderless fullscreen on Win32 that saves and restores the previous style, extended style, placement, maximized state, and topmost policy, then re-resolves DPI and framebuffer extent.
- Added native AppKit fullscreen and EWMH `_NET_WM_STATE_FULLSCREEN` support, plus deterministic headless state coverage.
- Added UTF-8 `_NET_WM_NAME` titles on X11 with an ASCII ICCCM fallback, avoiding malformed legacy titles in window-manager tooling.
- Reworked the Win32 event loop to process bounded input batches, repaint pointer-driven state before it can be starved by queued motion, wake on messages instead of sleeping unconditionally, and render during the modal move/resize loop.
- Reduced internal drag work by avoiding repeated full-tree hover hit tests while a widget owns mouse capture.
- Added `WindowOptions.lowLatency`, `AURORA_LOW_LATENCY`, and `AURORA_VSYNC`; Vulkan now prefers mailbox presentation for low-latency synchronized output and minimizes swapchain queue depth when supported.
- Added collision-checked short static text-layout caching, local-corner rounded-rectangle tessellation, direct axis-aligned quad spans, and solid-triangle fast paths to reduce redraw cost in the software fallback.
- Added fullscreen controls and selected-renderer diagnostics to the Desktop Environment demo, public-API and internal-drag regressions, real X11 window-manager fullscreen smoke coverage, and optimized-build guidance for Windows interaction testing.

## 0.3.3 — Standalone Windows DMD build compatibility

- Removed automatic `/manifest:embed` and `/manifestinput` linker flags from the default Windows executable configurations. Those flags made DMD's bundled `lld-link` invoke `mt.exe`, which is not part of a standalone DMD installation.
- Kept Per-Monitor-V2 activation in the Win32 module constructor before `main`, including Windows 8.1 and legacy fallbacks, so the DPI-correct framebuffer path remains active without a linked manifest.
- Kept the authored manifest and RC file as optional deployment resources and added `scripts/embed-windows-manifest.ps1` for users who intentionally have the Windows SDK installed.
- Added release validation that rejects any default DUB configuration which reintroduces `mt.exe`-dependent manifest flags.
- Documented the no-SDK default path, the optional manifest-first path, and the exact recovery command for 0.3.2 users.

## 0.3.2 — Windows high-DPI and sharper grayscale text

- Added a shared 96-DPI logical/physical framebuffer model through `DisplayScale`, distinct logical and framebuffer sizes, and resize-event scale metadata.
- Made the Win32 backend request Per-Monitor-V2 awareness before `main`, with Windows 8.1 and legacy fallbacks, DPI-aware initial sizing, `GetDpiForWindow`, `AdjustWindowRectExForDpi`, and `WM_DPICHANGED` handling.
- Added a Per-Monitor-V2 application manifest, resource-script template, and automatic manifest embedding for Aurora's Windows demo and Vulkan-smoke executables.
- Converted Win32 pointer coordinates to logical units while keeping Vulkan swapchains and software surfaces at the physical client extent.
- Replaced stretched GDI presentation with a 1:1 `SetDIBitsToDevice` copy of the physical software framebuffer.
- Rasterized glyphs at monitor-pixel size, snapped glyph quads to framebuffer pixels, and changed Vulkan/software A8 sampling to nearest at that 1:1 size to avoid a second filtering pass.
- Added portable `FontRenderMode.sharp` and `FontRenderMode.smooth` policies, runtime switching, and the `AURORA_FONT_RENDER_MODE` override. Sharp mode increases intermediate grayscale coverage contrast without claiming TrueType hinting or ClearType.
- Added deterministic 125%, 150%, and 200% DPI regression coverage, warning-as-error integration, Windows manifest validation, and packaging allowlisting for the new resources.

## 0.3.1 — Release hardening and reproducible packaging

- Added public compile-time package-version constants and an aggregate-import smoke test.
- Added deterministic checks for generated Unicode tables and embedded SPIR-V shaders.
- Made verification scripts independent of the caller's current directory and expanded them to build every DUB configuration with fresh graphs.
- Added authored-source hygiene, JSON, script-syntax, Unicode-input, and local-document-link checks.
- Added warning-as-error host builds and complete Windows/macOS cross-target object-generation checks for release validation.
- Added a standard-library-only release packager that enforces a source/file-type allowlist, creates reproducible ZIP and tar.gz archives, validates normalized archive metadata, embeds a per-file SHA-256 manifest, compares both extracted archives, reruns verification from the ZIP payload, and publishes checksums plus a report-last commit marker.
- Added release and package-validation documentation, including exact distinctions between host runtime tests, software-driver Vulkan tests, and compile-only targets.

## 0.3.0 — Unicode layout, OpenType shaping, fallback, and CFF

- Replaced the one-code-point/one-glyph path with cacheable renderer-neutral `TextLayout` records containing positioned glyphs, logical/visual runs, lines, clusters, caret states, and source mappings.
- Added generated Unicode 17 property tables and pure-D UAX #29 extended grapheme segmentation, UAX #9 bidirectional resolution/reordering, and UAX #14 line breaking.
- Added official Unicode 17 conformance runners for grapheme, line-break, `BidiCharacterTest`, and `BidiTest` corpora.
- Added script itemization and ordered font fallback resolved for complete grapheme clusters.
- Added a pure-D OpenType layout engine for GDEF, GSUB lookup types 1–8, GPOS lookup types 1–9, nested contextual lookups, lookup flags, mark filtering, ligature carets, Arabic joining masks, and legacy-kern fallback.
- Added static CFF1 Type 2 rasterization for name-keyed and CID-keyed OpenType fonts, including local/global subroutines, `FDArray`/`FDSelect`, cubic curves, and common arithmetic/flex operators.
- Kept TrueType `glyf`/`loca` simple and compound outline support.
- Migrated Canvas measurement/drawing and the text editor to the same window-local `FontSystem`, layout engine, and glyph atlas.
- Added grapheme-safe editing, Unicode soft wrapping, bidi hit testing, caret affinity, visual arrow navigation, and discontiguous bidi selection geometry.
- Added application-provided fallback APIs and reserved glyph-cache fields for future rendering modes and variable-font instances.
- Added a Wrap control to Notepad and expanded Font Gallery with ligatures, marks, multiple scripts, mixed-direction text, and static-CFF loading.
- Added text-system/boundary integration, font-corpus smoke, multilingual Vulkan smoke, and Windows/macOS cross-target compile validation.

## 0.2.0 — Renderer-neutral draw list, Vulkan, and smooth fonts

- Refactored widget drawing into an ordered indexed-triangle draw list.
- Added a Vulkan renderer with X11/XCB, Win32, and Metal-surface paths.
- Added a deterministic software renderer consuming the same draw list.
- Added automatic Vulkan selection and software fallback.
- Added pure-D TrueType `glyf` parsing, antialiased rasterization, and a shared A8 glyph atlas.
- Added UI/monospace font roles, discovery, environment overrides, custom font paths, and the Font Gallery demo.
- Retained the authored 5×7 face only as an emergency fallback.

## 0.1.0 — Initial compact GUI baseline

- Added CPU ARGB surfaces, Canvas primitives, retained widgets, layouts, a text editor, X11/Win32/AppKit/headless adapters, and Notepad/File Explorer/Desktop/Taskbar demos.
