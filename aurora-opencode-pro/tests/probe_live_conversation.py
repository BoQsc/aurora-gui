"""Opt-in live model probe, isolated from the user's chats and workspace."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--live", action="store_true", required=True,
                    help="Use the configured provider; makes paid model requests")
parser.parse_args()
package = Path(__file__).resolve().parents[1]
source = json.loads((Path(os.environ["APPDATA"])/"Aurora OpenCode/settings.json").read_text(encoding="utf-8-sig"))
directory = Path(tempfile.mkdtemp(prefix="live-conversation-", dir=package/"build"))
workspace = directory/"workspace"
workspace.mkdir()
state = directory/"appdata"/"Aurora OpenCode"
state.mkdir(parents=True)
settings = {key: source[key] for key in ("baseUrl", "apiKey", "model")}
settings.update(workspace=str(workspace), toolsEnabled=True, legacyTools=False,
                quickTitle=False, thinking=False)
settings_path = state/"settings.json"
settings_path.write_text(json.dumps(settings), encoding="utf-8")
(workspace/"guest_count.py").write_text("def guest_count(names):\n    return len(names) - 1\n", encoding="utf-8")
(workspace/"test_guest_count.py").write_text(
    "import unittest\nfrom guest_count import guest_count\n"
    "class GuestCountTest(unittest.TestCase):\n"
    " def test_three(self): self.assertEqual(guest_count(['A', 'B', 'C']), 3)\n"
    " def test_empty(self): self.assertEqual(guest_count([]), 0)\n", encoding="utf-8")
prompts = [
    "I have had a tiring day and am trying to arrange a low-stress dinner for three friends tomorrow. "
    "I have 45 minutes, everyone is vegetarian, no mushrooms, and I want to keep it simple. "
    "Give me two practical options in under 120 words. No file or tool work yet.",
    "Small correction: it is four people including me, and one person cannot eat gluten. "
    "Keep the original constraints. Choose one dinner and give me a short shopping list. "
    "Please stay under 160 words; no file or tool work yet.",
    "Please save the chosen dinner and shopping list to dinner-plan.md in the workspace. "
    "Keep all the corrected constraints. Read the file back to verify it, then briefly tell me "
    "what you saved. Do not run commands or browse the web.",
    "Separate small issue: guest_count.py counts invitees incorrectly. You may run commands for "
    "this request. Run python -u -B -m unittest test_guest_count, diagnose and fix guest_count.py, "
    "then rerun that check. Leave dinner-plan.md and test_guest_count.py unchanged. "
    "Keep the explanation brief."
]
(directory/"prompts.json").write_text(json.dumps(prompts, indent=2), encoding="utf-8")
original_test = (workspace/"test_guest_count.py").read_bytes()
executable = package/"aurora-opencode-pro.exe"
evidence = {"model": settings["model"], "binarySha256": hashlib.sha256(executable.read_bytes()).hexdigest()}
print("ARTIFACTS", directory, flush=True)
started = time.monotonic()
try:
    result = subprocess.run([str(executable), "--headless-loop"], input="\n".join(prompts)+"\nexit\n",
        text=True, encoding="utf-8", errors="replace", capture_output=True, cwd=workspace,
        env=dict(os.environ, APPDATA=str(directory/"appdata")), timeout=300)
    (directory/"conversation.txt").write_text(result.stdout+result.stderr, encoding="utf-8")
    evidence["exitCode"] = result.returncode
    assert result.returncode == 0, "Built application failed; see conversation.txt"
    threads = list((state/"threads").glob("*.json"))
    assert len(threads) == 1, "Live probe did not stay in one conversation"
    messages = json.loads(threads[0].read_text(encoding="utf-8"))["messages"]
    assert [m["content"] for m in messages if m["role"] == "user" and not m.get("internal")] == prompts
    assert not any(m.get("internal") and m.get("content", "").startswith("Continuation: outstanding verification")
                   for m in messages), "Verification created redundant model continuations"
    turns = [[] for _ in prompts]
    current = -1
    for m in messages:
        if m["role"] == "user" and not m.get("internal"):
            current += 1
        if current >= 0:
            turns[current].append(m)
    assert all(not m.get("toolCalls") for turn in turns[:2] for m in turn), "Casual chat used unrequested tools"
    document_calls = [c for m in turns[2] for c in m.get("toolCalls", [])]
    assert document_calls and all(c["name"] in ("write", "read") for c in document_calls)
    assert any(c["name"] == "read" for c in document_calls), "Agent skipped requested document readback"
    note_write = next(json.loads(c["arguments"])["content"] for c in document_calls if c["name"] == "write")
    note = (workspace/"dinner-plan.md").read_text(encoding="utf-8")
    assert note == note_write, "Code repair modified the preserved dinner plan"
    assert all(word in note.lower() for word in ("vegetarian", "mushroom", "gluten", "45"))
    assert "4" in note or "four" in note.lower(), "Saved plan lost corrected guest count"
    repair_results = [m for m in turns[3] if m["role"] == "tool" and m.get("toolName") == "run"]
    assert any(m.get("failed") for m in repair_results), "Agent skipped reproducing the failing test"
    assert repair_results and not repair_results[-1].get("failed"), "Agent did not finish with a passing check"
    assert (workspace/"test_guest_count.py").read_bytes() == original_test, "Agent changed the test to hide the bug"
    verification = subprocess.run([sys.executable, "-B", "-m", "unittest", "test_guest_count"],
                                  cwd=workspace, capture_output=True, text=True, timeout=20)
    (directory/"independent-check.txt").write_text(verification.stdout+verification.stderr, encoding="utf-8")
    assert verification.returncode == 0, "Independent verification of the agent's repair failed"
    evidence.update(status="passed", userTurns=len(turns),
                    toolCalls=sum(len(m.get("toolCalls", [])) for m in messages),
                    failedChecks=sum(bool(m.get("failed")) for m in repair_results),
                    redundantVerificationTurns=0, independentCheckExitCode=verification.returncode)
    print("PASS live casual context/correction -> document/readback -> reproduce/fix/retest; independent check passed", flush=True)
except BaseException as error:
    evidence.update(status="failed", error=str(error))
    raise
finally:
    evidence["seconds"] = time.monotonic()-started
    (directory/"result.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    # Retain the evidence without retaining the provider credential.
    settings_path.write_text(json.dumps({**settings, "apiKey": ""}), encoding="utf-8")
