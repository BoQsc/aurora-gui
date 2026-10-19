#!/usr/bin/env python3
"""A notepad project built on top of the generic aurora-host executable.

The host owns the window, widgets, layout, typing, selection, and painting.
This process owns document policy: loading, saving, file dialogs, and status.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parent
HOST = Path(os.environ.get(
    "AURORA_HOST_EXE",
    str(ROOT.parent / "aurora-host" / "aurora-host-experiment.exe"),
))
SCENE = ROOT / "notepad.scene.json"


class HostSession:
    """Asynchronous JSON-lines session with the host UI process."""

    def __init__(self, host: Path, scene: Path):
        self.process = subprocess.Popen(
            [str(host), "--run", str(scene), "--control"],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self._lock = threading.Lock()
        self._write_lock = threading.Lock()
        self._next_id = 0
        self._waiters: dict[int, tuple[threading.Event, dict]] = {}
        self._events: queue.Queue[dict] = queue.Queue()
        self._ready = threading.Event()
        self._closed = threading.Event()
        self._stderr: list[str] = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        try:
            assert self.process.stdout is not None
            for line in self.process.stdout:
                line = line.rstrip("\r\n")
                if line == "READY":
                    self._ready.set()
                elif line.startswith("RESPONSE "):
                    response = json.loads(line[len("RESPONSE "):])
                    with self._lock:
                        waiter = self._waiters.pop(response.get("id"), None)
                    if waiter:
                        waiter[1]["response"] = response
                        waiter[0].set()
                    else:
                        print(f"unmatched response: {response}", file=sys.stderr)
                elif line.startswith("EVENT "):
                    self._events.put(json.loads(line[len("EVENT "):]))
                else:
                    print(f"host: {line}")
        finally:
            self._closed.set()
            with self._lock:
                waiters = list(self._waiters.values())
                self._waiters.clear()
            for waiter, _ in waiters:
                waiter.set()

    def _read_stderr(self) -> None:
        assert self.process.stderr is not None
        for line in self.process.stderr:
            self._stderr.append(line.rstrip("\r\n"))

    def stderr_text(self) -> str:
        return "\n".join(self._stderr)

    def wait_ready(self, timeout: float = 20.0) -> None:
        if not self._ready.wait(timeout):
            raise RuntimeError(
                "host did not become ready\n" + self.stderr_text()
            )

    def call(self, command: str, timeout: float = 20.0, **fields) -> dict:
        with self._lock:
            self._next_id += 1
            request_id = self._next_id
            waiter = threading.Event()
            slot: dict = {}
            self._waiters[request_id] = (waiter, slot)
        payload = {"id": request_id, "command": command}
        payload.update(fields)
        assert self.process.stdin is not None
        with self._write_lock:
            self.process.stdin.write(json.dumps(payload) + "\n")
            self.process.stdin.flush()
        if not waiter.wait(timeout):
            with self._lock:
                self._waiters.pop(request_id, None)
            raise RuntimeError(f"timed out waiting for {command}")
        response = slot.get("response")
        if response is None:
            raise RuntimeError(f"host exited during {command}\n" + self.stderr_text())
        if not response.get("ok"):
            raise RuntimeError(
                f"{command} failed: {response.get('error', 'unknown error')}"
            )
        return response

    def next_event(self, timeout: float | None = None) -> dict | None:
        try:
            return self._events.get(timeout=timeout)
        except queue.Empty:
            return None

    def close(self, timeout: float = 10.0) -> int:
        if self.process.poll() is None:
            try:
                self.call("close")
            except Exception:
                pass
        try:
            return self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.process.kill()
            return self.process.wait(timeout=5)


def read_text(path: Path) -> str:
    with path.open("r", encoding="utf-8", newline="") as stream:
        return stream.read()


def write_text(path: Path, text: str) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(text)


class NotepadApp:
    def __init__(self, session: HostSession, path: Path | None):
        self.session = session
        self.path = path
        self.wrap = False
        self.running = True

    def startup(self) -> None:
        self.session.wait_ready()
        self.session.call("setWordWrap", node="editor", wrap=False)
        if self.path is None:
            self.set_labels("Untitled", "New document")
            return
        if self.path.exists():
            self.session.call("setText", node="editor",
                              text=read_text(self.path))
            self.set_labels(self.path.name, f"Opened {self.path.name}")
        else:
            self.session.call("setText", node="editor", text="")
            self.set_labels(self.path.name, f"New file {self.path.name}")

    def set_labels(self, path_text: str, status_text: str) -> None:
        self.session.call("setText", node="path", text=path_text)
        self.session.call("setText", node="status", text=status_text)

    def editor_text(self) -> str:
        return self.session.call("getText", node="editor")["text"]

    def new_document(self) -> None:
        self.path = None
        self.session.call("setText", node="editor", text="")
        self.set_labels("Untitled", "New document")
        self.session.call("setText", node="wrap", text="Word Wrap")
        self.wrap = False
        self.session.call("setWordWrap", node="editor", wrap=False)

    def open_document(self) -> None:
        response = self.session.call(
            "fileDialog",
            mode="open",
            title="Open Text File",
            initialPath=str(self.path) if self.path else "",
            acceptLabel="Open",
        )
        if not response.get("accepted"):
            self.session.call("setText", node="status", text="Open canceled")
            return
        self.path = Path(response["path"])
        try:
            text = read_text(self.path)
        except OSError as error:
            self.session.call("setText", node="status",
                              text=f"Open failed: {error}")
            return
        self.session.call("setText", node="editor", text=text)
        self.set_labels(self.path.name, f"Opened {self.path.name}")

    def save_document(self) -> None:
        if self.path is None:
            self.save_as()
            return
        if self.path.parent != Path("."):
            self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            write_text(self.path, self.editor_text())
        except OSError as error:
            self.session.call("setText", node="status",
                              text=f"Save failed: {error}")
            return
        self.set_labels(self.path.name, f"Saved {self.path.name}")

    def save_as(self) -> None:
        response = self.session.call(
            "fileDialog",
            mode="save",
            title="Save Text File",
            initialPath=str(self.path) if self.path else "",
            defaultFileName=self.path.name if self.path else "Untitled.txt",
            acceptLabel="Save",
        )
        if not response.get("accepted"):
            self.session.call("setText", node="status", text="Save canceled")
            return
        self.path = Path(response["path"])
        self.save_document()

    def toggle_wrap(self) -> None:
        self.wrap = not self.wrap
        self.session.call("setWordWrap", node="editor", wrap=self.wrap)
        self.session.call("setText", node="wrap",
                          text=f"Wrap: {'On' if self.wrap else 'Off'}")
        self.set_labels(
            self.path.name if self.path else "Untitled",
            f"Word wrap {'on' if self.wrap else 'off'}",
        )

    def handle_action(self, event: dict) -> None:
        action = event.get("action")
        try:
            if action == "new":
                self.new_document()
            elif action == "open":
                self.open_document()
            elif action == "save":
                self.save_document()
            elif action == "saveAs":
                self.save_as()
            elif action == "wrap":
                self.toggle_wrap()
            elif action == "close":
                self.running = False
                self.session.call("close")
        except Exception as error:
            self.session.call("setText", node="status",
                              text=f"Error: {error}")

    def run_events(self, timeout: float | None = None) -> None:
        deadline = None if timeout is None else time.monotonic() + timeout
        while self.running:
            if self.session.process.poll() is not None:
                return
            if deadline is not None and time.monotonic() >= deadline:
                return
            event = self.session.next_event(0.2)
            if event and event.get("event") == "action":
                self.handle_action(event)

    def screenshot(self, path: Path) -> None:
        self.session.call("screenshot", path=str(path))

    def stop(self) -> int:
        return self.session.close()


def demo(app: NotepadApp, source: Path, output: Path, png: Path) -> int:
    initial = "Host Notepad\n"
    write_text(source, initial)
    app.startup()
    if app.editor_text() != initial:
        raise RuntimeError("initial file was not loaded into the editor")

    edited = (
        "Host Notepad\n"
        "============\n\n"
        "Aurora renders the window; the host owns typing and painting.\n"
        "This document was edited over the control channel and saved by\n"
        "clicking the real Save button.\n\n"
        "Unicode: café, 日本語, 🚀\n"
    )
    app.session.call("setText", node="editor", text=edited)
    if app.editor_text() != edited:
        raise RuntimeError("getText did not return the edited document")

    app.session.call("click", node="save")
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        event = app.session.next_event(0.5)
        if event and event.get("event") == "action":
            app.handle_action(event)
            if source.exists() and read_text(source) == edited:
                break
    if read_text(source) != edited:
        raise RuntimeError("Save button did not write the edited document")

    app.session.call("click", node="wrap")
    app.run_events(0.5)
    if not app.wrap:
        raise RuntimeError("Word Wrap button did not update the editor")

    app.screenshot(output)
    if not output.is_file():
        raise RuntimeError("screenshot was not written")
    try:
        from PIL import Image
    except ImportError:
        print("Pillow unavailable; leaving the PPM screenshot")
    else:
        png.parent.mkdir(parents=True, exist_ok=True)
        Image.open(output).save(png)
        print(f"png: {png}")

    code = app.stop()
    if code != 0:
        raise RuntimeError(f"host exited with {code}\n{app.session.stderr_text()}")
    print("notepad demo passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", type=Path, default=HOST)
    parser.add_argument("--file", type=Path)
    parser.add_argument("--demo", action="store_true")
    parser.add_argument("--out", type=Path,
                        default=ROOT / "build" / "notepad.ppm")
    parser.add_argument("--png", type=Path,
                        default=ROOT / "build" / "notepad.png")
    args = parser.parse_args()

    if not args.host.is_file():
        raise RuntimeError(
            f"aurora host executable is missing: {args.host}\n"
            "build the host first or set AURORA_HOST_EXE"
        )
    if args.demo and args.file is None:
        args.file = ROOT / "build" / "notepad-demo.txt"
    if args.file is not None:
        args.file = args.file.resolve()
        args.file.parent.mkdir(parents=True, exist_ok=True)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.png.parent.mkdir(parents=True, exist_ok=True)

    session = HostSession(args.host, SCENE)
    app = NotepadApp(session, args.file)
    try:
        if args.demo:
            return demo(app, args.file, args.out, args.png)
        app.startup()
        print(f"notepad ready: {args.file or 'Untitled'}")
        app.run_events()
        code = app.stop()
        print(f"host exit: {code}")
        return code
    finally:
        if session.process.poll() is None:
            session.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"notepad failed: {error}", file=sys.stderr)
        raise SystemExit(1)
