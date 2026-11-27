"""Real native execution, credential-free fault proxy, and task-level measurements."""
from __future__ import annotations

import collections
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import queue
import re
import socket
import subprocess
import threading
import time
from urllib.parse import urlsplit
import uuid


def read_json(path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return default


def files(workspace):
    return {p.relative_to(workspace).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(workspace.rglob("*")) if p.is_file()
            and "__pycache__" not in p.parts and p.suffix != ".pyc"
            and not p.name.endswith(("-wal", "-shm", "-journal"))}


def json_answer(text):
    return json.loads(re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip()))


def completion_loop(messages):
    last_tool = max((i for i, m in enumerate(messages) if m.get("role") == "tool"), default=-1)
    rejected = collections.Counter()
    for message in messages[last_tool + 1:]:
        text = message.get("content", "")
        if not message.get("internal") or not text.startswith("Execution recovery:") or "cause=unfinished_outcome" not in text:
            continue
        try:
            fingerprint = json.loads(text.splitlines()[0].removeprefix("Execution recovery:").strip())["fingerprint"]
            rejected[fingerprint] += 1
        except (ValueError, KeyError):
            continue
    return max(rejected.values(), default=0) >= 3


class ProviderProxy:
    def __init__(self, saved, root, outages=0, truncate=False):
        self.target = urlsplit(saved["baseUrl"])
        assert self.target.scheme == "https" and self.target.hostname not in ("localhost", "127.0.0.1")
        self.key = saved["apiKey"]
        self.root, self.outages, self.truncate = root, outages, truncate
        self.counts = collections.Counter()
        self.started = time.monotonic()
        self.records, self.lock = [], threading.Lock()
        routing = "aurora-matrix-" + uuid.uuid4().hex
        owner = self

        class Proxy(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_):
                pass

            def handle(self):
                try:
                    super().handle()
                except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
                    pass

            def do_GET(self):
                self.forward(None)

            def do_POST(self):
                payload = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                request = json.loads(payload)
                owner.counts["attempts"] += 1
                if owner.counts["attempts"] <= owner.outages:
                    body = b'{"error":{"message":"Temporary injected provider outage"}}'
                    self.send_response(503)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Connection", "close")
                    self.end_headers(); self.wfile.write(body); self.wfile.flush()
                    owner.counts["injected503"] += 1
                    owner.record({"kind": "injected503"})
                    self.close_connection = True
                    return
                roles = [m.get("role") for m in request.get("messages", [])]
                cut = owner.truncate and request.get("tools") and roles.count("tool") >= 4
                if cut:
                    owner.truncate = False
                owner.record({"kind": "request", "roles": roles, "bytes": len(payload),
                              "sha256": hashlib.sha256(payload).hexdigest(),
                              "tools": [t.get("function", {}).get("name") for t in request.get("tools", [])],
                              "truncate": bool(cut)})
                self.forward(payload, cut)

            def forward(self, payload, cut=False):
                connection = http.client.HTTPSConnection(owner.target.hostname, owner.target.port, timeout=180)
                started = time.monotonic()
                try:
                    connection.request("GET" if payload is None else "POST",
                        owner.target.path.rstrip("/") + self.path.removeprefix("/v1"), body=payload,
                        headers={"Authorization": "Bearer " + owner.key, "Content-Type": "application/json",
                                 "x-opencode-session": routing, "User-Agent": "Aurora-task-matrix"})
                    response = connection.getresponse()
                    self.send_response(response.status)
                    self.send_header("Content-Type", response.getheader("Content-Type", "application/json"))
                    self.send_header("Connection", "close"); self.end_headers()
                    transferred, pending, usage = 0, b"", None
                    first_byte = None
                    while True:
                        chunk = response.read1(4096)
                        if not chunk:
                            break
                        if first_byte is None:
                            first_byte = time.monotonic() - started
                        if cut and response.status == 200:
                            chunk = chunk[:max(0, 768 - transferred)]
                        if chunk:
                            self.wfile.write(chunk); self.wfile.flush(); transferred += len(chunk)
                            pending += chunk
                            while b"\n" in pending:
                                line, pending = pending.split(b"\n", 1)
                                if line.startswith(b"data: "):
                                    try:
                                        frame = json.loads(line[6:])
                                        if frame.get("usage"):
                                            usage = frame["usage"]
                                    except (ValueError, AttributeError):
                                        pass
                        if cut and response.status == 200 and transferred >= 768:
                            owner.counts["truncatedStreams"] += 1
                            self.connection.shutdown(socket.SHUT_RDWR)
                            break
                    if payload is not None:
                        owner.counts["upstreamRequests"] += 1
                        owner.record({"kind": "response", "status": response.status, "bytes": transferred,
                                      "seconds": round(time.monotonic() - started, 3),
                                      "firstByteSeconds": first_byte, "usage": usage, "truncated": bool(cut)})
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    pass
                except Exception as error:
                    owner.counts["transportErrors"] += 1
                    owner.record({"kind": "transportError", "type": type(error).__name__})
                finally:
                    connection.close(); self.close_connection = True

        self.server = http.server.ThreadingHTTPServer(("127.0.0.2", 0), Proxy)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.2:{self.server.server_port}/v1"

    def record(self, row):
        row = {"elapsed": round(time.monotonic() - self.started, 3), **row}
        with self.lock:
            self.records.append(row)
            with (self.root / "provider-events.jsonl").open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(row) + "\n")

    def close(self):
        self.server.shutdown(); self.server.server_close(); self.key = ""


def run_case(case, executable, saved, root, repeat=1):
    root.mkdir(parents=True, exist_ok=False)
    workspace = root / "workspace"; workspace.mkdir()
    private = root / "private"; private.mkdir()
    fixtures = case.setup(workspace, private)
    initial = files(workspace)
    state = root / "appdata/Aurora OpenCode"; state.mkdir(parents=True)
    proxy = ProviderProxy(saved, root, case.outages, case.truncate)
    settings = dict(baseUrl=proxy.base, apiKey="isolated-matrix-proxy", model=saved["model"],
        workspace=str(workspace), thinking=saved.get("thinking", True), settingsVersion=4,
        toolsEnabled=True, legacyTools=False, quickTitle=False, composerSuggestion=False,
        followUpSuggestions=False, autoGoalFromFirstMessage=case.goal, verbosity="concise",
        developerMode=False, developerSourceDir=str(workspace), developerRequireLatestSource=False,
        contextBudgets=[dict(baseUrl=proxy.base, model=saved["model"], tokens=32000)],
        contextCompactions=[dict(baseUrl=proxy.base, model=saved["model"])])
    (state / "settings.json").write_text(json.dumps(settings), encoding="utf-8")
    process, started, inbox = None, time.monotonic(), queue.Queue()
    result = dict(name=case.name, complexity=case.complexity, repeat=repeat, status="failed",
                  model=saved["model"], thinking=settings["thinking"], goal=case.goal,
                  binarySha256=hashlib.sha256(executable.read_bytes()).hexdigest(), turns=[], errors=[])

    def current():
        headers = read_json(state / "threads.index.json", {}).get("sessions", [])
        header = headers[0] if headers else {}
        chat = read_json(state / "threads" / (header.get("id", "") + ".json"), {})
        return header, chat.get("messages", [])

    def send(message):
        process.stdin.write(json.dumps(message) + "\n"); process.stdin.flush()

    try:
        with (root / "process.log").open("w", encoding="utf-8") as log, (root / "events.jsonl").open("w", encoding="utf-8") as events:
            process = subprocess.Popen([str(executable), "--session-server"], cwd=workspace,
                env=dict(os.environ, APPDATA=str(root / "appdata"), TEMP=str(private), TMP=str(private),
                         AURORA_STRICT_PLAN="0", AURORA_TOOL_ROOT=str(root), FORGE_PUBLISH_SKIP="1"),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                text=True, encoding="utf-8", errors="replace", bufsize=1)

            def collect():
                for line in process.stdout:
                    try:
                        inbox.put(json.loads(line))
                    except ValueError:
                        pass
            threading.Thread(target=collect, daemon=True).start()
            send(dict(type="create", id="matrix", title=case.name, workspace=str(workspace),
                      model=saved["model"], thinking=settings["thinking"], tools=True))
            prompts = case.prompts(fixtures)
            (root / "prompts.json").write_text(json.dumps(prompts, indent=2), encoding="utf-8")
            position, turn_started, last_print = 0, time.monotonic(), 0
            while time.monotonic() - started < case.timeout:
                try:
                    event = inbox.get(timeout=1)
                    events.write(json.dumps(event) + "\n"); events.flush()
                    if event.get("type") == "created":
                        send(dict(type="submit", id="matrix", requestId="task-0", text=prompts[0]))
                        turn_started = time.monotonic()
                    if event.get("type") in ("turn.completed", "turn.failed", "turn.interrupted"):
                        assert event["type"] == "turn.completed" and event.get("turnStatus") == "completed", event
                        result["turns"].append(dict(index=position, seconds=round(time.monotonic() - turn_started, 3),
                                                    reply=event.get("reply", ""), terminal=event))
                        case.check_turn(position, event.get("reply", ""), workspace, fixtures)
                        position += 1
                        if position == len(prompts):
                            break
                        send(dict(type="submit", id="matrix", requestId="task-" + str(position), text=prompts[position]))
                        turn_started = time.monotonic()
                    if event.get("type") == "error":
                        raise RuntimeError(event.get("error", "Session-server error"))
                except queue.Empty:
                    if process.poll() is not None:
                        raise RuntimeError("Native process exited before completion")
                header, history = current()
                tools = [m for m in history if m.get("role") == "tool"]
                assert not completion_loop(history), "Completion loop: three identical rejections without another tool result"
                assert not any(m.get("toolName") in ("request_input", "task_blocker", "ask_user") for m in tools), "Requested user intervention"
                assert not any(m.get("toolName") in ("rebuild", "sync", "computer", "open") for m in tools), "Requested self-maintenance or desktop outside task"
                elapsed = time.monotonic() - started
                if elapsed - last_print >= 30:
                    print("LIVE", case.name, round(elapsed), "seconds; tools", len(tools), "state", header.get("taskStatus"), flush=True)
                    last_print = elapsed
            else:
                raise TimeoutError("Task exceeded the observation deadline")
            send(dict(type="shutdown")); process.wait(timeout=45)
        header, history = current()
        tools = [m for m in history if m.get("role") == "tool"]
        humans = [m for m in history if m.get("role") == "user" and not m.get("internal")]
        assert len(humans) == len(prompts), "Unexpected external steering"
        assert all(not re.search(r"(?:press|click)\s+[`\"']*continue|would you like me to|shall I (?:proceed|continue)", turn["reply"], re.I)
                   for turn in result["turns"]), "Final response asked for avoidable handholding"
        if case.readonly:
            assert files(workspace) == initial, "Read-only task mutated workspace files"
        for name in case.protected:
            assert files(workspace).get(name) == initial.get(name), "Protected input changed: " + name
        if case.goal:
            assert header.get("goalStatus") == "completed" and header.get("verificationStatus") == "passed", "Goal stopped without verified completion"
        assert proxy.counts["injected503"] == case.outages
        if case.truncate:
            assert proxy.counts["truncatedStreams"] == 1, "Truncated-stream failure was not exercised"
        result["independent"] = case.audit(workspace, private, fixtures, history, root)
        result["status"] = "passed"
    except Exception as error:
        result["errors"].append(str(error))
    finally:
        if process is not None and process.poll() is None:
            try:
                send(dict(type="cancel", id="matrix")); send(dict(type="shutdown")); process.wait(timeout=20)
            except Exception:
                process.kill(); process.wait(timeout=10)
        proxy.close()
        header, history = current()
        tools = [m for m in history if m.get("role") == "tool"]
        counts = collections.Counter(m.get("toolName") for m in tools)
        results = collections.Counter((m.get("toolName"), m.get("content")) for m in tools)
        result.update(seconds=round(time.monotonic() - started, 3), taskStatus=header.get("taskStatus"),
            goalStatus=header.get("goalStatus"), turnStatus=header.get("turnStatus"), verificationStatus=header.get("verificationStatus"),
            toolResults=len(tools), failedTools=sum(bool(m.get("failed")) for m in tools), toolCounts=dict(counts),
            repeatedToolResults=sum(n - 1 for n in results.values()),
            modelToolRounds=sum(bool(m.get("toolCalls")) for m in history), provider=dict(proxy.counts),
            userInputRequests=sum(m.get("toolName") in ("request_input", "task_blocker", "ask_user") for m in tools),
            externalSubmissions=len([m for m in history if m.get("role") == "user" and not m.get("internal")]),
            compactionOccurred=bool(header.get("compactionSummary")),
            answerWords=sum(len(turn["reply"].split()) for turn in result["turns"]),
            efficiencyBudget=case.tool_budget, efficiencyExceeded=len(tools) > case.tool_budget,
            sourceFiles=files(workspace))
        # Efficiency is separately reported: a slow correct result is not
        # silently conflated with an incorrect answer or a stalled goal.
        (root / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        if hasattr(fixtures, "close"):
            fixtures.close()
        print("RESULT", case.name, result["status"], round(result["seconds"], 1), "seconds; tools", len(tools), result["errors"], flush=True)
    return result
