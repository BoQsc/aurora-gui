"""Reproduce the Windows text audit without changing any rendering defaults.

Run from any directory with DMD, Python and Pillow installed. All compiler and
per-case outputs go under build-validation; summary images/JSON stay beside
this script. A failed experimental case is recorded, never silently skipped.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / "build-validation" / HERE.name
SIZES = [11, 12, 13, 17, 20, 26]
CASES = [
    ("framework", "segoeui", "0.5", "0", "sharp"),
    ("host", "segoeui", "0.75", "0", "sharp"),
    ("linear", "segoeui", "0", "0", "sharp"),
    ("quarter", "segoeui", "0.25", "0", "sharp"),
    ("smooth", "segoeui", "0.5", "0", "smooth"),
    ("natural", "segoeui", "0.5", "natural", "sharp"),
    ("consolas-framework", "consola", "0.5", "0", "sharp"),
    ("consolas-host", "consola", "0.75", "0", "sharp"),
    ("consolas-natural", "consola", "0.5", "natural", "sharp"),
]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def environment(contrast, hint):
    env = os.environ.copy()
    for key in ("AURORA_FONT_RENDER_MODE", "AURORA_FONT", "AURORA_UI_FONT",
                "AURORA_UI_BOLD_FONT", "AURORA_MONOSPACE_FONT"):
        env.pop(key, None)
    env.update(AURORA_TEXT_CONTRAST=contrast, AURORA_HINTING=hint,
               PYTHONWARNINGS="ignore::DeprecationWarning")
    return env


def run(command, env=None):
    return subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                          text=True, encoding="utf-8", errors="replace")


def comparison(theme, completed):
    # Only complete captures enter the montage. The failing experimental
    # Consolas case remains visible in summary.json and its own failure file.
    label_font = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 13)
    panels = []
    for family, modes in [
        ("Segoe UI", ["host", "framework", "linear", "quarter", "smooth", "natural"]),
        ("Consolas", ["consolas-host", "consolas-framework"]),
    ]:
        modes = [name for name in modes if name in completed]
        base = "framework" if family == "Segoe UI" else "consolas-framework"
        for size in (11, 13, 17, 26):
            names = modes + ["Windows grayscale"]
            images = [Image.open(BUILD / name / f"{size}-{theme}-aurora.png").convert("RGB")
                      for name in modes]
            images.append(Image.open(BUILD / base / f"{size}-{theme}-native-gray.png").convert("RGB"))
            row_height = images[0].height + 6
            panel = Image.new("RGB", (images[0].width + 260,
                                      30 + len(images) * row_height), "#e4e7eb")
            draw = ImageDraw.Draw(panel)
            draw.text((8, 6), f"{family} / {size} physical px / {theme} / actual pixels",
                      font=label_font, fill="black")
            for index, (name, img) in enumerate(zip(names, images)):
                y = 30 + index * row_height
                draw.text((8, y + 4), name, font=label_font, fill="black")
                panel.paste(img, (230, y))
            panels.append(panel)
    image = Image.new("RGB", (max(p.width for p in panels),
                              sum(p.height + 10 for p in panels)), "#c9ced6")
    y = 0
    for panel in panels:
        image.paste(panel, (0, y))
        y += panel.height + 10
    image.save(HERE / f"comparison-{theme}.png")
    if theme == "light":
        selected = [panels[1], panels[5]]
        detail = Image.new("RGB", (max(p.width for p in selected),
                                   sum(p.height + 10 for p in selected)), "#c9ced6")
        y = 0
        for panel in selected:
            detail.paste(panel, (0, y))
            y += panel.height + 10
        detail.save(HERE / "comparison-13px-light.png")


def host_snapshots():
    out = BUILD / "host-snapshots"
    out.mkdir(exist_ok=True)
    exe = out / "host.exe"
    command = ["dmd", "-i", "-O", "-version=AuroraHeadless",
               *["-I" + str(ROOT / p) for p in ["vendor/aurora-d-0.4.5/source",
                  "vendor/aurora-standard/source", "experiments/aurora-host/source",
                  "experiments/aurora-host/generated"]],
               "-of=" + str(exe), "-od=" + str(out),
               str(ROOT / "experiments/aurora-host/source/experiment/aurorahost/main.d"),
               "user32.lib", "gdi32.lib"]
    result = run(command)
    (out / "build.txt").write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError("Host build failed; see " + str(out / "build.txt"))
    records = []
    for name, contrast in [("current-host", "0.75"), ("framework-default", "0.5"),
                           ("linear-diagnostic", "0")]:
        ppm = out / f"{name}.ppm"
        result = run([str(exe), "--render",
                      str(ROOT / "experiments/aurora-host-notepadpp/padpp.scene.json"),
                      "--out", str(ppm)], environment(contrast, "0"))
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        png = HERE / f"padpp-{name}.png"
        with Image.open(ppm) as source:
            source.save(png)
        records.append({"file": png.name, "sha256": digest(png),
                        "contrast": contrast, "renderer": "headless software",
                        "dpi": 96})
    return records


def main():
    if os.name != "nt":
        raise SystemExit("The reference renderer requires Windows.")
    BUILD.mkdir(parents=True, exist_ok=True)
    summary = {"date": "2026-10-20", "sizes": SIZES, "cases": [],
               "decision": "audit only; no shared default selected or changed",
               "metric": "grayscale MAE on union of ink pixels; not a readability score"}
    for name, family, contrast, hint, mode in CASES:
        font = Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts" / (family + ".ttf")
        command = [sys.executable, str(ROOT / "scripts/compare-font-rendering.py"),
                   "--font", str(font), "--mode", mode, "--sizes", *map(str, SIZES),
                   "--out", str(BUILD / name)]
        result = run(command, environment(contrast, hint))
        record = {"name": name, "contrast": contrast, "hinting": hint, "mode": mode,
                  "exit_code": result.returncode, "font": str(font),
                  "font_sha256": digest(font)}
        (BUILD / name / "run.txt").write_text(result.stdout + result.stderr, encoding="utf-8")
        if result.returncode == 0:
            record["measurements"] = json.loads((BUILD / name / "manifest.json").read_text("utf-8"))
        else:
            record["error"] = result.stdout + result.stderr
            (HERE / (name + "-failure.txt")).write_text(record["error"], encoding="utf-8")
        summary["cases"].append(record)
        print(name, "completed" if result.returncode == 0 else "FAILED (recorded)", flush=True)
    failed_required = [c["name"] for c in summary["cases"]
                       if c["exit_code"] and c["hinting"] == "0"]
    if not failed_required:
        completed = {c["name"] for c in summary["cases"] if c["exit_code"] == 0}
        comparison("light", completed)
        comparison("dark", completed)
        summary["host_snapshots"] = host_snapshots()
        alpha = BUILD / "shared-alpha"
        result = run([sys.executable, str(ROOT / "scripts/compare-font-rendering.py"),
                      "--audit-shared-alpha", "--audit-neutral", "--text", "H",
                      "--sizes", "13", "26", "--out", str(alpha)], environment("0.5", "0"))
        (alpha / "run.txt").write_text(result.stdout + result.stderr, encoding="utf-8")
        if result.returncode:
            raise RuntimeError("Shared-alpha audit failed; see " + str(alpha / "run.txt"))
        summary["shared_alpha"] = json.loads((alpha / "manifest.json").read_text("utf-8"))
    summary["source_sha256"] = {p: digest(ROOT / p) for p in [
        "vendor/aurora-d-0.4.5/source/aurora/text/atlas.d",
        "vendor/aurora-d-0.4.5/source/aurora/text/hinter.d",
        "vendor/aurora-d-0.4.5/source/aurora/canvas.d",
        "scripts/compare-font-rendering.py",
        "experiments/aurora-host/source/experiment/aurorahost/main.d",
        "experiments/aurora-host-notepadpp/padpp.scene.json"]}
    (HERE / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return 1 if failed_required else 0


if __name__ == "__main__":
    raise SystemExit(main())
