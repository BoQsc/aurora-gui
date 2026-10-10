"""Exercise a multi-turn conversation through real HTTP, widgets and tools."""
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
requests = []
failures = []
finals = collections.Counter()
note = "# Dinner plan\nFour people. Vegetarian. No mushrooms. Gluten-free corn tortillas.\nReady within 45 minutes.\n"
check = ("import time, unittest\nSEATS = 3\n"
         "class DinnerCheck(unittest.TestCase):\n"
         " def test_seats(self):\n"
         "  print('checking guest count', flush=True)\n"
         "  time.sleep(0.5)\n"
         "  self.assertEqual(SEATS, 4)\n")


def call(identity, name, args):
    return {"id": identity, "type": "function",
            "function": {"name": name, "arguments": json.dumps(args)}}


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_body(self, body, kind):
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def do_GET(self):
        self.send_body(json.dumps({"data": [{"id": "conversation-fixture"}]}), "application/json")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(request)
        messages = request["messages"]
        prefixes = ("CHAT:", "CORRECTION:", "SAVE:", "REPAIR:", "RECAP:", "SLOW:", "NEW:", "OTHER:")
        prompts = [m["content"] for m in messages if m["role"] == "user"
                   and isinstance(m.get("content"), str) and m["content"].startswith(prefixes)]
        prompt = prompts[-1] if prompts else ""
        scenario = prompt.partition(":")[0]
        owners, seen = set(), set()
        results = {}
        for m in messages:
            for c in m.get("tool_calls", []):
                owners.add(c["id"])
            if m["role"] == "tool":
                identity = m["tool_call_id"]
                if identity not in owners or identity in seen:
                    failures.append("Unpaired or duplicate result: " + identity)
                seen.add(identity)
                results[identity] = m["content"]
        if scenario in ("CORRECTION", "SAVE", "REPAIR", "RECAP"):
            if not any(p.startswith("CHAT:") for p in prompts):
                failures.append("Lost original casual prompt")
        if scenario in ("SAVE", "REPAIR", "RECAP"):
            if not any(p.startswith("CORRECTION:") for p in prompts):
                failures.append("Lost corrected constraints")
        tools, content, delay = [], "", 0.0
        if scenario == "CHAT":
            content = "Two easy vegetarian dinners without mushrooms: a taco bar or pasta. Both fit 45 minutes."
        elif scenario == "CORRECTION":
            content = "For four people, choose gluten-free corn tortillas, black beans, rice, salsa and avocado."
        elif scenario == "SAVE":
            if "save-note" not in results:
                tools = [call("save-note", "write", {"filePath": "dinner-plan.md", "content": note})]
            elif "read-note" not in results:
                tools = [call("read-note", "read", {"filePath": "dinner-plan.md"})]
            else:
                finals["save"] += 1
                content = "Saved and read back dinner-plan.md with all corrected constraints."
        elif scenario == "REPAIR":
            if "write-check" not in results:
                tools = [call("repair-plan", "update_plan", {"objective": "Fix the guest count",
                         "plan": [{"step": "Fix and verify guest count", "status": "in_progress"}]}),
                         call("write-check", "write", {"filePath": "test_dinner.py", "content": check})]
            elif "failing-check" not in results:
                tools = [call("failing-check", "run", {"program": "python", "args": ["-u", "-m", "unittest", "test_dinner"]})]
            elif "fix-check" not in results:
                if "FAILED" not in results["failing-check"]:
                    failures.append("Agent did not receive the actual failed test output")
                steering = [m for m in messages if m["role"] == "user" and
                            isinstance(m.get("content"), str) and m["content"].startswith("STEER:")]
                if len(steering) != 1:
                    failures.append("Mid-tool steering missing or duplicated")
                tools = [call("fix-check", "edit", {"filePath": "test_dinner.py", "oldString": "SEATS = 3", "newString": "SEATS = 4"})]
            elif "passing-check" not in results:
                tools = [call("passing-check", "run", {"program": "python", "args": ["-u", "-m", "unittest", "test_dinner"]})]
            elif "finish-plan" not in results:
                if "OK" not in results["passing-check"]:
                    failures.append("Agent did not receive verification success")
                tools = [call("finish-plan", "update_plan", {"plan": [{"step": "Fix and verify guest count", "status": "completed"}]})]
            else:
                content = "Fixed the guest count to four; the check passed and dinner-plan.md was preserved."
        elif scenario == "RECAP":
            if "passing-check" not in results:
                failures.append("Queued follow-up lost tool history")
            content = "Recap: four people, vegetarian, no mushrooms, gluten-free, 45 minutes; the guest-count check passed."
        elif scenario == "SLOW":
            content, delay = "Partial response.", 0.8
        elif scenario == "NEW":
            content = "Fresh response after Stop."
        elif scenario == "OTHER":
            content = "Independent chat response."
        else:
            failures.append("Unexpected request scenario")
            content = "Unexpected scenario."
        fragments = [{"choices": [{"delta": {"content": content}, "finish_reason": None}]}] if content else []
        if tools:
            # Tool arguments arrive in separate SSE frames, as on a real provider.
            for i, tool in enumerate(tools):
                args = tool["function"]["arguments"]
                cut = len(args) // 2
                start = {**tool, "index": i, "function": {**tool["function"], "arguments": args[:cut]}}
                fragments.append({"choices": [{"delta": {"tool_calls": [start]}, "finish_reason": None}]})
                fragments.append({"choices": [{"delta": {"tool_calls": [{"index": i,
                    "function": {"arguments": args[cut:]}}]}, "finish_reason": None}]})
        ending = [{"choices": [{"delta": {"content": " Late tail."} if delay else {},
                    "finish_reason": "tool_calls" if tools else "stop"}]},
                  {"choices": [], "usage": {"prompt_tokens": 300, "completion_tokens": 40, "total_tokens": 340}}]
        wire = lambda rows: "".join("data: " + json.dumps(row) + "\n\n" for row in rows).encode()
        first, last = wire(fragments), wire(ending) + b"data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(first) + len(last)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(first)
            self.wfile.flush()
            time.sleep(delay or 0.02)
            self.wfile.write(last)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass  # Stop intentionally closes the old stream.


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    subprocess.run([sys.executable, str(package/"tests/run_architecture_checks.py"),
                    "conversation_flow_contracts"], cwd=package.parent, env=env, check=True, timeout=180)
    assert not failures, failures
    assert finals["save"] == 1, "Static document verification manufactured an extra model turn"
    assert len(requests) == 16, f"Unexpected request/continuation count: {len(requests)}"
    print("PASS 16 HTTP rounds: casual context, correction, document readback, failed tool recovery, steering, queued follow-up, Stop/resend, background chat and reload")
finally:
    server.shutdown()
    server.server_close()
