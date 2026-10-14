"""Build and compare isolated command-effect scheduler fixtures."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

PACKAGE=Path(__file__).resolve().parents[1]
ROOT=PACKAGE.parent

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--build',choices=['baseline','candidate'])
    p.add_argument('--baseline-ref',default='HEAD')
    p.add_argument('--profiles',nargs='+',default=['baseline','candidate'])
    p.add_argument('--repeats',type=int,default=3)
    a=p.parse_args();a.output=a.output.resolve();directory=a.output.parent;directory.mkdir(parents=True,exist_ok=True)
    if a.build:
        overlay=[]
        revision=subprocess.check_output(['git','rev-parse',a.baseline_ref if a.build=='baseline' else 'HEAD'],cwd=ROOT,text=True).strip()
        if a.build=='baseline':
            before=directory/'baseline-source'
            for name in ['tools','toolscheduler']:
                relative=f'aurora-opencode-pro/source/auroraopencode/{name}.d'
                target=before/'auroraopencode'/(name+'.d');target.parent.mkdir(parents=True,exist_ok=True)
                target.write_bytes(subprocess.check_output(['git','show',revision+':'+relative],cwd=ROOT))
            overlay=['-I'+str(before)]
        for name,source in [(a.build,'command_effect_contracts'),(a.build+'-child','command_effect_child')]:
            subprocess.run(['dmd','-i','-O','-inline',*overlay,'-I'+str(PACKAGE/'source'),'-I'+str(PACKAGE/'shared'),
                '-I'+str(ROOT/'aurora-opencode-core/source'),'-I'+str(ROOT/'vendor/aurora-d-0.4.5/source'),
                '-J'+str(PACKAGE/'assets'),'-of'+str(directory/(name+'.exe')),str(PACKAGE/'tests'/(source+'.d')),
                'user32.lib','gdi32.lib','shell32.lib','wininet.lib','winmm.lib'],cwd=directory,check=True,timeout=180)
        (directory/(a.build+'-provenance.json')).write_text(json.dumps(dict(revision=revision,
            source='committed tools and scheduler overlay' if a.build=='baseline' else 'working tree',
            modules={name:hashlib.sha256(((before if a.build=='baseline' else PACKAGE/'source')/'auroraopencode'/(name+'.d')).read_bytes()).hexdigest()
                     for name in (['tools','toolscheduler'] if a.build=='baseline' else ['tools','toolscheduler','workspacefingerprint'])}),indent=2),encoding='utf-8')
        return
    data=dict(binaries={x:hashlib.sha256((directory/(x+'.exe')).read_bytes()).hexdigest() for x in a.profiles},
              provenance={x:json.loads((directory/(x+'-provenance.json')).read_text(encoding='utf-8')) for x in a.profiles},runs=[])
    for attempt in range(1,a.repeats+1):
        for profile in a.profiles if attempt%2 else a.profiles[::-1]:
            run=directory/a.output.stem/profile/str(attempt);run.mkdir(parents=True,exist_ok=False)
            result=run/'results.json'
            proc=subprocess.run([str(directory/(profile+'.exe')),str(directory/(profile+'-child.exe')),str(result)],
                cwd=run,capture_output=True,text=True,errors='replace',timeout=40)
            (run/'fixture.log').write_text(proc.stdout+proc.stderr,encoding='utf-8')
            if proc.returncode:raise RuntimeError((proc.stdout+proc.stderr)[-2000:])
            cases=json.loads(result.read_text(encoding='utf-8'))
            data['runs'].append(dict(profile=profile,attempt=attempt,cases=cases))
            a.output.write_text(json.dumps(data,indent=2),encoding='utf-8')
            print(profile,attempt,sum(c['correct'] for c in cases),'/',len(cases),flush=True)
    if 'candidate' in a.profiles and not all(c['correct'] for r in data['runs'] if r['profile']=='candidate' for c in r['cases']):
        raise SystemExit('Candidate guard failed')

if __name__=='__main__':main()
