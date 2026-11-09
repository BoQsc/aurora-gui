module checked_run_contracts;
import auroraopencode.core;
import auroraopencode.tools;
import auroraopencode.toolscheduler;
import auroraopencode.opencode_client;
import auroraopencode.toolsettlement;
import auroraopencode.taskpolicy : verificationScope;
import auroraopencode.taskflow : acceptTaskRequest, taskHasActionEvidence, missingVerificationInput;
import auroraopencode.taskcontinuation : taskContinuation;
import auroraopencode.verificationrecipe : runVerificationRecipe, VerificationRun;
import auroraopencode.recipeevidence : missingRecipeInput;
import core.time : MonoTime;
import std.conv : to;
import std.file : mkdirRecurse, write, readText, remove;
import std.json : JSONValue, parseJSON;
import std.path : buildPath, absolutePath;
import std.stdio : writeln;
import std.string : indexOf, endsWith;

void main()
{
    const root = absolutePath("checked-run-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(root, "workspace");
    mkdirRecurse(buildPath(workspace, ".git"));
    setOpencodeStateDirectoryForTesting(buildPath(root, "state"));
    write(buildPath(workspace, "artifact.txt"), "payload");
    write(buildPath(workspace, "checker.py"),
        "from pathlib import Path\np=Path('count');p.write_text(str(int(p.read_text())+1) if p.exists() else '1')\nassert Path('artifact.txt').read_text()=='payload'\n");
    const arguments = `{"program":"python","args":["-B","checker.py"],"check":"tests","inputs":["artifact.txt","checker.py"]}`;
    auto client = new OpenCodeClient("http://127.0.0.1:1", "");
    scope(exit) client.closeSession();
    auto batch = scheduleToolBatch(client, 1, [OpenCodeToolCall("one-check", "run", arguments)], workspace,
        new ToolCancellation(), ChangeContext.init);
    batch.wait();
    OpenCodeEvent[] events; client.drain(events);
    OpenCodeEvent checked;
    foreach (event; events) if (!event.toolRunning) checked = event;
    assert(!checked.toolFailed && checked.verificationPassed && checked.verificationCheck == "verify:tests", checked.text);
    assert(readText(buildPath(workspace, "count")) == "1", "Single-command check ran more than once");
    ChatSession session; session.objective = "Check the packaged artifact";
    session.verificationScope = verificationScope(workspace, toolWorkspaceRevision(workspace));
    session.verificationStatus = "required"; session.taskStatus = "active";
    auto policy = ToolResultPolicy(false, workspace, workspace, "now", toolWorkspaceRevision(workspace));
    auto settled = settleToolResult(session, checked, arguments, policy);
    settled.message.id = "proof"; session.messages ~= settled.message; session.activeLeafId = "proof";
    assert(settled.acceptedVerification, settled.message.content);
    advanceToolTaskState(session, settled, checked, arguments, "required", session.verificationScope);
    assert(session.verificationStatus == "passed");
    const report = parseJSON(settled.message.content);
    assert(report["recipe"].str == "inline" && report["receipt"]["acceptedForCurrentSource"].boolean);
    ChatSession already; already.id = "existing-outcome";
    ChatMessage user; user.id = "request"; user.role = "user"; user.content = "Fix the artifact exporter";
    already.messages = [user]; already.activeLeafId = user.id;
    acceptTaskRequest(already, user.content, user.id);
    already.verificationScope = session.verificationScope; already.verificationStatus = "passed";
    auto plain = settled.message; plain.id = "plain"; plain.parentId = user.id;
    already.messages ~= plain; already.activeLeafId = plain.id;
    assert(!taskHasActionEvidence(already), "An ordinary check silently replaced the requested action");
    auto noChangeArgs = parseJSON(arguments); noChangeArgs["no_change_needed"] = true;
    auto noChange = executeTool(OpenCodeToolCall("unchanged", "run", noChangeArgs.toString()), workspace);
    assert(!noChange.failed && parseJSON(noChange.output)["noChangeNeeded"].boolean, noChange.output);
    ChatMessage proof; proof.id = "unchanged"; proof.parentId = plain.id; proof.role = "tool";
    proof.toolName = "run"; proof.toolArgs = noChangeArgs.toString(); proof.content = noChange.output;
    proof.verificationCheck = noChange.verification.check; proof.verificationScope = already.verificationScope;
    already.messages ~= proof; already.activeLeafId = proof.id;
    assert(taskHasActionEvidence(already), "Verified already-satisfied outcome required a fabricated source edit");
    const checkerText = readText(buildPath(workspace, "checker.py"));
    remove(buildPath(workspace, "checker.py"));
    already.verificationStatus = "required";
    assert(missingVerificationInput(already).endsWith("checker.py"));
    assert(taskContinuation(already, true, false).remaining.indexOf("checker.py") >= 0,
        "A deleted checker produced a vague verification loop instead of naming the missing input");
    write(buildPath(workspace, "checker.py"), checkerText);
    assert(missingVerificationInput(already).length == 0, "Restored inputs retained a stale missing-file diagnosis");
    already.verificationStatus = "passed";
    auto foreign = proof;
    auto foreignReport = parseJSON(foreign.content);
    foreignReport["workspace"] = buildPath(root, "unrelated-project");
    foreignReport["inputs"] = ["missing-checker.py"];
    foreign.content = foreignReport.toString();
    assert(missingRecipeInput(foreign, already.verificationScope).length == 0,
        "An unrelated checkout's receipt redirected the current task's repair");
    auto compileOnly = runVerificationRecipe(
        `{"inputs":["artifact.txt"],"no_change_needed":true,"steps":[{"kind":"compile","command":{"program":"dmd"}}]}`,
        workspace, (JSONValue) => VerificationRun("OK", false, false, "dmd compile"));
    assert(!compileOnly.passed, "Compilation alone certified the unchanged requested behavior");
    write(buildPath(workspace, "saved-check.json"),
        `{"inputs":["artifact.txt"],"steps":[{"kind":"tests","command":{"program":"python"}}]}`);
    auto savedNoChange = runVerificationRecipe(`{"recipe":"saved-check.json","no_change_needed":true}`,
        workspace, (JSONValue) => VerificationRun("PASS behavior", false, false, "python tests"));
    assert(savedNoChange.passed && parseJSON(savedNoChange.output)["noChangeNeeded"].boolean,
        "Saved recipe ignored the explicit already-satisfied outcome");
    write(buildPath(workspace, "scratch.tmp"), "unrelated generated output");
    remove(buildPath(workspace, "scratch.tmp"));
    const oldScope = session.verificationScope;
    invalidateToolWorkspace(workspace);
    session.verificationScope = verificationScope(workspace, toolWorkspaceRevision(workspace));
    OpenCodeEvent cleanup; cleanup.toolName = "remove"; cleanup.workspaceChanged = true;
    ToolSettlement cleanupResult; cleanupResult.message.toolName = "remove";
    advanceToolTaskState(session, cleanupResult, cleanup, `{}`, "passed", oldScope);
    assert(session.verificationStatus == "passed", "Shared desktop/actor transition lost unchanged checked-run proof");
    remove(buildPath(workspace, "artifact.txt"));
    invalidateToolWorkspace(workspace);
    session.verificationScope = verificationScope(workspace, toolWorkspaceRevision(workspace));
    advanceToolTaskState(session, cleanupResult, cleanup, `{}`, "passed", oldScope);
    assert(session.verificationStatus == "required", "Missing deliverable retained verification");
    auto background = executeTool(OpenCodeToolCall("bad", "run",
        `{"program":"python","args":["-B","checker.py"],"check":"tests","inputs":["checker.py"],"background":true}`), workspace);
    assert(background.failed && readText(buildPath(workspace, "count")) == "2");
    write(buildPath(workspace, "artifact.txt"), "wrong");
    const before = toolWorkspaceRevision(workspace);
    auto failing = scheduleToolBatch(client, 2, [OpenCodeToolCall("fail-check", "run", arguments)], workspace,
        new ToolCancellation(), ChangeContext.init);
    failing.wait(); client.drain(events);
    bool failed;
    foreach (event; events) if (!event.toolRunning && event.toolCallId == "fail-check") failed = event.toolFailed;
    assert(failed && toolWorkspaceRevision(workspace) > before, "Failed checked command did not invalidate the source revision");
    mkdirRecurse(buildPath(workspace, "tests"));
    write(buildPath(workspace, "tests", "test_behavior.py"), "assert 2 + 2 == 4\n");
    const directArgs = `{"program":"python","args":["-u","-B","tests/test_behavior.py"]}`;
    auto direct = scheduleToolBatch(client, 3, [OpenCodeToolCall("direct-check", "run", directArgs)], workspace,
        new ToolCancellation(), ChangeContext.init);
    direct.wait(); client.drain(events);
    OpenCodeEvent directEvent;
    foreach (event; events) if (!event.toolRunning && event.toolCallId == "direct-check") directEvent = event;
    assert(!directEvent.toolFailed && directEvent.verificationCheck == "python tests" && !directEvent.workspaceChanged,
        "A real direct test passed but left the task looking unverified");
    ChatSession directSession;
    directSession.verificationScope = verificationScope(workspace, toolWorkspaceRevision(workspace));
    directSession.verificationStatus = "required"; directSession.taskStatus = "active";
    auto directPolicy = ToolResultPolicy(false, workspace, workspace, "now", toolWorkspaceRevision(workspace));
    auto directReceipt = settleToolResult(directSession, directEvent, directArgs, directPolicy);
    assert(directReceipt.acceptedVerification, directReceipt.message.content);
    directSession.messages ~= directReceipt.message;
    advanceToolTaskState(directSession, directReceipt, directEvent, directArgs, "required", directSession.verificationScope);
    assert(directSession.verificationStatus == "passed" && directSession.taskStatus == "completed");
    writeln("PASS actual single-process custom check, durable receipt, shared cleanup preservation, deleted-input rejection and failed-check invalidation");
}
