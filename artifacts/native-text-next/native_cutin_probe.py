"""Generated-font native probes for unrounded MIRP/MSIRP CVT compatibility.

Move the two corners of a rectangle to a requested distance. Native ink bounds
then expose whether the interpreter kept the request or restored the outline.
No fonts are installed and no system settings are changed.
"""
from array import array
import json
import os
import subprocess

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image, ImageChops

from diagnose import BUILD, HERE, ref


def font(path, original, requested, axis, opcode, native):
    # At 16px, two design units correspond to one F26Dot6 unit.
    width, height = (original * 2, 1024) if axis == "x" else (1024, original * 2)
    pen=TTGlyphPen(None)
    pen.moveTo((0,0));pen.lineTo((0,height));pen.lineTo((width,height));pen.lineTo((width,0));pen.closePath()
    glyph=pen.glyph()
    code=[0x01 if axis=="x" else 0x00,0xB0,0,0x10]
    if native:code += [0xB1,4,3,0x8E]
    for point in ((2,3) if axis=="x" else (1,2)):
        if opcode=="mirp":code += [0xB1,point,0,0xE0]
        else:code += [0xB0,point,0xB8,(requested>>8)&255,requested&255,0x3A]
    glyph.program=Program();glyph.program.fromBytecode(code)
    fb=FontBuilder(2048,isTTF=True);fb.setupGlyphOrder([".notdef","probe"]);fb.setupCharacterMap({65:"probe"})
    fb.setupGlyf({".notdef":TTGlyphPen(None).glyph(),"probe":glyph})
    fb.setupHorizontalMetrics({".notdef":(2048,0),"probe":(2048,0)})
    fb.setupHorizontalHeader(ascent=2048,descent=0);fb.setupNameTable({"familyName":"Aurora cut-in diagnostic","styleName":"Regular"})
    fb.setupOS2(sTypoAscender=2048,sTypoDescender=0,usWinAscent=2048,usWinDescent=0)
    fb.setupPost();fb.setupMaxp();fb.font["maxp"].maxZones=2;fb.font["maxp"].maxStackElements=128
    cvt=newTable("cvt ");cvt.values=array("h",[requested*2]);fb.font["cvt "]=cvt
    gasp=newTable("gasp");gasp.version=1;gasp.gaspRange={65535:15};fb.font["gasp"]=gasp
    fb.save(path)


def main():
    out=BUILD/"cutin-probe";out.mkdir(exist_ok=True)
    env=os.environ.copy();env.update(AURORA_HINTING="natural",AURORA_TEXT_CONTRAST="0")
    rows=[]
    for opcode in ("mirp","msirp"):
        for axis in ("x","y"):
            for original in (0,4,8,16,31,32,64,96,192):
                for native in (False,True):
                    requested=original+64
                    path=out/f"{opcode}-{axis}-{original}-{native}.ttf"
                    font(path,original,requested,axis,opcode,native)
                    reference=ref.NativeReference(path)
                    try:
                        info={"width":40,"height":40,"pixel_size":16,"glyphs":[{"id":1,"x":8,"y":32}]}
                        target=reference.render(info,neutral=True,foreground=(255,)*3,background=(0,)*3).convert("L")
                        row={"opcode":opcode,"axis":axis,"original_26dot6":original,"requested_26dot6":requested,
                             "native_instruction_opt_out":native,"native_ink":sum(target.get_flattened_data()),"native_bounds":target.getbbox()}
                        for variant in ("C","mirp-cutin","msirp-cutin","mirp-x"):
                            exe=BUILD/variant/"fixture.exe"
                            if not exe.exists():continue
                            prefix=out/(path.stem+"-"+variant)
                            subprocess.run([str(exe),str(path),"16",str(prefix),"A"],env=env,check=True,capture_output=True)
                            layout=json.loads(prefix.with_suffix(".json").read_text())
                            actual=ImageChops.invert(Image.open(str(prefix)+"-light.ppm").convert("L"))
                            # Compare using the fixture's actual baseline, not the diagnostic's fixed 32px baseline.
                            matching=reference.render(layout,neutral=True,foreground=(255,)*3,background=(0,)*3).convert("L")
                            row[variant]={"ink":sum(actual.get_flattened_data()),"native_equal":actual.tobytes()==matching.tobytes()}
                        rows.append(row)
                    finally:reference.close()
    (HERE/"native-cutin-probe.json").write_text(json.dumps(rows,indent=2),encoding="utf-8")
    for opcode in ("mirp","msirp"):
        for axis in ("x","y"):
            selected=[r for r in rows if r["opcode"]==opcode and r["axis"]==axis and not r["native_instruction_opt_out"]]
            print(opcode,axis,[(r["original_26dot6"],r["native_ink"],r["C"]["ink"],r[opcode+"-cutin"]["ink"]) for r in selected])


if __name__=="__main__":main()
