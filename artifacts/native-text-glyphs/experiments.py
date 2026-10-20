"""Isolate 17px numeral and Courier outline hypotheses, preserving C/D/refined."""
import concurrent.futures
import json
from pathlib import Path
import sys

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
sys.path.insert(0,str(HERE.parent/'native-text-next'))
import diagnose
diagnose.BUILD=ROOT/'build-validation/native-text-glyphs/experiments'


def cutin(source,asymmetric=False):
    start=source.index('        long distance = cvtDist;',source.index('    void mirp('))
    end=source.index('        if ((opcode & 8)',start)
    return source[:start]+'''        // Research: tighten horizontal unrounded MIRP too.
        if (((opcode & 4) != 0 ||
             (naturalGrid && glyphProgram && projVectorY == 0 &&
              (instructControl & 4) == 0''' + (' && !naturalSymmetric' if asymmetric else '') + ''')) &&
            zoneSelect0 == zoneSelect1)
        {
            delta = cvtDist - orgDist;
            if (delta < 0) delta = -delta;
            if (delta > effectiveCutIn()) cvtDist = orgDist;
        }
        long distance = (opcode & 4) != 0 ? roundDistance(cvtDist, 0) : roundNone(cvtDist, 0);

'''+source[end:]


def curve_flags(hinter,truetype,ranges=False):
    hinter=hinter.replace('result.onCurve[i] = input.onCurve[i];','result.onCurve[i] = ctx.zone2.points[i].onCurve;')
    truetype=truetype.replace('fitAdvance = fitted.advance;','rawOnCurve[] = fitted.onCurve[];\n                fitAdvance = fitted.advance;')
    if ranges:
        hinter=hinter.replace('const low = cast(int) ctx.pop();\n                const high = cast(int) ctx.pop();',
            'const high = cast(int) ctx.pop();\n                const low = cast(int) ctx.pop();')
    return hinter,truetype


def main():
    h=(HERE/'baseline-refined/hinter.d').read_text()
    t=(HERE/'baseline-refined/truetype.d').read_text()
    cases={'mirp-all':(cutin(h),t),'mirp-asymmetric':(cutin(h,True),t),'curve-flags':curve_flags(h,t)}
    results={}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        tasks=[pool.submit(diagnose.measure,name,source,truetype=tt,experiment='native-refined',current=True)
               for name,(source,tt) in cases.items()]
        for future in concurrent.futures.as_completed(tasks):
            name,rows=future.result();results[name]=rows
    baseline=json.loads((HERE.parent/'native-text-refined/measurements.json').read_text())['comparisons']['refined-D']
    summary={}
    for name,rows in results.items():
        summary[name]={'improved':sum(a['monitor_error']<b['monitor_error'] for a,b in zip(rows,baseline)),
            'regressed':sum(a['monitor_error']>b['monitor_error'] for a,b in zip(rows,baseline)),
            'equal':sum(a['monitor_error']==b['monitor_error'] for a,b in zip(rows,baseline)),
            'mean':sum(a['monitor_error'] for a in rows)/len(rows),
            'regressions':[{'candidate':a,'baseline':b} for a,b in zip(rows,baseline) if a['monitor_error']>b['monitor_error']]}
    (HERE/'experiments.json').write_text(json.dumps({'summary':summary,'comparisons':results},indent=2))
    print(json.dumps({name:{k:v for k,v in row.items() if k!='regressions'} for name,row in summary.items()},indent=2))


if __name__=='__main__':main()
