"""Run full host and live Pad++ workflows against separate release output."""
import hashlib
import json
from pathlib import Path
import sys

from PIL import Image

import sys
sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'native-text-audit'))
from promotion import environment
sys.path.insert(0,str(Path(__file__).resolve().parent))
from validate import run

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
sys.path.insert(0,str(HERE.parent/'text-coverage-candidate'))
from review import make_review


def main():
    host=ROOT/'build-validation/native-text-default-d/host-release/aurora-host-experiment.exe'
    checks=[]
    assert host.exists(),'Build the isolated release first'
    def save():
        (HERE/'ui-validation.json').write_text(json.dumps({'default':'owner-approved refined D',
            'host_sha256':hashlib.sha256(host.read_bytes()).hexdigest(),'checks':checks},indent=2))
    for profile in ['C','default']:
        env=environment(profile)
        record=run([sys.executable,'experiments/aurora-host/tools/verify_experiment.py'],env=env)
        checks.append({'name':'host-'+profile,'records':[record]})
        save()
        print('Full host',profile,record['exit_code'],flush=True)
        env['AURORA_HOST_EXE']=str(host)
        record=run([sys.executable,'-u','-B','padpp.py','--self-test','--host',host],
            ROOT/'experiments/aurora-host-notepadpp',env)
        checks.append({'name':'padpp-'+profile,'records':[record]})
        save()
        print('Live Pad++',profile,record['exit_code'],flush=True)
        for suffix in ['.png','-metrics.json']:
            path=ROOT/('experiments/aurora-host-notepadpp/build/padpp'+suffix)
            if path.exists():(HERE/('padpp-live-'+profile+suffix)).write_bytes(path.read_bytes())
    if all(not r['exit_code'] for c in checks for r in c['records']):
        a=Image.open(HERE/'padpp-live-C.png').convert('RGB')
        dpi=round(a.width/1180*96)
        make_review(HERE/'padpp-live-C.png',HERE/'padpp-live-default.png',
            f'Pad++ live {dpi} DPI: previous C / default refined D',HERE/f'padpp-live-{dpi}')
        data=json.loads((HERE/'ui-validation.json').read_text());data.update(live_dpi=dpi)
        (HERE/'ui-validation.json').write_text(json.dumps(data,indent=2))
    return int(any(r['exit_code'] for c in checks for r in c['records']))


if __name__=='__main__':raise SystemExit(main())
