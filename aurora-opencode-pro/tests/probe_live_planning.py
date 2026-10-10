"""Opt-in live planning probe using the built app and a private workspace."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--live", action="store_true", required=True,
                    help="Use the configured provider; makes paid model requests")
parser.parse_args()
package = Path(__file__).resolve().parents[1]
source = json.loads((Path(os.environ["APPDATA"]) / "Aurora OpenCode/settings.json").read_text(encoding="utf-8-sig"))
directory = Path(tempfile.mkdtemp(prefix="live-planning-", dir=package / "build"))
workspace = directory / "workspace"
workspace.mkdir()
state = directory / "appdata/Aurora OpenCode"
state.mkdir(parents=True)
settings_path = state / "settings.json"
settings = {key: source[key] for key in ("baseUrl", "apiKey", "model")}
settings.update(workspace=str(workspace), toolsEnabled=True, legacyTools=False,
                quickTitle=False, thinking=False, experimentalStrictPlan=False)
settings_path.write_text(json.dumps(settings), encoding="utf-8")
(workspace / "delivery.py").write_text("def shipping(subtotal):\n    return 0 if subtotal >= 20 else 5\n", encoding="utf-8")
(workspace / "discounts.py").write_text("def apply_coupon(amount):\n    return amount * 0.9\n", encoding="utf-8")
(workspace / "cart.py").write_text(
    "from delivery import shipping\nfrom discounts import apply_coupon\n"
    "def total(items, coupon=False):\n    amount = sum(items) + shipping(sum(items))\n"
    "    return apply_coupon(amount) if coupon else amount\n", encoding="utf-8")
(workspace / "test_cart.py").write_text(
    "import unittest\nfrom cart import total\n"
    "class CartTests(unittest.TestCase):\n"
    " def test_small_coupon(self): self.assertAlmostEqual(total([10], True), 14)\n"
    " def test_medium(self): self.assertEqual(total([30]), 35)\n"
    " def test_threshold(self): self.assertEqual(total([50]), 50)\n"
    " def test_threshold_coupon(self): self.assertEqual(total([50], True), 45)\n", encoding="utf-8")
original_tests = (workspace / "test_cart.py").read_bytes()
prompt = (
    "Investigate and fix checkout totals in this workspace. Orders below 50 should cost 5 "
    "for delivery; orders of at least 50 before discounts get free delivery. Coupons "
    "should discount merchandise by 10%, without discounting delivery. Customers report "
    "that medium orders get free delivery and coupons also reduce delivery charges. "
    "Read the existing code and tests, reproduce the failures with python -u -B -m unittest "
    "test_cart, repair the implementation and verify with the same tests. Preserve the "
    "tests. Keep the final explanation brief."
)
(directory / "prompt.txt").write_text(prompt, encoding="utf-8")
executable = package / "aurora-opencode-pro.exe"
evidence = {"model": settings["model"],
            "binarySha256": hashlib.sha256(executable.read_bytes()).hexdigest()}
print("ARTIFACTS", directory, flush=True)
started = time.monotonic()
try:
    result = subprocess.run([str(executable), "--headless-loop"], input=prompt + "\nexit\n",
        text=True, encoding="utf-8", errors="replace", capture_output=True, cwd=workspace,
        env=dict(os.environ, APPDATA=str(directory / "appdata"), AURORA_STRICT_PLAN="0"), timeout=180)
    (directory / "conversation.txt").write_text(result.stdout + result.stderr, encoding="utf-8")
    assert result.returncode == 0, "Built application failed; see conversation.txt"
    threads = list((state / "threads").glob("*.json"))
    assert len(threads) == 1
    messages = json.loads(threads[0].read_text(encoding="utf-8"))["messages"]
    calls = [c for m in messages for c in m.get("toolCalls", [])]
    plans = [(i, json.loads(c["arguments"])["plan"]) for i, c in enumerate(calls) if c["name"] == "update_plan"]
    edits = [i for i, c in enumerate(calls) if c["name"] in ("write", "edit", "apply_patch")]
    evidence.update(toolCalls=len(calls), planUpdates=len(plans),
                    callsBeforeFirstPlan=plans[0][0] if plans else None,
                    firstEditIndex=edits[0] if edits else None)
    assert plans and edits and plans[0][0] < edits[0], "Plan was introduced after implementation"
    assert sum(s["status"] == "in_progress" for s in plans[0][1]) == 1
    assert any(s["status"] == "pending" for s in plans[0][1]), "Initial plan was retrospective"
    assert any(any(s["status"] == "completed" for s in steps) and
               any(s["status"] == "in_progress" for s in steps) for _, steps in plans[1:]), \
        "Plan jumped from initial work directly to all completed"
    assert all(s["status"] == "completed" for s in plans[-1][1]), "Completed task left a stale checklist"
    assert (workspace / "test_cart.py").read_bytes() == original_tests, "Agent changed the tests"
    checked = subprocess.run([os.environ.get("AURORA_PROBE_PYTHON", "python"), "-u", "-B", "-m", "unittest", "test_cart"],
        cwd=workspace, capture_output=True, text=True, timeout=15)
    (directory / "independent-check.txt").write_text(checked.stdout + checked.stderr, encoding="utf-8")
    assert checked.returncode == 0, "Independent checkout tests failed"
    evidence.update(status="passed", independentCheckExit=checked.returncode,
                    seconds=time.monotonic() - started)
    print("PASS live early plan, intermediate progress, completed checklist, preserved tests and independent verification", flush=True)
except Exception as error:
    evidence.update(status="failed", error=str(error), seconds=time.monotonic() - started)
    raise
finally:
    settings_path.write_text(json.dumps({**settings, "apiKey": ""}), encoding="utf-8")
    (directory / "result.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
