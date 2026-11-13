"""Opt-in real-provider recorder tasks from the reported chats; historical copies only."""
import argparse, hashlib, io, json, os, queue, shutil, subprocess, threading, time, zipfile
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]
REPO = PACKAGE.parent
CHAT = 't-m639300051903800675-1863'
TASKS = {
    'timing': ('01da5d0', 4652),
    'picker': ('01da5d0', 3433),
}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--live', action='store_true', required=True)
    ap.add_argument('--task', choices=TASKS, required=True)
    ap.add_argument('--exe', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--timeout', type=int, default=900)
    ap.add_argument('--reuse-copy', type=Path, help='Continue a previously completed isolated implementation')
    ap.add_argument('--feedback', type=Path, help='Independent observed failure supplied with the real follow-up')
    a = ap.parse_args()
    root = a.output.resolve(); root.mkdir(parents=True, exist_ok=False)
    checkout = root/'checkout'; checkout.mkdir()
    ref, message = TASKS[a.task]
    raw = subprocess.check_output(['git','archive','--format=zip',ref,
                                  'aurora-video-recorder','vendor/aurora-d-0.4.5'], cwd=REPO)
    manifest = {}
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        for item in archive.infolist():
            path = Path(item.filename)
            if item.is_dir() or any(x in {'.dub','build','bin','.aurora'} for x in path.parts): continue
            if path.suffix.lower() in {'.exe','.dll','.obj','.pdb','.log','.zip'}: continue
            target = checkout/path; target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(item)); manifest[path.as_posix()] = digest(target)
    if a.reuse_copy:
        shutil.copytree(a.reuse_copy.resolve()/'checkout', checkout, dirs_exist_ok=True,
            ignore=shutil.ignore_patterns('.git','build','.dub','__pycache__','*.exe','*.obj','*.mp4','*.log'))
    if a.feedback:
        message = 4856 if a.task == 'timing' else 3580
        if a.task == 'timing':
            for name in ['recorder_timing_acceptance.d','recorder_backpressure.d']:
                shutil.copyfile(PACKAGE/'benchmarks'/name, checkout/'aurora-video-recorder/tests'/name)
            script = (PACKAGE/'benchmarks/check_recorder_timing.py').read_text()
            script = script.replace("ws=root/'checkout/aurora-video-recorder'", 'ws=PACKAGE')
            script = script.replace("PACKAGE/'benchmarks/recorder_backpressure.d'", "PACKAGE/'tests/recorder_backpressure.d'")
            script = script.replace("PACKAGE/'benchmarks/recorder_timing_acceptance.d'", "PACKAGE/'tests/recorder_timing_acceptance.d'")
            (checkout/'aurora-video-recorder/tests/test_independent_timing.py').write_text(script)
        else:
            script = (PACKAGE/'benchmarks/check_recorder_picker.py').read_text().replace("ws=root/'checkout/aurora-video-recorder'", 'ws=PACKAGE')
            (checkout/'aurora-video-recorder/tests/test_independent_picker.py').write_text(script)
    manifest={p.relative_to(checkout).as_posix():digest(p) for p in checkout.rglob('*') if p.is_file()}
    (root/'snapshot.json').write_text(json.dumps(manifest, indent=2))
    subprocess.run(['git','init','-q',str(checkout)], check=True)
    subprocess.run(['git','-C',str(checkout),'add','.'], check=True, capture_output=True)
    subprocess.run(['git','-C',str(checkout),'-c','user.name=Replay','-c','user.email=replay@localhost',
                    'commit','-qm','Historical isolated input'], check=True)
    workspace = checkout/'aurora-video-recorder'
    original = Path(os.environ['APPDATA'])/'Aurora OpenCode'
    chat = json.loads((original/'threads'/(CHAT+'.json')).read_text(encoding='utf-8-sig'))
    request = chat['messages'][message]['content']
    assert chat['messages'][message]['role'] == 'user'
    context = ('The existing MP4 recorder produces recordings that play too fast. Compare wall-clock capture duration against encoded video duration, including slow capture and stopping. '
               if a.task == 'timing' else
               'The recorder window picker is unreliable: clicking a different target selects the wrong application. Fix the actual picker interaction and layout, preserving correct enumeration and capture. ')
    request = context+'\nActual user report: '+request+'\nProject: '+str(workspace)
    if a.feedback:
        command = 'python tests/test_independent_'+a.task+'.py build/acceptance'
        request += ('\nIndependent observed failure:\n'+a.feedback.read_text()+
            '\nRun '+command+' first to reproduce, fix the implementation, then pass that same unmodified independent check. '
            'The supplied test_independent_'+a.task+'.py and recorder_* acceptance sources are acceptance inputs; preserve them unchanged.')

    request += ('\nChild process TEMP and TMP are '+str(root/'temp')+'. Inspect that directory for test outputs; never assume the original user TEMP.\nThis is an isolated historical replay. Work only inside '+str(checkout)+
                '. No original project reads, desktop computer use, focus changes, external window launches, publishing, sync or rebuild. '
                'Do not inspect other projects or chats. Local isolated compiler outputs and offscreen widget tests are allowed. '
                'Fix the reported behavior, check the real implementation, and finish without adding unrelated features. '
                'Use the installed FFmpeg tools on PATH when necessary. Do not rewrite tests just to make them pass.')
    (root/'prompt.txt').write_text(request, encoding='utf-8')
    saved = json.loads((original/'settings.json').read_text(encoding='utf-8-sig'))
    state = root/'appdata'/'Aurora OpenCode'; state.mkdir(parents=True)
    settings = {**saved, 'workspace':str(workspace), 'quickTitle':False, 'composerSuggestion':False,
                'developerMode':False, 'developerSourceDir':str(root/'inactive-source'),
                'developerRequireLatestSource':False, 'developerAutoReapply':False}
    settings_file = state/'settings.json'; settings_file.write_text(json.dumps(settings))
    temp = root/'temp'; temp.mkdir()
    ffmpeg_dirs = list((Path(os.environ['LOCALAPPDATA'])/'Microsoft/WinGet/Packages').glob('Gyan.FFmpeg_*/ffmpeg-*/bin'))
    env = dict(os.environ, APPDATA=str(root/'appdata'), TEMP=str(temp), TMP=str(temp), FORGE_PUBLISH_SKIP='1', AURORA_TOOL_ROOT=str(root))
    if ffmpeg_dirs: env['PATH'] = str(ffmpeg_dirs[0])+os.pathsep+env['PATH']; env['AURORA_RECORDER_FFMPEG']=str(ffmpeg_dirs[0]/'ffmpeg.exe')
    started = time.monotonic(); process = None
    result = {'task':a.task,'chat':CHAT,'message':message,'ref':ref,'model':saved['model'],
              'binarySha256':digest(a.exe),'status':'running'}
    def history():
        try:
            h = json.loads((state/'threads.index.json').read_text(encoding='utf-8-sig'))['sessions'][0]
            return h, json.loads((state/'threads'/(h['id']+'.json')).read_text(encoding='utf-8-sig'))['messages']
        except (OSError,ValueError,KeyError,IndexError): return {}, []
    print('REPLAY',a.task,'ARTIFACTS',root,flush=True)
    try:
        with (root/'process.log').open('w', encoding='utf-8') as log:
            process = subprocess.Popen([str(a.exe.resolve()),'--session-server'],cwd=workspace,env=env,
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True,encoding='utf-8',errors='replace',bufsize=1)
            incoming = queue.Queue()
            def collect():
                for line in process.stdout:
                    try: incoming.put(json.loads(line))
                    except ValueError: pass
            threading.Thread(target=collect,daemon=True).start()
            def send(value): process.stdin.write(json.dumps(value)+'\n'); process.stdin.flush()
            send({'type':'create','id':'replay','title':'Orchestration '+a.task,'workspace':str(workspace),
                  'model':saved['model'],'thinking':saved.get('thinking',False),'tools':True})
            last = 0
            with (root/'events.jsonl').open('w',encoding='utf-8') as events:
                while time.monotonic()-started < a.timeout:
                    try:
                        event = incoming.get(timeout=2); events.write(json.dumps(event)+'\n'); events.flush()
                        if event['type']=='created': send({'type':'submit','id':'replay','text':request})
                        if event['type'] in {'turn.completed','turn.failed','turn.interrupted'}:
                            result['status']=event['type']; break
                        if event['type']=='error': raise RuntimeError(event.get('error'))
                    except queue.Empty:
                        if process.poll() is not None: raise RuntimeError('Replay process exited')
                    elapsed=time.monotonic()-started
                    if elapsed-last>=30:
                        h,m=history(); tools=[x for x in m if x.get('role')=='tool']
                        print('LIVE',a.task,round(elapsed),'tools',len(tools),'last',tools[-1].get('toolName') if tools else None,flush=True);last=elapsed
                else: result['status']='timeout'; send({'type':'cancel','id':'replay'})
                send({'type':'shutdown'}); process.wait(timeout=45)
        h,m=history(); tools=[x for x in m if x.get('role')=='tool']
        result.update(taskStatus=h.get('taskStatus'),verificationStatus=h.get('verificationStatus'),toolResults=len(tools),
                      failedTools=sum(bool(x.get('failed')) for x in tools),
                      controlMessages=sum(bool(x.get('internal')) for x in m),
                      planUpdates=sum(x.get('toolName')=='update_plan' for x in tools))
        # Audit native path arguments independently of the model's final claims.
        escaped=[]
        for x in tools:
            try: args=json.loads(x.get('toolArgs') or '{}')
            except ValueError: continue
            for key in ['path','filePath','workdir']:
                value=args.get(key)
                if value and Path(value).is_absolute() and not Path(value).resolve().is_relative_to(root): escaped.append((x.get('toolName'),key,value))
        result['escapedPaths']=escaped
        assert not escaped, 'Replay accessed an original project'
        assert not any(x.get('toolName') in {'computer','rebuild','sync'} for x in tools), 'Forbidden replay operation'
    finally:
        if process is not None and process.poll() is None: process.terminate();process.wait(timeout=15)
        settings_file.unlink(missing_ok=True)
        result['seconds']=time.monotonic()-started
        (root/'result.json').write_text(json.dumps(result,indent=2))
        print('RESULT',json.dumps(result),flush=True)

if __name__=='__main__': main()
