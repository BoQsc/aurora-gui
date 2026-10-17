module task_policy_ui_contracts;

import aurora;
import auroraopencode.core;
import auroraopencode.appui;
import auroraopencode.tools : runFilesystemHelperMode;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.file : mkdirRecurse, write, read, tempDir;
import std.path : absolutePath, buildPath;
import std.json : JSONValue, JSONType, parseJSON;
import std.conv : to;
import std.string : indexOf;
import std.stdio : writeln;

int main(string[] arguments)
{
    const helper = runFilesystemHelperMode(arguments); if (helper >= 0) return helper;
    const directory = absolutePath(buildPath(tempDir(), "aurora-task-ui-" ~ to!string(MonoTime.currTime.ticks)));
    const workspace = buildPath(directory, "sandbox");
    const source = buildPath(directory, "real-checkout");
    const scratch = buildPath(directory, "scratch");
    const state = buildPath(directory, "state");
    mkdirRecurse(workspace); mkdirRecurse(scratch);
    mkdirRecurse(buildPath(source, ".git")); mkdirRecurse(buildPath(source, "src"));
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = "http://127.0.0.1:9/v1"; settings.apiKey = "fixture";
    settings.workspace = workspace; settings.toolsEnabled = true;
    settings.legacyTools = false; settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void pump()
    {
        window.onNativeTick(0.05); root.projectTranscriptForTesting();
        assert(driver.paint()); Thread.sleep(2.msecs);
    }
    auto deadline = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < deadline) pump();
    assert(!root.startupPendingForTesting());
    root.newChatForTesting(); root.pauseToolContinuationForTesting();
    root.addConversationForTesting(["user"], ["Make the browser render and interact correctly. Source: " ~ source]);
    root.setTaskStateForTesting("Render and interact correctly", "active", "required");
    root.applyPlanForTesting(`{"plan":[{"step":"Verify the requested outcome","status":"completed"}]}`);
    const input = buildPath(source,"src","main.d");
    const executable = buildPath(scratch,"main.exe");
    write(input, "void main() {}\n");
    const expected = buildPath(source,"expected.ppm");
    const actual = buildPath(scratch,"actual.ppm");
    write(expected, "P6\n1 1\n255\n" ~ cast(string)[cast(ubyte)20,40,60]);
    write(actual, read(expected));
    JSONValue compiler;
    compiler["program"] = "dmd";
    compiler["args"] = JSONValue(["-of=" ~ executable,input]);
    compiler["workdir"] = scratch;
    JSONValue compile; compile["kind"] = "compile"; compile["command"] = compiler;
    JSONValue invocation; invocation["program"] = executable; invocation["workdir"] = scratch;
    JSONValue tests; tests["kind"] = "tests"; tests["command"] = invocation;
    JSONValue interaction; interaction["kind"] = "interaction"; interaction["command"] = invocation;
    JSONValue render; render["kind"] = "render"; render["reference"] = expected;
    render["actual"] = actual; render["referenceSource"] = "Independent one-pixel fixture specification";
    JSONValue recipe; recipe["inputs"] = JSONValue(["src"]);
    recipe["steps"] = JSONValue([compile, tests, render, interaction]);
    const recipePath = buildPath(source,"verify.json"); write(recipePath, recipe.toPrettyString());
    JSONValue args; args["recipe"] = recipePath;
    void dispatch(OpenCodeToolCall call)
    {
        root.addConversationForTesting(["assistant"], [""]);
        const count = root.toolMessageCountForTesting();
        root.injectToolCallsForTesting([call]);
        const until = MonoTime.currTime + 15.seconds;
        while ((root.toolMessageCountForTesting() == count || root.pendingToolResultsForTesting()) && MonoTime.currTime < until) pump();
        assert(root.toolMessageCountForTesting() == count + 1 && !root.pendingToolResultsForTesting(), root.lastToolResultForTesting());
    }
    dispatch(OpenCodeToolCall("compile", "run", compiler.toString()));
    assert(root.verificationStatusForTesting() == "required", "Compilation cleared visual/interaction requirements");
    auto partial = parseJSON(recipe.toString());
    partial["steps"] = JSONValue([tests, render]);
    const partialPath = buildPath(source,"partial.json");
    write(partialPath, partial.toPrettyString());
    JSONValue partialArgs; partialArgs["recipe"] = partialPath;
    dispatch(OpenCodeToolCall("partial", "verify", partialArgs.toString()));
    const partialResult = parseJSON(root.lastToolResultForTesting());
    assert(partialResult["receipt"]["acceptedForCurrentSource"].type == JSONType.true_);
    assert(partialResult["receipt"]["coverageComplete"].type == JSONType.false_);
    assert(partialResult["receipt"]["toolCallId"].str == "partial");
    assert(root.verificationStatusForTesting() == "required");
    root.applyPlanForTesting(`{"plan":[{"id":"pixels","step":"Check pixels","kind":"verify","done":"Render matches","status":"in_progress"}]}`);
    dispatch(OpenCodeToolCall("finish-pixels", "update_plan",
        `{"plan":[{"id":"pixels","step":"Check pixels","status":"completed","evidence":["partial"]}]}`));
    bool pixelsComplete;
    foreach (row; parseJSON(root.taskStateJsonForTesting())["taskSteps"].array)
        if (row["id"].str == "pixels") pixelsComplete = row["status"].str == "completed";
    assert(pixelsComplete, root.lastToolResultForTesting());
    assert(root.verificationStatusForTesting() == "required");
    auto interactionOnly = parseJSON(recipe.toString());
    interactionOnly["steps"] = JSONValue([interaction]);
    const interactionPath = buildPath(source,"interaction.json");
    write(interactionPath, interactionOnly.toPrettyString());
    JSONValue interactionArgs; interactionArgs["recipe"] = interactionPath;
    dispatch(OpenCodeToolCall("interaction-only", "verify", interactionArgs.toString()));
    assert(root.verificationStatusForTesting() == "passed", root.lastToolResultForTesting());
    writeln("PASS partial native receipts complete their plan outcomes and aggregate coverage across separate checks");
    dispatch(OpenCodeToolCall("verify", "verify", args.toString()));
    assert(root.verificationStatusForTesting() == "passed", root.lastToolResultForTesting());
    writeln("PASS actual GUI/scheduler accepts a scratch-built external checkout's typed recipe and rejects compilation-only completion");
    write(actual, "P6\n1 1\n255\n" ~ cast(string)[cast(ubyte)21,40,60]);
    dispatch(OpenCodeToolCall("wrong-render", "verify", args.toString()));
    assert(root.verificationStatusForTesting() == "required", "Wrong pixels left the GUI verification state green");
    writeln("PASS a visual mismatch invalidates accepted GUI evidence");
    root.persistForTesting();
    root.reloadSessionsForTesting();
    root.pauseToolContinuationForTesting();
    dispatch(OpenCodeToolCall("after-failure-interaction", "verify", interactionArgs.toString()));
    assert(root.verificationStatusForTesting() == "required", "A partial check revived superseded receipts after reload");
    writeln("PASS failed checker boundary and receipt scope survive persistence and reload");

    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Owner's task"]);
    const owner = root.currentSessionForTesting();
    root.setSessionTurnStatusForTesting(owner, "running");
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Other task"]);
    const other = root.currentSessionForTesting();
    root.setSessionTurnStatusForTesting(other, "running");
    const marker = "owner-only-restart-diagnostic";
    JSONValue note; note["cause"] = marker; note["session"] = root.sessionIdForTesting(owner);
    write(buildPath(state,"restart-resume.json"), note.toString());
    const ownerBefore = root.sessionMessageCountForTesting(owner);
    const otherBefore = root.sessionMessageCountForTesting(other);
    root.prepareResumeForTesting();
    foreach (_; 0 .. 80) pump();
    bool ownerGotReason, otherGotNeutral;
    foreach (i; ownerBefore .. root.sessionMessageCountForTesting(owner))
        if (root.sessionMessageContentForTesting(owner,i).indexOf(marker) >= 0) ownerGotReason = true;
    foreach (i; otherBefore .. root.sessionMessageCountForTesting(other))
    {
        const content = root.sessionMessageContentForTesting(other,i);
        assert(content.indexOf(marker) < 0, "Resume diagnostics leaked from the owner into another chat");
        if (content.indexOf("conversation's own durable objective") >= 0) otherGotNeutral = true;
    }
    assert(ownerGotReason && otherGotNeutral, "Actual multi-chat restart did not append scoped notices");
    writeln("PASS actual restart resumes both chats with owner-scoped diagnostics");
    root.clearPendingResumeForTesting(); window.close();
    return 0;
}
