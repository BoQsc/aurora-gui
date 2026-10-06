"""Build isolated executables; never replace or launch the production image."""
import argparse
import subprocess
import tempfile
import json
import time
import hashlib
import os
from pathlib import Path

package = Path(__file__).resolve().parents[1]
repo = package.parent
parser = argparse.ArgumentParser()
parser.add_argument('fixtures', nargs='*', default=['architecture_contracts', 'presentation_contracts', 'chat_consistency_smoke', 'headless_pro_smoke', 'tools_test', 'execution_ui_contracts', 'flow_resilience_contracts'])
args = parser.parse_args()
# The rebuild-button fixture requires an executable beneath the package's
# recipe. Each run still has a distinct filename and private artifact folder.
(package / 'build').mkdir(exist_ok=True)
directory = Path(tempfile.mkdtemp(prefix='architecture-checks-', dir=package / 'build'))
(directory / 'build').mkdir()
def source_fingerprint():
    digest = hashlib.sha256()
    roots = [package / 'source', package / 'shared', package / 'tests',
             repo / 'aurora-opencode-core/source', repo / 'vendor/aurora-d-0.4.5/source']
    for path in sorted(p for root in roots for p in root.rglob('*.d')):
        digest.update(str(path.relative_to(repo)).encode('utf-8'))
        digest.update(path.read_bytes())
    return digest.hexdigest()

fingerprint = source_fingerprint()
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
proof = {'sourceSha256': fingerprint, 'gitHead': head}
print('ARTIFACTS', directory, 'SOURCE', fingerprint, flush=True)
env = dict(os.environ)
for fixture in ['filesystem_host', *args.fixtures]:
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
    if fixture == 'filesystem_host':
        env['AURORA_FILESYSTEM_HOST'] = str(executable)
        continue
    evidence = dict(proof, executableSha256=hashlib.sha256(executable.read_bytes()).hexdigest())
    print('RUN', fixture, flush=True)
    started = time.monotonic()
    log_path = directory / (fixture + '.log')
    try:
        with log_path.open('w', encoding='utf-8') as log:
            result = subprocess.run([str(executable)], cwd=directory, timeout=120,
                                    stdout=log, stderr=subprocess.STDOUT, env=env)
    except subprocess.TimeoutExpired:
        (directory / (fixture + '.result.json')).write_text(json.dumps({
            **evidence, 'fixture': fixture, 'status': 'timeout', 'seconds': time.monotonic() - started
        }), encoding='utf-8')
        print(log_path.read_text(encoding='utf-8', errors='replace')[-6000:], flush=True)
        raise
    (directory / (fixture + '.result.json')).write_text(json.dumps({
        **evidence, 'fixture': fixture, 'status': 'passed' if result.returncode == 0 else 'failed',
        'exitCode': result.returncode, 'seconds': time.monotonic() - started,
    }), encoding='utf-8')
    if result.returncode:
        print(log_path.read_text(encoding='utf-8', errors='replace')[-6000:], flush=True)
        raise SystemExit(result.returncode)
    if source_fingerprint() != fingerprint:
        raise SystemExit('Sources changed during verification; result requires a fresh run')
    print('PASS', fixture, 'LOG', log_path, flush=True)
