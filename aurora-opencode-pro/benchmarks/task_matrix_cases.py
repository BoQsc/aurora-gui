"""Task specifications and independent checks; no fabricated provider decisions."""
from dataclasses import dataclass, field
import hashlib
import http.server
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import threading
import zipfile

from task_matrix_runner import files, json_answer
from task_matrix_project import SPEC, INPUT

HERE = Path(__file__).resolve().parent


def put(workspace, name, text):
    path = workspace / name; path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


class Fixtures(dict):
    def close(self):
        if "server" in self:
            self["server"].shutdown(); self["server"].server_close()


def empty_setup(workspace, private):
    return Fixtures()


def noop(*_):
    return {"passed": True}


@dataclass
class Case:
    name: str
    complexity: str
    prompts: object
    check_turn: object = noop
    setup: object = empty_setup
    audit: object = noop
    readonly: bool = True
    protected: list = field(default_factory=list)
    tool_budget: int = 8
    timeout: int = 300
    outages: int = 0
    truncate: bool = False
    goal: bool = False


def check_short(_, answer, *__):
    assert re.search(r"\bmutable\b", answer, re.I) and "immutable" in answer.lower()
    assert len(answer.split()) <= 65, "Simple explanation overproduced"


def check_thanks(_, answer, *__):
    assert len(answer.split()) <= 30 and "?" not in answer


def check_arithmetic(_, answer, *__):
    assert json_answer(answer) == {"total": "110.77"}


def lookup_setup(w, _):
    put(w, "README.md", "Shipment facts live in records/. Estimates are not arrival confirmations.\n")
    put(w, "archive/old-note.txt", "SH-47 estimated arrival 2026-11-26 17:00. This is an estimate, not actual arrival.\n")
    put(w, "records/shipment-SH47.json", json.dumps({"shipment": "SH-47", "destination": "Riga", "status": "dispatched", "arrival_time": None}))
    return Fixtures()


def check_lookup(_, answer, *__):
    assert json_answer(answer) == {"arrival_time": None, "status": "dispatched", "destination": "Riga", "source": "records/shipment-SH47.json"}


def source_read(w, p, f, history, root):
    assert any(m.get("toolName") in ("read", "grep", "run") for m in history), "Answer was not grounded in a lookup"
    return {"passed": True, "workspaceRead": True}


def style_setup(w, _):
    put(w, "style.css", ".button { padding: 4px; color: black; }\n.button.primary { padding: 8px; color: blue; }\n@media (max-width: 600px) { .button.primary { padding: 6px; } }\n")
    put(w, "notes.txt", "The responsive override is intentional.\n")
    return Fixtures(initial=files(w))


def check_style(_, answer, w, f):
    assert (w / "style.css").read_text() == ".button { padding: 4px; color: black; }\n.button.primary { padding: 12px; color: blue; }\n@media (max-width: 600px) { .button.primary { padding: 6px; } }\n"
    assert set(files(w)) == set(f["initial"]), "A small style edit created unnecessary files"
    assert len(answer.split()) <= 90


def invoice_setup(w, _):
    put(w, "invoice.py", "def total(subtotal, coupon=False):\n    return (subtotal + (0 if subtotal >= 20 else 5)) * (0.9 if coupon else 1)\n")
    put(w, "catalog.json", '{"unchanged":true}\n')
    return Fixtures(initial=files(w))


def invoice_behavior(w, threshold):
    script = f"from invoice import total\nassert abs(total(10, True)-14)<1e-8\nassert total({threshold-1})=={threshold+4}\nassert total({threshold})=={threshold}\nassert abs(total({threshold},True)-{threshold}*.9)<1e-8\nassert abs(total(49,True)-(49*.9+(5 if 49<{threshold} else 0)))<1e-8\n"
    check = subprocess.run([sys.executable, "-B", "-c", script], cwd=w, capture_output=True, text=True, timeout=20)
    assert check.returncode == 0, check.stdout + check.stderr


def check_invoice(_, answer, w, f):
    invoice_behavior(w, 50)


def context_turn(index, answer, w, f):
    if index == 0:
        assert files(w) == f["initial"], "Analysis request changed files"
        assert "50" in answer and re.search("coupon|delivery|shipping", answer, re.I)
    elif index == 1:
        invoice_behavior(w, 50); f["afterEdit"] = files(w)
    elif index == 2:
        assert files(w) == f["afterEdit"], "Answer-only follow-up restarted implementation"
        assert re.search("test|check|verif", answer, re.I), "Verification evidence absent"
    else:
        invoice_behavior(w, 75)


def review_setup(w, _):
    put(w, "review.py", "def lookup(db, name):\n    return db.execute(f\"SELECT id FROM users WHERE name = '{name}'\").fetchall()\n\ndef safe_lookup(db, name):\n    return db.execute('SELECT id FROM users WHERE name = ?', (name,)).fetchall()\n\ndef top(items):\n    items.sort(reverse=True)\n    return items[:3]\n")
    put(w, "SPEC.txt", "lookup accepts untrusted names. top must return the three largest values without changing the caller's list.\n")
    return Fixtures()


def check_review(_, answer, *__):
    assert re.search(r"inject|SQL.*interpol|interpol.*SQL", answer, re.I)
    assert re.search(r"mutat|in.place|caller.*list|sort.*input", answer, re.I)
    assert "review.py" in answer and re.search(r"\b2\b|lookup", answer)
    assert len(answer.split()) < 450, "Two-finding review overproduced"


def diagnosis_setup(w, _):
    put(w, "cost.py", "def cost(hours, rate):\n    return hours * rate\n")
    put(w, "test_cost.py", "import unittest\nfrom cost import cost\nclass CostTests(unittest.TestCase):\n def test_cost(self): self.assertEqual(cost(3,4),13)\n")
    put(w, "SPEC.txt", "The total is exactly hours multiplied by rate, with no fee or rounding.\n")
    return Fixtures()


def check_diagnosis(_, answer, *__):
    value = json_answer(answer)
    assert value["actual"] == 12 and value["required"] == 12 and value["test_expected"] == 13
    assert value["repair"] == "test", "The wrong test assertion caused an unjustified implementation fix"


def check_numerical_review(_, answer, *__):
    assert json_answer(answer) == {"current": "44.10", "required": "49.10", "at_60_with_coupon": "54.00"}


def diagnosis_audit(w, p, f, history, root):
    import ast
    observed = False
    for message in history:
        if message.get("role") != "tool" or message.get("toolName") not in ("run", "verify"):
            continue
        args = json.loads(message.get("toolArgs") or "{}")
        rows = [(args, message.get("content", ""))]
        if message.get("toolName") == "verify":
            rows = [(step["command"], step["output"]) for step in json.loads(message["content"])["steps"]]
        for command, output in rows:
            argv = command.get("args", [])
            invoked = any(argv[i:i + 2] == ["-m", "unittest"] for i in range(len(argv)))
            if "-c" in argv:
                try:
                    source = argv[argv.index("-c") + 1]
                    try:
                        tree = ast.parse(source)
                    except SyntaxError:
                        tree = ast.parse(source.replace("\\n", "\n"))
                    invoked |= any(isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                                   and n.func.attr in ("TextTestRunner", "loadTestsFromName", "main") for n in ast.walk(tree))
                except (ValueError, SyntaxError):
                    pass
            observed |= bool(invoked and "test_cost" in output and "12 != 13" in output
                             and re.search(r"Ran\s+1\s+test", output) and re.search(r"FAILED\s*\(failures=1\)", output))
    assert observed, "Diagnosis did not execute and observe the requested failing unittest"
    return {"passed": True, "failedReproducerCorrectlyExplained": True, "unittestFailureObserved": True}


def research_setup(w, _):
    records = []
    nonce = "DOC-" + hashlib.sha256(str(w).encode()).hexdigest()[:10]
    class Sources(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass
        def do_GET(self):
            records.append(self.path)
            if self.path == "/current" and records.count("/current") <= 2:
                self.send_response(503); self.end_headers(); self.wfile.write(b"Temporary source outage. Retry."); return
            if self.path == "/old":
                self.send_response(302); self.send_header("Location", "/archive"); self.end_headers(); return
            text = (f"Current release {nonce}: page limit 240, retries default enabled. This release supersedes the archived memo."
                    if self.path == "/current" else "Archived memo: page limit 80, retries disabled. Superseded by current release.")
            self.send_response(200); self.send_header("Content-Type", "text/plain"); self.end_headers(); self.wfile.write(text.encode())
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sources)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return Fixtures(server=server, base=f"http://127.0.0.1:{server.server_port}", nonce=nonce, requests=records)


def check_research(_, answer, w, f):
    value = json_answer(answer)
    assert value["release"] == f["nonce"] and value["page_limit"] == 240 and value["retries"] is True
    assert value["outdated_limit"] == 80
    sources = value["sources"]
    current, old, archive = (f["base"] + path for path in ("/current", "/old", "/archive"))
    assert isinstance(sources, list) and len(sources) == len(set(sources)), "Sources must be unique URLs"
    assert current in sources and (old in sources or archive in sources), "Current and archived claims need sources"
    assert set(sources) <= {current, old, archive}, "An unsupported source was cited"
    assert all(url.removeprefix(f["base"]) in f["requests"] for url in sources), "A cited source was not requested"
    assert f["requests"].count("/current") >= 3 and "/archive" in f["requests"], "Sources were not retrieved after failures/redirect"


def check_public_research(_, answer, *__):
    value = json_answer(answer)
    assert value["context_manager_closes_connection"] is False
    assert value["foreign_keys_default_enabled"] is False
    sources = " ".join(value["sources"])
    assert "docs.python.org/3/library/sqlite3.html" in sources and "sqlite.org/foreignkeys.html" in sources


def public_research_audit(w, p, f, history, root):
    arguments = "\n".join(m.get("toolArgs", "") for m in history if m.get("role") == "tool")
    assert "docs.python.org/3/library/sqlite3.html" in arguments and "sqlite.org/foreignkeys.html" in arguments, "Answer cited sources without requesting them"
    assert any(m.get("toolName") == "webfetch" and not m.get("failed") for m in history), "No successful source fetch"
    return {"passed": True, "primarySources": ["https://docs.python.org/3/library/sqlite3.html", "https://www.sqlite.org/foreignkeys.html"]}


WORKER = """import json,os,sys,time
from pathlib import Path
flag=Path(os.environ['TEMP'])/'worker-outage.json'
if not flag.exists():
 flag.write_text('{"exitCode":75}'); print('Temporary worker outage. Retry the same command.',flush=True); sys.exit(75)
time.sleep(1)
source=json.loads(Path(sys.argv[1]).read_text())
target=Path(sys.argv[2]); target.parent.mkdir(parents=True,exist_ok=True)
target.write_text(json.dumps({'items':len(source),'total':sum(r['units'] for r in source)},sort_keys=True))
print('Worker completed',flush=True)
"""

WORKFLOW_CHECKER = """import hashlib,json,zipfile
from pathlib import Path
w=Path(__file__).resolve().parent
assert json.loads((w/'output/result.json').read_text())=={'items':12,'total':78}
with zipfile.ZipFile(w/'out/bundle.zip') as z:
 assert sorted(z.namelist())==['input/catalog.json','output/result.json']
 for name in z.namelist(): assert z.read(name)==(w/name).read_bytes()
m=json.loads((w/'out/manifest.json').read_text())
assert m=={'artifact':'bundle.zip','sha256':hashlib.sha256((w/'out/bundle.zip').read_bytes()).hexdigest(),'completed':True}
print('PASS worker, archive entries/bytes and manifest checksum')
"""


def workflow_setup(w, _):
    put(w, "worker.py", WORKER); put(w, "check_workflow.py", WORKFLOW_CHECKER)
    zipped = io.BytesIO()
    with zipfile.ZipFile(zipped, "w") as archive:
        archive.writestr("catalog.json", json.dumps([{"item": str(i), "units": i} for i in range(1, 13)]))
    payload, requests = zipped.getvalue(), []
    class Download(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass
        def do_GET(self):
            requests.append(self.path)
            if len(requests) == 1:
                self.send_response(503); self.end_headers(); self.wfile.write(b"Temporary download outage"); return
            self.send_response(200); self.send_header("Content-Length", str(len(payload)))
            self.end_headers(); self.wfile.write(payload)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Download)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return Fixtures(server=server, url=f"http://127.0.0.1:{server.server_port}/input.zip",
                    sha=hashlib.sha256(payload).hexdigest(), requests=requests)


def workflow_audit(w, p, f, history, root):
    run = subprocess.run([sys.executable, "-B", "check_workflow.py"], cwd=w, capture_output=True, text=True, timeout=20)
    (root / "independent-final.log").write_text(run.stdout + run.stderr, encoding="utf-8")
    assert run.returncode == 0, run.stdout + run.stderr
    assert (p / "worker-outage.json").exists() and len(f["requests"]) >= 2, "Required tool failures not exercised"
    names = {m.get("toolName") for m in history if m.get("role") == "tool"}
    assert {"download", "archive", "checksum", "data", "environment", "process", "run"} <= names, names
    assert not any(m.get("toolName") == "process" and '"kill"' in m.get("toolArgs", "") for m in history), "Finished workers did not require killing"
    return {"passed": True, "downloadOutages": 1, "workerOutages": 1, "nativeToolKinds": sorted(names)}


def project_setup(w, p):
    put(w, "SPEC.md", SPEC); put(w, "input.json", json.dumps(INPUT, indent=2))
    put(w, "routekit/__init__.py", "def solve(edges,start,end):\n    raise NotImplementedError\n")
    checker = HERE / "task_matrix_project.py"
    put(w, "check_project.py", "import runpy,sys\nfrom pathlib import Path\n" +
        f"sys.argv=[{str(checker)!r},str(Path(__file__).resolve().parent),{str(p)!r}]\nrunpy.run_path({str(checker)!r},run_name='__main__')\n")
    return Fixtures()


def project_audit(w, p, f, history, root):
    assert (p / "checker-outage.json").exists(), "Checker outage was not exercised"
    run = subprocess.run([sys.executable, "-B", str(HERE / "task_matrix_project.py"), str(w), str(p), "--final"],
                         cwd=w, capture_output=True, text=True, timeout=90)
    (root / "independent-final.log").write_text(run.stdout + run.stderr, encoding="utf-8")
    assert run.returncode == 0, run.stdout + run.stderr
    return {"passed": True, **json.loads(run.stdout.splitlines()[-1])}


def all_cases():
    return [
        Case("simple-explanation", "low", lambda f: ["In one short sentence, explain how Python lists differ from tuples."], check_short, tool_budget=0),
        Case("casual-close", "low", lambda f: ["Thanks, that's all for now."], check_thanks, tool_budget=0),
        Case("supplied-arithmetic", "low", lambda f: ["Calculate an invoice: 19 items at 4.75 and 8 at 3.20. Apply a 10% discount only to merchandise, then add 6.50 shipping. Use exact decimal arithmetic and round the final total HALF_UP to cents. Return only JSON {\"total\":\"0.00\"}."], check_arithmetic, tool_budget=2),
        Case("grounded-unknown", "low", lambda f: ["Look up shipment SH-47 in this workspace. An estimated arrival is not evidence it arrived. Return only JSON with arrival_time (null if not recorded), status, destination, and source (workspace-relative authoritative filename). Do not edit files."], check_lookup, lookup_setup, source_read, tool_budget=6),
        Case("small-style-edit", "low", lambda f: ["In style.css change the base .button.primary padding from 8px to 12px. Preserve the responsive override and other rules. Make this small edit and briefly confirm."], check_style, style_setup, readonly=False, protected=["notes.txt"], tool_budget=5),
        Case("boundary-bugfix", "medium", lambda f: ["Fix invoice.total: delivery is 5 below merchandise subtotal 50 and free at 50 or above. A coupon discounts merchandise by 10%, never delivery. Preserve the API and catalog.json; verify boundary and coupon behavior. No dependencies. Finish briefly."], check_invoice, invoice_setup, readonly=False, protected=["catalog.json"], tool_budget=14, outages=2),
        Case("grounded-review", "medium", lambda f: ["Review review.py against SPEC.txt for concrete correctness/security bugs. Report actionable findings with file/line evidence and a reduced example. Do not modify files. The parameterized safe_lookup is intentional. Keep the review focused."], check_review, review_setup, source_read, tool_budget=12),
        Case("wrong-test-diagnosis", "medium", lambda f: ["Diagnose test_cost.py using SPEC.txt and cost.py. Execute the failing unittest reproducer, independently calculate the required result, and identify which side is wrong. Do not edit files. Return only JSON keys actual, required, test_expected (numbers), repair ('test' or 'implementation')."], check_diagnosis, diagnosis_setup, diagnosis_audit, tool_budget=8),
        Case("numerical-review", "medium", lambda f: ["Read invoice.py without changing files. Required rule: delivery costs 5 below merchandise subtotal 50 and is free at 50 or above; a coupon discounts merchandise by 10%, never delivery. Independently calculate the current result for subtotal 49 with coupon, the required result for that input, and the required result at subtotal 60 with coupon. Return only JSON string keys current, required, at_60_with_coupon, each to two decimal places."], check_numerical_review, invoice_setup, source_read, tool_budget=5),
        Case("source-outage-research", "medium", lambda f: [f"Research these two documents: {f['base']}/current and {f['base']}/old . The current source may fail temporarily; retry rather than substituting guesses. Resolve superseded/conflicting claims, follow redirects, and return only JSON keys release, page_limit, retries (boolean), outdated_limit, sources (URLs). Do not edit files."], check_research, research_setup, tool_budget=9, outages=2),
        Case("primary-source-research", "medium", lambda f: ["Check the actual primary documentation at https://docs.python.org/3/library/sqlite3.html and https://www.sqlite.org/foreignkeys.html . Does Python's connection context manager close the connection? Are SQLite foreign keys enabled by default according to those docs? Return only JSON keys context_manager_closes_connection, foreign_keys_default_enabled (booleans), sources (both supporting URLs). Fetch the sources and distinguish transaction management from closing. Do not edit files."], check_public_research, audit=public_research_audit, tool_budget=8),
        Case("conversation-scope", "medium", lambda f: [
            "Analyze invoice.py. Delivery should cost 5 below subtotal 50, free at 50 or above; coupons discount merchandise only. Identify defects and proposed fix. Do not edit.",
            "Implement that fix and verify it. Preserve the API and catalog.json. No dependencies. Keep the reply brief.",
            "What changed, and what verification supports it? Answer only without changing files or restarting work.",
            "Now change the free-delivery threshold to 75. Preserve the coupon rule and API. Verify the new boundary and finish briefly."], context_turn, invoice_setup,
            readonly=False, protected=["catalog.json"], tool_budget=28, timeout=600),
        Case("native-tool-workflow", "hard", lambda f: [f"Prepare a small artifact handoff in this isolated workspace. Inspect Python availability with environment. Download {f['url']} to input.zip, verifying publisher SHA256 {f['sha']}, and extract catalog.json to input/. Use native download/archive/checksum/data/environment tools. Start python worker.py input/catalog.json output/result.json with run background=true; use process wait/output to observe exit. The download and worker can each fail transiently; retry the same operation. Build out/bundle.zip containing exactly input/catalog.json and output/result.json with those relative paths. Use data to write out/manifest.json with artifact='bundle.zip', its actual sha256, and completed=true. Validate the archive. Leave no live worker. Preserve worker.py and check_workflow.py. Finally run python -B check_workflow.py with check='tests' and inputs naming the checker, extracted input and three output artifacts. No questions, dependencies or self-maintenance. Finish with output path and checks."], setup=workflow_setup, audit=workflow_audit,
            readonly=False, protected=["worker.py", "check_workflow.py"], tool_budget=32, timeout=600),
        Case("routing-project-goal", "hard", lambda f: ["Complete the entire routekit project specified in SPEC.md, including actual routes.json, routes.csv, routes.sqlite, README usage and tests. Read the specification and existing stub, implement and verify the behavior, recover from transient provider/checker failures, then call goal_complete with actual successful evidence. Make routine choices yourself; no Continue or approval requests. Work only in this isolated project."], setup=project_setup, audit=project_audit,
            readonly=False, protected=["input.json", "check_project.py", "SPEC.md"], tool_budget=55, timeout=1000, outages=3, truncate=True, goal=True),
    ]
