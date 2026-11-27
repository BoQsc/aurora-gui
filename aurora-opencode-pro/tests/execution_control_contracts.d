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
import auroraopencode.tools : executeTool, filesystemToolTimeout, ChangeContext;
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
    assert(exhausted.action == TurnAction.request && exhausted.turnStatus == "running" &&
        exhausted.taskStatus == "active",
        "An internal attempt counter abandoned unfinished work");
    writeln("PASS reworded completion, new reads and edits cannot reset unresolved-outcome recovery without stopping the chat");

    // A wait consumes its own duration, so the host deadline must include a
    // startup/shutdown margin. The old flat 3 s margin reported an elapsed
    // 100 s pause as a 103 s timeout.
    assert(filesystemToolTimeout("dshell", `{"command":"sleep","seconds":100}`) == 130_000);
    assert(filesystemToolTimeout("dshell", `{"command":"wait","seconds":300}`) == 330_000);
    assert(filesystemToolTimeout("dshell", `{"command":"sleep","seconds":600}`) == 330_000);
    assert(filesystemToolTimeout("dshell", `{"command":"list","timeout":100000}`) == 100_000);
    assert(filesystemToolTimeout("read", `{"timeout":100000}`) == 30_000);
    assert(filesystemToolTimeout("grep", `{"pattern":"x"}`) == 15_000);
    assert(filesystemToolTimeout("glob", `{"pattern":"**/*.d"}`) == 10_000);
    writeln("PASS wait deadlines add a host margin while explicit read/list/search deadlines stay bounded");

    // A transient host fault must not turn a delivered answer into a failed
    // turn: the environment interrupted the turn, and the recorded work stays.
    s = pending();
    foreach (attempt; 0 .. 2)
    {
        append(s, "assistant", "Delivered the requested correction " ~ to!string(attempt));
        auto d = decideTurn(s, p);
        assert(d.action == TurnAction.request, "Transient recovery did not ask for another round");
        append(s, "user", d.guidance, true);
        append(s, "tool", "Error: filesystem tool timed out after 130000 ms; its host was terminated.",
            false, "dshell", true);
    }
    append(s, "assistant", "The delivered answer and its evidence are preserved.");
    auto hostInterrupted = decideTurn(s, p);
    assert(hostInterrupted.action == TurnAction.request &&
        hostInterrupted.turnStatus == "running" &&
        hostInterrupted.taskStatus == "active", hostInterrupted.status);
    assert(!s.messages[$ - 1].failed, "A transient host fault marked the delivered answer as failed");
    writeln("PASS a persistent host fault schedules recovery and preserves the delivered answer");

    // Reported regression: a malformed command (a broken python -c one-liner)
    // was recorded as the obstacle, then the next execution of the same tool
    // succeeded. The stale obstacle must not consume the recovery budget and
    // turn the delivered answer into a failed turn.
    s = pending();
    append(s, "assistant", "Checking the published build");
    auto recovering = decideTurn(s, p);
    assert(recovering.action == TurnAction.request);
    append(s, "user", recovering.guidance, true);
    append(s, "tool",
        "  File \"<string>\", line 1\n    import os,p=pathlib\nSyntaxError: invalid syntax\n\nProcess exited with code 1.",
        false, "run", true);
    assert(executionState(s).failure.indexOf("SyntaxError") >= 0);
    append(s, "tool", "Publish log contents", false, "run");
    const resolvedExecution = executionState(s);
    assert(!resolvedExecution.failure.length, "A later successful execution kept the stale obstacle");
    append(s, "assistant", "The published build is verified.");
    auto continued = decideTurn(s, p);
    assert(continued.action == TurnAction.request &&
        continued.guidance.indexOf("previous completion attempt") < 0,
        "A resolved command failure spent the recovery budget: " ~ continued.status);
    writeln("PASS a malformed command resolved by the next execution does not fail the turn");

    // A success of an unrelated tool must not erase a failed execution.
    s = pending();
    append(s, "tool", "Error: the target could not be written", false, "write", true);
    append(s, "tool", "Target contents", false, "read");
    assert(executionState(s).failure.indexOf("could not be written") >= 0,
        "An unrelated successful tool erased the recorded obstacle");
    writeln("PASS only the failing tool's later success resolves its obstacle");

    // A new accepted check is real progress: attempts from an earlier streak
    // must not make the next answer terminal when the fingerprint recurs.
    s = pending();
    append(s, "assistant", "First delivery");
    auto first = decideTurn(s, p);
    assert(first.action == TurnAction.request);
    append(s, "user", first.guidance, true);
    append(s, "tool", "Error: filesystem tool host failed: response missing", false, "dshell", true);
    append(s, "assistant", "Second delivery after inspecting the host");
    auto second = decideTurn(s, p);
    assert(second.action == TurnAction.request);
    append(s, "user", second.guidance, true);
    append(s, "tool", "Current tests passed", false, "run");
    s.messages[$ - 1].verificationCheck = "verify:tests"; s.messages[$ - 1].verificationScope = "current";
    append(s, "assistant", "Third delivery with a fresh check");
    auto reset = decideTurn(s, p);
    assert(reset.action == TurnAction.request &&
        reset.guidance.indexOf("previous completion attempt") < 0,
        "An accepted check did not reset the recovery streak");
    writeln("PASS a newly accepted check resets the recovery streak instead of ending the turn");

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
    append(s,"assistant","The requested outcomes and checks are complete.");
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
    TaskWorkItem requiredOutcome;
    requiredOutcome.step = s.taskSteps[$-1]; requiredOutcome.required = true;
    s.contract.workItems ~= requiredOutcome;
    assert(!executionReadyToAnswer(s) && prepareAgentRequest(s,finishedPolicy).tools.length==1,
        "Final answer handoff hid tools while a real outcome remained");
    writeln("PASS a question answers directly; work that still needs tools is not cut off with no result");

    // A tool-less request that returns an empty reply must not settle as a
    // completed turn with nothing to show.
    s = pending(); s.verificationStatus="passed";
    append(s,"tool","Changed the requested implementation",false,"edit");
    s.messages[$-1].workspaceChanged=true;
    append(s,"assistant","  ",false);
    s.messages[$-1].finishReason="stop";
    s.taskSteps[0].status="completed";
    TurnPolicy noTools; noTools.toolsEnabled=false; noTools.finishReason="stop";
    auto blank = decideTurn(s,noTools);
    assert(blank.action == TurnAction.request && blank.guidance.indexOf("empty_answer")>=0,
        "An empty tool-less reply settled as a completed turn with no result");
    writeln("PASS an empty tool-less reply is retried instead of settling with no result");

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

    // The same command surfaces differently through `run` (program/args) and
    // `verify` (a recipe step). A passing rerun through the other surface must
    // clear the recorded failure; otherwise the chat stays pinned to an old
    // check that was in fact rerun successfully.
    s=pending();
    append(s,"tool","Interaction check failed",false,"run",true);
    s.messages[$-1].verificationCheck="verify:interaction";s.messages[$-1].verificationScope="current";
    s.messages[$-1].toolArgs=`{"program":"python","args":["-B",".tmp-native-check.py"]}`;
    assert(executionState(s).remaining.indexOf("has not passed")>=0);
    append(s,"tool",
        `{"passed":true,"steps":[{"kind":"interaction","command":{"program":"python","args":["-B",".tmp-native-check.py"]}}]}`,
        false,"verify");
    s.messages[$-1].verificationCheck="verify:interaction";s.messages[$-1].verificationScope="current";
    s.messages[$-1].toolArgs=`{"inputs":["app.d"],"steps":[{"kind":"interaction","command":{"program":"python","args":["-B",".tmp-native-check.py"]}}]}`;
    assert(executionState(s).remaining.indexOf("has not passed")<0,
        "A passing verify rerun did not clear the same command's recorded failure");
    writeln("PASS a passing rerun through verify clears a failure recorded by run");
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
