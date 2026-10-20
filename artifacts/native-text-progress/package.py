"""Package measurements and the recorded owner approval."""
from html import escape
import hashlib
import json
from pathlib import Path
import re
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / "build-validation/native-text-progress/corpus"
sys.path.insert(0, str(HERE.parent / "text-coverage-candidate"))
from review import make_review

data = json.loads((HERE / "measurements.json").read_text("utf-8"))
capture_records = json.loads((HERE / "captures.json").read_text("utf-8"))
gpu = {}
for record in capture_records:
    match = re.search(r"DPI=(\d+); differing pixels=(\d+); maximum channel error=(\d+); rejected frames=(\d+)", record["output"])
    if match:
        mode = "natural" if "gpu-natural" in record["command"][-1] else "baseline"
        gpu[mode] = dict(zip(("dpi", "pixels", "error", "rejected"), map(int, match.groups())))
font = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 13)
panels = []
for family, size, theme in (("tahoma", 18, "light"),):
    images = [Image.open(BUILD / (family + suffix) / filename).convert("RGB") for suffix, filename in (
        ("-baseline", f"{size}-{theme}-aurora.png"), ("-natural", f"{size}-{theme}-aurora.png"),
        ("-natural", f"{size}-{theme}-native-gray.png"))]
    height = images[0].height + 7
    panel = Image.new("RGB", (images[0].width + 230, 30 + 3 * height), "#e5e7eb")
    draw = ImageDraw.Draw(panel)
    draw.text((8, 6), f"{family} / {size}px / {theme} / resolved sampling mismatch / actual pixels", font=font, fill="black")
    for i, (label, image) in enumerate(zip(("B: previous default", "C: approved natural", "Windows grayscale"), images)):
        y = 30 + i * height
        draw.text((8, y + 5), label, font=font, fill="black")
        panel.paste(image, (210, y))
    panels.append(panel)
sheet = Image.new("RGB", (max(p.width for p in panels), sum(p.height + 8 for p in panels)), "#c9ced6")
y = 0
for panel in panels:
    sheet.paste(panel, (0, y)); y += panel.height + 8
sheet.save(HERE / "resolved-tahoma.png")

make_review(HERE / "host-workbench-legacy-96.png", HERE / "host-workbench-default-96.png",
            "Host workbench 96 DPI: former host weight / approved shared default",
            HERE / "host-workbench-weight")
make_review(HERE / "padpp-selftest-120dpi.png", HERE / "padpp-natural-selftest-120dpi.png",
            "Pad++ live 125% DPI: previous B / approved C",
            HERE / "padpp-live-120")
app_rows = []
for app, themes in (("notepad", ("light", "dark")), ("host", ("light", "dark")), ("padpp", ("light",))):
    for theme in themes:
        links = "".join(f'<td><a href="{app}-{theme}-{dpi}/review.html">{dpi} DPI</a></td>' for dpi in (96, 144))
        app_rows.append(f"<tr><td>{app}</td><td>{theme}</td>{links}</tr>")

rows = []
for item in data["comparisons"]:
    delta = item["natural_error"] - item["baseline_error"]
    kind = "regressed" if delta > 0 else "improved" if delta < 0 else "equal"
    rows.append(f'<tr data-font="{item["font"]}" data-kind="{kind}"><td>{item["font"]}</td>'
                f'<td>{item["size"]}</td><td>{item["theme"]}</td><td>{item["baseline_error"]:.2f}</td>'
                f'<td>{item["natural_error"]:.2f}</td><td class="{kind}">{delta:+.2f}</td></tr>')
options = "".join(f'<option>{family}</option>' for family in sorted({x["font"] for x in data["comparisons"]}))
html = """<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Aurora native text fidelity</title>
<style>body{font:16px/1.55 'Segoe UI',sans-serif;max-width:1100px;margin:35px auto;padding:0 22px;color:#172033;background:#f8fafc}
a{color:#164bad}table{border-collapse:collapse}td,th{padding:7px 14px;border:1px solid #ccd3dc;text-align:left}
img{max-width:100%;height:auto}.status{padding:16px;background:#e3f5e9;border-left:4px solid #287a44}
.improved{color:#12682f}.regressed{color:#a52020}select,button{font:inherit;padding:5px}code{background:#e8edf3;padding:3px}
.scroll{overflow:auto}details{margin:22px 0}input{accent-color:#164bad}tr[hidden]{display:none}</style>
<h1>Aurora native text fidelity</h1><p>20 October 2026 · pure-D renderer · Windows DirectWrite reference</p>
<p class="status"><b>C is the owner-approved shared default.</b> The owner selected “Make C the default” on 20 October 2026.
Foreground-aware coverage, repaired natural hinting and font-selected sampling reach rebuilt Aurora-D apps.
C improves __IMPROVED__ of __TOTAL__ comparisons and regresses in __REGRESSED__. Exact native parity remains unachieved.
<a href="decision.json">Decision and reviewed image hashes</a>.</p>
<p><a href="../text-coverage-candidate/index.html">Approved coverage review and decision</a> ·
<a href="README.md">Implementation and remaining work</a> · <a href="validation.json">Validation</a></p>
<p><b>Start with the real app:</b> <a href="padpp-live-120/review.html">Pad++ live 125% DPI comparison</a>.
The new default reproduces the reviewed C Pad++ screenshot pixel-for-pixel. Both modes pass the full editing workflow. C is lighter: the 125% host ink fixture is 0.0416.
The owner approved its revised 0.039 guard. Normal startup now uses C; <code>AURORA_HINTING=0</code> restores B.</p>
<h2>Native progress at 13 physical pixels</h2>
<p>Identical glyph IDs and origins isolate rasterization. Rows are B (previous default), C (approved natural hinting),
then Windows grayscale. Images retain actual pixels; browser scaling can affect perceived sharpness.</p>
<img src="native-comparison.png" alt="Segoe UI and Consolas, light and dark, baseline, natural hinting, Windows">
<h2>Closing the final Tahoma regression</h2>
<p>The font's smoothing choice now selects its 8×1 or 4×4 sample grid. Tahoma at 18px improves from 28.31 to 6.03
on light backgrounds. Off-grid phases also snap onto the native sampling grid without losing ink.</p>
<img src="resolved-tahoma.png" alt="Tahoma 18 pixel light after selecting the font's native sampling grid">
<p>Natural-mode DELTAP/SHPIX compatibility reduced regressions from 30 to 3; respecting gasp smoothing
choices reduced them to 1. The original <a href="measurements-before-delta-compat.json">98/128 checkpoint</a>
and <a href="measurements-before-gasp.json">125/128 checkpoint</a> are preserved.
The <a href="measurements-before-sampling-profile.json">127/128 checkpoint</a> records the last regression
before sampling followed the font's smoothing profile. Adding bundled Inter brings the current corpus to nine fonts and 144 comparisons.</p>
<h2>Actual application layouts</h2><p>Corrected captures assert the actual platform DPI and framebuffer dimensions.
At 150%, Pad++ is 1770×1140 pixels. Each interactive review compares previous B (A in its controls) with
approved C (B in its controls). Reviewed image bytes and hashes are preserved.</p>
<table><tr><th>Application</th><th>Theme</th><th>100%</th><th>150%</th></tr>""" + "".join(app_rows) + """</table>
<p><a href="host-workbench-weight/review.html">Workbench: former host contrast / approved default, same 96 DPI</a> ·
<a href="padpp-selftest.png">Full Pad++ self-test screenshot</a> · <a href="padpp-metrics.json">Pad++ timings</a></p>
<p><a href="workbench-density.json">Workbench density at 96/120/144/192 DPI</a>:
previous B 0.0477/0.0473/0.0518/0.0482; approved C 0.0478/0.0416/0.0569/0.0491.
The original software images labeled 144 DPI were incorrectly 96 DPI; their
<a href="../text-coverage-candidate/capture-errata.json">erratum</a> preserves the history.</p>
<h2>Live Vulkan validation</h2><p>Two changing marker states were captured from each mode's actual GPU window at __GPU_DPI__ DPI.
Previous B: maximum channel error __GPU_ERROR__ against software, __GPU_PIXELS__ differing pixels over both frames.
Approved C: pixel-exact with software in both frames. Both accepted runs report zero rejected frames.</p>
<p><a href="gpu-baseline-1.png">Previous B GPU</a> · <a href="gpu-natural-1.png">Approved C GPU</a> ·
<a href="captures.json">Capture commands and outputs</a></p>
<h2>All __TOTAL__ native comparisons</h2><p>Mean absolute RGB error on union of ink pixels. Lower is closer to this machine's
DirectWrite grayscale reference; this is not a readability verdict. Negative delta is an improvement.
Native gamma 1.8; grayscale enhanced contrast 1.0. No native rasterizer is used by Aurora.</p>
<p><label>Font <select id="font"><option value="">All</option>""" + options + """</select></label>
<label><input id="regressed" type="checkbox"> Show only regressions</label></p>
<div class="scroll"><table id="measurements"><thead><tr><th>Font</th><th>px</th><th>Theme</th><th>Previous B</th><th>Approved C</th><th>Delta</th></tr></thead>
<tbody>""" + "".join(rows) + """</tbody></table></div>
<p><a href="measurements.json">Raw measurements, native settings, font and source hashes</a></p>
<h2>What remains</h2><p>Complete instruction and rounding fidelity, and measure
the native coverage transfer across foregrounds and backgrounds. Exact Windows grayscale and ClearType parity remain unachieved.
Natural hinting is now shared globally. <code>AURORA_HINTING=0</code> restores B; <code>AURORA_TEXT_COVERAGE=legacy</code> restores the older coverage policy.</p>
<p>Checks pass for the coverage/cache suite, 1,872 existing font cases, 7,200 Windows glyph/size checks plus reverse replay,
instruction unit tests, DPI, host interactions and Pad++ workflow. The older Notepad full smoke retains its existing
drag/restore failure in both coverage modes; see the validation record.</p>
<p><a href="validation.json">Post-promotion validation</a> covers the shared default, unhinted compatibility,
font/phase/DPI regressions, full host verification and Pad++. The preserved
<a href="validation-natural-strict.json">strict B profile</a> rejected C's 0.0416 fixture against 0.045 before review.
The <a href="validation-natural-pre-promotion.json">proposed 0.039 profile</a> passed; the owner approved C and its revised guard.
The Inter phase assertion was not relaxed. See the <a href="promotion-proposal.json">approved proposal</a>.</p>
<script>const family=document.querySelector('#font'), only=document.querySelector('#regressed');
function filter(){document.querySelectorAll('#measurements tbody tr').forEach(row=>{
row.hidden=(family.value&&row.dataset.font!==family.value)||(only.checked&&row.dataset.kind!=='regressed');});}
family.onchange=only.onchange=filter;</script></html>
"""
html = html.replace("__IMPROVED__", str(data["improved"])).replace("__REGRESSED__", str(data["regressed"]))
html = html.replace("__TOTAL__", str(len(data["comparisons"])))
html = html.replace("__GPU_DPI__", str(gpu["baseline"]["dpi"])).replace("__GPU_ERROR__", str(gpu["baseline"]["error"]))
html = html.replace("__GPU_PIXELS__", str(gpu["baseline"]["pixels"]))
(HERE / "index.html").write_text(html, encoding="utf-8")
files = [p for p in HERE.rglob("*") if p.is_file() and p.name != "manifest.json" and "__pycache__" not in p.parts]
(HERE / "manifest.json").write_text(json.dumps({"date": "2026-10-20", "coverage_default": "foreground",
    "hinting_default": "natural", "experimental_hinting_promoted": True, "decision": "C, owner-approved 2026-10-20",
    "sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}, indent=2), encoding="utf-8")
print(HERE / "index.html")
