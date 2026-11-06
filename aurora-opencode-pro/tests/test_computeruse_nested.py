"""Test the streaming loop against a local scripted provider and disposable windows.

The provider speaks SSE (`data: ...` frames) exactly like a real gateway, so the
test proves the loop decodes sentences while the round is open, then runs the
action the sentence asked for.
"""
import base64
import ctypes
import io
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from PIL import Image

package = Path(__file__).resolve().parents[1]
repo = package.parent
with tempfile.TemporaryDirectory(prefix='aurora-nested-test-') as temporary:
    directory = Path(temporary)
    driver = directory / 'input.exe'
    subprocess.run(['dmd', '-i', '-I' + str(package / 'source'),
        '-I' + str(repo / 'aurora-opencode-core/source'),
        '-I' + str(repo / 'vendor/aurora-d-0.4.5/source'), '-of' + str(driver),
        str(package / 'tests/computeruse_input_test.d'),
        'user32.lib', 'gdi32.lib', 'shell32.lib', 'wininet.lib'], check=True, cwd=directory)
    ctypes.windll.user32.GetForegroundWindow.restype = ctypes.c_void_p
    ctypes.windll.user32.SetForegroundWindow.argtypes = [ctypes.c_void_p]
    previous = ctypes.windll.user32.GetForegroundWindow()
    fixture = subprocess.Popen([sys.executable, str(package / 'tests/computeruse_input_fixture.py'),
        str(directory)], creationflags=subprocess.CREATE_NO_WINDOW)
    server = None
    try:
        deadline = time.monotonic() + 5
        while not (directory / 'state.json').exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        positions = json.loads((directory / 'state.json').read_text(encoding='utf-8'))
        ax, ay = positions['A']['entry']
        bx, by = positions['B']['entry']
        responses = [
            {'action': 'key', 'name': 'alt+tab'},
            {'action': 'click', 'x': bx // 2, 'y': by // 2},
            {'steps': [{'action': 'screen', 'region': {'x': 30, 'y': 90, 'w': 120, 'h': 60}},
                       {'action': 'wait_for_change', 'timeout_ms': 100, 'interval_ms': 50}]},
            {'input_mode': 'virtual', 'steps': [
                {'action': 'click', 'x': ax // 2, 'y': ay // 2},
                {'action': 'type', 'text': 'N'}]},
            'Fixture input verified.',
            {'action': 'focus', 'title': positions['B']['title']},
            'Other window refused.',
            {'action': 'screen', 'region': {'x': 40, 'y': 160, 'w': 100, 'h': 60}},
        ]
        requests = []
        class Provider(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                requests.append(request)
                response = responses[len(requests) - 1]
                events = []
                if isinstance(response, str):
                    events.append({'choices': [{'delta': {'content': response}}]})
                    events.append({'choices': [{'delta': {}, 'finish_reason': 'stop'}]})
                else:
                    events.append({'choices': [{'delta': {
                        'content': 'Fixture screen read; acting now.'}}]})
                    events.append({'choices': [{'delta': {'tool_calls': [
                        {'index': 0, 'id': f'local-{len(requests)}', 'type': 'function',
                         'function': {'name': 'computer',
                                      'arguments': json.dumps(response)}}]}}]})
                    events.append({'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}]})
                body = ''.join('data: ' + json.dumps(event) + '\n\n'
                    for event in events) + 'data: [DONE]\n\n'
                encoded = body.encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        cases = [
            {'action': 'subagent', 'window': positions['A']['title'],
             'task': 'Use fixture A only. Type N; inspect detail when needed.', 'max_steps': 5},
            {'action': 'subagent', 'window': positions['A']['title'], 'frame': 'full',
             'model': 'fixture-explicit-override', 'input_mode': 'virtual',
             'task': 'Use fixture A only.', 'max_steps': 2},
            {'action': 'subagent', 'window': positions['A']['title'], 'frame': 'full',
             'task': 'Inspect a crop.', 'max_steps': 1},
            # The prototype is switch-gated: with the switch off it refuses
            # instead of quietly running a different loop.
            {'action': 'subagent', 'window': positions['A']['title'],
             'task': 'Switch-off refusal.', 'max_steps': 1, 'sentence_loop': False},
        ]
        scenario = directory / 'cases.json'
        scenario.write_text(json.dumps(cases), encoding='utf-8')
        run = subprocess.run([str(driver), str(scenario), str(directory),
            f'http://127.0.0.1:{server.server_port}/v1'], cwd=directory,
            capture_output=True, text=True, encoding='utf-8', timeout=30)
        assert run.returncode == 0, (run.returncode, run.stdout, run.stderr)
        rows = [json.loads(line) for line in run.stdout.splitlines()]
        assert not rows[0]['failed'] and rows[1]['failed'] and rows[2]['failed'], rows
        assert rows[3]['failed'], rows[3]
        assert 'experimental prototype' in rows[3]['output'], rows[3]['output']
        assert 'AURORA_STREAMING_LOOP' in rows[3]['output'], rows[3]['output']
        assert all(r['images'] == 1 for r in rows), 'Loop exit omitted current evidence'
        assert 'model=deepseek-v4.1-flash, input_mode=native' in rows[0]['output'], rows[0]
        assert 'desktop-switching shortcuts' in rows[0]['output']
        assert 'coordinates are outside' in rows[0]['output']
        assert 'Sent native click' in rows[0]['output'], 'Inner mode overrode loop mode'
        assert 'input cannot leave' in rows[1]['output']
        assert 'without verified completion' in rows[2]['output']
        assert len(requests) == 8
        assert all(r.get('stream') is True for r in requests), 'Loop did not request a streamed reply'
        system = requests[0]['messages'][0]['content']
        assert 'ONE short sentence' in system and 'exactly one action' in system, system[:200]
        output = rows[0]['output']
        assert 'sentence 1.1:' in output, output[:400]
        assert output.index('sentence 1.1:') < output.index('step 1 computer:'), \
            'The sentence did not reach the loop before its action'
        assert all(r['model'] == 'deepseek-v4.1-flash' for r in requests[:5] + requests[7:])
        assert all(r['model'] == 'fixture-explicit-override' for r in requests[5:7])
        def images(request):
            return [part['image_url']['url'] for message in request['messages']
                if isinstance(message.get('content'), list) for part in message['content']
                if part.get('type') == 'image_url']
        assert len(images(requests[3])) == 2, 'Requested native crop did not reach next request'
        main = Image.open(io.BytesIO(base64.b64decode(images(requests[0])[0].split(',', 1)[1])))
        assert main.size == (960, 540), 'Default loop frame did not match the advertised half scale'
        crop = Image.open(io.BytesIO(base64.b64decode(images(requests[3])[-1].split(',', 1)[1])))
        assert crop.size == (240, 120), crop.size
        assert len(images(requests[4])) == 1, 'Crop accumulated in later model requests'
        assert 'act-now' not in rows[0]['output']
        state = json.loads((directory / 'state.json').read_text(encoding='utf-8'))
        assert state['A']['text'] == 'N' and state['B']['text'] == '', \
            (state, rows[0]['output'])
        print('PASS: eight local provider rounds; selected/explicit models, native inheritance, target/shortcut refusals, scaled crop delivered once, truthful limit failure, actual fixture typing')
    finally:
        if server:
            server.shutdown()
            server.server_close()
        (directory / 'stop').touch()
        fixture.wait(timeout=5)
        if previous:
            ctypes.windll.user32.SetForegroundWindow(previous)
