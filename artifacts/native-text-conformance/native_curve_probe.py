"""Native oracle for TrueType instructions that change curve-point flags."""
import json,os,subprocess
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image
import audit


def font(path,opcode,low,high):
 pen=TTGlyphPen(None);pen.moveTo((0,0));pen.lineTo((0,1024));pen.lineTo((512,1536));pen.lineTo((1024,1024));pen.lineTo((1024,0));pen.closePath();g=pen.glyph()
 if opcode=='FLIPRGON[ ]':g.flags[1]=g.flags[2]=0
 asm=['PUSHB[ ]',low] if opcode=='FLIPPT[ ]' else ['PUSHB[ ]',low,high]
 asm += [opcode];p=Program();p.fromAssembly([str(v) for v in asm]);g.program=p
 fb=FontBuilder(2048,isTTF=True);fb.setupGlyphOrder(['.notdef','probe']);fb.setupCharacterMap({65:'probe'});fb.setupGlyf({'.notdef':TTGlyphPen(None).glyph(),'probe':g});fb.setupHorizontalMetrics({'.notdef':(2048,0),'probe':(2048,0)});fb.setupHorizontalHeader(ascent=2048,descent=0);fb.setupNameTable({'familyName':'Aurora curve flag conformance','styleName':'Regular'});fb.setupOS2(sTypoAscender=2048,sTypoDescender=0,usWinAscent=2048,usWinDescent=0);fb.setupPost();fb.setupMaxp();fb.font['maxp'].maxZones=2;fb.font['maxp'].maxStackElements=128;gasp=newTable('gasp');gasp.version=1;gasp.gaspRange={65535:15};fb.font['gasp']=gasp;fb.save(path)


def main():
 out=audit.BUILD/'curve-native';out.mkdir(exist_ok=True)
 exes={'before':audit.compile('curve-native-before',{p.stem:p.read_text() for p in (audit.HERE/'before-source').glob('*.d')}),'candidate':audit.compile('curve-native-candidate')}
 env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0',AURORA_TEST_CHARACTER='A');rows=[]
 for opcode,low,high in [('FLIPPT[ ]',2,2),('FLIPRGOFF[ ]',1,2),('FLIPRGON[ ]',1,2)]:
  path=out/(opcode.split('[')[0]+'.ttf');font(path,opcode,low,high);ref=audit.diagnose.ref.NativeReference(path)
  try:
   for size in [11,13,17,26,34]:
    row={'opcode':opcode,'low':low,'high':high,'size':size}
    for label,exe in exes.items():
     prefix=out/f'{path.stem}-{size}-{label}';subprocess.run([str(exe),str(path),str(size),str(prefix)],env=env,check=True,capture_output=True);info=json.loads(prefix.with_suffix('.json').read_text());a=Image.open(prefix.with_suffix('.ppm')).convert('RGB');n=ref.render(info,neutral=True);row[label]=audit.diagnose.ref.grayscale_error(a,n,255)['mean_absolute_error'];a.save(prefix.with_suffix('.png'));n.save(out/f'{path.stem}-{size}-native.png')
    rows.append(row)
  finally:ref.close()
 (audit.HERE/'native-curve-probe.json').write_text(json.dumps(rows,indent=2));print(rows)
 assert all(r['candidate']<=r['before'] for r in rows)
if __name__=='__main__':main()
