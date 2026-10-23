"""Isolated shared-app capture: compare C to the frozen source and exercise GPU."""
import hashlib,json,subprocess,sys
from pathlib import Path
from PIL import Image
import audit
sys.path.insert(0,str(audit.HERE.parent/'native-text-audit'))
from capture import environment


def main():
 out=audit.BUILD/'apps';out.mkdir(exist_ok=True);records=[];exes={}
 def run(command,env=None):
  p=subprocess.run(list(map(str,command)),cwd=audit.ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace');records.append({'command':list(map(str,command)),'exit_code':p.returncode,'output':p.stdout+p.stderr})
  if p.returncode:raise RuntimeError(p.stdout+p.stderr)
  return p
 includes=['vendor/aurora-d-0.4.5/source','vendor/aurora-standard/source','aurora-notepad/source','experiments/aurora-host/source','experiments/aurora-host/generated']
 for name in ['before','current','native']:
  build=out/name;build.mkdir(exist_ok=True);exe=build/'capture.exe';override=[]
  if name=='before':
   source=build/'source/aurora/text';source.mkdir(parents=True,exist_ok=True)
   for p in (audit.HERE/'before-source').glob('*.d'):(source/p.name).write_bytes(p.read_bytes())
   override=['-I'+str(build/'source')]
  cmd=['dmd','-i','-O','-J'+str(audit.ROOT/'experiments/aurora-host/assets'),*override,*['-I'+str(audit.ROOT/p) for p in includes],'-od='+str(build),'-of='+str(exe),audit.HERE.parent/'text-coverage-candidate/capture.d','user32.lib','gdi32.lib','shell32.lib','wininet.lib']
  if name!='native':cmd+=['-version=AuroraHeadless']
  run(cmd);exes[name]=exe
 cases=[];dest=audit.HERE/'app-captures';dest.mkdir(exist_ok=True)
 for app,themes in [('notepad',['light','dark']),('host',['light','dark']),('padpp',['light'])]:
  for theme in themes:
   for dpi in [96,120,144]:
    case=f'{app}-{theme}-{dpi}';images={}
    for label,profile in [('before','C'),('current','C'),('refined','refined-D')]:
     prefix=out/(case+'-'+label);run([exes['before' if label=='before' else 'current'],app,prefix,theme,dpi],environment(profile));images[label]=Image.open(prefix.with_suffix('.ppm')).convert('RGB')
    assert images['before'].tobytes()==images['current'].tobytes(),('C pixels changed',case)
    row={'case':case,'C_pixels_unchanged':True,'C_sha256':hashlib.sha256(images['current'].tobytes()).hexdigest(),'refined_sha256':hashlib.sha256(images['refined'].tobytes()).hexdigest()};cases.append(row)
    if app=='padpp' or dpi in [96,144]:
     for label in ['current','refined']:images[label].save(dest/(case+'-'+label+'.png'))
 gpu=[]
 for profile in ['C','refined-D']:
  prefix=out/('gpu-'+profile);p=run([exes['native'],'native',prefix],environment(profile));print(profile,p.stdout.strip(),flush=True)
  for stage in [0,1]:
   a=Image.open(str(prefix)+f'-{stage}.ppm').convert('RGB');b=Image.open(str(prefix)+f'-software-{stage}.ppm').convert('RGB')
   if profile=='refined-D':assert a.tobytes()==b.tobytes(),('GPU/software differ',stage)
   gpu.append({'profile':profile,'stage':stage,'equal':a.tobytes()==b.tobytes()})
 (audit.HERE/'captures.json').write_text(json.dumps({'C_app_pixels_unchanged':True,'cases':cases,'gpu':gpu,'records':records},indent=2));print('All 15 C application captures unchanged',flush=True)

if __name__=='__main__':main()
