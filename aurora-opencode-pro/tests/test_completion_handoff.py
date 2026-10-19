"""Exercise completion handoffs in the production app using local HTTP/SSE."""
import collections
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

package = Path(__file__).resolve().parents[1]
rounds = collections.Counter()
requests = collections.defaultdict(list)
failures = []
summary = "Result: Four requested documents saved.\nChecks: Verification was not requested or run.\nRemaining: None recorded."


def call(identity, name, args):
    return {"id": identity, "type": "function",
            "function": {"name": name, "arguments": json.dumps(args)}}


def plan(complete=False):
    return {"plan": [{"id": f"outcome-{i}", "step": f"Save document pair {i + 1}",
                      "kind": "edit", "done": "Both requested documents saved",
                      "status": "completed" if complete else "in_progress" if i == 0 else "pending",
                      **({"evidence": [f"write-{2*i}", f"write-{2*i+1}"]} if complete else {})}
                     for i in range(2)]}


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def respond(self, body, kind):
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.respond(json.dumps({"data": [{"id": name} for name in scenarios]}), "application/json")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        case = request["model"]
        requests[case].append(request)
        rounds[case] += 1
        number = rounds[case]
        if number > 4:
            failures.append("Unbounded summary repair: " + case)
            self.send_error(500)
            return
        system = "\n".join(message.get("content", "") for message in request["messages"]
                           if message["role"] == "system")
        repairing = "Completion handoff requested:\n" in system
        if repairing and (request.get("tools") or "no closing summary" in system):
            failures.append("Summary repair exposed tools or suppressed the handoff: " + case)
        owners = set()
        for message in request["messages"]:
            owners.update(tool["id"] for tool in message.get("tool_calls", []))
            if message["role"] == "tool" and message["tool_call_id"] not in owners:
                failures.append("Unpaired result: " + case)
        tools, content, finish = [], "", "stop"
        if number == 1:
            tools = [call("initial-plan", "update_plan", plan())] + [
                call(f"write-{i}", "write", {"filePath": f"document-{i}.md", "content": f"Document {i}"})
                for i in range(4)]
        elif number == 2:
            tools = [call("completed-plan", "update_plan", plan(True))]
        elif not repairing:
            content = (summary if case in ("healthy", "truncated") else "READY" if case == "exact"
                       else '{"result":"Four documents saved"}' if case == "json_format" else "Done.")
            if case == "truncated":
                finish = "length"
        elif case == "tool_attempt":
            tools = [call("must-not-run", "write", {"filePath": "unexpected.md", "content": "Must not execute"})]
        elif case == "provider_error":
            self.respond('data: {"error":{"message":"Summary generation unavailable"}}\n\ndata: [DONE]\n\n',
                         "text/event-stream")
            return
        else:
            content = "Done." if case == "fallback" else summary
        delta = {"tool_calls": [dict(tool, index=i) for i, tool in enumerate(tools)]} if tools else {"content": content}
        row = {"choices": [{"delta": delta, "finish_reason": "tool_calls" if tools else finish}]}
        self.respond("data: " + json.dumps(row) + "\n\ndata: [DONE]\n\n", "text/event-stream")


scenarios = {"missing": "compact", "healthy": "default", "fallback": "caveman",
             "tool_attempt": "concise", "exact": "default", "truncated": "default",
             "provider_error": "default", "json_format": "default"}
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    directory = Path(tempfile.mkdtemp(prefix="completion-handoff-", dir=package / "build"))
    workspaces = Path(tempfile.mkdtemp(prefix="aurora-completion-work-"))
    print("ARTIFACTS", directory, flush=True)
    executable = package / "aurora-opencode-pro.exe"
    durations = {}
    for case, style in scenarios.items():
        workspace = workspaces / case
        workspace.mkdir(parents=True)
        state = directory / case / "appdata" / "Aurora OpenCode"
        state.mkdir(parents=True)
        (state / "settings.json").write_text(json.dumps({
            "baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "apiKey": "local-fixture",
            "model": case, "workspace": str(workspace), "toolsEnabled": True,
            "legacyTools": False, "quickTitle": False, "verbosity": style}), encoding="utf-8")
        prompt = "Write four requested Markdown documents and finish the task."
        if case == "exact":
            prompt = "Write four requested Markdown documents, then reply READY."
        elif case == "json_format":
            prompt = "Write four requested Markdown documents. Respond in JSON."
        started = time.monotonic()
        try:
            process = subprocess.run([str(executable), "--headless", prompt], cwd=workspace,
                                     env=dict(os.environ, APPDATA=str(state.parent)),
                                     timeout=45, capture_output=True, text=True)
        finally:
            (directory / case / "requests.json").write_text(json.dumps(requests[case], indent=2), encoding="utf-8")
        durations[case] = time.monotonic() - started
        (directory / case / "process.log").write_text(process.stdout + process.stderr, encoding="utf-8")
        assert process.returncode == 0, process.stdout + process.stderr
        expected = 3 if case in ("healthy", "exact", "json_format") else 4
        assert rounds[case] == expected, (case, rounds[case], expected)
        history = next(json.loads(path.read_text(encoding="utf-8")) for path in (state / "threads").glob("*.json")
                       if any(message.get("content") == prompt for message in json.loads(path.read_text(encoding="utf-8"))["messages"]))
        messages = history["messages"]
        final_message = next(message for message in reversed(messages)
                             if message["role"] == "assistant" and not message.get("internal"))
        final = final_message["content"]
        if case == "exact":
            assert final == "READY", final
        elif case == "json_format":
            assert json.loads(final) == {"result": "Four documents saved"}, final
        else:
            assert all(label in final for label in ("Result:", "Checks:", "Remaining:")), final
        task = json.loads(final_message["taskStateJson"])
        assert task["taskStatus"] == "completed", task.get("taskStatus")
        assert sum(message.get("internal", False) and message.get("content", "").startswith(
                   "Completion handoff requested:\n") for message in messages) == (expected - 3)
        if case in ("fallback", "tool_attempt", "provider_error"):
            assert final.startswith("Aurora work summary (from recorded evidence):"), final
            assert "No current successful verification receipt recorded" in final
        if case in ("missing", "fallback", "tool_attempt", "provider_error"):
            assert any(message.get("content") == "Done." for message in messages), "Original response was lost"
        assert not (workspace / "unexpected.md").exists(), "Summary-only request executed a tool"
        for i in range(4):
            assert (workspace / f"document-{i}.md").read_text() == f"Document {i}"
        print("PASS", case, "requests=", rounds[case], flush=True)
    assert not failures, failures
    (directory / "result.json").write_text(json.dumps({"status": "passed", "rounds": dict(rounds),
        "localProviderSeconds": durations, "workspaceRoot": str(workspaces),
        "binarySha256": hashlib.sha256(executable.read_bytes()).hexdigest()}, indent=2), encoding="utf-8")
finally:
    server.shutdown()
    server.server_close()
