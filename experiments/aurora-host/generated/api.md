# aurora-host experiment protocol

**Generated from `protocol/aurora-host.api.json`.** Do not edit manually.

- Experiment version: `0.4.5`
- Protocol version: `9`
- Schema version: `2`
- Max scene depth: `16`
- Max scene nodes: `256`
- Max canvas commands: `4096`
- Max surface pixels: `4000000`
- Max input events: `4096`

## Capabilities

- `window`
- `scene`
- `canvas`
- `image`
- `surface`
- `label`
- `button`
- `row`
- `column`
- `spacer`
- `headless-render`
- `control-stdin`
- `text-editor`
- `text-field`
- `text-selection`
- `editor-view`
- `editor-styles`
- `editor-font-zoom`
- `editor-events`
- `assets`
- `pointer-events`
- `key-events`
- `frame-events`
- `shared-surface`
- `surface-diagnostics`
- `surface-dpi`
- `surface-input-reserve`
- `surface-stale-policy`
- `menu`
- `dynamic-menu`
- `tabs`
- `separator`
- `popup-menu`
- `context-menu`
- `ui-test-driver`
- `tooltips`

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
| `menu` | no | yes | no | no |
| `tabs` | no | no | no | no |
| `separator` | no | no | no | no |
| `textArea` | no | yes | no | no |
| `textField` | no | yes | no | no |
| `canvas` | no | no | no | no |
| `image` | no | no | no | no |
| `surface` | no | no | no | no |
| `spacer` | no | no | no | no |

## Common node fields

- `id`: optional unique string; derived from the node path when omitted
- `action`: optional button action name; emits an action event instead of the default activation event
- `events`: optional canvas/surface events (pointer, key, tick) or editor events (change, cursor)
- `tickHz`: optional canvas tick rate from 1 to 240; defaults to 0 (disabled)
- `tooltip`: optional plain-text hover hint; shown after a short dwell and hidden by popups or pointer exit

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
| `setText` | Set label, button, or editor text by node ID; notify:false suppresses editor change events. |
| `getText` | Read text from a text-editor node by ID. |
| `getEditorState` | Read text length, cursor, anchor, line, and column from an editor. |
| `setSelection` | Select a Unicode code-point range in an editor and focus it. |
| `setWordWrap` | Set word wrapping on a text-editor node. |
| `setEditorView` | Set lineNumbers, highlightCurrentLine, and/or a pixel fontSize override on a host text editor. |
| `setEditorStyles` | Replace non-overlapping token color ranges on a host text editor. |
| `setCanvas` | Replace a canvas node's command list by node ID. |
| `setTick` | Set a canvas tick rate by node ID. |
| `setTabs` | Replace the tab list on a tabs node by node ID. |
| `setChrome` | Update button style, icon, active state, text color, or font size by node ID. |
| `setMenu` | Replace a menu node's popup items, including checked and enabled state. |
| `getBounds` | Return a node's global rectangle. |
| `getTabs` | Return tab labels, actions, active/dirty flags, and global rectangles. |
| `uiClick` | Route a real pointer click through the UI input pipeline at global coordinates. |
| `uiMove` | Route a real pointer move through the UI input pipeline at global coordinates. |
| `tooltipState` | Report the active hover hint's node, text, visibility, and global rectangle. |
| `menu` | Open a menu node's popup menu by node ID. |
| `menuState` | Report the open popup menu rectangle, item geometry, and item state. |
| `menuClick` | Click a popup menu item by index and verify that the popup closed. |
| `pointer` | Inject a pointer event into a canvas or surface. |
| `key` | Inject a keyboard event into a canvas or surface. |
| `inputmap` | Report key, modifier, mouse-button, and event-kind codes used by the shared surface. |
| `surface` | Report surface mapping, frame sequence, input ring position, coalescing/drop counters, and frame freshness. |
| `fileDialog` | Open Aurora's generic open/save file dialog and return a path. |
| `click` | Activate a button by node ID. |
| `screenshot` | Save the current surface as a PPM. |
| `close` | Close the host window. |

## Shared surface

- Magic: `AURSFACE`
- Version: `2`
- Header size: `80`
- Input event size: `24`
- Frame buffers: `2`
- Input layout: kind:u8, button:u8, key:u16, modifiers:u32, x:i32, y:i32, wheelX:i32, wheelY:i32
- Frame layout: two consecutive width*height*4 RGBA8 buffers after header and input ring; active selects the readable buffer
- frame: the writer fills an inactive buffer, sets active, then increments frameSeq; the host copies the active buffer and writes the copied sequence to hostReadSeq; writers may reuse a buffer after hostReadSeq catches up with the frame that used it
- input: the host appends events at inputTail and the external consumer reads from inputHead, advancing inputHead after consuming; head == tail means empty and tail - head == inputCapacity means full
- inputReserve: up to inputReserve slots are reserved for discrete key, button, and wheel events so pointer motion cannot starve them; smaller rings reserve roughly a quarter of their capacity, at least one when capacity is greater than one
- inputCoordinates: pointer and wheel x/y are logical surface coordinates matching scene width/height; a writer sampling a native buffer scales them by native/logical
- dpi: scene width/height are logical layout extents; header width/height are native RGBA pixels, normally the host-preferred logical*displayScale size; the host scales the native image into the logical bounds
- wheel: kind 4 records pointer position in x/y and wheel deltas in wheelX/wheelY

| Header offset | Field |
|---|---|
| `0` | `magic` |
| `8` | `version` |
| `12` | `headerSize` |
| `16` | `width` |
| `20` | `height` |
| `24` | `active` |
| `28` | `inputCapacity` |
| `32` | `frameSeq` |
| `40` | `hostReadSeq` |
| `48` | `inputHead` |
| `52` | `inputTail` |
| `56` | `inputEventSize` |
| `60` | `bufferCount` |
| `64` | `frameBytes` |
