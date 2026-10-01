"""Exercise production Win32 input against two isolated fixture windows."""
import ctypes
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from PIL import Image

package = Path(__file__).resolve().parents[1]
repo = package.parent
with tempfile.TemporaryDirectory(prefix='aurora-input-test-') as temporary:
    directory = Path(temporary)
    driver = directory / 'input-test.exe'
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
        x, y = positions['A']['entry']
        blank = {'action': 'click', 'input_mode': 'native', 'x': x,
                 'y': y + 95, 'screenshot': False}
        # Focus/typing starts a new approach, then all three inert clicks execute.
        cases.append({'action': 'focus', 'title': positions['A']['title'], 'screenshot': False})
        cases.extend([dict(blank, x=x + i * 2) for i in range(3)])
        cases.append(dict(blank, x=x + 7))
        cases.append({'action': 'screen'})
        cases.append(dict(blank, x=x + 9))
        cases.append({'action': 'screen', 'region': {'x': x - 10, 'y': y + 75, 'w': 80, 'h': 40}})
        cases.append(dict(blank, x=x + 11))
        cases.append({'input_mode': 'native',
                      'steps': [dict(blank, x=x + i * 2) for i in range(5)]})
        cases.extend([dict(blank, x=x + i) for i in range(3)])
        scenario = directory / 'cases.json'
        scenario.write_text(json.dumps(cases), encoding='utf-8')
        result = subprocess.run([str(driver), str(scenario), str(directory)], capture_output=True,
            text=True, encoding='utf-8', timeout=20)
        assert result.returncode == 0, result.stderr
        outputs = [json.loads(line) for line in result.stdout.splitlines()]
        assert all(not row['failed'] for row in outputs[:11]), 'Fixture input unexpectedly failed'
        assert all(row['failed'] for row in outputs[11:15]), 'Invalid/own-process input was acknowledged as success'
        assert 'Queued virtual' in outputs[0]['output'] and 'Fixture A' in outputs[0]['output'], outputs[0]
        assert 'Fixture A' in outputs[1]['output'], 'Virtual click did not establish the keyboard target'
        assert 'Sent native' in outputs[4]['output'] and 'Fixture B' in outputs[4]['output']
        assert 'unverified' in outputs[0]['output']
        assert outputs[14]['images'] == 1, 'Failed batch omitted fresh evidence'
        assert outputs[16]['foreground_unchanged'], 'Observing the screen changed foreground'
        assert all(not row['failed'] for row in outputs[17:21]), outputs[17:21]
        assert outputs[21]['failed'] and 'little visible change' in outputs[21]['output'], outputs[21]
        assert outputs[21]['images'] == 2, 'Withheld click omitted focused evidence'
        details = outputs[21]['image_details']
        assert [i['name'] for i in details] == ['screen-target.jpg', 'screen-instructions.jpg']
        assert all(i['mime'] == 'image/jpeg' for i in details)
        assert Image.open(details[0]['path']).size == (640, 480)
        assert Image.open(details[1]['path']).size == (1920, 160)
        assert 'desktop origin' in outputs[21]['output'] and 'One retry' in outputs[21]['output']
        assert not outputs[23]['failed'], 'Focused evidence did not permit one retry'
        assert not outputs[24]['failed'] and not outputs[25]['failed'], 'A crop did not permit re-grounding'
        assert outputs[26]['failed'] and 'little visible change' in outputs[26]['output'], 'Batch bypassed guard'
        assert outputs[26]['images'] == 2, 'Batch overwrote focused recovery with a full frame'
        assert not outputs[27]['failed'], 'Batch recovery did not permit a retry'
        assert outputs[28]['failed'] and outputs[29]['failed'], outputs[26:30]
        assert 'Further nearby clicks are withheld' in outputs[28]['output']
        time.sleep(0.2)
        state = json.loads((directory / 'state.json').read_text(encoding='utf-8'))
        assert state['A']['text'] == 'aA', state
        assert state['B']['text'] == 'bB', state
        assert state['A']['clicks'] == 1, state
        print('PASS: 30 calls; real input, target checks, focused JPEG/origins, batch recovery, one retry, exhausted retry refusal')
    finally:
        (directory / 'stop').touch()
        fixture.wait(timeout=5)
        if previous:
            ctypes.windll.user32.SetForegroundWindow(previous)
