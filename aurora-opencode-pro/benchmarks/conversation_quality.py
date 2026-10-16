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
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--live", action="store_true", required=True,
                    help="Use the configured provider; makes paid model requests")
parser.add_argument("--exe", type=Path, default=package / "aurora-opencode-pro.exe")
parser.add_argument("--output", type=Path)
args = parser.parse_args()
directory = args.output or Path(tempfile.mkdtemp(prefix="conversation-quality-", dir=package / "build"))
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
prompts = [
    ("analysis", "Analyze invoice.py. Delivery must cost 5 below a merchandise subtotal of 50, and be free at 50 or above. A coupon discounts merchandise by 10%, never delivery. Identify the defects; do not edit files."),
    ("implementation", "Implement those fixes and verify the behavior. Preserve the total(subtotal, coupon=False) API, add no dependencies, and keep the final reply brief."),
    ("question", "What changed and what verification supports it? Answer only, without changing files or restarting work."),
    ("correction", "Now change the free-delivery threshold to 75 and verify it. Preserve the API and the earlier coupon rule. Keep the final reply brief."),
]
report = {"binarySha256": hashlib.sha256(args.exe.read_bytes()).hexdigest(),
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
        process = subprocess.Popen([str(args.exe.resolve()), "--headless-loop"], cwd=workspace,
            env=dict(os.environ, APPDATA=str((directory / "appdata").resolve()), AURORA_STRICT_PLAN="0"),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
            text=True, encoding="utf-8", errors="replace", bufsize=1)
        threading.Thread(target=read_output, args=(process.stdout,), daemon=True).start()
        for index, (name, prompt) in enumerate(prompts):
            marker = f"AURORA_EVAL_DONE_{index}"
            initial = source.read_bytes()
            started = time.monotonic()
            process.stdin.write(prompt + f" End the final reply with {marker}.\n")
            process.stdin.flush()
            response = ""
            deadline = started + 180
            while marker not in response:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"Scenario did not finish: {name}")
                try:
                    response += lines.get(timeout=min(1, remaining))
                except queue.Empty:
                    if process.poll() is not None:
                        raise RuntimeError(f"App exited during {name}: {process.returncode}")
            response = response.replace(marker, "").strip()
            if name in ("analysis", "question"):
                passed, detail = source.read_bytes() == initial, "Read-only request preserved source"
            else:
                passed, detail = check_behavior(75 if name == "correction" else 50)
            row = {"name": name, "passed": passed, "seconds": time.monotonic()-started,
                   "answerWords": len(response.split()),
                   "questionLinesHeuristic": len(re.findall(r"(?m)^.*\?\s*$", response)),
                   "independentCheck": detail, "response": response}
            report["scenarios"].append(row)
            print(name, "PASS" if passed else "FAIL", f"{row['seconds']:.3f}s", flush=True)
            if not passed:
                raise AssertionError(f"Independent check failed: {name}")
        process.stdin.write("exit\n")
        process.stdin.flush()
        assert process.wait(timeout=30) == 0
    sessions = [json.loads(path.read_text(encoding="utf-8")) for path in (state / "threads").glob("*.json")]
    messages = [message for session in sessions for message in session.get("messages", [])]
    assistants = [message for message in messages if message.get("role") == "assistant"]
    report.update(status="passed", models=sorted({session.get("model", "") for session in sessions}),
                  modelRequests=len(assistants), toolCalls=sum(len(m.get("toolCalls", [])) for m in assistants),
                  totalTokens=(sum(m["totalTokens"] for m in assistants)
                               if assistants and all(m.get("totalTokens", 0) > 0 for m in assistants) else None),
                  falseCompletions=0, resolvedScenarios=len(report["scenarios"]),
                  endToEndSeconds=sum(row["seconds"] for row in report["scenarios"]))
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
