"""Package already captured evidence; never runs applications or changes policy."""
import hashlib
import json
from pathlib import Path
from review import make_review

from PIL import Image, ImageDraw, ImageFont


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / "build-validation/text-coverage-candidate/review"
evidence = json.loads((HERE / "evidence.json").read_text("utf-8"))
evidence.pop("tests", None)  # Validation is recorded separately, including failures.
(HERE / "evidence.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
font = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 13)
panels = []
for family in ("segoe", "consolas"):
    rows = [("A: framework legacy", BUILD / f"{family}-legacy/13-light-aurora.png"),
            ("B: foreground candidate", BUILD / f"{family}-foreground/13-light-aurora.png"),
            ("Windows grayscale", BUILD / f"{family}-legacy/13-light-native-gray.png")]
    images = [Image.open(path).convert("RGB") for _, path in rows]
    height = images[0].height + 8
    panel = Image.new("RGB", (images[0].width + 230, 30 + height * 3), "#e5e7eb")
    draw = ImageDraw.Draw(panel)
    draw.text((8, 6), family + " / 13 physical px / light / actual pixels", fill="black", font=font)
    for index, ((label, _), image) in enumerate(zip(rows, images)):
        y = 30 + index * height
        draw.text((8, y + 5), label, fill="black", font=font)
        panel.paste(image, (210, y))
    panels.append(panel)
sheet = Image.new("RGB", (max(p.width for p in panels), sum(p.height + 8 for p in panels)), "#c9ced6")
y = 0
for panel in panels:
    sheet.paste(panel, (0, y))
    y += panel.height + 8
sheet.save(HERE / "font-comparison.png")

for dpi in (96, 144):
    make_review(HERE / f"padpp-light-{dpi}-current-host.png",
        HERE / f"padpp-light-{dpi}-foreground.png",
        f"Pad++ {dpi} DPI: A current host 0.75 / B foreground candidate 0.5",
        HERE / f"padpp-current-host-{dpi}")

rows = []
for app, label, themes in (("notepad", "Older Aurora Notepad", ("light", "dark")),
                            ("host", "Host editor primitives", ("light", "dark")),
                            ("padpp", "Pad++ (normalized 0.5 baseline)", ("light",))):
    for theme in themes:
        links = "".join(f'<td><a href="{app}-{theme}-{dpi}/review.html">{dpi} DPI</a></td>' for dpi in (96, 144))
        rows.append(f"<tr><td>{label}</td><td>{theme}</td>{links}</tr>")
html = """<!doctype html><meta charset="utf-8"><title>Aurora foreground coverage candidate</title>
<style>body{font:16px/1.55 'Segoe UI',sans-serif;max-width:1100px;margin:35px auto;padding:0 22px;color:#172033;background:#f8fafc}
a{color:#164bad}table{border-collapse:collapse}td,th{padding:8px 16px;border:1px solid #ccd3dc;text-align:left}
.status{padding:16px;background:#fff3cd;border-left:4px solid #cb9611}img{max-width:100%;height:auto}code{background:#e8edf3;padding:3px}</style>
<h1>Aurora foreground coverage candidate</h1>
<p class="status">B is experimental. The shared default is unchanged. The host's existing ink-density gate rejects B's lighter weight (0.0477 versus a minimum of 0.061). This gate has not been weakened.</p>
<p>Start with the current Pad++ host: <a href="padpp-current-host-96/review.html">100% DPI A/B</a> ·
<a href="padpp-current-host-144/review.html">150% DPI A/B</a>. A uses current host contrast 0.75; B uses foreground correction with maximum contrast 0.5.</p>
<h2>Renderer comparison at 13 px</h2><p>The rows below isolate the engine change against the framework's 0.5 baseline. Lower native-reference error is a diagnostic, not a readability verdict.</p>
<img src="font-comparison.png" alt="Segoe UI and Consolas at 13 pixels">
<h2>Applications and DPI</h2><p>These comparisons use maximum contrast 0.5 in both A and B. The host editor uses its real light/dark themes. Pad++ currently supplies a light skin only.</p>
<table><tr><th>Application</th><th>Theme</th><th>100%</th><th>150%</th></tr>""" + "".join(rows) + """</table>
<h2>Live Vulkan capture</h2><p>Both modes captured two changing marker states from the actual screen. Each differed from software in 12 pixels across both frames, with maximum channel error 1.</p>
<p><a href="gpu-legacy-1.png">A GPU</a> · <a href="gpu-foreground-1.png">B GPU</a></p>
<h2>Scope and remaining work</h2><p>This first pass adjusts grayscale coverage according to foreground luminance. It preserves shaping, glyph metrics and near-white coverage. It does not implement full background-sensitive gamma correction or repair experimental hinting.</p>
<p><a href="README.md">Implementation, test results and known failures</a> · <a href="evidence.json">Measurements</a> · <a href="validation.json">Validation record</a></p>
"""
decision_path = HERE / "decision.json"
decision = json.loads(decision_path.read_text("utf-8")) if decision_path.exists() else None
if decision and decision.get("status") == "approved":
    html = html.replace("B is experimental. The shared default is unchanged. The host's existing ink-density gate rejects B's lighter weight (0.0477 versus a minimum of 0.061). This gate has not been weakened.",
        "B was approved on 20 October 2026 and is now the shared default. The reviewed weight guard is 0.045. The original measurements remain below. Further native-fidelity work is documented separately.")
    html += '<p><a href="decision.json">Owner decision</a> · <a href="../native-text-progress/index.html">Native-fidelity progress</a></p>'
    html = html.replace('<h2>Applications and DPI</h2>',
        '<p class="status"><b>DPI correction:</b> the original software images labeled 144 DPI were actually 96 DPI. '
        'Their reviewed bytes are preserved. See <a href="capture-errata.json">the erratum</a> and '
        '<a href="../native-text-progress/index.html">corrected captures</a>.</p><h2>Applications and DPI</h2>')
    # Record the actual owner choice; preserve the reviewed image hashes.
    for review_path in HERE.glob("*/review.json"):
        review = json.loads(review_path.read_text("utf-8"))
        for key in ("baseline", "candidate", "difference"):
            entry = review.get(key)
            if entry:
                actual = hashlib.sha256((review_path.parent / entry["file"]).read_bytes()).hexdigest()
                if actual != entry["sha256"]:
                    raise RuntimeError("Reviewed evidence changed: " + str(review_path))
        review.update(status="approved", decision="B", decision_date=decision["date"],
                      decision_source="../decision.json")
        review_path.write_text(json.dumps(review, indent=2), encoding="utf-8")
        page = review_path.with_name("review.html")
        content = page.read_text("utf-8").replace(
            "Decision pending — neither image is approved as the standard.",
            "B approved by the project owner on 20 October 2026 — shared foreground coverage default.")
        content = content.replace("B — proposed candidate", "B — approved shared default")
        content = content.replace("Final choice belongs to the project owner. Report A, B, neither, or request\n    another capture; an agent can then record that decision separately.",
                                  'Owner selected B. <a href="../decision.json">Decision record</a>.')
        page.write_text(content, encoding="utf-8")
(HERE / "index.html").write_text(html, encoding="utf-8")
files = list(HERE.glob("*.png")) + [ROOT / p for p in (
    "vendor/aurora-d-0.4.5/source/aurora/text/coverage.d",
    "vendor/aurora-d-0.4.5/source/aurora/text/atlas.d",
    "vendor/aurora-d-0.4.5/source/aurora/canvas.d")]
approved = bool(decision and decision.get("status") == "approved")
manifest = {"status": "approved" if approved else "pending-user-review",
    "decision": "B" if approved else None, "default_changed": approved,
    "sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}
(HERE / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
print(HERE / "index.html")
