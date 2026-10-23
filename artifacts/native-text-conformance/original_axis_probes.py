import audit,json,concurrent.futures
base=(audit.BUILD/'original-mdrp/source/aurora/text/hinter.d').read_text()
a=base.index('    private static void interpolateBetween(');b=base.index('    private static void swap(',a)
prec=(audit.BUILD/'IUP-precision/source/aurora/text/hinter.d').read_text();pa=prec.index('    private static void interpolateBetween(');pb=prec.index('    private static void swap(',pa)
cases={}
for name,condition,iup in [('original-axis','(projVectorX == 0 || projVectorY == 0)',False),('original-x','projVectorY == 0',False),('original-axis-iup','(projVectorX == 0 || projVectorY == 0)',True)]:
 h=base.replace('const orgDist = refinedTextExperiment && naturalGrid && zoneSelect0 == 1 && zoneSelect1 == 1 ?',f'const orgDist = refinedTextExperiment && naturalGrid && {condition} && zoneSelect0 == 1 && zoneSelect1 == 1 ?')
 if iup:h=h[:a]+prec[pa:pb]+h[b:] if False else h.replace(base[a:b],prec[pa:pb])
 cases[name]=h
results={}
def run(name,h):
 exe=audit.compile(name,{'hinter':h});rows=audit.measure(name,exe,families=list(audit.diagnose.FONTS),sizes=list(audit.diagnose.SIZES));return name,rows
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 for f in concurrent.futures.as_completed([pool.submit(run,n,h) for n,h in cases.items()]):
  n,rows=f.result();results[n]=rows;print(n,[(font,ch,size,next(r['error'] for r in rows if r['font']==font and r['size']==size and r['character']==ch)) for font,ch,size in [('consolas','2',17),('times','>',12),('courier','*',12),('courier','g',17),('arial','A',17)]],flush=True)
(audit.HERE/'original-axis-hypotheses.json').write_text(json.dumps(results,indent=2))
