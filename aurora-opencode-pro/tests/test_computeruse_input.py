"""Exercise production Win32 input against two isolated fixture windows."""
import ctypes
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

package = Path(__file__).resolve().parents[1]
repo = package.parent
with tempfile.TemporaryDirectory(prefix='aurora-input-test-') as temporary:
    directory = Path(temporary)
    driver = directory / 'input-test.exe'
    subprocess.run(['dmd', '-i', '-I' + str(package / 'source'),
        '-I' + str(repo / 'aurora-opencode-core/source'),
        '-I' + str(repo / 'vendor/aurora-d-0.4.5/source'), '-of' + str(driver),
        str(package / 'tests/computeruse_input_test.d'),
        'user32.lib', 'gdi32.lib', 'shell32.lib', 'wininet.lib'], check=True)
    ctypes.windll.user32.GetForegroundWindow.restype = ctypes.c_void_p
    ctypes.windll.user32.SetForegroundWindow.argtypes = [ctypes.c_void_p]
    previous = ctypes.windll.user32.GetForegroundWindow()
    fixture = subprocess.Popen([sys.executable, str(package / 'tests/computeruse_input_fixture.py'),
        str(directory)], creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        deadline = time.monotonic() + 5
        while not (directory / 'state.json').exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        positions = json.loads((directory / 'state.json').read_text(encoding='utf-8'))
        def click(name, target='entry', **extra):
            x, y = positions[name][target]
            return {'action': 'click', 'x': x, 'y': y, 'screenshot': False, **extra}
        cases = [click('A'), {'action': 'key_down', 'name': 'shift', 'screenshot': False},
            click('A', input_mode='native'), {'action': 'type', 'text': 'a', 'screenshot': False},
            click('B', input_mode='native'),
            {'action': 'type', 'text': 'b', 'screenshot': False},
            {'action': 'type', 'text': 'A', 'window': positions['A']['title'], 'screenshot': False},
            click('B'), {'action': 'type', 'text': 'B', 'screenshot': False},
            click('A', 'button'),
            click('A', 'button', input_mode='native'),
            {'action': 'click', 'window': 'Aurora Input Driver Self', 'x': 860, 'y': 210, 'screenshot': False},
            {'action': 'click', 'x': -100, 'y': -100, 'screenshot': False},
            {'input_mode': 'invalid', 'action': 'click', 'x': 50, 'y': 50},
            {'steps': [{'action': 'click', 'x': -100, 'y': -100},
                       {'action': 'type', 'text': 'MUST-NOT-BE-SENT'}]},
            click('B'), {'action': 'screen'}]
        scenario = directory / 'cases.json'
        scenario.write_text(json.dumps(cases), encoding='utf-8')
        result = subprocess.run([str(driver), str(scenario)], capture_output=True,
            text=True, encoding='utf-8', timeout=20)
        assert result.returncode == 0, result.stderr
        outputs = [json.loads(line) for line in result.stdout.splitlines()]
        assert all(not row['failed'] for row in outputs[:11]), 'Fixture input unexpectedly failed'
        assert all(row['failed'] for row in outputs[11:15]), 'Invalid/own-process input was acknowledged as success'
        assert 'Queued virtual' in outputs[0]['output'] and 'Fixture A' in outputs[0]['output']
        assert 'Fixture A' in outputs[1]['output'], 'Virtual click did not establish the keyboard target'
        assert 'Sent native' in outputs[4]['output'] and 'Fixture B' in outputs[4]['output']
        assert 'unverified' in outputs[0]['output']
        assert outputs[14]['images'] == 1, 'Failed batch omitted fresh evidence'
        assert outputs[16]['foreground_unchanged'], 'Observing the screen changed foreground'
        time.sleep(0.2)
        state = json.loads((directory / 'state.json').read_text(encoding='utf-8'))
        assert state['A']['text'] == 'aA', state
        assert state['B']['text'] == 'bB', state
        assert state['A']['clicks'] == 1, state
        print('PASS: 17 calls; click/keyboard targets, explicit overrides, native fallback, refusal, fresh failure frame, observational capture')
    finally:
        (directory / 'stop').touch()
        fixture.wait(timeout=5)
        if previous:
            ctypes.windll.user32.SetForegroundWindow(previous)
