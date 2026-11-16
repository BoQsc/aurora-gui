# Aurora Designer: Panel selection and repeated dragging are unreliable

## Summary

A Panel cannot be reliably selected or moved with normal clicks once it contains a child. Clicking the Panel often selects the child instead, and after dragging a Panel the next click or drag is difficult or nearly impossible. Adding a Button while a Panel is selected can also place the Button in the Window instead.

## Environment

- Aurora Designer, current build.
- Single-window artboard: `window1` containing `panel2`, with a Button or Label inside `panel2`.

## Steps to reproduce

1. Add a Window.
2. Add a Panel inside the Window.
3. Add a Button inside the Panel.
4. Click the Panel normally, including where its child sits.
5. Click the same point again without moving.
6. Drag the Panel, release, then click or drag it again.
7. Select the Panel and add another Button.

## Expected behavior

- A normal click on a visible Panel selects the Panel, even when a child overlaps it.
- A click directly on the child still selects the child.
- Dragging the child moves the child; dragging the Panel moves the Panel.
- A Panel can be dragged repeatedly; the next click after a drag works immediately.
- A Button added while `panel2` is selected becomes a child of `panel2`, not `window1`.

## Actual behavior

- A click over a Panel lands on its deepest child.
- Clicking the child again does not reliably select the parent Panel.
- After dragging a Panel, clicking or dragging it again is difficult or nearly impossible.
- Adding a Button while a Panel is selected can place it in the Window instead.
- The nested-container workflow is not reliable enough to use.

## Evidence

- Physical click on empty Panel area: selected `panel2`.
- Physical click on the child: selected `button3`.
- Physical stationary second click on the child: still `button3`, not `panel2`.
- The child-covered Panel cannot be selected through a normal click path.
- Headless tests passed while the native layered-click workflow failed.

## Impact

The core workflow — selecting a Panel, adding children, moving a child, and moving the Panel again — is blocked. The Panel must be selectable directly and repeatably, not only through Layers or a special control.
