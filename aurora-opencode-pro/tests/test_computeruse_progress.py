"""Run progress and request-intent regressions without using the user's chat state."""
import subprocess
import tempfile
from pathlib import Path

package = Path(__file__).resolve().parents[1]
repo = package.parent
with tempfile.TemporaryDirectory(prefix='aurora-progress-test-') as temporary:
    directory = Path(temporary)
    for source in ['computer_progress_test.d', 'computer_intent_test.d']:
        executable = directory / (Path(source).stem + '.exe')
        subprocess.run(['dmd', '-i', '-I' + str(package / 'source'),
            '-I' + str(repo / 'aurora-opencode-core/source'),
            '-I' + str(repo / 'vendor/aurora-d-0.4.5/source'),
            '-J' + str(package / 'assets'), '-of' + str(executable),
            str(package / 'tests' / source),
            'user32.lib', 'gdi32.lib', 'shell32.lib', 'wininet.lib'], check=True, cwd=directory)
        subprocess.run([str(executable)], check=True, cwd=directory, timeout=30)
