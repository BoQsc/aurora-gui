import sys,json,concurrent.futures
sys.path.insert(0,'artifacts/native-text-conformance');import audit
h=(audit.CORE/'source/aurora/text/hinter.d').read_text()
cases={}
for n,condition in [('RDTG-diagonal','roundState == 3 && projVectorY != 0'),('RDTG-any','roundState == 3'),('RDTG-nondual','roundState == 3 && projVectorY != 0 && dualVectorX == projVectorX && dualVectorY == projVectorY')]:
 cases[n]=h.replace('''        if (finerGrid)
            return roundPhysicalDistance''',f'''        if (finerGrid && !(refinedTextExperiment && {condition}))
            return roundPhysicalDistance''')
def run(n,h):
 exe=audit.compile(n,{'hinter':h});return n,audit.measure(n,exe,families=list(audit.diagnose.FONTS),sizes=[12,13,17,26])
results={}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 for f in concurrent.futures.as_completed([pool.submit(run,k,v) for k,v in cases.items()]):
  n,r=f.result();results[n]=r
  print(n,[(f,ch,size,next(x['error'] for x in r if x['font']==f and x['size']==size and x['character']==ch)) for f,ch,size in [('tahoma','^',13),('verdana','>',17),('times','>',12),('courier','*',12),('arial','A',17)]])
(audit.HERE/'RDTG-hypotheses.json').write_text(json.dumps(results,indent=2))
