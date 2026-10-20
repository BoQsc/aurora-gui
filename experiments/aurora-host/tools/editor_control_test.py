#!/usr/bin/env python3
"""Exercise the host's generic text-area, action, and screenshot controls."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from control_client import HostSession


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=str(ROOT / "build" / "editor.ppm"))
    args = parser.parse_args()

    session = HostSession("samples/editor.scene.json")
    try:
        session.wait_ready()
        initial = session.send("getText", node="editor")
        if initial.get("text") != "Initial editor text":
            raise RuntimeError(f"unexpected initial editor text: {initial}")

        session.send("setText", node="search", text="needle")
        field = session.send("getText", node="search")
        if field.get("text") != "needle" or "\n" in field.get("text", ""):
            raise RuntimeError(f"unexpected text-field content: {field}")
        if not any(
            event.get("event") == "editor" and event.get("node") == "search"
            and event.get("kind") == "change"
            for event in session.events
        ):
            raise RuntimeError("text-field setText did not emit a change event")

        session.send("setText", node="editor", text="Edited by host control")
        edited = session.send("getText", node="editor")
        if edited.get("text") != "Edited by host control":
            raise RuntimeError(f"setText/getText mismatch: {edited}")

        state = session.send("getEditorState", node="editor")
        if (state.get("length") != len("Edited by host control")
                or state.get("cursor") != state.get("length")):
            raise RuntimeError(f"unexpected editor state: {state}")
        if not any(
            event.get("event") == "editor" and event.get("kind") == "change"
            for event in session.events
        ):
            raise RuntimeError("setText did not emit a change event")

        session.send("setSelection", node="editor", start=22, end=6)
        state = session.send("getEditorState", node="editor")
        if (state.get("cursor") != 6 or state.get("anchor") != 22
                or not state.get("hasSelection")):
            raise RuntimeError(f"setSelection did not set the range: {state}")
        if not any(
            event.get("event") == "editor" and event.get("kind") == "cursor"
            and event.get("cursor") == 6 and event.get("anchor") == 22
            for event in session.events
        ):
            raise RuntimeError("setSelection did not emit a cursor event")

        changes = sum(
            event.get("event") == "editor" and event.get("kind") == "change"
            for event in session.events
        )
        session.send(
            "setText", node="editor", text="Silent update", notify=False,
        )
        silent = session.send("getText", node="editor")
        if silent.get("text") != "Silent update":
            raise RuntimeError(f"silent setText mismatch: {silent}")
        if sum(
            event.get("event") == "editor" and event.get("kind") == "change"
            for event in session.events
        ) != changes:
            raise RuntimeError("setText notify=false emitted a change event")

        wrapped = session.send("setWordWrap", node="editor", wrap=True)
        if wrapped.get("wrap") is not True:
            raise RuntimeError(f"setWordWrap did not report true: {wrapped}")

        view = session.send(
            "setEditorView", node="editor", lineNumbers=True,
            highlightCurrentLine=True,
        )
        if (view.get("lineNumbers") is not True
                or view.get("highlightCurrentLine") is not True):
            raise RuntimeError(f"setEditorView did not enable both: {view}")
        view = session.send("setEditorView", node="editor", lineNumbers=False)
        if (view.get("lineNumbers") is not False
                or view.get("highlightCurrentLine") is not True):
            raise RuntimeError(f"setEditorView did not disable gutter: {view}")
        view = session.send("setEditorView", node="editor", fontSize=23)
        if view.get("fontSize") != 23:
            raise RuntimeError(f"setEditorView did not apply font size: {view}")
        view = session.send("setEditorView", node="editor", fontSize=0)
        if view.get("fontSize") != 0:
            raise RuntimeError(f"setEditorView did not reset font size: {view}")
        if session.send("setEditorView", node="editor",
                        fontSize=49).get("ok"):
            raise RuntimeError("setEditorView accepted an oversized font")

        styled = session.send(
            "setEditorStyles", node="editor",
            styles=[
                {"start": 0, "end": 6, "color": "#2457a7"},
                {"start": 7, "end": 10, "color": "#2f7d32"},
            ],
        )
        if not styled.get("ok") or styled.get("styles") != 2:
            raise RuntimeError(f"setEditorStyles failed: {styled}")
        if session.send(
            "setEditorStyles", node="editor",
            styles=[
                {"start": 0, "end": 8, "color": "#2457a7"},
                {"start": 7, "end": 10, "color": "#2f7d32"},
            ],
        ).get("ok"):
            raise RuntimeError("setEditorStyles accepted overlapping ranges")
        if session.send(
            "setEditorStyles", node="editor",
            styles=[{"start": 0, "end": 999, "color": "#2457a7"}],
        ).get("ok"):
            raise RuntimeError("setEditorStyles accepted an out-of-range span")
        cleared = session.send("setEditorStyles", node="editor", styles=[])
        if not cleared.get("ok") or cleared.get("styles") != 0:
            raise RuntimeError(f"setEditorStyles did not clear: {cleared}")

        session.send("click", node="apply")
        if not any(
            event.get("event") == "action"
            and event.get("node") == "apply"
            and event.get("action") == "apply"
            for event in session.events
        ):
            raise RuntimeError("button action event was not received")

        session.send("screenshot", path=args.out)
    finally:
        code = session.close()

    if code != 0:
        raise RuntimeError(f"host exited with {code}")
    if not Path(args.out).is_file():
        raise RuntimeError(f"screenshot was not written: {args.out}")
    print("editor control passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"editor control failed: {error}", file=sys.stderr)
        raise SystemExit(1)
