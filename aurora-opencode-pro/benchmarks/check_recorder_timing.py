"""Independent real encoder acceptance; never trusts the agent's generated tests."""
import argparse, json, os, subprocess, time
from pathlib import Path

PACKAGE=Path(__file__).resolve().parents[1]

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('replay',type=Path)
    ap.add_argument('--before',action='store_true')
    a=ap.parse_args(); root=a.replay.resolve()
    out=root/('independent-before' if a.before else 'independent-after');out.mkdir(parents=True,exist_ok=True)
    ws=root/'checkout/aurora-video-recorder'
    if a.before:
        source=out/'source/aurorarecorder';source.mkdir(parents=True,exist_ok=True)
        ref=json.loads((root/'result.json').read_text())['ref'] if (root/'result.json').exists() else '01da5d0'
        (source/'encoder.d').write_bytes(subprocess.check_output(['git','show',ref+':aurora-video-recorder/source/aurorarecorder/encoder.d'],cwd=PACKAGE.parent))
    compiler=['dmd','-i','-O','-verrors=10','-Isource','-I../vendor/aurora-d-0.4.5/source']
    if a.before: compiler.insert(3,'-I'+str(out/'source'))
    gate=out/'ffmpeg-gate.exe';probe=out/'probe.exe'
    started=time.monotonic()
    with (out/'compile.log').open('w') as log:
        subprocess.run(['dmd','-i','-O','-of'+str(gate),str(PACKAGE/'benchmarks/recorder_backpressure.d')],cwd=ws,stdout=log,stderr=subprocess.STDOUT,check=True)
        subprocess.run(compiler+['-of'+str(probe),str(PACKAGE/'benchmarks/recorder_timing_acceptance.d'),'user32.lib','gdi32.lib','ole32.lib'],cwd=ws,stdout=log,stderr=subprocess.STDOUT,check=True)
    bins=list((Path(os.environ['LOCALAPPDATA'])/'Microsoft/WinGet/Packages').glob('Gyan.FFmpeg_*/ffmpeg-*/bin'))
    assert bins,'Installed FFmpeg required'
    env=dict(os.environ,AURORA_TEST_REAL_FFMPEG=str(bins[0]/'ffmpeg.exe'),TEMP=str(out),TMP=str(out))
    run=subprocess.run([str(probe),str(gate),str(out)],cwd=ws,env=env,capture_output=True,text=True,timeout=75)
    (out/'probe.log').write_text(run.stdout+run.stderr)
    measurements=[]
    for line in run.stdout.splitlines():
        if not line.startswith('MEASURE '):continue
        _,fps,millis,frames=line.split();fps=int(fps)
        info=json.loads(subprocess.check_output([str(bins[0]/'ffprobe.exe'),'-v','error','-select_streams','v:0',
            '-show_entries','stream=duration,nb_frames','-of','json',str(out/f'independent-{fps}.mp4')],text=True))
        duration=float(info['streams'][0]['duration']); wall=int(millis)/1000
        measurements.append(dict(fps=fps,wallSeconds=wall,videoSeconds=duration,frames=int(frames),errorSeconds=duration-wall))
    passed=run.returncode==0 and len(measurements)==2 and all(abs(x['errorSeconds'])<0.25 for x in measurements)
    result=dict(passed=passed,probeExit=run.returncode,measurements=measurements,seconds=time.monotonic()-started)
    (out/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
    raise SystemExit(0 if passed else 1)

if __name__=='__main__':main()
