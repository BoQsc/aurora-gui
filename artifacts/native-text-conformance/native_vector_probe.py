"""Independent native oracle for current versus original hinting vectors."""
from array import array
import json,os,subprocess
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image
import audit


def font(path,opcode,dx,dy,original=False):
 pen=TTGlyphPen(None);pen.moveTo((0,0));pen.lineTo((0,1024));pen.lineTo((512,1024));pen.lineTo((512,0));pen.closePath()
 pen.moveTo((20000,0));pen.lineTo((20000+dx*2,0));pen.lineTo((20000,0));pen.closePath();g=pen.glyph()
 asm=['SVTCA[0]','PUSHW[ ]',5,dy,'SCFS[ ]','PUSHB[ ]',4,5,opcode]
 if original:asm += ['PUSHB[ ]',4,5,'MD[1]','ABS[ ]']
 else:asm += ['GFV[ ]' if opcode.startswith('SFVTL') else 'GPV[ ]','POP[ ]','ABS[ ]','PUSHW[ ]',4096,'DIV[ ]']
 # Place the right rectangle edge using the captured vector component/distance.
 asm += ['SVTCA[1]','DUP[ ]','PUSHB[ ]',2,'SWAP[ ]','SCFS[ ]','PUSHB[ ]',3,'SWAP[ ]','SCFS[ ]']
 p=Program();p.fromAssembly([str(a) for a in asm]);g.program=p
 fb=FontBuilder(2048,isTTF=True);fb.setupGlyphOrder(['.notdef','probe']);fb.setupCharacterMap({65:'probe'});fb.setupGlyf({'.notdef':TTGlyphPen(None).glyph(),'probe':g})
 fb.setupHorizontalMetrics({'.notdef':(2048,0),'probe':(2048,0)});fb.setupHorizontalHeader(ascent=2048,descent=-1024);fb.setupNameTable({'familyName':'Aurora vector conformance','styleName':'Regular'})
 fb.setupOS2(sTypoAscender=2048,sTypoDescender=-1024,usWinAscent=2048,usWinDescent=1024);fb.setupPost();fb.setupMaxp();fb.font['maxp'].maxZones=2;fb.font['maxp'].maxStackElements=128
 gasp=newTable('gasp');gasp.version=1;gasp.gaspRange={65535:15};fb.font['gasp']=gasp;fb.save(path)


def main():
 out=audit.BUILD/'vector-native';out.mkdir(exist_ok=True)
 old=audit.compile('vector-native-before',{p.stem:p.read_text() for p in (audit.HERE/'before-source').glob('*.d')})
 new=audit.compile('vector-native-after')
 env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0',AURORA_TEST_CHARACTER='A')
 rows=[]
 for opcode in ['SPVTL[0]','SPVTL[1]','SFVTL[0]','SFVTL[1]','SDPVTL[0]','SDPVTL[1]']:
  for dx,dy in [(128,128),(256,128),(128,256)]:
   for original in ([False,True] if opcode.startswith('SDPVTL') else [False]):
    name=f'{opcode[:5]}-{opcode[-2]}-{dx}-{dy}-{original}';path=out/(name+'.ttf');font(path,opcode,dx,dy,original);ref=audit.diagnose.ref.NativeReference(path)
    try:
     row={'opcode':opcode,'line_dx':dx,'current_line_dy':dy,'measure_original':original}
     for label,exe in [('before',old),('after',new)]:
      prefix=out/(name+'-'+label);subprocess.run([str(exe),str(path),'16',str(prefix)],env=env,check=True,capture_output=True);info=json.loads(prefix.with_suffix('.json').read_text())
      im=Image.open(prefix.with_suffix('.ppm')).convert('RGB');native=ref.render(info,neutral=True);cell=ord('A')-33;w=info['cell_width'];h=info['cell_height'];x=cell%16*w;y=cell//16*h;box=(x,y,x+w,y+h)
      row[label]=audit.diagnose.ref.grayscale_error(im.crop(box),native.crop(box),255)['mean_absolute_error']
     rows.append(row)
    finally:ref.close()
 (audit.HERE/'native-vector-probe.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows,indent=2))
 assert all(r['after']<=r['before'] for r in rows)
 assert all(r['after']<=0.5 for r in rows if not r['measure_original'])

if __name__=='__main__':main()
