"""Opt-in live, multi-turn quality evaluation with independent artifact checks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time

package = Path(__file__).resolve().parents[1]

def grade(report, directory):
    state = directory / "appdata" / "Aurora OpenCode"
    transcripts = [json.loads(path.read_text(encoding="utf-8")) for path in (state / "threads").glob("*.json")]
    messages = [message for transcript in transcripts for message in transcript.get("messages", [])]
    assistants = [message for message in messages if message.get("role") == "assistant"]
    index_path = state / "threads.index.json"
    index = json.loads(index_path.read_text(encoding="utf-8")) if index_path.exists() else {}
    headers = index.get("sessions", index.get("threads", [])) if isinstance(index, dict) else index
    for number, row in enumerate(report["scenarios"]):
        marker = f"AURORA_EVAL_DONE_{number}"
        finals = [message for message in assistants if (message.get("content", "") == row.get("response")
                  if report.get("framing") == "jsonl" else marker in message.get("content", ""))]
        final = finals[-1] if finals else {}
        receipt = json.loads(final.get("taskStateJson") or "{}")
        row["artifactPassed"] = row.get("artifactPassed", row["passed"])
        row["taskStatus"] = receipt.get("taskStatus", "unknown")
        row["verificationStatus"] = receipt.get("verificationStatus", "unknown")
        row["concise"] = row["answerWords"] <= 100
        row["turnFailed"] = final.get("failed", False) or not final
        row["completed"] = row["name"] == "question" or row["taskStatus"] == "completed"
        row["verified"] = row["name"] not in ("implementation", "correction") or row["verificationStatus"] == "passed"
        row["passed"] = row["artifactPassed"] and row["concise"] and not row["turnFailed"] and row["completed"] and row["verified"]
    resolved = sum(row["passed"] for row in report["scenarios"])
    report.update(status="passed" if resolved == len(report["scenarios"]) and resolved == report.get("expectedScenarios", len(prompts)) else "failed",
        models=sorted({header.get("model", "") for header in headers if header.get("model")}),
        modelRequests=len(assistants), toolCalls=sum(len(m.get("toolCalls", [])) for m in assistants),
        totalTokens=(sum(m["totalTokens"] for m in assistants)
                     if assistants and all(m.get("totalTokens", 0) > 0 for m in assistants) else None),
        completionStateMismatches=sum(not row["completed"] or not row["verified"] for row in report["scenarios"]),
        resolvedScenarios=resolved, endToEndSeconds=sum(row["seconds"] for row in report["scenarios"]))
    report.pop("falseCompletions", None)

prompts = [
    ("analysis", "Analyze invoice.py. Delivery must cost 5 below a merchandise subtotal of 50, and be free at 50 or above. A coupon discounts merchandise by 10%, never delivery. Identify the defects; do not edit files."),
    ("implementation", "Implement those fixes and verify the behavior. Preserve the total(subtotal, coupon=False) API, add no dependencies, and keep the final reply brief."),
    ("question", "What changed and what verification supports it? Answer only, without changing files or restarting work."),
    ("correction", "Now change the free-delivery threshold to 75 and verify it. Preserve the API and the earlier coupon rule. Keep the final reply brief."),
]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--live", action="store_true",
                    help="Use the configured provider; makes paid model requests")
parser.add_argument("--regrade", type=Path, help="Recheck saved artifacts, completion state and concision without model calls")
parser.add_argument("--exe", type=Path, default=package / "aurora-opencode-pro.exe")
parser.add_argument("--output", type=Path)
parser.add_argument("--extended", action="store_true", help="Also grade a numerical claim against independently computed values")
args = parser.parse_args()
if args.extended:
    prompts.insert(1, ("calculation", "Analyze invoice.py without editing it. For subtotal 49 with the coupon enabled, calculate the current return value and the required return value under the original rules: delivery costs 5 below 50 and coupons discount only merchandise. Return one JSON object with numeric keys actual and expected."))
if args.regrade:
    report = json.loads((args.regrade / "result.json").read_text(encoding="utf-8"))
    grade(report, args.regrade)
    (args.regrade / "result.regraded.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(report["status"], "resolved", report["resolvedScenarios"], "completion mismatches", report["completionStateMismatches"])
    raise SystemExit(0 if report["status"] == "passed" else 1)
if not args.live:
    parser.error("Use --live to authorize model requests, or --regrade with saved artifacts")
# A workspace inside the application checkout competes for its source lease
# with real development/builds, contaminating quality and latency measurements.
directory = args.output or Path(tempfile.mkdtemp(prefix="aurora-conversation-quality-"))
directory.mkdir(parents=True, exist_ok=True)
workspace = directory / "workspace"
workspace.mkdir(exist_ok=True)
state = directory / "appdata" / "Aurora OpenCode"
state.mkdir(parents=True, exist_ok=True)
saved = json.loads((Path(os.environ["APPDATA"]) / "Aurora OpenCode/settings.json").read_text(encoding="utf-8-sig"))
settings = {key: saved[key] for key in ("baseUrl", "apiKey", "model")}
settings.update(workspace=str(workspace.resolve()), toolsEnabled=True, legacyTools=False,
                quickTitle=False, verbosity="concise", thinking=False)
settings_path = state / "settings.json"
settings_path.write_text(json.dumps(settings), encoding="utf-8")
source = workspace / "invoice.py"
source.write_text("def total(subtotal, coupon=False):\n    return (subtotal + (0 if subtotal >= 20 else 5)) * (0.9 if coupon else 1)\n", encoding="utf-8")
report = {"binarySha256": hashlib.sha256(args.exe.read_bytes()).hexdigest(),
          "framing": "jsonl",
          "expectedScenarios": len(prompts),
          "route": "Actual console model is recorded from saved history; GUI preferences remain unchanged.",
          "scenarios": [], "status": "failed"}
lines = queue.Queue()
process = None

def read_output(stream):
    for line in stream:
        lines.put(line)

def check_behavior(threshold):
    check = ("from invoice import total\n"
             "assert abs(total(10, True)-14)<1e-8\n"
             f"assert total({threshold-1}) == {threshold+4}\n"
             f"assert total({threshold}) == {threshold}\n"
             f"assert abs(total({threshold},True)-{threshold*.9})<1e-8\n")
    result = subprocess.run([sys.executable, "-B", "-c", check], cwd=workspace,
                            capture_output=True, text=True, timeout=15)
    return result.returncode == 0, result.stdout + result.stderr

try:
    with (directory / "process.log").open("w", encoding="utf-8") as log:
        process = subprocess.Popen([str(args.exe.resolve()), "--headless-loop-json"], cwd=workspace,
            env=dict(os.environ, APPDATA=str((directory / "appdata").resolve()), AURORA_STRICT_PLAN="0"),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
            text=True, encoding="utf-8", errors="replace", bufsize=1)
        threading.Thread(target=read_output, args=(process.stdout,), daemon=True).start()
        for index, (name, prompt) in enumerate(prompts):
            initial = source.read_bytes()
            started = time.monotonic()
            process.stdin.write(prompt + "\n")
            process.stdin.flush()
            response = ""
            deadline = started + 180
            while not response:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"Scenario did not finish: {name}")
                try:
                    frame = json.loads(lines.get(timeout=min(1, remaining)))
                    response = frame["reply"]
                    if frame.get("error") or frame["turnStatus"] != "completed":
                        raise RuntimeError(f"Scenario did not complete: {name}: {frame}")
                except queue.Empty:
                    if process.poll() is not None:
                        raise RuntimeError(f"App exited during {name}: {process.returncode}")
            response = response.strip()
            if name in ("analysis", "question", "calculation"):
                passed, detail = source.read_bytes() == initial, "Read-only request preserved source"
                if name == "calculation":
                    try:
                        value = json.loads(response.removeprefix("```json").removesuffix("```").strip())
                        passed = passed and isinstance(value.get("actual"), (int, float)) and isinstance(value.get("expected"), (int, float)) and abs(value["actual"] - 44.1) < 1e-8 and abs(value["expected"] - 49.1) < 1e-8
                        detail += "; independently checked actual=44.1, expected=49.1"
                    except (ValueError, TypeError, AttributeError):
                        passed, detail = False, "Numerical answer did not satisfy the requested JSON contract"
            else:
                passed, detail = check_behavior(75 if name == "correction" else 50)
            row = {"name": name, "passed": passed, "seconds": time.monotonic()-started,
                   "answerWords": len(response.split()),
                   "questionLinesHeuristic": len(re.findall(r"(?m)^.*\?\s*$", response)),
                   "independentCheck": detail, "response": response}
            report["scenarios"].append(row)
            print(name, "artifact PASS" if passed else "artifact FAIL", f"{row['seconds']:.3f}s", flush=True)
            if not passed:
                raise AssertionError(f"Independent check failed: {name}")
        process.stdin.write("exit\n")
        process.stdin.flush()
        assert process.wait(timeout=30) == 0
    grade(report, directory)
    assert report["status"] == "passed", "Artifact, completion, accepted verification or concision check failed"
except Exception as error:
    report["error"] = str(error)
    raise
finally:
    if process is not None and process.poll() is None:
        process.kill()  # Only this isolated evaluation process.
        process.wait(timeout=15)
    settings_path.write_text(json.dumps({**settings, "apiKey": ""}), encoding="utf-8")
    (directory / "result.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print("ARTIFACTS", directory, flush=True)
