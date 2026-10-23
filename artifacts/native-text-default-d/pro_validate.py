"""Exercise actual OpenCode Pro markdown and chat widgets in isolated outputs."""
import hashlib
import json
import subprocess

from PIL import Image
import promotion as p


def main():
    folder = p.BUILD/'pro'
    folder.mkdir(exist_ok=True)
    (folder/'build').mkdir(exist_ok=True)
    records = []
    env = p.environment()
    for fixture in ['filesystem_host', 'chat_consistency_smoke', 'headless_pro_smoke']:
        exe = folder/(fixture+'.exe')
        command = ['dmd', '-i', '-O', '-version=AuroraHeadless',
                   '-I'+str(p.CORE/'source'),
                   '-I'+str(p.ROOT/'aurora-opencode-core/source'),
                   '-I'+str(p.ROOT/'aurora-opencode-pro/source'),
                   '-I'+str(p.ROOT/'aurora-opencode-pro/shared'),
                   '-J'+str(p.ROOT/'aurora-opencode-pro/assets'),
                   '-od='+str(folder), '-of='+str(exe),
                   str(p.ROOT/'aurora-opencode-pro/tests'/(fixture+'.d')),
                   'user32.lib', 'gdi32.lib', 'shell32.lib', 'wininet.lib', 'winmm.lib']
        result = subprocess.run(command, cwd=folder, capture_output=True, text=True)
        records.append({'fixture': fixture, 'stage': 'compile',
                        'exit_code': result.returncode, 'output': result.stdout+result.stderr})
        if result.returncode:
            break
        if fixture == 'filesystem_host':
            env['AURORA_FILESYSTEM_HOST'] = str(exe)
            continue
        result = subprocess.run([str(exe)], cwd=folder, env=env, capture_output=True,
                                text=True, encoding='utf-8', errors='replace', timeout=240)
        records.append({'fixture': fixture, 'stage': 'run',
                        'binary_sha256': hashlib.sha256(exe.read_bytes()).hexdigest(),
                        'exit_code': result.returncode, 'output': result.stdout+result.stderr})
        print(fixture, result.returncode, flush=True)
        if result.returncode:
            print(result.stdout[-3500:], result.stderr[-1500:], flush=True)
            control_env = p.environment('C')
            control_env['AURORA_FILESYSTEM_HOST'] = env['AURORA_FILESYSTEM_HOST']
            control = subprocess.run([str(exe)], cwd=folder, env=control_env,
                                     capture_output=True, text=True, encoding='utf-8',
                                     errors='replace', timeout=240)
            records.append({'fixture': fixture, 'stage': 'C-control',
                            'exit_code': control.returncode,
                            'output': control.stdout+control.stderr})
            print(fixture, 'previous C control', control.returncode, flush=True)
    (p.HERE/'pro-validation.json').write_text(json.dumps(records, indent=2))
    exe = p.compile('chat-current', p.HERE/'chat_probe.d')
    image = p.BUILD/'chat-current.ppm'
    result = subprocess.run([str(exe), str(image)], env=p.environment(),
                            check=True, capture_output=True, text=True)
    print(result.stdout, flush=True)
    current = Image.open(image).convert('RGB')
    before = Image.open(p.HERE/'chat-before-refined-D.png').convert('RGB')
    assert before.tobytes() == current.tobytes()
    current.save(p.HERE/'chat-default.png')
    print('Actual chat markdown: default equals preserved refined D.', flush=True)


if __name__ == '__main__':
    main()
