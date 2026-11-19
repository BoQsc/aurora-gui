"""Screenshots are window-scoped by default; the whole desktop is opt-in.

Runs the production computer-use tool against two fixture windows and checks
the attached frame's real pixel size against each window's own rectangle. A
click read in the window frame's pixel space must land on the control.
"""
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


class RECT(ctypes.Structure):
    _fields_ = [('left', ctypes.c_long), ('top', ctypes.c_long),
                ('right', ctypes.c_long), ('bottom', ctypes.c_long)]


user32 = ctypes.windll.user32
user32.FindWindowW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p]
user32.FindWindowW.restype = ctypes.c_void_p
user32.GetWindowRect.argtypes = [ctypes.c_void_p, ctypes.POINTER(RECT)]
user32.GetForegroundWindow.restype = ctypes.c_void_p
user32.SetForegroundWindow.argtypes = [ctypes.c_void_p]
user32.GetSystemMetrics.restype = ctypes.c_int


def window_size(title):
    hwnd = user32.FindWindowW(None, title)
    assert hwnd, f'fixture window not found: {title}'
    rect = RECT()
    assert user32.GetWindowRect(hwnd, ctypes.byref(rect))
    return rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top


def close(actual, expected, tolerance=4):
    return all(abs(a - e) <= tolerance for a, e in zip(actual, expected))


with tempfile.TemporaryDirectory(prefix='aurora-capture-test-') as temporary:
    directory = Path(temporary)
    driver = directory / 'capture-test.exe'
    subprocess.run(['dmd', '-i', '-I' + str(package / 'source'),
        '-I' + str(repo / 'aurora-opencode-core/source'),
        '-I' + str(repo / 'vendor/aurora-d-0.4.5/source'), '-of' + str(driver),
        str(package / 'tests/computeruse_capture_test.d'),
        'user32.lib', 'gdi32.lib', 'shell32.lib', 'wininet.lib'], check=True,
        cwd=directory)
    previous = user32.GetForegroundWindow()
    fixture = subprocess.Popen([sys.executable,
        str(package / 'tests/computeruse_input_fixture.py'), str(directory)],
        creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        deadline = time.monotonic() + 8
        while not (directory / 'state.json').exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        positions = json.loads((directory / 'state.json').read_text(encoding='utf-8'))
        a_title, b_title = positions['A']['title'], positions['B']['title']
        ax, ay, aw, ah = window_size(a_title)
        bx, by, bw, bh = window_size(b_title)
        # A native click is delivered as a press only when the target already
        # owns the foreground; otherwise Windows spends it on activation.
        a_hwnd = user32.FindWindowW(None, a_title)
        assert a_hwnd
        user32.SetForegroundWindow(a_hwnd)
        time.sleep(0.3)
        # The button's desktop point expressed in fixture A's window frame.
        button_x, button_y = positions['A']['button']
        frame_x, frame_y = button_x - ax, button_y - ay
        screen_w = user32.GetSystemMetrics(0)
        screen_h = user32.GetSystemMetrics(1)
        cases = [
            {'action': 'focus', 'title': a_title, 'screenshot': False},
            {'action': 'screen'},
            {'action': 'click', 'window': a_title, 'input_mode': 'native',
             'x': frame_x, 'y': frame_y},
            {'action': 'screen'},
            {'action': 'screen', 'full_screen': True},
            {'action': 'screen', 'window': b_title},
            {'action': 'screen', 'list_windows': True},
            {'action': 'screen', 'list_windows': True, 'app': 'python'},
            {'action': 'screen', 'list_windows': True, 'app': 'zz-no-such-app'},
            {'action': 'screen', 'app': 'python'},
        ]
        scenario = directory / 'cases.json'
        scenario.write_text(json.dumps(cases), encoding='utf-8')
        run = subprocess.run([str(driver), str(scenario), str(directory)],
            capture_output=True, text=True, encoding='utf-8', timeout=60)
        assert run.returncode == 0, (run.returncode, run.stdout, run.stderr)
        rows = [json.loads(line) for line in run.stdout.splitlines()]
        assert len(rows) == len(cases), rows

        def frame(row):
            assert row['images'] == 1, row
            return Image.open(row['image_details'][0]['path']).size

        assert not rows[0]['failed'], rows[0]
        assert not rows[1]['failed'], rows[1]
        assert frame(rows[1]) == (aw, ah), (frame(rows[1]), (aw, ah))
        assert a_title in rows[1]['output'] and 'window' in rows[1]['output'], rows[1]
        assert b_title in rows[1]['output'] and '(suggested)' in rows[1]['output'], \
            'A default screen did not list the window candidates'
        assert rows[1]['foreground_unchanged'], 'A window screenshot stole focus'

        assert not rows[2]['failed'], rows[2]
        assert 'in window' in rows[2]['output'] and a_title in rows[2]['output'], rows[2]
        assert frame(rows[2]) == (aw, ah), (frame(rows[2]), (aw, ah))
        assert not rows[3]['failed'] and frame(rows[3]) == (aw, ah), rows[3]

        assert not rows[4]['failed'] and frame(rows[4]) == (screen_w, screen_h), rows[4]
        assert 'desktop' in rows[4]['output'], rows[4]
        assert rows[4]['foreground_unchanged'], 'A desktop screenshot stole focus'

        assert not rows[5]['failed'], rows[5]
        assert frame(rows[5]) == (bw, bh), (frame(rows[5]), (bw, bh))
        assert b_title in rows[5]['output'], rows[5]

        assert not rows[6]['failed'], rows[6]
        assert rows[6]['images'] == 0, 'Listing windows captured an image'
        assert 'Visible windows' in rows[6]['output'], rows[6]
        assert a_title in rows[6]['output'] and b_title in rows[6]['output'], rows[6]

        assert not rows[7]['failed'] and rows[7]['images'] == 0, rows[7]
        assert a_title in rows[7]['output'] and b_title in rows[7]['output'], rows[7]
        assert '[python]' in rows[7]['output'], 'The list did not show app names'
        assert not rows[8]['failed'] and rows[8]['images'] == 0, rows[8]
        assert 'No visible window matches' in rows[8]['output'], rows[8]
        assert 'zz-no-such-app' in rows[8]['output'], rows[8]
        assert not rows[9]['failed'], rows[9]
        assert a_title in rows[9]['output'], rows[9]
        assert frame(rows[9]) == (aw, ah), (frame(rows[9]), (aw, ah))

        state = json.loads((directory / 'state.json').read_text(encoding='utf-8'))
        deadline = time.monotonic() + 3
        while state['A']['clicks'] != 1 and time.monotonic() < deadline:
            time.sleep(0.05)
            state = json.loads((directory / 'state.json').read_text(encoding='utf-8'))
        assert state['A']['clicks'] == 1, state
        print('PASS: default screen is the target window, full_screen is opt-in, '
              'named window capture works, the window list lets the agent choose, '
              'app names filter the list, and a frame-relative click lands')
    finally:
        (directory / 'stop').touch()
        try:
            fixture.wait(timeout=10)
        except subprocess.TimeoutExpired:
            fixture.terminate()
            fixture.wait(timeout=5)
        if previous:
            user32.SetForegroundWindow(previous)
