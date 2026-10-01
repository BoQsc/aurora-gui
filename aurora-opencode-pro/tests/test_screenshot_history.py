"""Compile and run image-history, persistence and long-chat regressions."""
import subprocess
import tempfile
from pathlib import Path

package = Path(__file__).resolve().parents[1]
repo = package.parent
with tempfile.TemporaryDirectory(prefix='aurora-history-test-') as temporary:
    directory = Path(temporary)
    executable = directory / 'history-test.exe'
    subprocess.run(['dmd', '-i', '-I' + str(package / 'source'),
        '-I' + str(repo / 'aurora-opencode-core/source'),
        '-I' + str(repo / 'vendor/aurora-d-0.4.5/source'),
        '-J' + str(package / 'assets'), '-of' + str(executable),
        str(package / 'tests/screenshot_history_test.d'),
        'user32.lib', 'gdi32.lib', 'shell32.lib', 'wininet.lib'],
        check=True, cwd=directory)
    subprocess.run([str(executable)], check=True, cwd=directory, timeout=90)
