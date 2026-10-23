"""Test retaining original design-point precision for relative hint distances."""
import audit,json,concurrent.futures
base=(audit.CORE/'source/aurora/text/hinter.d').read_text();cases={}
for name,mirp in [('original-mdrp',False),('original-relative',True)]:
 h=base
 a=h.index('    void mdrp(');b=h.index('    void mirp(',a);block=h[a:b]
 old='''const orgDist = dualProject2(zone.points[point].orgX, zone.points[point].orgY,
            zone0Ref().points[rp0].orgX, zone0Ref().points[rp0].orgY);'''
 new='''const orgDist = refinedTextExperiment && naturalGrid && zoneSelect0 == 1 && zoneSelect1 == 1 ?
            roundedMulDiv(interpolationOriginalDistance(zone.points[point],zone0Ref().points[rp0],false),1,unitsPerEm) :
            dualProject2(zone.points[point].orgX,zone.points[point].orgY,zone0Ref().points[rp0].orgX,zone0Ref().points[rp0].orgY);'''
 assert old in block;h=h[:a]+block.replace(old,new)+h[b:]
 if mirp:
  a=h.index('    void mirp(');b=h.index('    // Do not quantize',a);block=h[a:b];assert old in block;h=h[:a]+block.replace(old,new)+h[b:]
 cases[name]=h
results={}
def run(name,h):
 exe=audit.compile(name,{'hinter':h});rows=audit.measure(name,exe,families=list(audit.diagnose.FONTS),sizes=list(audit.diagnose.SIZES));return name,rows
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
 for f in concurrent.futures.as_completed([pool.submit(run,n,h) for n,h in cases.items()]):
  n,rows=f.result();results[n]=rows;print(n,[(font,ch,size,next(r['error'] for r in rows if r['font']==font and r['size']==size and r['character']==ch)) for font,ch,size in [('consolas','2',17),('times','>',12),('courier','*',12),('courier','g',17),('arial','A',17)]],flush=True)
(audit.HERE/'original-distance-hypotheses.json').write_text(json.dumps(results,indent=2))
