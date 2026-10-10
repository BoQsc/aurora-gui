module early_plan_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : OpenCodeToolCall, Settings, saveSettings,
    setOpencodeStateDirectoryForTesting, opencodeTheme;
import auroraopencode.tools : buildSystemPrompt;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, write, readText;
import std.json : JSONValue;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    environment["AURORA_STRICT_PLAN"] = "0";
    const state = absolutePath("early-plan-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    const evidence = buildPath(state, "evidence.txt");
    write(evidence, "actual evidence\n");
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.workspace = state; settings.apiKey = "";
    settings.quickTitle = false; settings.detachedPlan = false;
    saveSettings(settings);
    WindowOptions options;
    options.width = 1200; options.height = 800; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void pump()
    {
        window.onNativeTick(0.01);
        root.projectTranscriptForTesting();
        assert(driver.paint());
        Thread.sleep(5.msecs);
    }
    void fresh()
    {
        root.newChatForTesting();
        root.pauseToolContinuationForTesting();
        root.addConversationForTesting(["user", "assistant"], ["Investigate, fix and verify", ""]);
    }
    void context(int count)
    {
        foreach (i; 0 .. count)
            root.injectToolResultForTesting("read", "evidence " ~ to!string(i), false);
    }
    int identity;
    const readArgs = `{"filePath":` ~ JSONValue(evidence).toString ~ `}`;
    OpenCodeToolCall readCall()
    {
        return OpenCodeToolCall("read_" ~ to!string(++identity), "read", readArgs);
    }
    void run(const(OpenCodeToolCall)[] calls)
    {
        root.addConversationForTesting(["assistant"], [""]);
        const target = root.toolMessageCountForTesting() + cast(int) calls.length;
        root.injectToolCallsForTesting(calls);
        const deadline = MonoTime.currTime + 5.seconds;
        while ((root.toolMessageCountForTesting() < target || root.pendingToolResultsForTesting() > 0)
            && MonoTime.currTime < deadline) pump();
        assert(root.toolMessageCountForTesting() == target);
        assert(root.pendingToolResultsForTesting() == 0);
        pump();
    }
    const plan = `{"plan":[{"step":"Find the cause","status":"in_progress"},` ~
        `{"step":"Apply the fix","status":"pending"},` ~
        `{"step":"Check the result","status":"pending"}]}`;
    const advanced = `{"plan":[{"step":"Find the cause","status":"completed"},` ~
        `{"step":"Apply the fix","status":"in_progress"},` ~
        `{"step":"Check the result","status":"pending"}]}`;
    void record(string args)
    {
        run([OpenCodeToolCall("plan_" ~ to!string(++identity), "update_plan", args)]);
        assert(root.lastToolResultForTesting().indexOf("Plan updated") >= 0);
    }

    const startup = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < startup) pump();
    fresh();
    run([readCall()]);
    assert(root.lastToolResultForTesting().indexOf("actual evidence") >= 0);
    const quickFile = buildPath(state, "quick.md");
    run([OpenCodeToolCall("quick_edit", "write", `{"filePath":` ~
        JSONValue(quickFile).toString ~ `,"content":"one small edit"}`)]);
    assert(readText(quickFile) == "one small edit");
    assert(root.taskStepCountForTesting() == 0, "Quick edit was forced into a plan");
    writeln("PASS one lookup and a small edit execute without a plan or extra round");

    fresh(); context(3); run([readCall()]);
    assert(root.lastToolResultForTesting().indexOf("actual evidence") >= 0,
        "Normal mode blocked a read for a missing plan");
    writeln("PASS normal inspection continues without mandatory planning");

    fresh();
    run([readCall(), readCall(), readCall(), readCall(), readCall(), readCall(), readCall()]);
    assert(root.lastToolResultForTesting().indexOf("actual evidence") >= 0,
        "Normal mode blocked seven independent reads");
    assert(root.toolMessageCountForTesting() == 7);
    assert(root.taskStepCountForTesting() == 0);
    foreach (header; root.toolResultHeaderTextsForTesting())
        assert(header.indexOf("Deferred") < 0);
    writeln("PASS seven normal reads execute without synthetic planning results");

    fresh(); context(12);
    assert(root.lastUserMessageForTesting().indexOf("Progress guidance") >= 0 &&
        root.lastUserMessageForTesting().indexOf("update_plan") >= 0,
        "A long investigation without a plan received no advisory reminder: " ~
        root.lastUserMessageForTesting());
    run([readCall()]);
    assert(root.lastToolResultForTesting().indexOf("actual evidence") >= 0,
        "The advisory planning reminder blocked exploration");
    record(plan);
    assert(root.taskStepCountForTesting() == 3);
    writeln("PASS a long investigation without a plan gets an advisory reminder, not a pause");

    root.setStrictPlanEnabledForTesting(true);
    scope(exit) root.setStrictPlanEnabledForTesting(false);
    fresh(); run([readCall(), readCall(), readCall()]);
    assert(root.lastToolResultForTesting().indexOf("deferred for planning") >= 0);
    assert(root.toolMessageCountForTesting() == 3, "Tool protocol pairing was lost");
    assert(root.toolResultHeaderTextsForTesting().length == 0,
        "Strict planning pause leaked synthetic per-call output cards");
    size_t notices;
    void countNotices(Widget row)
    {
        if (row.id() == "oc-planning-pause") ++notices;
        foreach (child; row.children()) countNotices(child);
    }
    countNotices(root);
    assert(notices == 1, "A planning batch must show one concise status row");
    window.saveScreenshot("strict-plan-pause.bmp");
    run([readCall()]);
    assert(root.lastToolResultForTesting().indexOf("actual evidence") >= 0,
        "Refusing to plan deadlocked tool execution");
    writeln("PASS strict mode preserves protocol results with one visible pause, bounded to one deferral");

    fresh(); run([readCall(), readCall(), readCall()]);
    assert(root.lastToolResultForTesting().indexOf("deferred for planning") >= 0,
        "Large first inspection batch bypassed early planning");
    assert(root.explorationCountForTesting() == 3);
    writeln("PASS a large first inspection batch requests a plan before running");

    fresh(); context(3);
    run([OpenCodeToolCall("plan_and_read", "update_plan", plan), readCall()]);
    assert(root.taskStepCountForTesting() == 3);
    assert(root.taskStepStatusForTesting(0) == "in_progress");
    assert(root.planCardStepStatusForTesting(0) == "in_progress",
        "Early investigation was not visible in the rendered plan");
    assert(root.planCardStepStatusForTesting(1) == "pending");
    assert(root.lastToolResultForTesting().indexOf("actual evidence") >= 0);
    record(advanced);
    assert(root.planCardStepStatusForTesting(0) == "completed");
    assert(root.planCardStepStatusForTesting(1) == "in_progress");
    window.saveScreenshot("early-plan-progress.bmp");
    writeln("PASS a batch recording its plan executes; investigation and implementation render progressively");

    const usersBefore = root.userMessageCountForTesting();
    context(4);
    assert(root.userMessageCountForTesting() == usersBefore + 1);
    context(4);
    assert(root.userMessageCountForTesting() == usersBefore + 1, "Stale-plan reminder spammed");
    record(advanced);
    const usersAfterRefresh = root.userMessageCountForTesting();
    context(4);
    assert(root.userMessageCountForTesting() == usersAfterRefresh + 1,
        "Updating the plan did not rearm its progress reminder");
    writeln("PASS refresh guidance appears after four results, once per cycle, and rearms after an update");

    fresh();
    root.injectToolResultForTesting("update_plan", "invalid plan", true, "{}");
    context(3); run([readCall()]);
    assert(root.lastToolResultForTesting().indexOf("deferred for planning") >= 0,
        "Failed plan call falsely satisfied early planning");
    fresh();
    root.applyPlanForTesting(`{"plan":[{"step":"Earlier request","status":"completed"}]}`);
    context(3); run([readCall()]);
    assert(root.lastToolResultForTesting().indexOf("deferred for planning") >= 0,
        "Old completed checklist suppressed planning for a new request");
    writeln("PASS failed plan calls and earlier completed plans do not satisfy a new task");

    auto prompt = buildSystemPrompt(true, state, "win32");
    assert(prompt.indexOf("before substantial inspection") >= 0);
    assert(prompt.indexOf("before moving to the next phase") >= 0);
    assert(prompt.indexOf("single edits") >= 0);
    window.close();
    return 0;
}
