# Live scene building

This is the tight loop for building a scene with an assistant while the host
window stays open.

## The single executable

Copy `aurora-host-experiment.exe` anywhere and run:

```text
aurora-host-experiment.exe --dev
```

With no scene argument, the executable writes `aurora-scene.json` from its
embedded starter scene in the current directory and opens it. Pass a path to
open an existing scene:

```text
aurora-host-experiment.exe --dev samples/live-lab.scene.json
```

The host-owned `DEV · SCENE SOURCE` panel floats on the right. It survives a
reload:

- The **project path** field is the project selector. Type or paste a path and
  use **New** (creates the starter there), **Open** (reads and applies it), or
  **Save As** (writes the current source there and makes it the project).
- **Live** is on by default: edits apply about 250 ms after you stop typing. No
  Reload click is required for gradual scene building.
- **Reload** writes the editor source to the scene file and applies it.
- **Save** writes the editor source without applying it.
- **Live** can be toggled off when a deterministic manual Reload is wanted.
- Errors are reported in the panel; an invalid reload leaves the previous tree
  visible.

Live edits are validated in a temporary file before the real scene file is
written. A partial or invalid edit therefore cannot corrupt the project or
replace the last valid tree. Focus and caret in the source editor are restored
after each apply.

`--dev --control` exposes the panel through the existing control channel:
`aurora.dev.source`, `aurora.dev.path`, `aurora.dev.reload`, `aurora.dev.save`,
`aurora.dev.new`, `aurora.dev.open`, and `aurora.dev.saveas`. No Python, browser,
D compiler, or IDE is required to use `--dev`.

For automation, the host itself can expose the same JSON-lines protocol on a
loopback socket:

```text
aurora-host-experiment.exe --dev samples/live-lab.scene.json --listen 8795
python -B tools/live_cli.py --port 8795 '{"command":"ping"}'
```

`--listen` mirrors the normal `RESPONSE {...}` and `EVENT {...}` stream. The
Python bridge is now optional legacy tooling; it is not required for the live
loop, screenshots, or control.

The scene file is the program. The executable creates the first one; you edit
and save it in the panel.

The project path is deliberate instead of a modal file dialog: it is keyboard
driven, visible, and testable through the same control channel. A native file
browser is a later UI addition, not a runtime dependency.

### Current limits

- The package target is Windows 10/11 x64. Do not claim other hosts without a
  separate port and verification.
- The panel is an overlay on the right, not a split-pane editor; **Hide** collapses
  it to a small **DEV** tab so the scene can be viewed full-width.
- Each live apply still replaces the retained tree. Gradual scene building works,
  but application state stored inside the scene resets; incremental node patches
  are the next step.
- Custom D widgets and host components still require a host rebuild. Apps that
  render themselves can use the shared surface.
- Project selection is the editable path field, not a native file browser. The
  path, New, Open, and Save As actions are host-owned and testable.

## Scope boundary

The host is a Windows 10/11 x64 scene runner with a compile-time component set.
These are deliberate boundaries, not silent gaps:

- **Custom D widgets/components:** there is no dynamic widget ABI. A component
  is compiled into the host. Programs that render themselves use the shared
  surface instead of a plugin DLL.
- **Cross-platform packaging:** only Windows 10/11 x64 is built and verified
  here. Linux/macOS packaging needs separate platform builds and test receipts.
- **Single-file project container:** the executable creates a scene file next to
  it. A project bundle/container is a separate storage design.

Changing any of these is an architectural extension with its own verification,
not a switch in the scene schema.

## Pieces

- `--listen <port>` is the supported host-native automation transport.
- `tools/live_bridge.py` is legacy tooling that owns a visible host
  (`--control --watch`) and
  exposes a loopback JSON-lines socket.
- `tools/live_cli.py` sends one command and prints the response.
- `samples/live-lab.scene.json` is the scene currently being edited.

## Start

Build the windowed host once:

```text
dub build --config=host --build=release --dest=build/live-harness/host
```

Start the host directly with its native socket:

```text
aurora-host-experiment.exe --dev samples/live-lab.scene.json --listen 8791
```

Check it:

```text
python -B tools/live_cli.py --port 8791 '{"command":"ping"}'
```

The bridge is legacy tooling; use it only when you need its PNG conversion or
combined layout snapshot:

```text
python -B tools/live_bridge.py --daemon --port 8792
python -B tools/live_cli.py --port 8792 '{"command":"ping"}'
```

Capture the live window as a PNG:

```text
python -B tools/live_cli.py '{"command":"screenshot","path":"build/live-harness/shots/now.png"}'
```

Read the tree and every node's global rectangle:

```text
python -B tools/live_cli.py '{"command":"snapshot"}'
```

Stop the bridge and host cleanly:

```text
python -B tools/live_cli.py '{"command":"shutdown"}'
```

## Two speeds

1. **State-preserving changes** go through the control channel: `setText`,
   `setCanvas`, `setChrome`, `setMenu`, `setTabs`, `setEditorView`, `click`,
   `pointer`, and `key`. These do not reload the scene, so focus, selection, and
   editor state stay put.
2. **Structural changes** edit `samples/live-lab.scene.json` and then reload:

   ```text
   python -B tools/live_cli.py '{"command":"reload"}'
   ```

   The window and control session stay alive. An invalid scene reports the
   error and leaves the previous tree visible. `--watch` also reloads on a file
   mtime change; send `reload` explicitly when a deterministic checkpoint is
   wanted after an edit.

## What the bridge adds

- `screenshot` converts the host's PPM capture to PNG and returns the path.
- `snapshot` returns the tree plus each node's global rectangle, so layout and
  clipping can be checked without guessing from pixels.
- `events` drains button/action and editor events.
- `shutdown` closes the host and removes the pid file.
- `BRIDGE_DAEMON` launches a detached copy, so a tool turn cannot kill the
  window.

## Notes and limits

- The socket binds to `127.0.0.1` only. This is a local development tool, not a
  security boundary.
- `--listen` accepts one loopback client at a time; commands are serialized
  through the same UI-thread queue as stdin.
- The bridge copies the executable into `build/live-harness/run/<stamp>/` so the
  build output stays unlocked.
- The scene is tracked; screenshots, logs, pid file, and run copies live under
  the ignored `build/live-harness/`.
- A reload still replaces the whole retained tree. Use control commands for
  changes that must not lose state; incremental scene patching is the next
  architectural step.
