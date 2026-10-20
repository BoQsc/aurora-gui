"""Compare isolated interpreter hypotheses with approved C; never edit defaults.

Monitor and neutral DirectWrite references separate shape/sampling errors from
coverage transfer. Native rendering remains reference tooling only.
"""
import concurrent.futures
import hashlib
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
BUILD = ROOT / "build-validation/native-text-next"
BASELINE = HERE / "baseline-C"
FONTS = {"segoe": "C:/Windows/Fonts/segoeui.ttf", "consolas": "C:/Windows/Fonts/consola.ttf",
         "arial": "C:/Windows/Fonts/arial.ttf", "calibri": "C:/Windows/Fonts/calibri.ttf",
         "tahoma": "C:/Windows/Fonts/tahoma.ttf", "verdana": "C:/Windows/Fonts/verdana.ttf",
         "courier": "C:/Windows/Fonts/cour.ttf", "times": "C:/Windows/Fonts/times.ttf",
         "inter": str(CORE / "tests/fonts/InterVariable.ttf")}
SIZES = (11, 12, 13, 17, 18, 20, 26, 34)
TEXT = "Hamburgefontsiv 0123456789 = + - _ Il1 O0 | AV fi"
spec = importlib.util.spec_from_file_location("native_comparison", ROOT / "scripts/compare-font-rendering.py")
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)


def variants():
    source = (BASELINE / "hinter.d").read_text("utf-8")
    start = source.index("        long distance = cvtDist;", source.index("    void mirp("))
    end = source.index("        if ((opcode & 8)", start)
    mirp = source[:start] + """        // Compatibility hypothesis: honor CVT cut-in for unrounded MIRP.
        if (((opcode & 4) != 0 ||
             (naturalGrid && glyphProgram && (instructControl & 4) == 0)) &&
            zoneSelect0 == zoneSelect1)
        {
            delta = cvtDist - orgDist;
            if (delta < 0) delta = -delta;
            if (delta > effectiveCutIn()) cvtDist = orgDist;
        }
        long distance = (opcode & 4) != 0 ? roundDistance(cvtDist, 0) : roundNone(cvtDist, 0);

""" + source[end:]

    def msirp(text):
        begin = text.index("            case 0x3A: case 0x3B:")
        end = text.index("            case 0x49:", begin)
        block = text[begin:end].replace("const distance = cast(int) ctx.pop();", "long distance = cast(int) ctx.pop();")
        marker = "                const cur = ctx.project("
        insert = """                // Exploratory nontrivial-distance cutoff: half a physical pixel.
                if (ctx.naturalGrid && ctx.glyphProgram && (ctx.instructControl & 4) == 0 &&
                    ctx.zoneSelect0 == ctx.zoneSelect1)
                {
                    const original = ctx.dualProject2(zone.points[point].orgX, zone.points[point].orgY,
                        ctx.zone0Ref().points[ctx.rp0].orgX, ctx.zone0Ref().points[ctx.rp0].orgY);
                    const difference = distance >= original ? distance - original : original - distance;
                    if ((original >= 32 || original <= -32) && difference > ctx.effectiveCutIn())
                        distance = original;
                }
"""
        assert block.count(marker) == 1
        block = block.replace(marker, insert + marker)
        return text[:begin] + block + text[end:]

    return {"C": source, "mirp-cutin": mirp, "msirp-cutin": msirp(source), "both-cutin": msirp(mirp)}


def measure(name, source, truetype=None, rasterizer=None, experiment=None, current=False):
    out = BUILD / name
    module = out / "source/aurora/text/hinter.d"
    module.parent.mkdir(parents=True, exist_ok=True)
    module.write_text(source, encoding="utf-8")
    if not current:
        if truetype is None: truetype = (BASELINE / "truetype.d").read_text("utf-8")
        if rasterizer is None: rasterizer = (BASELINE / "rasterizer.d").read_text("utf-8")
    if truetype is not None:
        (module.parent / "truetype.d").write_text(truetype, encoding="utf-8")
    if rasterizer is not None:
        (module.parent / "rasterizer.d").write_text(rasterizer, encoding="utf-8")
    exe = out / "fixture.exe"
    subprocess.run(["dmd", "-i", "-O", "-version=AuroraHeadless", "-I" + str(out / "source"),
                    "-I" + str(CORE / "source"), "-od=" + str(out), "-of=" + str(exe),
                    str(CORE / "tests/font_quality.d"), "user32.lib", "gdi32.lib"], check=True, cwd=ROOT)
    env = os.environ.copy()
    env.pop("AURORA_TEXT_EXPERIMENT", None)
    if experiment:
        env["AURORA_TEXT_EXPERIMENT"] = experiment
    env.update(AURORA_HINTING="natural", AURORA_TEXT_COVERAGE="foreground")
    records = []
    for family, path in FONTS.items():
        native = ref.NativeReference(path)
        try:
            for size in SIZES:
                prefix = out / f"{family}-{size}"
                env["AURORA_TEXT_CONTRAST"] = "0.5"
                subprocess.run([str(exe), path, str(size), str(prefix), TEXT], env=env, check=True, cwd=ROOT)
                info = json.loads(prefix.with_suffix(".json").read_text("utf-8"))
                for dark in (False, True):
                    theme = "dark" if dark else "light"
                    image = Image.open(str(prefix) + f"-{theme}.ppm").convert("RGB")
                    target = native.render(info, dark)
                    target.save(str(prefix) + f"-{theme}-native.png")
                    image.save(str(prefix) + f"-{theme}-aurora.png")
                    record = {"font": family, "size": size, "theme": theme,
                              "monitor_error": ref.grayscale_error(image, target, 24 if dark else 255)["mean_absolute_error"]}
                    records.append(record)
                env["AURORA_TEXT_CONTRAST"] = "0"
                raw = out / f"{family}-{size}-raw"
                subprocess.run([str(exe), path, str(size), str(raw), TEXT], env=env, check=True, cwd=ROOT)
                for dark, record in zip((False, True), records[-2:]):
                    theme = record["theme"]
                    image = Image.open(str(raw) + f"-{theme}.ppm").convert("RGB")
                    target = native.render(info, dark, neutral=True)
                    target.save(str(prefix) + f"-{theme}-neutral.png")
                    image.save(str(prefix) + f"-{theme}-raw.png")
                    record["neutral_error"] = ref.grayscale_error(image, target, 24 if dark else 255)["mean_absolute_error"]
                    record["neutral_exact"] = image.tobytes() == target.tobytes()
        finally:
            native.close()
    print(name, "monitor", sum(r["monitor_error"] for r in records) / len(records),
          "neutral", sum(r["neutral_error"] for r in records) / len(records), flush=True)
    return name, records


def main():
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        futures = [pool.submit(measure, name, source) for name, source in variants().items()]
        for future in concurrent.futures.as_completed(futures):
            name, records = future.result()
            results[name] = records
    baseline = results["C"]
    summary = {}
    for name, records in results.items():
        summary[name] = {"improved": sum(r["monitor_error"] < b["monitor_error"] for r, b in zip(records, baseline)),
                         "regressed": sum(r["monitor_error"] > b["monitor_error"] for r, b in zip(records, baseline)),
                         "equal": sum(r["monitor_error"] == b["monitor_error"] for r, b in zip(records, baseline)),
                         "monitor_mean": sum(r["monitor_error"] for r in records) / len(records),
                         "neutral_mean": sum(r["neutral_error"] for r in records) / len(records),
                         "neutral_exact": sum(r["neutral_exact"] for r in records)}
    data = {"baseline": "owner-approved C", "default_changed": False,
            "reference": "https://learn.microsoft.com/en-us/typography/cleartype/truetypecleartype",
            "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in BASELINE.glob("*.d")},
            "summary": summary, "comparisons": results}
    (HERE / "cutin-experiments.json").write_text(json.dumps(data, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
