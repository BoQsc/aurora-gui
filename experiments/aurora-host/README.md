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

## Commands

```text
python tools/generate_reference.py --check
python tools/verify_experiment.py
python tools/editor_control_test.py

dub run --config=host -- samples/hello.scene.json
dub run --config=host-headless -- --render samples/hello.scene.json --out build/hello.ppm
python tools/control_client.py
```

Direct CLI modes:

```text
--version
--capabilities
--check samples/hello.scene.json
--check samples/editor.scene.json
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
{"id":6,"command":"fileDialog","mode":"open","title":"Open file"}
{"id":7,"command":"screenshot","path":"build/control-shot.ppm"}
{"id":8,"command":"close"}
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
samples/                        valid scenes, including the editor primitive
tests/                          invalid scene fixture
tools/                          generator, control clients, and verifier
build/                          ignored build and render output
```

## Scope

This is an experiment, not a standard:

- no binary ABI or socket protocol yet; stdin/stdout control is the current IPC;
- no client library or language bindings yet;
- no widget protocol beyond labels, buttons, text areas, rows, columns, and
  spacers;
- no promise of API stability.

The next experiment can add a retained-scene client protocol or a C ABI without
changing this folder's isolation rule: the experiment may depend on vendor
packages, but no vendor or application code may depend on the experiment.
