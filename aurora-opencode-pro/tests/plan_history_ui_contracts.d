module plan_history_ui_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings,
    setOpencodeStateDirectoryForTesting, opencodeTheme;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.file : mkdirRecurse, rmdirRecurse, tempDir;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.stdio : writeln;
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
        root.shutdownClient();
        window.close();
    }

    writeln("PASS update_plan revisions reach the persisted task state and survive a restart");
    return 0;
}
