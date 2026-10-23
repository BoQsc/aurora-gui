"""Measure native distance-type compensation independently of real fonts."""
import json,os,subprocess,sys
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image,ImageChops
import audit
sys.path.insert(0,str(audit.HERE.parent/'native-text-next'))
from native_cutin_probe import font

def main():
 out=audit.BUILD/'distance-types';out.mkdir(exist_ok=True);rows=[]
 for axis in ['x','y']:
  for distance in [40,63,64,72,96,127,128]:
   for color in [0,1,2]:
    path=out/f'{axis}-{distance}-{color}.ttf';font(path,128,128,axis,'mirp',False);ft=TTFont(path);g=ft['glyf']['probe'];code=[0x01 if axis=='x' else 0x00]
    for pt in ([2,3] if axis=='x' else [1,2]):code += [0xb0,pt,0xb8,(distance>>8)&255,distance&255,0x68+color,0x48]
    g.program=Program();g.program.fromBytecode(code);ft.save(path);ref=audit.diagnose.ref.NativeReference(path)
    try:
     info={'width':40,'height':40,'pixel_size':16,'glyphs':[{'id':1,'x':8,'y':32}]};im=ImageChops.invert(ref.render(info,neutral=True).convert('L'))
     rows.append({'axis':axis,'distance':distance,'color':color,'ink':sum(im.get_flattened_data()),'bounds':im.getbbox()})
    finally:ref.close()
 (audit.HERE/'distance-types.json').write_text(json.dumps(rows,indent=2));print('Color groups differing',[(axis,d,[r['ink'] for r in rows if r['axis']==axis and r['distance']==d]) for axis in ['x','y'] for d in [40,63,64,72,96,127,128]])

if __name__=='__main__':main()
