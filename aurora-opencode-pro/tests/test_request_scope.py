"""Replay paused old work -> independent action through the shipping app.

The local provider is deterministic: this tests task routing, real tools,
completion and persistence, not a hosted model's intelligence. All state and
files are isolated. --expect-regression records the old executable's failure.
"""
import argparse
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
parser = argparse.ArgumentParser()
parser.add_argument('--executable', type=Path, default=package/'aurora-opencode-pro.exe')
parser.add_argument('--expect-regression', action='store_true')
args = parser.parse_args()
requests, scope_errors = [], []

def tool(identity, name, value):
    return {'index': 0, 'id': identity, 'type': 'function',
            'function': {'name': name, 'arguments': json.dumps(value)}}

class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        data = b'{"data":[{"id":"scope-fixture"}]}'
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(request)
        messages = request['messages']
        humans = [m['content'] for m in messages if m['role'] == 'user' and isinstance(m.get('content'), str)]
        new = any(p.startswith('Fix fullscreen') for p in humans)
        results = {m['tool_call_id']: m['content'] for m in messages if m['role'] == 'tool'}
        scope = '\n'.join(m['content'] for m in messages if m['role'] == 'system' and isinstance(m.get('content'), str))
        call, content = None, ''
        if len(requests) > 16:
            content = 'FIXTURE_ABORT'
        elif not new and 'old-plan' not in results:
            call = tool('old-plan', 'update_plan', {'objective': 'Match the trading panel to its mockup with a fresh render',
                'constraints': ['1:1 mockup and trading regression checks'],
                'plan': [{'id': 'exact', 'step': 'Match the trading mockup', 'status': 'in_progress'}]})
        elif not new and 'missing-reference' not in results:
            call = tool('missing-reference', 'request_input', {
                'reason': 'The customer-owned reference image is not supplied', 'required_fact': 'The reference image',
                'question': 'Which reference image should the panel match?', 'checked': ['Workspace files'],
                'independent_work_complete': True, 'blocked_steps': ['exact']})
        elif not new:
            content = 'Which reference image should the panel match?'
        elif 'Answer only:' in humans[-1]:
            content = 'The fullscreen note was saved and read back. The trading goal remains paused.'
        elif humans[-1].lower() == 'continue':
            content = 'The fullscreen request is complete.'
        else:
            # Inspect the current task, excluding explicitly quoted background.
            current = scope.split('Background task')[0]
            if 'new-plan' not in results and 'Objective: Fix fullscreen' not in current:
                scope_errors.append('Fullscreen request retained the old task objective')
            if '1. [in_progress] exact:' in current:
                scope_errors.append('Fullscreen request retained the trading checklist')
            if 'new-plan' not in results:
                call = tool('new-plan', 'update_plan', {'objective': 'Save and read back the fullscreen repair note',
                    'plan': [{'id': 'note', 'step': 'Save and read back the fullscreen note', 'kind': 'edit',
                              'status': 'in_progress'}]})
            elif 'save-note' not in results:
                call = tool('save-note', 'write', {'filePath': 'fullscreen.md',
                    'content': 'Scope: fullscreen switching in world and map selector.\nLive GUI validation is separate from headless helper tests.\n'})
            elif 'read-note' not in results:
                call = tool('read-note', 'read', {'filePath': 'fullscreen.md'})
            elif 'close-note' not in results:
                call = tool('close-note', 'update_plan', {'plan_mode': 'patch',
                    'plan': [{'id': 'note', 'status': 'completed', 'evidence': ['save-note', 'read-note']}]})
            else:
                content = 'Saved and read back fullscreen.md. Live GUI validation remains separate.'
        delta = {'tool_calls': [call]} if call else {'content': content}
        data = ('data: '+json.dumps({'choices': [{'delta': delta, 'finish_reason': None}]})+'\n\n'+
                'data: '+json.dumps({'choices': [{'delta': {}, 'finish_reason': 'tool_calls' if call else 'stop'}]})+
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
directory = Path(tempfile.mkdtemp(prefix='request-scope-', dir=package/'build'))
workspace = directory/'workspace'
workspace.mkdir()
state = directory/'appdata/Aurora OpenCode'
state.mkdir(parents=True)
(state/'settings.json').write_text(json.dumps({
    'baseUrl': f'http://127.0.0.1:{server.server_port}/v1', 'apiKey': 'fixture', 'model': 'scope-fixture',
    'workspace': str(workspace), 'toolsEnabled': True, 'quickTitle': False, 'composerSuggestion': False,
    'autoGoalFromFirstMessage': False, 'legacyTools': False,
}), encoding='utf-8')
prompts = ['/goal Match the trading panel to the customer mockup.', '/goal pause',
           'Fix fullscreen switching globally. For this replay, save fullscreen.md explaining its scope and read it back; do not modify the game.',
           'Answer only: what was delivered and is the trading goal still paused?', 'continue', 'exit']
started = time.monotonic()
try:
    process = subprocess.run([str(args.executable.resolve()), '--headless-loop-json'], input='\n'.join(prompts)+'\n',
        cwd=workspace, env=dict(os.environ, APPDATA=str(directory/'appdata'), AURORA_STRICT_PLAN='0'),
        capture_output=True, text=True, encoding='utf-8', timeout=60)
    (directory/'process.log').write_text(process.stdout+process.stderr, encoding='utf-8')
    (directory/'requests.json').write_text(json.dumps(requests, indent=2), encoding='utf-8')
    replies = [json.loads(line) for line in process.stdout.splitlines() if line.startswith('{"')]
    index = json.loads((state/'threads.index.json').read_text(encoding='utf-8'))
    session = next(s for s in index['sessions'] if s.get('goal'))
    errors = list(dict.fromkeys(scope_errors))
    if process.returncode:
        errors.append(f'Process exited {process.returncode}')
    if session.get('goalStatus') != 'paused':
        errors.append('Trading goal did not remain paused')
    if any(row['id'] == 'exact' for row in session.get('taskSteps', [])):
        errors.append('Old trading checklist still owns the task')
    if not (workspace/'fullscreen.md').exists():
        errors.append('Requested file was not delivered')
    if session.get('taskStatus') != 'completed':
        errors.append('Current task did not complete')
    if any(reply.get('error') or reply.get('turnStatus') != 'completed' for reply in replies[2:]):
        errors.append('A later request failed or retained a runtime error')
    if len(requests) != 10:
        errors.append(f'Expected 10 provider requests, observed {len(requests)}')
    result = {'status': 'regression-reproduced' if errors else 'passed', 'errors': errors,
        'binarySha256': hashlib.sha256(args.executable.read_bytes()).hexdigest(),
        'seconds': time.monotonic()-started, 'requests': len(requests), 'replies': replies,
        'objective': session.get('objective'), 'taskStatus': session.get('taskStatus'),
        'goalStatus': session.get('goalStatus'), 'archivedTasks': len(session.get('taskArchive', []))}
    (directory/'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, indent=2))
    print('ARTIFACTS', directory)
    if args.expect_regression:
        assert scope_errors, 'Baseline no longer reproduces stale ownership'
    else:
        assert not errors, errors
finally:
    server.shutdown()
    server.server_close()
