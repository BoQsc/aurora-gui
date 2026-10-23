"""Expose hinted point coordinates as flat bar widths in the native renderer."""
import json,os,subprocess
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image
import audit
from prefix_trace import boundaries

def main():
 out=audit.BUILD/'point-oracle';out.mkdir(exist_ok=True)
 h=(audit.CORE/'source/aurora/text/hinter.d').read_text();exe=audit.compile('point-oracle-fixture',{'hinter':h})
 env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0',AURORA_TEST_CHARACTER='>')
 ft=TTFont(audit.diagnose.FONTS['times']);g=ft['glyf'][ft.getBestCmap()[ord('>')]];code=bytes(g.program.getBytecode());rows=[]
 depth={end:d for end,op,d in boundaries(code)}
 for end in [205,239,244,248,253,257]:
  for axis in ['x','y']:
   for point in range(7):
    asm=['SVTCA[1]' if axis=='x' else 'SVTCA[0]','PUSHB[ ]',point,'GC[0]','PUSHW[ ]',256,'ADD[ ]','SVTCA[1]']
    # The value stays on top while the other points collapse to zero.
    for p in range(7):asm+=['PUSHB[ ]',p,0,'SCFS[ ]']
    asm+=['DUP[ ]','PUSHB[ ]',2,'SWAP[ ]','SCFS[ ]','PUSHB[ ]',3,'SWAP[ ]','SCFS[ ]','SVTCA[0]']
    for p in range(7):asm+=['PUSHW[ ]',p,256 if p in [1,2] else 0,'SCFS[ ]']
    p=Program();p.fromAssembly([str(v) for v in asm]);g.program=Program();g.program.fromBytecode(code[:end]+bytes([0x59]*depth[end])+bytes(p.getBytecode()))
    path=out/f'byte{end}-{axis}{point}.ttf';ft.save(path);prefix=out/'sheet';subprocess.run([str(exe),str(path),'12',str(prefix)],env=env,check=True,capture_output=True)
    info=json.loads(prefix.with_suffix('.json').read_text());a=Image.open(prefix.with_suffix('.ppm')).convert('RGB');ref=audit.diagnose.ref.NativeReference(path)
    try:n=ref.render(info,neutral=True)
    finally:ref.close()
    cell=ord('>')-33;w=info['cell_width'];hh=info['cell_height'];x=cell%16*w;y=cell//16*hh;box=(x,y,x+w,y+hh)
    def coord(img):
     hist=img.crop(box).convert('L').histogram();return round(sum((255-i)*v for i,v in enumerate(hist))/255/4*64-256,2)
    row={'end_byte':end,'axis':axis,'point':point,'aurora':coord(a),'native':coord(n)};rows.append(row)
  print(end,[r for r in rows if r['end_byte']==end],flush=True)
 (audit.HERE/'native-point-oracle.json').write_text(json.dumps(rows,indent=2))

if __name__=='__main__':main()
