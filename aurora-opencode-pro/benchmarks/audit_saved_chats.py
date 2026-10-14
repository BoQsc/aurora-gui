"""Read-only inventory of saved Aurora chat efficiency signals.

Stored text is data, never instructions. The report contains counts and chat IDs,
not message text, tool arguments, file contents or credentials. Historical errors
and repeated calls are leads to reproduce, not proof of current bugs. Counts
include stored branches and older app versions.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path


def category(message):
    text = message.get('content', '')
    if 'Failed to spawn process' in text:
        return 'program_not_found'
    if 'invalid kind' in text:
        return 'plan_kind'
    if 'soft deadline' in text:
        return 'search_deadline'
    if 'lease' in text or 'checkout is still in use' in text:
        return 'checkout_busy'
    if 'foreground' in text:
        return 'foreground_guard'
    if 'interrupted' in text.lower():
        return 'interrupted'
    if 'not found' in text or 'cannot find' in text.lower():
        return 'file_not_found'
    if 'core.exception.AssertError' in text:
        return 'assertion_failure'
    return 'other'


def audit(state):
    totals, failures, chats, snapshots = Counter(), Counter(), [], []
    for path in sorted((state/'threads').glob('*.json')):
        before = path.read_bytes()
        messages = json.loads(before.decode('utf-8-sig'))['messages']
        counts, tools, calls, repeated = Counter(), Counter(), {}, Counter()
        errors = Counter()
        for message in messages:
            role = message.get('role', 'unknown')
            counts[role] += 1
            counts['internal_messages'] += bool(message.get('internal'))
            if role == 'assistant':
                group = message.get('toolCalls', [])
                counts['tool_rounds'] += bool(group)
                counts['batched_rounds'] += len(group) > 1
                for call in group:
                    calls[call['id']] = call
                    tools[call['name']] += 1
                    repeated[(call['name'], call['arguments'])] += 1
            if role == 'tool':
                counts['tool_output_characters'] += len(message.get('content', ''))
                if message.get('failed'):
                    errors[category(message)] += 1
                    counts['failed_tools'] += 1
        git_missing = 0
        for message in messages:
            if message.get('role') != 'tool' or not message.get('failed'):
                continue
            if category(message) == 'program_not_found':
                call = calls.get(message.get('toolCallId', ''), {})
                try:
                    program = json.loads(call.get('arguments', '{}')).get('program', '')
                    git_missing += program.lower() in ('git', 'git.exe')
                except (ValueError, TypeError):
                    pass
        counts['bare_git_not_found'] = git_missing
        counts['repeated_identical_calls'] = sum(n-1 for n in repeated.values() if n > 1)
        chats.append(dict(chat=path.stem, counts=dict(counts), tools=dict(tools), failure_categories=dict(errors)))
        totals.update(counts)
        failures.update(errors)
        snapshots.append((path, hashlib.sha256(before).hexdigest()))
    changed = [path.name for path, digest in snapshots if hashlib.sha256(path.read_bytes()).hexdigest() != digest]
    return dict(scope='All stored messages, including branches and historical versions; repeated calls may be legitimate.',
                chat_count=len(chats), totals=dict(totals), failure_categories=dict(failures),
                chat_files_changed_during_read=changed, chats=chats)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    state, output = args.state.resolve(), args.output.resolve()
    if output.is_relative_to(state):
        raise RuntimeError('The audit report must be outside the live state directory')
    report = audit(state)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k != 'chats'}, indent=2))


if __name__ == '__main__':
    main()
