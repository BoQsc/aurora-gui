import sys,json,concurrent.futures
sys.path.insert(0,'artifacts/native-text-conformance');import audit
base=(audit.BUILD/'current-line-vectors/source/aurora/text/hinter.d').read_text();cases={}
for label,cut,rounding in [('pv-both','projVectorX != 0','projVectorX != 0'),('free-both','freeVectorX != 0','freeVectorX != 0'),('pv-cut-y-round','projVectorX != 0','(projVectorY == 0 || (projVectorX != 0 && freeVectorX == 0))'),('free-cut-pv-round','freeVectorX != 0','projVectorX != 0')]:
 h=base.replace('return naturalGrid && projVectorY == 0 ? controlValueCutIn / 16 : controlValueCutIn;',f'return naturalGrid && ({cut}) ? controlValueCutIn / 16 : controlValueCutIn;').replace('naturalGrid && glyphProgram && projVectorY == 0','naturalGrid && glyphProgram && '+rounding)
 cases[label]=h
results={}
def run(n,h):
 exe=audit.compile(n,{'hinter':h});return n,audit.measure(n,exe,families=list(audit.diagnose.FONTS),sizes=[12,13,17,26])
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 for f in concurrent.futures.as_completed([pool.submit(run,k,v) for k,v in cases.items()]):
  n,r=f.result();results[n]=r
  print(n,[(f,ch,size,next(x['error'] for x in r if x['font']==f and x['size']==size and x['character']==ch)) for f,ch,size in [('tahoma','^',13),('verdana','>',17),('times','>',12),('courier','*',12),('arial','A',17)]])
(audit.HERE/'combined-vector-hypotheses.json').write_text(json.dumps(results,indent=2))
