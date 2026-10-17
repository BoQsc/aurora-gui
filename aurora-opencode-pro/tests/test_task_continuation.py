"""Real HTTP/SSE regressions for premature completion and internal recovery."""
import collections
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

package = Path(__file__).resolve().parents[1]
rounds = collections.Counter()
failures = []
prompts = {
    "Finish all six fixture steps.": "work",
    "Implement the fixture stalled task.": "stall",
    "Implement the fixture tool recovery task.": "toolstall",
    "Implement the fixture malformed output task.": "output",
    "Implement the fixture external obstacle task.": "obstacle",
    "Implement the fixture task requiring a missing deployment address.": "input",
    "What does the fixture pending plan mean?": "question",
    "Finish the fixture cancellation task.": "cancel",
    "Commit existing work only.": "commit",
    "Write seven fixture Markdown documents.": "unplanned",
    "Implement the fixture plan consistency task.": "consistency",
}


def call(identity, name, arguments):
    return {"id": identity, "type": "function",
            "function": {"name": name, "arguments": json.dumps(arguments)}}


def consistency_plan(statuses, explanation=None, corrected=False):
    labels = ["First outcome", "Second outcome", "Compatibility outcome"]
    evidence = ["consistency-corrected" if corrected else "consistency-first",
                "consistency-second", "consistency-third"]
    plan = {"plan": [{"id": f"c{i}", "step": labels[i], "kind": "edit",
                       "done": labels[i] + " saved", "status": status,
                       **({"evidence": [evidence[i]]} if status == "completed" else {})}
                      for i, status in enumerate(statuses)]}
    if explanation:
        plan["explanation"] = explanation
    return plan


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def body(self, body, kind):
        raw = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self.body('{"data":[{"id":"continuation-fixture"}]}', "application/json")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request["messages"]
        scenario = next(prompts[m["content"]] for m in reversed(messages)
                        if m["role"] == "user" and isinstance(m.get("content"), str)
                        and m["content"] in prompts)
        rounds[scenario] += 1
        if rounds[scenario] > 55:
            failures.append("Unbounded continuation: " + scenario)
            self.send_error(500)
            return
        owners, results = set(), {}
        for message in messages:
            for tool in message.get("tool_calls", []):
                owners.add(tool["id"])
            if message["role"] == "tool":
                identity = message["tool_call_id"]
                if identity not in owners or identity in results:
                    failures.append("Unpaired/duplicate result: " + identity)
                results[identity] = message["content"]
        continuations = sum(m["content"].count("Continuation: unfinished authorized work\n")
                            for m in messages if isinstance(m.get("content"), str))
        tools, content, delay = [], "", 0
        if scenario == "work":
            stage = continuations
            if f"write{stage}" not in results:
                tools = [call(f"plan{stage}", "update_plan", {
                    "objective": "Complete six real outcomes",
                    "plan": [{"step": f"Outcome {i}", "status": "completed" if i < stage
                              else "in_progress" if i == stage else "pending"} for i in range(6)]}),
                    call(f"write{stage}", "write", {"filePath": f"step{stage}.md", "content": f"outcome{stage}"})]
            elif stage == 5 and "complete-all" not in results:
                tools = [call("complete-all", "update_plan", {
                    "plan": [{"step": f"Outcome {i}", "status": "completed"} for i in range(6)]})]
            else:
                content = "All six outcomes completed." if stage == 5 else f"Partial outcome {stage} landed. Say the word and I will continue."
        elif scenario == "consistency":
            for identity, fragment in [("consistency-add-bad", "explanation"),
                                       ("consistency-jump-bad", "explanation"),
                                       ("consistency-reopen-bad", "reopen_steps")]:
                if identity in results and (not results[identity].startswith("Error:") or fragment not in results[identity]):
                    failures.append("Invalid plan transition accepted: " + identity)
            if "consistency-base" not in results:
                tools = [call("consistency-base", "update_plan", consistency_plan(["in_progress", "pending"])),
                         call("consistency-first", "write", {"filePath": "consistent-first.md", "content": "First outcome"})]
            elif "consistency-add-bad" not in results:
                tools = [call("consistency-add-bad", "update_plan", consistency_plan(["in_progress", "pending", "pending"])),
                         call("consistency-jump-bad", "update_plan", consistency_plan(["pending", "in_progress"])),
                         call("consistency-second", "write", {"filePath": "consistent-second.md", "content": "Second outcome"})]
            elif "consistency-detour" not in results:
                tools = [call("consistency-detour", "update_plan", consistency_plan(["pending", "in_progress"],
                    "The second outcome establishes compatibility needed to finish the first."))]
            elif "consistency-return" not in results:
                text = "\n".join(m.get("content", "") for m in messages if isinstance(m.get("content"), str))
                if "Return to: First outcome" not in text:
                    failures.append("Explained focus switch lost the automatic return point")
                tools = [call("consistency-return", "update_plan", consistency_plan(["in_progress", "completed"]))]
            elif "consistency-add" not in results:
                tools = [call("consistency-add", "update_plan", consistency_plan(["completed", "completed", "in_progress"],
                    "Inspection exposed a compatibility outcome needed for the requested result."))]
            elif "consistency-reopen-bad" not in results:
                tools = [call("consistency-reopen-bad", "update_plan", consistency_plan(["pending", "completed", "in_progress"],
                    "The compatibility outcome exposed a defect in the first outcome.")),
                         call("consistency-third", "write", {"filePath": "consistent-third.md", "content": "Compatibility outcome"})]
            elif "consistency-reopen" not in results:
                plan = consistency_plan(["in_progress", "completed", "completed"],
                    "The compatibility outcome exposed a defect requiring a correction to the first outcome.")
                plan["reopen_steps"] = ["c0"]
                tools = [call("consistency-reopen", "update_plan", plan)]
            elif "consistency-corrected" not in results:
                tools = [call("consistency-corrected", "write", {"filePath": "consistent-first.md", "content": "First outcome corrected"})]
            elif "consistency-finish" not in results:
                tools = [call("consistency-finish", "update_plan", consistency_plan(["completed"] * 3, corrected=True))]
            else:
                content = "All consistent outcomes completed."
        elif scenario == "unplanned":
            if rounds[scenario] > 2:
                failures.append("Optional planning added a completion round")
            if "document-6" not in results:
                tools = [call(f"document-{i}", "write", {
                    "filePath": f"document-{i}.md", "content": f"Document {i}"}) for i in range(7)]
            else:
                content = "Seven documents written."
        elif scenario == "commit":
            if "commit-status" not in results:
                tools = [call("commit-add", "run", {"program": "git", "args": ["add", "-A"]}),
                         call("commit-create", "run", {"program": "git", "args": ["commit", "-m", "fixture checkpoint"]}),
                         call("commit-status", "run", {"program": "git", "args": ["status", "--porcelain"]}),
                         call("commit-plan", "update_plan", {"plan": [{"step": "Commit and check existing work", "status": "completed"}]})]
            else:
                content = "Existing work committed; working tree checked."
        elif scenario in ("stall", "toolstall", "output", "obstacle", "input", "cancel"):
            if "pending-plan" not in results:
                tools = [call("pending-plan", "update_plan", {
                    "objective": "Implement fixture outcome",
                    "plan": [{"step": "Unfinished outcome", "status": "in_progress"}]})]
            elif scenario == "stall":
                if continuations < 10:
                    content = f"Remaining work is unchanged; attempt {continuations}."
                elif "recovered-write" not in results:
                    tools = [call("recovered-write", "write", {"filePath": "recovered.md", "content": "Recovered outcome"})]
                elif "recovered-plan" not in results:
                    tools = [call("recovered-plan", "update_plan", {"plan": [{"step": "Unfinished outcome", "status": "completed"}]})]
                else:
                    content = "Recovered and completed."
            elif scenario == "toolstall":
                attempts = sum(identity.startswith("missing-file-") for identity in results)
                if attempts < 40:
                    tools = [call(f"missing-file-{attempts}", "read", {"filePath": f"absent-{attempts}.md"})]
                elif "tool-recovered-write" not in results:
                    checkpoints = sum(m.get("content", "").count("Execution diagnosis checkpoint:") for m in messages
                                      if isinstance(m.get("content"), str))
                    if checkpoints < 2:
                        failures.append("Missing recurring internal diagnosis checkpoints")
                    tools = [call("tool-recovered-write", "write", {"filePath": "tool-recovered.md", "content": "Alternative succeeded"})]
                elif "tool-recovered-plan" not in results:
                    tools = [call("tool-recovered-plan", "update_plan", {"plan": [{"step": "Unfinished outcome", "status": "completed"}]})]
                else:
                    content = "Alternative succeeded; task completed."
            elif scenario in ("output", "obstacle"):
                if scenario == "output" and rounds[scenario] <= 4:
                    content = '<invoke name="write">\n<parameter name="filePath">must-not-execute.md</parameter>\n<parameter name="content">invalid</parameter>\n</invoke>'
                elif scenario == "obstacle" and "external-obstacle" not in results:
                    tools = [call("external-obstacle", "task_blocker", {"kind": "external", "reason": "Preferred tool unavailable"})]
                elif "alternative-write" not in results:
                    if scenario == "obstacle" and "Recover internally" not in results["external-obstacle"]:
                        failures.append("External obstacle was not redirected into recovery")
                    tools = [call("alternative-write", "write", {"filePath": scenario + "-recovered.md", "content": "Recovered with valid tools"})]
                elif "alternative-plan" not in results:
                    tools = [call("alternative-plan", "update_plan", {"plan": [{"step": "Unfinished outcome", "status": "completed"}]})]
                else:
                    content = "Recovered with valid tools; completed."
            elif scenario == "input":
                if "missing-input" not in results:
                    tools = [call("missing-input", "request_input", {
                        "reason": "The deployment server address has not been provided.",
                        "required_fact": "Deployment destination", "checked": ["No destination in local deployment configuration"],
                        "independent_work_complete": True, "question": "Which deployment server should I use?"})]
                else:
                    content = "Which deployment server should I use?"
            else:
                content, delay = "Partial cancellation response.", 1
        else:
            content = "The old implementation remains unfinished."
        first = {"choices": [{"delta": {"tool_calls": [{"index": i, **tool} for i, tool in enumerate(tools)]}
                             if tools else {"content": content}, "finish_reason": None}]}
        last = {"choices": [{"delta": {}, "finish_reason": "tool_calls" if tools else "stop"}]}
        wire = lambda item: ("data: " + json.dumps(item) + "\n\n").encode()
        start, end = wire(first), wire(last) + b"data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(start) + len(end)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(start)
            self.wfile.flush()
            time.sleep(delay or 0.01)
            self.wfile.write(end)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_STRICT_PLAN="0",
               AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"), *([] if "--debug" in sys.argv else ["--release"]),
                    "latency_cleanup_contracts", "task_continuation_contracts", "task_continuation_ui_contracts"],
                   cwd=package.parent, env=env, check=True, timeout=300)
    assert not failures, failures
    assert rounds == {"work": 13, "unplanned": 2, "consistency": 10, "commit": 2, "stall": 14, "toolstall": 44, "output": 7, "obstacle": 5, "input": 3, "question": 1, "cancel": 2}, rounds
    print("PASS recovered beyond previous reply/tool limits; required input and Stop remain controlled", dict(rounds))
finally:
    server.shutdown()
    server.server_close()
