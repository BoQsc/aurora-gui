"""Verify the actual opt-in D implementation and preserve approved C pixels."""
import concurrent.futures
import hashlib
import json
from pathlib import Path

from PIL import Image
from diagnose import CORE, BUILD, HERE, ROOT, FONTS, SIZES, measure, ref


def main():
    source=(CORE/"source/aurora/text/hinter.d").read_text("utf-8")
    results={}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures=[pool.submit(measure,name,source,experiment=experiment,current=True)
                 for name,experiment in (("verified-C",None),("D","native-next"))]
        for future in concurrent.futures.as_completed(futures):
            name,rows=future.result();results[name]=rows
    previous=json.loads((HERE/"cutin-experiments.json").read_text())["comparisons"]["C"]
    assert results["verified-C"]==previous,"C measurements changed"
    for family in FONTS:
        for size in SIZES:
            for theme in ("light","dark"):
                name=f"{family}-{size}-{theme}-aurora.png"
                before=Image.open(BUILD/"C"/name).convert("RGB")
                after=Image.open(BUILD/"verified-C"/name).convert("RGB")
                assert before.tobytes()==after.tobytes(),name
    baseline=results["verified-C"];candidate=results["D"]
    summary={"improved":sum(a["monitor_error"]<b["monitor_error"] for a,b in zip(candidate,baseline)),
             "regressed":sum(a["monitor_error"]>b["monitor_error"] for a,b in zip(candidate,baseline)),
             "equal":sum(a["monitor_error"]==b["monitor_error"] for a,b in zip(candidate,baseline)),
             "C_mean":sum(a["monitor_error"] for a in baseline)/len(baseline),
             "D_mean":sum(a["monitor_error"] for a in candidate)/len(candidate)}
    sources=[CORE/('source/aurora/text/'+name+'.d') for name in ('hinter','truetype','rasterizer','atlas','coverage')]
    sources += [CORE/'tests/font_quality.d', ROOT/'scripts/compare-font-rendering.py']
    reference=ref.NativeReference(FONTS['segoe'])
    try: native_settings=reference.settings
    finally: reference.close()
    data={"baseline":"owner-approved C; no experiment override","candidate":"D: closing-edge inclusion, native alpha quantization and VacuFormRound compatibility",
          "candidate_override":"AURORA_TEXT_EXPERIMENT=native-next","default_changed":False,
          "approved_C_pixels_unchanged":True,"summary":summary,"comparisons":results,
          "native_settings":native_settings,
          "fonts":{family:{"path":path,"sha256":hashlib.sha256(Path(path).read_bytes()).hexdigest()} for family,path in FONTS.items()},
          "source_sha256":{str(p.relative_to(HERE.parents[1])):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
    (HERE/"measurements.json").write_text(json.dumps(data,indent=2),encoding="utf-8")
    print(json.dumps(summary,indent=2))


if __name__=="__main__":main()
