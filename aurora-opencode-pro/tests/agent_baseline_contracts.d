module agent_baseline_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import auroraopencode.taskflow : planUpdateError, supportedStep;
import auroraopencode.taskmutation : applyTaskPlan;
import auroraopencode.taskcontinuation : unfinishedTask;
import auroraopencode.tools : builtinToolDefinitions;
import auroraopencode.planmode : setStrictPlanSetting;
import auroraopencode.tokenrate : TokenRateWindow;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    environment["AURORA_STRICT_PLAN"] = "0";
    setStrictPlanSetting(false);
    TokenRateWindow rate;
    assert(rate.observe(0, 0) == 0);
    foreach (i; 1 .. 50)
        assert(rate.observe(i * 10, i * 100) == 1000,
            "Constant streaming flickered at a sampling-window boundary");
    assert(rate.observe(490, 6000) == 0, "Silent output retained a stale rate");
    assert(rate.observe(30, 6100) == 0, "Authoritative token correction produced a negative rate");
    assert(rate.observe(40, 6200) == 1000);
    // The live figure must follow the current decode speed instead of dragging
    // a whole second of older samples behind it: a step from 100 to 400 t/s
    // has to read as the new speed within one window (400 ms).
    assert(TokenRateWindow.init.windowMs == 400,
        "the reset window lost its live span");
    TokenRateWindow step;
    assert(step.windowMs == 400);
    assert(step.observe(0, 0) == 0);
    foreach (i; 1 .. 11) step.observe(i * 10, i * 100);
    assert(step.observe(100, 1000) == 1000);
    int blending;
    foreach (i; 1 .. 4) blending = step.observe(100 + i * 40, 1000 + i * 100);
    assert(blending > 1000 && blending < 4000,
        "the live figure jumped instead of blending the speed change: " ~
        to!string(blending));
    const int settledStep = step.observe(260, 1400);
    assert(settledStep == 4000,
        "the live figure lagged the current decode speed: " ~
        to!string(settledStep));
    ChatSession session;
    session.contract.id = "request";
    session.verificationStatus = "required";
    const initial = `{"plan":[{"step":"Implement","status":"in_progress"},{"step":"Check","status":"pending"}]}`;
    assert(planUpdateError(session, initial, session.taskSteps).length == 0);
    assert(planUpdateError(session, `{"plan":[]}`, session.taskSteps).length == 0);
    applyTaskPlan(session, initial);
    const complete = `{"plan":[{"step":"Implement","status":"completed"},{"step":"Check","status":"completed"}]}`;
    assert(planUpdateError(session, complete, session.taskSteps).length == 0,
        "Checklist status required receipt bookkeeping");
    applyTaskPlan(session, complete);
    assert(supportedStep(session, session.taskSteps[0]));
    assert(unfinishedTask(session), "Completing a checklist bypassed independent verification");
    session.verificationStatus = "passed";
    assert(!unfinishedTask(session), "Completed checklist created synthetic continuation debt");
    const followup = `{"explanation":"The check exposed a remaining edge case","plan":[{"step":"Implement","status":"completed"},{"step":"Fix discovered edge case","status":"in_progress"},{"step":"Recheck","status":"pending"}]}`;
    assert(planUpdateError(session, followup, session.taskSteps).length == 0);
    applyTaskPlan(session, followup);
    assert(session.taskSteps.length == 3 && session.taskSteps[1].text == "Fix discovered edge case",
        "A revised complete plan silently retained obsolete checklist rows");
    assert(unfinishedTask(session), "A necessary discovered follow-up was lost");
    const invalid = `{"plan":[{"step":"A","status":"in_progress"},{"step":"B","status":"in_progress"}]}`;
    assert(planUpdateError(session, invalid, session.taskSteps).length > 0);
    foreach (tool; builtinToolDefinitions()) if (tool.name == "update_plan")
    {
        const schema = parseJSON(tool.parametersJson);
        assert(schema["properties"].object.length == 2);
        assert(schema["properties"]["plan"]["items"]["properties"].object.length == 2);
        assert(tool.description.length < 500, "Default plan schema still teaches custom bookkeeping");
    }
    writeln("PASS complete plan snapshots, discovered follow-ups, separate verification and compact tool schema");

    const state = buildPath(tempDir(), "aurora-agent-baseline-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.workspace = state; settings.apiKey = ""; settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) root.shutdownClient();
    void pump() { window.onNativeTick(0.02); Thread.sleep(5.msecs); }
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready) pump();
    void fresh(string request)
    {
        root.newChatForTesting(); root.pauseToolContinuationForTesting();
        root.addConversationForTesting(["user", "assistant"], [request, ""]);
    }
    void run(OpenCodeToolCall[] calls)
    {
        root.addConversationForTesting(["assistant"], [""]);
        const target = root.toolMessageCountForTesting() + cast(int) calls.length;
        root.injectToolCallsForTesting(calls);
        const deadline = MonoTime.currTime + 5.seconds;
        while ((root.toolMessageCountForTesting() < target || root.pendingToolResultsForTesting()) &&
            MonoTime.currTime < deadline) pump();
        assert(root.toolMessageCountForTesting() == target, "Tool-call/result pairing was lost");
    }
    fresh("Write two requested files.");
    root.setGoalForTesting("Write two requested files.", "active");
    const first = buildPath(state, "first.txt"), second = buildPath(state, "second.txt");
    auto writes = [OpenCodeToolCall("first", "write", `{"filePath":` ~ JSONValue(first).toString ~ `,"content":"first"}`),
         OpenCodeToolCall("second", "write", `{"filePath":` ~ JSONValue(second).toString ~ `,"content":"second"}`)];
    run(writes);
    assert(!exists(first) && !exists(second),
        "Goal mutations ran before the plan was recorded");
    run([OpenCodeToolCall("plan", "update_plan",
        `{"explanation":"Record the plan before the two-file change.","plan":[` ~
        `{"step":"Write both requested files","status":"in_progress"}]}`)]);
    run([OpenCodeToolCall("first-retry", "write", `{"filePath":` ~ JSONValue(first).toString ~ `,"content":"first"}`),
         OpenCodeToolCall("second-retry", "write", `{"filePath":` ~ JSONValue(second).toString ~ `,"content":"second"}`)]);
    assert(exists(first) && exists(second), "Planned goal work was deferred again");
    assert(readText(first) == "first" && readText(second) == "second");
    writeln("PASS a goal records its plan before the first multi-file mutation batch, then executes");

    fresh("Read the requested file.");
    root.setTaskStateForTesting("Read the requested file", "active", "not_required");
    foreach (i; 0 .. 3)
    {
        run([OpenCodeToolCall("read-" ~ to!string(i), "read", `{"filePath":` ~ JSONValue(first).toString ~ `}`)]);
        assert(root.lastToolResultForTesting().indexOf("Tool call skipped:") < 0,
            "A legitimate reread was suppressed before a pathological streak");
        if (i == 0) root.ensureDurableTaskCheckpointForTesting();
        else assert(!root.ensureDurableTaskCheckpointForTesting(),
            "Read-only tool output appended a redundant full task checkpoint");
    }
    run([OpenCodeToolCall("duplicate", "read", `{"filePath":` ~ JSONValue(first).toString ~ `}`)]);
    assert(root.lastToolResultForTesting().indexOf("Tool call skipped:") >= 0,
        "The live dispatcher missed a repeated read; streak=" ~ to!string(root.toolRepeatCountForTesting()) ~
        " result=" ~ root.lastToolResultForTesting());
    writeln("PASS live repeat guard allows rereads and stops an unchanged pathological streak");

    fresh("Measure live speed.");
    root.startTurnClockForTesting(); root.beginStreamForTesting();
    root.streamReasoningForTesting("Starting the stream clock");
    Thread.sleep(140.msecs);
    root.streamContentForTesting("A growing stream of output tokens establishes a visible decode rate.");
    assert(root.liveTokenRateTenthsForTesting() > 0);
    const deadline = MonoTime.currTime + 1400.msecs;
    while (MonoTime.currTime < deadline) pump();
    assert(root.liveTokenRateTenthsForTesting() == 0,
        "The UI retained a stale throughput number without new stream events");
    root.streamContentForTesting("The stream resumes with fresh output.");
    Thread.sleep(140.msecs);
    root.streamContentForTesting("And continues at the current speed.");
    assert(root.liveTokenRateTenthsForTesting() > 0, "Live throughput did not recover after a stall");
    root.projectTranscriptForTesting();
    auto driver = new UiTestDriver(window);
    assert(driver.paint());
    window.saveScreenshot("agent-baseline-throughput.bmp");
    root.finishStreamForTesting();
    assert(root.turnTokenRateTenthsForTesting() > 0);
    writeln("PASS 20 Hz throughput refresh expires stalled rates, recovers and retains the final mean");
    return 0;
}
