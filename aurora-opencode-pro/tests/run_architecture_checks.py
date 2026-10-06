"""Build isolated executables; never replace or launch the production image."""
import argparse
import subprocess
import tempfile
from pathlib import Path

package = Path(__file__).resolve().parents[1]
repo = package.parent
parser = argparse.ArgumentParser()
parser.add_argument('fixtures', nargs='*', default=['chat_consistency_smoke', 'headless_pro_smoke'])
args = parser.parse_args()
directory = Path(tempfile.mkdtemp(prefix='aurora-architecture-checks-'))
(directory / 'build').mkdir()
print('ARTIFACTS', directory, flush=True)
for fixture in args.fixtures:
    executable = directory / (fixture + '.exe')
    result = subprocess.run([
        'dmd', '-i', '-verrors=20',
        '-I' + str(package / 'source'), '-I' + str(package / 'shared'),
        '-I' + str(repo / 'aurora-opencode-core/source'),
        '-I' + str(repo / 'vendor/aurora-d-0.4.5/source'),
        '-J' + str(package / 'assets'), '-of' + str(executable),
        str(package / 'tests' / (fixture + '.d')),
        'user32.lib', 'gdi32.lib', 'shell32.lib', 'wininet.lib', 'winmm.lib',
    ], cwd=directory, timeout=120)
    if result.returncode:
        raise SystemExit(result.returncode)
    print('RUN', fixture, flush=True)
    result = subprocess.run([str(executable)], cwd=directory, timeout=120)
    if result.returncode:
        raise SystemExit(result.returncode)
    print('PASS', fixture, flush=True)
