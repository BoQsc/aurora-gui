import sys,json
sys.path.insert(0,'artifacts/native-text-next')
from diagnose import variants,measure,HERE
from signature_experiments import signature_variant
from concurrent.futures import ThreadPoolExecutor,as_completed
s=variants()['both-cutin']
s=s.replace('(original >= 32 || original <= -32)', '(original != 0)')
marker='''        long distance = (opcode & 4) != 0 ? roundDistance(cvtDist, 0) : roundNone(cvtDist, 0);'''
clamp='''
        if (naturalGrid && glyphProgram && projVectorY == 0 && (instructControl & 4) == 0)
        {
            if (distance >= 0 && distance < 16) distance = 16;
            else if (distance < 0 && distance > -16) distance = -16;
        }
'''
assert marker in s
s=s.replace(marker,marker+clamp)
marker='''                const cur = ctx.project(cast(int) zone.points[point].curX,
                    cast(int) zone.points[point].curY);
                const rpProj = ctx.project(cast(int) ctx.zone0Ref().points[ctx.rp0].curX,
                    cast(int) ctx.zone0Ref().points[ctx.rp0].curY);
                ctx.movePoint(ctx.zone1Ref(), point, distance - (cur - rpProj));'''
insert='''                if (ctx.naturalGrid && ctx.glyphProgram && ctx.projVectorY == 0 && (ctx.instructControl & 4) == 0)
                {
                    if (distance >= 0 && distance < 16) distance = 16;
                    else if (distance < 0 && distance > -16) distance = -16;
                }
'''
assert marker in s
s=s.replace(marker,insert+marker)
cases={'cutin-minimum':s,'vacuform-minimum':signature_variant(s,spacing=False)}
r={}
with ThreadPoolExecutor(max_workers=2) as p:
 for f in as_completed([p.submit(measure,n,s) for n,s in cases.items()]):n,rows=f.result();r[n]=rows
base=json.load(open(HERE/'cutin-experiments.json'))['comparisons']['C'];summary={}
for n,rows in r.items():summary[n]={'improved':sum(a['monitor_error']<b['monitor_error'] for a,b in zip(rows,base)),'regressed':sum(a['monitor_error']>b['monitor_error'] for a,b in zip(rows,base)),'equal':sum(a['monitor_error']==b['monitor_error'] for a,b in zip(rows,base)),'mean':sum(a['monitor_error'] for a in rows)/len(rows)}
(HERE/'minimum-experiments.json').write_text(json.dumps({'default_changed':False,'summary':summary,'comparisons':r},indent=2))
print(json.dumps(summary,indent=2))
