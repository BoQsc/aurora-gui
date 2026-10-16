module task_continuation_ui_contracts;
import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, exists, readText, tempDir;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.string : indexOf;
import std.stdio : writeln;
import auroraopencode.tools : executeTool;
import std.json : JSONValue;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run test_task_continuation.py");
    const state = buildPath(tempDir(), "aurora-continuation-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(state, "workspace");
    mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = base; settings.apiKey = "fixture"; settings.model = "continuation-fixture";
    settings.workspace = workspace; settings.toolsEnabled = true; settings.quickTitle = false;
    settings.legacyTools = false;
    saveSettings(settings);
    WindowOptions options;
    options.width = 1000; options.height = 700; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void pump()
    {
        window.onNativeTick(0.02);
        root.projectTranscriptForTesting();
        assert(driver.paint());
        Thread.sleep(5.msecs);
    }
    void until(bool delegate() done)
    {
        const deadline = MonoTime.currTime + 20.seconds;
        while (!done() && MonoTime.currTime < deadline) pump();
        assert(done(), "Did not settle: " ~ root.lastAssistantContentForTesting() ~
            " error=" ~ root.lastAssistantErrorForTesting());
    }
    void send(string text) { root.setInputForTesting(text); root.sendForTesting(); }
    void settled() { until(delegate() { return !root.turnBusyForTesting(); }); }
    until(delegate() { return !root.startupPendingForTesting(); });

    root.newChatForTesting();
    send("Finish all six fixture steps.");
    settled();
    assert(root.taskStatusForTesting() == "completed");
    foreach (i; 0 .. 6)
    {
        assert(root.taskStepStatusForTesting(i) == "completed");
        assert(readText(buildPath(workspace, "step" ~ to!string(i) ~ ".md")) == "outcome" ~ to!string(i));
    }
    assert(root.lastAssistantContentForTesting() == "All six outcomes completed.");
    writeln("PASS real HTTP/tools/UI continue five premature partial replies through all six outcomes");

    // Prepare a repository outside the conversation; the actual commit-only
    // turn then runs through the real scheduler, tool results and done handler.
    foreach (args; [["init"], ["config", "user.name", "Fixture"], ["config", "user.email", "fixture@example.invalid"]])
    {
        JSONValue value; value["program"] = "git"; value["args"] = JSONValue.emptyArray;
        foreach (arg; args) value["args"].array ~= JSONValue(arg);
        const result = executeTool(OpenCodeToolCall("setup", "run", value.toString()), workspace);
        assert(!result.failed, result.output);
    }
    root.newChatForTesting();
    send("Commit existing work only.");
    settled();
    assert(root.taskStatusForTesting() == "completed");
    assert(root.verificationStatusForTesting() == "not_required");
    assert(root.lastAssistantContentForTesting() == "Existing work committed; working tree checked.");
    root.persistForTesting(); root.reloadSessionsForTesting();
    assert(root.taskStatusForTesting() == "completed" && root.verificationStatusForTesting() == "not_required");
    writeln("PASS a verified commit-only turn finishes without redundant continuation, including after reload");

    root.newChatForTesting();
    send("Implement the fixture stalled task.");
    settled();
    assert(root.taskStatusForTesting() == "completed" && root.turnStatusForTesting() == "completed");
    assert(root.lastAssistantErrorForTesting().length == 0);
    assert(root.taskStepStatusForTesting(0) == "completed");
    assert(readText(buildPath(workspace, "recovered.md")) == "Recovered outcome");
    root.persistForTesting(); root.reloadSessionsForTesting();
    assert(root.taskStatusForTesting() == "completed");
    writeln("PASS recurring diagnosis recovers past the old stall limit and persists completion");

    root.newChatForTesting();
    send("Implement the fixture tool recovery task.");
    settled();
    assert(root.taskStatusForTesting() == "completed" && root.lastAssistantErrorForTesting().length == 0);
    assert(root.taskStepStatusForTesting(0) == "completed");
    assert(readText(buildPath(workspace, "tool-recovered.md")) == "Alternative succeeded");
    writeln("PASS forty failed tool calls recover through two checkpoints without a user restart");

    foreach (scenario; ["malformed output", "external obstacle"])
    {
        root.newChatForTesting();
        send("Implement the fixture " ~ scenario ~ " task.");
        settled();
        assert(root.taskStatusForTesting() == "completed" && root.lastAssistantErrorForTesting().length == 0);
        assert(root.taskStepStatusForTesting(0) == "completed");
    }
    assert(!exists(buildPath(workspace, "must-not-execute.md")), "Printed tool syntax was executed");
    assert(readText(buildPath(workspace, "output-recovered.md")) == "Recovered with valid tools");
    assert(readText(buildPath(workspace, "obstacle-recovered.md")) == "Recovered with valid tools");
    writeln("PASS repeated malformed output and a reported external obstacle recover internally");

    root.newChatForTesting();
    send("Implement the fixture task requiring a missing deployment address.");
    settled();
    assert(root.taskStatusForTesting() == "waiting_input");
    assert(root.lastAssistantContentForTesting() == "Which deployment server should I use?");
    assert(root.lastAssistantErrorForTesting().length == 0);
    writeln("PASS required input is reported explicitly and waits for the user");

    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Implement an old task"]);
    root.setTaskStateForTesting("Old implementation", "active", "not_required");
    root.applyPlanForTesting(`{"plan":[{"step":"Old unfinished step","status":"in_progress"}]}`);
    environment["AURORA_COMPUTER_USE"] = "1";
    send("What does the fixture pending plan mean?");
    settled();
    environment.remove("AURORA_COMPUTER_USE");
    assert(root.lastAssistantContentForTesting() == "The old implementation remains unfinished.");
    assert(root.taskStepStatusForTesting(0) == "in_progress");
    writeln("PASS a question about pending work answers without restarting implementation");

    root.newChatForTesting();
    send("Finish the fixture cancellation task.");
    until(delegate() { return root.lastAssistantContentForTesting() == "Partial cancellation response."; });
    root.clickSendButtonForTesting();
    assert(!root.turnBusyForTesting() && root.turnStatusForTesting() == "interrupted");
    const drain = MonoTime.currTime + 1300.msecs;
    while (MonoTime.currTime < drain) pump();
    assert(!root.turnBusyForTesting() && root.turnStatusForTesting() == "interrupted");
    assert(root.taskStepStatusForTesting(0) == "in_progress");
    assert(root.lastAssistantContentForTesting() == "Partial cancellation response.");
    writeln("PASS Stop preserves pending work and cannot be resurrected by the late done event");
    return 0;
}
