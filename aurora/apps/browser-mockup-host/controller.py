#!/usr/bin/env python3
"""Controller for the host-scene Aurora browser mockup.

The host owns the window, tab strip, toolbar rows, address field, status labels,
layout, and painting. The controller owns page state and replaces the flexed
page canvas draw list when state or available canvas bounds change.
"""
from __future__ import annotations

import json
from pathlib import Path
import sys
import time

PROJECT = Path(__file__).resolve().parent
AURORA = PROJECT.parents[1]
HOST_DIR = AURORA / "aurora-host"
sys.path.insert(0, str(HOST_DIR / "tools"))
from host_session import Host  # noqa: E402

SCENE = PROJECT / "scene.json"
PAGE_TITLES = {
    "start": "Aurora Start",
    "design": "Design Notes",
    "docs": "Docs & guides",
    "gallery": "Color studies",
    "search": "Search",
}
PAGE_COLORS = {
    "start": "#09111d",
    "design": "#f3eee5",
    "docs": "#0a1017",
    "gallery": "#160f23",
    "search": "#f4f8fb",
}
SWATCHES = [
    ("Ember", "#F25F4D"), ("Tide", "#38BDF8"), ("Citrus", "#F5B83D"),
    ("Iris", "#8B7CF6"), ("Paper", "#E8E1D6"), ("Ink", "#293241"),
]


def text_cmds(cmds: list, x: int, y: int, value: str, scale: int = 2,
              color: str = "#e7eef6") -> None:
    if value:
        cmds.append({"op": "text", "x": int(x), "y": int(y),
                     "text": value, "scale": int(scale), "color": color})


def rect(cmds: list, x: int, y: int, w: int, h: int, color: str) -> None:
    cmds.append({"op": "rect", "x": int(x), "y": int(y),
                 "width": int(w), "height": int(h), "color": color})


def rounded(cmds: list, x: int, y: int, w: int, h: int, radius: int,
            color: str) -> None:
    cmds.append({"op": "roundedRect", "x": int(x), "y": int(y),
                 "width": int(w), "height": int(h), "radius": int(radius),
                 "color": color})


def line(cmds: list, x1: int, y1: int, x2: int, y2: int, color: str,
         thickness: int = 1) -> None:
    cmds.append({"op": "line", "x": int(x1), "y": int(y1),
                 "x2": int(x2), "y2": int(y2), "color": color,
                 "thickness": int(thickness)})


def circle(cmds: list, x: int, y: int, radius: int, color: str) -> None:
    cmds.append({"op": "circle", "x": int(x), "y": int(y),
                 "radius": int(radius), "color": color})


def ring(cmds: list, x: int, y: int, radius: int, thickness: int,
         color: str) -> None:
    cmds.append({"op": "ring", "x": int(x), "y": int(y),
                 "radius": int(radius), "color": color,
                 "thickness": int(thickness)})


def wrap_words(value: str, width: int, scale: int) -> list[str]:
    max_chars = max(14, int(width / max(5.5, scale * 4.5)))
    words = value.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = word if not current else current + " " + word
        if len(candidate) <= max_chars:
            current = candidate
        else:
            if current:
                lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


class Tab:
    def __init__(self, page: str = "start"):
        self.history = [page]
        self.index = 0
        self.query = ""
        self.doc_section = 0
        self.gallery_index = 0

    @property
    def page(self) -> str:
        return self.history[self.index]


class BrowserController:
    def __init__(self, host: Host):
        self.host = host
        self.tabs = [Tab()]
        self.active = 0
        self.starred: set[tuple[int, str]] = set()
        self.press: tuple[int, int] | None = None
        self.hitboxes: list[tuple[int, int, int, int, str, object]] = []
        self.canvas_size = (0, 0)
        self.status = "READY"

    @property
    def tab(self) -> Tab:
        return self.tabs[self.active]

    def current_url(self) -> str:
        page = self.tab.page
        if page == "docs":
            return ("aurora://docs/overview", "aurora://docs/input",
                    "aurora://docs/frames", "aurora://docs/lifecycle")[
                self.tab.doc_section]
        if page == "search":
            query = self.tab.query
            return "aurora://search" + (f"?q={query}" if query else "")
        return {
            "start": "aurora://start",
            "design": "aurora://journal/focus",
            "gallery": "aurora://gallery",
        }[page]

    def refresh_tabs(self) -> None:
        items = []
        for index, tab in enumerate(self.tabs):
            items.append({
                "label": f"●  {PAGE_TITLES[tab.page]}",
                "action": f"tab.{index}",
                "active": index == self.active,
            })
        self.host.request("setTabs", node="tabs", items=items)

    def refresh(self) -> None:
        self.refresh_tabs()
        self.host.request("setText", node="address", text=self.current_url(),
                          notify=False)
        self.host.request("setText", node="status",
                          text=f"{self.status}  /  {self.current_url()}")
        self.redraw()

    def canvas_bounds(self) -> tuple[int, int]:
        result = self.host.request("getBounds", node="page")
        rect_data = result.get("rect", {})
        return int(rect_data.get("width", 0)), int(rect_data.get("height", 0))

    def redraw(self) -> None:
        width, height = self.canvas_bounds()
        if width <= 0 or height <= 0:
            return
        self.canvas_size = (width, height)
        cmds, hits = self.build_page(self.tab.page, width, height)
        self.hitboxes = hits
        self.host.request("setCanvas", node="page", commands=cmds)

    def navigate(self, page: str, query: str | None = None) -> None:
        tab = self.tab
        if query is not None:
            tab.query = query
        if page == "search":
            tab.query = query or "local mockup"
        if tab.history[tab.index] != page:
            tab.history = tab.history[:tab.index + 1]
            tab.history.append(page)
            tab.index = len(tab.history) - 1
        self.status = "READY"
        self.refresh()

    def back(self) -> None:
        if self.tab.index > 0:
            self.tab.index -= 1
            self.status = "READY"
            self.refresh()

    def forward(self) -> None:
        if self.tab.index + 1 < len(self.tab.history):
            self.tab.index += 1
            self.status = "READY"
            self.refresh()

    def go_from_text(self) -> None:
        result = self.host.request("getText", node="address")
        value = str(result.get("text", "")).strip()
        lower = value.lower()
        if not lower:
            self.navigate("start")
            return
        if "docs" in lower or "surface" in lower:
            self.tab.doc_section = 0
            if "input" in lower or "pointer" in lower:
                self.tab.doc_section = 1
            elif "frame" in lower:
                self.tab.doc_section = 2
            elif "life" in lower or "handshake" in lower:
                self.tab.doc_section = 3
            self.navigate("docs")
        elif "design" in lower or "focus" in lower or "journal" in lower:
            self.navigate("design")
        elif "gallery" in lower or "color" in lower or "palette" in lower:
            self.navigate("gallery")
        elif "start" in lower or "home" in lower or "aurora" in lower:
            self.navigate("start")
        else:
            self.navigate("search", value)

    def handle_action(self, action: str) -> None:
        if action == "tab.new":
            if len(self.tabs) < 5:
                self.tabs.append(Tab())
                self.active = len(self.tabs) - 1
                self.status = "New tab"
                self.refresh()
            return
        if action == "tab.close":
            if len(self.tabs) > 1:
                self.tabs.pop(self.active)
                self.active = min(self.active, len(self.tabs) - 1)
                self.status = "Tab closed"
                self.refresh()
            return
        if action.startswith("tab."):
            try:
                self.active = int(action[4:])
                self.status = "READY"
                self.refresh()
            except ValueError:
                pass
            return
        if action == "nav.back":
            self.back()
        elif action == "nav.forward":
            self.forward()
        elif action == "nav.home":
            self.navigate("start")
        elif action == "nav.reload":
            self.status = "Reloaded local page"
            self.refresh()
        elif action == "address.go":
            self.go_from_text()
        elif action == "bookmark.toggle":
            key = (self.active, self.tab.page)
            if key in self.starred:
                self.starred.remove(key)
                self.status = "Bookmark removed"
            else:
                self.starred.add(key)
                self.status = "Bookmark saved"
            self.refresh()
        elif action.startswith("bookmark."):
            page = action.split(".", 1)[1]
            if page in PAGE_TITLES:
                self.navigate(page)
        elif action.startswith("open:"):
            self.navigate(action.split(":", 1)[1])
        elif action.startswith("doc:"):
            self.tab.doc_section = int(action.split(":", 1)[1])
            self.refresh()
        elif action.startswith("gallery:"):
            self.tab.gallery_index = int(action.split(":", 1)[1])
            self.refresh()
        elif action.startswith("search:"):
            self.navigate(action.split(":", 1)[1])

    def handle_pointer(self, event: dict) -> None:
        kind = event.get("kind")
        x = int(event.get("x", 0))
        y = int(event.get("y", 0))
        if kind == "down":
            self.press = (x, y)
        elif kind == "up" and self.press is not None:
            if abs(self.press[0] - x) <= 4 and abs(self.press[1] - y) <= 4:
                for hx, hy, hw, hh, action, _ in reversed(self.hitboxes):
                    if hx <= x < hx + hw and hy <= y < hy + hh:
                        self.handle_action(action)
                        break
            self.press = None

    # ----- page rendering -------------------------------------------------

    def build_page(self, page: str, w: int, h: int):
        if page == "start":
            return self.build_start(w, h)
        if page == "design":
            return self.build_design(w, h)
        if page == "docs":
            return self.build_docs(w, h)
        if page == "gallery":
            return self.build_gallery(w, h)
        return self.build_search(w, h)

    def build_start(self, w: int, h: int):
        cmds: list = []
        hits: list = []
        margin = max(28, min(64, w // 15))
        rect(cmds, 0, 0, w, h, "#09111d")
        ring(cmds, w - 120, 150, 190, 1, "#153c52")
        ring(cmds, 100, h - 40, 210, 1, "#1e2748")
        text_cmds(cmds, margin, 34, "AURORA START  /  LOCAL SESSION", 1,
                  "#5f8298")
        headline = "A calmer way to browse."
        text_cmds(cmds, margin, 66, headline, 6 if w >= 760 else 4,
                  "#eef5fb")
        text_cmds(cmds, margin, 120 if w >= 760 else 108,
                  "A private workspace for the pages you actually need.", 2,
                  "#8fa3b9")
        cols = 3 if w >= 900 else 2 if w >= 600 else 1
        gap = 18
        card_w = max(180, (w - margin * 2 - gap * (cols - 1)) // cols)
        card_h = 122
        top = 178
        cards = [
            ("Design Notes", "Focus, rhythm and quiet interfaces.", "design",
             "#f59e0b"),
            ("Docs & guides", "The Aurora surface, explained.", "docs",
             "#818cf8"),
            ("Color studies", "Palettes with a point of view.", "gallery",
             "#f25f4d"),
        ]
        for index, (title, description, page, tint) in enumerate(cards):
            col = index % cols
            row = index // cols
            x = margin + col * (card_w + gap)
            y = top + row * (card_h + 14)
            if y + card_h > h - 28:
                continue
            rounded(cmds, x, y, card_w, card_h, 14, "#101b28")
            rect(cmds, x + 18, y + 18, 5, card_h - 36, tint)
            circle(cmds, x + 36, y + 38, 6, tint)
            text_cmds(cmds, x + 54, y + 24, title, 3, "#ecf4fb")
            for line_index, line_value in enumerate(
                    wrap_words(description, card_w - 76, 2)[:2]):
                text_cmds(cmds, x + 54, y + 58 + line_index * 20,
                          line_value, 2, "#8ea4b8")
            text_cmds(cmds, x + card_w - 58, y + card_h - 30, "OPEN", 1,
                      "#657c91")
            hits.append((x, y, card_w, card_h, f"open:{page}", index))
        rows = (len(cards) + cols - 1) // cols
        info_y = top + rows * (card_h + 14) + 10
        if info_y + 82 < h - 26:
            rounded(cmds, margin, info_y, w - margin * 2, 72, 12,
                    "#0f1a26")
            rect(cmds, margin + 18, info_y + 16, 4, 40, "#38bdf8")
            text_cmds(cmds, margin + 36, info_y + 13,
                      "NATIVE CHROME  /  RESPONSIVE PAGE", 2,
                      "#dce9f4")
            text_cmds(cmds, margin + 36, info_y + 39,
                      "Tabs, navigation and fields reflow natively. This page "
                      "redraws from its canvas bounds.", 1, "#7890a6")
            text_cmds(cmds, w - margin - 150, info_y + 14,
                      "LOCAL", 1, "#5f8298")
        text_cmds(cmds, margin, h - 36,
                  "CLICK A CARD  /  TYPE IN THE ADDRESS BAR AND PRESS GO", 1,
                  "#52677d")
        return cmds, hits

    def build_design(self, w: int, h: int):
        cmds: list = []
        hits: list = []
        margin = max(28, min(64, w // 15))
        rect(cmds, 0, 0, w, h, "#f3eee5")
        rect(cmds, 0, 0, w, 58, "#f8f4ed")
        line(cmds, margin, 58, w - margin, 58, "#d8cdbf")
        text_cmds(cmds, margin, 22, "AURORA JOURNAL", 3, "#201b16")
        text_cmds(cmds, w - margin - 180, 26, "ISSUE 04  /  DESIGN", 1,
                  "#7a6d5e")
        text_cmds(cmds, margin, 88, "Designing for focus", 6 if w >= 760 else 5,
                  "#1b1712")
        text_cmds(cmds, margin, 148,
                  "A field guide to interfaces that leave room to think.", 2,
                  "#655a4e")
        text_cmds(cmds, margin, 184, "MARA VOSS  /  8 MIN READ", 1,
                  "#8b7b68")
        article_w = max(320, int((w - margin * 2) * (0.60 if w >= 900 else 1.0)))
        body = ("The best interfaces do not demand attention. They make the "
                "next step obvious, then get out of the way. Focus is not a "
                "feature you toggle; it is the absence of everything that did "
                "not need to be there.")
        y = 222
        for value in wrap_words(body, article_w, 2):
            text_cmds(cmds, margin, y, value, 2, "#342e27")
            y += 24
        y += 12
        text_cmds(cmds, margin, y, "Leave room around the thing that matters.",
                  2, "#342e27")
        y += 48
        text_cmds(cmds, margin, y, "Read the field notes  >", 2, "#b34c30")
        hits.append((margin, y - 3, 220, 28, "open:gallery", 0))
        if w >= 900:
            qx = margin + article_w + 36
            qw = w - qx - margin
            qy = 220
            rounded(cmds, qx, qy, qw, 154, 12, "#e8dfd1")
            line(cmds, qx + 20, qy + 22, qx + 48, qy + 22, "#c55f3f", 3)
            quote = ("Attention is the rarest thing we can give an interface. "
                     "Spend it carefully.")
            yy = qy + 44
            for value in wrap_words(quote, qw - 44, 2):
                text_cmds(cmds, qx + 24, yy, value, 2, "#46392f")
                yy += 24
            text_cmds(cmds, qx + 24, qy + 122, "PRINCIPLE 01", 1, "#8b725d")
            rounded(cmds, qx, qy + 176, qw, 70, 10, "#1d2732")
            text_cmds(cmds, qx + 18, qy + 192, "LEAVE ROOM", 2, "#e8eef5")
            text_cmds(cmds, qx + 18, qy + 216,
                      "Quiet chrome. One clear next step.", 1, "#8fa1b6")
        else:
            bottom = y + 46
            rounded(cmds, margin, bottom, w - margin * 2, 104, 10, "#1d2732")
            text_cmds(cmds, margin + 18, bottom + 18,
                      "LEAVE ROOM", 2, "#e8eef5")
            text_cmds(cmds, margin + 18, bottom + 44,
                      "Quiet chrome. One clear next step.", 1, "#8fa1b6")
        return cmds, hits

    def build_docs(self, w: int, h: int):
        cmds: list = []
        hits: list = []
        margin = max(28, min(56, w // 18))
        rect(cmds, 0, 0, w, h, "#0a1017")
        wide = w >= 860
        sidebar = 210 if wide else 0
        if wide:
            rect(cmds, 0, 0, sidebar, h, "#0e151e")
            line(cmds, sidebar, 0, sidebar, h, "#1d2936")
        text_cmds(cmds, margin, 28, "AURORA SURFACE", 2, "#e7eef6")
        text_cmds(cmds, margin, 54, "DOCUMENTATION", 1, "#5f7186")
        nav = ["Overview", "Pointer input", "Frames", "Lifecycle"]
        nav_x = margin if wide else margin
        nav_y = 92 if wide else 92
        for index, label in enumerate(nav):
            x = nav_x + (0 if wide else index * 150)
            y = nav_y + (index * 38 if wide else 0)
            active = index == self.tab.doc_section
            if active:
                rounded(cmds, x - 8, y - 6, 180 if wide else 138, 32, 6,
                        "#162331")
            text_cmds(cmds, x, y, label, 2, "#e7eef6" if active else "#8c9caf")
            hits.append((x - 8, y - 6, 180 if wide else 138, 32,
                         f"doc:{index}", index))
        content_x = margin + sidebar + (24 if wide else 0)
        content_y = 92 if wide else 148
        if not wide:
            content_y = 166
        titles = ["Build calm interfaces.", "Pointer input, plainly.",
                  "Publish complete frames.", "Handshake, don't guess."]
        intros = [
            "A small explicit contract for pixels, input and lifecycle.",
            "Events arrive in a ring with logical surface coordinates.",
            "Fill the inactive buffer, flip it, then acknowledge the frame.",
            "The host reports mapping, dimensions and frame freshness.",
        ]
        text_cmds(cmds, content_x, content_y, titles[self.tab.doc_section],
                  6 if w >= 760 else 4, "#f0f5fa")
        intro_lines = wrap_words(intros[self.tab.doc_section],
                                 w - content_x - margin, 2)
        yy = content_y + 48
        for value in intro_lines:
            text_cmds(cmds, content_x, yy, value, 2, "#8c9caf")
            yy += 24
        code_y = yy + 18
        code_w = w - content_x - margin
        rounded(cmds, content_x, code_y, code_w, 132, 10, "#111a24")
        line(cmds, content_x, code_y + 34, content_x + code_w, code_y + 34,
             "#263442")
        text_cmds(cmds, content_x + 18, code_y + 10, "module.d", 1, "#5f7186")
        code = [
            "auto surface = LiveSurface(path);",
            "surface.publish(frame);",
            "surface.waitHost(surface.sequence);",
        ]
        for index, value in enumerate(code):
            text_cmds(cmds, content_x + 18, code_y + 46 + index * 22,
                      value, 1, "#b9cfe2")
        note_y = min(h - 54, code_y + 154)
        rounded(cmds, content_x, note_y, code_w, 42, 8, "#101b19")
        rect(cmds, content_x, note_y + 7, 3, 28, "#34d399")
        text_cmds(cmds, content_x + 14, note_y + 12,
                  "This page is painted by the host canvas and reflows with the window.",
                  1, "#a9c9bf")
        contract_y = note_y + 56
        contract_h = min(100, h - contract_y - 16)
        if contract_h >= 76:
            rounded(cmds, content_x, contract_y, code_w, contract_h, 10,
                    "#0e171f")
            text_cmds(cmds, content_x + 18, contract_y + 12,
                      "SURFACE CONTRACT", 1, "#5f8298")
            columns = [
                ("FRAMES", "Two RGBA buffers"),
                ("INPUT", "24-byte events"),
                ("DPI", "Native pixel target"),
            ]
            col_w = max(150, (code_w - 36) // 3)
            for index, (heading, body) in enumerate(columns):
                x = content_x + 18 + index * col_w
                if x + col_w > content_x + code_w - 12:
                    break
                text_cmds(cmds, x, contract_y + 40, heading, 1, "#dce9f4")
                text_cmds(cmds, x, contract_y + 60, body, 1, "#7890a6")
        return cmds, hits

    def build_gallery(self, w: int, h: int):
        cmds: list = []
        hits: list = []
        margin = max(28, min(56, w // 16))
        rect(cmds, 0, 0, w, h, "#160f23")
        text_cmds(cmds, margin, 28, "COLOR  /  MATERIAL", 1, "#a89cf4")
        text_cmds(cmds, margin, 48, "Color studies.", 6 if w >= 760 else 4,
                  "#e7eef6")
        text_cmds(cmds, margin, 98, "A small palette library for quiet interfaces.",
                  2, "#8c9caf")
        cols = 3 if w >= 900 else 2 if w >= 640 else 1
        gap = 16
        grid_w = w - margin * 2
        card_w = (grid_w - gap * (cols - 1)) // cols
        card_h = 94
        top = 146
        for index, (name, color) in enumerate(SWATCHES):
            col = index % cols
            row = index // cols
            x = margin + col * (card_w + gap)
            y = top + row * (card_h + 14)
            if y + card_h > h - 26:
                continue
            selected = index == self.tab.gallery_index
            rounded(cmds, x, y, card_w, card_h, 10, color)
            if selected:
                circle(cmds, x + card_w - 20, y + 20, 10, "#ffffff")
                line(cmds, x + card_w - 25, y + 20, x + card_w - 21, y + 24,
                     "#1b2028", 2)
                line(cmds, x + card_w - 21, y + 24, x + card_w - 14, y + 14,
                     "#1b2028", 2)
            text_cmds(cmds, x + 14, y + card_h - 48, name, 2,
                      "#20252f" if color in ("#F5B83D", "#E8E1D6") else "#ffffff")
            text_cmds(cmds, x + 14, y + card_h - 28, color.upper(), 1,
                      "#20252f" if color in ("#F5B83D", "#E8E1D6") else "#dbe7f2")
            hits.append((x, y, card_w, card_h, f"gallery:{index}", index))
        detail_y = top + (len(SWATCHES) + cols - 1) // cols * (card_h + 14) + 10
        if detail_y < h - 46:
            selected_name, selected_color = SWATCHES[self.tab.gallery_index]
            rounded(cmds, margin, detail_y, grid_w, 42, 8, "#111722")
            text_cmds(cmds, margin + 14, detail_y + 10,
                      f"SELECTED  /  {selected_name}  /  {selected_color.upper()}",
                      1, "#9db3c8")
            detail_top = detail_y + 54
            detail_h = min(178, h - detail_top - 18)
            if detail_h >= 116:
                rounded(cmds, margin, detail_top, grid_w, detail_h, 12,
                        "#111722")
                block_w = min(150, detail_h - 28)
                rounded(cmds, margin + 16, detail_top + 14, block_w,
                        detail_h - 28, 10, selected_color)
                value = selected_color.lstrip("#")
                rgb = (int(value[0:2], 16), int(value[2:4], 16),
                       int(value[4:6], 16))
                info_x = margin + 16 + block_w + 24
                text_cmds(cmds, info_x, detail_top + 18, "SELECTED STUDY",
                          1, "#7c8da1")
                text_cmds(cmds, info_x, detail_top + 38, selected_name, 4,
                          "#e7eef6")
                text_cmds(cmds, info_x, detail_top + 78,
                          selected_color.upper(), 2, "#9db3c8")
                text_cmds(cmds, info_x, detail_top + 106,
                          f"RGB  {rgb[0]}  {rgb[1]}  {rgb[2]}", 1, "#5f7186")
                text_cmds(cmds, info_x, detail_top + 128,
                          "Click any study to inspect its palette.", 1,
                          "#5f7186")
                note_x = info_x + 330
                if note_x + 260 < margin + grid_w - 20:
                    text_cmds(cmds, note_x, detail_top + 18,
                              "PALETTE NOTE", 1, "#7c8da1")
                    note = ("A quiet palette needs one confident accent, "
                            "generous neutral space, and a clear reading "
                            "order. Let the surface carry the contrast.")
                    yy = detail_top + 40
                    for value in wrap_words(note, margin + grid_w - note_x - 24, 1):
                        text_cmds(cmds, note_x, yy, value, 1, "#8c9caf")
                        yy += 20
        return cmds, hits

    def build_search(self, w: int, h: int):
        cmds: list = []
        hits: list = []
        margin = max(28, min(56, w // 16))
        rect(cmds, 0, 0, w, h, "#f4f8fb")
        query = self.tab.query or "local mockup"
        text_cmds(cmds, margin, 28, "LOCAL SEARCH  /  AURORA INDEX", 1,
                  "#1d6d8a")
        text_cmds(cmds, margin, 48, "Search results", 6 if w >= 760 else 4,
                  "#182839")
        text_cmds(cmds, margin, 98, f'Results for "{query[:58]}"', 2,
                  "#50687c")
        text_cmds(cmds, margin, 124,
                  "Local pages match the mockup index. No network was used.", 1,
                  "#71869a")
        line(cmds, margin, 150, w - margin, 150, "#d2dee9")
        rows = [
            ("Designing for focus", "aurora://journal/focus",
             "A field guide to interfaces that leave room to think.", "design"),
            ("Docs & guides", "aurora://docs/overview",
             "The Aurora surface, pointer input, frames and lifecycle.", "docs"),
            ("Color studies", "aurora://gallery",
             "A small palette library for quiet interfaces.", "gallery"),
        ]
        y = 174
        for title, url, snippet, page in rows:
            if y + 78 > h - 20:
                break
            rounded(cmds, margin, y, w - margin * 2, 78, 10, "#ffffff")
            line(cmds, margin, y, margin + (w - margin * 2), y, "#d3dfe9")
            text_cmds(cmds, margin + 22, y + 12, title, 3, "#1c2c3c")
            text_cmds(cmds, margin + 22, y + 38, url, 1, "#5d7b90")
            text_cmds(cmds, margin + 22, y + 56, snippet, 1, "#526678")
            hits.append((margin, y, w - margin * 2, 78, f"search:{page}", page))
            y += 90
        footer_y = y + 10
        footer_h = min(82, h - footer_y - 18)
        if footer_h >= 56:
            rounded(cmds, margin, footer_y, w - margin * 2, footer_h, 8,
                    "#e7eef5")
            text_cmds(cmds, margin + 18, footer_y + 12,
                      "LOCAL INDEX  /  3 PAGES MATCHED", 1, "#5b7a90")
            text_cmds(cmds, margin + 18, footer_y + 34,
                      "No network was used. Every result is a page in this host-scene mockup.",
                      1, "#71869a")
        return cmds, hits

    # ----- event loop -----------------------------------------------------

    def run(self) -> None:
        self.refresh()
        while self.host.process.poll() is None:
            try:
                event = self.host.pop_event(lambda value: True, timeout=0.25)
            except TimeoutError:
                continue
            kind = event.get("event")
            if kind == "action":
                self.handle_action(str(event.get("action", "")))
            elif kind == "pointer":
                self.handle_pointer(event)
            elif kind == "tick":
                try:
                    width, height = self.canvas_bounds()
                except Exception:
                    continue
                if (width, height) != self.canvas_size:
                    self.redraw()

    def close(self) -> None:
        self.host.close()


def main() -> int:
    host = Host(SCENE, watch=True, minimized=False)
    controller = BrowserController(host)
    try:
        controller.run()
    except KeyboardInterrupt:
        pass
    finally:
        controller.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
