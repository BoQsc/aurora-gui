"""Native scan-conversion oracle: small strips with fixed, unhinted coordinates."""
import json,os,subprocess,concurrent.futures
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image
import audit


def font(path,slope,thickness,offset,flags=5):
 pen=TTGlyphPen(None);pen.moveTo((0,(128+offset)*2));pen.lineTo((768,(128+offset+slope)*2));pen.lineTo((768,(128+offset+slope+thickness)*2));pen.lineTo((0,(128+offset+thickness)*2));pen.closePath();g=pen.glyph();p=Program();p.fromAssembly(['SVTCA[1]']);g.program=p
 fb=FontBuilder(2048,isTTF=True);fb.setupGlyphOrder(['.notdef','probe']);fb.setupCharacterMap({65:'probe'});fb.setupGlyf({'.notdef':TTGlyphPen(None).glyph(),'probe':g});fb.setupHorizontalMetrics({'.notdef':(2048,0),'probe':(2048,0)});fb.setupHorizontalHeader(ascent=2048,descent=-1024);fb.setupNameTable({'familyName':'Aurora scan conformance','styleName':'Regular'});fb.setupOS2(sTypoAscender=2048,sTypoDescender=-1024,usWinAscent=2048,usWinDescent=1024);fb.setupPost();fb.setupMaxp();fb.font['maxp'].maxZones=2;fb.font['maxp'].maxStackElements=128;gasp=newTable('gasp');gasp.version=1;gasp.gaspRange={65535:flags};fb.font['gasp']=gasp;fb.save(path)


def main():
 out=audit.BUILD/'dropout-native';out.mkdir(exist_ok=True)
 names=['plain','drop-low','drop-high','drop-nearest'];exes={}
 for name in names:
  mods={} if name=='plain' else {'rasterizer':(audit.BUILD/name/'source/aurora/text/rasterizer.d').read_text()}
  exes[name]=audit.compile('dropout-oracle-'+name,mods)
 env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0',AURORA_TEST_CHARACTER='A');rows=[]
 for slope in [0,128,256,-128]:
  for thickness in [1,16,32,48,64]:
   for offset in [0,16,32,48]:
    name=f's{slope}-t{thickness}-o{offset}';path=out/(name+'.ttf');font(path,slope,thickness,offset);ref=audit.diagnose.ref.NativeReference(path);row={'slope':slope,'thickness':thickness,'offset':offset}
    try:
     for label,exe in exes.items():
      prefix=out/'sheet';subprocess.run([str(exe),str(path),'16',str(prefix)],env=env,check=True,capture_output=True);info=json.loads(prefix.with_suffix('.json').read_text());a=Image.open(prefix.with_suffix('.ppm')).convert('RGB');n=ref.render(info,neutral=True)
      i=ord('A')-33;w=info['cell_width'];h=info['cell_height'];x=i%16*w;y=i//16*h;box=(x,y,x+w,y+h);row[label]=audit.diagnose.ref.grayscale_error(a.crop(box),n.crop(box),255)['mean_absolute_error']
     rows.append(row)
    finally:ref.close()
 print({n:sum(r[n] for r in rows)/len(rows) for n in names},flush=True)
 (audit.HERE/'native-dropout-probe.json').write_text(json.dumps(rows,indent=2))
if __name__=='__main__':main()
