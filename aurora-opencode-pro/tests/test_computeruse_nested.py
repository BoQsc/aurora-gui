"""Test real nested dispatch against a local scripted provider and disposable windows."""
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
                message = {'role': 'assistant', 'content': response if isinstance(response, str) else None}
                if isinstance(response, dict):
                    message['tool_calls'] = [{'id': f'local-{len(requests)}', 'type': 'function',
                        'function': {'name': 'computer', 'arguments': json.dumps(response)}}]
                body = json.dumps({'choices': [{'message': message}]}).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
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
        ]
        scenario = directory / 'cases.json'
        scenario.write_text(json.dumps(cases), encoding='utf-8')
        run = subprocess.run([str(driver), str(scenario), str(directory),
            f'http://127.0.0.1:{server.server_port}/v1'], cwd=directory,
            capture_output=True, text=True, encoding='utf-8', timeout=30, check=True)
        rows = [json.loads(line) for line in run.stdout.splitlines()]
        assert not rows[0]['failed'] and rows[1]['failed'] and rows[2]['failed'], rows
        assert all(r['images'] == 1 for r in rows), 'Loop exit omitted current evidence'
        assert 'model=deepseek-v4.1-flash, input_mode=native' in rows[0]['output'], rows[0]
        assert 'desktop-switching shortcuts' in rows[0]['output']
        assert 'coordinates are outside' in rows[0]['output']
        assert 'Sent native click' in rows[0]['output'], 'Inner mode overrode loop mode'
        assert 'input cannot leave' in rows[1]['output']
        assert 'without verified completion' in rows[2]['output']
        assert len(requests) == 8
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
        assert state['A']['text'] == 'N' and state['B']['text'] == '', state
        print('PASS: eight local provider rounds; selected/explicit models, native inheritance, target/shortcut refusals, scaled crop delivered once, truthful limit failure, actual fixture typing')
    finally:
        if server:
            server.shutdown()
            server.server_close()
        (directory / 'stop').touch()
        fixture.wait(timeout=5)
        if previous:
            ctypes.windll.user32.SetForegroundWindow(previous)
