"""Compare phase-dependent ink against native neutral rendering directly."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import warnings

from PIL import Image, ImageDraw

warnings.simplefilter("ignore", DeprecationWarning)
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CORE = ROOT / "vendor/aurora-d-0.4.5"
BUILD = ROOT / "build-validation/native-text-progress/native-phases"
BUILD.mkdir(parents=True, exist_ok=True)
source = BUILD / "probe.d"
source.write_text('''module probe;
import aurora.font : FontFace;
import std.json : JSONValue;
import std.conv : to;
import std.file : write;
int main(string[] args) {
    auto face = FontFace.load(args[1]);
    const size = args[2].to!int;
    const ch = args[3].to!dstring[0];
    JSONValue[] phases;
    foreach (phase; 0 .. 8) {
        auto glyph = face.rasterizeGlyph(face.glyphIndex(ch), size, 8, phase / 8.0);
        JSONValue info;
        info["id"] = glyph.glyphIndex;
        info["width"] = glyph.width; info["height"] = glyph.height;
        info["bearing_x"] = glyph.bearingX; info["bearing_y"] = glyph.bearingY;
        info["alpha"] = JSONValue(glyph.alpha);
        phases ~= info;
    }
    write(args[4], JSONValue(phases).toPrettyString());
    return 0;
}
''', encoding="utf-8")
exe = BUILD / "probe.exe"
subprocess.run(["dmd", "-i", "-O", "-version=AuroraHeadless", "-I" + str(CORE / "source"),
                "-od=" + str(BUILD), "-of=" + str(exe), str(source), "user32.lib", "gdi32.lib"], check=True)
spec = importlib.util.spec_from_file_location("comparison", ROOT / "scripts/compare-font-rendering.py")
ref = importlib.util.module_from_spec(spec); spec.loader.exec_module(ref)
env = os.environ.copy(); env["AURORA_HINTING"] = "natural"
records = []
font = CORE / "tests/fonts/InterVariable.ttf"
native = ref.NativeReference(font)
try:
    for ch in ("l", "H", "o"):
        for size in (13, 17, 21, 26, 34):
            out = BUILD / f"{ord(ch)}-{size}.json"
            subprocess.run([str(exe), str(font), str(size), ch, str(out)], env=env, check=True)
            phases = json.loads(out.read_text("utf-8"))
            images = []
            for phase, glyph in enumerate(phases):
                actual = Image.new("L", (80, 80))
                for y in range(glyph["height"]):
                    for x in range(glyph["width"]):
                        actual.putpixel((8 + glyph["bearing_x"] + x, 60 - glyph["bearing_y"] + y),
                                        glyph["alpha"][y*glyph["width"]+x])
                info = {"width": 80, "height": 80, "pixel_size": size,
                        "glyphs": [{"id": glyph["id"], "x": 8+phase/8, "y": 60}]}
                target = native.render(info, neutral=True, foreground=(255,)*3, background=(0,)*3).convert("L")
                row = {"character": ch, "size": size, "phase": phase,
                       "aurora_ink": sum(actual.getdata()), "native_ink": sum(target.getdata()),
                       "native_equal": actual.tobytes() == target.tobytes()}
                records.append(row)
                images.append((actual, target))
            sheet = Image.new("RGB", (640, 160), "#dddddd")
            draw = ImageDraw.Draw(sheet)
            for phase, (actual, target) in enumerate(images):
                sheet.paste(actual, (phase*80, 0)); sheet.paste(target, (phase*80, 80))
            sheet.save(BUILD / f"{ord(ch)}-{size}.png")
            print(ch, size, [(r["phase"], r["aurora_ink"], r["native_ink"], r["native_equal"])
                            for r in records if r["character"] == ch and r["size"] == size], flush=True)
finally:
    native.close()
(HERE / "native-phases.json").write_text(json.dumps(records, indent=2), encoding="utf-8")
