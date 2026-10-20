"""Isolate interpreter compatibility hypotheses without editing production code.

Clones only the hinter module into ignored build output and compiles the real
font-quality fixture against each variant. These are diagnostics, not policies.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import warnings

from PIL import Image

warnings.simplefilter("ignore", DeprecationWarning)
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CORE = ROOT / "vendor/aurora-d-0.4.5"
BUILD = ROOT / "build-validation/native-text-progress/hint-variants"
spec = importlib.util.spec_from_file_location("comparison", ROOT / "scripts/compare-font-rendering.py")
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)


def main():
    source = (CORE / "source/aurora/text/hinter.d").read_text("utf-8")
    variants = {"control": source}
    # Microsoft's compatibility description retains vertical deltas on touched
    # points and suppresses horizontal/untouched outline dents in natural mode.
    delta = source.replace("movePoint(zone0Ref(), point, b);", """if (!naturalGrid || !glyphProgram ||
                    (freeVectorX == 0 && zone0Ref().points[point].touchY))
                    movePoint(zone0Ref(), point, b);""")
    marker = """if (point >= 0 && point < ctx.zone2Ref().points.length)
                    {
                        if (ctx.freeVectorX != 0)"""
    # Restrict this replacement to SHPIX, not SHP.
    left, right = delta.split("            case 0x38:", 1)
    right = right.replace(marker, """if (point >= 0 && point < ctx.zone2Ref().points.length)
                    {
                        if (ctx.naturalGrid && ctx.glyphProgram &&
                            (ctx.freeVectorX != 0 || !ctx.zone2Ref().points[point].touchY)) continue;
                        if (ctx.freeVectorX != 0)""", 1)
    variants["delta-compat"] = left + "            case 0x38:" + right
    for name in ("control", "delta-compat"):
        # Axis-isolation diagnostic: preserve original x only in the returned
        # outline while retaining all interpreter behavior that influences y.
        variants[name + "-raw-x"] = variants[name].replace(
            "result.xs26Dot6[i] = ctx.zone2.points[i].curX;",
            "result.xs26Dot6[i] = ctx.scaleDesign(input.xs[i]);")
    results = []
    for name, variant in variants.items():
        out = BUILD / name
        module = out / "source/aurora/text/hinter.d"
        module.parent.mkdir(parents=True, exist_ok=True)
        module.write_text(variant, encoding="utf-8")
        exe = out / "fixture.exe"
        subprocess.run(["dmd", "-i", "-O", "-version=AuroraHeadless",
                        "-I" + str(out / "source"), "-I" + str(CORE / "source"),
                        "-od=" + str(out), "-of=" + str(exe),
                        str(CORE / "tests/font_quality.d"), "user32.lib", "gdi32.lib"], check=True, cwd=ROOT)
        env = os.environ.copy()
        env.update(AURORA_HINTING="natural", AURORA_TEXT_COVERAGE="foreground", AURORA_TEXT_CONTRAST="0.5")
        for family, filename in (("segoe", "segoeui.ttf"), ("consolas", "consola.ttf"),
                                 ("arial", "arial.ttf"), ("tahoma", "tahoma.ttf"), ("times", "times.ttf")):
            native = ref.NativeReference("C:/Windows/Fonts/" + filename)
            try:
                for size in (11, 13, 18, 26):
                    prefix = out / f"{family}-{size}"
                    subprocess.run([str(exe), "C:/Windows/Fonts/" + filename, str(size), str(prefix),
                                    "Hamburgefontsiv 0123456789 = + - _ Il1 O0 | AV fi"], cwd=ROOT, env=env, check=True)
                    info = json.loads(prefix.with_suffix(".json").read_text("utf-8"))
                    for dark in (False, True):
                        theme = "dark" if dark else "light"
                        actual = Image.open(str(prefix) + f"-{theme}.ppm").convert("RGB")
                        target = native.render(info, dark)
                        target.save(str(prefix) + f"-{theme}-native.png")
                        error = ref.grayscale_error(actual, target, 24 if dark else 255)
                        results.append({"variant": name, "font": family, "size": size, "theme": theme,
                                        **error})
            finally:
                native.close()
        print(name, "mean error", sum(x["mean_absolute_error"] for x in results if x["variant"] == name) / 40,
              flush=True)
    (HERE / "hint-variants.json").write_text(json.dumps({"reference":
        "https://learn.microsoft.com/en-us/typography/cleartype/truetypecleartype", "comparisons": results}, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
