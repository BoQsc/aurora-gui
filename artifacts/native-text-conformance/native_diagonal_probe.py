"""Native oracle for diagonal rounding and CVT cut-in; no system-font heuristics."""
from array import array
import json,os,subprocess,sys
from fontTools.ttLib import TTFont,newTable
from fontTools.ttLib.tables.ttProgram import Program
from PIL import Image
import audit
sys.path.insert(0,str(audit.HERE.parent/'native-text-next'))
from native_cutin_probe import font


def main():
 out=audit.BUILD/'diagonal-native';out.mkdir(exist_ok=True)
 exes={'before':audit.compile('diagonal-native-before',{p.stem:p.read_text() for p in (audit.HERE/'before-source').glob('*.d')}),
       'after':audit.compile('diagonal-native-after')}
 env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0',AURORA_TEST_CHARACTER='A');rows=[]
 for axis in ['x','y']:
  for px,py in [(16384,0),(13107,9830),(9830,13107),(0,16384)]:
   if (px if axis=='x' else py)==0:continue
   for mode in ['cutin','round']:
    for value in [40,72,96,128,192]:
     name=f'{axis}-{px}-{py}-{mode}-{value}';path=out/(name+'.ttf');font(path,128,128,axis,'mirp',False);ft=TTFont(path)
     # An unrounded MIRP request differs from the original projected width;
     # ROUND uses the same projection but exposes its result on an axis.
     prog=['SVTCA[1]' if axis=='x' else 'SVTCA[0]','PUSHW[ ]',px,py,'SPVFS[ ]','PUSHB[ ]',0,'SRP0[ ]']
     points=[2,3] if axis=='x' else [1,2]
     if mode=='cutin':
      cvt=newTable('cvt ');cvt.values=array('h',[value*2]);ft['cvt ']=cvt
      for pt in points:prog+=['ROFF[ ]','PUSHB[ ]',pt,0,'MIRP[00100]']
     else:
      prog+=['PUSHW[ ]',value,'ROUND[00]','SVTCA[1]' if axis=='x' else 'SVTCA[0]','DUP[ ]','PUSHB[ ]',points[0],'SWAP[ ]','SCFS[ ]','PUSHB[ ]',points[1],'SWAP[ ]','SCFS[ ]']
     p=Program();p.fromAssembly([str(v) for v in prog]);ft['glyf']['probe'].program=p;ft.save(path);ref=audit.diagnose.ref.NativeReference(path)
     try:
      row={'axis':axis,'projection':[px,py],'mode':mode,'value_26dot6':value}
      for label,exe in exes.items():
       prefix=out/(name+'-'+label);subprocess.run([str(exe),str(path),'16',str(prefix)],env=env,check=True,capture_output=True);info=json.loads(prefix.with_suffix('.json').read_text());a=Image.open(prefix.with_suffix('.ppm')).convert('RGB');n=ref.render(info,neutral=True)
       cell=ord('A')-33;w=info['cell_width'];h=info['cell_height'];x=cell%16*w;y=cell//16*h;box=(x,y,x+w,y+h);row[label]=audit.diagnose.ref.grayscale_error(a.crop(box),n.crop(box),255)['mean_absolute_error']
      rows.append(row)
     finally:ref.close()
 (audit.HERE/'native-diagonal-probe.json').write_text(json.dumps(rows,indent=2));print('Cases:',len(rows),'improve',sum(r['after']<r['before'] for r in rows),'regress',sum(r['after']>r['before'] for r in rows));print('Remaining', [r for r in rows if r['after']>0])
 assert all(r['after']<=r['before'] and r['after']<=0.5 for r in rows)

if __name__=='__main__':main()
