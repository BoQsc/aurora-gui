# Aurora Notes

A starter Aurora v2 project built as an `aurora-host` scene.

This is a project, not a new executable: the scene is the program. The host
owns the window, layout, painting, input routing, and DPI.

## Run

From `aurora-host/`:

```text
aurora-host.exe --run projects/aurora-notes/app.scene.json
```

Live editing:

```text
aurora-host.exe --dev projects/aurora-notes/app.scene.json
```

Validate without opening a window:

```text
aurora-host-headless.exe --check projects/aurora-notes/app.scene.json
```

## Structure

- `app.scene.json` — the whole starter UI: title bar, toolbar, note sidebar,
  editor, and status row.
- The sidebar items are scene rows. Add notes by adding sibling rows.
- The editor is a host `textArea` with `change` and `cursor` events.
- Actions (`note.new`, `note.open`, `note.save`, `note.focus`) are ready to be
  handled by a module or control client through the host control channel.

## Next steps

1. Add more note rows and a selected-state background.
2. Move domain state into a module once editing needs persistence.
3. Keep the host as the window/scene owner; do not add a new `GuiWindow`
   executable for the project.
