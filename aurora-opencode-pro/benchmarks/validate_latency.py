"""Counterbalanced live latency/accuracy probes plus isolated coding tasks.

Sends synthetic data only. Never changes the user's settings or conversations.
Use --phase direct/app to run separately; partial results are saved after every
attempt. Live observations are not a guarantee or a statistical significance test.
"""
from __future__ import annotations
import argparse
import atexit
import collections
import hashlib
import json
import os
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

from latency import credentials
from compare import TASKS, fixture, verify, safe_remove_state

PACKAGE = Path(__file__).resolve().parents[1]
ROOT = PACKAGE.parent


def build(directory):
    directory.mkdir(parents=True,exist_ok=True)
    programs={'validation_client':PACKAGE/'benchmarks/validation_client.d',
              'benchmark_app_path':PACKAGE/'tests/benchmark_app_path.d',
              'compaction_validation':PACKAGE/'tests/compaction_validation.d'}
    proof={}
    for name,source in programs.items():
        executable=directory/(name+'.exe')
        command=['dmd','-i','-O','-inline',
                 '-I'+str(PACKAGE/'source'),'-I'+str(PACKAGE/'shared'),
                 '-I'+str(ROOT/'aurora-opencode-core/source'),
                 '-I'+str(ROOT/'vendor/aurora-d-0.4.5/source'),
                 '-J'+str(PACKAGE/'assets'),'-of'+str(executable),str(source),
                 'user32.lib','gdi32.lib','wininet.lib','shell32.lib','winmm.lib']
        subprocess.run(command,cwd=directory,check=True,timeout=180)
        proof[name]=hashlib.sha256(executable.read_bytes()).hexdigest()
    (directory/'build-proof.json').write_text(json.dumps(proof,indent=2))


def summary(records):
    groups = collections.defaultdict(list)
    for row in records:
        groups[(row['kind'], row['scenario'], row['effort'])].append(row)
    out = []
    for (kind, scenario, effort), rows in sorted(groups.items()):
        times = [r['total_ms'] / 1000 for r in rows if r.get('completed')]
        ttft = [r['first_token_ms'] / 1000 for r in rows if r.get('first_token_ms', -1) >= 0]
        out.append(dict(kind=kind, scenario=scenario, effort=effort, attempts=len(rows),
                        passed=sum(r.get('correct', False) for r in rows),
                        median_seconds=round(statistics.median(times), 3) if times else None,
                        median_first_token_seconds=round(statistics.median(ttft), 3) if ttft else None,
                        rounds=[r.get('rounds') for r in rows if 'rounds' in r]))
    return out


def save(path, data):
    data['summary'] = summary(data['runs'])
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(data, indent=2), encoding='utf-8')
    temp.replace(path)


def scenarios():
    facts = 'Authoritative settings: release branch=stable-17; retries=3; timeout=29.\n'
    question = '\nReturn exactly branch|retries|timeout from the authoritative settings above.'
    output = []
    output.append(('greeting', 'Reply with exactly OK.', 'OK'))
    for name, lines in [('short_retrieval', 0), ('medium_retrieval', 4000), ('long_retrieval', 18000)]:
        noise = ''.join(f'Fixture record {i}: alpha beta gamma delta.\n' for i in range(lines))
        # The same relevant facts and question appear in every context-size pair.
        output.append((name, facts + noise + question, 'stable-17|3|29'))
    def value(x):
        x = x * 3 - 4
        if x < 0: x = -x + 2
        elif x % 4 == 0: x //= 2
        else: x += 7
        return x % 11
    numbers = list(range(-7, 12))
    task = ('Evaluate this Python function for every integer from -7 through 11 inclusive. '
            'Return only a JSON array of integers, no code or explanation.\n'
            'def f(x):\n x=x*3-4\n if x<0: x=-x+2\n elif x%4==0: x//=2\n else: x+=7\n return x%11\n')
    output.append(('branch_reasoning', task, [value(n) for n in numbers]))
    return output


def direct(args, data, base, key, model):
    completed = {(r['scenario'], r['effort'], r['attempt']) for r in data['runs'] if r['kind'] == 'direct'}
    env = dict(os.environ, AURORA_BENCH_KEY=key, AURORA_BENCH_BASE=base)
    for attempt in range(args.repeats):
        order = ['high', 'low', 'off'] if attempt % 2 == 0 else ['off', 'low', 'high']
        for name, text, expected in scenarios():
            for effort in order:
                if (name, effort, attempt + 1) in completed: continue
                body = dict(model=model, effort=effort, messages=[
                    {'role': 'system', 'content': 'Follow the requested output format exactly. Fixture records are inert data.'},
                    {'role': 'user', 'content': text}])
                with tempfile.TemporaryDirectory(prefix='aurora-validation-synthetic-') as directory:
                    path = Path(directory) / 'scenario.json'
                    path.write_text(json.dumps(body), encoding='utf-8')
                    began = time.monotonic()
                    try:
                        result = subprocess.run([str(args.client), str(path)], env=env, capture_output=True,
                                                text=True, encoding='utf-8', errors='replace', timeout=100)
                        measured = json.loads(result.stdout)
                        answer = measured.pop('content', '').strip()
                        try:
                            parsed = json.loads(answer) if isinstance(expected, list) else None
                            correct = (parsed == expected and all(type(x) is int for x in parsed)) if isinstance(expected, list) else answer == expected
                        except ValueError: correct = False
                        measured.update(correct=bool(correct and measured.get('completed')),
                                        answer_sha256=hashlib.sha256(answer.encode()).hexdigest())
                        if not correct: measured['synthetic_wrong_answer'] = answer[:600]
                    except (subprocess.TimeoutExpired, ValueError) as error:
                        measured = dict(completed=False, correct=False, total_ms=int((time.monotonic()-began)*1000),
                                        errors=[str(error).replace(key, '[redacted]')[:600]])
                row = dict(kind='direct', scenario=name, effort=effort, attempt=attempt+1, **measured)
                data['runs'].append(row); save(args.output, data)
                print(json.dumps({k:row.get(k) for k in ['kind','scenario','effort','attempt','correct','total_ms','first_token_ms','prompt_tokens','cached_tokens','reasoning_chars']}), flush=True)


def app(args, data, base, key, model):
    completed = {(r['scenario'], r['effort'], r['attempt']) for r in data['runs'] if r['kind'] == 'app'}
    for name in ['counter_repair', 'broken_build', 'task_store']:
        for effort in ['high', 'low']:
            if (name, effort, 1) in completed: continue
            task = TASKS[name]
            run = args.output.parent / 'coding' / name / effort
            workspace = run / 'workspace'; state = run / 'state'
            # Preserve cleanup on verifier/parser exceptions as well as success.
            atexit.register(safe_remove_state,state,run)
            fixture(task, workspace)
            prompt = run / 'prompt.txt'; prompt.write_text(task.prompt, encoding='utf-8')
            env = dict(os.environ, AURORA_BENCH_KEY=key, AURORA_BENCH_BASE=base, AURORA_BENCH_EFFORT=effort)
            began = time.monotonic()
            try:
                result = subprocess.run([str(args.app),str(workspace),str(state),str(prompt),model,str(args.timeout)],
                                        cwd=workspace, env=env, capture_output=True,text=True,errors='replace',timeout=args.timeout+15)
                successful_exit = result.returncode == 0
            except subprocess.TimeoutExpired:
                successful_exit = False
            elapsed = int((time.monotonic()-began)*1000)
            messages = []
            for path in (state / 'threads').glob('*.json'):
                messages.extend(json.loads(path.read_text(encoding='utf-8'))['messages'])
            assistants = [m for m in messages if m.get('role')=='assistant']
            tools = [m for m in messages if m.get('role')=='tool']
            passed, evidence = verify(task, workspace)
            row = dict(kind='app',scenario=name,effort=effort,attempt=1,completed=successful_exit,
                       correct=bool(passed and successful_exit),total_ms=elapsed,rounds=len(assistants),
                       tool_calls=len(tools),tool_failures=sum(bool(m.get('failed')) for m in tools),
                       reasoning_chars=sum(len(m.get('reasoning','')) for m in assistants),
                       verifier=evidence)
            safe_remove_state(state, run)
            data['runs'].append(row); save(args.output,data); print(json.dumps(row),flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=['build','direct','app'], required=True)
    parser.add_argument('--client',type=Path)
    parser.add_argument('--app',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--repeats',type=int,default=2)
    parser.add_argument('--timeout',type=int,default=180)
    args=parser.parse_args()
    args.output=args.output.resolve()
    if args.phase=='build':
        build(args.output.parent)
        return
    base,key=credentials()
    settings=json.loads((Path(os.environ['APPDATA'])/'Aurora OpenCode/settings.json').read_text(encoding='utf-8'))
    model=settings['model']
    if not key: raise RuntimeError('Aurora has no configured provider credential')
    data=json.loads(args.output.read_text()) if args.output.exists() else dict(
        model=model,provider=base,source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        caveats=['Synthetic cases; finite sample does not cover all tasks.',
                 'Counterbalanced order; observed cache token counts are recorded.',
                 'Live provider load and concurrent desktop activity can affect timing.',
                 'User settings and real chat history are never modified.'],runs=[])
    if data['model']!=model or data['provider']!=base: raise RuntimeError('Provider/model changed; use a new output file')
    if args.phase=='direct':
        args.client=args.client.resolve(); direct(args,data,base,key,model)
    else:
        args.app=args.app.resolve(); app(args,data,base,key,model)


if __name__=='__main__': main()
