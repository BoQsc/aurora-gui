"""Opaque RGB/selection corpus against independent DirectWrite grayscale output."""
import json
import os
from pathlib import Path
import subprocess
import sys

from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE.parent / 'native-text-next'))
import diagnose

BUILD = ROOT / 'build-validation/native-text-refined/colors'
COLORS = [(0, 0, 0), (35, 41, 48), (255, 255, 255), (240, 240, 240),
          (200, 35, 60), (30, 130, 70), (40, 80, 210), (60, 80, 160)]
BACKGROUNDS = [(255, 255, 255), (24, 24, 24), (170, 200, 240)]


def rgb_error(actual, target, background):
    errors = [sum(abs(x-y) for x,y in zip(a,b))/3
              for a,b in zip(actual.getdata(),target.getdata()) if a != background or b != background]
    return sum(errors)/max(1,len(errors))


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    # Keep the standard monochrome fixture unchanged. This supplemental fixture
    # accepts colors but uses the identical Canvas/atlas paths and glyph origins.
    source = (diagnose.CORE / 'tests/font_quality.d').read_text()
    source = source.replace('module tests.font_quality;', 'module native_color_fixture;')
    source = source.replace('if (args.length != 5)', 'if (args.length != 11)')
    source = source.replace('foreach (dark; [false, true])', 'foreach (dark; [false])')
    source = source.replace('const bg = dark ? Color.rgb(24, 24, 24) : Color.rgb(255, 255, 255);',
        'const bg = Color.rgb(args[8].to!ubyte, args[9].to!ubyte, args[10].to!ubyte);')
    source = source.replace('const fg = dark ? Color.rgb(240, 240, 240) : Color.rgb(0, 0, 0);',
        'const fg = Color.rgb(args[5].to!ubyte, args[6].to!ubyte, args[7].to!ubyte);')
    fixture = HERE / 'color_fixture.d'
    fixture.write_text(source)
    exe = BUILD / 'colors.exe'
    subprocess.run(['dmd','-i','-O','-version=AuroraHeadless','-I'+str(diagnose.CORE/'source'),
                    '-od='+str(BUILD),'-of='+str(exe),str(fixture),'user32.lib','gdi32.lib'],check=True)
    results = {p: [] for p in ['C','D','refined-D']}
    settings = None
    for family in ['segoe','consolas','courier','inter']:
        path = diagnose.FONTS[family]
        native = diagnose.ref.NativeReference(path)
        if settings is None:settings = native.settings
        try:
            for size in [12,17,26]:
                for fg in COLORS:
                    for bg in BACKGROUNDS:
                        key = f'{family}-{size}-'+'-'.join(map(str,(*fg,*bg)))
                        target = None
                        for profile, experiment in [('C',None),('D','native-next'),('refined-D','native-refined')]:
                            env = os.environ.copy()
                            env.update(AURORA_HINTING='natural',AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0.5')
                            env.pop('AURORA_TEXT_GAMMA',None)
                            env.pop('AURORA_TEXT_EXPERIMENT',None)
                            if experiment: env['AURORA_TEXT_EXPERIMENT']=experiment
                            prefix = BUILD / (key+'-'+profile)
                            subprocess.run([str(exe),path,str(size),str(prefix),diagnose.TEXT,
                                            *map(str,fg),*map(str,bg)],env=env,check=True)
                            info = json.loads(prefix.with_suffix('.json').read_text())
                            if target is None:
                                target = native.render(info,foreground=fg,background=bg)
                                origins = info['glyphs']
                                target.save(BUILD/(key+'-native.png'))
                            assert origins == info['glyphs']
                            actual = Image.open(str(prefix)+'-light.ppm').convert('RGB')
                            results[profile].append({'font':family,'size':size,'foreground':fg,'background':bg,
                                                     'rgb_ink_mae':rgb_error(actual,target,bg)})
        finally:
            native.close()
        print('Native RGB corpus:',family,flush=True)
    summary = {}
    for profile in ['C','D']:
        pairs = list(zip(results['refined-D'],results[profile]))
        summary[profile] = {'improved':sum(a['rgb_ink_mae']<b['rgb_ink_mae'] for a,b in pairs),
            'equal':sum(a['rgb_ink_mae']==b['rgb_ink_mae'] for a,b in pairs),
            'regressed':sum(a['rgb_ink_mae']>b['rgb_ink_mae'] for a,b in pairs),
            'baseline_mean':sum(b['rgb_ink_mae'] for a,b in pairs)/len(pairs),
            'refined_mean':sum(a['rgb_ink_mae'] for a,b in pairs)/len(pairs)}
    (HERE/'colors.json').write_text(json.dumps({'scope':'288 opaque RGB comparisons; independent DirectWrite grayscale; ink-union RGB MAE',
        'summary':summary,'comparisons':results,'native_settings':settings},indent=2))
    print(json.dumps(summary,indent=2))


if __name__ == '__main__':main()
