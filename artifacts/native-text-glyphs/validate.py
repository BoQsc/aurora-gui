"""Framework regressions and isolated releases; UI workflows are serialized."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import shutil

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
CORE=ROOT/'vendor/aurora-d-0.4.5'
BUILD=ROOT/'build-validation/native-text-glyphs'
from capture import environment


def run(command,cwd=ROOT,env=None):
    r=subprocess.run(list(map(str,command)),cwd=cwd,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace')
    return {'command':list(map(str,command)),'exit_code':r.returncode,'output':r.stdout+r.stderr}


def check(name,source,unit=False):
    out=BUILD/'validation'/name;out.mkdir(parents=True,exist_ok=True)
    exe=out/(name+'.exe')
    command=['dmd','-i','-I'+str(CORE/'source'),'-od='+str(out),'-of='+str(exe)]
    command+=['-unittest','-main'] if unit else ['-version=AuroraHeadless']
    records=[run([*command,CORE/source,'user32.lib','gdi32.lib'],CORE)]
    if not records[-1]['exit_code']:
        for profile in (['C'] if unit else ['C','refined-D']):
            record=run([exe],CORE,environment(profile));record['profile']=profile;records.append(record)
    print(name,'passed' if all(not r['exit_code'] for r in records) else 'FAILED',flush=True)
    return {'name':name,'records':records}


def release(name,path):
    out=BUILD/(name+'-release');out.mkdir(parents=True,exist_ok=True)
    record=run(['dub','build','-b','release','--force','--dest='+str(out)],ROOT/path)
    exe=out/('aurora-host-experiment.exe' if name=='host' else 'aurora-notepad.exe')
    if exe.exists():record['sha256']=hashlib.sha256(exe.read_bytes()).hexdigest()
    print(name,'release',record['exit_code'],flush=True)
    return {'name':name+'-release','records':[record]}


def native_alpha():
    out=BUILD/'unit';out.mkdir(parents=True,exist_ok=True)
    exe=out/'native-alpha.exe'
    records=[run(['dmd','-i','-O','-version=AuroraHeadless','-I'+str(CORE/'source'),
        '-od='+str(out),'-of='+str(exe),CORE/'tests/native_alpha.d','user32.lib','gdi32.lib'],CORE)]
    if not records[-1]['exit_code']:
        renamed=out/'renamed-legacy-font.ttf'
        shutil.copyfile(Path(os.environ.get('WINDIR','C:/Windows'))/'Fonts/cour.ttf',renamed)
        records.append(run([exe,renamed],CORE))
    return {'name':'native-alpha','records':records}


def main():
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        tasks=[pool.submit(check,*case) for case in [
            ('coverage','tests/text_coverage.d'),('font-quality','tests/font_quality_regression.d'),
            ('dpi','tests/dpi_rendering.d'),('window-dpi','tests/window_dpi_regression.d'),
            ('hinter-unit','source/aurora/text/hinter.d',True),
            ('rasterizer-unit','source/aurora/text/rasterizer.d',True),
            ('alpha-unit','source/aurora/text/alphacorrection.d',True),
            ('fontprofile-unit','source/aurora/text/fontprofile.d',True),
            ('hinting-windows','tests/hinting_windows_regression.d')]]
        tasks += [pool.submit(release,'host','experiments/aurora-host'),pool.submit(release,'notepad','aurora-notepad'),
                  pool.submit(native_alpha)]
        checks=[future.result() for future in tasks]
    for name,command in [
        ('standards',[sys.executable,'scripts/audit-aurora-standards.py']),
        ('python',[sys.executable,'-W','ignore','-m','unittest','scripts.tests.test_font_comparison','scripts.tests.test_aurora_standards_audit'])]:
        record=run(command);checks.append({'name':name,'records':[record]});print(name,record['exit_code'],flush=True)
    (HERE/'validation.json').write_text(json.dumps({'default':'owner-approved C','checks':checks},indent=2))
    return int(any(r['exit_code'] for c in checks for r in c['records']))


if __name__=='__main__':raise SystemExit(main())
