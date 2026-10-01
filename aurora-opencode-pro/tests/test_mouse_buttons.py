"""Verify button dispatch using real Win32 mouse-down/up events, not acknowledgments."""
import ctypes
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

package = Path(__file__).resolve().parents[1]
repo = package.parent
with tempfile.TemporaryDirectory(prefix='aurora-mouse-button-test-') as temporary:
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
        assert (directory / 'events.json').exists(), 'Mouse fixture did not start'
        cases, expected, gestures = [], [], []
        common = {'x': 170, 'y': 470, 'window': 'Aurora Mouse Button Fixture', 'screenshot': False}
        for mode in ('native', 'virtual'):
            for button in ('left', 'right', 'middle'):
                for action in ('click', 'double_click'):
                    cases.append(dict(common, action=action, button=button, input_mode=mode))
                    expected.extend([button + '_down', button + '_up'] * (2 if action == 'double_click' else 1))
                    gestures.append((button, action))
            cases.append(dict(common, action='right_click', input_mode=mode))
            expected.extend(['right_down', 'right_up'])
            gestures.append(('right', 'click'))
            cases.append({'input_mode': mode, 'steps': [
                dict(common, action='click', button='middle'),
                dict(common, action='click', button='right')]})
            expected.extend(['middle_down', 'middle_up', 'right_down', 'right_up'])
            gestures.append(('batch', 'click'))
        valid = len(cases)
        cases.extend([dict(common, input_mode='native', action='click', button='side'),
            dict(common, input_mode='native', action='click', button=42),
            dict(common, input_mode='native', action='right_click', button='left')])
        scenario = directory / 'cases.json'
        scenario.write_text(json.dumps(cases), encoding='utf-8')
        run = subprocess.run([str(driver), str(scenario)], cwd=directory, capture_output=True,
            text=True, encoding='utf-8', timeout=20, check=True)
        results = [json.loads(line) for line in run.stdout.splitlines()]
        assert all(not r['failed'] for r in results[:valid]), results
        assert all(r['failed'] for r in results[valid:]), 'Invalid button was silently changed'
        for result, (button, action) in zip(results, gestures):
            if button == 'batch': continue
            gesture = ('double-click' if action == 'double_click' else 'click')
            if button != 'left': gesture = button + (' ' if action == 'double_click' else '-') + gesture
            assert gesture in result['output'], result
        time.sleep(0.1)
        actual = json.loads((directory / 'events.json').read_text(encoding='utf-8'))
        assert actual == expected, {'expected': expected, 'actual': actual}
        print(f'PASS: {len(cases)} button calls; {len(actual)} real native/posted events; left/right/middle, double-click, alias, batches, invalid buttons')
    finally:
        (directory / 'stop').touch()
        fixture.wait(timeout=5)
        if previous:
            ctypes.windll.user32.SetForegroundWindow(previous)
