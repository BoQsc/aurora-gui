import sys,json
sys.path.insert(0,'artifacts/native-text-next')
from native_cutin_probe import font
from diagnose import BUILD,HERE,ref
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image
out=BUILD/'scan-probe';out.mkdir(exist_ok=True)
records=[]
for width in [4,8,16,24,32,48,64,80]:
 for shift in [0,4,8,12,16,24,32]:
  p=out/f'w{width}-s{shift}.ttf';font(p,width,width,'x','mirp',False)
  ft=TTFont(p);g=ft['glyf']['probe'];g.program=Program();g.program.fromBytecode([])
  for pt in g.coordinates:pass
  for i,(x,y) in enumerate(g.coordinates):g.coordinates[i]=(x+shift*2,y)
  ft['hmtx'].metrics['probe']=(2048,shift*2)
  ft['gasp'].gaspRange={65535:8};ft.save(p)
  n=ref.NativeReference(p)
  try:
   im=n.render({'width':40,'height':40,'pixel_size':16,'glyphs':[{'id':1,'x':8,'y':32}]},neutral=True,foreground=(255,)*3,background=(0,)*3).convert('L')
   row={'width':width,'shift':shift,'alpha':[im.getpixel((x,28)) for x in range(7,12)]};records.append(row)
  finally:n.close()
(HERE/'native-scan-probe.json').write_text(json.dumps(records,indent=2))
for w in [4,8,16,24,32,48,64,80]:print(w,[(r['shift'],r['alpha']) for r in records if r['width']==w])
