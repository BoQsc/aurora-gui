"""Run full host and live Pad++ workflows against separate release output."""
import hashlib
import json
from pathlib import Path
import sys

from PIL import Image

from capture import environment
from validate import run

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
sys.path.insert(0,str(HERE.parent/'text-coverage-candidate'))
from review import make_review


def main():
    host=ROOT/'build-validation/native-text-refined/host-release/aurora-host-experiment.exe'
    checks=[]
    assert host.exists(),'Build the isolated release first'
    def save():
        (HERE/'ui-validation.json').write_text(json.dumps({'default':'owner-approved C',
            'host_sha256':hashlib.sha256(host.read_bytes()).hexdigest(),'checks':checks},indent=2))
    for profile in ['C','refined-D']:
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
        previous=Image.open(HERE.parent/'native-text-next/padpp-live-C.png').convert('RGB')
        if a.size!=previous.size:
            # The desktop moved from 125% to 100% DPI since D's review. Render
            # the preserved D-era binary in C mode at today's scale; do not
            # resize either image or call differing resolutions a regression.
            baseline=ROOT/'build-validation/native-text-next/host-release/aurora-host-experiment.exe'
            env=environment('C');env['AURORA_HOST_EXE']=str(baseline)
            record=run([sys.executable,'-u','-B','padpp.py','--self-test','--host',baseline],
                ROOT/'experiments/aurora-host-notepadpp',env)
            checks.append({'name':'preserved-C-same-DPI','records':[record]});save()
            assert not record['exit_code'],record['output']
            path=ROOT/'experiments/aurora-host-notepadpp/build/padpp.png'
            (HERE/'padpp-preserved-C-same-DPI.png').write_bytes(path.read_bytes())
            previous=Image.open(path).convert('RGB')
        assert a.size==previous.size and a.tobytes()==previous.tobytes(),'Same-DPI live C pixels changed'
        dpi=round(a.width/1180*96)
        make_review(HERE/'padpp-live-C.png',HERE/'padpp-live-refined-D.png',
            f'Pad++ live {dpi} DPI: approved C / refined D (experimental)',HERE/f'padpp-live-{dpi}')
        save()
        path=HERE/'ui-validation.json';data=json.loads(path.read_text())
        data.update(C_live_pixels_unchanged=True,live_dpi=dpi,
            prior_review_dpi=120,desktop_DPI_changed_since_D_review=(dpi!=120))
        path.write_text(json.dumps(data,indent=2))
    return int(any(r['exit_code'] for c in checks for r in c['records']))


if __name__=='__main__':raise SystemExit(main())
