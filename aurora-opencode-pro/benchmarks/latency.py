"""Measure OpenCode Go latency without storing credentials or conversation text."""
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import struct
import tempfile
import time
import uuid
import zlib
from pathlib import Path


def credentials():
    settings = json.loads((Path(os.environ['APPDATA']) / 'Aurora OpenCode' /
                           'settings.json').read_text(encoding='utf-8'))
    base = settings['baseUrl'].rstrip('/')
    key = os.environ.get('AURORA_BENCH_KEY', '')
    if not key:
        for entry in settings.get('providerKeys', []):
            if entry.get('baseUrl', '').rstrip('/') == base:
                keys = [entry.get('apiKey', ''), entry.get('additionalApiKey', '')] + entry.get('extraApiKeys', [])
                active = entry.get('activeKeyIndex', int(entry.get('additionalKeyActive', False)))
                key = keys[active] if 0 <= active < len(keys) and keys[active] else keys[0]
                break
    return base, key or settings.get('apiKey', '')


def probe(base, key, body, session):
    started = time.monotonic()
    result = {'request_bytes': len(json.dumps(body).encode()), 'first_event_s': None,
              'first_token_s': None, 'first_content_s': None, 'reasoning_chars': 0,
              'content_chars': 0, 'tool_chars': 0, 'usage': {}, 'errors': []}
    with tempfile.TemporaryDirectory(prefix='aurora-latency-') as directory:
        payload = Path(directory) / 'body.json'
        payload.write_text(json.dumps(body), encoding='utf-8')
        # Credentials go through stdin, never the command line or a file.
        config = '\n'.join([
            'url = ' + json.dumps(base + '/chat/completions'),
            'header = ' + json.dumps('Authorization: Bearer ' + key),
            'header = "Content-Type: application/json"',
            'header = "Accept: text/event-stream"',
            'header = "Expect:"',
            'header = ' + json.dumps('x-opencode-session: ' + session),
            'user-agent = "aurora-opencode/0.66.9"',
        ])
        process = subprocess.Popen(
            ['curl.exe', '--config', '-', '--silent', '--show-error', '--no-buffer',
             '--max-time', '90', '--data-binary', '@' + str(payload),
             '--write-out', '\nMETRICS:%{json}\n'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding='utf-8', errors='replace')
        process.stdin.write(config)
        process.stdin.close()
        for line in process.stdout:
            elapsed = round(time.monotonic() - started, 4)
            if line.startswith('METRICS:'):
                metrics = json.loads(line[8:])
                result['http_status'] = metrics['http_code']
                result['curl'] = {k: metrics.get(k) for k in [
                    'time_namelookup', 'time_connect', 'time_appconnect',
                    'time_pretransfer', 'time_posttransfer', 'time_starttransfer', 'time_total',
                    'size_upload', 'size_download']}
                continue
            if not line.startswith('data:'):
                if line.strip():
                    result['errors'].append(line.strip().replace(key, '[redacted]')[:800])
                continue
            data = line[5:].strip()
            if data == '[DONE]':
                continue
            try:
                event = json.loads(data)
            except ValueError:
                continue
            if result['first_event_s'] is None:
                result['first_event_s'] = elapsed
            if event.get('usage'):
                result['usage'] = event['usage']
            for choice in event.get('choices', []):
                delta = choice.get('delta', {})
                reasoning = delta.get('reasoning_content') or delta.get('reasoning') or ''
                content = delta.get('content') or ''
                tools = delta.get('tool_calls') or []
                if (reasoning or content or tools) and result['first_token_s'] is None:
                    result['first_token_s'] = elapsed
                if content and result['first_content_s'] is None:
                    result['first_content_s'] = elapsed
                result['reasoning_chars'] += len(reasoning)
                result['content_chars'] += len(content)
                result['tool_chars'] += sum(len(c.get('function', {}).get('arguments', '')) for c in tools)
        result['exit_code'] = process.wait()
        error = process.stderr.read().strip()
        if error:
            result['errors'].append(error.replace(key, '[redacted]'))
    result['total_s'] = round(time.monotonic() - started, 4)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repeats', type=int, default=2)
    parser.add_argument('--cases', default='none,disabled,low')
    parser.add_argument('--context-lines', type=int, default=0)
    parser.add_argument('--image', choices=['stored', 'compressed'])
    parser.add_argument('--saved-images', action='store_true',
                        help='Use the two newest images in the active saved chat; never send its text')
    parser.add_argument('--image-files', nargs='+', type=Path,
                        help='Use local PNG/JPEG fixtures without saving their contents in results')
    parser.add_argument('--client', type=Path)
    parser.add_argument('--prompt', default='Reply with exactly OK. Do not explain.')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.repeats < 1 or args.context_lines < 0:
        parser.error('repeats must be positive and context-lines nonnegative')
    if sum(bool(x) for x in [args.saved_images, args.image, args.image_files]) > 1:
        parser.error('choose one image source')
    base, key = credentials()
    if not key:
        raise RuntimeError('Configure an Aurora API key or AURORA_BENCH_KEY')
    session = 'aurora-latency-' + str(uuid.uuid4())
    results = []
    # Identical synthetic pixels in both encodings isolate wire-size cost.
    image = None
    if args.image:
        width, height = 1200, 875
        rows = b''.join(b'\0' + bytes([y % 256, 80, 120]) * width for y in range(height))
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
        png = (b'\x89PNG\r\n\x1a\n' +
               chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) +
               chunk(b'IDAT', zlib.compress(rows, 0 if args.image == 'stored' else 6)) +
               chunk(b'IEND', b''))
        image = base64.b64encode(png).decode()
    images = [image] if image else []
    image_mimes = ['image/png'] * len(images)
    if args.saved_images:
        state = json.loads((Path(os.environ['APPDATA']) / 'Aurora OpenCode' /
                            'sessions.json').read_text(encoding='utf-8'))
        conversation = state['sessions'][state['current']]
        saved = [i for m in conversation['messages']
                 for i in m.get('images', []) if i.get('base64Data')][-2:]
        images = [i['base64Data'] for i in saved]
        image_mimes = [i.get('mimeType', 'image/png') for i in saved]
    if args.image_files:
        for path in args.image_files:
            data = path.read_bytes()
            if data.startswith(b'\xff\xd8\xff'):
                mime = 'image/jpeg'
            elif data.startswith(b'\x89PNG\r\n\x1a\n'):
                mime = 'image/png'
            else:
                parser.error('image fixtures must be PNG or JPEG')
            images.append(base64.b64encode(data).decode('ascii'))
            image_mimes.append(mime)
    for attempt in range(args.repeats):
        for case in args.cases.split(','):
            body = {'model': 'deepseek-v4.1-flash', 'stream': True,
                    'stream_options': {'include_usage': True},
                    'messages': [{'role': 'user', 'content':
                        ''.join(f'Fixture record {i}: alpha beta gamma delta.\n' for i in range(args.context_lines)) +
                        args.prompt}]}
            if case == 'disabled':
                body['thinking'] = {'type': 'disabled'}
            else:
                body['reasoning_effort'] = case
            if args.client:
                with tempfile.TemporaryDirectory(prefix='aurora-latency-client-') as directory:
                    scenario = Path(directory) / 'scenario.json'
                    body['image_files'] = []
                    body['image_mimes'] = image_mimes
                    for index, data in enumerate(images):
                        image_file = Path(directory) / f'image-{index}.txt'
                        image_file.write_text(data, encoding='ascii')
                        body['image_files'].append(str(image_file))
                    scenario.write_text(json.dumps(body), encoding='utf-8')
                    env = os.environ.copy()
                    env['AURORA_BENCH_KEY'] = key
                    run = subprocess.run([str(args.client.resolve()), base, session, str(scenario)],
                                         env=env, capture_output=True, text=True, timeout=100)
                    if run.returncode:
                        measured = {'exit_code': run.returncode, 'completed': False,
                                    'errors': [run.stderr.replace(key, '[redacted]')[:1600]]}
                    else:
                        measured = json.loads(run.stdout)
            else:
                if images:
                    body['messages'][0]['content'] = [
                        {'type': 'text', 'text': body['messages'][0]['content']}] + [
                        {'type': 'image_url', 'image_url': {'url': 'data:' + mime + ';base64,' + data}}
                        for mime, data in zip(image_mimes, images)]
                measured = probe(base, key, body, session)
            result = {'case': case, 'attempt': attempt + 1, 'image': args.image,
                      'saved_images': args.saved_images, 'image_count': len(images),
                      'image_mimes': image_mimes,
                      'transport': 'aurora' if args.client else 'curl',
                      'context_lines': args.context_lines, **measured}
            results.append(result)
            print(json.dumps(result), flush=True)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(results, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
