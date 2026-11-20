"""Drive the shipping executable through the real turn pipeline for intent behaviour.

The app is driven through its own session-server protocol: create one session,
submit each prompt, and wait for that turn's completion event. A deterministic
local provider answers with plain text, so no filesystem tool host is needed and
the check runs in restricted launchers as well as a normal shell.

The evidence is what the app actually sent to the provider (the durable task
state and the per-request guidance) and what it persisted in its own journal.

Scenarios:

* complaint   "the tray icon is too small" starts work rather than conversation
* correction  a later complaint amends that work instead of starting a task
* hold        "hold off for now" withholds the work instead of continuing it

Usage:
    python tests/verify_intent_live.py --executable aurora-opencode-pro.exe
    python tests/verify_intent_live.py --dump
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time

package = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--executable', type=Path, default=package / 'aurora-opencode-pro.exe')
parser.add_argument('--dump', action='store_true', help='Print the requests and state shape and exit')
args = parser.parse_args()


class Provider(http.server.BaseHTTPRequestHandler):
    captured = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        data = b'{"data":[{"id":"intent-fixture"}]}'
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        Provider.captured.append(body)
        data = ('data: ' + json.dumps({'choices': [{'delta': {'content': 'Reported as applied.'},
                                                    'finish_reason': None}]}) + '\n\n' +
                'data: ' + json.dumps({'choices': [{'delta': {}, 'finish_reason': 'stop'}]}) +
                '\n\ndata: [DONE]\n\n').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
endpoint = f'http://127.0.0.1:{server.server_port}/v1'


def system_text(body):
    return '\n'.join(m['content'] for m in body.get('messages', [])
                     if m.get('role') == 'system' and isinstance(m.get('content'), str))


def latest_human(body):
    humans = [m['content'] for m in body.get('messages', [])
              if m.get('role') == 'user' and isinstance(m.get('content'), str)]
    return humans[-1] if humans else ''


def persisted(state):
    journal = state / 'runtime-events.jsonl'
    latest = {}
    if not journal.is_file():
        return latest
    for line in journal.read_text(encoding='utf-8', errors='replace').splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get('type') == 'thread.updated' and isinstance(event.get('payload'), dict):
            latest = event['payload']
    return latest


class SessionServer:
    """The app's own JSONL session API, one submit per turn."""

    def __init__(self, state, workspace, log):
        environment = dict(os.environ, APPDATA=str(state.parent), AURORA_STRICT_PLAN='0')
        self.process = subprocess.Popen(
            [str(args.executable.resolve()), '--session-server',
             '--state-dir', str(state), '--workspace', str(workspace)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True,
            encoding='utf-8', errors='replace', env=environment)
        self.events = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.process.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self.events.put(json.loads(line))
            except ValueError:
                self.events.put({'type': 'text', 'line': line})

    def send(self, operation):
        self.process.stdin.write(json.dumps(operation) + '\n')
        self.process.stdin.flush()

    def wait_for(self, kind, request_id=None, timeout=90):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                event = self.events.get(timeout=max(0.1, deadline - time.monotonic()))
            except queue.Empty:
                break
            if event.get('type') != kind:
                continue
            if request_id is not None and event.get('requestId') != request_id:
                continue
            return event
        return {}

    def close(self):
        try:
            self.send({'type': 'shutdown'})
            self.wait_for('bye', timeout=10)
        except (OSError, ValueError):
            pass
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=15)
        try:
            self.process.stdin.close()
        except OSError:
            pass


def run(prompts):
    """One isolated profile; the prompts are submitted in order to one session."""
    directory = Path(tempfile.mkdtemp(prefix='intent-live-', dir=package / 'build'))
    workspace = directory / 'workspace'
    workspace.mkdir()
    state = directory / 'appdata/Aurora OpenCode'
    state.mkdir(parents=True)
    settings = {
        'baseUrl': endpoint, 'apiKey': 'fixture', 'model': 'intent-fixture',
        'workspace': str(workspace), 'toolsEnabled': True, 'quickTitle': False,
        'composerSuggestion': False, 'settingsVersion': 3,
        'autoGoalFromFirstMessage': False, 'legacyTools': False,
    }
    (state / 'settings.json').write_text(json.dumps(settings), encoding='utf-8')
    start = len(Provider.captured)
    log = (directory / 'process.log').open('w', encoding='utf-8', errors='replace')
    app = SessionServer(state, workspace, log)
    turns = {}
    completed = 0
    try:
        app.wait_for('ready', timeout=60)
        app.send({'type': 'create', 'id': 'intent', 'title': 'intent fixture',
                  'model': 'intent-fixture', 'tools': True, 'workspace': str(workspace)})
        app.wait_for('created', timeout=30)
        for index, prompt in enumerate(prompts, start=1):
            request_id = f'r{index}'
            before = len(Provider.captured)
            app.send({'type': 'submit', 'id': 'intent', 'requestId': request_id, 'text': prompt})
            event = app.wait_for('turn.completed', request_id=request_id, timeout=90)
            if event.get('type') == 'turn.completed':
                completed += 1
            turns[prompt] = Provider.captured[before:]
    finally:
        app.close()
        log.close()
    bodies = Provider.captured[start:]
    (directory / 'requests.json').write_text(json.dumps(bodies, indent=2), encoding='utf-8')
    return dict(directory=directory, state=state, bodies=bodies, turns=turns,
                session=persisted(state), completed=completed, accepted=len(turns))


def check(name, prompts, assertions):
    result = run(prompts)
    session = result['session']
    contract = session.get('taskContract') or {}
    detail = dict(name=name, completed=result['completed'],
                  requests={p: len(t) for p, t in result['turns'].items()},
                  objective=session.get('objective'), taskStatus=session.get('taskStatus'),
                  currentIntent=contract.get('currentIntent'), intent=contract.get('intent'),
                  archive=len(session.get('taskArchive') or []),
                  artifacts=str(result['directory']))
    failures = [label for label, predicate in assertions(result, session) if not predicate]
    if result['completed'] < len(prompts):
        failures.insert(0, f"only {result['completed']}/{len(prompts)} turns completed")
    return detail, failures


def main():
    if args.dump:
        result = run(['the tray icon is too small'])
        print('SESSION', json.dumps(result['session'], indent=2)[:1500])
        for prompt, turns in result['turns'].items():
            print('PROMPT', prompt, 'REQUESTS', len(turns))
            if turns:
                print('SYSTEM', system_text(turns[0])[:1200])
        return 0

    scenarios = [
        ('complaint', ['the tray icon is too small'], lambda r, s: [
            ('the complaint did not become the task objective',
             (s.get('objective') or '').lower().startswith('the tray icon is too small')),
            ('the complaint was filed as conversation rather than work',
             (s.get('taskContract') or {}).get('intent') in ('implementation', 'continuation')),
            ('the app told the model the complaint asks for an explanation',
             not any('asks for an explanation' in system_text(b)
                     for b in r['turns']['the tray icon is too small'])),
            ('the app did not authorize the change',
             any('authorized implementation work' in system_text(b)
                 for b in r['turns']['the tray icon is too small'])),
        ]),
        ('correction', ['add a copy button', 'it is still too small'], lambda r, s: [
            ('the correction started a new task instead of amending',
             (s.get('objective') or '').lower().startswith('add a copy button')),
            ('the correction archived the work in progress', len(s.get('taskArchive') or []) == 0),
            ('the correction was not recorded as continuation',
             (s.get('taskContract') or {}).get('currentIntent') == 'continuation'),
            ('the app did not tell the model to adopt the correction',
             any('continues or corrects the current work' in system_text(b)
                 for b in r['turns']['it is still too small'])),
        ]),
        ('hold', ['add a copy button', 'hold off for now'], lambda r, s: [
            ('the hold was read as work to continue',
             not any('continues or corrects the current work' in system_text(b)
                     for b in r['turns']['hold off for now'])),
            ('the hold became a new task objective',
             (s.get('objective') or '').lower().startswith('add a copy button')),
            ('the hold did not tell the model to stop',
             not r['turns']['hold off for now'] or
             any('hold the work' in system_text(b) for b in r['turns']['hold off for now'])),
        ]),
    ]
    report, errors = [], []
    for name, prompts, assertions in scenarios:
        detail, failures = check(name, prompts, assertions)
        detail['failures'] = failures
        report.append(detail)
        errors += [f'{name}: {failure}' for failure in failures]
    print(json.dumps(dict(binarySha256=hashlib.sha256(args.executable.read_bytes()).hexdigest(),
                          scenarios=report, errors=errors), indent=2))
    if errors:
        print('FAIL intent behaviour on the shipping executable')
        return 1
    print('PASS intent behaviour through the shipping executable')
    return 0


try:
    raise SystemExit(main())
finally:
    server.shutdown()
    server.server_close()
