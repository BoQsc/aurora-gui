import sys,json,concurrent.futures
sys.path.insert(0,'artifacts/native-text-conformance');import audit
base=(audit.BUILD/'current-line-vectors/source/aurora/text/hinter.d').read_text()
cases={}
cases['arithmetic']=base.replace('ctx.push(n1 == 0 ? 0 : n2 * 64 / n1)', 'ctx.push(n1 == 0 ? 0 : ctx.refinedTextExperiment ? roundedMulDiv(n2,64,n1) : n2*64/n1)').replace('ctx.push(n1 * n2 / 64)','ctx.push(ctx.refinedTextExperiment ? roundedMulDiv(n1,n2,64) : n1*n2/64)')
a=base.index('    private static void interpolateBetween(');b=base.index('    private static void swap(',a);block=base[a:b]
for suffix in ['X','Y']:
 block=block.replace(f'zone.points[ref1].orus{suffix}', f'(ctx.refinedTextExperiment ? zone.points[ref1].ipOriginal{suffix} : zone.points[ref1].orus{suffix})').replace(f'zone.points[ref2].orus{suffix}',f'(ctx.refinedTextExperiment ? zone.points[ref2].ipOriginal{suffix} : zone.points[ref2].orus{suffix})')
block=block.replace('const orus = xAxis ? zone.points[i].orusX : zone.points[i].orusY;', 'const orus = ctx.refinedTextExperiment ? (xAxis ? zone.points[i].ipOriginalX : zone.points[i].ipOriginalY) : (xAxis ? zone.points[i].orusX : zone.points[i].orusY);')
block=block.replace('value = cur1 + mulDiv(cast(int) (orus - orus1), scale, 0x4000);', 'value = cur1 + (ctx.refinedTextExperiment ? roundedMulDiv(orus - orus1,cur2-cur1,orus2-orus1) : mulDiv(cast(int) (orus - orus1), scale, 0x4000));')
cases['IUP-precision']=base[:a]+block+base[b:]
cases['arithmetic-IUP']=cases['arithmetic'][:a]+block+cases['arithmetic'][b:] if False else cases['arithmetic'].replace(base[a:b],block)
results={}
def run(n,h):
 exe=audit.compile(n,{'hinter':h});return n,audit.measure(n,exe,families=list(audit.diagnose.FONTS),sizes=list(audit.diagnose.SIZES))
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 for f in concurrent.futures.as_completed([pool.submit(run,k,v) for k,v in cases.items()]):
  n,r=f.result();results[n]=r
  print(n,[(f,ch,size,next(x['error'] for x in r if x['font']==f and x['size']==size and x['character']==ch)) for f,ch,size in [('tahoma','^',13),('verdana','>',17),('times','>',12),('courier','*',12),('courier','g',17),('arial','A',17),('consolas','2',17)]])
(audit.HERE/'precision-hypotheses.json').write_text(json.dumps(results,indent=2))
