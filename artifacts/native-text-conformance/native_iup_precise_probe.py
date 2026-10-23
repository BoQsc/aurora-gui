"""Native IUP oracle: moved endpoints, fractional original points, both axes."""
import json,os,subprocess,math
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image
import audit
from native_original_distance_probe import font as original_font


def nearest(x):return (-1 if x<0 else 1)*math.floor(abs(x)+0.5)

def font(path,start,end,mid,axis,size,cur0,cur2):
 original_font(path,start,end,axis,size,False);ft=TTFont(path);pen=TTGlyphPen(None)
 pts=[(start,0),(mid,1024),(end,1024),(start,-1024)] if axis=='x' else [(0,start),(0,mid),(1024,end),(1024,start)]
 pen.moveTo(pts[0]);[pen.lineTo(p) for p in pts[1:]];pen.closePath();g=pen.glyph();ft['hmtx'].metrics['probe']=(2048,min(p[0] for p in pts))
 expected=nearest(mid*size*64/2048)+cur0-nearest(start*size*64/2048) if mid<start else nearest(cur0+(cur2-cur0)*(mid-start)/(end-start))
 asm=['SVTCA[1]' if axis=='x' else 'SVTCA[0]','PUSHW[ ]',0,cur0,'SCFS[ ]','PUSHW[ ]',2,cur2,'SCFS[ ]','IUP[1]' if axis=='x' else 'IUP[0]','PUSHB[ ]',1,'GC[0]','PUSHW[ ]',expected,'SUB[ ]','PUSHW[ ]',1024,'MUL[ ]','PUSHW[ ]',256,'ADD[ ]','SVTCA[1]']
 for pt in range(4):asm+=['PUSHB[ ]',pt,0,'SCFS[ ]']
 asm+=['DUP[ ]','PUSHB[ ]',2,'SWAP[ ]','SCFS[ ]','PUSHB[ ]',3,'SWAP[ ]','SCFS[ ]','SVTCA[0]']
 for pt in range(4):asm+=['PUSHW[ ]',pt,256 if pt in [1,2] else 0,'SCFS[ ]']
 p=Program();p.fromAssembly([str(v) for v in asm]);g.program=p;ft['glyf']['probe']=g;ft.save(path)


def main():
 out=audit.BUILD/'iup-precise-native';out.mkdir(exist_ok=True)
 exes={'before':audit.compile('iup-precise-native-before'),'candidate':audit.compile('iup-precise-native-candidate',{'hinter':(audit.BUILD/'iup-precise/source/aurora/text/hinter.d').read_text()})}
 env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0',AURORA_TEST_CHARACTER='A');rows=[]
 for start,end,inner in [(147,1008,610),(101,310,203),(100,300,200),(147,149,148)]:
  for mid in [inner,start-37]:
   for size in [1,2,3,11,13,16,17,26,34]:
    for axis in ['x','y']:
     for cur0,cur2 in [(0,128),(256,0)]:
      name=f'{start}-{end}-{mid}-{size}-{axis}-{cur0}';path=out/(name+'.ttf');font(path,start,end,mid,axis,size,cur0,cur2);ref=audit.diagnose.ref.NativeReference(path);row={'original_start':start,'original_end':end,'original_midpoint':mid,'size':size,'axis':axis,'cur_start':cur0,'cur_end':cur2}
      try:
       for label,exe in exes.items():
        prefix=out/(name+'-'+label);subprocess.run([str(exe),str(path),str(size),str(prefix)],env=env,check=True,capture_output=True);info=json.loads(prefix.with_suffix('.json').read_text());a=Image.open(prefix.with_suffix('.ppm')).convert('RGB');n=ref.render(info,neutral=True);row[label]=audit.diagnose.ref.grayscale_error(a,n,255)['mean_absolute_error']
       rows.append(row)
      finally:ref.close()
 assert all(r['candidate']<=r['before'] and r['candidate']==0 for r in rows)
 print('Cases',len(rows),'improve',sum(r['candidate']<r['before'] for r in rows),'regress',sum(r['candidate']>r['before'] for r in rows),'worst',max(r['candidate'] for r in rows),flush=True)
 (audit.HERE/'native-iup-precise-probe.json').write_text(json.dumps(rows,indent=2))
if __name__=='__main__':main()
