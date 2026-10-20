"""Bound quadratic flattening error instead of choosing segments by length."""
import concurrent.futures
import json

from diagnose import measure, variants, HERE, BASELINE
from signature_experiments import signature_variant


def curve_source(tolerance):
    source = (BASELINE / "truetype.d").read_text("utf-8")
    start = source.index("        const estimate =", source.index("    private static void appendQuadratic"))
    end = source.index("        auto previous = from;", start)
    return source[:start] + f"""        // Maximum quadratic chord deviation falls with the square of N.
        const dx = from.x - 2 * control.x + to.x;
        const dy = from.y - 2 * control.y + to.y;
        const deviation = sqrt(dx * dx + dy * dy) * scale * 0.25;
        int segments = cast(int) ceil(sqrt(deviation / {tolerance}));
        if (segments < 1) segments = 1;
        if (segments > 128) segments = 128;
""" + source[end:]


def main():
    source = variants()["C"]
    cases = {"curves-64": (source, curve_source("0.015625")),
             "curves-256": (source, curve_source("0.00390625")),
             "curves-vacuform": (signature_variant(source, spacing=False),curve_source("0.015625"))}
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for future in concurrent.futures.as_completed([pool.submit(measure,n,s,t) for n,(s,t) in cases.items()]):
            name,rows=future.result();results[name]=rows
    baseline = json.loads((HERE/"cutin-experiments.json").read_text())["comparisons"]["C"]
    summary={}
    for name,rows in results.items():
        summary[name]={"improved":sum(a["monitor_error"]<b["monitor_error"] for a,b in zip(rows,baseline)),
            "regressed":sum(a["monitor_error"]>b["monitor_error"] for a,b in zip(rows,baseline)),
            "equal":sum(a["monitor_error"]==b["monitor_error"] for a,b in zip(rows,baseline)),
            "monitor_mean":sum(a["monitor_error"] for a in rows)/len(rows),
            "neutral_mean":sum(a["neutral_error"] for a in rows)/len(rows)}
    (HERE/"curve-experiments.json").write_text(json.dumps({"default_changed":False,"summary":summary,
        "comparisons":results},indent=2),encoding="utf-8")
    print(json.dumps(summary,indent=2))


if __name__ == "__main__":main()
