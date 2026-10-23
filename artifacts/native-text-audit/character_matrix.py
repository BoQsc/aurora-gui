"""Expose every character and every regression instead of averaging whole lines."""
import hashlib
import concurrent.futures
import json
import os
import subprocess

from PIL import Image

import audit


def profile(exe,label,families,sizes,phases,themes,experiment='native-refined'):
    records=[]
    for family in families:
        native=audit.diagnose.ref.NativeReference(audit.diagnose.FONTS[family])
        try:
            for size in sizes:
                for phase in phases:
                    for theme in themes:
                        name=f'{family}-{size}-p{phase}-{theme}'
                        prefix=audit.BUILD/label/name
                        prefix.parent.mkdir(parents=True,exist_ok=True)
                        env=os.environ.copy()
                        env.update(AURORA_HINTING='natural',AURORA_TEXT_EXPERIMENT='native-refined',
                            AURORA_TEXT_COVERAGE='foreground',AURORA_TEXT_CONTRAST='0.5',
                            AURORA_TEST_PHASE=str(phase/8),AURORA_TEST_DARK='1' if theme=='dark' else '0')
                        if experiment is None:env.pop('AURORA_TEXT_EXPERIMENT',None)
                        else:env['AURORA_TEXT_EXPERIMENT']=experiment
                        env.pop('AURORA_TEXT_GAMMA',None)
                        env.pop('AURORA_TEST_CHARACTER',None)
                        subprocess.run([str(exe),audit.diagnose.FONTS[family],str(size),str(prefix)],check=True,env=env,capture_output=True)
                        info=json.loads(prefix.with_suffix('.json').read_text())
                        actual=Image.open(prefix.with_suffix('.ppm')).convert('RGB');target=native.render(info,theme=='dark')
                        actual.save(str(prefix)+'-aurora.png');target.save(str(prefix)+'-native.png')
                        for glyph in info['glyphs']:
                            cell=glyph['cell'];w=info['cell_width'];h=info['cell_height'];x=cell%16*w;y=cell//16*h
                            a=actual.crop((x,y,x+w,y+h));b=target.crop((x,y,x+w,y+h))
                            error=audit.diagnose.ref.grayscale_error(a,b,24 if theme=='dark' else 255)['mean_absolute_error']
                            records.append([family,size,phase,theme,glyph['codepoint'],error])
        finally:native.close()
        print(label,family,'complete',flush=True)
    return records


def summary(before,after):
    assert len(before)==len(after) and all(a[:5]==b[:5] for a,b in zip(before,after))
    return {'improved':sum(a[5]<b[5] for a,b in zip(after,before)),
        'equal':sum(a[5]==b[5] for a,b in zip(after,before)),
        'regressed':sum(a[5]>b[5] for a,b in zip(after,before)),
        'before_mean':sum(r[5] for r in before)/len(before),'after_mean':sum(r[5] for r in after)/len(after),
        'worst_before':max(r[5] for r in before),'worst_after':max(r[5] for r in after)}


def main():
    before=audit.compile('matrix-before',{name:(audit.HERE/'before-source'/f'{name}.d').read_text() for name in ['hinter','truetype','rasterizer']})
    after=audit.compile('matrix-after')
    results={}
    groups={'broad':(list(audit.diagnose.FONTS),list(audit.diagnose.SIZES),[0],['light']),
            'focused-17':(['consolas','courier'],[17],list(range(8)),['light','dark'])}
    for name,args in groups.items():
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            fs={label:pool.submit(profile,exe,'matrix-'+label,*args,experiment=None if label=='C' else 'native-refined') for label,exe in [('before',before),('after',after),('C',after)]}
            records={label:f.result() for label,f in fs.items()}
        results[name]={'columns':['font','size','phase_eighths','theme','codepoint','error'],
            'summary':summary(records['before'],records['after']),'comparisons':records}
        if name=='focused-17':
            results[name]['by_font']={family:summary([r for r in records['before'] if r[0]==family],
                [r for r in records['after'] if r[0]==family]) for family in args[0]}
    results['provenance']={'source_sha256':{str((audit.CORE/'source/aurora/text'/f'{name}.d').relative_to(audit.ROOT)):hashlib.sha256((audit.CORE/'source/aurora/text'/f'{name}.d').read_bytes()).hexdigest() for name in ['hinter','truetype','rasterizer']},
        'before_git_revision':json.loads((audit.HERE/'before-source/provenance.json').read_text())['git_revision']}
    (audit.HERE/'character-matrix.json').write_text(json.dumps(results,indent=2))
    print(json.dumps({k:{'summary':v['summary'],'by_font':v.get('by_font')} for k,v in results.items() if k!='provenance'},indent=2))


if __name__=='__main__':
    import sys
    if '--approved-only' in sys.argv:
        results=json.loads((audit.HERE/'character-matrix.json').read_text())
        exe=audit.compile('matrix-approved-C')
        groups={'broad':(list(audit.diagnose.FONTS),list(audit.diagnose.SIZES),[0],['light']),
                'focused-17':(['consolas','courier'],[17],list(range(8)),['light','dark'])}
        for name,args in groups.items():results[name]['comparisons']['C']=profile(exe,'matrix-C',*args,experiment=None)
        (audit.HERE/'character-matrix.json').write_text(json.dumps(results,indent=2))
    else:main()
