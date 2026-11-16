# Aurora Designer

A visual UI designer for Aurora-D interfaces. Build a real widget hierarchy with
the palette, canvas, Layers tree, and inspector, then copy the generated D code.

The window uses a visible 28 px frameless titlebar with the document name, dirty
marker, app icon, and minimize/maximize/close controls. Drag the bar to move the
window, double-click it to maximize, or right-click it for the system menu.

## Hierarchy interactions

- The palette shows its current `Adds to:` container. Clicking an entry adds the
  widget centered in the selected container, or as a sibling under its parent
  when the selection cannot host children. The palette also targets the
  container under a drag.
- Dragging from the palette shows a drop preview and highlights the target
  container. The widget is placed in that container's coordinate space, clamped
  to its bounds. On an empty artboard, the first drop creates the root window.
- The canvas selects the widget painted topmost under the pointer. A visible
  child wins even where it spills outside its container, and a container's own
  body selects the container. Alt-click selects the parent; the Layers tree and
  inspector also expose parent selection. Every container except the window
  shows a title chip at its top-left that selects and drags the container; the
  rest of the top edge stays clickable for children. Drag a selected widget
  onto another container to reparent it while preserving its artboard position;
  a drop target is shown during the drag. Corner handles resize the selected
  widget.
- The Layers tree shows the hierarchy with indentation and collapsible rows.
  Click a row to select it. Right-click for add-child, select-parent, raise,
  lower, bring-to-front, send-to-back, and delete actions.
- The inspector shows type, depth, parent, and child count. Containers offer
  `Add panel child`; child nodes offer `Select parent`; non-root nodes expose
  Front/Back/Up/Down sibling-order controls.

This is a v2 package. It depends on the sibling
[`../aurora-d`](../aurora-d) library through DUB; it has no vendored library
copy and no version number in its folder name.

## Build and run

From this folder:

```sh
dub build --config=default
dub run --config=default
```

The windowed build links as a Windows GUI executable, so no console window
appears. The `default` configuration is also what plain `dub run` selects.

## Headless smoke

```sh
dub run --config=headless-smoke
```

It exercises the titlebar layout, hierarchical child insertion, palette click
and drag, empty-artboard root creation, paint/hit order, sibling z-order,
canvas reparenting, resizing, code generation, serialization, undo/redo, and
pointer routing. It writes `build/headless-smoke/designer-smoke.ppm`.

For a software-rendered screenshot from the windowed build:

```text
aurora-designer.exe --screenshot build\designer.ppm
```

## Verification

The v2 gate includes this package:

```text
cd ..
python -B verify.py
```

All tooling is Python or DUB; there are no PowerShell or batch launchers.