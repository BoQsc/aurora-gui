"""Test whether the natural sampling lattice supports every public atlas phase."""
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
CORE = ROOT / "vendor/aurora-d-0.4.5"
BUILD = ROOT / "build-validation/native-text-progress/sampling-variants"
spec = importlib.util.spec_from_file_location("comparison", ROOT / "scripts/compare-font-rendering.py")
ref = importlib.util.module_from_spec(spec); spec.loader.exec_module(ref)
env = os.environ.copy()
env.update(AURORA_HINTING="natural", AURORA_TEXT_COVERAGE="foreground", AURORA_TEXT_CONTRAST="0.5")
source = (CORE / "source/aurora/text/truetype.d").read_text("utf-8")
module = BUILD / "source/aurora/text/truetype.d"
module.parent.mkdir(parents=True, exist_ok=True)
module.write_text(source.replace("pixelSize < 20 ? 8 : 4, pixelSize < 20 ? 1 : 4",
                                 "8, pixelSize < 20 ? 1 : 4"), encoding="utf-8")
records = []
for name, fixture in (("capture", "font_quality.d"), ("regression", "font_quality_regression.d")):
    command = ["dmd", "-i", "-O", "-version=AuroraHeadless", "-I" + str(BUILD / "source"),
               "-I" + str(CORE / "source"), "-od=" + str(BUILD), "-of=" + str(BUILD / (name + ".exe")),
               str(CORE / "tests" / fixture), "user32.lib", "gdi32.lib"]
    subprocess.run(command, cwd=ROOT, check=True)
result = subprocess.run([str(BUILD / "regression.exe"), str(CORE / "tests/fonts/InterVariable.ttf")],
                        cwd=ROOT, env=env, capture_output=True, text=True)
print("8-sample regression exit:", result.returncode, result.stdout, result.stderr, flush=True)
for family, filename in (("segoe", "segoeui.ttf"), ("consolas", "consola.ttf"), ("arial", "arial.ttf"),
                         ("calibri", "calibri.ttf"), ("tahoma", "tahoma.ttf"), ("verdana", "verdana.ttf"),
                         ("courier", "cour.ttf"), ("times", "times.ttf")):
    native = ref.NativeReference("C:/Windows/Fonts/" + filename)
    try:
        for size in (11, 12, 13, 17, 18, 20, 26, 34):
            prefix = BUILD / f"{family}-{size}"
            subprocess.run([str(BUILD / "capture.exe"), "C:/Windows/Fonts/" + filename,
                            str(size), str(prefix), "Hamburgefontsiv 0123456789 = + - _ Il1 O0 | AV fi"],
                           cwd=ROOT, env=env, check=True)
            info = json.loads(prefix.with_suffix(".json").read_text("utf-8"))
            for dark in (False, True):
                theme = "dark" if dark else "light"
                actual = Image.open(str(prefix) + f"-{theme}.ppm").convert("RGB")
                target = native.render(info, dark)
                records.append({"font": family, "size": size, "theme": theme,
                                **ref.grayscale_error(actual, target, 24 if dark else 255)})
    finally:
        native.close()
current = json.loads((HERE / "measurements.json").read_text("utf-8"))["comparisons"]
before = {(r["font"], r["size"], r["theme"]): r["natural_error"] for r in current}
delta = [r["mean_absolute_error"] - before[(r["font"], r["size"], r["theme"])] for r in records]
summary = {"horizontal_samples": 8, "phase_regression_exit": result.returncode,
           "phase_regression_output": result.stdout + result.stderr, "comparisons": records,
           "vs_current_natural": {"improved": sum(d < 0 for d in delta), "equal": sum(d == 0 for d in delta),
                                  "regressed": sum(d > 0 for d in delta)}}
(HERE / "sampling-variants.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
print(summary["vs_current_natural"], flush=True)
