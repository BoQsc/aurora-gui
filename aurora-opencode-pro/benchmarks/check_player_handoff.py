"""Independent structural and history checks for a real player-handoff replay."""
import argparse
import collections
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import zipfile


def sha(stream):
    return hashlib.file_digest(stream, 'sha256').hexdigest()


def check(directory):
    workspace = directory/'TerraForest'
    state = directory/'appdata/Aurora OpenCode'
    manifest = {r['path']: r for r in json.loads((directory/'snapshot.json').read_text())}
    index = json.loads((state/'threads.index.json').read_text(encoding='utf-8-sig'))
    settings = json.loads((state/'settings.json').read_text(encoding='utf-8-sig'))
    header = next(s for s in index['sessions'] if s.get('title', '').startswith('Live player handoff'))
    messages = json.loads((state/'threads'/(header['id']+'.json')).read_text(encoding='utf-8-sig'))['messages']
    errors = []
    def require(ok, text):
        if not ok: errors.append(text)
    source = (workspace/'addons/characters/runtime/human_view.gd').read_text(encoding='utf-8')
    model = re.search(r'const MODEL\s*=\s*preload\("res://([^"\n]+)"\)', source).group(1)
    blend = 'addons/characters/Human_R11_Complete_Repost/Human.r11.blend'
    target_hashes = {model: manifest[model]['sha256'], blend: manifest[blend]['sha256']}
    archives = [p for p in workspace.rglob('*.zip') if p.relative_to(workspace).as_posix() not in manifest]
    require(bool(archives), 'No new handoff ZIP delivered')
    archive_results = []
    for archive in archives:
        row = {'path': archive.relative_to(workspace).as_posix()}
        with zipfile.ZipFile(archive) as bundle:
            entries = [i for i in bundle.infolist() if not i.is_dir()]
            row['files'] = len(entries)
            require(bundle.testzip() is None, row['path']+': ZIP CRC failure')
            require(len({i.filename for i in entries}) == len(entries), row['path']+': duplicate archive entries')
            for i in entries:
                path = PurePosixPath(i.filename)
                require(not path.is_absolute() and '..' not in path.parts, 'Unsafe archive path: '+i.filename)
            matched = {}
            for original, expected in target_hashes.items():
                candidates = [i for i in entries if PurePosixPath(i.filename).name == Path(original).name]
                for entry in candidates:
                    with bundle.open(entry) as stream:
                        if sha(stream) == expected: matched[original] = entry.filename
                require(original in matched, row['path']+': missing byte-identical source '+original)
            row['matchedSourceAssets'] = matched
            if model in matched:
                with bundle.open(matched[model]) as stream:
                    magic, version, total = struct.unpack('<4sII', stream.read(12))
                    size, kind = struct.unpack('<II', stream.read(8))
                    gltf = json.loads(stream.read(size))
                require(magic == b'glTF' and version == 2 and kind == 0x4E4F534A, 'Invalid runtime GLB')
                joints = [gltf['nodes'][j].get('name') for skin in gltf.get('skins', []) for j in skin['joints']]
                row['rig'] = {'jointCount': len(joints), 'animations': len(gltf.get('animations', [])),
                              'mounts': [x for x in joints if x and ('Weapon_' in x or x == 'RightHand')]}
                require(len(joints) == 59 and len(gltf.get('animations', [])) == 71, 'Unexpected runtime rig or clip set')
                for item in gltf.get('images', [])+gltf.get('buffers', []):
                    uri = item.get('uri', '')
                    require(not uri or uri.startswith('data:') or
                            str(PurePosixPath(matched[model]).parent/uri) in bundle.namelist(),
                            'Unresolved model dependency: '+uri)
            documents = []
            for item in entries:
                if Path(item.filename).suffix.lower() in ('.md', '.txt') and item.file_size < 200_000:
                    text = bundle.read(item).decode('utf-8', errors='replace')
                    documents.append({'path': item.filename, 'text': text})
            row['documents'] = documents
            require(any('handoff' in d['path'].lower() or 'readme' in d['path'].lower() for d in documents),
                    row['path']+': missing handoff instructions')
        archive_results.append(row)
    changed_sources = []
    for name, original in manifest.items():
        if Path(name).suffix.lower() not in {'.blend', '.glb', '.gd', '.tscn', '.tres', '.res'}: continue
        path = workspace/name
        with path.open('rb') as stream:
            if sha(stream) != original['sha256']: changed_sources.append(name)
    require(not changed_sources, 'Packaging unexpectedly modified project model/code assets: '+str(changed_sources))
    plans = []
    failures = []
    tools_since = 0
    max_gap = 0
    for i, message in enumerate(messages):
        if message.get('role') != 'tool': continue
        if message.get('failed'):
            failures.append({'message': i, 'tool': message.get('toolName'), 'output': message.get('content', '')[:1500]})
        if message.get('toolName') == 'update_plan' and not message.get('failed'):
            try: args = json.loads(message.get('toolArgs', '{}'))
            except ValueError: args = {}
            plans.append({'message': i, 'toolsSincePrevious': tools_since, 'args': args})
            max_gap = max(max_gap, tools_since); tools_since = 0
        elif message.get('toolName') not in ('process', 'tool_status', 'read_plan'):
            tools_since += 1
    max_gap = max(max_gap, tools_since)
    workspaces = {}
    for line in (state/'logs/errors.log').read_text(encoding='utf-8', errors='replace').splitlines():
        if 'agent-lifecycle ' not in line: continue
        try: event = json.loads(line.split('agent-lifecycle ', 1)[1])
        except ValueError: continue
        if event.get('toolCallId') and event.get('workspace'):
            workspaces[event['toolCallId']] = Path(event['workspace'])
    verification_inputs = []
    tracked_archives = set()
    for message in messages:
        if message.get('toolName') != 'verify' or message.get('failed'): continue
        try:
            receipt = json.loads(message['content'])
            if 'inputs' in receipt and 'workspace' in receipt:
                base = Path(receipt['workspace'])
                values = receipt['inputs']
            else:
                recipe_path = Path(receipt['recipe'])
                recipe = json.loads(recipe_path.read_text(encoding='utf-8'))
                base = workspaces[message['toolCallId']]
                values = recipe['inputs']
            paths = [(base/value).resolve() for value in values]
            verification_inputs.append({'toolCallId': message['toolCallId'], 'paths': [str(p) for p in paths]})
            for archive in archives:
                for path in paths:
                    if archive.resolve() == path or (path.is_dir() and archive.resolve().is_relative_to(path)):
                        tracked_archives.add(str(archive.resolve()))
        except (KeyError, OSError, ValueError):
            pass
    require(all(str(p.resolve()) in tracked_archives for p in archives),
            'An archive was omitted from every accepted verifier input set')
    require(header.get('taskStatus') == 'completed', 'Task did not complete')
    if header.get('goal'):
        require(header.get('goalStatus') == 'completed', 'Explicit persistent goal did not complete')
    require(all(r.get('status') == 'completed' for r in header.get('taskSteps', [])), 'Final checklist stale')
    effort = next((r.get('effort') for r in settings.get('reasoningControls', [])
                   if r.get('model') == header.get('model') and r.get('baseUrl') == settings.get('baseUrl')), None)
    report = {'status': 'passed' if not errors else 'failed', 'errors': errors,
              'model': header.get('model'), 'storedSessionThinking': header.get('thinking'),
              'configuredReasoningEffort': effort,
              'messages': len(messages), 'toolCounts': dict(collections.Counter(m.get('toolName') for m in messages if m.get('role') == 'tool')),
              'taskStatus': header.get('taskStatus'), 'goalStatus': header.get('goalStatus'),
              'verificationStatus': header.get('verificationStatus'), 'maxToolsBetweenPlanUpdates': max_gap,
              'plans': plans, 'failures': failures, 'archives': archive_results,
              'acceptedVerificationInputs': verification_inputs}
    (directory/'independent-check.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k not in ('archives', 'plans', 'failures')}, indent=2))
    print('CHECK', directory/'independent-check.json')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    raise SystemExit(0 if check(args.directory.resolve())['status'] == 'passed' else 1)
