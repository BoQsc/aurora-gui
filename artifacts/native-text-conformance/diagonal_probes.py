"""Probe diagonal vector semantics against independent native glyphs."""
import concurrent.futures,json
import audit


def dual_vectors(h):
 a=h.index('            case 0x86: case 0x87:');b=h.index('            case 0x10:',a)
 block=h[a:b];old='''                ctx.dualVectorX = ux; ctx.dualVectorY = uy;
                ctx.setProjectionVector(ux, uy);'''
 new='''                if (ctx.refinedTextExperiment)
                {
                    const currentX = ctx.zone1Ref().points[p2].curX - ctx.zone2Ref().points[p1].curX;
                    const currentY = ctx.zone1Ref().points[p2].curY - ctx.zone2Ref().points[p1].curY;
                    ctx.setProjectionVector(cast(int) (perpendicular ? -currentY : currentX),
                        cast(int) (perpendicular ? currentX : currentY));
                    ctx.dualVectorX = ux; ctx.dualVectorY = uy;
                }
                else
                {
                    ctx.dualVectorX = ux; ctx.dualVectorY = uy;
                    ctx.setProjectionVector(ux, uy);
                }'''
 assert old in block
 return h[:a]+block.replace(old,new)+h[b:]


def round_vectors(h):
 for prefix in ['proj','free']:
  for axis,component in [('X','x'),('Y','y')]:
   old=f'{prefix}Vector{axis} = cast(int) ({component} * 0x4000 / length)'
   new=f'{prefix}Vector{axis} = cast(int) ({component} * 0x4000 / length + ({component} < 0 ? -0.5 : 0.5))'
   assert old in h;h=h.replace(old,new)
 return h


def main():
 h=(audit.CORE/'source/aurora/text/hinter.d').read_text()
 cases={'dual-vectors':dual_vectors(h),'dual-rounded':round_vectors(dual_vectors(h)),
        'rounded-vectors':round_vectors(h)}
 def run(name,source):
  exe=audit.compile(name,{'hinter':source});return name,audit.measure(name,exe,families=list(audit.diagnose.FONTS),sizes=list(audit.diagnose.SIZES))
 rows={}
 with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
  for future in concurrent.futures.as_completed([pool.submit(run,k,v) for k,v in cases.items()]):
   name,result=future.result();rows[name]=result
 (audit.HERE/'diagonal-hypotheses.json').write_text(json.dumps(rows,indent=2))
 for name,r in rows.items():
  print(name,[(f,ch,size,next(x['error'] for x in r if x['font']==f and x['size']==size and x['character']==ch)) for f,ch,size in [('tahoma','^',13),('verdana','>',17),('times','>',12),('courier','*',12),('arial','A',17)]])

if __name__=='__main__':main()
