"""Probe native GETINFO branches with generated test fonts, never OS font edits.

Each diagnostic glyph shifts one pixel vertically only when a queried bit is
set. The comparison tooling renders its actual Windows glyph instructions.
"""
import importlib.util
import json
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables.ttProgram import Program

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / "build-validation/native-text-progress/getinfo"
BUILD.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location("comparison", ROOT / "scripts/compare-font-rendering.py")
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)


def font(path, selector, mask, gasp):
    pen = TTGlyphPen(None)
    pen.moveTo((0, 0)); pen.lineTo((0, 2048)); pen.lineTo((1024, 2048)); pen.lineTo((1024, 0)); pen.closePath()
    glyph = pen.glyph()
    code = [0x00, 0xB1, 4, 3, 0x8E]  # Native ClearType behavior; y vectors.
    for point in range(4):
        code += [0xB0, point, 0x2E]  # Touch vertical points without movement.
    code += [0xB8, selector >> 8, selector & 255, 0x88]
    # Build a 32-bit mask by multiplying a 16-bit input if needed.
    if mask <= 32767:
        code += [0xB8, mask >> 8, mask & 255]
    else:
        code += [0xB0, 1]
        for _ in range(mask.bit_length() - 1):
            code += [0x20, 0x60]  # DUP ADD doubles an integer without F26Dot6 MUL scaling.
    # DIV returns a 26.6 quotient; FLOOR + ODD tests the chosen result bit.
    code += [0x62, 0x66, 0x56, 0x58, 0xB0, 4, 0x17, 0xB4, 0, 1, 2, 3, 64, 0x38, 0x59]
    glyph.program = Program(); glyph.program.fromBytecode(code)
    fb = FontBuilder(2048, isTTF=True)
    fb.setupGlyphOrder([".notdef", "probe"])
    fb.setupCharacterMap({65: "probe"})
    fb.setupGlyf({".notdef": TTGlyphPen(None).glyph(), "probe": glyph})
    fb.setupHorizontalMetrics({".notdef": (2048, 0), "probe": (2048, 0)})
    fb.setupHorizontalHeader(ascent=2048, descent=0)
    fb.setupNameTable({"familyName": "Aurora native diagnostic", "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=2048, sTypoDescender=0, usWinAscent=2048, usWinDescent=0)
    fb.setupPost(); fb.setupMaxp()
    fb.font["maxp"].maxZones = 2
    fb.font["maxp"].maxStackElements = 128
    fb.font["maxp"].maxStorage = 1
    if gasp is not None:
        table = newTable("gasp"); table.version = 0 if gasp < 4 else 1
        table.gaspRange = {65535: gasp}; fb.font["gasp"] = table
    fb.save(path)


results = []
for gasp in (None, 3, 7, 15):
    for selector, bit in ((1, 0), (32, 12), (64, 13), (128, 14), (256, 15),
                          (1024, 17), (2048, 18), (4096, 19)):
        filename = BUILD / f"gasp{gasp}-s{selector}.ttf"
        font(filename, selector, 1 << bit, gasp)
        native = ref.NativeReference(filename)
        try:
            for size in (13, 20):
                info = {"width": 50, "height": 50, "pixel_size": size, "glyphs": [{"id": 1, "x": 8, "y": 32}]}
                image = native.render(info, neutral=True, foreground=(255,)*3, background=(0,)*3)
                bounds = image.getbbox()
                results.append({"gasp": gasp, "size": size, "selector": selector, "result_bit": bit,
                                "bounds": bounds, "bit_set": bounds[1] == 31-size})
                image.save(BUILD / f"gasp{gasp}-s{selector}-{size}.png")
        finally:
            native.close()
(HERE / "native-getinfo.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
for gasp in (None, 3, 7, 15):
    for size in (13, 20):
        print("gasp", gasp, "size", size, [(r["result_bit"], r["bit_set"], r["bounds"][1])
              for r in results if r["gasp"] == gasp and r["size"] == size])
