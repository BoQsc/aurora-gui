module early_plan_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : OpenCodeToolCall, Settings, saveSettings,
    setOpencodeStateDirectoryForTesting, opencodeTheme;
import auroraopencode.tools : buildSystemPrompt;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, write, readText, exists, tempDir;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    environment["AURORA_STRICT_PLAN"] = "0";
    const state = buildPath(tempDir(), "aurora-early-plan-" ~ to!string(MonoTime.currTime.ticks));
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
        if (root.toolMessageCountForTesting() != target)
            writeln("run mismatch: target=", target, " got=", root.toolMessageCountForTesting(),
                " pending=", root.pendingToolResultsForTesting(),
                " last user=", root.lastUserMessageForTesting(),
                " last tool=", root.lastToolResultForTesting());
        assert(root.toolMessageCountForTesting() == target, "Expected " ~ to!string(target) ~
            " tool messages, got " ~ to!string(root.toolMessageCountForTesting()) ~
            "; last result: " ~ root.lastToolResultForTesting());
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
        assert(root.lastToolResultForTesting().indexOf("Plan updated") >= 0, root.lastToolResultForTesting());
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
    assert(root.lastUserMessageForTesting().indexOf("Plan progress checkpoint") >= 0 &&
        root.lastUserMessageForTesting().indexOf("update_plan") >= 0,
        "A long investigation without a plan received no planning reminder: " ~
        root.lastUserMessageForTesting());
    run([readCall()]);
    assert(root.lastToolResultForTesting().indexOf("actual evidence") >= 0,
        "Advisory planning blocked useful inspection in normal mode");
    record(plan);
    assert(root.taskStepCountForTesting() == 3);
    run([readCall()]);
    assert(root.lastToolResultForTesting().indexOf("actual evidence") >= 0,
        "Recording the plan did not release the deferred exploration");
    writeln("PASS a long investigation without a plan is asked for one, then continues after the plan is recorded");

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

    // A plan that runs a full upkeep window without being refreshed is stale:
    // the reminder repeats once per window while the drift lasts and a refresh
    // clears it. Work does not wait for the plan. (The detached-plan card's
    // stale badge is covered by tool_feedback_ui_contracts, which runs with the
    // panel enabled.)
    const usersBefore = root.userMessageCountForTesting();
    context(4);
    assert(root.userMessageCountForTesting() == usersBefore, "A short healthy phase still forced plan maintenance");
    context(5);
    assert(root.userMessageCountForTesting() == usersBefore,
        "Plan upkeep arrived before its window");
    context(1);
    assert(root.userMessageCountForTesting() == usersBefore + 1 &&
        root.lastUserMessageForTesting().indexOf("Plan upkeep") >= 0,
        "A plan that ran a full upkeep window without a refresh received no reminder: " ~
        root.lastUserMessageForTesting());
    context(9);
    assert(root.userMessageCountForTesting() == usersBefore + 1, "Plan upkeep repeated inside its window");
    context(1);
    assert(root.userMessageCountForTesting() == usersBefore + 1,
        "An unchanged work phase received repeated upkeep lectures");
    record(advanced);
    assert(root.toolResultsSincePlanUpdateForTesting() == 0,
        "A refreshed plan kept its stale tool-result count");
    const usersAfterRefresh = root.userMessageCountForTesting();
    context(9);
    assert(root.userMessageCountForTesting() == usersAfterRefresh,
        "A refreshed plan was reminded again too soon");
    context(1);
    assert(root.userMessageCountForTesting() == usersAfterRefresh + 1,
        "A refreshed plan should be reminded again after a full window");
    writeln("PASS a long phase reissues plan upkeep once per window and a refresh clears it");

    // A checklist that stays stale past the second window no longer waits for a
    // reminder alone: the next edit batch is deferred once so the plan is
    // checked off before more work, and the retried call then runs.
    context(10);
    assert(root.toolResultsSincePlanUpdateForTesting() == 20,
        "the upkeep gate fixture did not reach the second window");
    const gateFile = buildPath(state, "upkeep-gate.md");
    run([OpenCodeToolCall("upkeep_gate_write", "write",
        `{"filePath":` ~ JSONValue(gateFile).toString ~ `,"content":"gate"}`)]);
    assert(root.lastToolResultForTesting().indexOf("deferred for plan upkeep") >= 0,
        "A stale checklist did not defer the next edit: " ~ root.lastToolResultForTesting());
    assert(!exists(gateFile), "The deferred edit ran anyway");
    assert(root.lastUserMessageForTesting().indexOf("Plan upkeep gate") >= 0,
        "The deferral did not require the plan to be reconciled");
    record(advanced);
    run([OpenCodeToolCall("upkeep_gate_retry", "write",
        `{"filePath":` ~ JSONValue(gateFile).toString ~ `,"content":"gate"}`)]);
    assert(exists(gateFile), "The retried edit did not run after the plan was refreshed");
    writeln("PASS a checklist that stays stale defers one edit batch until the plan is reconciled");

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

    root.setStrictPlanEnabledForTesting(false);
    fresh();
    root.setTaskStateForTesting("Write and optionally verify the phase document", "active", "not_required");
    const phasePlan = `{"plan":[{"id":"inspect","step":"Inspect inputs","kind":"research","status":"in_progress"},{"id":"edit","step":"Write phase document","kind":"edit","status":"pending"},{"id":"check","step":"Verify phase document","kind":"verify","status":"pending"}]}`;
    record(phasePlan);
    run([readCall()]);
    const phaseFile = buildPath(state, "phase.md");
    const beforeEdit = root.userMessageCountForTesting();
    run([OpenCodeToolCall("phase_write", "write", `{"filePath":` ~ JSONValue(phaseFile).toString ~ `,"content":"phase complete"}`)]);
    assert(root.userMessageCountForTesting() == beforeEdit + 1 &&
        root.lastUserMessageForTesting().indexOf("Work now includes editing or verification") >= 0);
    assert(root.taskStepStatusForTesting(0) == "in_progress", "A phase reminder fabricated completion");
    run([readCall(), readCall()]);
    assert(root.userMessageCountForTesting() == beforeEdit + 1, "Phase guidance repeated without a phase change");
    auto phaseAdvanced = parseJSON(phasePlan);
    phaseAdvanced["plan"][0]["status"] = "completed";
    phaseAdvanced["plan"][1]["status"] = "in_progress";
    record(phaseAdvanced.toString());
    const beforeCheck = root.userMessageCountForTesting();
    assert(root.verificationStatusForTesting() == "not_required");
    // The check receipt is injected: this fixture covers the plan reconciliation
    // around an accepted verification, while process execution itself is
    // covered by tools_test and the live application.
    root.injectToolResultForTesting("run", "OK", false,
        `{"program":"python","args":["-u","-B","-m","unittest","test_phase"]}`,
        0, 0, "", null, "unittest");
    assert(root.verificationStatusForTesting() == "passed", "An accepted optional check could not satisfy a recorded verification outcome");
    assert(root.userMessageCountForTesting() == beforeCheck + 1 &&
        root.lastUserMessageForTesting().indexOf("Work now includes editing or verification") >= 0);
    foreach (ref step; phaseAdvanced["plan"].array) step["status"] = "completed";
    record(phaseAdvanced.toString());
    foreach (i; 0 .. 3) assert(root.taskStepStatusForTesting(i) == "completed");
    writeln("PASS editing and accepted verification trigger bounded reconciliation without delaying tools or fabricating ticks");

    fresh();
    record(`{"plan":[{"id":"project","step":"Deliver the document","kind":"edit","status":"in_progress"}]}`);
    run([OpenCodeToolCall("current-phase-write", "write", `{"filePath":` ~ JSONValue(phaseFile).toString ~ `,"content":"phase complete"}`)]);
    record(`{"work_items":[{"id":"child-check","step":"Verify document","kind":"verify","status":"in_progress","done":"Regression tests pass"}]}`);
    const beforeChildCheck = root.userMessageCountForTesting();
    // Same receipt, injected: this fixture covers the plan/work tracking around
    // an accepted check, not process execution.
    root.seedPendingToolBatchForTesting([
        OpenCodeToolCall("child-check-receipt", "run",
            `{"program":"python","args":["-u","-B","-m","unittest","test_phase"]}`)]);
    root.injectToolResultForTesting("run", "OK", false,
        `{"program":"python","args":["-u","-B","-m","unittest","test_phase"]}`,
        0, 0, "", null, "unittest");
    assert(root.userMessageCountForTesting() == beforeChildCheck && !root.planNeedsUpdateForTesting(),
        "A tracked verification action incorrectly made its broader outcome stale");
    record(`{"work_items":[{"id":"child-check","status":"completed","evidence":["child-check-receipt"]}]}`);
    assert(root.taskStepStatusForTesting(0) == "in_progress");
    writeln("PASS detailed work tracks a phase within a broader outcome without forcing a checklist rewrite");

    // The normal path never rejects useful edits merely to refresh a plan.
    root.setStrictPlanEnabledForTesting(false);
    fresh(); record(plan); context(23);
    const smoothFile = buildPath(state, "normal-stale-plan.md");
    run([OpenCodeToolCall("normal-stale-write", "write",
        `{"filePath":` ~ JSONValue(smoothFile).toString ~ `,"content":"useful work"}`)]);
    assert(exists(smoothFile), "Default upkeep still deferred authorized work");
    assert(root.taskStepStatusForTesting(0) == "in_progress", "Upkeep fabricated completed research");
    auto prompt = buildSystemPrompt(true, state, "win32");
    assert(prompt.indexOf("Simple edits, lookups and answers") >= 0);
    assert(prompt.indexOf("mark it done and advance") >= 0);
    assert(prompt.indexOf("Call update_plan before the first substantive action on every request") < 0);
    writeln("PASS default stale-plan upkeep permits useful edits and keeps unfinished work honest");
    window.close();
    return 0;
}
