"""Controlled provider over Aurora's actual conversation/tool/verification loop.

All tasks, credentials and workspaces are synthetic. The provider repeats a
compiler check only when Aurora reopens verification after a completed plan.
"""
import argparse
import base64
import collections
import hashlib
import http.server
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline',type=Path,required=True)
parser.add_argument('--candidate',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--modes',nargs='+',default=['readonly','retire','mutating','oversized'])
parser.add_argument('--delays',nargs='+',type=float,default=[0,0.25,1.0])
args=parser.parse_args()
args.baseline=args.baseline.resolve();args.candidate=args.candidate.resolve();args.output=args.output.resolve()
cases={};counts=collections.Counter();pairing_errors=[]


def call(identity,name,arguments):
    return dict(id=identity,type='function',function=dict(name=name,arguments=json.dumps(arguments)))


def message_text(message):
    content=message.get('content','')
    return content if isinstance(content,str) else '\n'.join(part.get('text','') for part in content if part.get('type')=='text')


class Server(http.server.ThreadingHTTPServer):
    daemon_threads=True
    def handle_error(self,request,address):
        if not isinstance(__import__('sys').exc_info()[1],(ConnectionResetError,BrokenPipeError,ConnectionAbortedError)):
            super().handle_error(request,address)


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*_):pass
    def send(self,payload,kind='application/json'):
        raw=payload.encode();self.send_response(200);self.send_header('Content-Type',kind)
        self.send_header('Content-Length',str(len(raw)));self.send_header('Connection','close');self.end_headers()
        try:self.wfile.write(raw);self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError,ConnectionAbortedError):pass
    def do_GET(self):self.send(json.dumps({'data':[{'id':k} for k in cases]}))
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        model=body['model'];counts[model]+=1;case=cases[model]
        owners=set();results={}
        for message in body['messages']:
            for c in message.get('tool_calls',[]):owners.add(c['id'])
            if message['role']=='tool':
                identity=message['tool_call_id']
                if identity not in owners or identity in results:pairing_errors.append('Unpaired/duplicate tool result')
                results[identity]=message['content']
        statuses=[]
        for message in body['messages']:
            statuses.extend(line.strip() for line in message_text(message).splitlines() if line.strip().startswith('Verification:'))
        case.setdefault('requests',[]).append(dict(number=counts[model],tool_results=list(results),verification=statuses[-1:] ,tools_enabled=bool(body.get('tools'))))
        tools=[];content=''
        compile_args=dict(program=case['compiler'],args=['-of'+str(case['workspace']/'probe.exe'),str(case['workspace']/'app.d')],
                          workdir=str(case['workspace']),timeout=10000)
        steps=[dict(step='Implement fixture',status='completed',kind='edit'),
               dict(step='Compile and inspect',status='completed',kind='verify')]
        if 'edit' not in results:
            active=[dict(step='Implement fixture',status='in_progress',kind='edit'),dict(step='Compile and inspect',status='pending',kind='verify')]
            code=('import std.stdio; void main() { writeln(2); }\n' if case['mode']!='mutating' else
                  'import std.stdio; import std.file; void main() { std.file.write("data.txt", "changed"); writeln(2); }\n')
            tools=[call('plan','update_plan',{'plan':active}),call('edit','write',{'filePath':'app.d','content':code})]
        elif 'compile' not in results:tools=[call('compile','run',compile_args)]
        elif case['mode']=='retire' and 'image' not in results:
            tools=[call('image','view_image',dict(filePath=str(case['workspace']/'fixture.png')))]
        elif 'inspect' not in results:
            if case['mode']=='retire':
                image_ids=re.findall(r'\[Image ([^\s]+): fixture\.png;', '\n'.join(message_text(m) for m in body['messages']))
                assert image_ids, 'view_image must provide an actual image reference on this branch'
                tools=[call('inspect','retire_images',dict(imageIds=[image_ids[-1]],summary='Fixture visual facts retained.'))]
            else:tools=[call('inspect','run',dict(program=str(case['workspace']/'probe.exe'),args=[],timeout=5000))]
        elif 'complete' not in results:tools=[call('complete','update_plan',{'plan':steps})]
        else:
            final_already=any(m['role']=='assistant' and m.get('content')=='Done:2' for m in body['messages'])
            if final_already and 'recheck' not in results:tools=[call('recheck','run',compile_args)]
            else:content='Done:2'
        time.sleep(case['delay'])
        first={'choices':[{'delta':{'tool_calls':[dict(index=i,**c) for i,c in enumerate(tools)]} if tools else {'content':content},'finish_reason':None}]}
        last={'choices':[{'delta':{},'finish_reason':'tool_calls' if tools else 'stop'}]}
        self.send('data: '+json.dumps(first)+'\n\ndata: '+json.dumps(last)+'\n\ndata: [DONE]\n\n','text/event-stream')


server=Server(('127.0.0.1',0),Provider)
threading.Thread(target=server.serve_forever,daemon=True).start()
report=dict(scope='Actual app loop, controlled local provider delays; no live model speed claim.',
            binaries={p:hashlib.sha256(getattr(args,p).read_bytes()).hexdigest() for p in ['baseline','candidate']},runs=[])
try:
    for delay in args.delays:
        for mode in args.modes:
            for profile in (['baseline','candidate'] if delay!=0.25 else ['candidate','baseline']):
                with tempfile.TemporaryDirectory(prefix='aurora-command-rounds-') as directory:
                    root=Path(directory);workspace=root/'workspace';workspace.mkdir();state=root/'state'
                    (workspace/'app.d').write_text('import std.stdio; void main() { writeln(1); }\n',encoding='utf-8')
                    (workspace/'data.txt').write_text('original')
                    if mode=='retire':
                        (workspace/'fixture.png').write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=='))
                    if mode=='oversized':
                        with (workspace/'large.bin').open('wb') as f:f.truncate(17*1024*1024)
                    model=f'{profile}-{mode}-{delay}'
                    cases[model]=dict(mode=mode,delay=delay,workspace=workspace,compiler=shutil.which('dmd'))
                    prompt=root/'prompt.txt';prompt.write_text('Change the fixture to print 2, compile it, inspect it, complete the plan, and report Done:2. Keep unrelated files intact.')
                    env=dict(os.environ,AURORA_BENCH_BASE=f'http://127.0.0.1:{server.server_port}/v1',AURORA_BENCH_KEY='fixture',AURORA_BENCH_EFFORT='low')
                    began=time.monotonic()
                    process=subprocess.run([str(getattr(args,profile)),str(workspace),str(state),str(prompt),model,'35'],
                                           cwd=root,env=env,capture_output=True,text=True,errors='replace',timeout=45)
                    elapsed=time.monotonic()-began
                    messages=[]
                    for path in (state/'threads').glob('*.json'):messages.extend(json.loads(path.read_text(encoding='utf-8'))['messages'])
                    assistants=[m for m in messages if m['role']=='assistant'];tools=[m for m in messages if m['role']=='tool']
                    final=assistants[-1].get('content','') if assistants else ''
                    rechecks=sum(c['id']=='recheck' for m in assistants for c in m.get('toolCalls',[]))
                    lifecycle=[]
                    log=state/'logs/errors.log'
                    if log.exists():
                        for line in log.read_text(encoding='utf-8',errors='replace').splitlines():
                            if 'agent-lifecycle ' in line:
                                try:lifecycle.append(json.loads(line.split('agent-lifecycle ',1)[1]))
                                except ValueError:pass
                    args.output.parent.mkdir(parents=True,exist_ok=True)
                    (args.output.parent/(model+'-trace.json')).write_text(json.dumps(dict(requests=cases[model].get('requests'),lifecycle=lifecycle),indent=2))
                    avoids_recheck=profile=='candidate' and mode in ['readonly','retire']
                    expected=(5 if avoids_recheck else 7)+(mode=='retire')
                    assert process.returncode==0 and final=='Done:2',(model,process.stderr,final)
                    assert not any(m.get('failed') for m in tools),(model,[(m.get('toolName'),m.get('content','')[:100]) for m in tools if m.get('failed')])
                    assert counts[model]==expected,(model,counts[model],expected)
                    assert rechecks==int(not avoids_recheck),(model,rechecks)
                    finished=[event for event in lifecycle if event.get('stage')=='turn.completed']
                    assert finished and finished[-1].get('verificationStatus')=='passed',(model,finished)
                    run=subprocess.run([str(workspace/'probe.exe')],cwd=workspace,capture_output=True,text=True,timeout=5)
                    assert run.returncode==0 and run.stdout.strip()=='2'
                    assert (workspace/'data.txt').read_text()==('changed' if mode=='mutating' else 'original')
                    row=dict(profile=profile,mode=mode,delay_s=delay,model_requests=counts[model],verification_rechecks=rechecks,
                             seconds=round(elapsed,3),passed=True)
                    report['runs'].append(row);print(json.dumps(row),flush=True)
                    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2))
    assert not pairing_errors,pairing_errors
finally:server.shutdown();server.server_close()
