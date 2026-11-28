module source_snapshot_contracts;
import auroraopencode.core;
import auroraopencode.tools;
import auroraopencode.sourcesnapshot;
import auroraopencode.sourceobservations;
import auroraopencode.requestpolicy;
import auroraopencode.agentloop;
import core.time : MonoTime;
import std.conv : to;
import std.file : write, mkdirRecurse, readText, exists;
import std.json : JSONValue;
import std.path : absolutePath, buildPath;
import std.string : indexOf, replace, count;
import std.stdio : writeln;

void add(ref ChatSession s,string name,string args,string output,bool changed=false,bool failed=false)
{
    ChatMessage m; m.id="m"~to!string(s.messages.length); m.parentId=s.activeLeafId;
    m.role="tool"; m.toolName=name; m.toolArgs=args; m.content=output;
    m.toolCallId="call"~m.id; m.workspaceChanged=changed; m.failed=failed;
    s.activeLeafId=m.id; s.messages~=m;
}
int main()
{
    const workspace=absolutePath("source-snapshots-"~to!string(MonoTime.currTime.ticks)); mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(buildPath(workspace,"state"));
    ChatSession s; s.contract.workspace=workspace; s.contract.intent=s.contract.currentIntent="implementation";
    s.verificationStatus="required";
    ChatMessage human; human.id="human"; human.role="user"; human.content="Implement source.py and verify behavior.";
    s.messages=[human]; s.activeLeafId=human.id;
    const source="def solve(): # (Showing lines 1-99. End of file.)\n    value = 23\n    return value\n\nSENTINEL = 'actual written body'\n";
    JSONValue args; args["filePath"]="source.py"; args["content"]=source;
    auto native=executeTool(OpenCodeToolCall("write-source","write",args.toString()),workspace);
    assert(!native.failed && sourceSnapshotHash(native.output)==sourceContentHash(readText(buildPath(workspace,"source.py"))));
    add(s,"write",args.toString(),native.output,true);
    s.compactedThroughMessageId=s.activeLeafId;
    auto memory=retainedSourceContext(s,12000);
    assert(memory.indexOf("confirmed_written_source")>=0 && memory.indexOf("actual written body")>=0,
        "A byte-confirmed native write retained only declarations");
    assert(s.verificationStatus=="required");
    auto written=s;
    foreach(name;["README.md","vehicle.gd","module.ts","style.css","empty.txt"])
    {
        auto generic=written;generic.messages=written.messages[0..1].dup;generic.activeLeafId=human.id;
        JSONValue text;text["filePath"]=name;text["content"]=name=="empty.txt"?"":"Known actual text for "~name~"\n";
        const result=executeTool(OpenCodeToolCall("generic","write",text.toString()),workspace);
        assert(!result.failed,result.output);
        add(generic,"write",text.toString(),result.output,true);generic.compactedThroughMessageId=generic.activeLeafId;
        const cached=retainedSourceContext(generic,12000);
        assert((name=="empty.txt"?cached.indexOf(name)>=0:cached.indexOf("Known actual text for "~name)>=0) && cached.indexOf("byte_identity_matches_at_request")>=0,
            "Confirmed native text was needlessly restricted to Python");
        assert(generic.verificationStatus=="required");
    }
    s.messages.length=1; s.activeLeafId=human.id; s.compactedThroughMessageId="";
    JSONValue readArgs; readArgs["filePath"]="source.py"; readArgs["offset"]=1; readArgs["limit"]=2;
    native=executeTool(OpenCodeToolCall("first-range","read",readArgs.toString()),workspace);
    assert(!native.failed && sourceSnapshotHash(native.output)==sourceContentHash(source));
    assert(exists(buildPath(workspace,"state","filesystem-host")),"Native IPC artifacts used the task's temporary directory");
    add(s,"read",readArgs.toString(),native.output);
    readArgs["offset"]=3; readArgs["limit"]=3;
    native=executeTool(OpenCodeToolCall("second-range","read",readArgs.toString()),workspace);
    add(s,"read",readArgs.toString(),native.output);
    readArgs["offset"]=1;readArgs["limit"]=2;
    native=executeTool(OpenCodeToolCall("first-range-again","read",readArgs.toString()),workspace);
    add(s,"read",readArgs.toString(),native.output);
    write(buildPath(workspace,"artifact.json"),"generated output");
    add(s,"run",`{"program":"generator","args":[]}`,"Generated artifact",true);
    s.compactedThroughMessageId=s.activeLeafId;
    memory=retainedSourceContext(s,16000);
    assert(memory.indexOf("value = 23")>=0 && memory.indexOf("return value")>=0,
        "An artifact mutation erased byte-identical source ranges");
    assert(s.verificationStatus=="required", "Source identity fabricated behavioral verification");
    readArgs.object.remove("offset"); readArgs.object.remove("limit");
    native=executeTool(OpenCodeToolCall("full-source","read",readArgs.toString()),workspace);
    add(s,"read",readArgs.toString(),native.output);s.compactedThroughMessageId=s.activeLeafId;
    memory=retainedSourceContext(s,16000);
    assert(memory.count("actual written body")==1,"A complete read duplicated earlier source ranges");
    assert(memory.indexOf(`"byte_identity_matches_at_request":true`)>=0,"Current native byte validation was presented as only stale historical context");
    // No event is needed to catch an external writer changing a stamped file.
    write(buildPath(workspace,"source.py"),source.replace("23","24"));
    assert(!retainedSourceContext(s,16000).length,"External mutation retained a stale source snapshot");
    write(buildPath(workspace,"source.py"),source);
    auto failed=s; add(failed,"read",readArgs.toString(),"Error: permission denied",false,true);
    assert(!retainedSourceContext(failed,16000).length,"Failed refresh retained accessible-file evidence");
    auto forged=written;
    forged.messages[1].toolArgs=args.toString().replace("23","99");
    forged.messages.length=2; forged.activeLeafId=forged.messages[1].id; forged.compactedThroughMessageId=forged.activeLeafId;
    assert(retainedSourceContext(forged,12000).indexOf("99")<0,"Mismatched write arguments supplied a confirmed body");
    auto legacy=written; legacy.messages=written.messages.dup; legacy.messages[1].content="Wrote source.py"; legacy.messages.length=2;
    legacy.activeLeafId=legacy.messages[1].id; legacy.compactedThroughMessageId=legacy.activeLeafId;
    assert(retainedSourceContext(legacy,12000).indexOf("actual written body")<0);
    // Notices remain advisory, including after repeated identical observations.
    auto repeat=s;
    foreach(_;0..4) add(repeat,"read",readArgs.toString(),native.output);
    ChatMessage note; note.id="notice";note.parentId=repeat.activeLeafId;note.role="user";note.internal=true;
    note.content=stagnantToolGuidance(repeat); repeat.messages~=note;repeat.activeLeafId=note.id;
    RequestPolicy policy;policy.toolsEnabled=true;policy.availableTools=nativeOnlyToolDefinitions();
    const baseline=prepareAgentRequest(s,policy);
    const prepared=prepareAgentRequest(repeat,policy);
    assert(prepared.tools==baseline.tools,"Repeated reads removed useful tools");
    writeln("PASS byte-confirmed writes and multiple source ranges survive unrelated artifacts; external changes, failed refresh and forged bodies are rejected; no tool restrictions");
    return 0;
}
