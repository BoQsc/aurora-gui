"""Pixel-for-pixel isolation of approved C, reviewed D and diagnostic hint modes."""
import hashlib,json,os,subprocess
from PIL import Image
import audit


def main():
 exes={'before':audit.compile('compatibility-before',{p.stem:p.read_text() for p in (audit.HERE/'before-source').glob('*.d')}),'current':audit.compile('compatibility-current')};rows=[]
 for profile,experiment,hinting in [('C','','natural'),('D','native-next','natural'),('unhinted','native-refined','0'),('diagnostic','native-refined','1')]:
  env=os.environ.copy();env.update(AURORA_TEXT_EXPERIMENT=experiment,AURORA_HINTING=hinting,AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0.5')
  for key in ['AURORA_TEST_CHARACTER','AURORA_TEST_DARK','AURORA_TEST_PHASE','AURORA_TEXT_GAMMA']:env.pop(key,None)
  for family,font in audit.diagnose.FONTS.items():
   for size in audit.diagnose.SIZES:
    images=[]
    for name,exe in exes.items():
     prefix=audit.BUILD/('compat-'+name);subprocess.run([str(exe),font,str(size),str(prefix)],env=env,check=True,capture_output=True);images.append(Image.open(prefix.with_suffix('.ppm')).convert('RGB').tobytes())
    rows.append({'profile':profile,'font':family,'size':size,'pixels_unchanged':images[0]==images[1],'before_sha256':hashlib.sha256(images[0]).hexdigest(),'current_sha256':hashlib.sha256(images[1]).hexdigest()})
  print(profile,'72 sheets compared',flush=True)
 (audit.HERE/'compatibility.json').write_text(json.dumps({'status':'pass' if all(r['pixels_unchanged'] for r in rows) else 'FAIL','cases':rows},indent=2));assert all(r['pixels_unchanged'] for r in rows)

if __name__=='__main__':main()
