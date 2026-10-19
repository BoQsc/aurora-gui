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
- Scenes can contain retained custom-drawn canvases using portable primitives.

## Commands

```text
python tools/generate_reference.py --check
python tools/verify_experiment.py
python tools/editor_control_test.py
python tools/canvas_test.py
python tools/canvas_control_test.py

dub run --config=host -- samples/hello.scene.json
dub run --config=host-headless -- --render samples/hello.scene.json --out build/hello.ppm
dub run --config=host-headless -- --render samples/canvas.scene.json --out build/canvas.ppm
python tools/control_client.py
```

Direct CLI modes:

```text
--version
--capabilities
--check samples/hello.scene.json
--check samples/editor.scene.json
--check samples/canvas.scene.json
--render samples/hello.scene.json --out build/hello.ppm
--run samples/hello.scene.json
```

`--render` is intended for the `host-headless` configuration. `--run` is the
windowed configuration.

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
{"id":6,"command":"setCanvas","node":"plot","commands":[{"op":"rect","x":0,"y":0,"width":10,"height":10,"color":"#00ff00"}]}
{"id":7,"command":"fileDialog","mode":"open","title":"Open file"}
{"id":8,"command":"screenshot","path":"build/control-shot.ppm"}
{"id":9,"command":"close"}
```

Responses are `RESPONSE {json}`; button events are `EVENT {json}`. A button
with an `action` field emits an action event instead of the default activation
event. All widget access happens on the UI thread; the reader thread only queues
commands.

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

## Separate demos

The host does not contain application-specific notepad code. A separate
[aurora-host-notepad](../aurora-host-notepad/) project supplies the scene and
document policy, while the host supplies the editable UI, actions, rendering,
and control channel.

## Layout

```text
protocol/aurora-host.api.json   single source of truth
generated/                      generated protocol constants and API reference
source/                         scene parser, widget builder, host CLI
samples/                        valid scenes, including editor and canvas primitives
tests/                          invalid scene fixture
tools/                          generator, control clients, and verifier
build/                          ignored build and render output
```

## Scope

This is an experiment, not a standard:

- no binary ABI or socket protocol yet; stdin/stdout control is the current IPC;
- no client library or language bindings yet;
- no widget protocol beyond labels, buttons, text areas, canvases, rows,
  columns, and spacers;
- no promise of API stability.

The next experiment can add canvas input/frame events, a retained-scene client
protocol, or a native C/plugin ABI without changing this folder's isolation
rule: the experiment may depend on vendor packages, but no vendor or application
code may depend on the experiment.
