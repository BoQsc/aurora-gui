module plan_history_ui_contracts;

import aurora;
import aurora.testing : UiTestDriver;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings,
    setOpencodeStateDirectoryForTesting, opencodeTheme;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.file : mkdirRecurse, rmdirRecurse, tempDir;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;
import std.uuid : randomUUID;

private OpenCodeRoot startRoot(ref GuiWindow window)
{
    WindowOptions options;
    options.renderer = RendererPreference.software;
    window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    {
        root.tickTree(0.02);
        Thread.sleep(5.msecs);
    }
    assert(!root.startupPendingForTesting());
    root.pauseToolContinuationForTesting();
    return root;
}

int main()
{
    auto directory = buildPath(tempDir(),
        "aurora-plan-history-" ~ randomUUID().toString());
    mkdirRecurse(directory);
    scope (exit) rmdirRecurse(directory);
    setOpencodeStateDirectoryForTesting(directory);
    Settings settings;
    settings.baseUrl = "http://127.0.0.1:1/v1";
    settings.apiKey = "";
    settings.quickTitle = false;
    settings.toolsEnabled = true;
    saveSettings(settings);

    {
        GuiWindow window;
        auto root = startRoot(window);
        root.addConversationForTesting(["user", "assistant"],
            ["Track the fix", "Planning"]);
        root.setTaskStateForTesting("Track the fix", "active", "not_required");

        // A real update_plan tool result goes through the app handler, and the
        // revision appears in the task state the app persists.
        root.injectToolResultForTesting("update_plan", "Plan updated", false,
            `{"objective":"Ship the parser fix","explanation":"Initial plan",` ~
            `"plan":[{"step":"Inspect inputs","id":"inspect","kind":"research","status":"pending"},` ~
            `{"step":"Patch parser","id":"patch","kind":"edit","status":"pending"}]}`);
        auto first = parseJSON(root.taskStateJsonForTesting());
        assert(first["planHistory"].type == JSONType.array,
            "The persisted task state has no plan history");
        assert(first["planHistory"].array.length == 1);
        assert(first["planHistory"][0]["source"].str == "update_plan");
        assert(first["planHistory"][0]["explanation"].str == "Initial plan");
        assert(first["planHistory"][0]["objective"].str == first["objective"].str);
        assert(first["planHistory"][0]["steps"].array.length == 2);
        assert(first["planHistory"][0]["steps"][1]["id"].str == "patch");

        // A status-only revision records a second snapshot and leaves the
        // first one untouched.
        root.injectToolResultForTesting("update_plan", "Plan updated", false,
            `{"plan_mode":"patch","plan":[{"id":"inspect","status":"in_progress"}]}`);
        auto second = parseJSON(root.taskStateJsonForTesting());
        assert(second["planHistory"].array.length == 2);
        assert(second["planHistory"][1]["steps"][0]["status"].str == "in_progress");
        assert(second["planHistory"][0]["steps"][0]["status"].str == "pending");

        root.flushRepositoryForTesting();
        root.shutdownClient();
        window.close();
    }

    // Relaunching against the same state restores every revision, not just the
    // live plan.
    {
        GuiWindow window;
        auto root = startRoot(window);
        auto restored = parseJSON(root.taskStateJsonForTesting());
        assert(restored["planHistory"].type == JSONType.array,
            "The restored task state lost its plan history");
        assert(restored["planHistory"].array.length == 2);
        assert(restored["planHistory"][0]["explanation"].str == "Initial plan");
        assert(restored["planHistory"][0]["source"].str == "update_plan");
        assert(restored["planHistory"][1]["steps"][0]["status"].str == "in_progress");

        // The action-group header stays generic; the settled tool result's
        // content must say what changed.
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["Show the plan change"]);
        const initial = `{"explanation":"Initial plan",` ~
            `"plan":[{"step":"Inspect inputs","id":"inspect","status":"pending"},` ~
            `{"step":"Patch parser","id":"patch","status":"pending"}]}`;
        root.injectToolResultForTesting("update_plan", "", false, initial);
        auto headers = root.toolGroupHeaderTextsForTesting();
        assert(headers.length == 1 &&
            headers[0].indexOf("Updated the plan") >= 0 &&
            headers[0].indexOf("Initial plan") < 0,
            "Plan details leaked into the action-group header: " ~
            (headers.length ? headers[0] : "(none)"));
        auto content = root.toolResultForTesting(0);
        assert(content.indexOf("Initial plan") >= 0 &&
            content.indexOf("Added \"Inspect inputs\" (pending)") >= 0 &&
            content.indexOf("Added \"Patch parser\" (pending)") >= 0,
            "Plan content omitted the initial change: " ~ content);

        // Patch updates carry only stable IDs, so resolve them against the
        // current checklist and name the step whose status changed.
        const patched = `{"plan_mode":"patch","plan":[{"id":"inspect","status":"in_progress"}]}`;
        root.injectToolResultForTesting("update_plan", "", false, patched);
        headers = root.toolGroupHeaderTextsForTesting();
        assert(headers.length == 1 &&
            headers[0].indexOf("Updated the plan") >= 0 &&
            headers[0].indexOf("Inspect inputs") < 0,
            "Plan patch detail leaked into the action-group header: " ~
            (headers.length ? headers[0] : "(none)"));
        content = root.lastToolResultForTesting();
        assert(content.indexOf(
            "\"Inspect inputs\": pending -> in progress") >= 0,
            "Plan content omitted the patched status change: " ~ content);

        // A routine full-plan progress update has no explanation. Its content
        // names both status transitions.
        const progressed = `{"plan":[` ~
            `{"step":"Inspect inputs","id":"inspect","status":"completed"},` ~
            `{"step":"Patch parser","id":"patch","status":"in_progress"}]}`;
        root.injectToolResultForTesting("update_plan", "", false, progressed);
        headers = root.toolGroupHeaderTextsForTesting();
        assert(headers.length == 1 &&
            headers[0].indexOf("Updated the plan") >= 0 &&
            headers[0].indexOf("Patch parser") < 0,
            "Routine progress leaked into the action-group header: " ~
            (headers.length ? headers[0] : "(none)"));
        content = root.lastToolResultForTesting();
        assert(content.indexOf(
            "\"Inspect inputs\": in progress -> completed") >= 0 &&
            content.indexOf(
                "\"Patch parser\": pending -> in progress") >= 0,
            "Plan content omitted routine progress: " ~ content);

        // A single-update fixture keeps the rendered content easy to inspect:
        // expand the action group and its tool row before capturing it.
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["Render plan content"]);
        root.applyPlanForTesting(initial);
        const rendered = `{"plan_mode":"patch","plan":[` ~
            `{"id":"inspect","status":"completed"},` ~
            `{"id":"patch","status":"in_progress"}]}`;
        root.injectToolResultForTesting("update_plan", "", false, rendered);
        root.projectTranscriptForTesting();
        root.toggleFirstToolGroupForTesting();
        root.toggleFirstToolBubbleForTesting();
        root.scrollToForTesting(int.max);
        auto driver = new UiTestDriver(window);
        assert(driver.paint(), "Expanded plan update content did not paint");
        assert(!root.firstToolGroupCollapsedForTesting() &&
            !root.firstToolBubbleCollapsedForTesting(),
            "The plan update content fixture did not stay expanded");
        window.saveScreenshot("build/plan-action-content.ppm");

        root.shutdownClient();
        window.close();
    }

    writeln("PASS update_plan revisions reach the persisted task state and survive a restart");
    return 0;
}
