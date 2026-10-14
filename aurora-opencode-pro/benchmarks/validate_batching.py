"""Actual Aurora GUI/tool loop with controlled response delays and dependencies."""
import argparse
import collections
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args(); args.app=args.app.resolve(); args.output=args.output.resolve()
counts=collections.Counter(); failures=[]; delays={}; records=[]


def call(identity,name,arguments):
    return dict(id=identity,type='function',function=dict(name=name,arguments=json.dumps(arguments)))


class Server(http.server.ThreadingHTTPServer):
    daemon_threads=True
    def handle_error(self,request,address):
        if not isinstance(__import__('sys').exc_info()[1],(ConnectionResetError,BrokenPipeError,ConnectionAbortedError)):
            super().handle_error(request,address)


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*_): pass
    def send(self,status,payload,kind='application/json'):
        raw=payload.encode(); self.send_response(status); self.send_header('Content-Type',kind)
        self.send_header('Content-Length',str(len(raw))); self.send_header('Connection','close');self.end_headers()
        try:self.wfile.write(raw);self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError,ConnectionAbortedError):pass
    def do_GET(self):
        self.send(200,json.dumps({'data':[{'id':m} for m in delays]}))
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        model=body['model'];counts[model]+=1
        owners=set();results={}
        for m in body['messages']:
            for c in m.get('tool_calls',[]):owners.add(c['id'])
            if m['role']=='tool':
                identity=m['tool_call_id']
                if identity not in owners or identity in results:failures.append('Tool pairing/order error')
                results[identity]=m['content']
        time.sleep(delays[model])
        if model=='cancel': return
        tools=[];content=''
        if model.startswith(('serial','batch')):
            missing=[i for i in range(4) if f'read{i}' not in results]
            if missing:
                selected=missing[:1] if model.startswith('serial') else missing
                tools=[call(f'read{i}','read',{'filePath':f'item{i}.txt'}) for i in selected]
            else:content='sum=10'
        elif model=='dependent':
            if 'router' not in results:tools=[call('router','read',{'filePath':'router.txt'})]
            elif 'chosen' not in results:
                assert 'item1.txt' in results['router']
                tools=[call('chosen','read',{'filePath':'item1.txt'})]
            else:content='chosen=2'
        elif model=='failure':
            if 'missing' not in results:tools=[call('missing','read',{'filePath':'absent.txt'})]
            else:content='Missing file; task incomplete.'
        first={'choices':[{'delta':{'tool_calls':[dict(index=i,**c) for i,c in enumerate(tools)]} if tools else {'content':content},'finish_reason':None}]}
        last={'choices':[{'delta':{},'finish_reason':'tool_calls' if tools else 'stop'}]}
        wire='data: '+json.dumps(first)+'\n\ndata: '+json.dumps(last)+'\n\ndata: [DONE]\n\n'
        self.send(200,wire,'text/event-stream')


for delay in [0,0.2,1.0]:
    for policy in ['serial','batch']:delays[f'{policy}-{delay}']=delay
delays.update(dependent=0.2,failure=0.2,cancel=5)
server=Server(('127.0.0.1',0),Provider)
threading.Thread(target=server.serve_forever,daemon=True).start()
try:
    for model in delays:
        with tempfile.TemporaryDirectory(prefix='aurora-batch-validation-') as directory:
            root=Path(directory);workspace=root/'workspace';workspace.mkdir();state=root/'state'
            for i in range(4):(workspace/f'item{i}.txt').write_text(str(i+1))
            (workspace/'router.txt').write_text('item1.txt')
            prompt=root/'prompt.txt';prompt.write_text('Read the fixture data and return the requested result; report missing data explicitly.')
            env=dict(os.environ,AURORA_BENCH_BASE=f'http://127.0.0.1:{server.server_port}/v1',AURORA_BENCH_KEY='fixture',AURORA_BENCH_EFFORT='low')
            began=time.monotonic()
            result=subprocess.run([str(args.app),str(workspace),str(state),str(prompt),model,'1' if model=='cancel' else '20'],
                                  cwd=root,env=env,capture_output=True,text=True,timeout=30)
            elapsed=time.monotonic()-began
            messages=[]
            for path in (state/'threads').glob('*.json'):messages.extend(json.loads(path.read_text())['messages'])
            assistants=[m for m in messages if m['role']=='assistant']
            tools=[m for m in messages if m['role']=='tool']
            final=assistants[-1].get('content','') if assistants else ''
            if model.startswith(('serial','batch')):
                assert result.returncode==0 and final=='sum=10',(model,result.stderr,final)
                assert len(tools)==4 and not any(m.get('failed') for m in tools),(model,tools)
                assert counts[model]==(5 if model.startswith('serial') else 2),(model,counts[model])
            elif model=='dependent':
                assert result.returncode==0 and final=='chosen=2' and counts[model]==3
            elif model=='failure':
                assert result.returncode==0 and final=='Missing file; task incomplete.'
                assert len(tools)==1 and tools[0].get('failed')
            else:
                assert result.returncode==4 and elapsed<3,(result.returncode,elapsed)
            row=dict(model=model,delay_s=delays[model],seconds=round(elapsed,3),model_requests=counts[model],
                     tool_results=len(tools),passed=True)
            records.append(row);print(json.dumps(row),flush=True)
    assert not failures,failures
    for delay in [0.2,1.0]:
        serial=next(r for r in records if r['model']==f'serial-{delay}')
        batch=next(r for r in records if r['model']==f'batch-{delay}')
        assert serial['seconds']-batch['seconds']>delay*2,(serial,batch)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(dict(records=records,pairing_failures=failures),indent=2))
finally:
    server.shutdown();server.server_close()
