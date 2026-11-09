"""Real-provider replay of Aurora user tasks in historical source copies only."""
import argparse, hashlib, io, json, os, pathlib, queue, shutil, subprocess, threading, time, zipfile
P = pathlib.Path
PACKAGE = P(__file__).resolve().parents[1]
REPO = PACKAGE.parent
TASKS = {
    "empty-send": "7235259",
    "export-menu": "f73c558",
}
def sha(p):
    with p.open("rb") as f: return hashlib.file_digest(f, "sha256").hexdigest()
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--task", choices=TASKS, required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--chat-id", required=True, help="Local Aurora chat containing the original user request")
    ap.add_argument("--exe", type=P, required=True)
    ap.add_argument("--timeout", type=int, default=1200)
    a=ap.parse_args()
    root=P(os.environ["LOCALAPPDATA"])/"Temp/aurora-flow-replays"/(a.task+"-"+a.label)
    root.mkdir(parents=True, exist_ok=False)
    checkout=root/"checkout"; checkout.mkdir()
    ref,sid=TASKS[a.task],a.chat_id
    paths=["aurora-opencode-pro", "aurora-opencode-core", "vendor/aurora-d-0.4.5", "scripts"]
    archive=subprocess.check_output(["git","archive","--format=zip",ref,*paths],cwd=REPO)
    manifest=[]
    with zipfile.ZipFile(io.BytesIO(archive)) as z:
        for row in z.infolist():
            p=P(row.filename)
            if row.is_dir() or any(x in {"build",".dub","node_modules","bin","screenshots",".aurora"} for x in p.parts): continue
            if p.suffix.lower() in {".exe",".bak",".pdb",".obj",".zip",".log"}: continue
            dest=checkout/p; dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(z.read(row))
            manifest.append({"path":p.as_posix(),"sha256":sha(dest)})
    (root/"snapshot.json").write_text(json.dumps(manifest,indent=2))
    subprocess.run(["git","init","-q",str(checkout)],check=True)
    subprocess.run(["git","-C",str(checkout),"add","."],check=True,capture_output=True)
    subprocess.run(["git","-C",str(checkout),"-c","user.name=Replay","-c","user.email=replay@localhost","commit","-qm","Historical isolated input"],check=True)
    workspace=checkout/"aurora-opencode-pro"
    original=P(os.environ["APPDATA"])/"Aurora OpenCode"
    saved=json.loads((original/"settings.json").read_text(encoding="utf-8-sig"))
    state=root/"appdata/Aurora OpenCode";state.mkdir(parents=True)
    settings={**saved,"workspace":str(workspace),"quickTitle":False,"composerSuggestion":False,
              "developerMode":False,"developerSourceDir":str(workspace),"developerAutoReapply":False,"developerRequireLatestSource":False}
    sp=state/"settings.json";sp.write_text(json.dumps(settings))
    chat=json.loads((original/"threads"/(sid+".json")).read_text(encoding="utf-8-sig"))
    users=[m["content"] for m in chat["messages"] if m.get("role")=="user" and not m.get("internal")]
    request=users[0]
    if a.task=="export-menu":
        request=next(x for x in users if "move Export under Checkpoint" in x)
    request=request.replace(str(PACKAGE),str(workspace)).replace(str(REPO),str(checkout))
    request += ("\n\nThis is an isolated historical source replay. Work only in "+str(checkout)+
                ". Do not read any original project or chats. Do not publish, push, use sync/rebuild, restart the production app or open external windows. "
                "Verify this copy using isolated compiler output and relevant widget tests. Local test builds are allowed. "
                "The archive intentionally excludes caches, binaries and prior generated reports. Complete the requested behavior without unrelated changes.")
    (root/"prompt.txt").write_text(request,encoding="utf-8")
    temp=root/"temp";temp.mkdir()
    result={"task":a.task,"ref":ref,"model":saved["model"],"binarySha256":sha(a.exe),"files":len(manifest),"status":"running","configuredReasoningEffort":next((x.get("effort") for x in saved.get("reasoningControls",[]) if x.get("model")==saved["model"]),None)}
    print("ARTIFACTS",root,"MODEL",saved["model"],"FILES",len(manifest),flush=True)
    started=time.monotonic();process=None
    def view():
        try:
            index=json.loads((state/"threads.index.json").read_text(encoding="utf-8-sig"));h=index["sessions"][0]
            m=json.loads((state/"threads"/(h["id"]+".json")).read_text(encoding="utf-8-sig"))["messages"]
            return h,m
        except (OSError,ValueError,KeyError):return {},[]
    try:
        with (root/"process.log").open("w",encoding="utf-8") as log:
            process=subprocess.Popen([str(a.exe.resolve()),"--session-server"],cwd=workspace,
                env=dict(os.environ,APPDATA=str(root/"appdata"),TEMP=str(temp),TMP=str(temp),FORGE_PUBLISH_SKIP="1"),
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True,encoding="utf-8",errors="replace",bufsize=1)
            incoming=queue.Queue()
            def collect():
                for line in process.stdout:
                    try:incoming.put(json.loads(line))
                    except ValueError:pass
            threading.Thread(target=collect,daemon=True).start()
            def send(x):process.stdin.write(json.dumps(x)+"\n");process.stdin.flush()
            send({"type":"create","id":"flow","title":"Real flow replay "+a.task,"workspace":str(workspace),"model":saved["model"],"thinking":saved.get("thinking",False),"tools":True})
            last=0
            with (root/"events.jsonl").open("w",encoding="utf-8") as events:
                while time.monotonic()-started<a.timeout:
                    try:
                        event=incoming.get(timeout=2);events.write(json.dumps(event)+"\n");events.flush()
                        if event["type"]=="created":send({"type":"submit","id":"flow","requestId":"actual-user-task","text":request})
                        if event["type"] in {"turn.completed","turn.failed","turn.interrupted"}:
                            result.update(status=event["type"],final=event);break
                        if event["type"]=="error":raise RuntimeError(event.get("error"))
                    except queue.Empty:
                        if process.poll() is not None:raise RuntimeError("Replay exited")
                    elapsed=time.monotonic()-started
                    if elapsed-last>=20:
                        h,m=view();t=[x for x in m if x.get("role")=="tool"]
                        print("LIVE",round(elapsed),"tools",len(t),"state",h.get("taskStatus"),"last",t[-1].get("toolName") if t else None,flush=True);last=elapsed
                else:result["status"]="timeout";send({"type":"cancel","id":"flow"})
                send({"type":"shutdown"});process.wait(timeout=45)
        h,m=view();result.update(taskStatus=h.get("taskStatus"),verificationStatus=h.get("verificationStatus"),
            toolResults=sum(x.get("role")=="tool" for x in m),rounds=sum(bool(x.get("toolCalls")) for x in m if x.get("role")=="assistant"),
            failedTools=sum(x.get("role")=="tool" and x.get("failed",False) for x in m),promptTokens=sum(x.get("promptTokens",0) for x in m),peakPromptTokens=max((x.get("promptTokens",0) for x in m),default=0),plan=h.get("taskSteps"))
    except Exception as error:
        result.update(status="replay.failed",error=str(error))
        raise
    finally:
        if process is not None and process.poll() is None:process.terminate();process.wait(timeout=15)
        settings.update(apiKey="",additionalApiKey="",providerApiKeys=[],providerKeys=[]);sp.write_text(json.dumps(settings))
        result["seconds"]=time.monotonic()-started;(root/"result.json").write_text(json.dumps(result,indent=2))
        print("RESULT",result["status"],round(result["seconds"]),"ARTIFACTS",root,flush=True)
if __name__=="__main__":main()
