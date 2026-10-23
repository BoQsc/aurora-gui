"""Prototype vertical dropout controls against whole glyphs, never font names."""
import json,concurrent.futures
import audit

h=(audit.CORE/'source/aurora/text/hinter.d').read_text();base=(audit.CORE/'source/aurora/text/rasterizer.d').read_text();t=(audit.CORE/'source/aurora/text/truetype.d').read_text()
a=base.index('private void rasterizeNativeSampledCoverage(');b=base.index('\nunittest',a);old=base[a:b]
# Retain all individual sample hits so dropout insertions cannot double-count.
new=old.replace('bool[] hits = new bool[cast(size_t) width * samplesX];','bool[] hits = new bool[cast(size_t) width * samplesX];\n    bool[] allHits = new bool[cast(size_t) width * samplesX * height * samplesY];')
new=new.replace('if (covered) ++counts[sample / samplesX];','if (covered) { ++counts[sample / samplesX]; allHits[(cast(size_t)y*samplesY+sy)*width*samplesX+sample] = true; }')
# Keep original writes, then revise alpha from the union of normal/dropout hits.
new=new[:new.rfind('}')] + '''
    foreach (sx; 0 .. width * samplesX)
    {
        const xc = (sx + 0.5) / samplesX;
        crossings.length = 0;
        foreach (original; edges)
        {
            OutlineEdge edge = OutlineEdge(original.y0, original.x0, original.y1, original.x1,
                original.cy, original.cx, original.quadratic);
            if (xc < min(edge.y0,edge.y1) || xc >= max(edge.y0,edge.y1)) continue;
            crossings ~= Crossing(edge.xAtY(xc),edge.y1>edge.y0?1:-1);
        }
        crossings.sort!((a,b)=>a.x<b.x);
        int winding;
        double low;
        foreach (crossing; crossings)
        {
            const previous = winding;
            winding += crossing.winding;
            if (previous == 0 && winding != 0) low = crossing.x;
            if (previous != 0 && winding == 0 && crossing.x > low)
            {
                const first = cast(int) ceil(low*samplesY-0.5);
                const last = cast(int) floor(crossing.x*samplesY-0.5);
                if (last >= first) continue;
                const target = TARGET;
                if (target >= 0 && target < height*samplesY)
                    allHits[cast(size_t)target*width*samplesX+sx] = true;
            }
        }
    }
    foreach (y; 0 .. height)
    foreach (x; 0 .. width)
    {
        int count;
        foreach (sy; 0 .. samplesY)
        foreach (sx; 0 .. samplesX)
            if (allHits[(cast(size_t)y*samplesY+sy)*width*samplesX+x*samplesX+sx]) ++count;
        const total=samplesX*samplesY;
        alpha[cast(size_t)y*width+x]=cast(ubyte)((count*255+(total-1)/2)/total);
    }
}
'''
# Bitmap y grows downward; native lower design-space pixel means higher bitmap index.
cases={n:base[:a]+new.replace('TARGET',v)+base[b:] for n,v in [('drop-low','first'),('drop-high','last'),('drop-nearest','cast(int)floor((low+crossing.x)*samplesY/2)')]}

def run(n,r):
 exe=audit.compile(n,{'hinter':h,'rasterizer':r});result=audit.measure(n,exe,families=list(audit.diagnose.FONTS),sizes=[12,13,17,26]);return n,result
results={}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 for f in concurrent.futures.as_completed([pool.submit(run,n,r) for n,r in cases.items()]):
  n,rows=f.result();results[n]=rows
  print(n,[(font,ch,size,next(r['error'] for r in rows if r['font']==font and r['size']==size and r['character']==ch)) for font,ch,size in [('times','>',12),('courier','*',12),('courier','g',17),('arial','A',17)]],flush=True)
(audit.HERE/'dropout-hypotheses.json').write_text(json.dumps(results,indent=2))
