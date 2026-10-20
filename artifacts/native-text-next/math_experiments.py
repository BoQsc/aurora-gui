import sys
sys.path.insert(0,'artifacts/native-text-next')
from diagnose import variants,measure,HERE
from signature_experiments import signature_variant
from concurrent.futures import ThreadPoolExecutor,as_completed
import json
src=variants()['C']
rounding=src.replace('return cast(int) (cast(long) a * b / c);','''const product = a * b;
    const negative = (product < 0) != (c < 0);
    const numerator = product < 0 ? -product : product;
    const denominator = c < 0 ? -c : c;
    const result = (numerator + denominator / 2) / denominator;
    return negative ? -result : result;''')
def orus(s):
 s=s.replace('Pt(x, y, x, y, x, y, false, false, input.onCurve[i])','Pt(x, y, x, y, input.xs[i], input.ys[i], false, false, input.onCurve[i])')
 for n,x,y in [(1,'xMin - input.lsb','0'),(2,'xMin - input.lsb + input.advance','0'),(3,'0','yMax + input.tsb'),(4,'0','yMax + input.tsb - input.vadvance')]:
  old=f'Pt(pp{n}x, 0, pp{n}x, 0, pp{n}x, 0' if n<3 else f'Pt(0, pp{n}y, 0, pp{n}y, 0, pp{n}y'
  new=f'Pt(pp{n}x, 0, pp{n}x, 0, {x}, {y}' if n<3 else f'Pt(0, pp{n}y, 0, pp{n}y, {x}, {y}'
  assert old in s;s=s.replace(old,new)
 s=s.replace('newDist = oldRange != 0 ? mulDiv(orgDist, curRange, oldRange) : orgDist;','newDist = oldRange != 0 ? mulDiv(orgDist, curRange, oldRange) : twilight ? orgDist : ctx.scaleDesign(orgDist);')
 return s
cases={'rounded-math':rounding,'unscaled-original':orus(src),'original-rounded':orus(rounding),'original-signatures':signature_variant(orus(rounding),spacing=False)}
r={}
with ThreadPoolExecutor(max_workers=3) as p:
 for f in as_completed([p.submit(measure,n,s) for n,s in cases.items()]):
  n,rows=f.result();r[n]=rows
base=json.load(open(HERE/'cutin-experiments.json'))['comparisons']['C'];summary={}
for n,rows in r.items():
 summary[n]={'improved':sum(a['monitor_error']<b['monitor_error'] for a,b in zip(rows,base)),'regressed':sum(a['monitor_error']>b['monitor_error'] for a,b in zip(rows,base)),'mean':sum(a['monitor_error'] for a in rows)/len(rows)}
(HERE/'math-experiments.json').write_text(json.dumps({'default_changed':False,'summary':summary,'comparisons':r},indent=2))
print(json.dumps(summary,indent=2))
