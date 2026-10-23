"""Character-level audit; whole-line MAE is insufficient to establish quality."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
CORE=ROOT/'vendor/aurora-d-0.4.5'
BUILD=ROOT/'build-validation/native-text-audit'
sys.path.insert(0,str(HERE.parent/'native-text-next'))
import diagnose


def compile(name,modules=None):
    out=BUILD/name;out.mkdir(parents=True,exist_ok=True)
    if modules:
        dest=out/'source/aurora/text';dest.mkdir(parents=True,exist_ok=True)
        for module,source in modules.items():(dest/(module+'.d')).write_text(source)
    exe=out/'sheet.exe'
    subprocess.run(['dmd','-i','-O','-version=AuroraHeadless','-I'+str(out/'source'),
        '-I'+str(CORE/'source'),'-od='+str(out),'-of='+str(exe),str(HERE/'glyph_sheet.d'),
        'user32.lib','gdi32.lib'],check=True)
    return exe


def measure(name,exe,experiment='native-refined',hinting='natural',families=None,sizes=None):
    env=os.environ.copy()
    env.update(AURORA_HINTING=hinting,AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0.5')
    env.pop('AURORA_TEXT_GAMMA',None)
    env.pop('AURORA_TEXT_EXPERIMENT',None)
    env.pop('AURORA_TEST_DARK',None)
    env.pop('AURORA_TEST_PHASE',None)
    if experiment:env['AURORA_TEXT_EXPERIMENT']=experiment
    out=BUILD/name;out.mkdir(parents=True,exist_ok=True)
    rows=[]
    for family in (families or ['segoe','consolas','courier']):
        font=diagnose.FONTS[family]
        native=diagnose.ref.NativeReference(font)
        try:
            for size in (sizes or [13,17,26]):
                prefix=out/f'{family}-{size}'
                subprocess.run([str(exe),font,str(size),str(prefix)],check=True,env=env,capture_output=True)
                info=json.loads(prefix.with_suffix('.json').read_text())
                actual=Image.open(prefix.with_suffix('.ppm')).convert('RGB')
                reference=native.render(info)
                actual.save(str(prefix)+'-aurora.png');reference.save(str(prefix)+'-native.png')
                for glyph in info['glyphs']:
                    cell=glyph['cell'];w=info['cell_width'];h=info['cell_height']
                    x=cell%16*w;y=cell//16*h
                    a=actual.crop((x,y,x+w,y+h));b=reference.crop((x,y,x+w,y+h))
                    score=diagnose.ref.grayscale_error(a,b,255)
                    rows.append({'font':family,'size':size,'character':chr(glyph['codepoint']),
                        'codepoint':glyph['codepoint'],'error':score['mean_absolute_error'],'ink_pixels':score['ink_pixels']})
        finally:native.close()
    print(name,'character mean',sum(r['error'] for r in rows)/len(rows),'worst',max(r['error'] for r in rows),flush=True)
    return rows


def main():
    exe=compile('current')
    results={}
    for name,experiment,hinting in [('current', 'native-refined','natural'),('C',None,'natural'),('unhinted',None,'0')]:
        results[name]=measure(name,exe,experiment,hinting)
    (HERE/'initial-audit.json').write_text(json.dumps({'git_revision':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
        'comparisons':results},indent=2))
    for family in ['segoe','consolas','courier']:
        rows=[r for r in results['current'] if r['font']==family and r['size']==17]
        print(family,'worst:',sorted(rows,key=lambda r:r['error'],reverse=True)[:12])


if __name__=='__main__':main()
