"""Opt-in hosted-agent review handoff using isolated copies of actual Aurora sources.

No canned provider responses. Uses the configured model and records task time,
tool counts and independent artifact checks. Never opens another project.
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import socket
import subprocess
import threading
import time
import zipfile

PACKAGE = Path(__file__).resolve().parents[1]
REPO = PACKAGE.parent


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


CHECKER = r'''import csv,hashlib,json,socket,zipfile
from pathlib import Path
p=Path(__file__).resolve().parent
root=p.parent
manifest=json.loads((p/'expected-source.json').read_text())
with zipfile.ZipFile(p/'review.zip') as z:
    assert z.testzip() is None
    files={x.filename for x in z.infolist() if not x.is_dir()}
    assert files==set(manifest), (len(files),len(manifest),files.symmetric_difference(manifest))
    for name,digest in manifest.items():
        assert hashlib.sha256(z.read(name)).hexdigest()==digest,name
metadata=json.loads((p/'handoff.json').read_text())
assert metadata['version']==json.loads((root/'dub.json').read_text())['version']
assert metadata['complete'] is True
digest=hashlib.sha256((p/'review.zip').read_bytes()).hexdigest()
assert hashlib.sha256((p/'downloaded.zip').read_bytes()).hexdigest()==digest
rows=list(csv.DictReader((p/'artifacts.csv').open(newline='',encoding='utf-8')))
assert any(x['artifact']=='review.zip' and x['sha256']==digest for x in rows)
with socket.socket() as s:
    s.settimeout(1)
    assert s.connect_ex(('127.0.0.1',metadata['port']))!=0,'HTTP server was left running'
print('PASS exact source manifest, ZIP CRCs, metadata, CSV digest, HTTP download and server cleanup')
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--live', action='store_true', required=True)
    ap.add_argument('--exe', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--timeout', type=int, default=900)
    a = ap.parse_args()
    directory = a.output.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    workspace = directory / 'checkout' / 'aurora-opencode-pro'
    workspace.mkdir(parents=True)
    scopes = ['source/auroraopencode', 'shared', 'dub.json', 'docs/agent-execution-flow-06643.md']
    manifest = {}
    paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '--', *scopes],
                                    cwd=PACKAGE, text=True).splitlines()
    for relative in sorted(set(paths)):
        source = PACKAGE / relative
        if not source.is_file():
            continue
        target = workspace / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        manifest[relative] = sha(target)
    review = workspace / 'review'
    review.mkdir()
    with socket.socket() as port_probe:
        port_probe.bind(('127.0.0.1', 0))
        port = port_probe.getsockname()[1]
    (review / 'handoff.json').write_text(json.dumps({'project': 'Aurora OpenCode', 'version': None,
                                                  'complete': False, 'port': port}), encoding='utf-8')
    (review / 'artifacts.csv').write_text('artifact,sha256\n', encoding='utf-8')
    (review / 'expected-source.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    (review / 'check_handoff.py').write_text(CHECKER, encoding='utf-8')
    subprocess.run(['git', 'init', '-q', str(workspace)], check=True)
    subprocess.run(['git', '-C', str(workspace), 'add', '.'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(workspace), '-c', 'user.name=Isolated replay',
                    '-c', 'user.email=replay@localhost', 'commit', '-qm', 'Isolated Aurora review input'],
                   check=True, capture_output=True)
    prompt = f'''Prepare a portable source review handoff for Aurora OpenCode in this isolated copy.
Work only in {workspace}. Do not modify original sources, rebuild, publish, install tools, or access any other project.
Use native archive, data, environment and process operations for packaging, metadata edits,
inspection and waiting. Use run for launching Python and the checker. Inspect Python availability and free disk space.
Create review/review.zip containing exactly source/auroraopencode/, shared/, dub.json and
docs/agent-execution-flow-06643.md, with their workspace-relative paths. Validate the archive.
Update review/handoff.json with the version from dub.json and mark complete when the handoff is ready.
Record review.zip and its actual SHA-256 in review/artifacts.csv, preserving the header.
Smoke-test sharing it: start Python's HTTP server in the background, bound to 127.0.0.1:{port},
serving review/. Wait for readiness, inspect the TCP listener and its owning PID, download
http://127.0.0.1:{port}/review.zip to review/downloaded.zip, compare checksums, then stop
your server and wait for it to exit. Do not kill processes you did not start.
Run the independent review/check_handoff.py checker once after the deliverables are ready;
it checks exact archived source hashes, metadata, CSV, the real download and server cleanup.
Do not change the checker or expected-source.json. Finish with the artifact path and checks performed.'''
    (directory / 'prompt.txt').write_text(prompt, encoding='utf-8')
    original = Path(os.environ['APPDATA']) / 'Aurora OpenCode'
    saved = json.loads((original / 'settings.json').read_text(encoding='utf-8-sig'))
    state = directory / 'appdata' / 'Aurora OpenCode'
    state.mkdir(parents=True)
    # This is artifact preparation in a normal task workspace, not Aurora's
    # self-development checkout. Keep the protected developer source separate.
    developer_source = directory / 'inactive-developer-source'
    developer_source.mkdir()
    settings = {**saved, 'workspace': str(workspace), 'quickTitle': False, 'composerSuggestion': False,
                'developerMode': False, 'developerSourceDir': str(developer_source),
                'developerAutoReapply': False, 'developerRequireLatestSource': False, 'nativeOnly': True}
    settings_path = state / 'settings.json'
    settings_path.write_text(json.dumps(settings), encoding='utf-8')
    temp = directory / 'temp'
    temp.mkdir()
    result = {'status': 'running', 'model': saved['model'], 'sourceFiles': len(manifest),
              'binarySha256': sha(a.exe), 'port': port}
    process = None
    started = time.monotonic()
    print('ARTIFACTS', directory, 'MODEL', saved['model'], 'SOURCE_FILES', len(manifest), flush=True)

    def messages():
        try:
            index = json.loads((state / 'threads.index.json').read_text(encoding='utf-8-sig'))
            header = next(x for x in index['sessions'] if x.get('title', '').startswith('Native service source handoff'))
            chat = json.loads((state / 'threads' / (header['id'] + '.json')).read_text(encoding='utf-8-sig'))
            return header, chat['messages']
        except (OSError, ValueError, KeyError, StopIteration):
            return {}, []

    try:
        with (directory / 'process.log').open('w', encoding='utf-8') as log:
            process = subprocess.Popen([str(a.exe.resolve()), '--session-server'], cwd=workspace,
                                       env=dict(os.environ, APPDATA=str(directory / 'appdata'), TEMP=str(temp), TMP=str(temp), FORGE_PUBLISH_SKIP='1'),
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                                       text=True, encoding='utf-8', errors='replace', bufsize=1)
            incoming = queue.Queue()
            def collect():
                for line in process.stdout:
                    try:
                        incoming.put(json.loads(line))
                    except ValueError:
                        pass
            threading.Thread(target=collect, daemon=True).start()
            def send(message):
                process.stdin.write(json.dumps(message) + '\n')
                process.stdin.flush()
            send({'type': 'create', 'id': 'native', 'title': 'Native service source handoff',
                  'workspace': str(workspace), 'model': saved['model'],
                  'thinking': saved.get('thinking', False), 'tools': True})
            last = 0
            with (directory / 'events.jsonl').open('w', encoding='utf-8') as events:
                while time.monotonic() - started < a.timeout:
                    try:
                        event = incoming.get(timeout=2)
                        events.write(json.dumps(event) + '\n'); events.flush()
                        if event['type'] == 'created':
                            send({'type': 'submit', 'id': 'native', 'requestId': 'source-handoff', 'text': prompt})
                        if event['type'] in {'turn.completed', 'turn.failed', 'turn.interrupted'}:
                            result.update(status=event['type'], final=event)
                            break
                        if event['type'] == 'error':
                            raise RuntimeError(event.get('error'))
                    except queue.Empty:
                        if process.poll() is not None:
                            raise RuntimeError('Session server exited')
                    elapsed = time.monotonic() - started
                    if elapsed - last >= 30:
                        header, history = messages()
                        tools = [x for x in history if x.get('role') == 'tool']
                        print('LIVE', round(elapsed), 'tools', len(tools), 'last', tools[-1].get('toolName') if tools else None,
                              'state', header.get('taskStatus'), flush=True)
                        last = elapsed
                else:
                    result['status'] = 'timeout'
                    send({'type': 'cancel', 'id': 'native'})
                send({'type': 'shutdown'})
                process.wait(timeout=45)
        header, history = messages()
        tools = [x for x in history if x.get('role') == 'tool']
        result.update(toolResults=len(tools), failedTools=sum(bool(x.get('failed')) for x in tools),
                      taskStatus=header.get('taskStatus'), verificationStatus=header.get('verificationStatus'),
                      toolCounts={name: sum(x.get('toolName') == name for x in tools) for name in sorted({x.get('toolName', '') for x in tools})})
        checked = subprocess.run(['python', str(review / 'check_handoff.py')], cwd=workspace, capture_output=True,
                                 text=True, encoding='utf-8', timeout=60)
        (directory / 'independent-check.log').write_text(checked.stdout + checked.stderr, encoding='utf-8')
        result['independentPassed'] = checked.returncode == 0
        assert checked.returncode == 0, checked.stdout + checked.stderr
        assert result['status'] == 'turn.completed', result
        for name, digest in manifest.items():
            assert sha(workspace / name) == digest, 'Source was modified: ' + name
    except Exception as error:
        result.update(status='replay.failed', error=str(error))
        raise
    finally:
        if process is not None and process.poll() is None:
            process.terminate(); process.wait(timeout=15)
        # Never retain copied provider credentials in benchmark artifacts.
        settings_path.unlink(missing_ok=True)
        result['seconds'] = time.monotonic() - started
        (directory / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print('RESULT', result['status'], round(result['seconds'], 2), 'INDEPENDENT', result.get('independentPassed'),
              'TOOLS', result.get('toolResults'), flush=True)


if __name__ == '__main__':
    main()
