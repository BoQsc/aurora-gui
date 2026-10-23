"""Verify shared default against the pre-promotion refined D pixels."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CORE = ROOT / 'vendor/aurora-d-0.4.5'
BUILD = ROOT / 'build-validation/native-text-default-d'
sys.path.insert(0, str(HERE.parent / 'native-text-next'))
import diagnose


def environment(profile='default'):
    env = os.environ.copy()
    for key in tuple(env):
        if key.startswith(('AURORA_TEXT_', 'AURORA_TEST_')) or key in (
                'AURORA_HINTING', 'AURORA_FONT', 'AURORA_UI_FONT',
                'AURORA_MONOSPACE_FONT', 'AURORA_UI_BOLD_FONT', 'AURORA_FONT_RENDER_MODE'):
            env.pop(key, None)
    if profile != 'default':
        env['AURORA_TEXT_EXPERIMENT'] = {
            'C': 'compatible-c', 'D-original': 'native-next',
            'refined-D': 'native-refined', 'unhinted': 'native-refined',
            'diagnostic': 'native-refined'}[profile]
    if profile in ('unhinted', 'diagnostic'):
        env['AURORA_HINTING'] = '0' if profile == 'unhinted' else '1'
    return env


def compile(name, source, before=False, native=False):
    out = BUILD / name
    out.mkdir(parents=True, exist_ok=True)
    include = HERE / 'before-source/source' if before else CORE / 'source'
    exe = out / 'probe.exe'
    command = ['dmd', '-i', '-O', '-I'+str(include), '-I'+str(CORE/'source'),
               '-I'+str(ROOT/'aurora-opencode-core/source'),
               '-od='+str(out), '-of='+str(exe), str(source),
               'user32.lib', 'gdi32.lib', 'shell32.lib', 'wininet.lib']
    if not native:
        command.append('-version=AuroraHeadless')
    subprocess.run(command, check=True, cwd=ROOT)
    return exe


def render(exe, font, size, prefix, env):
    subprocess.run([str(exe), font, str(size), str(prefix)], env=env,
                   check=True, capture_output=True)
    return Image.open(prefix.with_suffix('.ppm')).convert('RGB')


def main():
    exes = {name: compile('glyph-'+name, HERE/'glyph_sheet.d', before=name=='before')
            for name in ['before', 'current']}
    rows = []
    cases = [(font, size, 0, False) for font in diagnose.FONTS for size in range(1, 97)]
    cases += [(font, 17, phase, dark) for font in diagnose.FONTS
              for phase in range(8) for dark in [False, True] if phase or dark]
    for family, size, phase, dark in cases:
        images = []
        for label, profile in [('before', 'refined-D'), ('current', 'default')]:
            env = environment(profile)
            env.update(AURORA_TEST_PHASE=str(phase/8), AURORA_TEST_DARK=str(int(dark)))
            image = render(exes[label], diagnose.FONTS[family], size, BUILD/label, env)
            images.append(image.tobytes())
        rows.append({'font': family, 'size': size, 'phase': phase, 'dark': dark,
                     'equal': images[0] == images[1],
                     'sha256': hashlib.sha256(images[1]).hexdigest()})
        if size == 96:
            print(family, 'sizes 1..96 checked', flush=True)
    controls = []
    for profile in ['C', 'D-original', 'unhinted', 'diagnostic']:
        for family, font in diagnose.FONTS.items():
            for size in diagnose.SIZES:
                pixels = [render(exes[label], font, size, BUILD/label,
                                 environment(profile)).tobytes() for label in exes]
                controls.append({'profile': profile, 'font': family, 'size': size,
                                 'equal': pixels[0] == pixels[1]})
        print(profile, '72 compatibility sheets checked', flush=True)
    result = {'default': 'refined D', 'default_sheets': len(rows),
              'default_glyphs': len(rows)*94, 'cases': rows, 'controls': controls}
    (HERE/'promotion.json').write_text(json.dumps(result, indent=2))
    assert all(r['equal'] for r in rows+controls), 'Promotion changed reviewed pixels'
    print('Default equals refined D; explicit compatibility profiles unchanged.', flush=True)


if __name__ == '__main__':
    main()
