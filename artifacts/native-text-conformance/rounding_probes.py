import sys,json,concurrent.futures
sys.path.insert(0,'artifacts/native-text-conformance');import audit,diagonal_probes
h=diagonal_probes.dual_vectors((audit.CORE/'source/aurora/text/hinter.d').read_text())
cases={}
for name,condition in [('freedom-x','freeVectorX != 0'),('projection-x','projVectorX != 0'),('axis-freedom-x','freeVectorY == 0'),('vector-ratio','freeVectorY == 0')]:
 c=h.replace('naturalGrid && glyphProgram && projVectorY == 0','naturalGrid && glyphProgram && '+condition)
 if name=='vector-ratio':
  c=c.replace('''return roundPhysicalDistance(distance * 16, compensation * 16) / 16;''','''{
                const multiplier = maxInt(1, cast(int) (16.0 * (projVectorX < 0 ? -projVectorX : projVectorX) / 0x4000));
                return roundPhysicalDistance(distance * multiplier, compensation * multiplier) / multiplier;
            }''')
 cases[name]=c
results={}
def run(name,h):
 exe=audit.compile(name,{'hinter':h});return name,audit.measure(name,exe,families=list(audit.diagnose.FONTS),sizes=[12,13,17,26])
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 for f in concurrent.futures.as_completed([pool.submit(run,k,v) for k,v in cases.items()]):
  n,r=f.result();results[n]=r
  print(n,[(f,ch,size,next(x['error'] for x in r if x['font']==f and x['size']==size and x['character']==ch)) for f,ch,size in [('tahoma','^',13),('verdana','>',17),('times','>',12),('courier','*',12),('arial','A',17)]])
(audit.HERE/'diagonal-rounding-hypotheses.json').write_text(json.dumps(results,indent=2))
