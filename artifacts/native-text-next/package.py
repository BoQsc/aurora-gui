"""Package C/D evidence without recording approval or changing the default."""
import hashlib
from html import escape
import json
from pathlib import Path
import re
import sys

from PIL import Image, ImageDraw, ImageFont

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
BUILD=ROOT/"build-validation/native-text-next"
sys.path.insert(0,str(HERE.parent/"text-coverage-candidate"))
from review import make_review


def main():
    data=json.loads((HERE/"measurements.json").read_text());s=data["summary"]
    validation=json.loads((HERE/"validation.json").read_text()) if (HERE/"validation.json").exists() else None
    passed=validation is not None and all(r["exit_code"]==0 for c in validation["checks"] for r in c["records"])
    captures=json.loads((HERE/"captures.json").read_text())
    gpu=[]
    for r in captures:
        m=re.search(r"(C|D) Vulkan screen capture.*DPI=(\d+); differing pixels=(\d+); maximum channel error=(\d+); rejected frames=(\d+)",r["output"])
        if m:gpu.append(dict(zip(("profile","dpi","different_pixels","max_error","rejected_frames"),m.groups())))
    font=ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf",13)
    panels=[]
    for family,size,theme in (("segoe",13,"light"),("segoe",13,"dark"),("consolas",17,"light"),
                              ("arial",13,"light"),("courier",13,"light"),("inter",13,"light")):
        name=f"{family}-{size}-{theme}"
        ims=[Image.open(BUILD/p/(name+suffix+".png")).convert("RGB") for p,suffix in
             (("verified-C","-aurora"),("D","-aurora"),("D","-native"))]
        panel=Image.new("RGB",(max(im.width for im in ims)+175,35+sum(im.height+7 for im in ims)),"#e3e7ee")
        draw=ImageDraw.Draw(panel);draw.text((8,5),f"{family}, {size}px, {theme} — actual pixels",font=font,fill="black")
        y=35
        for label,im in zip(("Approved C","Candidate D","Windows grayscale"),ims):
            draw.text((8,y+5),label,font=font,fill="black");panel.paste(im,(170,y));y+=im.height+7
        panels.append(panel)
    montage=Image.new("RGB",(max(p.width for p in panels),sum(p.height+8 for p in panels)),"#c8cfd9");y=0
    for panel in panels:montage.paste(panel,(0,y));y+=panel.height+8
    montage.save(HERE/"comparison.png")
    if (HERE/"padpp-live-D.png").exists():
        make_review(HERE/"padpp-live-C.png",HERE/"padpp-live-D.png",
                    "Pad++ live 125% DPI: approved C / candidate D",HERE/"padpp-live-120")
    rows=[]
    for c,d in zip(data["comparisons"]["verified-C"],data["comparisons"]["D"]):
        delta=d["monitor_error"]-c["monitor_error"]
        rows.append(f'<tr><td>{c["font"]}</td><td>{c["size"]}</td><td>{c["theme"]}</td><td>{c["monitor_error"]:.3f}</td><td>{d["monitor_error"]:.3f}</td><td>{delta:+.3f}</td></tr>')
    app_rows=[]
    for app,themes in (("notepad",("light","dark")),("host",("light","dark")),("padpp",("light",))):
        for theme in themes:
            app_rows.append(f'<tr><td>{app}</td><td>{theme}</td>'+''.join(f'<td><a href="{app}-{theme}-{dpi}/review.html">{dpi} DPI</a></td>' for dpi in (96,144))+'</tr>')
    gpu_rows=''.join('<tr>'+''.join(f'<td>{escape(g[key])}</td>' for key in ("profile","dpi","different_pixels","max_error","rejected_frames"))+'</tr>' for g in gpu)
    improvement=100*(1-s["D_mean"]/s["C_mean"])
    html=f'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Aurora candidate D — native text progress</title><style>
body{{font:16px/1.6 'Segoe UI',sans-serif;margin:35px auto;max-width:1100px;padding:0 22px;background:#f8fafc;color:#172033}}
a{{color:#164bad}}.status{{padding:16px;border-left:4px solid #cb9611;background:#fff3cd}}img{{max-width:100%;height:auto}}
table{{border-collapse:collapse}}td,th{{border:1px solid #ccd3dc;padding:6px 12px;text-align:left}}code{{background:#e8edf3;padding:3px}}.scroll{{overflow:auto}}</style>
<h1>Aurora candidate D: closing native scan-conversion gaps</h1><p>20 October 2026 · pure-D rendering · DirectWrite grayscale reference</p>
<p class="status"><b>C remains the approved default. The owner chose to keep C and continue improving D.</b> D improves {s["improved"]}/144 comparisons,
leaves {s["equal"]} equal and regresses {s["regressed"]}. Average native error falls from {s["C_mean"]:.3f} to {s["D_mean"]:.3f} ({improvement:.1f}%).
Approved C pixels are unchanged. Exact native parity remains unachieved.</p>
<p><b>Start here:</b> <a href="padpp-live-120/review.html">Live Pad++ at 125% DPI: C versus D</a> ·
<a href="README.md">Implementation, failed experiments and limits</a> · <a href="validation.json">Validation record</a></p>
<h2>What D changes</h2><p>Native scan conversion includes samples exactly on closing outline edges and rounds exact half-alpha ties down.
D also recognizes the documented legacy TypeMan VacuFormRound function after IUP on both axes, while respecting the font's INSTCTRL opt-out.
These fixes share the existing A8 atlas and software/Vulkan paths; there is no native rasterizer in Aurora.</p>
<p>The test-only override is <code>AURORA_TEXT_EXPERIMENT=native-next</code>, set before startup. Leave it unset for C.
The coverage policy, contrast default, layout, font metrics and existing ink guard are unchanged.</p>
<h2>Actual font pixels</h2><p>Rows are C, D, then this machine's Windows grayscale reference. Glyph IDs and origins match; this isolates rasterization from shaping.</p>
<img src="comparison.png" alt="Approved C, candidate D and Windows grayscale font comparison">
<h2>Application reviews</h2><p>Matched light/dark layouts use actual 96/144 DPI framebuffers. Pad++ at 150% is 1770×1140 pixels.</p>
<table><tr><th>Application</th><th>Theme</th><th>100%</th><th>150%</th></tr>{''.join(app_rows)}</table>
<h2>Validation</h2><p>Full validation status: <b>{'passed for C and D' if passed else 'not yet complete'}</b>.
The record includes coverage/cache, 1,872 font cases per profile, instruction/scan-conversion unittests, DPI/window-DPI,
7,200 Windows glyph/size cases per profile with reverse replay, standards/Python checks, full host interactions and full Pad++ workflows.</p>
<p>GPU probes captured two changing, validated window states per profile. Differences below are against software over both states.</p>
<table><tr><th>Profile</th><th>DPI</th><th>Differing pixels</th><th>Max channel error</th><th>Rejected stale/obscured frames</th></tr>{gpu_rows}</table>
<p>D's remaining software/Vulkan differences are at most one channel level. Rejected frames are excluded from accepted captures.
<a href="captures.json">Capture commands and results</a>. The unrelated older Notepad drag/restore smoke failure remains documented.</p>
<details><summary>All 144 native comparisons</summary><div class="scroll"><table><tr><th>Font</th><th>px</th><th>Theme</th><th>C error</th><th>D error</th><th>Delta</th></tr>{''.join(rows)}</table></div></details>
<p><a href="measurements.json">Measurements and source hashes</a> · <a href="proposal.json">Concrete promotion proposal</a> ·
<a href="../native-text-progress/index.html">Approved C review history</a></p></html>'''
    (HERE/"index.html").write_text(html,encoding="utf-8")
    proposal={"status":"pending-owner-review","baseline":"C","candidate":"D",
              "default_changed":False,"changes":["Closing-edge sample inclusion","Native half-alpha quantization","Recognized post-IUP VacuFormRound compatibility"],
              "coverage_default":"foreground","contrast_default":0.5,"ink_guard":0.039,"summary":s,
              "review":"index.html","live_application_review":"padpp-live-120/review.html","decision":None}
    path=HERE/"proposal.json"
    if not path.exists() or json.loads(path.read_text()).get("decision") is None:path.write_text(json.dumps(proposal,indent=2),encoding="utf-8")
    files=[p for p in HERE.rglob('*') if p.is_file() and p.name!='manifest.json' and '__pycache__' not in p.parts]
    (HERE/"manifest.json").write_text(json.dumps({"default":"approved C","D_status":"keep-C-and-refine-D",
        "sha256":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}},indent=2),encoding="utf-8")
    print(HERE/"index.html")


if __name__=="__main__":main()
