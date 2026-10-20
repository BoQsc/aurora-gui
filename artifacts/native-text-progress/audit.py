"""Fresh native comparisons for the approved baseline and repaired hinting.

Windows reference tools only; every case compiles into its own build directory.
"""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / "build-validation/native-text-progress/corpus"
FONTS = {"segoe": "segoeui.ttf", "consolas": "consola.ttf", "arial": "arial.ttf",
         "calibri": "calibri.ttf", "tahoma": "tahoma.ttf", "verdana": "verdana.ttf",
         "courier": "cour.ttf", "times": "times.ttf",
         "inter": str(ROOT / "vendor/aurora-d-0.4.5/tests/fonts/InterVariable.ttf")}


def capture(family, filename, hint):
    name = family + ("-natural" if hint == "natural" else "-baseline")
    out = BUILD / name
    env = os.environ.copy()
    env.update(AURORA_HINTING=hint, AURORA_TEXT_COVERAGE="foreground",
               AURORA_TEXT_CONTRAST="0.5", PYTHONWARNINGS="ignore::DeprecationWarning")
    command = [sys.executable, str(ROOT / "scripts/compare-font-rendering.py"),
               "--font", str(Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts" / filename),
               "--sizes", "11", "12", "13", "17", "18", "20", "26", "34", "--out", str(out)]
    result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True,
                            encoding="utf-8", errors="replace")
    out.mkdir(parents=True, exist_ok=True)
    (out / "run.txt").write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(name + "\n" + result.stdout + result.stderr)
    print(name, "completed", flush=True)
    return name, json.loads((out / "manifest.json").read_text("utf-8"))


def main():
    cases = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        futures = [pool.submit(capture, family, filename, hint)
                   for family, filename in FONTS.items() for hint in ("0", "natural")]
        for future in concurrent.futures.as_completed(futures):
            name, data = future.result()
            cases[name] = data
    comparisons = []
    for family in FONTS:
        a = cases[family + "-baseline"]["grayscale_comparison"]
        b = cases[family + "-natural"]["grayscale_comparison"]
        for current, candidate in zip(a, b):
            assert (current["size"], current["theme"]) == (candidate["size"], candidate["theme"])
            comparisons.append({"font": family, "size": current["size"], "theme": current["theme"],
                "baseline_error": current["mean_absolute_error"],
                "natural_error": candidate["mean_absolute_error"]})
    summary = {"baseline": "previous B: foreground coverage; hinting off",
               "candidate": "approved C shared default: same coverage; repaired natural hinting",
               "hinting_default_changed": True, "cases": cases, "comparisons": comparisons,
               "improved": sum(x["natural_error"] < x["baseline_error"] for x in comparisons),
               "equal": sum(x["natural_error"] == x["baseline_error"] for x in comparisons),
               "regressed": sum(x["natural_error"] > x["baseline_error"] for x in comparisons)}
    summary["source_sha256"] = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in (
        "vendor/aurora-d-0.4.5/source/aurora/text/hinter.d",
        "vendor/aurora-d-0.4.5/source/aurora/font.d",
        "vendor/aurora-d-0.4.5/source/aurora/text/truetype.d",
        "vendor/aurora-d-0.4.5/source/aurora/text/atlas.d",
        "vendor/aurora-d-0.4.5/source/aurora/text/coverage.d",
        "vendor/aurora-d-0.4.5/source/aurora/text/rasterizer.d",
        "vendor/aurora-d-0.4.5/source/aurora/canvas.d",
        "vendor/aurora-d-0.4.5/tests/font_quality.d",
        "scripts/compare-font-rendering.py")}
    (HERE / "measurements.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    font = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 13)
    panels = []
    for family in ("segoe", "consolas"):
        for theme in ("light", "dark"):
            images = [Image.open(BUILD / (family + suffix) / filename).convert("RGB") for suffix, filename in (
                ("-baseline", f"13-{theme}-aurora.png"), ("-natural", f"13-{theme}-aurora.png"),
                ("-natural", f"13-{theme}-native-gray.png"))]
            height = images[0].height + 7
            panel = Image.new("RGB", (images[0].width + 230, 30 + 3 * height), "#e5e7eb")
            draw = ImageDraw.Draw(panel)
            draw.text((8, 6), f"{family} / 13px / {theme} / actual pixels", font=font, fill="black")
            for i, (label, image) in enumerate(zip(("B: previous default", "C: repaired natural hinting", "Windows grayscale"), images)):
                y = 30 + i * height
                draw.text((8, y+5), label, font=font, fill="black")
                panel.paste(image, (210, y))
            panels.append(panel)
    sheet = Image.new("RGB", (max(p.width for p in panels), sum(p.height+8 for p in panels)), "#c9ced6")
    y = 0
    for panel in panels:
        sheet.paste(panel, (0, y)); y += panel.height+8
    sheet.save(HERE / "native-comparison.png")
    print("Improved / equal / regressed:", summary["improved"], summary["equal"], summary["regressed"])


if __name__ == "__main__":
    main()
