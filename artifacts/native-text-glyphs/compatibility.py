"""The refinement must be inactive under both compatibility hinting modes."""
import json
import os
from pathlib import Path
import subprocess

from PIL import Image

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
BUILD=ROOT/'build-validation/native-text-glyphs/compatibility'


def main():
    BUILD.mkdir(parents=True,exist_ok=True)
    exe=ROOT/'build-validation/native-text-glyphs/corpus/C/fixture.exe'
    results=[]
    for hinting in ['0','1']:
        for name in ['segoeui.ttf','cour.ttf']:
            captures=[]
            for profile in ['C','refined-D']:
                env=os.environ.copy()
                env.update(AURORA_HINTING=hinting,AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0.5')
                env.pop('AURORA_TEXT_EXPERIMENT',None)
                if profile=='refined-D':env['AURORA_TEXT_EXPERIMENT']='native-refined'
                prefix=BUILD/f'{hinting}-{name}-{profile}'
                subprocess.run([str(exe),'C:/Windows/Fonts/'+name,'13',str(prefix),'office Il1 O0 café Жй'],env=env,check=True)
                captures.append(prefix)
            for theme in ['light','dark']:
                a,b=[Image.open(str(p)+f'-{theme}.ppm').convert('RGB') for p in captures]
                assert a.tobytes()==b.tobytes(),(hinting,name,theme)
                results.append({'hinting':hinting,'font':name,'theme':theme,'refinement_inactive':True})
    (HERE/'compatibility.json').write_text(json.dumps(results,indent=2))
    print('Compatibility profiles: all 8 comparisons unchanged')


if __name__=='__main__':main()
