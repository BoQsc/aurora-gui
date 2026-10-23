"""Capture C/refined D without touching the declined D review or user binary."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from PIL import Image

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
BUILD=ROOT/'build-validation/native-text-audit/capture'
sys.path.insert(0,str(HERE.parent/'text-coverage-candidate'))
from review import make_review


def environment(profile):
    env=os.environ.copy()
    for key in ('AURORA_FONT_RENDER_MODE','AURORA_FONT','AURORA_UI_FONT','AURORA_MONOSPACE_FONT','AURORA_UI_BOLD_FONT',
                'AURORA_TEXT_GAMMA','AURORA_TEXT_EXPERIMENT','AURORA_HINTING','AURORA_TEXT_CONTRAST','AURORA_TEXT_COVERAGE'):
        env.pop(key,None)
    if profile=='refined-D':env['AURORA_TEXT_EXPERIMENT']='native-refined'
    return env


def main():
    BUILD.mkdir(parents=True,exist_ok=True)
    records=[]
    def run(command,env=None):
        result=subprocess.run(list(map(str,command)),cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace')
        records.append({'command':list(map(str,command)),'exit_code':result.returncode,'output':result.stdout+result.stderr})
        if result.returncode:raise RuntimeError(result.stdout+result.stderr)
        return result
    executables={}
    for target in ['headless','native']:
        out=BUILD/target;out.mkdir(exist_ok=True)
        exe=out/'capture.exe'
        includes=['vendor/aurora-d-0.4.5/source','vendor/aurora-standard/source','aurora-notepad/source',
                  'experiments/aurora-host/source','experiments/aurora-host/generated']
        command=['dmd','-i','-O','-J'+str(ROOT/'experiments/aurora-host/assets'),*['-I'+str(ROOT/p) for p in includes],'-od='+str(out),'-of='+str(exe),
                 HERE.parent/'text-coverage-candidate/capture.d','user32.lib','gdi32.lib','shell32.lib','wininet.lib']
        if target=='headless':command.append('-version=AuroraHeadless')
        run(command);executables[target]=exe
    for profile in ['C','refined-D']:
        env=environment(profile)
        for app,themes in [('notepad',['light','dark']),('host',['light','dark']),('padpp',['light'])]:
            for theme in themes:
                for dpi in [96,144]:
                    name=f'{app}-{theme}-{dpi}'
                    prefix=BUILD/(name+'-'+profile)
                    run([executables['headless'],app,prefix,theme,dpi],env)
                    actual=Image.open(prefix.with_suffix('.ppm')).convert('RGB')
                    actual.save(HERE/(name+'-'+profile+'.png'))
                    if profile=='C':
                        previous=Image.open(HERE.parent/'native-text-next'/(name+'-C.png')).convert('RGB')
                        assert actual.tobytes()==previous.tobytes(),('C changed',name)
        prefix=BUILD/('gpu-'+profile)
        result=run([executables['native'],'native',prefix],env)
        print(profile,result.stdout.strip(),flush=True)
        for stage in [0,1]:
            for suffix in [f'-{stage}',f'-software-{stage}']:
                Image.open(str(prefix)+suffix+'.ppm').save(HERE/('gpu-'+profile+suffix+'.png'))
            if profile=='refined-D':
                a=Image.open(str(prefix)+f'-{stage}.ppm').convert('RGB')
                b=Image.open(str(prefix)+f'-software-{stage}.ppm').convert('RGB')
                assert a.tobytes()==b.tobytes(),'Experimental opacity shader must match software exactly'
    for path in HERE.glob('*-C.png'):
        if path.name.startswith('gpu-'):continue
        name=path.stem[:-2]
        make_review(path,HERE/(name+'-refined-D.png'),name+': approved C / refined D (experimental)',HERE/name)
    (HERE/'captures.json').write_text(json.dumps({'C_app_pixels_unchanged':True,'records':records},indent=2))


if __name__=='__main__':main()
