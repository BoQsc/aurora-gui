"""Native oracle for distances between originally unrounded design points."""
import json,os,subprocess,math
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image
import audit


def font(path,start,end,axis,size,negative):
 if negative:start,end=end,start
 pen=TTGlyphPen(None)
 pts=[(start,0),(start,1024),(end,1024),(end,0)] if axis=='x' else [(0,start),(0,end),(1024,end),(1024,start)]
 pen.moveTo(pts[0]);[pen.lineTo(p) for p in pts[1:]];pen.closePath();g=pen.glyph();targets=[2,3] if axis=='x' else [1,2];refs=[0,1] if axis=='x' else [0,3]
 raw=(end-start)*size*64/2048;grid=4 if axis=='x' else 64;expected=(1 if raw>=0 else -1)*math.floor(abs(raw)/grid+0.5)*grid
 asm=['SVTCA[1]' if axis=='x' else 'SVTCA[0]']
 for pt in refs:asm+=['PUSHB[ ]',pt,0,'SCFS[ ]']
 asm+=['PUSHB[ ]',0,'SRP0[ ]']
 for pt in targets:asm+=['PUSHB[ ]',pt,'MDRP[00100]']
 asm+=['PUSHB[ ]',2,'GC[0]','PUSHW[ ]',expected,'SUB[ ]','PUSHW[ ]',1024,'MUL[ ]','PUSHW[ ]',256,'ADD[ ]','SVTCA[1]']
 for pt in range(4):asm+=['PUSHB[ ]',pt,0,'SCFS[ ]']
 asm+=['DUP[ ]','PUSHB[ ]',2,'SWAP[ ]','SCFS[ ]','PUSHB[ ]',3,'SWAP[ ]','SCFS[ ]','SVTCA[0]']
 for pt in range(4):asm+=['PUSHW[ ]',pt,256 if pt in [1,2] else 0,'SCFS[ ]']
 p=Program();p.fromAssembly([str(v) for v in asm]);g.program=p
 fb=FontBuilder(2048,isTTF=True);fb.setupGlyphOrder(['.notdef','probe']);fb.setupCharacterMap({65:'probe'});fb.setupGlyf({'.notdef':TTGlyphPen(None).glyph(),'probe':g});fb.setupHorizontalMetrics({'.notdef':(2048,0),'probe':(2048,min(p[0] for p in pts))});fb.setupHorizontalHeader(ascent=2048,descent=-2048);fb.setupNameTable({'familyName':'Aurora original distance conformance','styleName':'Regular'});fb.setupOS2(sTypoAscender=2048,sTypoDescender=-2048,usWinAscent=2048,usWinDescent=2048);fb.setupPost();fb.setupMaxp();fb.font['maxp'].maxZones=2;fb.font['maxp'].maxStackElements=128;gasp=newTable('gasp');gasp.version=1;gasp.gaspRange={65535:15};fb.font['gasp']=gasp;fb.save(path)


def main():
 out=audit.BUILD/'original-distance-native';out.mkdir(exist_ok=True)
 exes={'before':audit.compile('original-native-before',{p.stem:p.read_text() for p in (audit.HERE/'before-source').glob('*.d')}),'candidate':audit.compile('original-native-candidate')}
 env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0',AURORA_TEST_CHARACTER='A');rows=[]
 for start,end in [(147,1008),(37,1113),(248,750),(305,938),(101,310)]:
  for size in [11,12,13,17,26,34]:
   for axis in ['x','y']:
    for negative in [False,True]:
     name=f'{start}-{end}-{size}-{axis}-{negative}';path=out/(name+'.ttf');font(path,start,end,axis,size,negative);ref=audit.diagnose.ref.NativeReference(path);row={'original_start':start,'original_end':end,'size':size,'axis':axis,'negative':negative}
     try:
      for label,exe in exes.items():
       prefix=out/(name+'-'+label);subprocess.run([str(exe),str(path),str(size),str(prefix)],env=env,check=True,capture_output=True);info=json.loads(prefix.with_suffix('.json').read_text());a=Image.open(prefix.with_suffix('.ppm')).convert('RGB');n=ref.render(info,neutral=True);row[label]=audit.diagnose.ref.grayscale_error(a,n,255)['mean_absolute_error']
      rows.append(row)
     finally:ref.close()
 print('Cases',len(rows),'improve',sum(r['candidate']<r['before'] for r in rows),'regress',sum(r['candidate']>r['before'] for r in rows),'worst',max(r['candidate'] for r in rows),flush=True)
 (audit.HERE/'native-original-distance-probe.json').write_text(json.dumps(rows,indent=2))
 assert all(r['candidate']==0 and r['candidate']<=r['before'] for r in rows)
if __name__=='__main__':main()
