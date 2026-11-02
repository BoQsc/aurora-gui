"""Small live held-out code/unknown-fact checks through the actual desktop root."""
import argparse, hashlib, json, os, queue, subprocess, tempfile, threading, time
from pathlib import Path
package = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--live', action='store_true', required=True)
parser.add_argument('--exe', type=Path, default=package/'aurora-opencode-pro.exe')
parser.add_argument('--output', type=Path, required=True)
a = parser.parse_args()
d = a.output.resolve(); d.mkdir(parents=True, exist_ok=True)
w = d/'workspace'; w.mkdir()
s = d/'appdata/Aurora OpenCode'; s.mkdir(parents=True)
source = ("def fee(weight, priority=False):\n    amount = 4 if weight <= 2 else 4 + 3 * (weight - 2)\n    return amount * 2 if priority else amount\n\n"
          "def allowed(role, locked):\n    return role == 'owner' or role == 'editor' and not locked\n\n"
          "def unique(values):\n    return list(dict.fromkeys(values))\n")
(w/'specimen.py').write_text(source)
(w/'shipment.txt').write_text('Shipment SH-47: destination Riga. Status: dispatched. Arrival time not recorded.\n')
saved=json.loads((Path(os.environ['APPDATA'])/'Aurora OpenCode/settings.json').read_text(encoding='utf-8-sig'))
settings={k:saved[k] for k in ('baseUrl','apiKey','model')}
settings.update(workspace=str(w), toolsEnabled=True, legacyTools=False, quickTitle=False, verbosity='concise', thinking=False)
settings_path=s/'settings.json'; settings_path.write_text(json.dumps(settings))
cases=[('branch', 'Read specimen.py. What does fee return for (2, False), (3, False), and (3, True)? Return one JSON object with key values, an array in that order.', {'values':[4,7,14]}),
       ('precedence', 'In specimen.py, what does allowed return for (owner, True) and (editor, True)? Return one JSON object with key values, an array of booleans in that order.', {'values':[True,False]}),
       ('ordering', 'What does unique([3,1,3,2,1]) return in specimen.py? Return one JSON object with key values.', {'values':[3,1,2]}),
       ('unknown', 'Read shipment.txt. What exact time did shipment SH-47 arrive? Use null if unavailable. Return one JSON object with key arrival_time.', {'arrival_time':None})]
q=queue.Queue(); report={'binarySha256':hashlib.sha256(a.exe.read_bytes()).hexdigest(), 'model':settings['model'], 'cases':[], 'status':'failed'}
def equivalent(actual, expected):
 if isinstance(expected, bool) or expected is None: return type(actual) is type(expected) and actual == expected
 if isinstance(expected, dict): return isinstance(actual, dict) and actual.keys() == expected.keys() and all(equivalent(actual[k], v) for k,v in expected.items())
 if isinstance(expected, list): return isinstance(actual, list) and len(actual) == len(expected) and all(equivalent(x,y) for x,y in zip(actual,expected))
 return not isinstance(actual, bool) and actual == expected
process=None
try:
 with (d/'process.log').open('w',encoding='utf-8') as log:
  process=subprocess.Popen([str(a.exe.resolve()),'--headless-loop-json'],cwd=w,env=dict(os.environ,APPDATA=str(d/'appdata'),AURORA_STRICT_PLAN='0'),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True,encoding='utf-8',errors='replace',bufsize=1)
  def collect():
   for line in process.stdout: q.put(line)
  threading.Thread(target=collect,daemon=True).start()
  for name,prompt,expected in cases:
   start=time.monotonic(); process.stdin.write(prompt+'\n'); process.stdin.flush()
   until=start+120
   while True:
    if time.monotonic()>until: raise TimeoutError(name)
    try:
     frame=json.loads(q.get(timeout=1)); break
    except queue.Empty:
     if process.poll() is not None: raise RuntimeError('Evaluation process exited')
   response=frame.get('reply',''); parsed=None
   try: parsed=json.loads(response)
   except ValueError: pass
   passed=equivalent(parsed,expected) and not frame.get('error') and frame.get('turnStatus')=='completed' and (w/'specimen.py').read_text()==source
   report['cases'].append(dict(name=name,prompt=prompt,expected=expected,response=response,passed=passed,seconds=time.monotonic()-start))
   print(name,'PASS' if passed else 'FAIL',flush=True)
  process.stdin.write('exit\n'); process.stdin.flush(); process.wait(timeout=30)
  report['status']='passed' if all(c['passed'] for c in report['cases']) and process.returncode==0 else 'failed'
finally:
 if process is not None and process.poll() is None: process.kill(); process.wait(timeout=10)
 settings_path.write_text(json.dumps({**settings,'apiKey':''}))
 (d/'result.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
 print('ARTIFACTS',d,flush=True)
raise SystemExit(0 if report['status']=='passed' else 1)
