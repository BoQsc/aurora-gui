"""Expose native size-program state through generated glyphs in private font copies."""
import json,subprocess,os
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image,ImageChops
import audit


def main():
 exe=audit.BUILD/'diagnostic/sheet.exe';out=audit.BUILD/'state-probe';out.mkdir(exist_ok=True);rows=[]
 for family in ['arial','tahoma','courier','times']:
  for size in [12,17]:
   for slot in [2,18,19,22,24]:
    ft=TTFont(audit.diagnose.FONTS[family]);name=ft.getBestCmap()[ord('A')];pen=TTGlyphPen(None);pen.moveTo((0,0));pen.lineTo((0,1024));pen.lineTo((1024,1024));pen.lineTo((1024,0));pen.closePath();g=pen.glyph()
    code=['SVTCA[1]']
    for point in [2,3]:code+=['PUSHB[ ]',point,slot,'RS[ ]','ABS[ ]','PUSHW[ ]',4096,'MUL[ ]','SCFS[ ]']
    p=Program();p.fromAssembly([str(c) for c in code]);g.program=p;ft['glyf'][name]=g;ft['hmtx'].metrics[name]=(2048,0);font=out/f'{family}-{size}-slot{slot}.ttf';ft.save(font)
    env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0',AURORA_TEST_CHARACTER='A');prefix=out/'sheet'
    subprocess.run([str(exe),str(font),str(size),str(prefix)],env=env,check=True,capture_output=True);info=json.loads(prefix.with_suffix('.json').read_text());a=ImageChops.invert(Image.open(prefix.with_suffix('.ppm')).convert('L'));ref=audit.diagnose.ref.NativeReference(font)
    try:n=ImageChops.invert(ref.render(info,neutral=True).convert('L'))
    finally:ref.close()
    row={'font':family,'size':size,'slot':slot,'aurora_ink':sum(a.get_flattened_data()),'native_ink':sum(n.get_flattened_data()),'aurora_bounds':a.getbbox(),'native_bounds':n.getbbox()};rows.append(row)
 (audit.HERE/'state-probe.json').write_text(json.dumps(rows,indent=2));print(json.dumps([r for r in rows if r['aurora_bounds']!=r['native_bounds'] or r['slot']==2],indent=2))

if __name__=='__main__':main()
