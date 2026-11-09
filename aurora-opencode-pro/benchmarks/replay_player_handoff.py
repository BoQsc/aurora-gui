"""Opt-in real-provider replay of the saved TerraForest player handoff request.

Uses the shipping session server with the GUI's exact model/thinking settings.
All work and history are private to a source snapshot; previous deliverables,
builds and caches are excluded. No canned provider responses or tool results.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import time


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def snapshot(source, workspace):
    roots = {'addons', 'assets', 'authoring', 'demo', 'docs', 'tests', 'tools', 'mods', 'vehicle_demo'}
    omitted = {'.git', '.godot', '.build', '__pycache__', 'node_modules', 'dist', 'reports', 'evidence', 'reviews'}
    records = []
    for root, dirs, files in os.walk(source):
        relative = Path(root).relative_to(source)
        dirs[:] = [d for d in dirs if d not in omitted and (relative.parts or d in roots)]
        for name in files:
            path = Path(root)/name
            if path.suffix.lower() in {'.exe', '.pdb', '.log', '.bak', '.zip', '.tmp', '.lock', '.obj'}:
                continue
            if relative.parts and relative.parts[0] == 'docs' and path.suffix.lower() not in {'.md', '.txt', '.json', '.gd', '.py', '.cfg'}:
                continue
            destination = workspace/relative/name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
            records.append({'path': (relative/name).as_posix(), 'bytes': path.stat().st_size,
                            'sha256': digest(destination)})
    return records


def saved_view(state):
    try:
        index = json.loads((state/'threads.index.json').read_text(encoding='utf-8-sig'))
        header = next((s for s in index['sessions'] if s.get('title', '').startswith('Live player handoff')), {})
        messages = json.loads((state/'threads'/(header['id']+'.json')).read_text(encoding='utf-8-sig'))['messages'] if header else []
        return header, messages
    except (OSError, ValueError, KeyError):
        return {}, []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--exe', type=Path, default=Path(__file__).resolve().parents[1]/'aurora-opencode-pro.exe')
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--snapshot', type=Path, help='Reuse a pristine snapshot from an earlier run')
    args = parser.parse_args()
    directory = args.output.resolve()
    package = Path(__file__).resolve().parents[1]
    if directory.is_relative_to(package.parent):
        raise ValueError('Live replay output must be outside Aurora checkout to avoid source-guard interference')
    directory.mkdir(parents=True, exist_ok=False)
    workspace = directory/'TerraForest'
    workspace.mkdir()
    if args.snapshot:
        manifest = json.loads((args.snapshot.parent/'snapshot.json').read_text())
        for record in manifest:
            source = args.snapshot.resolve()/record['path']
            if digest(source) != record['sha256']:
                raise ValueError('Snapshot input changed: '+record['path'])
            target = workspace/record['path']
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    else:
        manifest = snapshot(args.source.resolve(strict=True), workspace)
    (directory/'snapshot.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    # Match the original project being nested in a repository without sharing
    # Aurora's checkout identity or inheriting its source-operation guards.
    subprocess.run(['git', 'init', '-q', str(directory)], check=True, capture_output=True)
    state = directory/'appdata/Aurora OpenCode'
    state.mkdir(parents=True)
    saved = json.loads((Path(os.environ['APPDATA'])/'Aurora OpenCode/settings.json').read_text(encoding='utf-8-sig'))
    settings = {**saved, 'workspace': str(workspace), 'quickTitle': False, 'composerSuggestion': False}
    settings_path = state/'settings.json'
    settings_path.write_text(json.dumps(settings), encoding='utf-8')
    prompt = (str(workspace) + ' find and make a zip of player model so we can offer other person '
              'to animate and add new item then we will bring back to reintegrate.\n\n'
              'This is a copied project for a live task replay. Work only in this copy; do not '
              'access or modify the original project or use its previous handoff outputs. '
              'The snapshot excludes build outputs, caches, previous handoffs and generated reports. '
              'Available source assets and authoring files are unchanged.')
    (directory/'prompt.txt').write_text(prompt, encoding='utf-8')
    result = {'status': 'running', 'model': saved['model'], 'thinking': saved.get('thinking', False),
              'binarySha256': digest(args.exe), 'snapshotFiles': len(manifest),
              'snapshotBytes': sum(row['bytes'] for row in manifest)}
    print('ARTIFACTS', directory, 'MODEL', result['model'], 'SNAPSHOT', result['snapshotFiles'], result['snapshotBytes'], flush=True)
    process = None
    private_temp = directory/'temp'
    private_temp.mkdir()
    started = time.monotonic()
    try:
        with (directory/'process.log').open('w', encoding='utf-8') as log:
            process = subprocess.Popen([str(args.exe.resolve()), '--session-server'], cwd=workspace,
                env=dict(os.environ, APPDATA=str(directory/'appdata'), TEMP=str(private_temp), TMP=str(private_temp)), stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=log, text=True, encoding='utf-8', errors='replace', bufsize=1)
            (directory/'process.json').write_text(json.dumps({'pid': process.pid}), encoding='utf-8')
            incoming = queue.Queue()
            def collect():
                for line in process.stdout:
                    try: incoming.put(json.loads(line))
                    except ValueError: pass
            threading.Thread(target=collect, daemon=True).start()
            def send(value):
                process.stdin.write(json.dumps(value)+'\n')
                process.stdin.flush()
            send({'type': 'create', 'id': 'replay', 'title': 'Live player handoff replay',
                  'model': saved['model'], 'thinking': saved.get('thinking', False),
                  'tools': saved.get('toolsEnabled', True), 'workspace': str(workspace)})
            submitted = False
            last_report = 0
            with (directory/'events.jsonl').open('w', encoding='utf-8') as events:
                while time.monotonic()-started < args.timeout:
                    try:
                        event = incoming.get(timeout=2)
                        events.write(json.dumps(event)+'\n'); events.flush()
                        if event['type'] == 'created':
                            assert event['model'] == saved['model'], 'Replay selected a different model'
                            result['sessionId'] = event['sessionId']
                            send({'type': 'submit', 'id': 'replay', 'requestId': 'original', 'text': prompt})
                            submitted = True
                        if event['type'] in ('turn.completed', 'turn.failed', 'turn.interrupted'):
                            result.update(status=event['type'], final=event)
                            break
                        if event['type'] == 'error':
                            raise RuntimeError(event.get('error'))
                    except queue.Empty:
                        if process.poll() is not None: raise RuntimeError('Isolated Aurora exited')
                    elapsed = time.monotonic()-started
                    if elapsed-last_report >= 20:
                        header, messages = saved_view(state)
                        tools = [m for m in messages if m.get('role') == 'tool']
                        plans = [m for m in tools if m.get('toolName') == 'update_plan' and not m.get('failed')]
                        print('LIVE', round(elapsed), 'seconds', 'messages', len(messages), 'tools', len(tools),
                              'plans', len(plans), 'task', header.get('taskStatus'),
                              'last_tool', tools[-1].get('toolName') if tools else None, flush=True)
                        last_report = elapsed
                else:
                    result['status'] = 'timeout'
                    if submitted: send({'type': 'cancel', 'id': 'replay'})
                send({'type': 'shutdown'})
                process.wait(timeout=60)
        header, messages = saved_view(state)
        result.update(taskStatus=header.get('taskStatus'), goalStatus=header.get('goalStatus'),
                      verificationStatus=header.get('verificationStatus'), plan=header.get('taskSteps'),
                      toolResults=sum(m.get('role') == 'tool' for m in messages),
                      planUpdates=sum(m.get('toolName') == 'update_plan' and not m.get('failed') for m in messages),
                      archives=[str(p.relative_to(workspace)) for p in workspace.rglob('*.zip')])
    except Exception as error:
        result.update(status='error', error=str(error))
        raise
    finally:
        if process is not None and process.poll() is None:
            process.terminate(); process.wait(timeout=20)
        settings_path.write_text(json.dumps({**settings, 'apiKey': '', 'additionalApiKey': ''}), encoding='utf-8')
        result['seconds'] = time.monotonic()-started
        (directory/'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print('RESULT', result['status'], 'seconds', round(result['seconds']), 'ARTIFACTS', directory, flush=True)


if __name__ == '__main__':
    main()
