"""Independent generated-font evidence for unrounded horizontal MIRP cut-in."""
import json
import os
from pathlib import Path
import subprocess
import sys

from fontTools.ttLib import TTFont
from PIL import Image

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
sys.path.insert(0,str(HERE.parent/'native-text-next'))
import diagnose
from native_cutin_probe import font


def main():
    out=ROOT/'build-validation/native-text-glyphs/native-probe';out.mkdir(parents=True,exist_ok=True)
    records=[]
    candidates={'before':ROOT/'build-validation/native-text-refined/corpus/refined-D/fixture.exe',
                'after':ROOT/'build-validation/native-text-glyphs/corpus/refined-D/fixture.exe'}
    env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',
        AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0')
    for axis in ['x','y']:
        for flags in [7,15]:
            for original in [64,96,128,192]:
                path=out/f'{axis}-{flags}-{original}.ttf'
                font(path,original,original+64,axis,'mirp',False)
                ft=TTFont(path);ft['gasp'].gaspRange={65535:flags};ft.save(path)
                native=diagnose.ref.NativeReference(path)
                try:
                    row={'axis':axis,'gasp':flags,'outline_26dot6':original,'requested_26dot6':original+64}
                    for label,exe in candidates.items():
                        prefix=out/f'{path.stem}-{label}'
                        subprocess.run([str(exe),str(path),'16',str(prefix),'A'],check=True,env=env,capture_output=True)
                        info=json.loads(prefix.with_suffix('.json').read_text())
                        actual=Image.open(str(prefix)+'-light.ppm').convert('RGB')
                        target=native.render(info,neutral=True)
                        row[label]={'error':diagnose.ref.grayscale_error(actual,target,255)['mean_absolute_error'],
                            'exact':actual.tobytes()==target.tobytes()}
                    records.append(row)
                finally:native.close()
    assert all(r['after']['error']<r['before']['error'] for r in records if r['axis']=='x')
    assert all(r['after']==r['before'] for r in records if r['axis']=='y')
    (HERE/'native-probe.json').write_text(json.dumps({'scope':'16 generated-font cases; x/y and symmetric/asymmetric; neutral DirectWrite reference',
        'comparisons':records},indent=2))
    print('Native unrounded MIRP probe: all 8 x cases improve; 8 y controls unchanged')


if __name__=='__main__':main()
