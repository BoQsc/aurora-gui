"""Long-horizon intent check: does the app keep owning the right work over many turns?

The shipping executable is driven through its own session-server protocol: one
session, prompts submitted in order, each turn awaited. A deterministic provider
answers with plain text, so no filesystem tool host is involved.

Each scenario is a small long-running conversation (a goal, drift, corrections,
scope growth, a hold, a new task). After every turn the harness reads the durable
task state the app persisted and checks four things: who owns the objective, what
the turn was read as, whether work was archived, and what the app told the model.

Usage:
    python tests/verify_intent_longhorizon.py --executable aurora-opencode-pro.exe
    python tests/verify_intent_longhorizon.py --dump
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
parser.add_argument('--dump', action='store_true', help='Print the observed sequence for every scenario')
args = parser.parse_args()


class Provider(http.server.BaseHTTPRequestHandler):
    captured = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        data = b'{"data":[{"id":"longhorizon-fixture"}]}'
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


def run_sequence(prompts, auto_goal):
    directory = Path(tempfile.mkdtemp(prefix='intent-long-', dir=package / 'build'))
    workspace = directory / 'workspace'
    workspace.mkdir()
    state = directory / 'appdata/Aurora OpenCode'
    state.mkdir(parents=True)
    settings = {
        'baseUrl': endpoint, 'apiKey': 'fixture', 'model': 'longhorizon-fixture',
        'workspace': str(workspace), 'toolsEnabled': True, 'quickTitle': False,
        'composerSuggestion': False, 'settingsVersion': 3,
        'autoGoalFromFirstMessage': bool(auto_goal), 'legacyTools': False,
    }
    (state / 'settings.json').write_text(json.dumps(settings), encoding='utf-8')
    log = (directory / 'process.log').open('w', encoding='utf-8', errors='replace')
    app = SessionServer(state, workspace, log)
    snapshots, turns, completed = [], [], 0
    try:
        app.wait_for('ready', timeout=60)
        app.send({'type': 'create', 'id': 'long', 'title': 'long horizon fixture',
                  'model': 'longhorizon-fixture', 'tools': True, 'workspace': str(workspace)})
        app.wait_for('created', timeout=30)
        for index, prompt in enumerate(prompts, start=1):
            request_id = f'r{index}'
            before = len(Provider.captured)
            app.send({'type': 'submit', 'id': 'long', 'requestId': request_id, 'text': prompt})
            event = app.wait_for('turn.completed', request_id=request_id, timeout=90)
            if event.get('type') == 'turn.completed':
                completed += 1
            snapshots.append(persisted(state))
            turns.append(Provider.captured[before:])
    finally:
        app.close()
        log.close()
    return dict(directory=directory, snapshots=snapshots, turns=turns, completed=completed)


def object_value(spec, previous, prompt):
    if spec == 'self':
        return prompt
    if spec == 'same':
        return previous
    if isinstance(spec, str) and spec.startswith('literal:'):
        return spec[len('literal:'):]
    return spec


def check(name, scenario):
    prompts = [turn['prompt'] for turn in scenario['turns']]
    result = run_sequence(prompts, scenario.get('auto_goal', False))
    snapshots, turns = result['snapshots'], result['turns']
    failures = []
    if result['completed'] < len(prompts):
        failures.append(f"only {result['completed']}/{len(prompts)} turns completed")
    first_objective = snapshots[0].get('objective') if snapshots else ''
    sequence = []
    for index, turn in enumerate(scenario['turns']):
        snapshot = snapshots[index] if index < len(snapshots) else {}
        contract = snapshot.get('taskContract') or {}
        bodies = turns[index] if index < len(turns) else []
        previous = object_value(turn['objective'], first_objective, prompts[0])
        current = snapshot.get('objective') or ''
        sequence.append(dict(turn=index + 1, prompt=prompts[index][:38],
                             intent=contract.get('currentIntent'),
                             objective='same' if current == (first_objective or '') and index else 'changed',
                             archive=len(snapshot.get('taskArchive') or []),
                             goal=snapshot.get('goalStatus', '')))
        if current != (previous or ''):
            failures.append(f"turn {index + 1} \"{prompts[index][:34]}\": objective is "
                            f"{current!r}, expected {previous!r}")
        wanted = turn.get('intent')
        if wanted and contract.get('currentIntent') not in wanted:
            failures.append(f"turn {index + 1} \"{prompts[index][:34]}\": read as "
                            f"{contract.get('currentIntent')!r}, expected one of {sorted(wanted)}")
        if 'archive' in turn and len(snapshot.get('taskArchive') or []) != turn['archive']:
            failures.append(f"turn {index + 1} \"{prompts[index][:34]}\": archive "
                            f"{len(snapshot.get('taskArchive') or [])}, expected {turn['archive']}")
        if 'guidance' in turn and not any(turn['guidance'] in system_text(body) for body in bodies):
            failures.append(f"turn {index + 1} \"{prompts[index][:34]}\": guidance "
                            f"{turn['guidance']!r} was not sent")
        if 'goal' in turn and snapshot.get('goalStatus', '') not in turn['goal']:
            failures.append(f"turn {index + 1} \"{prompts[index][:34]}\": goal status "
                            f"{snapshot.get('goalStatus', '')!r}, expected one of {sorted(turn['goal'])}")
    return dict(name=name, sequence=sequence, failures=failures,
                artifacts=str(result['directory']))


SCENARIOS = [
    # A side question must not take the objective, and a short resume either
    # continues the active task or answers normally; what it must never do is
    # start a task named after the side question.
    dict(name='question-then-continue', turns=[
        dict(prompt='Deliver a CSV export with a verified round trip',
             objective='self', intent={'implementation'}, archive=0),
        dict(prompt='what does the rebuild tool do?',
             objective='same', intent={'clarification'}, archive=0),
        dict(prompt='continue',
             objective='same', intent={'continuation', 'conversation'}, archive=0),
    ]),
    dict(name='correction-drift', turns=[
        dict(prompt='Add a settings page with a theme picker',
             objective='self', intent={'implementation'}),
        # A refinement amends the settings page; it must not archive it.
        dict(prompt='make the font bigger',
             objective='same', intent={'implementation', 'continuation'}),
        dict(prompt='no, the other label',
             objective='same', intent={'continuation'}, guidance='continues or corrects'),
        dict(prompt='i meant the dark theme',
             objective='same', intent={'continuation'}),
    ]),
    dict(name='repeated-failure', turns=[
        dict(prompt='Fix the flicker when the panel opens',
             objective='self', intent={'implementation'}),
        dict(prompt='still flickering', objective='same', intent={'continuation'}),
        dict(prompt='still flickering', objective='same', intent={'continuation'}),
        dict(prompt='why is it still flickering?', objective='same', intent={'diagnosis'}),
    ]),
    dict(name='scope-amendment', turns=[
        dict(prompt='Build the importer for CSV files',
             objective='self', intent={'implementation'}),
        dict(prompt='also handle gzipped files', objective='same', intent={'continuation'}),
        dict(prompt='additionally reject empty rows', objective='same', intent={'continuation'}),
    ]),
    dict(name='new-task-separation', turns=[
        dict(prompt='Build the importer for CSV files',
             objective='self', intent={'implementation'}),
        dict(prompt='new task: build the exporter for XLSX',
             objective='literal:new task: build the exporter for XLSX',
             intent={'implementation'}, archive=1),
    ]),
    dict(name='hold-resume', turns=[
        dict(prompt='Build the importer for CSV files',
             objective='self', intent={'implementation'}),
        dict(prompt='hold off for now', objective='same', intent={'conversation'},
             guidance='hold the work'),
        dict(prompt='ok go ahead', objective='same', intent={'continuation'}, archive=0),
    ]),
    dict(name='delegation', turns=[
        dict(prompt='Build the importer for CSV files',
             objective='self', intent={'implementation'}),
        dict(prompt='you decide the column order', objective='same', intent={'continuation'}),
        dict(prompt='up to you', objective='same', intent={'continuation'}),
    ]),
    dict(name='mixed-long', auto_goal=True, turns=[
        dict(prompt='Migrate the exporter to the new schema with a verified audit trail',
             objective='self', intent={'implementation'}),
        dict(prompt='what is left?', objective='same', intent={'clarification'}),
        dict(prompt='keep the public API stable', objective='same',
             intent={'continuation', 'conversation'}),
        dict(prompt='why did the last check fail?', objective='same', intent={'diagnosis'}),
        dict(prompt='no, the second column is wrong', objective='same',
             intent={'continuation'}, guidance='continues or corrects'),
        dict(prompt='go ahead', objective='same', intent={'continuation'}),
        dict(prompt='continue', objective='same', intent={'continuation'}),
        dict(prompt='new task: write the migration notes',
             objective='literal:new task: write the migration notes',
             intent={'implementation'}, archive=1),
    ]),
]


def main():
    report, errors = [], []
    for scenario in SCENARIOS:
        result = check(scenario['name'], scenario)
        report.append(result)
        errors += [f"{scenario['name']}: {failure}" for failure in result['failures']]
    if args.dump:
        for result in report:
            print('==', result['name'])
            for row in result['sequence']:
                print(f"  {row['turn']}. {row['prompt']:<40} intent={row['intent']:<14} "
                      f"obj={row['objective']:<8} archive={row['archive']} goal={row['goal']}")
    else:
        print(json.dumps(dict(binarySha256=hashlib.sha256(args.executable.read_bytes()).hexdigest(),
                              scenarios=report, errors=errors), indent=2))
    deltas = [(row['turn'], row['prompt'], row['intent'], row['goal'])
              for result in report for row in result['sequence']
              if row['goal'] in ('active', 'paused') and row['intent'] in ('conversation', 'clarification')
              and row['turn'] > 1]
    if errors:
        print('FAIL long-horizon intent behaviour')
        return 1
    print('PASS long-horizon intent behaviour through the shipping executable')
    return 0


try:
    raise SystemExit(main())
finally:
    server.shutdown()
    server.server_close()
