"""Isolate legacy post-IUP and horizontal compatibility from native hinting."""
import concurrent.futures
import json

from diagnose import measure, variants, HERE
from signature_experiments import signature_variant


def post_iup(source, freeze=False, raw_x=False):
    source = signature_variant(source, vacuform=True, spacing=False)
    source = source.replace("        return freeVectorX == 0 && freeVectorY != 0 &&",
                            "        if (iupAxes == 3) return false;\n        return freeVectorX == 0 && freeVectorY != 0 &&")
    source = source.replace("                ctx.iupAxes |= 1u << (opcode & 1);", """                if (ctx.naturalGrid && ctx.glyphProgram && (ctx.instructControl & 4) == 0 &&
                    ctx.iupAxes == 3) return;
                ctx.iupAxes |= 1u << (opcode & 1);""")
    if freeze:
        source = source.replace("        requirePoint(zone, point);\n        if (freeVectorX != 0)", """        requirePoint(zone, point);
        if (naturalGrid && glyphProgram && (instructControl & 4) == 0 && iupAxes == 3) return;
        if (freeVectorX != 0)""", 1)
    if raw_x:
        source = source.replace("result.xs26Dot6[i] = ctx.zone2.points[i].curX;", """result.xs26Dot6[i] = ctx.naturalGrid && (ctx.instructControl & 4) == 0 ?
                ctx.scaleDesign(input.xs[i]) : ctx.zone2.points[i].curX;""")
        source = source.replace("result.originX26Dot6 = ctx.zone2.points[n].curX;", """result.originX26Dot6 = ctx.naturalGrid && (ctx.instructControl & 4) == 0 ?
            0 : ctx.zone2.points[n].curX;""")
    return source


def main():
    source = variants()["C"]
    cases = {"post-delta": post_iup(source), "post-move": post_iup(source, freeze=True),
             "legacy-raw-x": post_iup(source, raw_x=True),
             "post-cutin": post_iup(variants()["both-cutin"], freeze=True)}
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for future in concurrent.futures.as_completed([pool.submit(measure,n,s) for n,s in cases.items()]):
            name, rows = future.result()
            results[name] = rows
    baseline = json.loads((HERE / "cutin-experiments.json").read_text())["comparisons"]["C"]
    summaries = {}
    for name,rows in results.items():
        summaries[name] = {"improved":sum(a["monitor_error"]<b["monitor_error"] for a,b in zip(rows,baseline)),
            "regressed":sum(a["monitor_error"]>b["monitor_error"] for a,b in zip(rows,baseline)),
            "equal":sum(a["monitor_error"]==b["monitor_error"] for a,b in zip(rows,baseline)),
            "monitor_mean":sum(a["monitor_error"] for a in rows)/len(rows),
            "neutral_mean":sum(a["neutral_error"] for a in rows)/len(rows)}
    (HERE / "iup-experiments.json").write_text(json.dumps({"default_changed":False,"summary":summaries,
        "comparisons":results},indent=2),encoding="utf-8")
    print(json.dumps(summaries,indent=2))


if __name__ == "__main__":
    main()
