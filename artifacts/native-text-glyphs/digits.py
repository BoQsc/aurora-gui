"""Each 17px numeral at all eight horizontal phases, before/after vs native."""
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from PIL import Image

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
CORE=ROOT/'vendor/aurora-d-0.4.5'
BUILD=ROOT/'build-validation/native-text-glyphs/digits'
sys.path.insert(0,str(HERE.parent/'native-text-next'))
import diagnose


def compile_fixtures():
    BUILD.mkdir(parents=True,exist_ok=True)
    source=(CORE/'tests/font_quality.d').read_text().replace('module tests.font_quality;','module native_digit_fixture;')
    source=source.replace('    const width =',
        '    foreach (ref glyph; layout.glyphs) glyph.x += environment.get("AURORA_TEST_PHASE", "0").to!double;\n    const width =',1)
    fixture=HERE/'digit_fixture.d';fixture.write_text(source)
    executables={}
    for label in ['before','after']:
        out=BUILD/label;out.mkdir(exist_ok=True)
        includes=[]
        if label=='before':
            target=out/'source/aurora/text';target.mkdir(parents=True,exist_ok=True)
            for name in ['hinter','truetype']:
                shutil.copyfile(HERE/'baseline-refined'/f'{name}.d',target/f'{name}.d')
            includes=['-I'+str(out/'source')]
        exe=out/'digits.exe'
        subprocess.run(['dmd','-i','-O','-version=AuroraHeadless',*includes,'-I'+str(CORE/'source'),
            '-od='+str(out),'-of='+str(exe),str(fixture),'user32.lib','gdi32.lib'],check=True)
        executables[label]=exe
    return executables


def measure(family,executables):
    path=diagnose.FONTS[family]
    native=diagnose.ref.NativeReference(path)
    records=[]
    try:
        for phase in range(8):
            for digit in '0123456789':
                row={'font':family,'size':17,'digit':digit,'phase_eighths':phase}
                for label,exe in executables.items():
                    env=os.environ.copy()
                    env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',
                        AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0.5',AURORA_TEST_PHASE=str(phase/8))
                    env.pop('AURORA_TEXT_GAMMA',None)
                    prefix=BUILD/f'{family}-{phase}-{digit}-{label}'
                    subprocess.run([str(exe),path,'17',str(prefix),digit],env=env,check=True,capture_output=True)
                    info=json.loads(prefix.with_suffix('.json').read_text())
                    for dark in [False,True]:
                        theme='dark' if dark else 'light'
                        actual=Image.open(str(prefix)+f'-{theme}.ppm').convert('RGB')
                        target=native.render(info,dark)
                        target.save(str(prefix)+f'-{theme}-native.png')
                        row[label+'-'+theme]=diagnose.ref.grayscale_error(actual,target,24 if dark else 255)['mean_absolute_error']
                for theme in ['light','dark']:
                    records.append({**{k:v for k,v in row.items() if k in ['font','size','digit','phase_eighths']},
                        'theme':theme,'before_error':row['before-'+theme],'after_error':row['after-'+theme]})
    finally:native.close()
    print(family,'numeral/phase corpus complete',flush=True)
    return records


def main():
    executables=compile_fixtures()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        groups=list(pool.map(lambda family:measure(family,executables),['consolas','courier']))
    records=[r for group in groups for r in group]
    summary={}
    for family in ['consolas','courier']:
        rows=[r for r in records if r['font']==family]
        summary[family]={'improved':sum(r['after_error']<r['before_error'] for r in rows),
            'equal':sum(r['after_error']==r['before_error'] for r in rows),
            'regressed':sum(r['after_error']>r['before_error'] for r in rows),
            'before_mean':sum(r['before_error'] for r in rows)/len(rows),
            'after_mean':sum(r['after_error'] for r in rows)/len(rows)}
    (HERE/'digits.json').write_text(json.dumps({'scope':'320 cases: 2 fonts × 10 isolated numerals × 8 phases × 2 themes, all 17px',
        'summary':summary,'comparisons':records},indent=2))
    print(json.dumps(summary,indent=2))


if __name__=='__main__':main()
