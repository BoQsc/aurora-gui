"""Stop real glyph programs at instruction boundaries to locate first divergence."""
import json,os,subprocess
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image
import audit


def boundaries(code):
 i=0;depth=0
 while i<len(code):
  op=code[i];i+=1
  if op in [0x40,0x41]:n=code[i];i+=1+n*(2 if op==0x41 else 1)
  elif 0xb0<=op<=0xb7:i+=op-0xb0+1
  elif 0xb8<=op<=0xbf:i+=(op-0xb8+1)*2
  if op==0x58:depth+=1
  elif op==0x59:depth-=1
  yield i,op,depth


def main():
 out=audit.BUILD/'prefix-consolas2';out.mkdir(exist_ok=True)
 h=(audit.CORE/'source/aurora/text/hinter.d').read_text();exe=audit.compile('prefix-fixture',{'hinter':h})
 env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0');records=[]
 for family,size,ch in [('consolas',17,'2')]:
  ft=TTFont(audit.diagnose.FONTS[family]);name=ft.getBestCmap()[ord(ch)];g=ft['glyf'][name];original=bytes(g.program.getBytecode());env['AURORA_TEST_CHARACTER']=ch
  trace_h=h.replace('''            ctx.ip++;
            version (AuroraHintTrace)''','''            ctx.ip++;
            if (ctx.glyphProgram && ctx.code.ptr == code.ptr)
            {
                import std.stdio : stderr;
                stderr.writefln("STEP:%s",ctx.ip-1);
            }
            version (AuroraHintTrace)''')
  trace_exe=audit.compile('prefix-trace-actual',{'hinter':trace_h})
  r=subprocess.run([str(trace_exe),audit.diagnose.FONTS[family],str(size),str(out/'execution')],env=env,check=True,capture_output=True,text=True)
  executed={int(line.split(':')[1]) for line in r.stderr.splitlines() if line.startswith('STEP:')}
  rows=[]
  for end,op,depth in boundaries(original):
   # Retain nested ELSE branches; the worst Times cases execute there.
   if end-1 not in executed:continue
   if op not in [0x2b,0x2f,0x2e,0x3e,0x3f,0x48,0x86,0x87,0x06,0x07,0x08,0x09,0x30,0x31] and not 0xc0<=op<=0xff:continue
   if op==0x2b and end<5:continue
   g.program=Program();g.program.fromBytecode(original[:end]+bytes([0x30,0x31]+[0x59]*depth))
   path=out/f'{family}-{size}-{ord(ch)}-byte{end}.ttf';ft.save(path);prefix=out/'sheet'
   subprocess.run([str(exe),str(path),str(size),str(prefix)],env=env,check=True,capture_output=True)
   info=json.loads(prefix.with_suffix('.json').read_text());actual=Image.open(prefix.with_suffix('.ppm')).convert('RGB');ref=audit.diagnose.ref.NativeReference(path)
   try:native=ref.render(info,neutral=True)
   finally:ref.close()
   r={'font':family,'size':size,'character':ch,'end_byte':end,'opcode':hex(op),'error':audit.diagnose.ref.grayscale_error(actual,native,255)['mean_absolute_error']};rows.append(r)
   actual.save(out/(path.stem+'-aurora.png'));native.save(out/(path.stem+'-native.png'))
  print(family,ch,rows,flush=True);records.extend(rows)
 (audit.HERE/'prefix-divergence-consolas2.json').write_text(json.dumps(records,indent=2))

if __name__=='__main__':main()
