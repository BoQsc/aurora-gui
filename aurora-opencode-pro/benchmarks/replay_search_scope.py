"""Real-provider replay of an existing Aurora chat in an isolated source copy."""
import argparse, hashlib, json, os, queue, shutil, subprocess, threading, time
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]
REPO = PACKAGE.parent
SID = 't-m639298375290728147-406'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', required=True)
    parser.add_argument('--exe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout', type=int, default=600)
    parser.add_argument('--reuse-snapshot', type=Path, help='Reuse a previously hashed isolated source snapshot')
    a = parser.parse_args()
    root = a.output.resolve(); root.mkdir(parents=True, exist_ok=False)
    checkout = root / 'checkout'
    if a.reuse_snapshot:
        source = a.reuse_snapshot.resolve()
        assert source.name.startswith('aurora-search-replay-') and (source/'snapshot.json').is_file()
        checkout = source/'checkout'
    else: checkout.mkdir()
    state = root / 'appdata' / 'Aurora OpenCode'; state.mkdir(parents=True)
    temp = root / 'temp'; temp.mkdir()
    original = Path(os.environ['APPDATA']) / 'Aurora OpenCode'
    saved = json.loads((original / 'settings.json').read_text(encoding='utf-8-sig'))
    chat = json.loads((original / 'threads' / (SID + '.json')).read_text(encoding='utf-8-sig'))
    first = next(m['content'] for m in chat['messages'] if m['role'] == 'user' and not m.get('internal'))
    prompt = first.replace(str(REPO), str(checkout))
    prompt += '\n\nIsolated replay: read only the source copy at the path above. Original locations and other projects are outside this replay. No changes.'
    (root / 'prompt.txt').write_text(prompt, encoding='utf-8')
    # Tracked source plus the real audit-artifact noise encountered by the bad
    # root searches. No binaries, private state/configuration or other projects.
    paths = set(subprocess.check_output(['git', 'ls-files'], cwd=REPO, text=True).splitlines())
    # Project verification recipes are authored inputs, unlike conversation
    # state beneath .aurora. Keep the recipe referenced by MODULES.md.
    recipes = REPO / 'experiments' / 'aurora-host' / '.aurora'
    if recipes.exists():
        paths.update(p.relative_to(REPO).as_posix() for p in recipes.glob('verify*.json') if p.is_file())
    artifacts = REPO / 'artifacts'
    if artifacts.exists():
        for directory, folders, files in os.walk(artifacts, followlinks=False):
            folders[:] = [x for x in folders if x not in {'build', '.git', '.dub', '__pycache__', 'node_modules'}
                          and not (Path(directory) / x).is_symlink()]
            for name in files:
                if Path(name).suffix.lower() in {'.d', '.py', '.md', '.txt', '.json'}:
                    paths.add((Path(directory) / name).relative_to(REPO).as_posix())
    skip_dirs = {'.git', '.dub', '.cache', 'build', 'dist', 'out', 'target', 'node_modules',
                 'coverage', '__pycache__', '.aurora', '.audit-inputs', 'state'}
    skip_extensions = {'.exe', '.dll', '.pdb', '.obj', '.lib', '.o', '.a', '.so', '.dylib',
                       '.bin', '.zip', '.7z', '.rar', '.gz', '.tar', '.png', '.jpg', '.jpeg',
                       '.gif', '.webp', '.ico', '.pdf', '.mp3', '.mp4', '.wav', '.woff', '.woff2',
                       '.ttf', '.otf', '.db', '.sqlite', '.class', '.jar', '.pyc', '.log', '.pem', '.key'}
    manifest = {}; total = 0
    if a.reuse_snapshot:
        manifest = json.loads((a.reuse_snapshot/'snapshot.json').read_text())
        for relative, expected in manifest.items():
            assert digest(checkout/relative)==expected, relative
            total += (checkout/relative).stat().st_size
        paths = set()
    for relative in sorted(paths):
        path = Path(relative); source = REPO / path
        recipe = '.aurora' in path.parts and path.name.startswith('verify') and path.suffix=='.json'
        if any((part.lower() in skip_dirs and not (part=='.aurora' and recipe)) or
               'terraforest' in part.lower() for part in path.parts): continue
        if path.suffix.lower() in skip_extensions or source.is_symlink() or not source.is_file(): continue
        if path.name.lower() in {'settings.json', '.env'} or ('publish' in path.name.lower() and path.suffix == '.json'): continue
        if source.stat().st_size > 8 * 1024 * 1024: continue
        raw = source.read_bytes()
        if b'\0' in raw[:8192]: continue
        total += len(raw)
        if total > 1024 * 1024 * 1024: raise RuntimeError('Source snapshot exceeds 1 GiB')
        target = checkout / path; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(raw)
        manifest[relative] = hashlib.sha256(raw).hexdigest()
    (root / 'snapshot.json').write_text(json.dumps(manifest, indent=2))
    if not a.reuse_snapshot: subprocess.run(['git', 'init', '-q', str(checkout)], check=True)
    if subprocess.run(['git','-C',str(checkout),'rev-parse','--verify','HEAD'], capture_output=True).returncode:
        subprocess.run(['git','-C',str(checkout),'add','.'],check=True,capture_output=True)
        subprocess.run(['git','-C',str(checkout),'-c','user.name=Isolated replay','-c','user.email=replay@localhost',
                        'commit','-qm','Isolated source snapshot'],check=True,capture_output=True)
    print('SNAPSHOT', len(manifest), 'files', total, 'bytes', 'ARTIFACTS', root, flush=True)
    opening = [c for m in chat['messages'][:6] for c in m.get('toolCalls', []) if c['name'] == 'grep']
    assert len(opening) == 2
    calls_path = root / 'opening-calls.json'; calls_path.write_text(json.dumps(opening))
    subprocess.run([str(a.exe.resolve()), '--probe', str(checkout), str(calls_path), str(root / 'opening-results.json')],
                   cwd=checkout, timeout=30, check=True, env=dict(os.environ, TEMP=str(temp), TMP=str(temp)))
    probes = json.loads((root / 'opening-results.json').read_text())
    assert len(probes) == 4 and all(not row['failed'] for row in probes), probes
    for row in probes[::2]:
        output = json.loads(row['output'])
        assert output['status'] == 'scope_selection' and output['contentsSearched'] is False
        assert output['suggestedSearches'][0]['path'].replace('\\', '/').endswith('/experiments/aurora-host')
        assert row['elapsedMs'] < 5000
    print('EXACT_OPENING_PROBES_MS', [x['elapsedMs'] for x in probes], flush=True)
    settings = {**saved, 'workspace': str(checkout), 'quickTitle': False, 'composerSuggestion': False,
                'developerMode': False, 'developerSourceDir': str(root / 'inactive-source'),
                'developerRequireLatestSource': False, 'nativeOnly': True}
    settings_path = state / 'settings.json'; settings_path.write_text(json.dumps(settings))
    result = {'status': 'running', 'chatId': SID, 'model': saved['model'], 'files': len(manifest),
              'snapshotBytes': total, 'binarySha256': digest(a.exe)}
    process = None; started = time.monotonic()
    def history():
        try:
            index = json.loads((state / 'threads.index.json').read_text(encoding='utf-8-sig'))
            h = index['sessions'][0]
            return h, json.loads((state / 'threads' / (h['id'] + '.json')).read_text(encoding='utf-8-sig'))['messages']
        except (OSError, ValueError, KeyError, IndexError): return {}, []
    try:
        with (root / 'process.log').open('w', encoding='utf-8') as log:
            process = subprocess.Popen([str(a.exe.resolve()), '--session-server'], cwd=checkout,
                env=dict(os.environ, APPDATA=str(root / 'appdata'), TEMP=str(temp), TMP=str(temp), FORGE_PUBLISH_SKIP='1'),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True, encoding='utf-8', errors='replace', bufsize=1)
            incoming = queue.Queue()
            def collect():
                for line in process.stdout:
                    try: incoming.put(json.loads(line))
                    except ValueError: pass
            threading.Thread(target=collect, daemon=True).start()
            def send(value): process.stdin.write(json.dumps(value) + '\n'); process.stdin.flush()
            send({'type':'create','id':'search','title':'Search scope replay','workspace':str(checkout),
                  'model':saved['model'],'thinking':False,'tools':True})
            last = 0
            with (root / 'events.jsonl').open('w', encoding='utf-8') as events:
                while time.monotonic() - started < a.timeout:
                    try:
                        event = incoming.get(timeout=2); events.write(json.dumps(event)+'\n'); events.flush()
                        if event['type']=='created': send({'type':'submit','id':'search','requestId':'actual-opening','text':prompt})
                        if event['type'] in {'turn.completed','turn.failed','turn.interrupted'}:
                            result.update(status=event['type'],final=event); break
                        if event['type']=='error': raise RuntimeError(event.get('error'))
                    except queue.Empty:
                        if process.poll() is not None: raise RuntimeError('Session server exited')
                    if time.monotonic()-started-last >= 30:
                        h,m=history(); tools=[x for x in m if x.get('role')=='tool']
                        print('LIVE',round(time.monotonic()-started),'tools',len(tools),'last',tools[-1].get('toolName') if tools else None,flush=True)
                        last=time.monotonic()-started
                else: result['status']='timeout'; send({'type':'cancel','id':'search'})
                send({'type':'shutdown'}); process.wait(timeout=45)
        h,m=history(); tools=[x for x in m if x.get('role')=='tool']
        searches=[{'arguments':x.get('toolArgs'),'elapsedMs':x.get('toolElapsedMs'),'failed':bool(x.get('failed')),
                   'output':x.get('content','')} for x in tools if x.get('toolName')=='grep']
        result.update(toolResults=len(tools),failedTools=sum(bool(x.get('failed')) for x in tools),searches=searches)
        assert result['status']=='turn.completed', result['status']
        assert any('experiments/aurora-host' in json.dumps(x).replace('\\\\','/') for x in tools), 'Target project never inspected'
        assert all((x['elapsedMs'] or 0)<15000 for x in searches), 'A search again blocked the opening for more than 15 seconds'
        assert not any(x.get('toolName') in {'write','edit','apply_patch','remove','move','rename','rebuild','sync'} for x in tools)
        for relative, expected in manifest.items(): assert digest(checkout/relative)==expected, relative
        result['independentPassed']=True
    except Exception as error:
        result.update(status='replay.failed',error=str(error)); raise
    finally:
        if process is not None and process.poll() is None: process.terminate(); process.wait(timeout=15)
        settings_path.unlink(missing_ok=True)
        result['seconds']=time.monotonic()-started
        (root/'result.json').write_text(json.dumps(result,indent=2))
        print('RESULT',result['status'],round(result['seconds'],2),'TOOLS',result.get('toolResults'),'ARTIFACTS',root,flush=True)


if __name__=='__main__': main()
