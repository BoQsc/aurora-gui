"""Reuse Aurora's review UI while preserving any recorded owner decision."""
import importlib.util
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("aurora_visual_review",
    ROOT / "scripts/make-aurora-visual-review.py")
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)


def make_review(baseline, candidate, title, output, difference=None):
    output.mkdir(parents=True, exist_ok=True)
    path = output / "review.json"
    expected = {"baseline": ui.digest(baseline), "candidate": ui.digest(candidate),
                "difference": ui.digest(difference) if difference else None}
    if path.exists():
        previous = json.loads(path.read_text("utf-8"))
        existing = {key: previous[key]["sha256"] if previous.get(key) else None
                    for key in expected}
        if expected == existing:
            return
        if previous.get("decision") is not None or previous.get("status") != "pending-user-review":
            raise RuntimeError("Evidence changed after a recorded decision; use a new review folder: " + str(output))
    a = ui.copy_evidence(baseline, output, "baseline")
    b = ui.copy_evidence(candidate, output, "candidate")
    diff = ui.copy_evidence(difference, output, "difference") if difference else None
    manifest = {"schema": 1, "title": title, "status": "pending-user-review",
                "baseline": a, "candidate": b, "difference": diff, "decision": None}
    path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (output / "review.html").write_text(ui.review_html(title, a, b, diff), encoding="utf-8")
