"""Record real drag events, bounded recovery, full dwell and kill-switch interruption."""
import ctypes
import json
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

package = Path(__file__).resolve().parents[1]
repo = package.parent
with tempfile.TemporaryDirectory(prefix='aurora-drag-test-') as temporary:
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
    fixture = subprocess.Popen([sys.executable, str(package / 'tests/mouse_button_fixture.py'),
        str(directory)], creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        deadline = time.monotonic() + 5
        while not (directory / 'events.json').exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert (directory / 'events.json').exists()
        drag = {'action': 'drag', 'input_mode': 'native', 'window': 'Aurora Mouse Button Fixture',
                'button': 'middle', 'x': 170, 'y': 470, 'x2': 250, 'y2': 470,
                'duration_ms': 80, 'screenshot': False}
        cases = [{'action': 'focus', 'title': 'Aurora Mouse Button Fixture',
                  'input_mode': 'native', 'screenshot': False}]
        cases.extend([dict(drag, x=170 + i * 3) for i in range(3)])
        cases.append(dict(drag))
        cases.append({'action': 'wait', 'duration_ms': 800, 'screenshot': False})
        cases.extend([dict(drag), dict(drag)])
        cases.append(dict(drag, x=250, x2=170))
        cases.append({'input_mode': 'native', 'steps': [dict(drag) for _ in range(5)]})
        cases.extend([dict(drag), dict(drag), dict(drag, button='invalid')])
        cases.extend([{'action': 'wait', 'duration_ms': -1, 'screenshot': False},
                      {'action': 'wait', 'duration_ms': 10001, 'screenshot': False},
                      {'action': 'wait', 'duration_ms': 10000, 'screenshot': False,
                       'test_abort_after_ms': 150}])
        scenario = directory / 'cases.json'
        scenario.write_text(json.dumps(cases), encoding='utf-8')
        run = subprocess.run([str(driver), str(scenario), str(directory)], cwd=directory,
            capture_output=True, text=True, encoding='utf-8', timeout=20, check=True)
        rows = [json.loads(line) for line in run.stdout.splitlines()]
        assert all(not r['failed'] for r in rows[:4]), rows[:4]
        assert rows[4]['failed'] and rows[4]['images'] == 2, rows[4]
        assert 'direction' in rows[4]['output'] and 'One retry' in rows[4]['output']
        assert not rows[5]['failed'] and int(re.findall(r'\[(\d+) ms\]', rows[5]['output'])[-1]) >= 800
        assert not rows[6]['failed'] and rows[7]['failed'], rows[6:8]
        assert not rows[8]['failed'], 'Reversing direction did not allow recovery'
        assert rows[9]['failed'] and rows[9]['images'] == 2, rows[9]
        assert not rows[10]['failed'] and rows[11]['failed'], rows[10:12]
        assert all(r['failed'] for r in rows[12:]), rows[12:]
        assert 'kill switch' in rows[15]['output']
        assert int(re.findall(r'\[(\d+) ms\]', rows[15]['output'])[-1]) < 700
        time.sleep(0.1)
        actual = json.loads((directory / 'events.json').read_text(encoding='utf-8'))
        assert actual == ['middle_down', 'middle_up'] * 9, actual
        print('PASS: 16 calls; nine actual drags, jitter/batch guard, one retry, reverse recovery, full 800 ms dwell, 150 ms kill interruption')
    finally:
        (directory / 'stop').touch()
        fixture.wait(timeout=5)
        if previous:
            ctypes.windll.user32.SetForegroundWindow(previous)
