#!/usr/bin/env python3
"""Drive the generic host's menu, toolbar, tab and context-menu depth."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys
import traceback

from control_client import HostSession

ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def center(rect: dict) -> tuple[int, int]:
    return (
        int(rect["x"]) + int(rect["width"]) // 2,
        int(rect["y"]) + int(rect["height"]) // 2,
    )


def action_events(session: HostSession) -> list[tuple[str, str]]:
    return [
        (event.get("node", ""), event.get("action", ""))
        for event in session.events
        if event.get("event") == "action"
    ]


def action_count(session: HostSession, node: str, action: str) -> int:
    return action_events(session).count((node, action))


def open_menu(session: HostSession, bounds: dict, node: str) -> dict:
    x, y = center(bounds[node])
    response = session.send("uiClick", x=x, y=y)
    require(response.get("ok") is True, f"uiClick failed for {node}: {response}")
    state = session.send("menuState")
    require(state.get("ok") is True, f"menuState failed for {node}: {state}")
    return state["menu"]


def menu_index(menu: dict, label: str) -> int:
    for item in menu["items"]:
        if item["label"] == label:
            return int(item["index"])
    labels = [item["label"] for item in menu["items"]]
    raise RuntimeError(f"menu item not found: {label} in {labels}")


def menu_item(menu: dict, label: str) -> dict:
    for item in menu["items"]:
        if item["label"] == label:
            return item
    labels = [item["label"] for item in menu["items"]]
    raise RuntimeError(f"menu item not found: {label} in {labels}")


def click_item(session: HostSession, menu: dict, label: str) -> None:
    index = menu_index(menu, label)
    response = session.send("menuClick", index=index)
    require(response.get("ok") is True, f"menuClick failed for {label}: {response}")
    require(response.get("closed") is True, f"menu stayed open after {label}")


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    tokens: list[bytes] = []
    position = 0
    while len(tokens) < 4:
        while position < len(data) and data[position : position + 1].isspace():
            position += 1
        if data[position : position + 1] == b"#":
            while position < len(data) and data[position : position + 1] not in (b"\n", b"\r"):
                position += 1
            continue
        start = position
        while position < len(data) and not data[position : position + 1].isspace():
            position += 1
        tokens.append(data[start:position])
    require(tokens[0] == b"P6", f"{path} is not a binary PPM")
    width, height, maximum = (int(token) for token in tokens[1:])
    require(maximum == 255, f"{path} has unsupported channel depth")
    while position < len(data) and data[position : position + 1].isspace():
        position += 1
    pixels = data[position:]
    require(len(pixels) == width * height * 3, f"{path} has a truncated pixel buffer")
    return width, height, pixels


def sample(pixels: bytes, width: int, x: int, y: int) -> tuple[int, int, int]:
    offset = (y * width + x) * 3
    return tuple(pixels[offset : offset + 3])  # type: ignore[return-value]


def require_color(pixels: bytes, width: int, x: int, y: int,
                  expected: tuple[int, int, int], label: str) -> None:
    actual = sample(pixels, width, x, y)
    distance = sum(abs(a - b) for a, b in zip(actual, expected))
    require(distance <= 9, f"{label} pixel {actual} is not near {expected}")


def pixel_scale(width: int, root: dict) -> float:
    scale = width / int(root["width"])
    require(scale >= 1.0 and scale <= 4.0,
            f"unexpected screenshot scale: {scale}")
    return scale


def pixel_point(rect: dict, root: dict, scale: float) -> tuple[int, int]:
    return (
        round((int(rect["x"]) - int(root["x"])) * scale),
        round((int(rect["y"]) - int(root["y"])) * scale),
    )


def verify_layout(pixels: bytes, width: int, height: int, root: dict,
                  bounds: dict) -> None:
    scale = pixel_scale(width, root)
    require((width, height) == (round(int(root["width"]) * scale),
                                round(int(root["height"]) * scale)),
            "screenshot size does not match the scaled scene window")
    ly = round((int(bounds["menubar"]["y"]) - int(root["y"])) * scale)
    require_color(pixels, width, width - round(20 * scale),
                  ly + round(15 * scale), (0xF5, 0xF6, 0xF7),
                  "menu bar")
    require_color(pixels, width, width - round(20 * scale),
                  ly + round((30 + 5) * scale), (0xF7, 0xF8, 0xFA),
                  "toolbar")
    require_color(pixels, width, width - round(20 * scale),
                  ly + round((30 + 42 + 17) * scale),
                  (0xF3, 0xF3, 0xF3), "tab strip")
    editor = bounds["editor"]
    editor_x, editor_y = pixel_point(editor, root, scale)
    require_color(pixels, width,
                  editor_x + round(int(editor["width"]) * scale) // 2,
                  editor_y + round(int(editor["height"]) * scale) // 2,
                  (0xFF, 0xFF, 0xFF), "editor field")
    status = bounds["statusbar"]
    status_x, status_y = pixel_point(status, root, scale)
    require_color(pixels, width,
                  status_x + round(int(status["width"]) * scale) // 2,
                  status_y + round(int(status["height"]) * scale) // 2,
                  (0xEE, 0xF1, 0xF5), "status bar")
    require(int(root["x"]) == 0 and int(root["y"]) == 0,
            "root does not start at the client origin")


def verify_popup_pixels(pixels: bytes, width: int, height: int, root: dict,
                        menu: dict, label: str) -> None:
    rect = menu["rect"]
    scale = pixel_scale(width, root)
    left = round((int(rect["x"]) - int(root["x"])) * scale)
    top = round((int(rect["y"]) - int(root["y"])) * scale)
    right = left + round(int(rect["width"]) * scale)
    bottom = top + round(int(rect["height"]) * scale)
    require(0 <= left < right <= width and 0 <= top < bottom <= height,
            f"{label} popup lies outside the screenshot")
    require_color(pixels, width, left + round(18 * scale),
                  top + round(18 * scale), (0xFF, 0xFF, 0xFF),
                  f"{label} panel")
    require(int(rect["width"]) >= 140 and int(rect["height"]) >= 40,
            f"{label} popup is too small: {rect['width']}x{rect['height']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default="build")
    args = parser.parse_args()
    out = ROOT / args.out_dir
    out.mkdir(parents=True, exist_ok=True)

    session = HostSession("samples/workbench.scene.json")
    try:
        session.wait_ready()
        status = session.send("status")
        require(status.get("ok") is True, f"status failed: {status}")

        nodes = [
            "workbench", "menubar", "file-menu", "edit-menu", "toolbar",
            "tb-save", "docs", "editor", "statusbar", "status-message",
        ]
        bounds = {
            node: session.send("getBounds", node=node)["rect"] for node in nodes
        }
        root = bounds["workbench"]
        require(int(bounds["menubar"]["height"]) == 30, "menu bar is not 30 px")
        require(int(bounds["toolbar"]["height"]) == 42, "toolbar is not 42 px")
        require(int(bounds["docs"]["height"]) == 34, "tab strip is not 34 px")
        require(int(bounds["statusbar"]["height"]) == 25,
                "status bar is not 25 px")
        require(int(bounds["editor"]["height"]) > 400,
                "editor does not own the work area")
        require(int(bounds["statusbar"]["y"]) >=
                int(bounds["editor"]["y"]) + int(bounds["editor"]["height"]),
                "status bar overlaps the editor")

        menu = open_menu(session, bounds, "file-menu")
        labels = [item["label"] for item in menu["items"] if not item["separator"]]
        require(labels[:2] == ["New", "Open..."] and "Save" in labels,
                f"unexpected File menu: {labels}")
        require("Recent Files" in labels, "File menu has no submenu")
        click_item(session, menu, "Save")
        require(action_count(session, "file-menu", "file.save") == 1,
                "Save did not emit its action")
        session.send("setText", node="status-message", text="Saved notes.txt")

        menu = open_menu(session, bounds, "edit-menu")
        wrap = menu_item(menu, "Word wrap")
        require(wrap["checked"] is True, "checked menu item lost its state")
        click_item(session, menu, "Word wrap")
        require(action_count(session, "edit-menu", "view.wrap") == 1,
                "Word wrap did not emit its action")

        menu = open_menu(session, bounds, "file-menu")
        recent = menu_item(menu, "Recent Files")
        session.send("uiMove", x=center(recent["rect"])[0],
                     y=center(recent["rect"])[1])
        child = session.send("menuState")["menu"]
        child_labels = [
            item["label"] for item in child["items"] if not item["separator"]
        ]
        require(child_labels == ["notes.txt", "config.json"],
                f"cascade submenu did not open: {child_labels}")
        menu_shot = out / "ui-depth-menu.ppm"
        session.send("screenshot", path=str(menu_shot))
        menu_width, menu_height, menu_pixels = read_ppm(menu_shot)
        verify_popup_pixels(menu_pixels, menu_width, menu_height, root, child,
                            "cascade")
        click_item(session, child, "notes.txt")
        require(action_count(session, "file-menu", "file.open.recent.notes") == 1,
                "submenu item did not emit its action")

        tabs = session.send("getTabs", node="docs")
        require(tabs["ok"] is True and tabs["count"] == 3, "initial tabs are wrong")
        require(tabs["tabs"][1]["active"] is True and
                tabs["tabs"][1]["dirty"] is True,
                "active/dirty tab state is wrong")
        first = tabs["tabs"][0]
        session.send("uiClick", x=center(first["rect"])[0],
                     y=center(first["rect"])[1])
        require(action_count(session, "docs", "doc.welcome") == 1,
                "tab click did not emit its document action")

        new_tabs = [
            {"label": "welcome.py", "action": "doc.welcome", "active": True},
            {"label": "notes.txt", "action": "doc.notes", "dirty": True},
            {"label": "config.json", "action": "doc.config"},
            {"label": "run.log", "action": "doc.run"},
        ]
        response = session.send("setTabs", node="docs", items=new_tabs)
        require(response.get("ok") is True and response["count"] == 4,
                "setTabs did not update the strip")
        tabs = session.send("getTabs", node="docs")
        require(tabs["count"] == 4 and tabs["tabs"][0]["active"] is True and
                tabs["tabs"][1]["dirty"] is True,
                "updated tab state is wrong")

        session.send("setChrome", node="tb-wrap", active=False)
        session.send("setChrome", node="tb-wrap", active=True)
        session.send("uiClick", x=center(bounds["tb-save"])[0],
                     y=center(bounds["tb-save"])[1])
        require(action_count(session, "tb-save", "file.save") == 1,
                "toolbar Save did not emit its action")

        editor_x, editor_y = center(bounds["editor"])
        session.send("uiClick", x=editor_x, y=editor_y, button="right")
        context = session.send("menuState")["menu"]
        context_labels = [
            item["label"] for item in context["items"] if not item["separator"]
        ]
        require(context_labels[:2] == ["Undo", "Redo"] and
                "Copy" in context_labels and "Find..." in context_labels,
                f"unexpected context menu: {context_labels}")
        context_shot = out / "ui-depth-context.ppm"
        session.send("screenshot", path=str(context_shot))
        burn = read_ppm(context_shot)
        verify_popup_pixels(burn[2], burn[0], burn[1], root, context, "context")
        click_item(session, context, "Copy")
        require(action_count(session, "editor", "edit.copy") == 1,
                "context menu Copy did not emit its action")

        tree = session.send("tree")
        status_node = next(node for node in tree["nodes"]
                           if node["id"] == "status-message")
        require(status_node["text"] == "Saved notes.txt",
                "status message did not update")

        shot = out / "ui-depth.ppm"
        session.send("screenshot", path=str(shot))
        width, height, pixels = read_ppm(shot)
        verify_layout(pixels, width, height, root, bounds)

        try:
            from PIL import Image
        except ImportError:
            pass
        else:
            for ppm in (shot, menu_shot, context_shot):
                Image.open(ppm).save(ppm.with_suffix(".png"))

        print(f"layout: menu={bounds['menubar']['height']} "
              f"toolbar={bounds['toolbar']['height']} "
              f"tabs={bounds['docs']['height']} "
              f"editor={bounds['editor']['height']} "
              f"status={bounds['statusbar']['height']}")
        print(f"actions: {sorted(set(action_events(session)))}")
        print(f"screenshots: {shot}, {menu_shot}, {context_shot}")
    finally:
        exit_code = session.close()

    require(exit_code == 0, f"host exited with {exit_code}")
    print("ui depth test passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ui depth test failed: {error}", file=sys.stderr)
        traceback.print_exc()
        raise SystemExit(1)
