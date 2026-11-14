module execution_control_contracts;
import auroraopencode.core;
import auroraopencode.executioncontrol;
import auroraopencode.taskflow : acceptTaskRequest, taskEvidenceIndex;
import auroraopencode.taskpolicy : taskWorkspace, verificationCoverage;
import auroraopencode.turnpolicy;
import auroraopencode.requestintent;
import auroraopencode.contextpolicy : latestActualUserRequest;
import auroraopencode.requestpolicy;
import auroraopencode.taskmutation : applyTaskPlan;
import auroraopencode.tools : executeTool, ChangeContext;
import std.conv : to;
import std.file : mkdirRecurse, tempDir;
import std.path : buildPath, absolutePath;
import std.string : indexOf, startsWith;
import std.stdio : writeln;
import core.time : MonoTime;

void append(ref ChatSession s, string role, string text, bool internal = false, string tool = "", bool failed = false)
{
    ChatMessage m; m.id = "m" ~ to!string(s.messages.length); m.parentId = s.activeLeafId;
    m.role = role; m.content = text; m.internal = internal; m.toolName = tool; m.failed = failed;
    s.messages ~= m; s.activeLeafId = m.id;
}
ChatSession pending()
{
    ChatSession s;
    append(s, "user", "Fix the recorder's incorrect window selection.");
    acceptTaskRequest(s, s.messages[$-1].content, s.activeLeafId);
    s.taskSteps = [TaskStep("Correct selection", "in_progress")];
    s.verificationStatus = "required";
    return s;
}
int main()
{
    TurnPolicy p; p.toolsEnabled = true;
    auto s = pending();
    append(s,"tool","Initial implementation edit",false,"edit");
    s.messages[$-1].diffAdditions=1;
    foreach (attempt; 0 .. 2)
    {
        append(s, "assistant", "Everything is now fixed " ~ to!string(attempt));
        auto d = decideTurn(s,p);
        assert(d.action == TurnAction.request && d.guidance.startsWith(executionRecoveryMarker));
        append(s,"user",d.guidance,true);
        // New files, successful reads, edits and changed prose do not resolve
        // the selection outcome or erase the recovery interval.
        append(s,"tool","Different source " ~ to!string(attempt),false,"read");
        append(s,"tool","Applied patch " ~ to!string(attempt),false,"apply_patch");
        s.messages[$-1].workspaceChanged = true;
    }
    append(s,"assistant","The requested interaction is fully corrected.");
    auto exhausted = decideTurn(s,p);
    assert(exhausted.action == TurnAction.failed && exhausted.taskStatus == "active",
        "Unresolved completion prose must not loop or advertise completed work");
    writeln("PASS reworded completion, new reads and edits cannot reset unresolved-outcome recovery");

    s = pending();
    foreach (i; 0 .. 12)
    {
        append(s,"tool","Resolved outcome " ~ to!string(i),false,"edit");
        s.taskSteps ~= TaskStep("Outcome " ~ to!string(i), "completed", "outcome-" ~ to!string(i), "edit", "Required behavior", [s.messages[$-1].id]);
        auto d = decideTurn(s,p);
        assert(d.action == TurnAction.request);
        append(s,"user",d.guidance,true);
    }
    s.taskSteps[0].status="completed"; s.verificationStatus="passed";
    append(s,"tool","Changed the requested implementation",false,"edit");
    s.messages[$-1].diffAdditions=1; s.messages[$-1].workspaceChanged=true;
    assert(decideTurn(s,p).action == TurnAction.settle, executionState(s).remaining);
    writeln("PASS progressing outcomes have no fixed request or tool budget");
    RequestPolicy finishedPolicy;finishedPolicy.toolsEnabled=true;
    finishedPolicy.availableTools=[OpenCodeToolDef("read","Read a file",`{"type":"object"}`)];
    assert(executionReadyToAnswer(s));
    // A follow-up that points at work not yet done keeps its tools. Treating it
    // as the final answer left none, so the model wrote its lookup as text and
    // the turn ended with no result at all.
    append(s,"user","C:\\work\\project hope you fixed the upstream too");
    assert(!directQuestionRequest(latestActualUserRequest(s)));
    assert(prepareAgentRequest(s,finishedPolicy).tools.length==1,
        "A follow-up that needs a lookup ended with no tools and no result");
    append(s,"user","Explain the change once more.");
    assert(directQuestionRequest(latestActualUserRequest(s)));
    assert(prepareAgentRequest(s,finishedPolicy).tools.length==0,
        "A direct question after completed work exposed tools for another unnecessary audit");
    s.taskSteps ~= TaskStep("Newly discovered required outcome","pending");
    assert(!executionReadyToAnswer(s) && prepareAgentRequest(s,finishedPolicy).tools.length==1,
        "Final answer handoff hid tools while a real outcome remained");
    writeln("PASS a question answers directly; work that still needs tools is not cut off with no result");

    s = pending(); s.verificationStatus="passed"; s.verificationScope="current";
    append(s,"tool","Checks passed",false,"run");
    s.messages[$-1].verificationCheck="verify:tests,interaction";
    s.messages[$-1].verificationScope="current";
    assert(verificationCoverage(s).indexOf("interaction")>=0);
    append(s,"user","It still does nothing; the selection is incorrect.");
    acceptTaskRequest(s,s.messages[$-1].content,s.activeLeafId);
    assert(s.verificationStatus=="required");
    assert(verificationCoverage(s)=="verify:","Old passing checks overruled a later failure report");
    append(s,"tool","Reproduced and checked current behavior",false,"run");
    s.messages[$-1].verificationCheck="verify:tests"; s.messages[$-1].verificationScope="current";
    assert(verificationCoverage(s)=="verify:tests");
    writeln("PASS new user failure invalidates earlier checks while preserving subsequent evidence");
    s=pending();
    append(s,"tool","Real timing check failed",false,"run",true);
    s.messages[$-1].verificationCheck="verify:tests";s.messages[$-1].verificationScope="current";
    s.messages[$-1].toolArgs=`{"program":"python","args":["tests/real.py"]}`;
    append(s,"tool","Different test passed",false,"run");
    s.messages[$-1].verificationCheck="verify:tests";s.messages[$-1].verificationScope="current";
    s.messages[$-1].toolArgs=`{"program":"python","args":["tests/simulation.py"]}`;
    assert(executionState(s).remaining.indexOf("has not passed")>=0);
    append(s,"tool","Real timing check now passed",false,"run");
    s.messages[$-1].verificationCheck="verify:tests";s.messages[$-1].verificationScope="current";
    s.messages[$-1].toolArgs=`{"program":"python","args":["tests/real.py"]}`;
    assert(executionState(s).remaining.indexOf("has not passed")<0);
    writeln("PASS a different green test cannot erase a recorded behavioral failure");
    foreach (label; ["pytest", "cargo test", "dub test", "verify:interaction"])
    {
        auto failed=pending();append(failed,"tool","Behavior failed",false,"run",true);
        failed.messages[$-1].verificationCheck=label;failed.messages[$-1].verificationScope="current";
        assert(executionState(failed).remaining.indexOf("has not passed")>=0);
    }

    assert(actionApprovalRequest("approved") && actionApprovalRequest("Approved."));
    s = pending(); s.contract.intent="analysis";
    append(s,"user","approved");acceptTaskRequest(s,"approved",s.activeLeafId);
    assert(s.contract.currentIntent=="continuation" && s.contract.intent=="implementation");
    writeln("PASS explicit approved reply resumes the prepared work");

    const root=absolutePath(buildPath(tempDir(),"aurora-execution-"~to!string(MonoTime.currTime.ticks)));
    const a=buildPath(root,"general"); const b=buildPath(root,"target with spaces");
    mkdirRecurse(buildPath(a,".git"));mkdirRecurse(buildPath(b,".git"));
    s=pending();append(s,"user","The general source is at "~a~".");
    append(s,"user","Let's investigate the actual project at "~b);
    s.contract.intent="implementation";s.contract.currentIntent="implementation";
    import auroraopencode.checkout : canonicalPath;
    assert(canonicalPath(taskWorkspace(s,a))==canonicalPath(b),"Analysis wording concealed an explicitly selected target project");
    writeln("PASS explicitly named project owns verification despite earlier general source path");

    s=pending();append(s,"user","Stop using computer use and start fixing.");
    assert(desktopRestricted(s));
    applyTaskPlan(s,`{"constraints":[],"plan":[{"step":"Fix selection","status":"in_progress"}]}`);
    assert(desktopRestricted(s));
    ChangeContext context;context.desktopRestricted=desktopRestricted(s);
    auto refused=executeTool(OpenCodeToolCall("blocked","computer",`{"action":"click"}`),root,null,context);
    assert(refused.failed && refused.output.indexOf("restriction")>=0);
    append(s,"user","Why is it still incorrect?");assert(desktopRestricted(s));
    append(s,"user","Do not resume computer use.");assert(desktopRestricted(s));
    append(s,"user","Resume computer use.");assert(!desktopRestricted(s));
    writeln("PASS desktop stop survives plan replacement and diagnosis, and is enforced at tool admission");

    s=pending();
    foreach (i;0..3)append(s,"tool","Verification input belongs to another task checkout",false,"run",true);
    assert(executionToolRecovery(s).indexOf("checkout")>=0);
    append(s,"user",executionToolRecovery(s),true);
    assert(!executionToolRecovery(s).length,"Repeated obstacle notice emitted without another failed window");
    RequestPolicy rp;rp.toolsEnabled=true;
    append(s,"user","Plan progress checkpoint: update the plan now",true);
    auto request=prepareAgentRequest(s,rp);
    foreach(m;request.messages) assert(m.content.indexOf("Application control: the phase-change reminder")<0 &&
        m.content.indexOf("Plan progress checkpoint:")<0);
    writeln("PASS concrete failure recovery and removal of legacy plan reconciliation controls");
    return 0;
}
