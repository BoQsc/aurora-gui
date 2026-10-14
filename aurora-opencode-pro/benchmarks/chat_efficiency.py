"""Offline, synthetic regressions inspired by recurring saved-chat failures.

No conversation text, credentials or provider calls are used by the fixtures.
Build the baseline before applying a fix, build the candidate afterward, then run
both profiles in counterbalanced order. Reports retain each executable's hash.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

PACKAGE = Path(__file__).resolve().parents[1]
ROOT = PACKAGE.parent


def inputs():
    paths = [PACKAGE/'source/auroraopencode/tools.d',
             PACKAGE/'source/auroraopencode/developerworkflow.d',
             PACKAGE/'tests/chat_efficiency_contracts.d']
    return {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def record_build(directory, profile):
    metadata = dict(inputs=inputs(), git_head=subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        executable_sha256=hashlib.sha256((directory/(profile+'.exe')).read_bytes()).hexdigest())
    (directory/(profile+'.build.json')).write_text(json.dumps(metadata, indent=2), encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--build', choices=['baseline', 'candidate', 'git-only'])
    parser.add_argument('--profiles', nargs='+', default=['baseline', 'candidate'])
    parser.add_argument('--repeats', type=int, default=3)
    args = parser.parse_args()
    directory = args.output.resolve().parent
    directory.mkdir(parents=True, exist_ok=True)
    if args.build:
        binary = directory / (args.build + '.exe')
        before = inputs()
        subprocess.run(['dmd', '-i', '-O', '-inline',
                        '-I'+str(PACKAGE/'source'), '-I'+str(PACKAGE/'shared'),
                        '-I'+str(ROOT/'aurora-opencode-core/source'),
                        '-I'+str(ROOT/'vendor/aurora-d-0.4.5/source'),
                        '-J'+str(PACKAGE/'assets'), '-of'+str(binary),
                        str(PACKAGE/'tests/chat_efficiency_contracts.d'),
                        'user32.lib', 'gdi32.lib', 'shell32.lib', 'wininet.lib', 'winmm.lib'],
                       cwd=directory, check=True, timeout=180)
        if inputs() != before:
            raise RuntimeError('Fixture/source changed during compilation')
        record_build(directory, args.build)
        return
    real_git = shutil.which('git')
    if not real_git:
        raise RuntimeError('Git is required to prepare an isolated repository')
    provenance = {p: json.loads((directory/(p+'.build.json')).read_text()) for p in args.profiles}
    fixture = 'aurora-opencode-pro/tests/chat_efficiency_contracts.d'
    if len({p['inputs'][fixture] for p in provenance.values()}) != 1:
        raise RuntimeError('Both profiles must use the identical fixture')
    report = dict(scope='Synthetic offline native-tool fixtures; no provider wait or generation.',
                  provenance=provenance,
                  binaries={p: hashlib.sha256((directory/(p+'.exe')).read_bytes()).hexdigest()
                            for p in args.profiles}, runs=[])
    if any(provenance[p]['executable_sha256'] != digest for p,digest in report['binaries'].items()):
        raise RuntimeError('A benchmark executable changed after compilation')
    for attempt in range(1, args.repeats+1):
        for profile in args.profiles if attempt % 2 else args.profiles[::-1]:
            run = directory / args.output.stem / profile / ('run-'+str(attempt))
            if run.exists():
                raise RuntimeError('Use a new output directory for a fresh comparison')
            run.mkdir(parents=True)
            result = run/'results.json'
            started = time.monotonic()
            process = subprocess.run([str(directory/(profile+'.exe')), str(run/'workspace'), str(result)],
                                     cwd=run, env=dict(os.environ, AURORA_TEST_GIT=real_git,
                                                       AURORA_TEST_RUNTIME_PATH=str(Path(shutil.which('dmd')).parent)),
                                     capture_output=True, text=True, errors='replace', timeout=180)
            (run/'fixture.log').write_text(process.stdout+process.stderr, encoding='utf-8')
            if process.returncode:
                raise RuntimeError('Fixture failed: '+(process.stdout+process.stderr)[-3000:])
            cases = json.loads(result.read_text(encoding='utf-8'))
            row = dict(profile=profile, attempt=attempt, seconds=round(time.monotonic()-started,3), cases=cases)
            report['runs'].append(row)
            args.output.write_text(json.dumps(report, indent=2), encoding='utf-8')
            print(json.dumps(dict(profile=profile, attempt=attempt,
                                  passed=sum(c['correct'] for c in cases), total=len(cases), seconds=row['seconds'])), flush=True)
    for profile in args.profiles:
        rows=[r for r in report['runs'] if r['profile']==profile]
        print(profile, 'failed cases:', sorted({c['case'] for r in rows for c in r['cases'] if not c['correct']}), flush=True)
    candidate = args.profiles[-1]
    if candidate != 'baseline':
        cases = [c for r in report['runs'] if r['profile']==candidate for c in r['cases']]
        if not cases or not all(c['correct'] for c in cases):
            raise RuntimeError('Candidate did not pass every outcome/guard')


if __name__ == '__main__':
    main()
