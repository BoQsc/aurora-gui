"""One real-provider persistent goal, with staged work and injected failures.

Successful model responses are always forwarded from the configured real provider.
Faults are HTTP errors or a truncated real SSE stream, never canned task decisions.
Only one goal is submitted; the runner never sends Continue, retry or repair advice.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit
import uuid

from live_goal_fixture import setup

PACKAGE = Path(__file__).resolve().parents[1]


def read_json(path, fallback=None):
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return fallback


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True)
    parser.add_argument("--exe", type=Path, default=PACKAGE / "aurora-opencode-pro.exe")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--context", type=int, default=32000)
    args = parser.parse_args()
    executable = args.exe.resolve(strict=True)
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    workspace, private = root / "workspace", root / "verifier"
    workspace.mkdir(); private.mkdir()
    appdata = root / "appdata"
    state = appdata / "Aurora OpenCode"
    state.mkdir(parents=True)
    setup(workspace, private)
    saved = read_json(Path(os.environ["APPDATA"]) / "Aurora OpenCode/settings.json")
    if not saved or not saved.get("apiKey"):
        raise RuntimeError("Configure a real Aurora provider before running this opt-in test")
    target = urlsplit(saved["baseUrl"])
    if target.scheme not in ("http", "https") or target.hostname in ("127.0.0.1", "localhost"):
        raise RuntimeError("This proof requires a real remote provider")
    actual_key = saved["apiKey"]  # Memory only. Never written to fixture settings or logs.
    routing_key = "aurora-resilience-" + uuid.uuid4().hex
    started = time.monotonic()
    record_lock = threading.Lock()
    counts = collections.Counter()
    fired = set()
    provider_records = []

    def passed_phases():
        path = private / "receipts.jsonl"
        try:
            return {json.loads(line)["phase"] for line in path.read_text().splitlines()}
        except (OSError, ValueError):
            return set()

    def record(row):
        row = {"seconds": round(time.monotonic() - started, 3), **row}
        with record_lock:
            provider_records.append(row)
            with (root / "provider-events.jsonl").open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(row) + "\n")

    class Proxy(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def error_response(self, code, label):
            detail = "Temporary injected provider outage" if code != 429 else "Usage limit reached. Resets in 1 second"
            body = json.dumps({"error": {"message": detail}}).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            if code == 429:
                self.send_header("Retry-After", "1")
            self.end_headers()
            self.wfile.write(body); self.wfile.flush()
            counts["injected_provider_failures"] += 1
            record({"kind": label, "status": code, "phasesPassed": sorted(passed_phases())})

        def do_GET(self):
            self.forward(None)

        def do_POST(self):
            payload = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if not self.path.endswith("/chat/completions"):
                self.forward(payload); return
            request = json.loads(payload)
            if request.get("tools"):
                if all(m.get("role") in ("system", "developer") for m in request.get("messages", [])):
                    counts["system_only_task_requests"] += 1
                # Observe only: a missing pending repair fails the test rather
                # than inserting instructions into the agent's provider call.
                _, history = current()
                for message in reversed(history):
                    if message.get("role") == "tool" or (message.get("role") == "user" and not message.get("internal")):
                        break
                    content = message.get("content", "")
                    if message.get("internal") and content.startswith(("Agent output recovery:", "Execution recovery:")):
                        marker = content.splitlines()[0]
                        wire_text = "\n".join(m["content"] for m in request.get("messages", []) if isinstance(m.get("content"), str))
                        if marker not in wire_text:
                            counts["missing_recovery_directives"] += 1
                            record({"kind": "missing_recovery_directive", "marker": marker})
                        break
            counts["chat_attempts"] += 1
            number = counts["chat_attempts"]
            phases = passed_phases()
            # Three quick failures exceed the old per-request quick retry cap.
            if number <= 3:
                self.error_response(503, "initial_503"); return
            if 2 in phases and "mid_rate_limit" not in fired:
                counts["mid_rate_limit"] += 1
                if counts["mid_rate_limit"] == 2:
                    fired.add("mid_rate_limit")
                self.error_response(429, "mid_goal_429"); return
            if 5 in phases and "late_502" not in fired:
                counts["late_502"] += 1
                if counts["late_502"] == 3:
                    fired.add("late_502")
                self.error_response(502, "late_goal_502"); return
            truncate = 4 in phases and "broken_stream" not in fired
            if truncate:
                fired.add("broken_stream")
            counts["upstream_chat_requests"] += 1
            record({"kind": "upstream_request", "model": request.get("model"),
                    "messages": len(request.get("messages", [])),
                    "roles": [m.get("role") for m in request.get("messages", [])],
                    "bodySha256": hashlib.sha256(payload).hexdigest(),
                    "requestBytes": len(payload), "phasesPassed": sorted(phases),
                    "truncate": truncate})
            self.forward(payload, truncate)

        def forward(self, payload, truncate=False):
            connection_class = http.client.HTTPSConnection if target.scheme == "https" else http.client.HTTPConnection
            connection = connection_class(target.hostname, target.port, timeout=180)
            path = target.path.rstrip("/") + self.path.removeprefix("/v1")
            headers = {"Authorization": "Bearer " + actual_key, "User-Agent": "Aurora-resilience-live-proof",
                       "x-opencode-session": routing_key, "Content-Type": "application/json",
                       "Accept": self.headers.get("Accept", "text/event-stream")}
            try:
                connection.request("GET" if payload is None else "POST", path, body=payload, headers=headers)
                response = connection.getresponse()
                self.send_response(response.status)
                self.send_header("Content-Type", response.getheader("Content-Type", "application/json"))
                self.send_header("Connection", "close")
                self.end_headers()
                transferred = 0
                while True:
                    chunk = response.read1(4096)
                    if not chunk:
                        break
                    if truncate and response.status == 200:
                        # Cut a REAL successful provider stream before its
                        # terminal frame. No fabricated model/tool response.
                        limit = 768
                        chunk = chunk[:max(0, limit - transferred)]
                    if chunk:
                        self.wfile.write(chunk); self.wfile.flush()
                        transferred += len(chunk)
                    if truncate and response.status == 200 and transferred >= 768:
                        counts["injected_provider_failures"] += 1
                        counts["truncated_real_streams"] += 1
                        record({"kind": "truncated_real_sse", "bytes": transferred,
                                "phasesPassed": sorted(passed_phases())})
                        self.connection.shutdown(socket.SHUT_RDWR)
                        break
                if payload is not None:
                    record({"kind": "upstream_response", "status": response.status, "bytes": transferred})
                    if response.status >= 400:
                        counts["unexpected_upstream_errors"] += 1
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass
            except Exception as error:
                counts["proxy_transport_errors"] += 1
                record({"kind": "proxy_transport_error", "errorType": type(error).__name__})
            finally:
                connection.close()
                self.close_connection = True

    # Remain on loopback, while preserving the hosted wire profile. Aurora's
    # conventional localhost/127.0.0.1 endpoint selects llama.cpp normalization;
    # applying that to a hosted provider would change the path being tested.
    server = http.server.ThreadingHTTPServer(("127.0.0.2", 0), Proxy)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    local_base = f"http://127.0.0.2:{server.server_port}/v1"
    model = saved["model"]
    settings = dict(baseUrl=local_base, apiKey="isolated-fault-proxy", model=model,
                    workspace=str(workspace), thinking=saved.get("thinking", True),
                    settingsVersion=4, toolsEnabled=True, legacyTools=False,
                    quickTitle=False, composerSuggestion=False, followUpSuggestions=False,
                    autoGoalFromFirstMessage=True, verbosity="concise", developerMode=False,
                    developerSourceDir=str(workspace), developerRequireLatestSource=False,
                    contextBudgets=[dict(baseUrl=local_base, model=model, tokens=args.context)],
                    contextCompactions=[dict(baseUrl=local_base, model=model)])
    (state / "settings.json").write_text(json.dumps(settings), encoding="utf-8")
    prompt = ("Implement and verify the entire six-milestone billing delivery described in README.md. "
              "This is one persistent goal: follow each newly released milestone through phase 6, deliver the real "
              "invoice.json, invoice.csv and ledger.sqlite, then call goal_complete with actual successful check evidence. "
              "Read the existing code and test_public.py. All customer facts will be in the milestone files; "
              "make routine choices yourself. The acceptance worker can fail transiently with exit 75: retry it. "
              "Keep working through provider/tool failures without asking for Continue, approval or user input. "
              "Preserve run_checks.py and test_public.py. Work only in this isolated workspace; no desktop, "
              "publishing, sync, rebuild, original chats or other projects. The external read-only acceptance checker "
              "is authorized; do not change it or its private state. Final reference must be RESILIENCE-20261127-Q8. "
              "Finish only after all six phases, actual deliverables and final current-source verification pass.")
    (root / "prompt.txt").write_text(prompt, encoding="utf-8")
    proof = dict(status="running", model=model, thinking=settings["thinking"],
                 wireProfile="hosted",
                 binarySha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
                 externalGoalSubmissions=0, continueMessages=0, interventionMessages=0,
                 contextBudget=args.context, errors=[])
    process = None
    terminal = None
    incoming = queue.Queue()
    snapshots = []
    seen_signature = None
    last_print = 0
    maximum_observation_repeats = 0
    observation_counts = collections.Counter()
    observed_tools = 0
    last_workspace_state = None

    def workspace_fingerprint():
        digest = hashlib.sha256()
        for path in sorted(workspace.rglob("*")):
            if not path.is_file() or "__pycache__" in path.parts or path.suffix == ".pyc" or path.name.endswith(("-wal", "-shm", "-journal")):
                continue
            try:
                content_hash = hashlib.sha256(path.read_bytes()).digest()
            except OSError:
                continue
            digest.update(path.relative_to(workspace).as_posix().encode())
            digest.update(b"\0"); digest.update(content_hash)
        return digest.hexdigest()

    def current():
        index = read_json(state / "threads.index.json", {})
        headers = index.get("sessions", [])
        header = next((row for row in headers if row.get("goalStatus")), headers[0] if headers else {})
        history = read_json(state / "threads" / (str(header.get("id", "")) + ".json"), {})
        return header, history.get("messages", [])

    def send(value):
        process.stdin.write(json.dumps(value) + "\n"); process.stdin.flush()

    print("ARTIFACTS", root, "MODEL", model, "BINARY", proof["binarySha256"], flush=True)
    try:
        with (root / "process.log").open("w", encoding="utf-8") as error_log:
            process = subprocess.Popen([str(executable), "--session-server"], cwd=workspace,
                env=dict(os.environ, APPDATA=str(appdata), TEMP=str(private), TMP=str(private),
                         AURORA_STRICT_PLAN="0", AURORA_TOOL_ROOT=str(root), FORGE_PUBLISH_SKIP="1"),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=error_log,
                text=True, encoding="utf-8", errors="replace", bufsize=1)

            def collect():
                for line in process.stdout:
                    try:
                        incoming.put(json.loads(line))
                    except ValueError:
                        pass
            threading.Thread(target=collect, daemon=True).start()
            send(dict(type="create", id="live-goal", title="Long goal with real provider and failures",
                      workspace=str(workspace), model=model, thinking=settings["thinking"], tools=True))
            with (root / "events.jsonl").open("w", encoding="utf-8") as events:
                while time.monotonic() - started < args.timeout:
                    try:
                        event = incoming.get(timeout=1)
                        events.write(json.dumps(event) + "\n"); events.flush()
                        if event.get("type") == "created":
                            send(dict(type="submit", id="live-goal", requestId="one-standing-goal", text=prompt))
                            proof["externalGoalSubmissions"] += 1
                        if event.get("type") in ("turn.completed", "turn.failed", "turn.interrupted"):
                            terminal = event
                            break
                        if event.get("type") == "error":
                            raise RuntimeError("Session server: " + str(event.get("error")))
                    except queue.Empty:
                        if process.poll() is not None:
                            raise RuntimeError("Aurora exited before goal completion")
                    header, messages = current()
                    tools = [m for m in messages if m.get("role") == "tool"]
                    workspace_state = (workspace_fingerprint(), tuple(sorted(passed_phases())))
                    if workspace_state != last_workspace_state:
                        observation_counts.clear(); last_workspace_state = workspace_state
                    for m in tools[observed_tools:]:
                        name = m.get("toolName")
                        try:
                            arguments = json.loads(m.get("toolArgs", "{}"))
                        except ValueError:
                            arguments = {}
                        if name not in ("read", "list") and not (name == "dshell" and arguments.get("command") == "list"):
                            continue
                        target_path = arguments.get("filePath", arguments.get("path", ""))
                        key = (name, os.path.normcase(os.path.normpath(target_path)),
                               hashlib.sha256(m.get("content", "").encode()).hexdigest())
                        observation_counts[key] += 1
                    observed_tools = max(observed_tools, len(tools))
                    maximum_observation_repeats = max(maximum_observation_repeats, max(observation_counts.values(), default=0))
                    if maximum_observation_repeats >= 9:
                        raise RuntimeError("Sustained observation loop: the same unchanged file/list result was fetched nine times without workspace or milestone progress")
                    if any(m.get("toolName") in ("rebuild", "sync", "computer", "open") for m in tools):
                        raise RuntimeError("The isolated task requested a forbidden application/desktop operation")
                    if counts["missing_recovery_directives"]:
                        raise RuntimeError("Pending recovery was saved but omitted from the actual provider request")
                    if counts["system_only_task_requests"]:
                        raise RuntimeError("Compaction produced a system-only task request without a conversational turn")
                    # Completion-only recovery is a product defect, even if
                    # the goal itself has been marked complete. Do not let
                    # repeated final answers run until the overall deadline.
                    if header.get("goalStatus") == "completed":
                        last_tool = max((i for i, m in enumerate(messages) if m.get("role") == "tool"), default=-1)
                        final_recoveries = sum(bool(m.get("internal")) and "cause=unfinished_outcome" in m.get("content", "")
                                               for m in messages[last_tool + 1:])
                        if final_recoveries >= 3:
                            raise RuntimeError("Completion loop: verified goal completed but final replies were repeatedly rejected without further actions")
                    signature = (header.get("goalStatus"), header.get("turnStatus"), len(messages), len(tools), workspace_state)
                    if signature != seen_signature:
                        row = dict(seconds=round(time.monotonic() - started, 2), goalStatus=header.get("goalStatus"),
                                   turnStatus=header.get("turnStatus"), taskStatus=header.get("taskStatus"),
                                   verificationStatus=header.get("verificationStatus"), toolResults=len(tools),
                                   workspaceSha256=workspace_state[0],
                                   failedTools=sum(bool(m.get("failed")) for m in tools),
                                   phasesPassed=sorted(passed_phases()))
                        snapshots.append(row); seen_signature = signature
                        with (root / "timeline.jsonl").open("a", encoding="utf-8") as stream:
                            stream.write(json.dumps(row) + "\n")
                    elapsed = time.monotonic() - started
                    if elapsed - last_print >= 20:
                        print("LIVE", round(elapsed), "seconds; phases", sorted(passed_phases()),
                              "tools", len(tools), "failed", sum(bool(m.get("failed")) for m in tools),
                              "goal", header.get("goalStatus"), "turn", header.get("turnStatus"), flush=True)
                        last_print = elapsed
                else:
                    raise TimeoutError("The real goal did not finish within the observation deadline")
            proof["terminal"] = terminal
            send(dict(type="shutdown")); process.wait(timeout=45)
        header, messages = current()
        tools = [m for m in messages if m.get("role") == "tool"]
        proof.update(goalStatus=header.get("goalStatus"), taskStatus=header.get("taskStatus"),
                     verificationStatus=header.get("verificationStatus"), toolResults=len(tools),
                     failedTools=sum(bool(m.get("failed")) for m in tools),
                     modelToolRounds=sum(bool(m.get("toolCalls")) for m in messages),
                     provider=dict(counts), phasesPassed=sorted(passed_phases()),
                     compactionOccurred=bool(header.get("compactionSummary")),
                     goalCompletionCalls=sum(m.get("toolName") == "goal_complete" and not m.get("failed") for m in tools),
                     userInputRequests=sum(m.get("toolName") in ("request_input", "task_blocker", "ask_user") for m in tools))
        assert terminal["type"] == "turn.completed" and terminal["turnStatus"] == "completed", terminal
        assert header.get("goalStatus") == "completed", "The turn stopped before the persistent goal was complete"
        assert header.get("verificationStatus") == "passed", "Current-source verification missing"
        assert proof["phasesPassed"] == list(range(1, 7)), "Not every phase passed"
        assert proof["externalGoalSubmissions"] == 1 and proof["userInputRequests"] == 0, "User intervention was requested"
        assert proof["goalCompletionCalls"] >= 1, "The model did not validate goal completion"
        assert counts["injected_provider_failures"] == 9 and counts["truncated_real_streams"] == 1, "Scheduled provider faults were not all exercised"
        fault_rows = [json.loads(line) for line in (private / "tool-faults.jsonl").read_text().splitlines()]
        assert {row["phase"] for row in fault_rows} == {1, 3, 5}, "Real tool failures were not all exercised"
        proof["injectedToolFailures"] = len(fault_rows)
        # Final verifier is independent of the model and runs after it stopped.
        audited = subprocess.run([sys.executable, "-B", str(Path(__file__).with_name("live_goal_fixture.py")),
            "phase", str(workspace), str(private), "--phase", "6"], capture_output=True, text=True, timeout=120)
        (root / "independent-final.log").write_text(audited.stdout + audited.stderr, encoding="utf-8")
        assert audited.returncode == 0, "Independent final verifier failed: " + audited.stderr[-1800:]
        proof["independentFinalPassed"] = True
        identities = collections.Counter((m.get("toolName"), m.get("toolArgs"), m.get("content")) for m in tools
                                         if m.get("toolName") not in ("process", "tool_status", "read_plan", "update_plan", "update_subplan"))
        proof["maximumIdenticalToolResultCount"] = max(identities.values(), default=0)
        proof["finalChecks"] = json.loads((private / "receipts.jsonl").read_text().splitlines()[-1])["checks"]
        proof["status"] = "passed"
    except Exception as error:
        proof["status"] = "failed"; proof["errors"].append(str(error))
    finally:
        if process is not None and process.poll() is None:
            try:
                send(dict(type="cancel", id="live-goal")); send(dict(type="shutdown")); process.wait(timeout=30)
            except Exception:
                process.kill(); process.wait(timeout=15)
        server.shutdown(); server.server_close()
        actual_key = ""
        proof["seconds"] = round(time.monotonic() - started, 3)
        proof["maximumIdenticalObservationStreak"] = maximum_observation_repeats
        header, messages = current()
        tools = [m for m in messages if m.get("role") == "tool"]
        proof.update(goalStatus=header.get("goalStatus"), taskStatus=header.get("taskStatus"),
                     verificationStatus=header.get("verificationStatus"), toolResults=len(tools),
                     failedTools=sum(bool(m.get("failed")) for m in tools),
                     modelToolRounds=sum(bool(m.get("toolCalls")) for m in messages),
                     provider=dict(counts), phasesPassed=sorted(passed_phases()),
                     compactionOccurred=bool(header.get("compactionSummary")),
                     userInputRequests=sum(m.get("toolName") in ("request_input", "task_blocker", "ask_user") for m in tools),
                     goalCompletionCalls=sum(m.get("toolName") == "goal_complete" and not m.get("failed") for m in tools),
                     sourceFiles={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in
                                  (Path(__file__), Path(__file__).with_name("live_goal_fixture.py"))})
        (root / "result.json").write_text(json.dumps(proof, indent=2), encoding="utf-8")
        print("RESULT", proof["status"], proof["errors"], "ARTIFACTS", root, flush=True)
    return 0 if proof["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
