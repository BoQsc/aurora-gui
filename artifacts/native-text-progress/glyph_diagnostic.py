"""Isolate the remaining Calibri/Tahoma differences one glyph at a time."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import warnings

from PIL import Image

warnings.simplefilter("ignore", DeprecationWarning)
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / "build-validation/native-text-progress/glyph-diagnostic"
spec = importlib.util.spec_from_file_location("comparison", ROOT / "scripts/compare-font-rendering.py")
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)
BUILD.mkdir(parents=True, exist_ok=True)
records = []
for family, filename, size in (("calibri", "calibri.ttf", 20), ("tahoma", "tahoma.ttf", 18)):
    native = ref.NativeReference("C:/Windows/Fonts/" + filename)
    exe = ROOT / f"build-validation/native-text-progress/corpus/{family}-natural/font-quality.exe"
    try:
        for ch in sorted(set("Hamburgefontsiv0123456789=+-_IlO|AV")):
            entry = {"font": family, "size": size, "character": ch}
            for mode, hint, contrast, neutral in (("baseline", "0", "0.5", False),
                ("natural", "natural", "0.5", False), ("neutral", "natural", "0", True)):
                prefix = BUILD / f"{family}-{ord(ch)}-{mode}"
                env = os.environ.copy()
                env.update(AURORA_HINTING=hint, AURORA_TEXT_COVERAGE="foreground", AURORA_TEXT_CONTRAST=contrast)
                subprocess.run([str(exe), "C:/Windows/Fonts/" + filename, str(size), str(prefix), ch],
                               cwd=ROOT, env=env, check=True)
                info = json.loads(prefix.with_suffix(".json").read_text("utf-8"))
                actual = Image.open(str(prefix) + "-light.ppm").convert("RGB")
                target = native.render(info, neutral=neutral)
                target.save(str(prefix) + "-native.png")
                entry[mode] = ref.grayscale_error(actual, target, 255)
                entry[mode]["actual_ink"] = sum(255-v for v in actual.convert("L").getdata())
                entry[mode]["native_ink"] = sum(255-v for v in target.convert("L").getdata())
            records.append(entry)
    finally:
        native.close()
for family in ("calibri", "tahoma"):
    ordered = sorted((r for r in records if r["font"] == family),
                     key=lambda r: r["natural"]["mean_absolute_error"]-r["baseline"]["mean_absolute_error"], reverse=True)
    print(family, [(r["character"], round(r["baseline"]["mean_absolute_error"], 2),
                    round(r["natural"]["mean_absolute_error"], 2), round(r["neutral"]["mean_absolute_error"], 2))
                   for r in ordered[:10]], flush=True)
(HERE / "glyph-diagnostic.json").write_text(json.dumps(records, indent=2), encoding="utf-8")
