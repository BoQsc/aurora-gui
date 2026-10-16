"""Interleaved latency sweep across the DeepSeek V4.1 variants the endpoint serves.

Reuses benchmarks/latency.py's credential loading, transport and timing fields so
numbers are comparable with the existing latency reports. Credentials are never
written to the report; only timings, sizes, token usage and errors are stored.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from latency import credentials, probe  # noqa: E402

MODELS = [
    'deepseek/deepseek-v4.1-flash',
    'deepseek/deepseek-v4.1-flash-fast',
]

TINY = 'Reply with exactly OK. Do not explain.'
LONG = ('Write consecutive integers starting at 1, one per line, separated by\n'
        'single spaces on a single line. Do not stop early and do not explain.')

# How Aurora actually disables thinking. `reasoning_effort: "off"` is the
# CommandCode wire shape (see buildChatBody in provideradapter.d); the older
# `thinking: {type: disabled}` switch is accepted but ignored by this endpoint,
# which is why reasoning tokens still appear under it.
THINKING_OFF = {
    'off': {'reasoning_effort': 'off'},
    'disabled': {'thinking': {'type': 'disabled'}},
    'none': {'reasoning_effort': 'none'},
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--models', default=','.join(MODELS))
    parser.add_argument('--thinking-off', default='off', choices=sorted(THINKING_OFF))
    parser.add_argument('--reasoning-effort', default='',
                        help="thinking ON with this effort (low/medium/high); "
                             "overrides --thinking-off")
    parser.add_argument('--client', type=Path,
                        help="drive Aurora's real WinINet client instead of curl")
    args = parser.parse_args()

    base, key = credentials()
    if not key:
        raise RuntimeError('Configure an Aurora API key or AURORA_BENCH_KEY')
    models = [m.strip() for m in args.models.split(',') if m.strip()]

    results = []
    # Round-robin across models so load drift does not favour whichever runs first.
    for attempt in range(args.repeats):
        order = models if attempt % 2 == 0 else list(reversed(models))
        for model in order:
            for case, prompt in (('tiny', TINY), ('long', LONG)):
                body = {
                    'model': model,
                    'stream': True,
                    'stream_options': {'include_usage': True},
                    'messages': [{'role': 'user', 'content': prompt}],
                    **(dict(reasoning_effort=args.reasoning_effort)
                       if args.reasoning_effort
                       else THINKING_OFF[args.thinking_off]),
                }
                session = 'aurora-latency-' + str(uuid.uuid4())
                started = time.monotonic()
                if args.client:
                    # The client takes the same body shape and reports its own
                    # WinINet send/header/first-byte breakdown.
                    with tempfile.TemporaryDirectory(
                            prefix='aurora-latency-client-') as directory:
                        scenario = Path(directory) / 'scenario.json'
                        body['image_files'] = []
                        body['image_mimes'] = []
                        scenario.write_text(json.dumps(body), encoding='utf-8')
                        env = os.environ.copy()
                        env['AURORA_BENCH_KEY'] = key
                        run = subprocess.run(
                            [str(args.client.resolve()), base, session, str(scenario)],
                            env=env, capture_output=True, text=True, timeout=120)
                        if run.returncode:
                            measured = {'errors': [run.stderr[:1600]], 'exit_code':
                                        run.returncode}
                        else:
                            measured = json.loads(run.stdout)
                            measured['first_token_s'] = round(
                                measured.get('first_token_ms', -1) / 1000.0, 4)
                            measured['total_s'] = round(
                                measured.get('total_ms', 0) / 1000.0, 4)
                else:
                    measured = probe(base, key, body, session)
                measured['wall_s'] = round(time.monotonic() - started, 4)
                record = {'model': model, 'case': case, 'attempt': attempt + 1,
                          'thinking_off': args.thinking_off,
                          'reasoning_effort': args.reasoning_effort or None,
                          'transport': 'aurora' if args.client else 'curl',
                          'reasoning_tokens': measured.get('usage', {})
                              .get('completion_tokens_details', {})
                              .get('reasoning_tokens'),
                          'prompt_chars': len(prompt), **measured}
                results.append(record)
                print(json.dumps({k: record.get(k) for k in (
                    'model', 'case', 'attempt', 'thinking_off', 'transport',
                    'http_status', 'first_token_s', 'first_content_s',
                    'reasoning_tokens', 'content_chars', 'content_chars',
                    'sent_ms', 'headers_ms', 'first_byte_ms', 'total_s',
                    'wall_s', 'errors', 'usage')}),
                    flush=True)
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps(results, indent=2), encoding='utf-8')

    print('\nsummary')
    for model in models:
        for case in ('tiny', 'long'):
            rows = [r for r in results
                    if r['model'] == model and r['case'] == case
                    and r.get('first_token_s') is not None]
            if not rows:
                print(f'{model:38s} {case:5s} no successful samples')
                continue
            firsts = sorted(r['first_token_s'] for r in rows)
            totals = sorted(r['total_s'] for r in rows)
            reasons = [r['reasoning_tokens'] for r in rows
                       if r.get('reasoning_tokens') is not None]
            print(f'{model:38s} {case:5s} n={len(rows)} '
                  f'first_token median={statistics.median(firsts):.3f}s '
                  f'min={firsts[0]:.3f}s max={firsts[-1]:.3f}s '
                  f'| total median={statistics.median(totals):.3f}s'
                  + (f' | reasoning median={statistics.median(reasons)}' if reasons else ''))

    # Paired comparison: samples are interleaved within each round, so match on
    # (attempt, case) and test the per-round differences. Reported with a
    # normalized effect size and a distribution-free sign-test p-value, which
    # needs no normality assumption about provider latency.
    if len(models) == 2:
        print('\npaired comparison ({} vs {})'.format(models[0], models[1]))
        for case in ('tiny', 'long'):
            def by_attempt(model):
                return {r['attempt']: r['first_token_s'] for r in results
                        if r['model'] == model and r['case'] == case
                        and r.get('first_token_s') is not None}
            left, right = by_attempt(models[0]), by_attempt(models[1])
            diffs = [left[a] - right[a] for a in sorted(set(left) & set(right))]
            if not diffs:
                print(f'  {case:5s} no matched pairs')
                continue
            wins = sum(1 for d in diffs if d < 0)
            ties = sum(1 for d in diffs if d == 0)
            effective = len(diffs) - ties
            # Exact two-sided sign test under p=0.5. The tail must be the one
            # *at or beyond* the observed count, not the upper tail: with 11 of
            # 12 wins the evidence is in the small-count tail, so sum P(X <= k)
            # for k = min(wins, effective - wins).
            from math import comb
            if effective:
                extreme = min(wins, effective - wins)
                tail = sum(comb(effective, k) for k in
                           range(extreme + 1)) / 2 ** effective
                p_value = min(1.0, 2 * tail)
            else:
                p_value = 1.0
            mean_diff = statistics.mean(diffs)
            sd = statistics.stdev(diffs) if len(diffs) > 1 else 0.0
            print(f'  {case:5s} pairs={len(diffs)} '
                  f'mean_diff={mean_diff:+.3f}s sd={sd:.3f}s '
                  f'wins_for_{models[0].split("/")[-1]}={wins} '
                  f'wins_for_{models[1].split("/")[-1]}={effective - wins} '
                  f'sign_test_p={p_value:.4f}')


if __name__ == '__main__':
    main()
