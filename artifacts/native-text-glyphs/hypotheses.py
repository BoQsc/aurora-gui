"""Reproduce excluded hypotheses using the preserved pre-fix renderer sources."""
import concurrent.futures
import json

from experiments import HERE, diagnose, cutin, curve_flags


def main():
    h=(HERE/'baseline-refined/hinter.d').read_text()
    t=(HERE/'baseline-refined/truetype.d').read_text()
    def fine(tolerance):
        start=t.index('        const estimate =',t.index('    private static void appendQuadratic'))
        end=t.index('        auto previous = from;',start)
        return t[:start]+f'''        const dx = from.x - 2 * control.x + to.x;
        const dy = from.y - 2 * control.y + to.y;
        const deviation = sqrt(dx * dx + dy * dy) * scale * 0.25;
        int segments = cast(int) ceil(sqrt(deviation / {tolerance}));
        if (segments < 1) segments = 1;
        if (segments > 128) segments = 128;
'''+t[end:]
    post=cutin(h).replace('        return freeVectorX == 0 && freeVectorY != 0 &&',
        '        if (iupAxes == 3) return false;\n        return freeVectorX == 0 && freeVectorY != 0 &&',1)
    repeated=post.replace('                ctx.iupAxes |= 1u << (opcode & 1);',
        '                if (ctx.naturalGrid && ctx.glyphProgram && (ctx.instructControl & 4) == 0 && ctx.iupAxes == 3) return;\n                ctx.iupAxes |= 1u << (opcode & 1);')
    groups={
        'curve-range-experiments.json':{'curve-ranges':curve_flags(h,t,True),'mirp-curves':curve_flags(cutin(h),t,True)},
        'curve-precision-experiments.json':{'mirp-fine64':(cutin(h),fine('0.015625')),'mirp-fine256':(cutin(h),fine('0.00390625'))},
        'post-iup-experiments.json':{'mirp-post-delta':(post,t),'mirp-post-iup':(repeated,t)}}
    for file,cases in groups.items():
        results={}
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            futures=[pool.submit(diagnose.measure,name,source,truetype=tt,experiment='native-refined',current=True)
                     for name,(source,tt) in cases.items()]
            for future in concurrent.futures.as_completed(futures):
                name,rows=future.result();results[name]=rows
        (HERE/file).write_text(json.dumps(results,indent=2))


if __name__=='__main__':main()
