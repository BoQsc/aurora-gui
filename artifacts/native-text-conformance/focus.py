"""ASCII at 17px: every eighth-pixel phase, both themes, nine fonts."""
import concurrent.futures,hashlib,json,os,subprocess
from PIL import Image
import audit
from conformance import score


def main():
 exes={'before':audit.compile('focus-before',{p.stem:p.read_text() for p in (audit.HERE/'before-source').glob('*.d')}),'current':audit.compile('focus-current')}
 dest=audit.HERE/'focus';dest.mkdir(exist_ok=True)
 def run(family):
  font=audit.diagnose.FONTS[family];native=audit.diagnose.ref.NativeReference(font);out=audit.BUILD/'focus'/family;out.mkdir(parents=True,exist_ok=True);rows=[]
  env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0.5');env.pop('AURORA_TEXT_GAMMA',None);env.pop('AURORA_TEST_CHARACTER',None)
  try:
   for dark in [False,True]:
    for phase in range(8):
     env.update(AURORA_TEST_DARK='1' if dark else '0',AURORA_TEST_PHASE=str(phase/8));images={};infos={};name=f'{family}-17-p{phase}-'+('dark' if dark else 'light')
     for label,exe in exes.items():
      prefix=out/(name+'-'+label);subprocess.run([str(exe),font,'17',str(prefix)],env=env,check=True,capture_output=True);infos[label]=json.loads(prefix.with_suffix('.json').read_text());images[label]=Image.open(prefix.with_suffix('.ppm')).convert('RGB')
     assert infos['before']==infos['current'],('glyph placement changed',name)
     info=infos['current'];images['native']=native.render(info,dark)
     if True:
      for label,img in images.items():img.save(dest/(name+'-'+label+'.png'))
     for g in info['glyphs']:
      i=g['cell'];w=info['cell_width'];h=info['cell_height'];x=i%16*w;y=i//16*h;box=(x,y,x+w,y+h);n=images['native'].crop(box)
      a=score(images['before'].crop(box),n,24 if dark else 255);b=score(images['current'].crop(box),n,24 if dark else 255)
      rows.append([family,phase,'dark' if dark else 'light',g['codepoint'],g['id'],a['exact'],b['exact'],a['ink_mae'],b['ink_mae'],a['different_pixels'],b['different_pixels'],b['maximum_channel_error']])
  finally:native.close()
  print(family,'17px phases/themes captured',flush=True);return rows
 rows=[]
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
  for f in concurrent.futures.as_completed([pool.submit(run,f) for f in audit.diagnose.FONTS]):rows.extend(f.result())
 columns=['font','phase_eighths','theme','codepoint','glyph_id','before_exact','current_exact','before_ink_mae','current_ink_mae','before_different_pixels','current_different_pixels','current_maximum_channel_error']
 result={'source_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (audit.HERE/'after-source').glob('*.d')},'status':'pass' if all(r[6] for r in rows) else 'FAIL','size':17,'tested':len(rows),'current_exact':sum(r[6] for r in rows),'placement_unchanged':True,'columns':columns,'cases':rows}
 (audit.HERE/'focus.json').write_text(json.dumps(result,separators=(',',':')));print({k:v for k,v in result.items() if k not in ['cases','columns']})

if __name__=='__main__':main()
