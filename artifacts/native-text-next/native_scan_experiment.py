import sys
sys.path.insert(0,'artifacts/native-text-next')
from scan_experiments import scan_source
from diagnose import measure,variants,HERE
from signature_experiments import signature_variant
import json
s=scan_source(True).replace('(min(counts[x], total) * 255 + total / 2) / total','(min(counts[x], total) * 255 + total / 2 - 1) / total')
n,r=measure('native-scan',signature_variant(variants()['C'],spacing=False),None,s)
b=json.load(open(HERE/'cutin-experiments.json'))['comparisons']['C']
a={'improved':sum(x['monitor_error']<y['monitor_error'] for x,y in zip(r,b)),'regressed':sum(x['monitor_error']>y['monitor_error'] for x,y in zip(r,b)),'equal':sum(x['monitor_error']==y['monitor_error'] for x,y in zip(r,b)),'mean':sum(x['monitor_error'] for x in r)/144}
(HERE/'native-scan-experiment.json').write_text(json.dumps({'default_changed':False,'summary':a,'comparisons':r},indent=2));print(a)
