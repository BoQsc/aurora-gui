"""Counterbalanced app-path comparison of stock and explicit batching prompts.

Both binaries use the same source snapshot. The baseline is compiled with
AuroraBatchingBaseline, which omits only the candidate's static prompt section.
Synthetic workspaces and independent outcome checks are used for every attempt.
"""
import argparse
import atexit
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

from compare import TASKS, fixture, verify, safe_remove_state
from latency import credentials

PACKAGE=Path(__file__).resolve().parents[1]
ROOT=PACKAGE.parent
CASES=['independent_reads','broken_build','task_store','dependent_reads','ordered_reads','missing_input']


def build(directory,profile):
    directory.mkdir(parents=True,exist_ok=True)
    exe=directory/(profile+'.exe')
    command=['dmd','-i','-O','-inline',
             *(['-version=AuroraBatchingBaseline'] if profile=='baseline' else []),
             '-I'+str(PACKAGE/'source'),'-I'+str(PACKAGE/'shared'),
             '-I'+str(ROOT/'aurora-opencode-core/source'),
             '-I'+str(ROOT/'vendor/aurora-d-0.4.5/source'),
             '-J'+str(PACKAGE/'assets'),'-of'+str(exe),str(PACKAGE/'tests/benchmark_app_path.d'),
             'user32.lib','gdi32.lib','wininet.lib','shell32.lib','winmm.lib']
    subprocess.run(command,cwd=directory,check=True,timeout=180)


def setup(name,workspace):
    if name in TASKS:
        fixture(TASKS[name],workspace);return TASKS[name].prompt
    workspace.mkdir(parents=True)
    if name=='independent_reads':
        for i in range(6):(workspace/f'value{i}.txt').write_text(str((i+1)*7))
        return ('Read value0.txt, value1.txt, value2.txt, value3.txt, value4.txt and value5.txt with the read tool. '
                'Add the six integers. Return exactly Sum=<total>. Do not modify files.')
    if name=='dependent_reads':
        (workspace/'entry.txt').write_text('route.txt')
        (workspace/'route.txt').write_text('selected.txt')
        (workspace/'selected.txt').write_text('7316')
        (workspace/'decoy.txt').write_text('WRONG')
        return ('Use read to open entry.txt, then follow the filename it contains, then follow that file\'s filename. '
                'Return exactly Value=<integer in the final referenced file>. Read only referenced files and do not modify files.')
    if name=='ordered_reads':
        (workspace/'first.txt').write_text('alpha');(workspace/'second.txt').write_text('omega')
        return ('Read first.txt and then second.txt using read. Issue each read in a separate assistant tool-call response, '
                'waiting for the first result before issuing the second. Return exactly alpha|omega. Do not modify files.')
    return ('Use read to inspect absent.txt. If it does not exist, return exactly Unavailable. '
            'Do not create it or search for alternative files.')


def path_of(call,workspace):
    try:
        args=json.loads(call['arguments']);value=args.get('filePath',args.get('path',''))
        path=Path(value)
        return path.relative_to(workspace).as_posix() if path.is_absolute() else path.as_posix().removeprefix('./')
    except (ValueError,TypeError,KeyError):return '<unresolved>'


def measure(name,profile,attempt,directory,base,key,model,timeout):
    run=directory/name/profile/f'run-{attempt}'
    workspace=run/'workspace';state=run/'state'
    atexit.register(safe_remove_state,state,run)
    prompt=setup(name,workspace)
    originals={p.name:p.read_bytes() for p in workspace.glob('*') if p.is_file()}
    prompt_file=run/'prompt.txt';prompt_file.write_text(prompt)
    env=dict(os.environ,AURORA_BENCH_KEY=key,AURORA_BENCH_BASE=base,AURORA_BENCH_EFFORT='high')
    began=time.monotonic()
    try:
        process=subprocess.run([str(directory/(profile+'.exe')),str(workspace),str(state),str(prompt_file),model,str(timeout)],
                               cwd=workspace,env=env,capture_output=True,text=True,errors='replace',timeout=timeout+15)
        completed=process.returncode==0
    except subprocess.TimeoutExpired:completed=False
    elapsed=time.monotonic()-began
    try:
        messages=[]
        for path in (state/'threads').glob('*.json'):messages.extend(json.loads(path.read_text(encoding='utf-8'))['messages'])
        assistants=[m for m in messages if m.get('role')=='assistant']
        tools=[m for m in messages if m.get('role')=='tool']
        final=assistants[-1].get('content','').strip() if assistants else ''
        groups=[[c for c in m.get('toolCalls',[]) if c['name'] in ('read','glob','grep','checksum')] for m in assistants]
        reads=[path_of(c,workspace) for m in assistants for c in m.get('toolCalls',[]) if c['name']=='read']
        violations=[]
        if name in TASKS:
            passed,evidence=verify(TASKS[name],workspace)
        else:
            expected={'independent_reads':'Sum=147','dependent_reads':'Value=7316','ordered_reads':'alpha|omega','missing_input':'Unavailable'}[name]
            passed=final==expected;evidence=final[:200]
            if any(not (workspace/path).exists() or (workspace/path).read_bytes()!=text for path,text in originals.items()):violations.append('input modified')
            mutations=[m['toolName'] for m in tools if m.get('toolName') in ('write','edit','apply_patch','copy','move','rename','remove','create_folder')]
            if mutations:violations.append('unrequested mutation')
            if name=='independent_reads' and set(reads)!={f'value{i}.txt' for i in range(6)}:violations.append('required read missing')
            if name=='dependent_reads' and reads!=['entry.txt','route.txt','selected.txt']:violations.append('dependency/reference order violated')
            if name=='ordered_reads':
                if reads!=['first.txt','second.txt'] or any(sum(c['name']=='read' for c in m.get('toolCalls',[]))>1 for m in assistants):violations.append('explicit separate-read instruction violated')
            if name=='missing_input' and (reads!=['absent.txt'] or (workspace/'absent.txt').exists() or not any(m.get('failed') for m in tools)):violations.append('missing-input handling violated')
        latencies=[]
        log=state/'logs/errors.log'
        if log.exists():
            for line in log.read_text(errors='replace').splitlines():
                if 'request latency:' in line and 'milestone=settled' in line:
                    fields=dict(re.findall(r'(\w+)=([^ ]+)',line))
                    latencies.append({k:int(fields[k]) for k in ['firstTokenUs','settledUs','uploadedUs']})
        return dict(case=name,profile=profile,attempt=attempt,completed=completed,correct=bool(completed and passed and not violations),
                    seconds=round(elapsed,3),model_rounds=len(assistants),inspection_rounds=sum(bool(g) for g in groups),
                    inspection_calls=sum(len(g) for g in groups),batched_inspection_rounds=sum(len(g)>1 for g in groups),
                    tool_results=len(tools),tool_failures=sum(bool(m.get('failed')) for m in tools),
                    provider_first_token_sum_s=round(sum(r['firstTokenUs'] for r in latencies if r['firstTokenUs']>=0)/1e6,3),
                    reasoning_chars=sum(len(m.get('reasoning','')) for m in assistants),violations=violations,verifier=evidence)
    finally:safe_remove_state(state,run)


def assess(data):
    rows=data['runs'];profiles={p:[r for r in rows if r['profile']==p] for p in ['baseline','candidate']}
    independent={p:[r for r in rr if r['case'] in ('independent_reads','broken_build','task_store')] for p,rr in profiles.items()}
    totals={p:sum(r['inspection_rounds'] for r in rr) for p,rr in independent.items()}
    rounds={p:sum(r['model_rounds'] for r in rr) for p,rr in independent.items()}
    complete=len(rows)==len(CASES)*2*data['repeats']
    all_correct=complete and all(r['correct'] for r in rows)
    fewer=totals['candidate']<totals['baseline']
    no_more=rounds['candidate']<=rounds['baseline']
    return dict(complete=complete,all_outcomes_and_guards_passed=all_correct,
                independent_inspection_rounds=totals,independent_model_rounds=rounds,
                acceptance_passed=bool(all_correct and fewer and no_more))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--build',choices=['baseline','candidate'])
    parser.add_argument('--repeats',type=int,default=2);parser.add_argument('--timeout',type=int,default=180)
    args=parser.parse_args();args.output=args.output.resolve();directory=args.output.parent
    if args.build:build(directory,args.build);return
    base,key=credentials()
    settings=json.loads((Path(os.environ['APPDATA'])/'Aurora OpenCode/settings.json').read_text())
    model=settings['model']
    if not key:raise RuntimeError('Configure the Aurora provider credential')
    data=json.loads(args.output.read_text()) if args.output.exists() else dict(model=model,provider=base,repeats=args.repeats,
        acceptance='Every outcome/dependency/order/missing-input guard passes; fewer aggregate independent inspection rounds and no increase in aggregate model rounds.',
        binaries={p:hashlib.sha256((directory/(p+'.exe')).read_bytes()).hexdigest() for p in ['baseline','candidate']},runs=[])
    if data['model']!=model or data['provider']!=base or data['repeats']!=args.repeats:raise RuntimeError('Configuration changed; use a new report')
    for profile,digest in data['binaries'].items():
        if hashlib.sha256((directory/(profile+'.exe')).read_bytes()).hexdigest()!=digest:raise RuntimeError('Test binary changed; use a new report')
    existing={(r['case'],r['profile'],r['attempt']) for r in data['runs']}
    for attempt in range(1,args.repeats+1):
        for name in CASES:
            for profile in (['baseline','candidate'] if attempt%2 else ['candidate','baseline']):
                if (name,profile,attempt) in existing:continue
                row=measure(name,profile,attempt,directory,base,key,model,args.timeout)
                data['runs'].append(row);data['assessment']=assess(data)
                temporary=args.output.with_suffix('.tmp');temporary.write_text(json.dumps(data,indent=2));temporary.replace(args.output)
                print(json.dumps(row),flush=True)
    print('ASSESSMENT',json.dumps(data['assessment']),flush=True)


if __name__=='__main__':main()
