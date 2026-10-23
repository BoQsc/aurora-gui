import sys,json,concurrent.futures
sys.path.insert(0,'artifacts/native-text-conformance');import audit,diagonal_probes
h=diagonal_probes.dual_vectors((audit.CORE/'source/aurora/text/hinter.d').read_text())
a=h.index('            case 0x06: case 0x07:');b=h.index('            case 0x0A:',a);block=h[a:b]
for i,zone in [(1,'zone2Ref()'),(2,'zone1Ref()')]:
 for axis in ['X','Y']:
  block=block.replace(f'ctx.{zone}.points[p{i}].org{axis}',f'(ctx.refinedTextExperiment ? ctx.{zone}.points[p{i}].cur{axis} : ctx.{zone}.points[p{i}].org{axis})')
h=h[:a]+block+h[b:]
cases={'current-line-vectors':h,
'current-line-projection-x':h.replace('naturalGrid && glyphProgram && projVectorY == 0','naturalGrid && glyphProgram && (projVectorY == 0 || (projVectorX != 0 && freeVectorX == 0))')}
def run(n,h):
 exe=audit.compile(n,{'hinter':h});return n,audit.measure(n,exe,families=list(audit.diagnose.FONTS),sizes=list(audit.diagnose.SIZES))
results={}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
 for f in concurrent.futures.as_completed([pool.submit(run,k,v) for k,v in cases.items()]):
  n,r=f.result();results[n]=r
  print(n,[(f,ch,size,next(x['error'] for x in r if x['font']==f and x['size']==size and x['character']==ch)) for f,ch,size in [('tahoma','^',13),('verdana','>',17),('times','>',12),('courier','*',12),('arial','A',17)]])
(audit.HERE/'current-vector-hypotheses.json').write_text(json.dumps(results,indent=2))
