module goal_hold_contracts;

// Progress audits recover within a bounded budget and settle quietly; an audit
// never paints a failure row or stops the chat.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, OpenCodeToolCall,
    setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.conv : to;
import std.file : mkdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf, replace;

int main()
{
    const state = buildPath(tempDir(),
        "aurora-goal-hold-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(state, "workspace");
    mkdirRecurse(workspace);
    write(buildPath(workspace, "note.txt"), "readable note");
    setOpencodeStateDirectoryForTesting(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:1/v1","apiKey":"fixture",` ~
        `"model":"fixture","toolsEnabled":true,"workspace":` ~
        `"` ~ workspace.replace("\\", "\\\\") ~ `"}`);
    WindowOptions options;
    options.width = 900;
    options.height = 640;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope (exit) root.shutdownClient();
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    {
        window.onNativeTick(0.02);
        Thread.sleep(2.msecs);
    }
    assert(!root.startupPendingForTesting(), "Conversation startup did not settle");

    void pump()
    {
        window.onNativeTick(0.02);
        Thread.sleep(2.msecs);
    }
    foreach (issue; ["goal_audit_stalled", "task_audit_stalled"])
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user", "assistant"], ["Finish the parser fix", "It is done."]);
        root.setGoalForTesting("Finish the parser fix", "active");
        root.setTaskStateForTesting("Finish the parser fix", "active", "required");
        root.applyPlanForTesting(`{"plan":[{"step":"Verify the fix","status":"in_progress"}]}`);
        root.pauseToolContinuationForTesting();
        root.startTurnClockForTesting();
        root.injectOutputFailureForTesting(issue);
        assert(root.goalStatusForTesting() == "active" && root.turnStatusForTesting() == "running",
            "An unfinished task/goal silently paused instead of recovering");
        assert(root.taskStatusForTesting() == "active" && root.failedMessageCountForTesting() == 0,
            "Recoverable no-action output lost the task or created a failure bubble");
        bool recovery;
        foreach (i; 0 .. root.totalMessageCountForTesting())
            if (root.messageContentForTesting(i).indexOf("Agent output recovery:") >= 0) recovery = true;
        assert(recovery);
        foreach (_; 0 .. 3)
        {
            root.addConversationForTesting(["assistant"], ["Still done without a check."]);
            root.startTurnClockForTesting(); root.injectOutputFailureForTesting(issue);
        }
        assert(root.turnStatusForTesting() == "completed" && root.failedMessageCountForTesting() == 0,
            "Exhausted audit recovery stopped the chat with a failure row");
        assert(root.goalStatusForTesting() == "paused",
            "Exhaustion left the goal active with no running turn");
        assert(root.taskStatusForTesting() != "completed",
            "Exhaustion fabricated completion of the unfinished task");
        bool visible;
        foreach (i; 0 .. root.totalMessageCountForTesting())
            if (root.messageContentForTesting(i).indexOf("Agent output stalled") >= 0) visible = true;
        assert(!visible, "Audit exhaustion leaked a failure notice into the transcript");
        pump();
    }
    writeln("PASS task and goal audits recover quietly; exhaustion settles without stopping the chat");
    return 0;
}
