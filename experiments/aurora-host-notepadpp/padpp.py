#!/usr/bin/env python3
"""Aurora Pad++, a Notepad++-style workbench built on the generic aurora-host.

The host owns generic UI mechanics: window, widgets, layout, text editing,
selection, focus, painting, and editor events.  This process owns application
policy: document models, tabs, dirty state, file I/O, language metadata,
find/replace behavior, status, and the performance benchmark.
"""
from __future__ import annotations

import argparse
from copy import deepcopy
from dataclasses import dataclass, field
import faulthandler
import json
import os
from pathlib import Path
import queue
import re
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib

ROOT = Path(__file__).resolve().parent
HOST = Path(os.environ.get(
    "AURORA_HOST_EXE",
    str(ROOT.parent / "aurora-host" / "aurora-host-experiment.exe"),
))
SCENE = ROOT / "padpp.scene.json"
TAB_COUNT = 8
COUNT_THRESHOLD = 512 * 1024
BENCH_LINES = int(os.environ.get("AURORA_PADPP_BENCH_LINES", "2000"))
LANGUAGES = ["Plain Text", "Python", "C++", "D", "JSON", "Markdown"]
ZOOM_STEPS = [80, 90, 100, 110, 125, 150, 175, 200]
BASE_FONT_SIZE = 17
SYNTAX_THRESHOLD = 200_000
TOKEN_COLORS = {
    "comment": "#2f7d32",
    "string": "#a15c00",
    "keyword": "#2457a7",
    "number": "#8a3fa0",
}
TOKEN_PATTERNS = {
    "Python": re.compile(
        r"""(?P<comment>#[^\n]*)"""
        r'''|(?P<string>"""[\s\S]*?"""|''' + "'''" + r"""[\s\S]*?'''|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')"""
        r"""|(?P<keyword>\b(?:and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield)\b)"""
        r"""|(?P<number>\b\d+(?:\.\d+)?\b)"""
    ),
    "C++": re.compile(
        r"""(?P<comment>//[^\n]*|/\*[\s\S]*?\*/)"""
        r"""|(?P<string>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')"""
        r"""|(?P<keyword>\b(?:alignas|auto|bool|break|case|catch|char|class|const|constexpr|continue|default|delete|do|double|else|enum|explicit|extern|false|float|for|friend|if|inline|int|long|namespace|new|nullptr|operator|private|protected|public|return|short|signed|sizeof|static|struct|switch|template|this|throw|true|try|typedef|typename|union|unsigned|using|virtual|void|volatile|while)\b)"""
        r"""|(?P<number>\b\d+(?:\.\d+)?\b)"""
    ),
    "D": re.compile(
        r"""(?P<comment>//[^\n]*|/\*[\s\S]*?\*/|/[+][\s\S]*?[+]/)"""
        r"""|(?P<string>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')"""
        r"""|(?P<keyword>\b(?:alias|auto|bool|break|case|cast|class|const|continue|default|delegate|do|double|else|enum|false|final|float|for|foreach|foreach_reverse|if|immutable|import|in|int|interface|long|mixin|module|new|null|out|override|private|protected|public|return|scope|shared|short|static|struct|switch|template|this|throw|true|try|typeof|ubyte|uint|ulong|union|unittest|ushort|void|while|with)\b)"""
        r"""|(?P<number>\b\d+(?:\.\d+)?\b)"""
    ),
    "JSON": re.compile(
        r"""(?P<string>"(?:\\.|[^"\\\n])*")"""
        r"""|(?P<keyword>\b(?:true|false|null)\b)"""
        r"""|(?P<number>-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)"""
    ),
    "Markdown": re.compile(
        r"""(?P<comment>^>.*$)"""
        r"""|(?P<string>`[^`\n]+`|```[\s\S]*?```)"""
        r"""|(?P<keyword>^#{1,6}[ \t].*$|\*\*[^*\n]+\*\*)"""
        r"""|(?P<number>^\s*[-*+]\s|^\s*\d+\.\s)""",
        re.MULTILINE,
    ),
}
SUFFIXES = {
    ".py": "Python",
    ".pyw": "Python",
    ".c": "C++",
    ".cc": "C++",
    ".cpp": "C++",
    ".cxx": "C++",
    ".h": "C++",
    ".hpp": "C++",
    ".d": "D",
    ".json": "JSON",
    ".md": "Markdown",
    ".markdown": "Markdown",
    ".txt": "Plain Text",
}


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


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

    def call(self, command: str, timeout: float = 60.0, **fields) -> dict:
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
            raise RuntimeError(
                f"host exited during {command}\n" + self.stderr_text()
            )
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

    def close(self, timeout: float = 15.0) -> int:
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
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as stream:
        stream.write(text)


@dataclass
class Document:
    name: str = "Untitled"
    path: Path | None = None
    text: str = ""
    dirty: bool = False
    cursor: int = 0
    anchor: int = 0
    line: int = 0
    column: int = 0
    language: str = "Plain Text"
    chars: int = 0
    words: int | None = 0
    lines: int = 1
    status: str = "Ready"
    revision: int = 0


class Workbench:
    def __init__(self, session: HostSession):
        self.session = session
        self.docs: list[Document] = []
        self.active = 0
        self.wrap = False
        self.match_case = False
        self.whole_word = False
        self.line_numbers = True
        self.highlight_current_line = True
        self.zoom_percent = 100
        self.find_needle = ""
        self.menu_base: dict[str, list] = {}
        self._menu_cache_key: tuple | None = None
        self._find_cache_key: tuple | None = None
        self._find_count = 0
        self.running = True
        self.action_seq = 0
        self.last_error: str | None = None
        self._load_menu_base()

    # ---------- startup and document model ----------

    def startup(self, path: Path | None = None) -> None:
        self.session.wait_ready()
        welcome = self.session.call("getText", node="editor")["text"]
        self.docs = [Document(name="Untitled", text=welcome)]
        self._measure(self.docs[0], force=True)
        if path is not None:
            try:
                self.docs[0] = self._document_for_path(path)
            except OSError as error:
                self.docs[0].status = f"Open failed: {error}"
        self.active = 0
        self.session.call("setWordWrap", node="editor", wrap=False)
        self._apply_editor_view()
        self._load_active()
        self._refresh_all(self.docs[0].status)

    def _apply_editor_view(self) -> None:
        font_size = (0 if self.zoom_percent == 100 else
                     round(BASE_FONT_SIZE * self.zoom_percent / 100))
        self.session.call(
            "setEditorView", node="editor",
            lineNumbers=self.line_numbers,
            highlightCurrentLine=self.highlight_current_line,
            fontSize=font_size,
        )

    @staticmethod
    def _syntax_styles(doc: Document) -> list[dict]:
        pattern = TOKEN_PATTERNS.get(doc.language)
        if pattern is None or len(doc.text) > SYNTAX_THRESHOLD:
            return []
        styles = []
        for match in pattern.finditer(doc.text):
            color = TOKEN_COLORS.get(match.lastgroup or "")
            if color is not None:
                styles.append({
                    "start": match.start(),
                    "end": match.end(),
                    "color": color,
                })
        return styles

    def _apply_syntax(self, doc: Document | None = None) -> None:
        doc = self.docs[self.active] if doc is None else doc
        self.session.call("setEditorStyles", node="editor",
                          styles=self._syntax_styles(doc))

    def _load_menu_base(self) -> None:
        try:
            scene = json.loads(SCENE.read_text(encoding="utf-8"))
        except OSError:
            return

        def visit(nodes: list[dict]) -> None:
            for node in nodes:
                if node.get("type") == "menu":
                    self.menu_base[node["id"]] = deepcopy(node.get("items", []))
                visit(node.get("children", []))

        root = scene.get("root")
        if root is not None:
            visit([root])

    @staticmethod
    def _set_checked(items: list[dict], states: dict[str, bool]) -> None:
        for item in items:
            if item.get("label") in states:
                item["checked"] = states[item["label"]]
            Workbench._set_checked(item.get("children", []), states)

    def _refresh_menus(self) -> None:
        doc = self.docs[self.active]
        states = {
            "edit-menu": {
                "Word wrap": self.wrap,
                "Match case": self.match_case,
                "Whole word": self.whole_word,
            },
            "view-menu": {
                "Word wrap": self.wrap,
                "Match case": self.match_case,
                "Toggle line numbers": self.line_numbers,
                "Toggle current line": self.highlight_current_line,
            },
            "language-menu": {
                language: language == doc.language for language in LANGUAGES
            },
        }
        key = (
            doc.language, self.wrap, self.match_case, self.whole_word,
            self.line_numbers, self.highlight_current_line,
        )
        if key == self._menu_cache_key:
            return
        for node, flags in states.items():
            base = self.menu_base.get(node)
            if base is None:
                continue
            items = deepcopy(base)
            self._set_checked(items, flags)
            self.session.call("setMenu", node=node, items=items)
        self._menu_cache_key = key

    @staticmethod
    def _language_for(path: Path) -> str:
        return SUFFIXES.get(path.suffix.lower(), "Plain Text")

    @classmethod
    def _document_for_path(cls, path: Path) -> Document:
        text = read_text(path)
        doc = Document(name=path.name, path=path, text=text,
                       language=cls._language_for(path))
        cls._measure_static(doc)
        return doc

    @staticmethod
    def _measure_static(doc: Document, force: bool = False) -> None:
        doc.chars = len(doc.text)
        doc.lines = doc.text.count("\n") + 1
        if force or len(doc.text) <= COUNT_THRESHOLD:
            doc.words = len(re.findall(r"\S+", doc.text))
        else:
            doc.words = None

    def _measure(self, doc: Document, force: bool = False) -> None:
        self._measure_static(doc, force)
        doc.revision += 1

    def _load_active(self) -> None:
        doc = self.docs[self.active]
        started = time.perf_counter()
        self.session.call("setText", node="editor", text=doc.text,
                          notify=False)
        after_text = time.perf_counter()
        self.session.call("setSelection", node="editor",
                          start=doc.cursor, end=doc.anchor)
        self._apply_syntax(doc)
        self.last_load_timings = {
            "setText": after_text - started,
            "setSelection": time.perf_counter() - after_text,
        }

    def _capture_active(self) -> Document:
        doc = self.docs[self.active]
        doc.text = self.session.call("getText", node="editor")["text"]
        state = self.session.call("getEditorState", node="editor")
        doc.cursor = int(state["cursor"])
        doc.anchor = int(state["anchor"])
        doc.line = int(state["line"])
        doc.column = int(state["column"])
        self._measure(doc)
        return doc

    def editor_text(self) -> str:
        return self.session.call("getText", node="editor")["text"]

    def _activate(self, index: int, message: str | None = None) -> None:
        if index < 0 or index >= TAB_COUNT:
            return
        self._capture_active()
        if index >= len(self.docs):
            while len(self.docs) <= index:
                self.docs.append(Document())
        self.active = index
        self._load_active()
        self._refresh_all(message or self.docs[index].status)

    def activate_tab(self, index: int) -> None:
        if index == self.active:
            doc = self.docs[index]
            self.session.call("setSelection", node="editor",
                              start=doc.cursor, end=doc.anchor)
            self._refresh_all(doc.status)
            return
        self._activate(index, f"Tab {index + 1}: {self.docs[index].name}")

    def new_document(self) -> None:
        self._capture_active()
        if len(self.docs) >= TAB_COUNT:
            self._set_message("All 8 tab slots are in use")
            return
        self.docs.append(Document(status="New document"))
        self.active = len(self.docs) - 1
        self._load_active()
        self._refresh_all("New document")

    def close_active(self) -> None:
        doc = self.docs[self.active]
        if doc.dirty:
            self._set_message("Close blocked: save unsaved changes first")
            return
        self.docs.pop(self.active)
        if not self.docs:
            self.docs.append(Document())
        self.active = min(self.active, len(self.docs) - 1)
        self._load_active()
        self._refresh_all("Tab closed")

    def open_path(self, path: Path) -> None:
        self._capture_active()
        try:
            doc = self._document_for_path(path)
        except OSError as error:
            self._set_message(f"Open failed: {error}")
            return
        target = len(self.docs)
        active = self.docs[self.active]
        if active.path is None and not active.dirty and not active.text:
            target = self.active
        elif target >= TAB_COUNT:
            self._set_message("All 8 tab slots are in use")
            return
        if target == self.active:
            self.docs[target] = doc
        elif target < len(self.docs):
            self.docs[target] = doc
        else:
            self.docs.append(doc)
        self.active = target
        self._load_active()
        self._refresh_all(f"Opened {doc.name}")

    def open_document(self) -> None:
        doc = self.docs[self.active]
        response = self.session.call(
            "fileDialog",
            mode="open",
            title="Open Document",
            initialPath=str(doc.path) if doc.path else "",
            acceptLabel="Open",
        )
        if not response.get("accepted"):
            self._set_message("Open canceled")
            return
        self.open_path(Path(response["path"]))

    # ---------- file operations ----------

    def save_active(self, path: Path | None = None) -> bool:
        doc = self._capture_active()
        if path is not None:
            doc.path = path
            doc.name = path.name
            doc.language = self._language_for(path)
            self._apply_syntax(doc)
        if doc.path is None:
            return self.save_as()
        try:
            write_text(doc.path, doc.text)
        except OSError as error:
            doc.status = f"Save failed: {error}"
            self._refresh_all(doc.status)
            return False
        doc.dirty = False
        doc.status = f"Saved {doc.name}"
        self._refresh_all(doc.status)
        return True

    def save_as(self) -> bool:
        doc = self.docs[self.active]
        response = self.session.call(
            "fileDialog",
            mode="save",
            title="Save Document",
            initialPath=str(doc.path) if doc.path else "",
            defaultFileName=doc.path.name if doc.path else "Untitled.txt",
            acceptLabel="Save",
        )
        if not response.get("accepted"):
            self._set_message("Save canceled")
            return False
        return self.save_active(Path(response["path"]))

    # ---------- application controls ----------

    def cycle_language(self) -> None:
        doc = self._capture_active()
        index = LANGUAGES.index(doc.language) if doc.language in LANGUAGES else 0
        self.set_language(LANGUAGES[(index + 1) % len(LANGUAGES)])

    def set_language(self, language: str) -> None:
        if language not in LANGUAGES:
            self._set_message(f"Unknown language: {language}")
            return
        doc = self._capture_active()
        doc.language = language
        doc.status = f"Language mode: {language}"
        self._apply_syntax(doc)
        self._refresh_all(doc.status)

    def select_all(self) -> None:
        doc = self._capture_active()
        self.session.call("setSelection", node="editor",
                          start=0, end=len(doc.text))
        state = self.session.call("getEditorState", node="editor")
        doc.cursor = int(state["cursor"])
        doc.anchor = int(state["anchor"])
        doc.line = int(state["line"])
        doc.column = int(state["column"])
        doc.status = "Selected all"
        self._refresh_all(doc.status)

    def focus_find(self) -> None:
        self.session.call("click", node="find")
        self._set_message("Find bar ready")

    def toggle_wrap(self) -> None:
        self.wrap = not self.wrap
        self.session.call("setWordWrap", node="editor", wrap=self.wrap)
        self._refresh_all(
            f"Word wrap {'on' if self.wrap else 'off'}"
        )

    def toggle_case(self) -> None:
        self.match_case = not self.match_case
        self._refresh_all(
            f"Match case {'on' if self.match_case else 'off'}"
        )

    def toggle_whole_word(self) -> None:
        self.whole_word = not self.whole_word
        self._refresh_all(
            f"Whole word {'on' if self.whole_word else 'off'}"
        )

    def toggle_line_numbers(self) -> None:
        self.line_numbers = not self.line_numbers
        self._apply_editor_view()
        self._refresh_all(
            f"Line numbers {'on' if self.line_numbers else 'off'}"
        )

    def toggle_current_line(self) -> None:
        self.highlight_current_line = not self.highlight_current_line
        self._apply_editor_view()
        self._refresh_all(
            f"Current line highlight "
            f"{'on' if self.highlight_current_line else 'off'}"
        )

    def zoom_in(self) -> None:
        next_steps = [step for step in ZOOM_STEPS if step > self.zoom_percent]
        if not next_steps:
            self._set_message("Zoom: 200% (maximum)")
            return
        self.zoom_percent = next_steps[0]
        self._apply_editor_view()
        self._refresh_all(f"Zoom: {self.zoom_percent}%")

    def zoom_out(self) -> None:
        previous = [step for step in ZOOM_STEPS if step < self.zoom_percent]
        if not previous:
            self._set_message("Zoom: 80% (minimum)")
            return
        self.zoom_percent = previous[-1]
        self._apply_editor_view()
        self._refresh_all(f"Zoom: {self.zoom_percent}%")

    def zoom_reset(self) -> None:
        self.zoom_percent = 100
        self._apply_editor_view()
        self._refresh_all("Zoom: 100%")

    def _pattern(self, needle: str) -> re.Pattern[str]:
        flags = 0 if self.match_case else re.IGNORECASE
        body = re.escape(needle)
        if self.whole_word:
            body = rf"(?<!\w){body}(?!\w)"
        return re.compile(body, flags)

    def _needle(self) -> str:
        return self.session.call("getText", node="find")["text"]

    def _replacement(self) -> str:
        return self.session.call("getText", node="replace")["text"]

    def _refresh_find_hint(self) -> None:
        doc = self.docs[self.active]
        needle = self.find_needle
        if not needle:
            key = None
            label = "Right-click the editor for commands"
        else:
            key = (needle, self.match_case, self.whole_word,
                   id(doc), doc.revision, len(doc.text))
            count = len(self._pattern(needle).findall(doc.text))
            self._find_count = count
            label = ("No matches" if count == 0 else
                     f"{count} match{'' if count == 1 else 'es'}")
        if key == self._find_cache_key:
            return
        self._find_cache_key = key
        self.session.call("setText", node="find-hint", text=label)

    def _select_match(self, start: int, end: int, text: str,
                      message: str | None = None) -> None:
        line = text.count("\n", 0, start) + 1
        line_start = text.rfind("\n", 0, start) + 1
        column = start - line_start + 1
        doc = self.docs[self.active]
        doc.cursor = end
        doc.anchor = start
        doc.line = line - 1
        doc.column = column - 1
        doc.status = message or f"Match at line {line}, column {column}"
        self.session.call("setSelection", node="editor",
                          start=start, end=end)
        self._refresh_all(doc.status)

    def find_next(self) -> None:
        needle = self._needle()
        if not needle:
            self._set_message("Find text is empty")
            return
        doc = self._capture_active()
        state = self.session.call("getEditorState", node="editor")
        text = doc.text
        start = int(state["cursor"])
        self.find_needle = needle
        pattern = self._pattern(needle)
        match = pattern.search(text, start)
        if match is None and start > 0:
            match = pattern.search(text, 0, start)
        if match is None:
            self._refresh_find_hint()
            self._set_message(f"Not found: {needle}")
            return
        self._select_match(match.start(), match.end(), text,
                           f"Found at line "
                           f"{text.count(chr(10), 0, match.start()) + 1}")

    def find_previous(self) -> None:
        needle = self._needle()
        if not needle:
            self._set_message("Find text is empty")
            return
        doc = self._capture_active()
        state = self.session.call("getEditorState", node="editor")
        start = min(int(state["anchor"]), int(state["cursor"]))
        text = doc.text
        self.find_needle = needle
        pattern = self._pattern(needle)
        matches = list(pattern.finditer(text, 0, start))
        if not matches and start < len(text):
            matches = list(pattern.finditer(text, start))
        if not matches:
            self._refresh_find_hint()
            self._set_message(f"Not found before cursor: {needle}")
            return
        match = matches[-1]
        self._select_match(match.start(), match.end(), text,
                           f"Found at line "
                           f"{text.count(chr(10), 0, match.start()) + 1}")

    def _replace_text(self, text: str, dirty: bool, message: str,
                      cursor: int | None = None,
                      anchor: int | None = None) -> None:
        doc = self.docs[self.active]
        self.session.call("setText", node="editor", text=text, notify=False)
        doc.text = text
        doc.dirty = dirty
        doc.cursor = len(text) if cursor is None else cursor
        doc.anchor = doc.cursor if anchor is None else anchor
        doc.status = message
        self._measure(doc, force=True)
        self.session.call("setSelection", node="editor",
                          start=doc.anchor, end=doc.cursor)
        self._apply_syntax(doc)
        self._refresh_all(message)

    def replace_current(self) -> None:
        needle = self._needle()
        if not needle:
            self._set_message("Find text is empty")
            return
        replacement = self._replacement()
        doc = self._capture_active()
        text = doc.text
        state = self.session.call("getEditorState", node="editor")
        anchor = int(state["anchor"])
        cursor = int(state["cursor"])
        start, end = min(anchor, cursor), max(anchor, cursor)
        pattern = self._pattern(needle)
        if start != end and pattern.fullmatch(text[start:end]):
            updated = text[:start] + replacement + text[end:]
            self._replace_text(
                updated, True, "Replaced 1 occurrence",
                cursor=start + len(replacement), anchor=start + len(replacement)
            )
            return
        self.find_next()
        if self.docs[self.active].anchor != self.docs[self.active].cursor:
            self._set_message("Match selected; press Replace again")

    def replace_all(self) -> None:
        needle = self._needle()
        if not needle:
            self._set_message("Find text is empty")
            return
        replacement = self._replacement()
        doc = self._capture_active()
        pattern = self._pattern(needle)
        updated, count = pattern.subn(lambda _: replacement, doc.text)
        if count == 0:
            self._set_message(f"Not found: {needle}")
            return
        self._replace_text(updated, True,
                           f"Replaced {count} occurrence"
                           f"{'' if count == 1 else 's'}")

    # ---------- event handling and status ----------

    def handle_event(self, event: dict) -> None:
        name = event.get("event")
        try:
            if name == "action":
                self.action_seq += 1
                self.handle_action(event.get("action", ""))
            elif name == "editor":
                node = event.get("node")
                if node == "editor":
                    self.handle_editor_event(event)
                elif node == "find" and event.get("kind") == "change":
                    self.find_needle = self._needle()
                    self._refresh_find_hint()
        except Exception as error:
            self.last_error = str(error)
            self._set_message(f"Error: {error}")

    def handle_action(self, action: str) -> None:
        if action.startswith("tab:"):
            self.activate_tab(int(action[4:]))
        elif action.startswith("tab") and action[3:].isdigit():
            self.activate_tab(int(action[3:]))
        elif action.startswith("lang:"):
            self.set_language(action[len("lang:"):])
        elif action in ("new", "file.new"):
            self.new_document()
        elif action in ("open", "file.open"):
            self.open_document()
        elif action in ("save", "file.save"):
            self.save_active()
        elif action in ("saveAs", "file.saveAs"):
            self.save_as()
        elif action in ("closeTab", "file.close"):
            self.close_active()
        elif action in ("cycleMode", "language.next"):
            self.cycle_language()
        elif action in ("toggleWrap", "view.wrap"):
            self.toggle_wrap()
        elif action in ("toggleCase", "search.case"):
            self.toggle_case()
        elif action in ("toggleWholeWord", "search.wholeWord"):
            self.toggle_whole_word()
        elif action in ("toggleLineNumbers", "view.lineNumbers"):
            self.toggle_line_numbers()
        elif action in ("toggleCurrentLine", "view.currentLine"):
            self.toggle_current_line()
        elif action in ("findNext", "search.findNext"):
            self.find_next()
        elif action in ("findPrevious", "search.findPrevious"):
            self.find_previous()
        elif action in ("replace", "search.replace"):
            self.replace_current()
        elif action in ("replaceAll", "search.replaceAll"):
            self.replace_all()
        elif action in ("selectAll", "edit.selectAll"):
            self.select_all()
        elif action == "search.find":
            self.focus_find()
        elif action in ("benchmark", "tools.benchmark"):
            self.run_benchmark(active_ui=True)
        elif action == "help.about":
            self._set_message(
                "Aurora Pad++: app-owned tabs, files, languages and search"
            )
        elif action == "help.capabilities":
            self._set_message(
                "Host: UI chrome, menus, tabs, files, text; "
                "app: editor policy"
            )
        elif action in ("view.zoomIn", "zoomIn"):
            self.zoom_in()
        elif action in ("view.zoomOut", "zoomOut"):
            self.zoom_out()
        elif action in ("view.zoomReset", "zoomReset"):
            self.zoom_reset()
        elif action in ("exit", "app.exit"):
            self.running = False
        else:
            self._set_message(f"Unknown action: {action}")

    def handle_editor_event(self, event: dict) -> None:
        doc = self.docs[self.active]
        doc.cursor = int(event.get("cursor", doc.cursor))
        doc.anchor = int(event.get("anchor", doc.anchor))
        doc.line = int(event.get("line", doc.line))
        doc.column = int(event.get("column", doc.column))
        doc.chars = int(event.get("length", doc.chars))
        if event.get("kind") == "change":
            doc.dirty = True
            if doc.chars <= COUNT_THRESHOLD:
                doc.text = self.session.call("getText", node="editor")["text"]
                self._measure(doc, force=True)
                doc.lines = doc.text.count("\n") + 1
            else:
                doc.words = None
            self._apply_syntax(doc)
            doc.status = "Modified"
            self._refresh_all(doc.status)
        else:
            self._status()

    def pump(self, timeout: float = 0.0) -> None:
        deadline = time.monotonic() + timeout
        while True:
            wait = max(0.0, deadline - time.monotonic())
            event = self.session.next_event(wait)
            if event is None:
                return
            self.handle_event(event)

    def pump_until(self, predicate, timeout: float = 10.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            event = self.session.next_event(0.2)
            if event is not None:
                self.handle_event(event)
            if self.session.process.poll() is not None:
                return predicate()
        return predicate()

    def click_action(self, node: str, action: str,
                     timeout: float = 15.0) -> None:
        before = self.action_seq
        self.session.call("click", node=node)
        if not self.pump_until(lambda: self.action_seq > before, timeout):
            raise RuntimeError(f"action did not arrive: {action}")

    def _set_message(self, message: str) -> None:
        self.docs[self.active].status = message
        self._status()

    def _status(self) -> None:
        doc = self.docs[self.active]
        words = "—" if doc.words is None else f"{doc.words}"
        selected = abs(doc.cursor - doc.anchor)
        self.session.call(
            "setText", node="status-position",
            text=f"Ln {doc.line + 1}, Col {doc.column + 1}"
        )
        self.session.call("setText", node="status-selection",
                          text=f"Sel {selected}")
        self.session.call(
            "setText", node="status-document",
            text=f"{doc.lines} lines  |  {words} words  |  {doc.chars} chars"
        )
        self.session.call("setText", node="status-language",
                          text=doc.language)
        self.session.call("setText", node="status-zoom",
                          text=f"{self.zoom_percent}%")
        self.session.call("setText", node="status-message",
                          text=doc.status)

    @staticmethod
    def _short_name(name: str, limit: int = 22) -> str:
        return name if len(name) <= limit else name[:limit - 3] + "..."

    def _refresh_tabs(self) -> None:
        items = [
            {
                "label": self._short_name(doc.name),
                "action": f"tab:{index}",
                "active": index == self.active,
                "dirty": doc.dirty,
            }
            for index, doc in enumerate(self.docs)
        ]
        self.session.call("setTabs", node="docs", items=items)

    def _refresh_all(self, message: str | None = None) -> None:
        if message is not None:
            self.docs[self.active].status = message
        doc = self.docs[self.active]
        self.session.call("setChrome", node="tb-wrap", active=self.wrap)
        self.session.call("setChrome", node="tb-case",
                          active=self.match_case)
        self.session.call("setChrome", node="tb-lines",
                          active=self.line_numbers)
        self.session.call("setChrome", node="find-case",
                          active=self.match_case)
        self.session.call("setChrome", node="find-word",
                          active=self.whole_word)
        self._refresh_tabs()
        self._status()
        self._refresh_find_hint()
        self._refresh_menus()

    # ---------- benchmark and lifecycle ----------

    def benchmark_text(self, text: str, name: str = "large.txt",
                       path: Path | None = None) -> dict:
        log(f"benchmark: capture current editor ({len(text)} chars target)")
        self._capture_active()
        if len(self.docs) >= TAB_COUNT:
            raise RuntimeError("benchmark needs a free tab")
        doc = Document(name=name, path=path, text=text, language="Plain Text")
        self._measure(doc, force=True)
        self.docs.append(doc)
        index = len(self.docs) - 1
        log("benchmark: setText")
        start = time.perf_counter()
        self.active = index
        self._load_active()
        load_seconds = time.perf_counter() - start
        log(f"benchmark: loaded in {load_seconds:.2f}s "
            f"{self.last_load_timings}; getText")

        start = time.perf_counter()
        roundtrip = self.session.call("getText", node="editor")["text"]
        roundtrip_seconds = time.perf_counter() - start
        log(f"benchmark: round trip in {roundtrip_seconds:.2f}s; switch")
        if roundtrip != text:
            raise RuntimeError("large document round trip changed the text")

        start = time.perf_counter()
        self._activate(0, "benchmark: switched away")
        self._activate(index, "benchmark: switched back")
        switch_seconds = time.perf_counter() - start
        log(f"benchmark: switch in {switch_seconds:.2f}s; find")

        needle = re.findall(r"needle-\d{6}", text)[-1]
        self.session.call("setText", node="find", text=needle)
        start = time.perf_counter()
        self.find_next()
        find_seconds = time.perf_counter() - start
        log(f"benchmark: find in {find_seconds:.3f}s")
        state = self.session.call("getEditorState", node="editor")
        selected = int(state["cursor"]) - int(state["anchor"])
        if selected != len(needle):
            raise RuntimeError(
                f"find did not select the large-file needle: "
                f"state={state}, status={doc.status!r}, "
                f"needle_at={doc.text.find(needle)}"
            )

        self._refresh_all(
            f"Benchmark: load {load_seconds:.2f}s, "
            f"round trip {roundtrip_seconds:.2f}s, "
            f"switch {switch_seconds:.2f}s, find {find_seconds:.3f}s"
        )
        return {
            "name": name,
            "bytes": len(text.encode("utf-8")),
            "lines": doc.lines,
            "load_seconds": load_seconds,
            "roundtrip_seconds": roundtrip_seconds,
            "switch_seconds": switch_seconds,
            "find_seconds": find_seconds,
            "load_mib_per_second": (
                len(text.encode("utf-8")) / (1024 * 1024) / load_seconds
            ),
            "roundtrip_mib_per_second": (
                len(text.encode("utf-8")) / (1024 * 1024) / roundtrip_seconds
            ),
        }

    def run_benchmark(self, active_ui: bool = False,
                      lines: int | None = None) -> dict:
        lines = BENCH_LINES if lines is None else lines
        text = "".join(
            f"{index:06d}  the quick brown fox jumps over the lazy dog "
            f"needle-{index:06d}  pack my box with five dozen liquor jugs\n"
            for index in range(lines)
        )
        result = self.benchmark_text(
            text, f"large-{lines}.txt",
            path=None,
        )
        if active_ui:
            self._refresh_all(
                f"Bench: {result['lines']} lines, "
                f"load {result['load_seconds']:.2f}s, "
                f"round trip {result['roundtrip_seconds']:.2f}s"
            )
        return result

    def screenshot(self, path: Path) -> None:
        self.session.call("screenshot", path=str(path))

    def stop(self) -> int:
        return self.session.close()


def host_working_set_mb(pid: int) -> float | None:
    if sys.platform != "win32":
        return None
    try:
        import ctypes
        from ctypes import wintypes

        class PROCESS_MEMORY_COUNTERS_EX(ctypes.Structure):
            _fields_ = [
                ("cb", wintypes.DWORD),
                ("PageFaultCount", wintypes.DWORD),
                ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t),
                ("PrivateUsage", ctypes.c_size_t),
            ]

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        psapi = ctypes.WinDLL("psapi", use_last_error=True)
        process = kernel32.OpenProcess(0x1000 | 0x0400, False, pid)
        if not process:
            return None
        try:
            counters = PROCESS_MEMORY_COUNTERS_EX()
            counters.cb = ctypes.sizeof(counters)
            if not psapi.GetProcessMemoryInfo(
                    process, ctypes.byref(counters),
                    ctypes.sizeof(counters)):
                return None
            return counters.WorkingSetSize / (1024 * 1024)
        finally:
            kernel32.CloseHandle(process)
    except Exception:
        return None


def read_ppm(ppm: Path) -> tuple[int, int, bytes]:
    data = ppm.read_bytes()
    if not data.startswith(b"P6"):
        raise RuntimeError("screenshot is not a binary PPM")
    parts = data.split(b"\n", 3)
    if len(parts) != 4:
        raise RuntimeError("malformed PPM header")
    width, height = map(int, parts[1].split())
    maximum = int(parts[2])
    if maximum != 255 or len(parts[3]) != width * height * 3:
        raise RuntimeError("unsupported PPM payload")
    return width, height, parts[3]


def verify_ppm_pixels(ppm: Path) -> dict:
    width, height, raw = read_ppm(ppm)
    samples = dark = bright = 0
    colors: set[tuple[int, int, int]] = set()
    luminance = 0
    for pixel in range(0, width * height, 17):
        red, green, blue = raw[pixel * 3:pixel * 3 + 3]
        samples += 1
        luminance += red * 299 + green * 587 + blue * 114
        if red + green + blue < 180:
            dark += 1
        if max(red, green, blue) > 150:
            bright += 1
        colors.add((red // 16, green // 16, blue // 16))
    result = {
        "width": width,
        "height": height,
        "samples": samples,
        "dark_fraction": dark / samples,
        "bright_fraction": bright / samples,
        "mean_luminance": luminance / samples / 1000,
        "quantized_colors": len(colors),
    }
    if (width < 1000 or height < 600
            or result["dark_fraction"] < 0.0005
            or result["bright_fraction"] < 0.35
            or result["mean_luminance"] < 140
            or result["quantized_colors"] < 20):
        raise RuntimeError(f"screenshot pixel gate failed: {result}")
    return result


def sample_color(raw: bytes, width: int, x: int, y: int
                 ) -> tuple[int, int, int]:
    offset = (y * width + x) * 3
    return tuple(raw[offset:offset + 3])  # type: ignore[return-value]


def require_color(raw: bytes, width: int, x: int, y: int,
                  expected: tuple[int, int, int], label: str) -> None:
    actual = sample_color(raw, width, x, y)
    distance = sum(abs(a - b) for a, b in zip(actual, expected))
    if distance > 9:
        raise RuntimeError(f"{label} pixel {actual} is not near {expected}")


def node_rect(app: Workbench, node: str) -> dict:
    return app.session.call("getBounds", node=node)["rect"]


def node_text(app: Workbench, node: str) -> str:
    for entry in app.session.call("tree")["nodes"]:
        if entry["id"] == node:
            return entry.get("text", "")
    raise RuntimeError(f"node not found in tree: {node}")


def verify_chrome_pixels(app: Workbench, ppm: Path) -> dict:
    width, height, raw = read_ppm(ppm)
    scale = width / 1180
    checks = [
        ("menubar", 0.96, 0.5, (0xF0, 0xF2, 0xF5), 30),
        ("toolbar", 0.61, 0.5, (0xF7, 0xF9, 0xFB), 42),
        ("docs", 0.96, 0.5, (0xEE, 0xF1, 0xF5), 34),
        ("findbar", 0.88, 0.5, (0xEE, 0xF2, 0xF6), 38),
        ("statusbar", 0.60, 0.5, (0xE8, 0xED, 0xF2), 26),
    ]
    heights = {}
    for node, fx, fy, expected, wanted_height in checks:
        rect = node_rect(app, node)
        actual_height = int(rect["height"])
        if actual_height != wanted_height:
            raise RuntimeError(
                f"{node} height is {actual_height}, expected {wanted_height}"
            )
        heights[node] = actual_height
        x = round((int(rect["x"]) + int(rect["width"]) * fx) * scale)
        y = round((int(rect["y"]) + int(rect["height"]) * fy) * scale)
        require_color(raw, width, x, y, expected, node)
    editor = node_rect(app, "editor")
    if int(editor["height"]) < 400:
        raise RuntimeError(f"editor is too short: {editor}")
    require_color(
        raw, width,
        round((int(editor["x"]) + int(editor["width"]) * 0.9) * scale),
        round((int(editor["y"]) + int(editor["height"]) * 0.5) * scale),
        (0xFF, 0xFF, 0xFF), "editor",
    )
    return heights


def verify_editor_gutter(app: Workbench, ppm: Path) -> dict:
    width, height, raw = read_ppm(ppm)
    scale = width / 1180
    editor = node_rect(app, "editor")
    left = round((int(editor["x"]) + 8) * scale)
    right = round((int(editor["x"]) + 44) * scale)
    top = round((int(editor["y"]) + 4) * scale)
    bottom = round((int(editor["y"]) + int(editor["height"]) - 4) * scale)
    require_color(
        raw, width,
        round((int(editor["x"]) + 12) * scale),
        round((int(editor["y"]) + int(editor["height"]) * 0.9) * scale),
        (0xEE, 0xF1, 0xF5), "editor gutter",
    )
    dark = 0
    for y in range(top, bottom, 2):
        for x in range(left, right, 2):
            red, green, blue = sample_color(raw, width, x, y)
            if red + green + blue < 430:
                dark += 1
    if dark < 60:
        raise RuntimeError(
            f"line-number gutter has too few glyph pixels: {dark}"
        )
    return {"dark_pixels": dark, "sample_width": right - left}


def verify_popup_pixels(ppm: Path, menu: dict, label: str) -> dict:
    width, height, raw = read_ppm(ppm)
    rect = menu["rect"]
    scale = width / 1180
    left = round(int(rect["x"]) * scale)
    top = round(int(rect["y"]) * scale)
    right = left + round(int(rect["width"]) * scale)
    bottom = top + round(int(rect["height"]) * scale)
    if not (0 <= left < right <= width and 0 <= top < bottom <= height):
        raise RuntimeError(f"{label} popup lies outside the screenshot")
    require_color(raw, width, left + round(int(rect["width"]) * 0.35 * scale),
                  top + round(18 * scale), (0xFF, 0xFF, 0xFF),
                  f"{label} panel")
    if int(rect["width"]) < 140 or int(rect["height"]) < 40:
        raise RuntimeError(f"{label} popup is too small: {rect}")
    return {
        "width": int(rect["width"]),
        "height": int(rect["height"]),
        "items": len(menu["items"]),
    }


def ppm_to_png(ppm: Path, png: Path) -> None:
    width, height, raw = read_ppm(ppm)

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload)) + kind + payload +
            struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    stride = width * 3
    scanlines = b"".join(
        b"\x00" + raw[y * stride:(y + 1) * stride]
        for y in range(height)
    )
    png.parent.mkdir(parents=True, exist_ok=True)
    png.write_bytes(
        b"\x89PNG\r\n\x1a\n" +
        chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
        chunk(b"IDAT", zlib.compress(scanlines, 9)) +
        chunk(b"IEND", b"")
    )


def click_action(app: Workbench, node: str, action: str,
                 timeout: float = 15.0) -> None:
    app.click_action(node, action, timeout)


def click_tab(app: Workbench, index: int, timeout: float = 15.0) -> None:
    tabs = app.session.call("getTabs", node="docs")["tabs"]
    if index >= len(tabs):
        raise RuntimeError(f"tab {index} does not exist: {len(tabs)} tabs")
    rect = tabs[index]["rect"]
    x = int(rect["x"]) + int(rect["width"]) // 2
    y = int(rect["y"]) + int(rect["height"]) // 2
    app.session.call("uiClick", x=x, y=y)
    if not app.pump_until(lambda: app.active == index, timeout):
        raise RuntimeError(f"tab click did not activate tab {index}")


def open_menu(app: Workbench, node: str) -> dict:
    rect = app.session.call("getBounds", node=node)["rect"]
    x = int(rect["x"]) + int(rect["width"]) // 2
    y = int(rect["y"]) + int(rect["height"]) // 2
    app.session.call("uiClick", x=x, y=y)
    state = app.session.call("menuState")
    return state["menu"]


def menu_index(menu: dict, label: str) -> int:
    for item in menu["items"]:
        if item["label"] == label:
            return int(item["index"])
    labels = [item["label"] for item in menu["items"] if not item["separator"]]
    raise RuntimeError(f"menu item not found: {label} in {labels}")


def click_menu_item(app: Workbench, menu: dict, label: str,
                    timeout: float = 15.0) -> None:
    before = app.action_seq
    response = app.session.call("menuClick", index=menu_index(menu, label))
    if not response.get("closed"):
        raise RuntimeError(f"menu stayed open after {label}")
    if not app.pump_until(lambda: app.action_seq > before, timeout):
        raise RuntimeError(f"menu item did not dispatch: {label}")


def run_self_test(app: Workbench, screenshot: Path, png: Path,
                  metrics_path: Path, temp: Path) -> int:
    log("self-test: startup")
    app.startup()
    if not app.docs[0].text.startswith("Aurora Pad++"):
        raise RuntimeError("welcome document was not loaded")

    log("self-test: File menu and new tab")
    file_menu = open_menu(app, "file-menu")
    file_labels = [
        item["label"] for item in file_menu["items"] if not item["separator"]
    ]
    if (file_labels[:3] != ["New", "Open...", "Save"] or
            "Save As..." not in file_labels or "Exit" not in file_labels):
        raise RuntimeError(f"unexpected File menu: {file_labels}")
    click_menu_item(app, file_menu, "New")
    if len(app.docs) != 2 or app.active != 1:
        raise RuntimeError("File > New did not create and activate a tab")
    if app.docs[1].text != "":
        raise RuntimeError("new document was not empty")

    python_text = (
        "# Aurora Pad++ self-test\n"
        "def greet(name):\n"
        "    return f\"Hello, {name}!\"\n\n"
        "print(greet(\"world\"))\n"
    )
    app.session.call("setText", node="editor", text=python_text)
    app.pump_until(lambda: app.docs[1].dirty, 5)
    if not app.docs[1].dirty:
        raise RuntimeError("editor change event did not mark the tab dirty")
    if app.docs[1].text != python_text:
        raise RuntimeError("editor change event did not capture edited text")

    log("self-test: document tab clicks")
    click_tab(app, 0)
    if app.active != 0 or app.editor_text() == python_text:
        raise RuntimeError("tab switch to the first document failed")
    click_tab(app, 1)
    if app.editor_text() != python_text:
        raise RuntimeError("tab switch back lost the edited document")

    log("self-test: menu screenshot")
    menu_shot = screenshot.with_name("padpp-menu.ppm")
    file_menu = open_menu(app, "file-menu")
    app.screenshot(menu_shot)
    menu_pixels = verify_popup_pixels(menu_shot, file_menu, "File menu")
    click_menu_item(app, file_menu, "Close Tab")
    if len(app.docs) != 2:
        raise RuntimeError("dirty tab was closed without saving")

    log("self-test: language menu")
    language_menu = open_menu(app, "language-menu")
    click_menu_item(app, language_menu, "Python")
    if app.docs[app.active].language != "Python":
        raise RuntimeError("Language > Python did not change the mode")

    log("self-test: editor context menu and find")
    app.session.call("setText", node="find", text="world")
    editor = node_rect(app, "editor")
    context_x = int(editor["x"]) + int(editor["width"]) // 2
    context_y = int(editor["y"]) + int(editor["height"]) // 2
    app.session.call("uiClick", x=context_x, y=context_y, button="right")
    context = app.session.call("menuState")["menu"]
    context_labels = [
        item["label"] for item in context["items"] if not item["separator"]
    ]
    if (context_labels[:4] != ["Find...", "Find Next", "Find Previous",
                               "Replace All"] or
            "Select All" not in context_labels):
        raise RuntimeError(f"unexpected editor context menu: {context_labels}")
    context_shot = screenshot.with_name("padpp-context.ppm")
    app.screenshot(context_shot)
    context_pixels = verify_popup_pixels(
        context_shot, context, "editor context"
    )
    click_menu_item(app, context, "Find Next")
    state = app.session.call("getEditorState", node="editor")
    selected = app.editor_text()[min(state["anchor"], state["cursor"]):
                                  max(state["anchor"], state["cursor"])]
    if selected != "world":
        raise RuntimeError(f"context Find Next selected {selected!r}")

    log("self-test: delayed hover hints")
    case = node_rect(app, "tb-case")
    # Start from a neutral pointer so the hint arms from a fresh move, not from
    # whatever hover state the preceding context-menu click left behind.
    app.session.call("uiMove", x=16, y=700)
    app.pump_until(
        lambda: not app.session.call(
            "tooltipState")["tooltip"]["visible"], 3)
    app.session.call(
        "uiMove",
        x=int(case["x"]) + int(case["width"]) // 2,
        y=int(case["y"]) + int(case["height"]) // 2,
    )
    if not app.pump_until(
            lambda: app.session.call("tooltipState")["tooltip"]["visible"], 5):
        state = app.session.call("tooltipState")["tooltip"]
        raise RuntimeError(
            f"toolbar hover hint did not appear (target={case}, state={state})")
    hint = app.session.call("tooltipState")["tooltip"]
    if (hint["node"] != "tb-case"
            or hint["text"] != "Match case (case-sensitive search)"):
        raise RuntimeError(f"unexpected toolbar hover hint: {hint}")
    if int(hint["rect"]["y"]) + int(hint["rect"]["height"]) > int(case["y"]):
        raise RuntimeError("toolbar hover hint overlaps its anchor")
    app.session.call("uiMove", x=900, y=700)
    if not app.pump_until(
            lambda: not app.session.call(
                "tooltipState")["tooltip"]["visible"], 3):
        raise RuntimeError("hover hint did not hide after pointer exit")

    log("self-test: find-bar replace and view toggles")
    app.session.call("setText", node="replace", text="Aurora")
    click_action(app, "replace-all", "replaceAll")
    replaced = app.editor_text()
    if "greet(\"Aurora\")" not in replaced or "world" in replaced:
        raise RuntimeError("Replace All did not update the document")

    log("self-test: live find counts, whole word, and find previous")
    app.session.call("setText", node="find", text="Aurora")
    app.pump_until(lambda: app.find_needle == "Aurora", 5)
    app.find_needle = "Aurora"
    app._refresh_find_hint()
    if app._find_count != 2:
        raise RuntimeError(f"find count was {app._find_count}, expected 2")
    hint = node_text(app, "find-hint")
    if hint != "2 matches":
        raise RuntimeError(f"find hint was {hint!r}, expected '2 matches'")
    app.session.call("setText", node="find", text="Auro")
    app.find_needle = "Auro"
    app._refresh_find_hint()
    if app._find_count != 2:
        raise RuntimeError("substring find count was not 2")
    click_action(app, "find-word", "toggleWholeWord")
    if not app.whole_word or app._find_count != 0:
        raise RuntimeError("whole-word toggle did not filter the find count")
    hint = node_text(app, "find-hint")
    if hint != "No matches":
        raise RuntimeError(f"whole-word hint was {hint!r}")
    click_action(app, "find-word", "toggleWholeWord")
    if app.whole_word:
        raise RuntimeError("whole-word toggle did not turn off")

    app.session.call("setText", node="find", text="Aurora")
    app.find_needle = "Aurora"
    app.session.call("setSelection", node="editor",
                     start=len(app.editor_text()),
                     end=len(app.editor_text()))
    app.find_previous()
    state = app.session.call("getEditorState", node="editor")
    selected = app.editor_text()[min(state["anchor"], state["cursor"]):
                                  max(state["anchor"], state["cursor"])]
    if selected != "Aurora":
        raise RuntimeError(f"Find Previous selected {selected!r}")
    click_action(app, "tb-wrap", "toggleWrap")
    if not app.wrap:
        raise RuntimeError("toolbar Wrap did not turn word wrap on")
    click_action(app, "tb-wrap", "toggleWrap")
    if app.wrap:
        raise RuntimeError("toolbar Wrap did not turn word wrap off")
    click_action(app, "tb-lines", "toggleLineNumbers")
    if app.line_numbers:
        raise RuntimeError("toolbar Lines did not hide the gutter")
    click_action(app, "tb-lines", "toggleLineNumbers")
    if not app.line_numbers:
        raise RuntimeError("toolbar Lines did not restore the gutter")
    view_menu = open_menu(app, "view-menu")
    click_menu_item(app, view_menu, "Toggle current line")
    if app.highlight_current_line:
        raise RuntimeError("View > current line did not disable the band")
    view_menu = open_menu(app, "view-menu")
    click_menu_item(app, view_menu, "Toggle current line")
    if not app.highlight_current_line:
        raise RuntimeError("View > current line did not restore the band")

    log("self-test: checked menu state and zoom")
    click_action(app, "tb-wrap", "toggleWrap")
    view_menu = open_menu(app, "view-menu")
    wrap_item = next(item for item in view_menu["items"]
                     if item["label"] == "Word wrap")
    if not wrap_item["checked"]:
        raise RuntimeError("View > Word wrap did not show its checked state")
    click_menu_item(app, view_menu, "Word wrap")
    if app.wrap:
        raise RuntimeError("View > Word wrap did not toggle wrap off")
    language_menu = open_menu(app, "language-menu")
    python_item = next(item for item in language_menu["items"]
                       if item["label"] == "Python")
    if not python_item["checked"]:
        raise RuntimeError("Language > Python did not show its checked state")
    click_menu_item(app, language_menu, "Python")

    app.zoom_in()
    if app.zoom_percent != 110:
        raise RuntimeError("Zoom in did not reach 110%")
    zoom_label = node_text(app, "status-zoom")
    if zoom_label != "110%":
        raise RuntimeError(f"status zoom was {zoom_label!r}")
    app.zoom_out()
    app.zoom_reset()
    if app.zoom_percent != 100:
        raise RuntimeError("Zoom reset did not restore 100%")
    styles = app._syntax_styles(app.docs[app.active])
    colors = {style["color"] for style in styles}
    if TOKEN_COLORS["keyword"] not in colors or (
            TOKEN_COLORS["string"] not in colors):
        raise RuntimeError(f"Python syntax styles are incomplete: {colors}")

    log("self-test: save and open")
    sample = temp / "sample.py"
    app.docs[1].path = sample
    app.docs[1].name = sample.name
    app.docs[1].language = app._language_for(sample)
    click_action(app, "tb-save", "save")
    if read_text(sample) != replaced:
        raise RuntimeError("Save did not write the active document")
    if app.docs[1].dirty:
        raise RuntimeError("Save did not clear the dirty marker")

    opened = temp / "opened.md"
    opened_text = "# Opened file\n\nRound-trip through the app-owned model.\n"
    write_text(opened, opened_text)
    app.open_path(opened)
    if app.editor_text() != opened_text or app.docs[app.active].language != "Markdown":
        raise RuntimeError("Open did not load text and language metadata")

    log("self-test: large document benchmark")
    large = app.run_benchmark()
    large_index = len(app.docs) - 1
    if large["lines"] not in (BENCH_LINES, BENCH_LINES + 1):
        raise RuntimeError(
            f"benchmark created {large['lines']} lines, "
            f"expected {BENCH_LINES}"
        )
    # The host virtualizes editor layout; whole-document repaint regressions
    # previously took 1.5 s to load, 12 s to find, and ~419 MB of RSS.
    if (large["load_seconds"] > 2
            or large["roundtrip_seconds"] > 2
            or large["switch_seconds"] > 3
            or large["find_seconds"] > 2):
        raise RuntimeError(f"large-file performance gate failed: {large}")
    host_rss = host_working_set_mb(app.session.process.pid)
    if host_rss is not None and host_rss > 350:
        raise RuntimeError(
            f"large-file memory gate failed: {host_rss:.0f} MB working set"
        )

    log("self-test: screenshot")
    app.activate_tab(large_index)
    if app.docs[app.active].name != large["name"]:
        raise RuntimeError(
            f"benchmark tab was not activated: {app.docs[app.active].name}"
        )
    app.session.call("setText", node="find", text="Aurora")
    app.session.call("setText", node="replace", text="world")
    app.find_needle = "Aurora"
    app._refresh_all("Self-test passed | 2,001-line large-file document")
    app.session.call("uiMove", x=900, y=700)
    app.screenshot(screenshot)
    pixels = verify_ppm_pixels(screenshot)
    chrome_heights = verify_chrome_pixels(app, screenshot)
    gutter = verify_editor_gutter(app, screenshot)
    ppm_to_png(screenshot, png)
    menu_png = png.with_name("padpp-menu.png")
    context_png = png.with_name("padpp-context.png")
    ppm_to_png(menu_shot, menu_png)
    ppm_to_png(context_shot, context_png)
    metrics = {
        "large_file": large,
        "host_working_set_mb": host_rss,
        "screenshot_pixels": pixels,
        "chrome_heights": chrome_heights,
        "editor_gutter": gutter,
        "file_menu": menu_pixels,
        "editor_context_menu": context_pixels,
        "tabs": len(app.docs),
        "dirty_after_save": app.docs[1].dirty,
        "screenshot": str(png),
        "screenshots": [str(png), str(menu_png), str(context_png)],
    }
    metrics_path.parent.mkdir(parents=True, exist_ok=True)
    metrics_path.write_text(json.dumps(metrics, indent=2) + "\n",
                            encoding="utf-8")
    print(json.dumps(metrics, indent=2))
    code = app.stop()
    if code != 0:
        raise RuntimeError(f"host exited with {code}\n{app.session.stderr_text()}")
    print("aurora pad++ self-test passed")
    return 0


def main() -> int:
    global BENCH_LINES
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", type=Path, default=HOST)
    parser.add_argument("--file", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--screenshot", type=Path,
                        default=ROOT / "build" / "padpp.ppm")
    parser.add_argument("--png", type=Path,
                        default=ROOT / "build" / "padpp.png")
    parser.add_argument("--metrics", type=Path,
                        default=ROOT / "build" / "padpp-metrics.json")
    parser.add_argument("--bench-lines", type=int, default=BENCH_LINES)
    args = parser.parse_args()
    BENCH_LINES = args.bench_lines

    if not args.host.is_file():
        raise RuntimeError(
            f"aurora host executable is missing: {args.host}\n"
            "build the host first or set AURORA_HOST_EXE"
        )
    args.screenshot.parent.mkdir(parents=True, exist_ok=True)
    args.png.parent.mkdir(parents=True, exist_ok=True)
    args.metrics.parent.mkdir(parents=True, exist_ok=True)

    session = HostSession(args.host, SCENE)
    app = Workbench(session)
    try:
        if args.self_test:
            faulthandler.dump_traceback_later(60, repeat=True)
            with tempfile.TemporaryDirectory(prefix="aurora-padpp-") as folder:
                code = run_self_test(
                    app, args.screenshot, args.png, args.metrics,
                    Path(folder),
                )
            faulthandler.cancel_dump_traceback_later()
            return code
        app.startup(args.file.resolve() if args.file else None)
        print(f"aurora pad++ ready: "
              f"{args.file or app.docs[app.active].name}")
        while app.running and session.process.poll() is None:
            event = session.next_event(0.2)
            if event is not None:
                app.handle_event(event)
        return session.process.poll() or 0
    finally:
        if session.process.poll() is None:
            session.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"aurora pad++ failed: {error}", file=sys.stderr)
        raise SystemExit(1)
