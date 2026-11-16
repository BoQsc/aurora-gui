# Aurora Designer

A visual UI designer for Aurora-D interfaces. Drag widgets from the palette,
position them on the artboard, edit properties in the inspector, and copy the
generated D code.

Click a palette entry to add the widget at the artboard center, or drag it onto
the artboard to place it under the pointer. Dragging a widget already on the
artboard moves it; its corner handles resize it.

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

It exercises the designer's document model, selection, drag, palette add,
code generation, serialization round-trip, undo/redo, and pointer routing. It
writes `build/headless-smoke/designer-smoke.ppm`.

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