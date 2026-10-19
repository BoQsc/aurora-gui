# aurora-host experiment protocol

**Generated from `protocol/aurora-host.api.json`.** Do not edit manually.

- Experiment version: `0.1.0`
- Protocol version: `1`
- Schema version: `1`
- Max scene depth: `16`
- Max scene nodes: `256`
- Max canvas commands: `4096`

## Capabilities

- `window`
- `scene`
- `canvas`
- `label`
- `button`
- `row`
- `column`
- `spacer`
- `headless-render`
- `control-stdin`
- `text-editor`

## Window

| Field | Type |
|---|---|
| `title` | string |
| `width` | int |
| `height` | int |
| `theme` | light|dark |

## Node types

| Type | Children | Text | Scale | Spacing |
|---|---|---|---|---|
| `column` | yes | no | no | yes |
| `row` | yes | no | no | yes |
| `label` | no | yes | yes | no |
| `button` | no | yes | no | no |
| `textArea` | no | yes | no | no |
| `canvas` | no | no | no | no |
| `spacer` | no | no | no | no |

## Common node fields

- `id`: optional unique string; derived from the node path when omitted
- `action`: optional button action name; emits an action event instead of the default activation event

## Commands

| Command | Meaning |
|---|---|
| `--version` | Print experiment, protocol, and Unicode versions. |
| `--capabilities` | Print supported capabilities and scene node types. |
| `--check <scene>` | Validate a scene without creating a window. |
| `--render <scene> --out <file.ppm>` | Render headlessly to a PPM file. |
| `--run <scene>` | Open an Aurora window and run the scene. |

## Control channel

Transport: stdin/stdout JSON lines; launch --run <scene> --control

| Command | Meaning |
|---|---|
| `ping` | Liveness check. |
| `status` | Window size, renderer, and node count. |
| `tree` | List node IDs, types, and text. |
| `setText` | Set label, button, or editor text by node ID. |
| `getText` | Read text from a text-editor node by ID. |
| `setWordWrap` | Set word wrapping on a text-editor node. |
| `setCanvas` | Replace a canvas node's command list by node ID. |
| `fileDialog` | Open Aurora's generic open/save file dialog and return a path. |
| `click` | Activate a button by node ID. |
| `screenshot` | Save the current surface as a PPM. |
| `close` | Close the host window. |
