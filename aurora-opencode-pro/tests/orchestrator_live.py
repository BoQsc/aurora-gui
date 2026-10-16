"""End-to-end check that the experimental orchestrator leads PARALLEL ROUNDS.

It runs the real desktop binary once with `--headless <prompt>` against an
in-process SSE fixture provider that plays the orchestrator's model:

  * round 1  -> assign {builder, reviewer}   (two subagents must run at once)
  * round 2  -> assign {researcher}          (the orchestrator leads the next
                                              round, from its own nested chat)
  * then     -> finish                       (the dispatch closes)

The fixture records every request identity and how many subagent requests were
in flight together, which is the concurrency evidence. Afterwards the persisted
state is checked for the nested subagent chats.

Usage: python -u tests/orchestrator_live.py
"""
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

package = Path(__file__).resolve().parents[1]
HOLD = 0.6
# How many rounds the fixture's orchestrator leads before it finishes. One vs
# two isolates a fault that only a *second* round can reach.
ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("ORCH_ROUNDS", "2"))
# "finish" ends the dispatch with the finish tool; "plain" ends it with a final
# message. They isolate a fault in the finish tool from the resumed turn itself.
MODE = sys.argv[2] if len(sys.argv) > 2 else "finish"

lock = threading.Lock()
log = []
state = {"inFlight": 0, "peak": 0, "subagent": 0, "orchestrator": 0}
NAMES = ("builder", "reviewer", "researcher", "orchestrator")


def row(delta, finish=None):
    return "data: " + json.dumps(
        {"choices": [{"delta": delta, "finish_reason": finish}]}) + "\n\n"


def tool_row(identity, name, arguments):
    return "data: " + json.dumps({"choices": [{"delta": {"tool_calls": [
        {"index": 0, "id": identity, "type": "function",
         "function": {"name": name, "arguments": json.dumps(arguments)}}]},
        "finish_reason": "tool_calls"}]}) + "\n\n"
def tool_row_many(calls):
    """Several tool calls in one delta, as a provider streams a batch."""
    fragments = []
    for index, (identity, name, arguments) in enumerate(calls):
        fragments.append({"index": index, "id": identity, "type": "function",
                          "function": {"name": name,
                                       "arguments": json.dumps(arguments)}})
    return "data: " + json.dumps({"choices": [{"delta": {"tool_calls": fragments},
                                               "finish_reason": "tool_calls"}]}) + "\n\n"



USAGE = "data: " + json.dumps(
    {"choices": [], "usage": {"prompt_tokens": 100, "completion_tokens": 20,
                              "total_tokens": 120}}) + "\n\n"
DONE = "data: [DONE]\n\n"


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def wire(self, body, kind="text/event-stream"):
        payload = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()

    def fail(self, status=500):
        body = json.dumps({"error": {"message": "fixture failure"}}).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def do_GET(self):
        self.wire(json.dumps({"data": [{"id": "fixture", "owned_by": "fixture"}]}),
                  "application/json")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        system = " ".join(message.get("content", "")
                          for message in request.get("messages", [])
                          if message.get("role") == "system"
                          and isinstance(message.get("content"), str))
        if not request.get("tools"):
            with lock:
                log.append("utility")
            self.wire(row({"content": "Round report"}, "stop") + DONE)
            return
        identity = next((name for name in NAMES if "(id %s)" % name in system),
                        "unknown")
        with lock:
            log.append(identity)

        if MODE == "generic":
            # No orchestrator: one ordinary tool round, then a final answer.
            # Same shape of transcript, no subagents, to tell a fault in the
            # orchestrator apart from a general tool-row painting fault.
            with lock:
                state["orchestrator"] += 1
                turn = state["orchestrator"]
            print("fixture: generic request %d" % turn, flush=True)
            if turn == 1:
                self.wire(row({"content": "Writing the file."}, None) +
                          tool_row("write-1", "write", {"filePath": "out.txt",
                                                        "content": "hello"}) +
                          USAGE + DONE)
            else:
                self.wire(row({"content": "Done."}, "stop") + USAGE + DONE)
            return

        if identity in ("builder", "reviewer", "researcher"):
            if MODE == "subfail":
                # A subagent's request fails: the round must still settle
                # instead of leaving the orchestrator waiting forever.
                print("fixture: %s request failed on purpose" % identity,
                      flush=True)
                self.fail()
                return
            with lock:
                state["subagent"] += 1
                state["inFlight"] += 1
                state["peak"] = max(state["peak"], state["inFlight"])
                live = state["inFlight"]
            print("fixture: %s request, %d subagent requests in flight"
                  % (identity, live), flush=True)
            time.sleep(HOLD)  # hold it open so the two subagents overlap
            with lock:
                state["inFlight"] -= 1
            self.wire(row({"content": "Report from %s: my part is done." % identity},
                          "stop") + USAGE + DONE)
            return

        with lock:
            state["orchestrator"] += 1
            turn = state["orchestrator"]
        print("fixture: orchestrator request %d" % turn, flush=True)
        if turn == 1 and ROUNDS >= 1:
            calls = [("assign-1", "assign", {"assignments": [
                {"agent_id": "builder", "task": "Implement it"},
                {"agent_id": "reviewer", "task": "Review it"}]})]
            if MODE == "shot-inline":
                # A real orchestrator records the plan it works from, and the
                # inline plan card hangs off that plan; without it there is no
                # in-transcript plan surface to host the subagent rows.
                calls.insert(0, ("plan-1", "update_plan", {
                    "objective": "Build and review the feature",
                    "plan": [{"step": "Implement the feature",
                              "status": "in_progress"},
                             {"step": "Review it", "status": "pending"}]}))
            self.wire(row({"content": "Assigning the first round."}, None) +
                      tool_row_many(calls) + USAGE + DONE)
        elif turn == 2 and ROUNDS >= 2:
            if MODE == "revisit":
                # Re-task a subagent that already owns a nested chat: the round
                # must reuse that chat instead of creating another.
                batch = {"assignments": [{"agent_id": "builder",
                                          "task": "Fix what the review found"}]}
            else:
                batch = {"assignments": [{"agent_id": "researcher",
                                          "task": "Check the facts"}]}
            self.wire(row({"content": "Leading the next round."}, None) +
                      tool_row("assign-2", "assign", batch) + USAGE + DONE)
        elif MODE == "finish" and turn == ROUNDS + 1:
            # End the dispatch, exactly once: the app asks again for its final
            # answer, which must be a plain reply rather than another finish.
            self.wire(row({"content": "Dispatch complete."}, None) +
                      tool_row("finish-1", "finish", {"summary": "Goal met"}) +
                      USAGE + DONE)
        elif MODE == "ask" and turn == ROUNDS + 1:
            # The decision belongs to the user: ask, then stop the dispatch.
            self.wire(row({"content": "I need a decision."}, None) +
                      tool_row("ask-1", "ask_user",
                               {"question": "Which database should I use?"}) +
                      USAGE + DONE)
        else:
            self.wire(row({"content": "Goal met."}, "stop") + USAGE + DONE)


def records(node):
    """Yield every JSON object, so a nested chat can be found wherever it lives."""
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from records(value)
    elif isinstance(node, list):
        for value in node:
            yield from records(value)


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    port = server.server_port
    threading.Thread(target=server.serve_forever, daemon=True).start()

    directory = Path(tempfile.mkdtemp(prefix="orchestrator-live-"))
    print("state directory: %s" % directory, flush=True)
    workspace = directory / "workspace"
    workspace.mkdir()
    appdata = directory / "appdata"
    state_dir = appdata / "Aurora OpenCode"
    state_dir.mkdir(parents=True)
    (state_dir / "settings.json").write_text(json.dumps({
        "baseUrl": "http://127.0.0.1:%d/v1" % port, "apiKey": "local-fixture",
        "model": "fixture", "workspace": str(workspace), "toolsEnabled": True,
        "legacyTools": False, "quickTitle": False,
        "experimentalOrchestrator": MODE != "generic",
        # "shot-inline" renders the plan inside the transcript instead of the
        # detached panel, so both plan surfaces can be checked.
        "detachedPlan": MODE != "shot-inline",
    }), encoding="utf-8")

    env = dict(os.environ, APPDATA=str(appdata))
    executable = package / "aurora-opencode-pro.exe"
    started = time.monotonic()
    prompt = "Build and review the feature, then report based on the facts."
    image = directory / "plan.png"
    restored = directory / "restored.png"
    if MODE == "restore":
        # Persist a round in this project first, then load that project again:
        # the restored chat must still list its nested subagent chats.
        first = subprocess.run(
            [str(executable), "--screenshot-chat", str(image), prompt],
            cwd=workspace, env=env, timeout=60, capture_output=True, text=True)
        print("first run exit %d, screenshot %s" % (first.returncode, image),
              flush=True)
        result = subprocess.run(
            [str(executable), "--screenshot-chat", str(restored), prompt],
            cwd=workspace, env=env, timeout=60, capture_output=True, text=True)
        print("second run exit %d, screenshot %s" % (result.returncode, restored),
              flush=True)
    if MODE in ("shot", "shot-inline", "restore"):
        # Render the real transcript (plan card included) and keep the pixels
        # for inspection: the plan must list the named subagents.
        command = [str(executable), "--screenshot-chat", str(image), prompt]
    else:
        command = [str(executable), "--headless", prompt]
    if MODE != "restore":
        result = subprocess.run(command, cwd=workspace, env=env, timeout=60,
                                capture_output=True, text=True)
    print("app exit %d after %.1fs" % (result.returncode, time.monotonic() - started))
    if result.stdout.strip():
        print("app stdout: " + result.stdout.strip()[-1500:])
    if result.stderr.strip():
        print("app stderr: " + result.stderr.strip()[-1500:])
    if MODE in ("shot", "shot-inline", "restore"):
        print("screenshot: %s (%d bytes)"
              % (image, image.stat().st_size if image.exists() else -1))
        if not image.exists() or image.stat().st_size < 5000:
            print("FAIL the screenshot was not written")
            return 1
        if MODE == "restore":
            print("restored: %s (%d bytes)"
                  % (restored, restored.stat().st_size if restored.exists() else -1))
            if not restored.exists() or restored.stat().st_size < 5000:
                print("FAIL the restored screenshot was not written")
                return 1

    with lock:
        identity_log, subagents, peak = list(log), state["subagent"], state["peak"]
        orchestrator = state["orchestrator"]
    print("fixture saw: %s" % identity_log)

    failures = []
    if result.returncode != 0:
        failures.append("the app exited %d" % result.returncode)
    if MODE != "subfail" and peak < 2:
        failures.append("the subagents never overlapped (peak in flight %d)" % peak)
    expected = ["builder", "reviewer"] + (
        ["researcher"] if ROUNDS >= 2 and MODE != "revisit" else [])
    if MODE == "generic":
        expected = []
    if MODE == "revisit" and identity_log.count("builder") < 2:
        failures.append("the second round did not re-task the existing subagent")
    for name in expected:
        if name not in identity_log:
            failures.append("the orchestrator never dispatched %s" % name)
    wanted_turns = ROUNDS + 1
    if MODE != "generic" and orchestrator < wanted_turns:
        failures.append("the orchestrator made %d requests, expected >= %d"
                        % (orchestrator, wanted_turns))
    if identity_log.count("builder") == 0 or identity_log.count("reviewer") == 0:
        failures.append("round one did not run builder and reviewer")

    # The nested subagent chats must be persisted, linked to the parent chat.
    nested = {}
    for path in state_dir.rglob("*.json"):
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            continue
        for record in records(value):
            # The thread store serializes the parent link as `parentSession`.
            parent = record.get("parentSessionId") or record.get("parentSession")
            agent = record.get("subagentId")
            if isinstance(parent, str) and parent and isinstance(agent, str) and agent:
                nested[agent] = parent
    print("persisted nested chats: %s" % nested)
    if MODE == "revisit" and "researcher" in nested:
        failures.append("re-tasking must reuse the existing nested chat")
    for name in expected:
        if name not in nested:
            failures.append("no persisted nested chat for %s" % name)
    if len(set(nested.values())) > 1:
        failures.append("the nested chats do not share one parent: %s" % nested)

    # The orchestrator's own conversation records how the dispatch ended.
    hub_status = ""
    index_path = state_dir / "threads.index.json"
    if index_path.exists():
        try:
            index_value = json.loads(index_path.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            index_value = None
        if index_value is not None:
            for record in records(index_value):
                agents = record.get("agents")
                if isinstance(agents, list) and any(
                        isinstance(agent, dict) and agent.get("router")
                        for agent in agents):
                    hub_status = record.get("taskStatus", "")
                    break
    print("orchestrator task status: %r" % hub_status)
    if MODE == "ask" and hub_status != "blocked":
        failures.append("ask_user must leave the task blocked, saw %r" % hub_status)

    server.shutdown()
    if failures:
        print("FAIL " + "; ".join(failures))
        return 1
    print("PASS parallel rounds: %d subagents overlapped, %d orchestrator turns, "
          "nested chats for %s" % (peak, orchestrator, ", ".join(sorted(nested))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
