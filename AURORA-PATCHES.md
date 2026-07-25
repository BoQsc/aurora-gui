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
