# aurora-host experiment

An isolated experiment for a portable Aurora UI host. It is a leaf: it depends
on `vendor/aurora-d-0.4.5` and `vendor/aurora-standard`, but no repository
package depends on it. Delete this folder and Aurora is unaffected.

## Responsibility

The host has one responsibility: it owns the retained Aurora UI shell and its
platform boundary. It does not own application content, application rendering,
or domain policy. [RESPONSIBILITY.md](RESPONSIBILITY.md) defines the normative
rules, and `tools/check_boundary.py` enforces the dependency, import, and leaf
constraints as part of the experiment verification gate.

## What it proves

- A scene file is the stable, user-facing contract.
- The protocol constants and reference are generated from one schema.
- The host validates a scene without creating a window.
- Validation rejects unknown fields, duplicate node IDs, and inconsistent
  frame-event declarations instead of deferring them to the first render.
- The host can construct the retained widget tree and render it headlessly.
- The same executable can open a real Aurora window with `--run`.
- A stdin/stdout control channel can inspect and change the live scene.
- Scenes can contain real editable text areas and named button actions.
- The host owns editor painting: only display rows intersecting the viewport are
  shaped and drawn, while the full buffer, selection, and undo state stay in the
  host.
- Single-line text fields feed application search and command workflows.
- Editor text, cursor, anchor, and line/column changes are readable and
  observable without the host owning document policy.
- Scenes can contain retained custom-drawn canvases using portable primitives.
- Pointer, keyboard, and frame-tick events reach the scene without a second
  event loop.
- An application can animate a retained canvas from tick events and replace its
  draw list without rebuilding the scene or opening another window.
- Relative image assets are decoded by Aurora and render in windowed and
  headless modes.
- A memory-mapped shared surface carries RGBA frames and an input ring, so
  high-frequency clients do not send per-frame JSON draw commands.
- Application-visible content is Aurora-rendered: menu bars, tabs, toolbars,
  popups, the editor, and the undecorated file-dialog window all paint through
  Aurora. The OS retains only the top-level window frame, taskbar integration,
  and dialog window placement/system-move.
- Scene nodes can declare hover hints. The host shows them after a dwell in an
  Aurora-rendered overlay, suppresses them for pointer exit and popups, and
  reports the active hint through `tooltipState`.
- Text uses Aurora's shared foreground-aware grayscale transfer, with the
  reviewed lighter weight on light surfaces and established near-white weight.
- The application icon is embedded in both the window runtime and the PE
  resource, so the executable remains portable without an `.ico` sidecar.
- Icon artwork, ICO assembly, and scene base64 embedding are first-party D
  authoring, so no Python interpreter or image library is involved.
- A scene can carry its own base64 ICO in `window.icon`. The host materializes
  it to a content-addressed temp file and applies it live, so editing a scene
  updates the titlebar and taskbar icon without restarting the process.

## Commands

```text
python tools/generate_reference.py --check
python tools/verify_experiment.py
python tools/editor_control_test.py
python tools/canvas_test.py
python tools/canvas_control_test.py
python tools/drive_interaction.py
python tools/drive_animation.py
python tools/drive_image.py
python tools/drive_surface.py
python tools/surface_dpi_test.py
python tools/module_contract_test.py
python tools/icon_test.py --host build/verify/aurora-host-experiment.exe
python tools/scene_icon_test.py --host build/verify/aurora-host-experiment.exe
python tools/reload_test.py --host build/verify/aurora-host-experiment.exe --scene samples/workspace.scene.json
python -B tools/package_host.py --out build/package/aurora-host-0.1.0-win64
python -B tools/verify_package.py --package build/package/aurora-host-0.1.0-win64.zip

dmd -I../../vendor/aurora-d-0.4.5/source -Isource -i -mscrtlib=msvcrt -run tools/icon_author.d --kind host --out assets/aurora-host.ico
dub run --config=host -- samples/hello.scene.json
dub run --config=host -- samples/workspace.scene.json --watch
dub run --config=host-headless -- --render samples/hello.scene.json --out build/hello.ppm
dub run --config=host-headless -- --render samples/canvas.scene.json --out build/canvas.ppm
dub run --config=host-headless -- --render samples/image.scene.json --out build/image.ppm
python tools/control_client.py
```

### Live window workflow

Never launch `--run` directly from the executable you are still rebuilding.
Windows locks a running executable, so the build cannot replace it.

Use the launcher instead:

```text
python -B tools/live_host.py --scene samples/notepad-icon.scene.json
```

It builds into a unique `build/live/<timestamp>/` directory, copies the host to
`build/run/<timestamp>/`, and runs the copy. The build output stays unlocked, so
source rebuilds cannot close or block the visible window. Pass `--exe` to use an
already-built host, and `--replace PID` to close the old window only after the
new copy is running.

For a persistent scene-building session with a host-native control socket, use
[LIVE-BUILDING.md](LIVE-BUILDING.md):

```text
aurora-host-experiment.exe --dev samples/live-lab.scene.json --listen 8791
python -B tools/live_cli.py --port 8791 '{"command":"ping"}'
```

The legacy `tools/live_bridge.py` remains available for PNG conversion and
layout snapshots; it is not required for control.

The host itself now carries a single-executable development mode:

```text
aurora-host-experiment.exe --dev
```

It creates `aurora-scene.json` from an embedded starter when no path is given
and opens the host-owned scene source panel. No Python or external IDE is
required. Live is on by default: edits apply after a short pause, and the Live
button pauses or resumes automatic application. See
[LIVE-BUILDING.md](LIVE-BUILDING.md).

The host also exposes the JSON-lines control channel directly:

```text
aurora-host-experiment.exe --dev samples/live-lab.scene.json --listen 8795
python -B tools/live_cli.py --port 8795 '{"command":"ping"}'
```

`--listen` removes the need for the Python bridge in automation.

`samples/notepad-icon.scene.json` embeds the notepad ICO as base64. Replace
`window.icon` or regenerate the scene from an ICO with:

```text
dmd -I../../vendor/aurora-d-0.4.5/source -Isource -i -mscrtlib=msvcrt -run tools/icon_author.d --scene samples/notepad.scene.json --icon assets/aurora-notepad.ico --scene-out samples/notepad-icon.scene.json
```

`--kind host|notepad|sticky|alert` generates a new seven-size ICO, and
`--base64-out <file>` also writes its base64 form.

`samples/notepad-sticky.scene.json` is the checked-in sticky-icon demo and
embeds `assets/aurora-notepad-sticky.ico`.

With `--control`, a running window can also be changed directly with
`{"command":"setIcon","icon":"<base64 ICO>"}`. The host materializes and owns
the icon, so no scene edit or external HICON helper is needed. Clients can
detect this with the `live-icon-control` capability.

The host, icon author, and protocol generator are D. Python files under
`tools/` are development, test, and packaging tooling; they are not shipped in
the package and are not required by the host or by icon authoring.

Built-in authoring is procedural (`host`, `notepad`, `sticky`, `alert`).
Arbitrary artwork is still supported at runtime by supplying an ICO through
`window.icon` or `setIcon`; the authoring tool does not draw freeform art.

## Portable package

[PACKAGING.md](PACKAGING.md) defines the Windows x64 distribution layout,
runtime contract, launch model, and clean-extraction verification. The package
contains only the release windowed host, sample scenes and assets,
package-local documentation, and license notices. It uses the Windows system
CRT (`msvcrt.dll`) and does not require or bundle a Microsoft Visual C++
Redistributable. Windows 10/11 x64 is the supported target.

`tools/package_host.py` builds and stages a directory plus zip; it refuses to
overwrite an existing output unless `--clean` is passed. `tools/verify_package.py`
extracts the zip to a fresh temporary directory, verifies `MANIFEST.sha256`,
checks and renders both a text scene and the image-asset scene, and drives the
live control channel.

`verify.json` builds the windowed host into `build/verify` before the UI-depth
check, so verification can run while a demo instance is open. Its final render
comparison normalizes the live screenshot to the owner-approved 1225x800
(125% DPI) reference's 980x640 logical viewport and allows up to 2% differing
pixels for DPI-dependent glyph hinting; layout, chrome, and color checks remain
exact. Use
`verify-source.json` for a DPI-independent compile and source/control/render
gate.

The 1x UI-depth golden is reproducibly projected from the owner-approved 125%
reference:

```text
python tools/normalize_ui_screenshot.py --screenshot samples/ui-depth-reference.png --reference samples/ui-depth-ref1x.png --out samples/ui-depth-ref1x.png
```


Direct CLI modes:

```text
--version
--capabilities
--check samples/hello.scene.json
--check samples/editor.scene.json
--check samples/canvas.scene.json
--check samples/animation.scene.json
--check samples/image.scene.json
--check samples/surface.scene.json
--render samples/hello.scene.json --out build/hello.ppm
--run samples/hello.scene.json
```

`--render` is intended for the `host-headless` configuration. `--run` is the
windowed configuration.

## Text rendering

The host inherits Aurora's shared `sharp`, foreground-aware grayscale policy,
with maximum coverage contrast `0.5`. It no longer installs a private contrast
override. Dark foreground text receives less coverage boosting; near-white text
keeps the established transfer. Font metrics and layout are unchanged.
`AURORA_TEXT_COVERAGE=legacy` selects the former framework transfer, and
`AURORA_TEXT_CONTRAST` remains an explicit diagnostic override. Owner-approved
natural grayscale hinting C is the shared default. `AURORA_HINTING=0` restores
the previous unhinted B rendering; `1` selects the older diagnostic interpreter.

## Control channel

Launch with `--control` to enable JSON lines on stdin/stdout:

```text
aurora-host-experiment.exe --run samples/hello.scene.json --control
```

The host prints `READY`. Send one JSON object per line:

```json
{"id":1,"command":"tree"}
{"id":2,"command":"click","node":"hello"}
{"id":3,"command":"setText","node":"status","text":"Changed by client"}
{"id":4,"command":"getText","node":"editor"}
{"id":5,"command":"setWordWrap","node":"editor","wrap":true}
{"id":6,"command":"getEditorState","node":"editor"}
{"id":7,"command":"setSelection","node":"editor","start":0,"end":4}
{"id":8,"command":"setText","node":"editor","text":"Silent","notify":false}
{"id":9,"command":"setCanvas","node":"plot","commands":[{"op":"rect","x":0,"y":0,"width":10,"height":10,"color":"#00ff00"}]}
{"id":10,"command":"setTick","node":"plot","hz":60}
{"id":11,"command":"pointer","node":"plot","kind":"down","x":40,"y":30,"button":"left"}
{"id":12,"command":"key","node":"plot","kind":"down","key":"a","modifiers":1}
{"id":13,"command":"inputmap"}
{"id":14,"command":"fileDialog","mode":"open","title":"Open file"}
{"id":15,"command":"screenshot","path":"build/control-shot.ppm"}
{"id":16,"command":"setIcon","icon":"<base64 ICO>"}
{"id":17,"command":"close"}
{"id":18,"command":"reload"}
```

Responses are `RESPONSE {json}`; button events are `EVENT {json}`. A button
with an `action` field emits an action event instead of the default activation
event. All widget access happens on the UI thread; the reader thread only queues
commands.

`reload` reparses the scene file used at launch and replaces the retained tree in
the existing window. `--watch` does the same automatically when the file's
modification time changes. A reload keeps the window and control session alive;
invalid scene edits are reported on stderr and leave the previous tree visible.
`setIcon` replaces the live window icon from a base64 ICO until the next reload.

Canvas and surface nodes opt into events with `"events":["pointer","key","tick"]`.
Pointer events report local `x`/`y`, button, and modifiers; wheel events also
report `wheelX`/`wheelY`. Key events report `key` and `modifiers`. `setTick`
emits `tick` events with a `delta` in seconds, and the client must change its own
labels in response. Injected `pointer` and `key` commands exercise the same
scene path as real window input and are useful for deterministic tests.

## Editor state and events

`textArea` nodes support reading and replacing text, word wrapping, editor state,
and logical selections. `textField` nodes are the same editor widget in
single-line mode and are useful for search boxes and command inputs.

`setText` notifies editor listeners by default. Pass `"notify":false` when a
client is restoring a document or setting a field programmatically and does not
want a change event.

`getEditorState` returns the text length, cursor, anchor, line, and column.
`setSelection` takes Unicode code-point offsets, sets a logical selection, and
focuses the editor. A node that opts into `change` and/or `cursor` events emits:

```text
EVENT {"event":"editor","node":"editor","kind":"change","cursor":12,
       "anchor":12,"length":12,"line":0,"column":12}
```

The host reports state; the application decides what it means. It does not
maintain a document model, dirty flags, file paths, or tab state.

The demo client launches the window, pings it, prints the tree, clicks
`hello`, verifies that the `status` label changed, captures the surface, and
closes the window:

```text
python tools/control_client.py
```

## Canvas

A `canvas` node records a portable draw list. Aurora paints it as part of the
normal retained scene; a static canvas repaints only when the widget is
invalidated. Canvas coordinates are local to the widget.

```json
{
  "id": "plot",
  "type": "canvas",
  "background": "#101820",
  "width": 320,
  "height": 240,
  "commands": [
    {"op":"rect","x":20,"y":20,"width":100,"height":60,"color":"#e63946"},
    {"op":"line","x":20,"y":100,"x2":300,"y2":100,"color":"#f1faee","thickness":3},
    {"op":"text","x":200,"y":145,"text":"Aurora","color":"#f1faee","scale":2}
  ]
}
```

Supported operations are `rect`, `roundedRect`, `line`, `circle`, `ring`, and
`text`. Colors are `#RRGGBB` or `#RRGGBBAA`. Optional `width`, `height`, and
`flex` fields participate in normal scene layout. The command count is bounded
by `maxCanvasCommands` in the generated protocol. A controller can replace the
draw list with the `setCanvas` command; the host invalidates and repaints the
same retained node.

## Images and events

An `image` node loads a PNG, JPEG, or other Aurora-decoded asset from a path
relative to the scene file or an absolute path. It participates in normal layout
and can be constrained with `width` and `height`. The `image` sample and
`tools/drive_image.py` verify the same pixels in headless and windowed modes.

`tools/drive_interaction.py` drives pointer down/move/up, wheel, key, and tick
events through `samples/interaction.scene.json`, checks the emitted events,
updates a label and canvas, and asserts the redrawn pixels in a screenshot.

## Shared surface

`surface` is the high-frequency data plane. The scene names a file, width, and
height:

```json
{
  "id": "live",
  "type": "surface",
  "path": "../build/live.surface",
  "width": 320,
  "height": 240,
  "staleMs": 250,
  "events": ["pointer", "key"],
  "flex": 1
}
```

The file is a little-endian, versioned mapping. The generated
[API reference](generated/api.md) lists every header offset and the event ring
layout. The current surface version is `2`, the header is 80 bytes, input events
are 24 bytes, and there are two RGBA8 frame buffers after a 64-event ring:

Scene `width` and `height` are logical layout extents. The header dimensions are
native RGBA pixels and may be the host-preferred `logical * displayScale` size;
the host scales that image into the scene bounds. At 96 DPI, a 320x240 surface
therefore accepts a 320x240 native frame; at 200% it accepts 640x480. The control
response exposes `pixelWidth`, `pixelHeight`, `displayScale`,
`preferredWidth`, and `preferredHeight` so a producer can match the window.

```text
kind:u8, button:u8, key:u16, modifiers:u32,
x:i32, y:i32, wheelX:i32, wheelY:i32
```

Pointer and wheel `x`/`y` are logical surface coordinates matching the scene
`width` and `height`; a producer sampling a native buffer scales them by the
native-to-logical ratio.

The writer fills the inactive buffer, sets `active`, then increments `frameSeq`.
The host copies the active buffer on its normal tick and publishes the copied
sequence in `hostReadSeq`; a writer waits for that acknowledgement before reusing
the buffer. The host appends input at `inputTail`; the client reads from
`inputHead` and advances it after consuming. `head == tail` is empty and
`tail - head == inputCapacity` is full.

The `surface` control response reports `inputDropped` and `inputCoalesced`
counters plus `frameAgeMs` and `stale`; `staleMs` configures the staleness
window (default 500 ms, minimum 50). `inputDroppedMoves` and
`inputDroppedDiscrete` classify saturation: up to eight ring slots are
reserved for key, button, and wheel events (smaller rings reserve roughly a
quarter, with at least one slot when capacity is greater than one), so pointer
motion cannot starve a later key-up or button-up. Adjacent identical
pointer moves are coalesced
because motion is state rather than an ordered command; the coalescing counter
records how many duplicate samples were absorbed. `inputmap` returns the
numeric key, modifier, button, and event-kind contract used by the ring, so
clients do not have to hard-code undocumented Aurora enum values.

Mapping failures are reported instead of silently retried. A missing file,
incompatible magic/version/layout, and an open failure leave `mapped:false` with
an `error` string; `retryInMs` reports the next retry. A live mapping that later
fails validation is unmapped and reports the new error, so a stale image cannot
survive a malformed replacement.

No draw commands cross the JSON channel per frame. `tools/drive_surface.py`
publishes a checker frame and a software-rasterized, z-buffered rotating cube
directly into the mapping, verifies the resulting screenshots, and checks the
pointer, wheel, and key records in the input ring.

## Animated canvas

`samples/animation.scene.json` opts a canvas into `tick` events at 20 Hz.
`tools/drive_animation.py` redraws two waveforms and a phase marker for three
successive ticks, then asserts that each screenshot contains the expected wave
colors and has a distinct pixel hash:

```text
python tools/drive_animation.py
```

This is the application-owned 2D path: the host supplies the retained canvas,
the frame clock, and invalidation; the client owns what the animation means and
when to replace the draw list. For high-frequency or engine-owned rendering,
use the shared surface instead of sending a large draw list every frame.

## Browser and engine boundary

The host deliberately does not embed a browser, JavaScript runtime, or 3D game
engine. Those are application dependencies with their own compositors, asset
loaders, GPU device lifecycles, and security models. The host provides the
window, retained scene, input routing, frame clock, file dialogs, and control
channel around them.

The supported integration path today is the shared surface:

1. The application creates an offscreen browser or engine render target.
2. It copies or converts that frame into the versioned RGBA8 surface buffer.
3. The host composites that single retained `surface` node on its normal tick.
4. Pointer, wheel, and key records flow back through the input ring.

This boundary is what the rotating-cube demo exercises. A browser would use a
WebView2 or Chromium offscreen target in the same role; a 3D application would
use its own renderer and publish the result. No per-frame JSON draw commands or
cross-thread widget mutation are required.

Not implemented yet: a native plugin ABI, a GPU-shared texture or compositor
handoff, audio/video services, and a packaged WebView2 host. Those would be
separate optional modules, not reasons to make the core host own browser or
engine policy. The current surface ABI uses a CPU-visible mapping and is an
experiment, not a stable binary contract.

The integration contract for out-of-process modules is
[MODULES.md](MODULES.md). It defines the version/capability handshake, lifecycle,
frame ownership, input-ring rules, failure recovery, and shutdown expectations.
It also states the deliberate v1 limits: no focus/IME/drag-drop events, no GPU
handoff, and no host-side module supervision.

## Separate demos

The host does not contain application-specific notepad code. A separate
[aurora-host-notepad](../aurora-host-notepad/) project supplies the scene and
document policy, while the host supplies the editable UI, actions, rendering,
and control channel.

[aurora-host-notepadpp](../aurora-host-notepadpp/) goes further: an eight-slot
tabbed workbench with file dialogs, dirty state, find/replace, language
metadata, editor events, and a measured large-document benchmark. Unwrapped
documents no longer allocate a display-row map proportional to the document;
selection and scrolling use the logical line index directly. Wrapped documents
keep a per-line row index and shape only viewport rows. A 100,000-line
stress pass in the core editor test measures `setText`, end-of-document
selection, wrap toggling, and wrapped selection, failing if any operation
exceeds five seconds.

## Layout

```text
protocol/aurora-host.api.json   single source of truth
MODULES.md                      out-of-process module contract and lifecycle
generated/                      generated protocol constants and API reference
source/                         scene parser, widget builder, host CLI
samples/                        valid scenes, including editor, canvas, animation, image, and surface
tests/                          invalid scene fixture
tools/                          generator, control clients, and verifier
PACKAGING.md                    portable package layout and runtime contract
build/                          ignored build and render output
LICENSE                         0BSD source-code license
LICENSE-CC0.txt                 CC0-1.0 documentation and sample-content license
THIRD-PARTY-NOTICES.md          vendor, Unicode, MIT, and Microsoft runtime notices
```

## Scope

This is an experiment, not a standard:

- no binary ABI or socket protocol yet; stdin/stdout control is the current IPC;
- the shared-surface file format is a versioned experiment ABI, not a stable
  plugin ABI;
- no built-in browser, JavaScript runtime, audio pipeline, or 3D engine; those
  integrate through an application-owned offscreen target and the shared surface;
- no client library or language bindings yet;
- no widget protocol beyond labels, buttons, text areas, text fields, canvases,
  images, surfaces, rows, columns, and spacers;
- no promise of API stability.

The next experiment can add a native C/plugin ABI, GPU-shared textures, or a
retained-scene client protocol without changing this folder's isolation rule:
the experiment may depend on vendor packages, but no vendor or application code
may depend on the experiment.

## License

The host's source code, protocol schema, generated constants, and tools are
released under **0BSD**; see [LICENSE](LICENSE). Documentation, sample scenes,
images, and sample assets are released under **CC0-1.0**; see
[LICENSE-CC0.txt](LICENSE-CC0.txt).

The vendored `aurora-d` and `aurora-standard` packages, Unicode data, the
Microsoft Terminal MIT material, and the DMD runtime retain their own licenses.
See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). These notices do not
relicense vendor code.
