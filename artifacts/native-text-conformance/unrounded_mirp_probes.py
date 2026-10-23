import concurrent.futures,json
import audit
base=(audit.CORE/'source/aurora/text/hinter.d').read_text()
cases={}
for name,condition in [('mirp-pv','projVectorX != 0'),('mirp-all','true')]:
 h=base.replace('''              projVectorY == 0 && (instructControl & 4) == 0)) &&''',f'''              {condition} && (instructControl & 4) == 0)) &&''')
 assert h!=base;cases[name]=h

def run(n,h):
 exe=audit.compile(n,{'hinter':h});rows=audit.measure(n,exe,families=list(audit.diagnose.FONTS),sizes=list(audit.diagnose.SIZES));return n,rows
results={}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
 for f in concurrent.futures.as_completed([pool.submit(run,n,h) for n,h in cases.items()]):
  n,rows=f.result();results[n]=rows;print(n,[(font,ch,size,next(r['error'] for r in rows if r['font']==font and r['size']==size and r['character']==ch)) for font,ch,size in [('times','>',12),('courier','*',12),('courier','g',17),('arial','A',17)]],flush=True)
(audit.HERE/'unrounded-mirp-hypotheses.json').write_text(json.dumps(results,indent=2))
