"""Amplify GC coordinates eightfold to observe native F26.6 point positions."""
import json,os,subprocess,re
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image
import audit


def main():
 out=audit.BUILD/'consolas2-points';out.mkdir(exist_ok=True);h=(audit.CORE/'source/aurora/text/hinter.d').read_text()
 trace=h.replace('''        ++_hintingCounters.successes;''','''        import std.stdio : stderr;
        stderr.writefln("POINTSX:%s",result.xs26Dot6);
        stderr.writefln("POINTSY:%s",result.ys26Dot6);
        ++_hintingCounters.successes;''')
 exe=audit.compile('consolas2-points-fixture',{'hinter':trace});env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0',AURORA_TEST_CHARACTER='2')
 p=subprocess.run([str(exe),audit.diagnose.FONTS['consolas'],'17',str(out/'original')],env=env,check=True,capture_output=True,text=True)
 coords={axis:json.loads(re.search('POINTS'+axis+':(.*)',p.stderr)[1]) for axis in ['X','Y']}
 ft=TTFont(audit.diagnose.FONTS['consolas']);g=ft['glyf'][ft.getBestCmap()[50]];n=len(g.coordinates);original=bytes(g.program.getBytecode());rows=[]
 for axis in ['X','Y']:
  for point in range(n):
   value=coords[axis][point];asm=['SVTCA[1]' if axis=='X' else 'SVTCA[0]','PUSHB[ ]',point,'GC[0]','PUSHW[ ]',value,'SUB[ ]','PUSHW[ ]',512,'MUL[ ]','PUSHW[ ]',256,'ADD[ ]','SVTCA[1]']
   for i in range(n):asm+=['PUSHB[ ]',i,0,'SCFS[ ]']
   asm+=['DUP[ ]','PUSHB[ ]',2,'SWAP[ ]','SCFS[ ]','PUSHB[ ]',3,'SWAP[ ]','SCFS[ ]','SVTCA[0]']
   for i in range(n):asm+=['PUSHW[ ]',i,256 if i in [1,2] else 0,'SCFS[ ]']
   asm+=['PUSHB[ ]',0,n-1,'FLIPRGON[ ]'];p=Program();p.fromAssembly([str(v) for v in asm]);g.program=Program();g.program.fromBytecode(original+bytes(p.getBytecode()));path=out/f'{axis}{point}.ttf';ft.save(path);prefix=out/'sheet'
   subprocess.run([str(exe),str(path),'17',str(prefix)],env=env,check=True,capture_output=True);info=json.loads(prefix.with_suffix('.json').read_text());a=Image.open(prefix.with_suffix('.ppm')).convert('L');ref=audit.diagnose.ref.NativeReference(path)
   try:native=ref.render(info,neutral=True).convert('L')
   finally:ref.close()
   def decode(img):
    hist=img.histogram();return value+(sum((255-i)*v for i,v in enumerate(hist))/255/4*64-256)/8
   rows.append({'axis':axis,'point':point,'aurora':round(decode(a),3),'native':round(decode(native),3),'original_aurora':value})
  print(axis,[r for r in rows if r['axis']==axis and abs(r['aurora']-r['native'])>.3],flush=True)
 (audit.HERE/'native-consolas2-points.json').write_text(json.dumps(rows,indent=2))
if __name__=='__main__':main()
