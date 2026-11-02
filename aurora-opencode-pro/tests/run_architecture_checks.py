"""Build isolated executables; never replace or launch the production image."""
import argparse
import subprocess
import tempfile
import json
import time
import hashlib
import os
import shutil
import stat
from pathlib import Path

package = Path(__file__).resolve().parents[1]
repo = package.parent
parser = argparse.ArgumentParser()
parser.add_argument('--release', action='store_true', help='Measure optimized fixtures using release compiler flags')
parser.add_argument('--keep-runs', type=int, default=3, help='Retain this many newest architecture-check run directories')
parser.add_argument('--prune-only', action='store_true', help='Prune old architecture-check runs and exit')
parser.add_argument('fixtures', nargs='*', default=['preference_writer_contracts', 'architecture_contracts', 'presentation_contracts', 'chat_performance_contracts', 'chat_consistency_smoke', 'history_preservation_contracts', 'journal_history_restore_contracts', 'tool_feedback_contracts', 'tool_feedback_ui_contracts', 'headless_pro_smoke', 'tools_test', 'execution_ui_contracts', 'flow_resilience_contracts', 'read_progress_contracts', 'read_progress_ui_contracts', 'image_latency_contracts', 'task_continuation_contracts', 'plan_receipt_contracts', 'followup_ui_contracts', 'background_process_ui_smoke', 'export_reveal_ui_smoke',
                       'source_background_guard', 'duplicate_launch_contracts', 'markdown_viewport_contracts', 'wrapped_code_selection_contracts', 'lazy_tool_group_contracts', 'image_history_performance_contracts',
                       'repository_responsiveness_contracts', 'startup_responsiveness_contracts',
                       'history_mailbox_contracts', 'corrupt_restore_contracts', 'application_crash_restore_contracts',
                       'exit_checkpoint_contracts', 'goal_mode_contracts', 'output_recovery_contracts',
                       'engine_policy_contracts', 'projection_cache_contracts', 'verification_revision_contracts', 'retry_policy_contracts', 'tool_protocol_contracts', 'tool_resource_contracts', 'attachment_collection_contracts', 'orchestration_ownership_contracts', 'orchestrator_headless_smoke', 'actor_mailbox_contracts', 'conversation_projection_contracts', 'conversation_metadata_contracts', 'conversation_registry_contracts', 'conversation_job_contracts', 'actor_owner_performance_contracts', 'scheduler_shutdown_contracts'])
args = parser.parse_args()
if args.keep_runs < 1:
    parser.error('--keep-runs must be at least 1')
# The rebuild-button fixture requires an executable beneath the package's
# recipe. Each run still has a distinct filename and private artifact folder.
build_root = package / 'build'
build_root.mkdir(exist_ok=True)

def prune_architecture_runs(keep: int, current: Path | None = None) -> int:
    """Remove old retained runs while preserving the newest `keep` snapshots."""
    runs = []
    for candidate in build_root.iterdir():
        if candidate == current or candidate.is_symlink() or not candidate.is_dir():
            continue
        if not candidate.name.startswith('architecture-checks-'):
            continue
        try:
            runs.append((candidate.stat().st_mtime, candidate))
        except OSError:
            continue
    runs.sort(key=lambda item: item[0], reverse=True)
    # The just-created run consumes one retention slot when present.
    retain_old = max(0, keep - (1 if current is not None else 0))
    def remove_readonly(function, path, excinfo):
        try:
            os.chmod(path, stat.S_IWRITE)
            function(path)
        except OSError as error:
            print(f'PRUNE WARNING {path}: {error}', flush=True)

    removed = 0
    for _, candidate in runs[retain_old:]:
        try:
            shutil.rmtree(candidate, onexc=remove_readonly)
        except OSError as error:
            print(f'PRUNE WARNING {candidate}: {error}', flush=True)
        else:
            if candidate.exists():
                print(f'PRUNE WARNING {candidate}: incomplete removal', flush=True)
            else:
                removed += 1
    return removed

if args.prune_only:
    removed = prune_architecture_runs(args.keep_runs)
    print(f'PRUNED {removed} old architecture-check run(s); kept {args.keep_runs}', flush=True)
    raise SystemExit(0)

directory = Path(tempfile.mkdtemp(prefix='architecture-checks-', dir=build_root))
(directory / 'build').mkdir()
removed = prune_architecture_runs(args.keep_runs, directory)
if removed:
    print(f'PRUNED {removed} old architecture-check run(s); kept {args.keep_runs}', flush=True)
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
proof = {'sourceSha256': fingerprint, 'gitHead': head,
         'buildMode': 'optimized-with-assertions' if args.release else 'debug'}
print('ARTIFACTS', directory, 'SOURCE', fingerprint, flush=True)
env = dict(os.environ)
for fixture in ['filesystem_host', *args.fixtures]:
    executable = directory / (fixture + '.exe')
    compile_command = [
        'dmd', '-i', '-verrors=20',
        *(['-O', '-inline'] if args.release and fixture != 'filesystem_host' else []),
        '-I' + str(package / 'source'), '-I' + str(package / 'shared'),
        '-I' + str(package / 'tests'),
        '-I' + str(repo / 'aurora-opencode-core/source'),
        '-I' + str(repo / 'vendor/aurora-d-0.4.5/source'),
        '-J' + str(package / 'assets'), '-of' + str(executable),
        str(package / 'tests' / (fixture + '.d')),
        'user32.lib', 'gdi32.lib', 'shell32.lib', 'wininet.lib', 'winmm.lib',
    ]
    build_log = directory / (fixture + '.build.log')
    with build_log.open('w', encoding='utf-8') as log:
        result = subprocess.run(compile_command, cwd=directory,
                                timeout=180 if args.release else 120,
                                stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        (directory / (fixture + '.result.json')).write_text(json.dumps({
            **proof, 'fixture': fixture, 'status': 'compile-failed',
            'exitCode': result.returncode, 'command': compile_command,
        }), encoding='utf-8')
        print('COMPILE FAILED', fixture, 'exitCode=', result.returncode, 'LOG', build_log, flush=True)
        print(build_log.read_text(encoding='utf-8', errors='replace')[-6000:], flush=True)
        raise SystemExit(1)
    # Linked fixtures are retained as evidence; their compiler intermediates
    # are reproducible and otherwise accumulate gigabytes during regression work.
    executable.with_suffix('.obj').unlink(missing_ok=True)
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
