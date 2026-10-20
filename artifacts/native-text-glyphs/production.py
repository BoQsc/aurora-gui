"""Compare C, reviewed D and refined D from the real shared source."""
import concurrent.futures
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

from PIL import Image

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
sys.path.insert(0,str(HERE.parent/'native-text-next'))
import diagnose

diagnose.BUILD=ROOT/'build-validation/native-text-glyphs/corpus'


def main():
    source=(diagnose.CORE/'source/aurora/text/hinter.d').read_text()
    results={}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        futures=[pool.submit(diagnose.measure,name,source,experiment=experiment,current=True)
                 for name,experiment in (('C',None),('D','native-next'),('refined-D','native-refined'))]
        for future in concurrent.futures.as_completed(futures):
            name,rows=future.result();results[name]=rows
    previous=json.loads((HERE.parent/'native-text-next/measurements.json').read_text())
    assert results['C']==previous['comparisons']['verified-C']
    assert results['D']==previous['comparisons']['D']
    for profile,old in [('C','verified-C'),('D','D')]:
        for family in diagnose.FONTS:
            for size in diagnose.SIZES:
                for theme in ['light','dark']:
                    name=f'{family}-{size}-{theme}-aurora.png'
                    a=Image.open(diagnose.BUILD/profile/name).convert('RGB')
                    b=Image.open(ROOT/'build-validation/native-text-next'/old/name).convert('RGB')
                    assert a.tobytes()==b.tobytes(),(profile,name)
    results['before-refined-D']=json.loads((HERE.parent/'native-text-refined/measurements.json').read_text())['comparisons']['refined-D']
    summary={}
    for profile in ['C','D','before-refined-D']:
        rows=results['refined-D'];base=results[profile]
        summary[profile]={
            'improved':sum(a['monitor_error']<b['monitor_error'] for a,b in zip(rows,base)),
            'regressed':sum(a['monitor_error']>b['monitor_error'] for a,b in zip(rows,base)),
            'equal':sum(a['monitor_error']==b['monitor_error'] for a,b in zip(rows,base)),
            'baseline_mean':sum(a['monitor_error'] for a in base)/len(base),
            'refined_mean':sum(a['monitor_error'] for a in rows)/len(rows)}
    files=[diagnose.CORE/('source/aurora/text/'+p+'.d') for p in ['hinter','truetype','rasterizer','atlas','coverage','alphacorrection','fontprofile']]
    files += [diagnose.CORE/'source/aurora/font.d',diagnose.CORE/'tests/font_quality.d',ROOT/'scripts/compare-font-rendering.py']
    files += [diagnose.CORE/p for p in ['source/aurora/render/vulkan.d','source/aurora/vulkan/shaders.d',
        'tools/make_spirv.py','licenses/Microsoft-Terminal-MIT.txt']]
    native=diagnose.ref.NativeReference(diagnose.FONTS['segoe'])
    native_settings=native.settings
    native.close()
    data={'default':'owner-approved C','reviewed_D_decision':'Keep C; continue improving D',
          'refined_override':'AURORA_TEXT_EXPERIMENT=native-refined','C_D_pixels_unchanged':True,
          'summary':summary,'comparisons':results,'native_settings':native_settings,
          'font_sha256':{family:hashlib.sha256(Path(path).read_bytes()).hexdigest() for family,path in diagnose.FONTS.items()},
          'source_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}
    (HERE/'measurements.json').write_text(json.dumps(data,indent=2))
    print(json.dumps(summary,indent=2))


if __name__=='__main__':main()
