# aurora-host experiment

An isolated experiment for a portable Aurora UI host. It is a leaf: it depends
on `vendor/aurora-d-0.4.5` and `vendor/aurora-standard`, but nothing in the
repository depends on it. Delete this folder and Aurora is unaffected.

## What it proves

- A scene file is the stable, user-facing contract.
- The protocol constants and reference are generated from one schema.
- The host validates a scene without creating a window.
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

dub run --config=host -- samples/hello.scene.json
dub run --config=host-headless -- --render samples/hello.scene.json --out build/hello.ppm
dub run --config=host-headless -- --render samples/canvas.scene.json --out build/canvas.ppm
dub run --config=host-headless -- --render samples/image.scene.json --out build/image.ppm
python tools/control_client.py
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
{"id":13,"command":"fileDialog","mode":"open","title":"Open file"}
{"id":14,"command":"screenshot","path":"build/control-shot.ppm"}
{"id":15,"command":"close"}
```

Responses are `RESPONSE {json}`; button events are `EVENT {json}`. A button
with an `action` field emits an action event instead of the default activation
event. All widget access happens on the UI thread; the reader thread only queues
commands.

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
  "events": ["pointer", "key"],
  "flex": 1
}
```

The file is a little-endian, versioned mapping. The generated
[API reference](generated/api.md) lists every header offset and the event ring
layout. The current surface version is `2`, the header is 80 bytes, input events
are 24 bytes, and there are two RGBA8 frame buffers after a 64-event ring:

```text
kind:u8, button:u8, key:u16, modifiers:u32,
x:i32, y:i32, wheelX:i32, wheelY:i32
```

The writer fills the inactive buffer, sets `active`, then increments `frameSeq`.
The host copies the active buffer on its normal tick and publishes the copied
sequence in `hostReadSeq`; a writer waits for that acknowledgement before reusing
the buffer. The host appends input at `inputTail`; the client reads from
`inputHead` and advances it after consuming. `head == tail` is empty and
`tail - head == inputCapacity` is full.

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

## Separate demos

The host does not contain application-specific notepad code. A separate
[aurora-host-notepad](../aurora-host-notepad/) project supplies the scene and
document policy, while the host supplies the editable UI, actions, rendering,
and control channel.

[aurora-host-notepadpp](../aurora-host-notepadpp/) goes further: an eight-slot
tabbed workbench with file dialogs, dirty state, find/replace, language
metadata, editor events, and a measured large-document benchmark. Its self-test
also exposes the current scaling limit: the first full layout of a 214 KB
document takes roughly 1.5-2.4 s on a release host build, a 5,000-line document
stalls during end-of-document selection, and a 100,000-line stress run is not
viable because retained editor layout and memory grow steeply with document
size. Normal small-document editing remains responsive.

## Layout

```text
protocol/aurora-host.api.json   single source of truth
generated/                      generated protocol constants and API reference
source/                         scene parser, widget builder, host CLI
samples/                        valid scenes, including editor, canvas, animation, image, and surface
tests/                          invalid scene fixture
tools/                          generator, control clients, and verifier
build/                          ignored build and render output
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
