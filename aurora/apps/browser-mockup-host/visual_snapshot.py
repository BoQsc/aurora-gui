#!/usr/bin/env python3
"""Render host-scene previews without opening a window."""
from __future__ import annotations

import json
from pathlib import Path
import struct
import subprocess
import sys
import zlib

PROJECT = Path(__file__).resolve().parent
AURORA = PROJECT.parents[1]
HOST = AURORA / "aurora-host"
HEADLESS = HOST / "aurora-host-headless.exe"
SCENE = PROJECT / "scene.json"
OUT = PROJECT / "build"
sys.path.insert(0, str(PROJECT))
from controller import BrowserController, PAGE_TITLES  # noqa: E402

CHROME_HEIGHT = 156


def ppm_to_png(source: Path, target: Path) -> tuple[int, int]:
    data = source.read_bytes()
    magic, size, maxval, body = data.split(b"\n", 3)
    assert magic == b"P6" and maxval == b"255"
    width, height = map(int, size.split())
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw.extend(body[y * width * 3 : (y + 1) * width * 3])

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + kind + payload +
                struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    target.write_bytes(png)
    return width, height


def render(name: str, page: str, width: int, height: int,
           query: str = "", doc_section: int = 0,
           gallery_index: int = 0) -> tuple[int, int]:
    scene = json.loads(SCENE.read_text(encoding="utf-8"))
    scene["window"]["width"] = width
    scene["window"]["height"] = height
    controller = BrowserController(None)
    controller.tabs[0].history[0] = page
    controller.tabs[0].query = query
    controller.tabs[0].doc_section = doc_section
    controller.tabs[0].gallery_index = gallery_index
    url = controller.current_url()
    commands, _ = controller.build_page(page, width, height - CHROME_HEIGHT)

    def update_node(node: dict) -> None:
        node_id = node.get("id")
        if node_id == "tabs":
            node["items"] = [{
                "label": f"●  {PAGE_TITLES[page]}",
                "action": "tab.0",
                "active": True,
            }]
        elif node_id == "address":
            node["text"] = url
        elif node_id == "status":
            node["text"] = f"READY  /  {url}"
        elif node_id == "page":
            node["commands"] = commands
            node.pop("events", None)
            node.pop("tickHz", None)
        for child in node.get("children", []):
            update_node(child)

    update_node(scene["root"])
    scene_path = OUT / f"{name}.scene.json"
    ppm_path = OUT / f"{name}.ppm"
    png_path = PROJECT / f"{name}.png"
    scene_path.write_text(json.dumps(scene), encoding="utf-8")
    result = subprocess.run(
        [str(HEADLESS), "--render", str(scene_path), "--out", str(ppm_path)],
        cwd=str(HOST), capture_output=True, text=True, encoding="utf-8",
        timeout=120,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stdout + result.stderr)
    return ppm_to_png(ppm_path, png_path)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    if not HEADLESS.is_file():
        raise SystemExit(f"missing headless host: {HEADLESS}")
    start = render("preview", "start", 1100, 760)
    design = render("preview-design", "design", 1100, 760)
    docs = render("preview-docs", "docs", 1100, 760)
    gallery = render("preview-gallery", "gallery", 1100, 760,
                     gallery_index=3)
    search = render("preview-search", "search", 1100, 760,
                    query="unknown thing")
    large = render("preview-large", "start", 1400, 900)
    print(
        f"PASS headless previews start={start} design={design} docs={docs} "
        f"gallery={gallery} search={search} large={large}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL host-scene preview: {error}", file=sys.stderr)
        raise SystemExit(1)
