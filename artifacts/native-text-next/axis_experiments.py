import sys,json
sys.path.insert(0,'artifacts/native-text-next')
from diagnose import variants,measure,HERE
from signature_experiments import signature_variant
from concurrent.futures import ThreadPoolExecutor,as_completed
source=variants()['mirp-cutin']
x=source.replace('(naturalGrid && glyphProgram && (instructControl & 4) == 0)) &&','(naturalGrid && glyphProgram && projVectorY == 0 && (instructControl & 4) == 0)) &&')
y=source.replace('(naturalGrid && glyphProgram && (instructControl & 4) == 0)) &&','(naturalGrid && glyphProgram && projVectorX == 0 && (instructControl & 4) == 0)) &&')
assert x!=source and y!=source
cases={'mirp-x':x,'mirp-y':y,'vacuform-mirp-x':signature_variant(x,spacing=False)}
r={}
with ThreadPoolExecutor(max_workers=3) as pool:
 for f in as_completed([pool.submit(measure,n,s) for n,s in cases.items()]):
  n,rows=f.result();r[n]=rows
base=json.load(open(HERE/'cutin-experiments.json'))['comparisons']['C'];summary={}
for n,rows in r.items():summary[n]={'improved':sum(a['monitor_error']<b['monitor_error'] for a,b in zip(rows,base)),'regressed':sum(a['monitor_error']>b['monitor_error'] for a,b in zip(rows,base)),'equal':sum(a['monitor_error']==b['monitor_error'] for a,b in zip(rows,base)),'mean':sum(a['monitor_error'] for a in rows)/len(rows)}
(HERE/'axis-experiments.json').write_text(json.dumps({'default_changed':False,'summary':summary,'comparisons':r},indent=2))
print(json.dumps(summary,indent=2))
