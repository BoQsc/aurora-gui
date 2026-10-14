"""Real Continue/Regenerate/queued callbacks after Stop, then native tool delivery."""
import argparse, collections, hashlib, http.server, json, os, subprocess, threading
from pathlib import Path

package=Path(__file__).resolve().parents[1];repo=package.parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--build',action='store_true')
args=parser.parse_args();directory=args.output.resolve().parent;directory.mkdir(parents=True,exist_ok=True)
exe=directory/'resume.exe'
if args.build:
    subprocess.run(['dmd','-i','-I'+str(package/'source'),'-I'+str(package/'shared'),
                    '-I'+str(repo/'aurora-opencode-core/source'),'-I'+str(repo/'vendor/aurora-d-0.4.5/source'),
                    '-J'+str(package/'assets'),'-of'+str(exe),str(package/'tests/resume_tool_handoff_contracts.d'),
                    'user32.lib','gdi32.lib','wininet.lib','shell32.lib','winmm.lib'],cwd=directory,check=True,timeout=180)
    (directory/'provenance.json').write_text(json.dumps(dict(gitHead=subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),
        appuiSha256=hashlib.sha256((package/'source/auroraopencode/appui.d').read_bytes()).hexdigest(),
        fixtureSha256=hashlib.sha256((package/'tests/resume_tool_handoff_contracts.d').read_bytes()).hexdigest()),indent=2),encoding='utf-8')
    raise SystemExit

rounds=collections.Counter();failures=[]
class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*_):pass
    def do_GET(self):self.reply('{"data":[{"id":"resume-fixture"}]}','application/json')
    def reply(self,payload,kind):
        data=payload.encode();self.send_response(200);self.send_header('Content-Type',kind)
        self.send_header('Content-Length',str(len(data)));self.end_headers()
        try:self.wfile.write(data);self.wfile.flush()
        except (ConnectionResetError,BrokenPipeError,ConnectionAbortedError):pass
    def do_POST(self):
        request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        model=request['model'];rounds[model]+=1
        owners=set();results=[]
        for message in request['messages']:
            owners.update(c['id'] for c in message.get('tool_calls',[]))
            if message['role']=='tool':
                identity=message['tool_call_id']
                if identity not in owners or identity in results:failures.append('Unpaired/duplicate result')
                results.append(identity)
        if 'listing' in results:delta={'content':'RESUMED'};finish='stop'
        else:
            delta={'tool_calls':[dict(index=0,id='listing',type='function',function=dict(name='dshell',arguments='{"command":"list"}'))]}
            finish='tool_calls'
        wire='data: '+json.dumps({'choices':[{'delta':delta,'finish_reason':None}]})+'\n\n'
        wire+='data: '+json.dumps({'choices':[{'delta':{},'finish_reason':finish}]})+'\n\ndata: [DONE]\n\n'
        self.reply(wire,'text/event-stream')

class Server(http.server.ThreadingHTTPServer):
    daemon_threads=True
    def handle_error(self,request,address):
        if not isinstance(__import__('sys').exc_info()[1],(ConnectionResetError,BrokenPipeError,ConnectionAbortedError)):
            super().handle_error(request,address)
server=Server(('127.0.0.1',0),Provider)
threading.Thread(target=server.serve_forever,daemon=True).start()
report=dict(executableSha256=hashlib.sha256(exe.read_bytes()).hexdigest(),provenance=json.loads((directory/'provenance.json').read_text()),runs=[])
try:
    for mode in ['continue','regenerate','queued','send']:
        run=directory/args.output.stem/mode;run.mkdir(parents=True,exist_ok=False)
        env=dict(os.environ,AURORA_CONTRACT_PROVIDER_BASE=f'http://127.0.0.1:{server.server_port}/v1',AURORA_RESUME_MODE=mode)
        result=subprocess.run([str(exe)],cwd=run,env=env,capture_output=True,text=True,errors='replace',timeout=20)
        (run/'fixture.log').write_text(result.stdout+result.stderr,encoding='utf-8')
        path=run/'result.json'
        row=json.loads(path.read_text(encoding='utf-8')) if path.exists() else dict(mode=mode,passed=False,error=(result.stdout+result.stderr)[-1500:])
        row['requests']=rounds['resume-'+mode];row['exitCode']=result.returncode
        report['runs'].append(row);print(json.dumps(row),flush=True)
        args.output.write_text(json.dumps(report,indent=2),encoding='utf-8')
    assert not failures,failures
    assert all(r['passed'] and r['requests']==2 for r in report['runs'])
finally:server.shutdown();server.server_close()
