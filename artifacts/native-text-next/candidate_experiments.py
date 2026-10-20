import sys,json
sys.path.insert(0,'artifacts/native-text-next')
from scan_experiments import scan_source
from diagnose import measure,variants,HERE
from signature_experiments import signature_variant
from concurrent.futures import ThreadPoolExecutor,as_completed
h=signature_variant(variants()['C'],spacing=False)
s=scan_source(False);q=s.replace('(min(counts[x], total) * 255 + total / 2) / total','(min(counts[x], total) * 255 + total / 2 - 1) / total')
r={}
with ThreadPoolExecutor(max_workers=2) as p:
 for f in as_completed([p.submit(measure,n,h,None,t) for n,t in [('right-vacuform',s),('right-vacuform-round',q)]]):n,a=f.result();r[n]=a
b=json.load(open(HERE/'cutin-experiments.json'))['comparisons']['C'];summary={}
for n,a in r.items():summary[n]={'improved':sum(x['monitor_error']<y['monitor_error'] for x,y in zip(a,b)),'regressed':sum(x['monitor_error']>y['monitor_error'] for x,y in zip(a,b)),'equal':sum(x['monitor_error']==y['monitor_error'] for x,y in zip(a,b)),'mean':sum(x['monitor_error'] for x in a)/144}
(HERE/'candidate-experiments.json').write_text(json.dumps({'default_changed':False,'summary':summary,'comparisons':r},indent=2));print(json.dumps(summary,indent=2))
