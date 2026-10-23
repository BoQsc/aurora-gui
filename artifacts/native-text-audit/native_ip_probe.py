"""Independent generated-font IP/MDAP checks using the Windows reference."""
from array import array
import json
import os
import subprocess
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image
import audit


def font(path, axis, target, original_range, current_range):
    def xy(x,y):return (x,y) if axis=='y' else (y,x)
    pen=TTGlyphPen(None)
    pen.moveTo(xy(0,target));pen.lineTo(xy(0,target+256));pen.lineTo(xy(1024,target+256));pen.lineTo(xy(1024,target));pen.closePath()
    pen.moveTo(xy(20000,0));pen.lineTo(xy(20000,original_range));pen.lineTo(xy(20000,0));pen.closePath()
    g=pen.glyph();p=Program()
    # Explicit reference locations, followed by IP and grid rounding. Construct
    # the top edge relative to the resulting bottom edge so bounds expose IP.
    asm=['SVTCA[0]' if axis=='y' else 'SVTCA[1]', 'PUSHW[ ]',4,0,'SCFS[ ]',
         'PUSHW[ ]',5,current_range,'SCFS[ ]','PUSHB[ ]',4,'SRP1[ ]','PUSHB[ ]',5,'SRP2[ ]',
         'PUSHB[ ]',0,'IP[ ]','PUSHB[ ]',0,'MDAP[1]',
         'PUSHB[ ]',3,'ALIGNRP[ ]']
    for point in [1,2]:asm += ['PUSHB[ ]',point,0,'GC[0]','PUSHW[ ]',128,'ADD[ ]','SCFS[ ]']
    p.fromAssembly([str(v) for v in asm]);g.program=p
    fb=FontBuilder(2048,isTTF=True);fb.setupGlyphOrder(['.notdef','probe']);fb.setupCharacterMap({65:'probe'})
    fb.setupGlyf({'.notdef':TTGlyphPen(None).glyph(),'probe':g});fb.setupHorizontalMetrics({'.notdef':(2048,0),'probe':(2048,0)})
    fb.setupHorizontalHeader(ascent=2048,descent=-1024);fb.setupNameTable({'familyName':'Aurora interpolation diagnostic','styleName':'Regular'})
    fb.setupOS2(sTypoAscender=2048,sTypoDescender=-1024,usWinAscent=2048,usWinDescent=1024);fb.setupPost();fb.setupMaxp()
    fb.font['maxp'].maxZones=2;fb.font['maxp'].maxStackElements=128
    gasp=newTable('gasp');gasp.version=1;gasp.gaspRange={65535:15};fb.font['gasp']=gasp;fb.save(path)


def main():
    out=audit.BUILD/'ip-native';out.mkdir(exist_ok=True)
    before=audit.compile('ip-native-before', {n:(audit.HERE/'before-source'/f'{n}.d').read_text() for n in ['hinter','truetype','rasterizer']})
    after=audit.compile('ip-native-after')
    env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',AURORA_TEXT_CONTRAST='0',AURORA_TEST_CHARACTER='A')
    rows=[]
    for axis in ['x','y']:
      for target,original,current in [(64,256,127),(23,555,760),(11,277,276),(203,710,448),(-64,256,127),(64,-256,127)]:
        path=out/f'{axis}-{target}-{original}-{current}.ttf';font(path,axis,target,original,current)
        native=audit.diagnose.ref.NativeReference(path)
        try:
          row={'axis':axis,'target_design_units':target,'original_range_design_units':original,'current_range_26dot6':current}
          for label,exe in [('before',before),('after',after)]:
            prefix=out/(path.stem+'-'+label);subprocess.run([str(exe),str(path),'16',str(prefix)],env=env,check=True,capture_output=True)
            info=json.loads(prefix.with_suffix('.json').read_text());actual=Image.open(prefix.with_suffix('.ppm')).convert('RGB');reference=native.render(info,neutral=True)
            cell=ord('A')-33;w=info['cell_width'];h=info['cell_height'];x=cell%16*w;y=cell//16*h
            box=(x,y,x+w,y+h)
            row[label]=audit.diagnose.ref.grayscale_error(actual.crop(box),reference.crop(box),255)['mean_absolute_error']
          rows.append(row)
        finally:native.close()
    assert all(r['after'] <= r['before'] for r in rows)
    assert sum(r['after'] < r['before'] for r in rows) >= 3
    (audit.HERE/'native-ip-probe.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows,indent=2))

if __name__=='__main__':main()
