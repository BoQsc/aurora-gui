"""Strict per-glyph differential suite; every unequal pixel is a failed case.

Enumerates every glyph in the selected fonts by default. This bypasses shaping
only to isolate rasterization; script shaping is a separate conformance gate.
Never uses an average improvement or blank-image check as a pass condition.
"""
import argparse,concurrent.futures,hashlib,json,os,subprocess,time
from pathlib import Path
from fontTools.ttLib import TTFont
from PIL import Image,ImageChops
import audit


def compile_fixture(name,modules=None):
 out=audit.BUILD/name;out.mkdir(parents=True,exist_ok=True)
 if modules:
  d=out/'source/aurora/text';d.mkdir(parents=True,exist_ok=True)
  for n,s in modules.items():(d/(n+'.d')).write_text(s)
 exe=out/'conformance.exe'
 subprocess.run(['dmd','-i','-O','-version=AuroraHeadless','-I'+str(out/'source'),'-I'+str(audit.CORE/'source'),'-od='+str(out),'-of='+str(exe),str(audit.HERE/'conformance_sheet.d'),'user32.lib','gdi32.lib'],check=True)
 return exe


def score(a,b,background):
 diff=ImageChops.difference(a,b)
 bounds=diff.getbbox()
 if bounds is None:return {'exact':True,'different_pixels':0,'maximum_channel_error':0,'ink_mae':0.0}
 channels=diff.split();histograms=[c.histogram() for c in channels]
 total=sum(sum(i*v for i,v in enumerate(hist)) for hist in histograms)
 changed=sum(ImageChops.lighter(ImageChops.lighter(channels[0],channels[1]),channels[2]).point([0]+[1]*255).histogram()[1:])
 ag=a.convert('L');bg=b.convert('L')
 mask=ImageChops.lighter(ImageChops.difference(ag,Image.new('L',a.size,background)),ImageChops.difference(bg,Image.new('L',a.size,background)))
 ink=sum(mask.point([0]+[1]*255).histogram()[1:])
 maximum=max(max(i for i,v in enumerate(hist) if v) for hist in histograms)
 return {'exact':False,'different_pixels':changed,'maximum_channel_error':maximum,'ink_mae':total/max(1,ink*3),'different_bounds':bounds}


def font_suite(family,exe,sizes,phases,themes,limit=0,label='current',charset='all'):
 font=audit.diagnose.FONTS[family];ft=TTFont(font);count=ft['maxp'].numGlyphs
 mapping={}
 for cp,name in ft.getBestCmap().items():mapping.setdefault(ft.getGlyphID(name),[]).append(cp)
 ids=list(range(count)) if charset=='all' else sorted({ft.getGlyphID(ft.getBestCmap()[cp]) for cp in range(33,127) if cp in ft.getBestCmap()})
 if limit:ids=ids[:limit]
 out=audit.BUILD/'full-glyphs'/label/family;out.mkdir(parents=True,exist_ok=True)
 ref=audit.diagnose.ref.NativeReference(font);env=os.environ.copy();env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0.5')
 env.pop('AURORA_TEXT_GAMMA',None)
 rows=[];seen=0;exact=0;worst=[];start=time.perf_counter()
 try:
  for size in sizes:
   size_exact=0;size_seen=0
   for phase in phases:
    for theme in themes:
     for first in range(0,len(ids),64):
      batch=ids[first:first+64];job={'pixel_size':size,'phase_eighths':phase,'dark':theme=='dark','glyph_ids':batch}
      job_path=out/'job.json';job_path.write_text(json.dumps(job));prefix=out/'sheet'
      subprocess.run([str(exe),font,str(job_path),str(prefix)],env=env,check=True,capture_output=True)
      info=json.loads(prefix.with_suffix('.json').read_text());actual=Image.open(prefix.with_suffix('.ppm')).convert('RGB');native=ref.render(info,theme=='dark')
      w,h=info['cell_width'],info['cell_height']
      batch_worst=0
      for i,gid in enumerate(batch):
       x=i%8*w;y=i//8*h;box=(x,y,x+w,y+h);r=score(actual.crop(box),native.crop(box),24 if theme=='dark' else 255)
       r.update(font=family,size=size,phase_eighths=phase,theme=theme,glyph_id=gid,codepoints=mapping.get(gid,[]))
       # Any ink touching the cell edge needs a larger capture before judging.
       for img in [actual,native]:
        cell=img.crop(box).convert('L');bg=24 if theme=='dark' else 255
        if any(cell.crop(edge).getextrema()!=(bg,bg) for edge in [(0,0,w,1),(0,h-1,w,h),(0,0,1,h),(w-1,0,w,h)]):r['capture_edge_warning']=True
       if r.get('capture_edge_warning'):r['exact']=False
       seen+=1;size_seen+=1;exact+=r['exact'];size_exact+=r['exact']
       if not r['exact']:
        rows.append(r);batch_worst=max(batch_worst,r['ink_mae'])
      if batch_worst>20 and (len(worst)<6 or batch_worst>worst[-1][0]):
       name=f'{size}-p{phase}-{theme}-g{first}'
       actual.save(out/(name+'-aurora.png'));native.save(out/(name+'-native.png'));(out/(name+'.json')).write_text(json.dumps(info))
       worst.append((batch_worst,name));worst.sort(reverse=True);worst=worst[:6]
   print(f'{family} {size}px: exact {size_exact}/{size_seen}; elapsed {time.perf_counter()-start:.1f}s',flush=True)
   result={'font':family,'font_sha256':hashlib.sha256(Path(font).read_bytes()).hexdigest(),'glyph_count':count,'tested':seen,'exact':exact,'failed':seen-exact,'columns':['size','phase_eighths','theme','glyph_id','different_pixels','maximum_channel_error','ink_mae','capture_edge_warning'],'codepoints':mapping,'failures':[[r.get(k,False) for k in ['size','phase_eighths','theme','glyph_id','different_pixels','maximum_channel_error','ink_mae','capture_edge_warning']] for r in rows],'worst_sheets':worst,'seconds':time.perf_counter()-start}
   (audit.HERE/f'full-{label}'/f'{family}.json').write_text(json.dumps(result,separators=(',',':')))
 finally:ref.close()
 return result


def main():
 p=argparse.ArgumentParser();p.add_argument('--label',default='current');p.add_argument('--charset',choices=['all','ascii'],default='all');p.add_argument('--min-size',type=int);p.add_argument('--max-size',type=int);p.add_argument('--fonts',nargs='+',default=list(audit.diagnose.FONTS));p.add_argument('--sizes',type=int,nargs='+',default=[13,17,26]);p.add_argument('--phases',type=int,nargs='+',default=[0]);p.add_argument('--themes',nargs='+',default=['light']);p.add_argument('--limit',type=int,default=0);p.add_argument('--hinter',type=Path);p.add_argument('--source-dir',type=Path);args=p.parse_args()
 if args.min_size is not None or args.max_size is not None:
  assert args.min_size and args.max_size and 1<=args.min_size<=args.max_size<=256
  args.sizes=list(range(args.min_size,args.max_size+1))
 source_paths=[audit.CORE/'source/aurora/text'/name for name in ['hinter.d','rasterizer.d','truetype.d','atlas.d','alphacorrection.d','coverage.d','fontprofile.d']]
 source_hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths}
 modules={p.stem:p.read_text() for p in source_paths}
 if args.source_dir:
  for p in args.source_dir.glob('*.d'):modules[p.stem]=p.read_text()
 source=args.hinter.read_text() if args.hinter else modules['hinter'];modules['hinter']=source
 exe=compile_fixture('full-fixture-'+args.label,modules);(audit.HERE/f'full-{args.label}').mkdir(exist_ok=True)
 results=[]
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
  fs=[pool.submit(font_suite,f,exe,args.sizes,args.phases,args.themes,args.limit,args.label,args.charset) for f in args.fonts]
  for f in concurrent.futures.as_completed(fs):results.append(f.result())
 summary={'status':'pass' if all(r['failed']==0 for r in results) else 'FAIL','font_count':len(results),'tested':sum(r['tested'] for r in results),'exact':sum(r['exact'] for r in results),'failed':sum(r['failed'] for r in results),'sizes':args.sizes,'phases':args.phases,'themes':args.themes,'all_glyphs':not args.limit and args.charset=='all','charset':args.charset,'compiled_hinter_text_sha256':hashlib.sha256(source.encode()).hexdigest(),'shared_source_sha256':source_hashes,'fixture_sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'compiled_module_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (exe.parent/'source/aurora/text').glob('*.d')}}
 (audit.HERE/('conformance-'+args.label+'.json')).write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2));return int(summary['failed']>0)

if __name__=='__main__':raise SystemExit(main())
