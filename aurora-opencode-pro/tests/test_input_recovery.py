"""Native HTTP regressions for false input pauses, recovery and true missing facts."""
import collections,http.server,json,os,subprocess,sys,tempfile,threading,hashlib,time
from pathlib import Path
package=Path(__file__).resolve().parents[1]
rounds=collections.Counter(); failures=[]
permission={"required_fact":"Whether I may close the running executable window or the user will close it", "reason":"The release link step cannot overwrite a mapped image", "question":"A running window maps the output executable. Do you want me to close that window, or will you close it yourself?", "checked":["Process ownership and build output inspected"], "independent_work_complete":True}
def call(identity,name,args):return {"id":identity,"type":"function","function":{"name":name,"arguments":json.dumps(args)}}
class Provider(http.server.BaseHTTPRequestHandler):
 protocol_version="HTTP/1.1"
 def log_message(self,*_):pass
 def do_GET(self):
  body=b'{"data":[{"id":"recovery-fixture"}]}'
  self.send_response(200);self.send_header("Content-Length",str(len(body)));self.send_header("Connection","close");self.end_headers();self.wfile.write(body)
 def do_POST(self):
  messages=json.loads(self.rfile.read(int(self.headers["Content-Length"])))["messages"]
  prompt=next((m["content"] for m in reversed(messages) if m["role"]=="user" and m.get("content") in ["Resume the paused fixture.","Resolve the technical input fixture."]),None)
  if prompt is None:failures.append("A genuine input pause or Stop started a model request");self.send_error(500);return
  scenario="resume" if prompt.startswith("Resume") else "trap";rounds[scenario]+=1
  owners=set();results={}
  for m in messages:
   for t in m.get("tool_calls",[]):owners.add(t["id"])
   if m["role"]=="tool":
    identity=m["tool_call_id"]
    if identity not in owners or identity in results:failures.append("Unpaired tool result")
    results[identity]=m["content"]
  tools=[];content="";writer=scenario+"-write";planner=scenario+"-plan"
  if scenario=="trap" and "false-input" not in results:tools=[call("false-input","request_input",permission)]
  elif writer not in results:
   if scenario=="trap" and "Recover internally" not in results["false-input"]:failures.append("Technical permission question was accepted")
   tools=[call(writer,"write",{"filePath":"resumed.md" if scenario=="resume" else "resolved.md","content":"Recovered" if scenario=="resume" else "Resolved"})]
  elif planner not in results:tools=[call(planner,"update_plan",{"plan":[{"id":scenario,"step":"Write recovered document" if scenario=="resume" else "Resolve technical obstacle","kind":"edit","status":"completed","evidence":[writer]}]})]
  else:content="Recovered document completed." if scenario=="resume" else "Technical obstacle recovered."
  if rounds[scenario]>8:failures.append("Recovery did not settle");tools=[];content="Fixture failed."
  delta={"tool_calls":[dict(t,index=i) for i,t in enumerate(tools)]} if tools else {"content":content}
  body=("data: "+json.dumps({"choices":[{"delta":delta,"finish_reason":None}]})+"\n\n"+"data: "+json.dumps({"choices":[{"delta":{},"finish_reason":"tool_calls" if tools else "stop"}]})+"\n\ndata: [DONE]\n\n").encode()
  self.send_response(200);self.send_header("Content-Type","text/event-stream");self.send_header("Content-Length",str(len(body)));self.send_header("Connection","close");self.end_headers();self.wfile.write(body)
class Server(http.server.ThreadingHTTPServer):
 def handle_error(self,request,address):
  if not isinstance(sys.exc_info()[1],(ConnectionResetError,BrokenPipeError)):super().handle_error(request,address)
server=Server(("127.0.0.1",0),Provider);threading.Thread(target=server.serve_forever,daemon=True).start()
try:
 env=dict(os.environ,AURORA_STRICT_PLAN="0",AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
 if "--production" in sys.argv:
  directory=Path(tempfile.mkdtemp(prefix="production-input-recovery-",dir=package/"build"));workspace=directory/"workspace";workspace.mkdir();state=directory/"appdata/Aurora OpenCode";state.mkdir(parents=True)
  (state/"settings.json").write_text(json.dumps({"baseUrl":env["AURORA_CONTRACT_PROVIDER_BASE"],"apiKey":"local-fixture","model":"recovery-fixture","workspace":str(workspace),"toolsEnabled":True,"quickTitle":False,"legacyTools":False}))
  exe=package/"aurora-opencode-pro.exe";started=time.monotonic()
  result=subprocess.run([str(exe),"--headless","Resolve the technical input fixture."],cwd=workspace,env=dict(env,APPDATA=str(directory/"appdata")),capture_output=True,text=True,timeout=45)
  (directory/"process.log").write_text(result.stdout+result.stderr);assert result.returncode==0,result.stdout+result.stderr
  assert (workspace/"resolved.md").read_text()=="Resolved"
  assert any(any(m.get("content")=="Technical obstacle recovered." for m in json.loads(p.read_text())["messages"]) for p in (state/"threads").glob("*.json"))
  (directory/"result.json").write_text(json.dumps({"status":"passed","binarySha256":hashlib.sha256(exe.read_bytes()).hexdigest(),"rounds":dict(rounds),"seconds":time.monotonic()-started},indent=2));print("PASS production input recovery; ARTIFACTS",directory)
  assert rounds=={"trap":4},rounds
 else:
  subprocess.run([sys.executable,str(package/"tests/run_architecture_checks.py"),"recovery_quality_contracts","input_recovery_ui_contracts"],env=env,check=True,timeout=180)
  assert rounds=={"resume":3,"trap":4},rounds
 assert not failures,failures
 print("PASS automatic false-pause recovery; genuine input and Stop preserved",dict(rounds))
finally:server.shutdown();server.server_close()
