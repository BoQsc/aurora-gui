"""Switching computer use off must stop a call that is already driving the desktop."""
import subprocess
import tempfile
from pathlib import Path

package = Path(__file__).resolve().parents[1]
repo = package.parent
with tempfile.TemporaryDirectory(prefix='aurora-toggle-test-') as temporary:
    directory = Path(temporary)
    executable = directory / 'computer_toggle_stop_test.exe'
    subprocess.run(['dmd', '-i', '-I' + str(package / 'source'),
        '-I' + str(repo / 'aurora-opencode-core/source'),
        '-I' + str(repo / 'vendor/aurora-d-0.4.5/source'),
        '-of' + str(executable),
        str(package / 'tests/computer_toggle_stop_test.d'),
        'user32.lib', 'gdi32.lib', 'shell32.lib', 'wininet.lib'], check=True, cwd=directory)
    subprocess.run([str(executable)], check=True, cwd=directory, timeout=60)
