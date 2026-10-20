"""Test native closing-edge inclusion and scanline dropout retention."""
import concurrent.futures
import json

from diagnose import measure, variants, BASELINE, HERE
from signature_experiments import signature_variant


def scan_source(dropout=False):
    source=(BASELINE/"rasterizer.d").read_text("utf-8")
    start=source.index("            foreach (crossing; crossings)",source.index("void rasterizeSampledCoverage"))
    end=source.index("        const total = samplesX * samplesY;",start)
    source=source[:start]+"""            foreach (crossing; crossings)
            {
                const previousWinding = winding;
                winding += crossing.winding;
                if (previousWinding == 0 && winding != 0) left = crossing.x;
                if (previousWinding != 0 && winding == 0)
                {
                    const start = max(0.0, min(cast(double) width, left));
                    const stop = max(0.0, min(cast(double) width, crossing.x));
                    int first = cast(int) ceil(start * samplesX - 0.5);
                    int last = cast(int) floor(stop * samplesX - 0.5) + 1;
"""+("""                    if (last <= first && stop > start)
                    {
                        first = cast(int) floor((start + stop) * 0.5 * samplesX);
                        last = first + 1;
                    }
""" if dropout else "")+"""                    first = max(0, first); last = min(width * samplesX, last);
                    foreach (sample; first .. last) counts[sample / samplesX]++;
                }
            }
        }
"""+source[end:]
    source=source.replace("(counts[x] * 255 + total / 2) / total", "(min(counts[x], total) * 255 + total / 2) / total")
    return source


def main():
    source=variants()["C"]
    cases={"right-ties":(source,scan_source()),"scan-dropouts":(source,scan_source(True)),
           "scan-vacuform":(signature_variant(source,spacing=False),scan_source(True))}
    records={}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for future in concurrent.futures.as_completed([pool.submit(measure,n,s,None,r) for n,(s,r) in cases.items()]):
            name,rows=future.result();records[name]=rows
    base=json.loads((HERE/"cutin-experiments.json").read_text())["comparisons"]["C"];summary={}
    for name,rows in records.items():
        summary[name]={"improved":sum(a["monitor_error"]<b["monitor_error"] for a,b in zip(rows,base)),
            "regressed":sum(a["monitor_error"]>b["monitor_error"] for a,b in zip(rows,base)),
            "equal":sum(a["monitor_error"]==b["monitor_error"] for a,b in zip(rows,base)),
            "mean":sum(a["monitor_error"] for a in rows)/len(rows)}
    (HERE/"scan-experiments.json").write_text(json.dumps({"default_changed":False,"summary":summary,
        "comparisons":records},indent=2),encoding="utf-8")
    print(json.dumps(summary,indent=2))


if __name__=="__main__":main()
