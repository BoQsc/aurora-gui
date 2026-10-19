# aurora-host-notepad

A separate notepad project built on the generic
[aurora-host](../aurora-host/) executable.

The host owns the window, layout, `TextArea` typing, selection, scrolling,
word wrap, painting, and the stdin/stdout control channel. This project owns
document policy: opening, saving, file dialogs, status text, and the scene file's
style and layout. The host contains no notepad-specific code.

## Run

Build the host once:

```text
cd ../aurora-host
dub build --config=host --compiler=dmd
```

Then run the notepad:

```text
python notepad.py --file notes.txt
```

Use the toolbar to create, open, save, save as, toggle word wrap, or close. Text
editing stays inside the host process; the controller only acts on toolbar
actions, so there is no per-keystroke IPC.

## Demo

```text
python notepad.py --demo
```

The demo builds a source document, loads it into the host, replaces it through
the control channel, clicks the real `Save` button, verifies the file on disk,
toggles word wrap, captures the live surface, and closes the host.

## Scene

[notepad.scene.json](notepad.scene.json) is the style and layout contract. It
uses generic host nodes: rows, columns, labels, buttons, and a `textArea`.
Buttons carry actions such as `save`; the controller handles those actions.
Nothing in the host assumes a notepad theme, toolbar, or document model.

## Verify

```text
python tools/verify_notepad.py
python -m unittest tests/test_notepad.py
```

The verifier compiles a fresh host in a temporary directory, runs the demo
against it, checks the saved Unicode document and the screenshot, and leaves the
repository untouched.

## Current scope

Supported now:

- real editable `TextArea` with selection, undo, clipboard, and scrolling;
- New, Open, Save, Save As, Word Wrap, and Close actions;
- generic host file dialog for Open/Save As;
- status/path labels updated by the controller;
- Unicode document round trip and live screenshot.

Not yet part of this demo:

- dirty-document close prompts;
- recent files and menu bar;
- line/column status driven by host change events;
- theme switching from the scene.

Those can be added in this project or as generic host primitives without putting
application policy back into the host.
