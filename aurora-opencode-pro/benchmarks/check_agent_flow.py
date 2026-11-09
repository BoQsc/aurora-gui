"""Independent real-widget acceptance checks for the hosted-model replay outputs."""
import argparse, json, pathlib, subprocess, time, http.server, threading
P=pathlib.Path
PACKAGE=P(__file__).resolve().parents[1]
def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument("replay",type=P);ap.add_argument("--before",action="store_true");a=ap.parse_args();r=a.replay.resolve();ws=r/"checkout/aurora-opencode-pro"
 task=json.loads((r/"result.json").read_text())["task"]
 out=r/("independent-before" if a.before else "independent");out.mkdir(exist_ok=True);exe=out/"probe.exe"
 command=["dmd","-i","-verrors=20","-Isource","-Ishared","-I../aurora-opencode-core/source","-I../vendor/aurora-d-0.4.5/source","-Jassets","-of"+str(exe),str(PACKAGE/"benchmarks/flow_task_probe.d"),"user32.lib","gdi32.lib","shell32.lib","wininet.lib","winmm.lib"]
 if task=="empty-send":command.insert(1,"-version=EmptySendProbe")
 if a.before:
  before=out/"before-source/auroraopencode";before.mkdir(parents=True,exist_ok=True)
  ref="7235259" if task=="empty-send" else "f73c558"
  module="conversationactor.d" if task=="empty-send" else "appui.d"
  original=subprocess.check_output(["git","show",ref+":aurora-opencode-pro/source/auroraopencode/"+module],cwd=PACKAGE.parent)
  (before/module).write_bytes(original);command.insert(-5,str(before/module))
 started=time.monotonic()
 with (out/"compile.log").open("w") as f: built=subprocess.run(command,cwd=ws,stdout=f,stderr=subprocess.STDOUT,timeout=180)
 result={"task":task,"compileExit":built.returncode,"status":"compile-failed"}
 if built.returncode==0:
  class Provider(http.server.BaseHTTPRequestHandler):
   def log_message(self,*args): pass
   def do_POST(self):
    self.rfile.read(int(self.headers.get('Content-Length','0')))
    data=b'data: {"choices":[{"delta":{"content":"CONTINUED"},"finish_reason":null}]}\n\ndata: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n'
    self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
  server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Provider)
  threading.Thread(target=server.serve_forever,daemon=True).start()
  try:
   with (out/"probe.log").open("w") as f: checked=subprocess.run([str(exe),task,str(out/"state"),f'http://127.0.0.1:{server.server_port}/v1'],cwd=ws,stdout=f,stderr=subprocess.STDOUT,timeout=60)
  finally: server.shutdown();server.server_close()
  result.update(status=(("already-satisfied" if checked.returncode==0 else "unexpected-failure") if task=="empty-send" else ("unexpected-pass" if checked.returncode==0 else "expected-failure")) if a.before else ("passed" if checked.returncode==0 else "failed"),probeExit=checked.returncode)
 else: print((out/"compile.log").read_text()[-3000:])
 result["seconds"]=time.monotonic()-started;(r/("independent-before.json" if a.before else "independent-check.json")).write_text(json.dumps(result,indent=2));print(json.dumps(result),"ARTIFACTS",out)
 if built.returncode==0: print((out/"probe.log").read_text()[-1500:])
 raise SystemExit(0 if result["status"] in {"passed","expected-failure","already-satisfied"} else 1)
if __name__=="__main__":main()
