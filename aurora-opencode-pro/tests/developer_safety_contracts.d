module developer_safety_contracts;
import auroraopencode.developerworkflow;
import auroraopencode.checkout : CheckoutLease, checkoutIdentity;
import auroraopencode.workscheduler : WorkItem, WorkScheduler;
import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : executeTool, developerSourceDirectoryHandler, developerSourceEditCheckHandler;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.array : join;
import std.conv : to;
import std.file : write, readText, exists, mkdirRecurse, tempDir, thisExePath;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;
import std.process : spawnProcess, wait, Config;
import std.string : strip, indexOf;

string root;
string command(string dir, string[] args) {
    auto r=runDeveloperCommand(["git","-C",dir]~args,dir,30,"",null);
    assert(r.status==0,args.join(" ")~": "~r.output);
    return r.output.strip;
}
void fixture(string name,out string author,out string upstream,out string dev) {
    auto path=buildPath(root,name); mkdirRecurse(path);
    author=buildPath(path,"author"); upstream=buildPath(path,"upstream.git"); dev=buildPath(path,"dev");
    command(path,["init","--bare",upstream]); command(path,["init","-b","main",author]);
    command(author,["config","user.name","Fixture"]); command(author,["config","user.email","fixture@example.invalid"]);
    command(author,["config","core.autocrlf","false"]);
    write(buildPath(author,"base.txt"),"base\n"); write(buildPath(author,".gitignore"),"*.local\n");
    command(author,["add","-A"]); command(author,["commit","-m","base"]);
    command(author,["remote","add","origin",upstream]); command(author,["push","origin","main"]);
    command(path,["clone","-c","core.autocrlf=false","--branch","main",upstream,dev]);
    command(dev,["config","user.name","Fixture"]); command(dev,["config","user.email","fixture@example.invalid"]);
}
DeveloperWorkflow workflow(string upstream) {
    auto w=new DeveloperWorkflow("git"); w.upstreamUrl=upstream; w.upstreamBranch="main"; return w;
}
void update(string author,string file,string content) {
    write(buildPath(author,file),content); command(author,["add","-A"]);
    command(author,["commit","-m","Maintainer update"]); command(author,["push","origin","main"]);
}
OpenCodeToolCall writeCall(string path,string content) {
    JSONValue args; args["filePath"]=path; args["content"]=content;
    return OpenCodeToolCall("fixture-write","write",args.toString);
}
final class HeldJob : WorkItem {
    Semaphore entered, release;
    this(string path) { workspace=path; exclusive=true; entered=new Semaphore(); release=new Semaphore(); }
    override void execute() { entered.notify(); release.wait(); }
    override void settle(ulong revision) {}
}
void main(string[] args) {
    if (args.length == 4 && args[1] == "--hold-lock")
    {
        auto held=new CheckoutLease(args[2]);
        scope (exit) held.release();
        write(args[3],"ready"); Thread.sleep(700.msecs); return;
    }
    root=buildPath(tempDir(),"aurora-source-safety-"~to!string(MonoTime.currTime.ticks)); mkdirRecurse(root);
    setOpencodeStateDirectoryForTesting(buildPath(root,"state"));
    string author,upstream,dev;
    fixture("merge",author,upstream,dev);
    command(dev,["switch","-c","topic"]); write(buildPath(dev,"topic.txt"),"topic\n");
    command(dev,["add","-A"]); command(dev,["commit","-m","topic"]);
    command(dev,["switch","main"]); write(buildPath(dev,"local.txt"),"local\n");
    command(dev,["add","-A"]); command(dev,["commit","-m","local"]);
    command(dev,["merge","--no-ff","--no-commit","topic"]);
    write(buildPath(dev,"integration.txt"),"merge-only integration\n"); command(dev,["add","-A"]);
    command(dev,["commit","-m","integration"]); const previous=command(dev,["rev-parse","HEAD"]);
    update(author,"upstream.txt","new\n");
    auto w=workflow(upstream); auto result=w.sync(dev,true); assert(!result.failed,result.message);
    assert(readText(buildPath(dev,"integration.txt"))=="merge-only integration\n");
    command(dev,["merge-base","--is-ancestor",previous,"HEAD"]);
    assert(command(dev,["for-each-ref","--format=%(refname)","refs/aurora/recovery/"]).length);
    writeln("PASS: sync preserves merge-only changes, original history and durable recovery refs");

    fixture("ignored",author,upstream,dev);
    write(buildPath(dev,"settings.local"),"precious\n"); const ignoredHead=command(dev,["rev-parse","HEAD"]);
    write(buildPath(author,"settings.local"),"replacement\n"); command(author,["add","-f","settings.local"]);
    command(author,["commit","-m","track local file"]); command(author,["push","origin","main"]);
    w=workflow(upstream); result=w.sync(dev,true);
    assert(result.failed && result.message.indexOf("ignored")>=0,result.message);
    assert(readText(buildPath(dev,"settings.local"))=="precious\n");
    assert(command(dev,["rev-parse","HEAD"])==ignoredHead);
    writeln("PASS: ignored-file collisions stop before source or local content changes");

    fixture("staging",author,upstream,dev);
    write(buildPath(dev,"base.txt"),"staged\n"); command(dev,["add","base.txt"]);
    write(buildPath(dev,"base.txt"),"staged\nunstaged\n"); update(author,"upstream.txt","new\n");
    w=workflow(upstream);
    const publishedRevision=command(author,["rev-parse","HEAD"]);
    const stagedHead=command(dev,["rev-parse","HEAD"]);
    result=w.sync(dev,true,false,"ffffffffffffffffffffffffffffffffffffffff");
    assert(result.failed && result.message.indexOf("published source")>=0,result.message);
    assert(command(dev,["rev-parse","HEAD"])==stagedHead);
    assert(command(dev,["show",":base.txt"])=="staged");
    assert(readText(buildPath(dev,"base.txt"))=="staged\nunstaged\n");
    result=w.sync(dev,true,false,publishedRevision); assert(!result.failed,result.message);
    assert(command(dev,["show",":base.txt"])=="staged");
    assert(readText(buildPath(dev,"base.txt"))=="staged\nunstaged\n");
    writeln("PASS: successful sync preserves the staged/unstaged split");

    fixture("gates",author,upstream,dev);
    w=workflow(upstream);
    developerSourceDirectoryHandler=()=>dev;
    developerSourceEditCheckHandler=(string source,string[] paths,bool gitResolution) {
        auto check=w.checkSourceBeforeEdit(source,paths,gitResolution);
        return check.failed || check.available ? check.message : "";
    };
    update(author,"upstream.txt","new\n");
    auto edit=executeTool(writeCall(buildPath(dev,"base.txt"),"must not write\n"),root);
    assert(edit.failed && readText(buildPath(dev,"base.txt"))=="base\n",edit.output);
    assert(!executeTool(writeCall(buildPath(root,"unrelated.txt"),"independent\n"),root).failed);
    assert(!w.sync(dev,true).failed);
    w.upstreamUrl=buildPath(root,"offline.git");
    edit=executeTool(writeCall(buildPath(dev,"base.txt"),"offline write\n"),dev);
    assert(edit.failed && readText(buildPath(dev,"base.txt"))=="base\n");
    w.upstreamUrl=upstream;
    assert(!executeTool(writeCall(buildPath(dev,"base.txt"),"local work\n"),root).failed);
    update(author,"base.txt","owner work\n");
    result=w.sync(dev,true); assert(result.failed,result.message);
    assert(w.checkRebuildSource(dev).failed);
    assert(w.checkRebuildSource(dev,false).failed,
        "Turning off freshness checks must not permit a conflicted rebuild");
    assert(w.checkSourceBeforeEdit(dev,[buildPath(dev,"upstream.txt")],false,false).failed,
        "Turning off freshness checks must not permit ordinary edits during conflicts");
    assert(!w.checkSourceBeforeEdit(dev,[buildPath(dev,"base.txt")],false,false).failed,
        "Conflict repairs must remain available with freshness checks off");
    edit=executeTool(writeCall(buildPath(dev,"base.txt"),"owner and local work integrated\n"),root);
    assert(!edit.failed,edit.output);
    assert(executeTool(writeCall(buildPath(dev,"upstream.txt"),"unrelated change\n"),dev).failed);
    command(dev,["add","base.txt"]);
    assert(w.checkRebuildSource(dev).failed,"Pending restoration must still block builds after staging");
    assert(w.checkRebuildSource(dev,false).failed);
    assert(w.checkSourceBeforeEdit(dev,null,false,false).failed);
    assert(!w.sync(dev,true).failed);
    assert(!w.checkRebuildSource(dev).failed);
    w.upstreamUrl=buildPath(root,"offline.git");
    assert(!w.checkRebuildSource(dev,false).failed && !w.checkSourceBeforeEdit(dev,null,false,false).failed,
        "Freshness opt-out must still work offline after conflicts are finished");
    w.upstreamUrl=upstream;
    assert(readText(buildPath(dev,"base.txt"))=="owner and local work integrated\n");
    const localGateStarted=MonoTime.currTime;
    assert(!w.checkSourceBeforeEdit(dev,null).failed);
    writeln("MEASURE source_gate_local_ms=",(MonoTime.currTime-localGateStarted).total!"msecs");
    developerSourceDirectoryHandler=null; developerSourceEditCheckHandler=null;
    writeln("PASS: stale/offline writes are blocked; unrelated files and conflict resolution remain usable");

    mkdirRecurse(buildPath(dev,"aurora-opencode-pro"));
    assert(checkoutIdentity(dev)==checkoutIdentity(buildPath(dev,"aurora-opencode-pro")));
    auto scheduler=new WorkScheduler(2);
    auto first=new HeldJob(dev); auto second=new HeldJob(buildPath(dev,"aurora-opencode-pro"));
    assert(scheduler.submit(first) && first.entered.wait(2.seconds));
    assert(scheduler.submit(second));
    assert(!second.entered.wait(200.msecs),"Root/package writers overlapped");
    first.release.notify(); assert(second.entered.wait(2.seconds)); second.release.notify(); scheduler.close();
    auto lease=new CheckoutLease(dev);
    bool rejected;
    auto contender=new Thread({
        try { auto blocked=new CheckoutLease(buildPath(dev,"aurora-opencode-pro"),null,0); blocked.release(); }
        catch (Exception) { rejected=true; }
    });
    contender.start(); contender.join(); lease.release(); assert(rejected);
    const ready=buildPath(root,"lock-ready.txt");
    auto child=spawnProcess([thisExePath(),"--hold-lock",dev,ready],null,Config.suppressConsole);
    const deadline=MonoTime.currTime+3.seconds;
    while (!exists(ready) && MonoTime.currTime<deadline) Thread.sleep(10.msecs);
    assert(exists(ready)); rejected=false;
    try { auto blocked=new CheckoutLease(buildPath(dev,"aurora-opencode-pro"),null,0); blocked.release(); }
    catch (Exception) { rejected=true; }
    assert(rejected); assert(wait(child)==0);
    auto available=new CheckoutLease(dev); available.release();
    writeln("PASS: root/package scheduler jobs, threads and separate processes serialize the same checkout");
    writeln("ARTIFACTS ",root);
}
