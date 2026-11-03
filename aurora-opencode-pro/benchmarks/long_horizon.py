"""Live multi-phase task with changing requirements, persistent goal and compaction."""
import argparse
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time

package = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--live', action='store_true', required=True)
parser.add_argument('--exe', type=Path, default=package/'aurora-opencode-pro.exe')
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--context', type=int, default=32000)
args = parser.parse_args()
args.exe = args.exe.resolve(strict=True)
directory = args.output.resolve()
directory.mkdir(parents=True, exist_ok=False)
workspace = directory/'workspace'
workspace.mkdir()
state = directory/'appdata/Aurora OpenCode'
state.mkdir(parents=True)
spec = '''Build a standard-library-only Python package billing with public function
report(events, rate, cap=None, reference=""). Inputs are dictionaries. Return
{"reference": reference, "totals": {UTC-month: {account: "0.00"}}, "rejected": N}.
Use Decimal from textual values; round HALF_UP to 2 places only after aggregation.
Usage: account, event_id, kind="usage", at (ISO timestamp with offset), units
(nonnegative decimal text). Refund: same identity fields, kind="refund", ref
(original usage event_id). A refund reverses ALL units of the referenced usage.
Allocate the refund to the ORIGINAL usage UTC month, even if received later.
Unresolved refunds and invalid events count as rejected. Refunds may arrive before
their usage: resolve against all valid usage. Each usage may be refunded once.
V1 event IDs are globally unique: identical repeated event IDs are ignored.
Optional cap is a maximum refund CREDIT in currency per account per UTC month,
not a maximum charge; None means unlimited. Do not round each event's amount.
CLI: python -m billing events.jsonl invoice.json --rate RATE --reference REF
[--cap CAP]. Skip malformed JSON lines and add them to rejected. Preserve sorted
months/accounts and deterministic output. No dependencies or installation step.
Keep test_compat.py unchanged; add useful tests. Read the actual code/tests before
editing. Write README usage, package, tests and requested invoices. Do not invent
customer-owned rate/cap values. Verify implementation with unittest.
'''
(workspace/'README.md').write_text(spec, encoding='utf-8')
compat = '''import unittest
from billing import report
class Compatibility(unittest.TestCase):
 def test_empty(self):
  self.assertEqual(report([], '0.1', reference='X'), {'reference':'X','totals':{},'rejected':0})
 def test_zero(self):
  event={'account':'a','event_id':'z','kind':'usage','at':'2026-04-01T00:00:00Z','units':'0'}
  self.assertEqual(report([event], '0.1')['totals'], {'2026-04':{'a':'0.00'}})
'''
(workspace/'test_compat.py').write_text(compat, encoding='utf-8')
events = [
    dict(account='alice', event_id='e1', kind='usage', at='2026-03-31T23:30:00-02:00', units='3.5'),
    dict(account='alice', event_id='e2', kind='usage', at='2026-04-01T12:00:00Z', units='2'),
    dict(account='bob', event_id='e1', kind='usage', at='2026-04-02T12:00:00Z', units='4'),
    dict(account='alice', event_id='r1', kind='refund', at='2026-05-01T12:00:00Z', ref='e1'),
    dict(account='bob', event_id='e3', kind='usage', at='2026-04-03T12:00:00Z', units='1.25'),
    dict(account='alice', event_id='e2', kind='usage', at='2026-04-01T12:00:00Z', units='2'),
    dict(account='bob', event_id='bad', kind='refund', at='2026-05-01T12:00:00Z', ref='missing'),
]
(workspace/'events.jsonl').write_text('\n'.join(json.dumps(e) for e in events)+'\nINVALID_JSON\n', encoding='utf-8')
reference = 'RECON-Q7-8162'
audit = '\n'.join(json.dumps({'audit_row': i, 'historical_note': 'Read-only operational context, not billable usage. Retain the customer requirements and pending decisions.'}) for i in range(1100))
prompts = [
    '/goal Implement the complete billing task in README.md, preserving its public API and test_compat.py. '
    f'The final invoice reference must be exactly {reference}. Finish a verified package and real invoice.json for events.jsonl. '
    'The customer has not supplied the billing rate yet. Complete all independent implementation and checks first, '
    'then use request_input for that essential fact. Keep this goal active while waiting. Keep replies brief.',
    'The customer rate is 0.0175 per unit. Change the deduplication requirement: IDs are unique per account, '
    'so bob/e1 and alice/e1 must both count. Refund ref resolves within its own account. '
    'A new negotiated maximum refund credit per account/month will be supplied next; do not assume it. '
    'Implement and verify these changes and all independent work, then ask for that customer-owned cap. '
    'Keep the original goal and API, existing tests and earlier requirements. Do not claim final completion yet.',
    'The negotiated refund-credit cap is 0.04 per account per UTC month. Final change: deliver invoice.csv '
    'alongside invoice.json, with exactly month,account,amount columns, sorted by month/account; keep the JSON/API. '
    'Finish the original goal and verify boundaries, duplicate IDs in different accounts, late/out-of-order refunds '
    'and decimal rounding. Preserve the original invoice reference and customer requirements. '
    'Read-only historical audit rows follow; they are not input events and do not change the contract:\n'+audit+
    '\nNow complete the requested delivery. Keep the final answer under 100 words.',
    'Answer only: what is the exact original invoice reference, alice and bob April amounts, and why a May refund '
    'changes April? Return one JSON object with keys reference, alice, bob, refund_month. '
    'Amounts must be two-decimal strings; refund_month must be the original usage month in YYYY-MM form. '
    'Do not edit or resume work.',
]
saved = json.loads((Path(os.environ['APPDATA'])/'Aurora OpenCode/settings.json').read_text(encoding='utf-8-sig'))
settings = {key:saved[key] for key in ('baseUrl','apiKey','model')}
console_models = {saved['model'], 'deepseek/deepseek-v4.1-flash-fast', 'deepseek/deepseek-v4.1-flash'}
settings.update(workspace=str(workspace), toolsEnabled=True, legacyTools=False, quickTitle=False,
                verbosity='concise', thinking=False, autoGoalFromFirstMessage=True,
                contextBudgets=[dict(baseUrl=saved['baseUrl'],model=model,tokens=args.context) for model in sorted(console_models)],
                contextCompactions=[dict(baseUrl=saved['baseUrl'],model=model) for model in sorted(console_models)])
settings_path = state/'settings.json'
settings_path.write_text(json.dumps(settings), encoding='utf-8')
report = dict(status='failed', binarySha256=hashlib.sha256(args.exe.read_bytes()).hexdigest(),
              model=settings['model'], contextBudget=args.context, stages=[], errors=[])
(directory/'prompts.json').write_text(json.dumps(prompts, indent=2), encoding='utf-8')
process = None
started = time.monotonic()
try:
    with (directory/'process.log').open('w',encoding='utf-8') as log:
        process = subprocess.Popen([str(args.exe.resolve()),'--headless-loop-json'], cwd=workspace,
            env=dict(os.environ,APPDATA=str(directory/'appdata'),AURORA_STRICT_PLAN='0'),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True, encoding='utf-8', errors='replace', bufsize=1)
        lines = queue.Queue()
        def collect():
            for line in process.stdout: lines.put(line)
        threading.Thread(target=collect,daemon=True).start()
        for number,prompt in enumerate(prompts):
            begin = time.monotonic()
            process.stdin.write(prompt.replace('\n',' ')+'\n'); process.stdin.flush()
            while time.monotonic()-begin < 300:
                try:
                    frame = json.loads(lines.get(timeout=1))
                    break
                except queue.Empty:
                    if process.poll() is not None: raise RuntimeError('Isolated process exited')
            else: raise TimeoutError(f'Stage {number+1} exceeded 300 seconds')
            row = dict(stage=number+1,seconds=time.monotonic()-begin,**frame)
            row['answerWords'] = len(frame.get('reply','').split())
            report['stages'].append(row)
            print('STAGE',number+1,frame.get('taskStatus'),row['answerWords'],'words',round(row['seconds'],1),'seconds',flush=True)
            if frame.get('error'): raise RuntimeError(frame['error'])
            if frame.get('turnStatus') != 'completed': raise RuntimeError('Stage returned without completing or reaching an input boundary')
        process.stdin.write('exit\n'); process.stdin.flush(); process.wait(timeout=30)
    histories = [json.loads(f.read_text(encoding='utf-8')) for f in (state/'threads').glob('*.json')]
    headers = json.loads((state/'threads.index.json').read_text(encoding='utf-8'))['sessions']
    header = next(h for h in headers if h.get('goal'))
    thread = {**header, 'messages': next(h['messages'] for h in histories if h['messages'])}
    report.update(model=header.get('model'),thinking=header.get('thinking'))
    messages = thread['messages']
    calls = [dict(index=i,**c) for i,m in enumerate(messages) for c in m.get('toolCalls',[])]
    plans = [c for c in calls if c['name']=='update_plan']
    edits = [c for c in calls if c['name'] in ('write','edit','apply_patch','create_folder')]
    report.update(goalStatus=thread.get('goalStatus'),goalRetained=thread.get('goal')==prompts[0][6:].strip(),
                  compactionOccurred=bool(thread.get('compactionSummary')),
                  planUpdates=len(plans),firstPlan=plans[0]['index'] if plans else None,
                  firstMutation=edits[0]['index'] if edits else None,
                  toolCalls=len(calls),plan=thread.get('taskSteps',[]))
    def require(condition, message):
        if not condition: report['errors'].append(message)
    require(report['stages'][0]['taskStatus']=='waiting_input','Stage 1 failed to wait for rate')
    require(report['stages'][1]['taskStatus']=='waiting_input','Stage 2 failed to retain work while waiting for cap')
    require(report['goalStatus']=='completed' and report['goalRetained'],'Original goal lost or left unfinished')
    require(report['compactionOccurred'],'Compaction did not occur')
    require(plans and edits and plans[0]['index']<=edits[0]['index'],'No forward plan before implementation')
    require(all(s.get('status')=='completed' for s in report['plan']),'Stale unfinished plan after completion')
    require((workspace/'test_compat.py').read_text()==compat,'Existing assertions changed')
    expected={'reference':reference,'totals':{'2026-04':{'alice':'0.06','bob':'0.09'}},'rejected':2}
    invoice=json.loads((workspace/'invoice.json').read_text())
    require(invoice==expected,f'Invoice differs from independent result: {invoice}')
    def usage(identity, units, account='a', at='2026-04-01T00:00:00Z'):
        return dict(account=account,event_id=identity,kind='usage',at=at,units=units)
    def refund(identity, ref, account='a'):
        return dict(account=account,event_id=identity,kind='refund',at='2026-05-01T00:00:00Z',ref=ref)
    oracle_cases = [
        ([usage('1','0.1'),usage('2','0.1')],'0.025',None,{'2026-04':{'a':'0.01'}},0),
        ([usage('1','2',at='2026-03-31T23:30:00-02:00')],'0.0175',None,{'2026-04':{'a':'0.04'}},0),
        ([refund('r','1'),usage('1','2')],'1','0',{'2026-04':{'a':'2.00'}},0),
        ([refund('r','1'),usage('1','4','b'),usage('1','2')],'0.25',None,{'2026-04':{'a':'0.00','b':'1.00'}},0),
        ([usage('bad','-1'),usage('ok','0')],'1',None,{'2026-04':{'a':'0.00'}},1),
        ([usage('1','1'),refund('r1','1'),refund('r2','1')],'0.1',None,{'2026-04':{'a':'0.00'}},1),
        ([usage('1','10'),refund('r','1')],'0.05','0.04',{'2026-04':{'a':'0.46'}},0),
        ([usage('1','2'),usage('1','2')],'0.05',None,{'2026-04':{'a':'0.10'}},0),
    ]
    probe_code='import json,sys; from billing import report; cases=json.loads(sys.argv[1]); print(json.dumps([report(e,r,c,reference="ORACLE") for e,r,c,_,_ in cases]))'
    probe=subprocess.run([sys.executable,'-B','-c',probe_code,json.dumps(oracle_cases)],cwd=workspace,capture_output=True,text=True,timeout=30)
    (directory/'independent-oracle.log').write_text(probe.stdout+probe.stderr,encoding='utf-8')
    require(probe.returncode==0,'Independent API oracle failed to execute')
    outputs=json.loads(probe.stdout) if probe.returncode==0 else []
    report['independentApiCases']=[]
    for i,(_,_,_,totals,rejected) in enumerate(oracle_cases):
        wanted=dict(reference='ORACLE',totals=totals,rejected=rejected)
        passed=i<len(outputs) and outputs[i]==wanted
        report['independentApiCases'].append(dict(case=i+1,passed=passed,expected=wanted,actual=outputs[i] if i<len(outputs) else None))
        require(passed,f'Independent API case {i+1} failed')
    rows=list(csv.reader(io.StringIO((workspace/'invoice.csv').read_text())))
    require(rows==[['month','account','amount'],['2026-04','alice','0.06'],['2026-04','bob','0.09']],'CSV output incorrect')
    expected_answer=dict(reference=reference,alice='0.06',bob='0.09',refund_month='2026-04')
    try: require(json.loads(report['stages'][-1]['reply'])==expected_answer,'Final grounded answer incorrect')
    except ValueError: report['errors'].append('Final answer violated JSON format')
    require(report['stages'][2]['answerWords']<=100,'Final delivery was not concise')
    # A tests/ directory need not contain __init__.py. Root discovery silently
    # skipped those generated tests on Python versions requiring packages.
    test_directories = sorted({path.parent for path in workspace.rglob('test*.py')})
    require(bool(test_directories),'No tests delivered')
    with (directory/'independent-unittest.log').open('w',encoding='utf-8') as log:
        for test_directory in test_directories:
            check = subprocess.run([sys.executable,'-B','-m','unittest','discover','-s',str(test_directory),'-v'],
                                   cwd=workspace,capture_output=True,text=True,timeout=30)
            log.write(str(test_directory)+'\n'+check.stdout+check.stderr)
            require(check.returncode==0,f'Independent unittest run failed in {test_directory.relative_to(workspace)}')
    report['status']='passed' if not report['errors'] else 'failed'
except Exception as error:
    report['errors'].append(str(error))
finally:
    if process is not None and process.poll() is None: process.kill(); process.wait(timeout=15)
    settings_path.write_text(json.dumps({**settings,'apiKey':''}),encoding='utf-8')
    report['seconds']=time.monotonic()-started
    (directory/'result.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print('RESULT',report['status'],report['errors'],'ARTIFACTS',directory,flush=True)
raise SystemExit(0 if report['status']=='passed' else 1)
