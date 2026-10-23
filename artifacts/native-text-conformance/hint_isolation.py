"""Separate native outline/hinting and sampling failures using modified private font copies."""
import json,os,subprocess
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image,ImageDraw,ImageFont
import audit

CASES=[('tahoma',13,'^'),('verdana',17,'>'),('times',12,'>'),('courier',17,'g'),('courier',17,'3'),('courier',12,'*'),('arial',17,'A'),('consolas',17,'2'),('segoe',12,'?')]

def main():
 exe=audit.compile('diagnostic');out=audit.BUILD/'hint-isolation';out.mkdir(exist_ok=True)
 rows=[];panels=[];label_font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',14)
 for family,size,ch in CASES:
  path=audit.diagnose.FONTS[family];ft=TTFont(path);no=out/f'{family}-no-glyph-hints.ttf'
  for glyph in ft['glyf'].glyphs.values():
   glyph.expand(ft['glyf'])
   if hasattr(glyph,'program'):glyph.program=Program()
  ft.save(no)
  env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0',AURORA_TEST_CHARACTER=ch);env.pop('AURORA_TEST_PHASE',None);env.pop('AURORA_TEST_DARK',None)
  prefix=out/f'{family}-{size}-{ord(ch)}';subprocess.run([str(exe),path,str(size),str(prefix)],check=True,env=env,capture_output=True)
  info=json.loads(prefix.with_suffix('.json').read_text());w=info['cell_width'];h=info['cell_height'];cell=ord(ch)-33;x=cell%16*w;y=cell//16*h;box=(x+4,y+2,x+w-4,y+h-8)
  actual=Image.open(prefix.with_suffix('.ppm')).convert('RGB');native=audit.diagnose.ref.NativeReference(path);unhinted=audit.diagnose.ref.NativeReference(no)
  try:target=native.render(info,neutral=True);target_no=unhinted.render(info,neutral=True)
  finally:native.close();unhinted.close()
  row={'font':family,'size':size,'character':ch,'aurora_vs_native_raw':audit.diagnose.ref.grayscale_error(actual,target,255),'native_vs_native_no_hints':audit.diagnose.ref.grayscale_error(target,target_no,255)};rows.append(row)
  panel=Image.new('RGB',((w-8)*7*3+60,(h-10)*7+50),'#e5e9ef');d=ImageDraw.Draw(panel)
  for i,(label,img) in enumerate([('Aurora raw',actual),('Windows raw',target),('Windows no hints',target_no)]):
   d.text((20+i*((w-8)*7+20),6),f'{family} {size}px {ch}: {label}',font=label_font,fill='black');panel.paste(img.crop(box).resize(((w-8)*7,(h-10)*7),Image.Resampling.NEAREST),(20+i*((w-8)*7+20),35))
  panels.append(panel);print(family,size,ch,row,flush=True)
 (audit.HERE/'hint-isolation.json').write_text(json.dumps(rows,indent=2))
 image=Image.new('RGB',(max(p.width for p in panels),sum(p.height+10 for p in panels)),'#c4cbd5');y=0
 for p in panels:image.paste(p,(0,y));y+=p.height+10
 image.save(audit.HERE/'hint-isolation.png')

if __name__=='__main__':main()
