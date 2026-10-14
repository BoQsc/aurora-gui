module resume_tool_handoff_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import auroraopencode.tools : runFilesystemHelperMode;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.json : JSONValue;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;

int main(string[] args)
{
    const helper = runFilesystemHelperMode(args); if (helper >= 0) return helper;
    const mode = environment.get("AURORA_RESUME_MODE", "continue");
    const state = absolutePath("resume-state-" ~ mode ~ "-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(state, "workspace"); mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = environment.get("AURORA_CONTRACT_PROVIDER_BASE");
    settings.apiKey = "synthetic"; settings.model = "resume-" ~ mode;
    settings.toolsEnabled = true; settings.workspace = workspace; settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options; options.width = 1000; options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    auto driver = new UiTestDriver(window);
    scope(exit) root.shutdownClient();
    void pump() { window.onNativeTick(0.02); Thread.sleep(5.msecs); }
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready) pump();
    assert(!root.startupPendingForTesting());
    root.newChatForTesting();
    root.enableToolsForTesting(workspace);
    root.addConversationForTesting(["user"], ["List this fixture workspace and reply RESUMED."]);
    root.startTurnClockForTesting(); root.beginStreamForTesting();
    root.streamContentForTesting("Interrupted fixture reply.");
    root.stopActiveTurnForTesting(); root.projectTranscriptForTesting();
    assert(!root.turnBusyForTesting());
    if (mode == "continue" || mode == "regenerate")
    {
        int target = -1;
        foreach (index; 0 .. 40) if (root.bubbleActionForTesting(index) == "Regenerate") { target = index; break; }
        assert(target >= 0, "No resume actions after Stop");
        if (mode == "regenerate") assert(root.invokeBubbleActionForTesting(target));
        else {
            assert(driver.paint());
            const bubble = root.messageBubbleGlobalBoundsForTesting(target);
            const action = root.bubbleSecondaryActionBoundsForTesting(target);
            assert(action.width > 0, "No Continue secondary action");
            driver.click(Point(bubble.x + action.x + action.width / 2, bubble.y + action.y + action.height / 2));
        }
    }
    else if (mode == "queued")
    {
        root.queueFollowUpForTesting("List this fixture workspace and reply RESUMED.");
        root.projectTranscriptForTesting();
        assert(root.clickQueuedPromptActionForTesting(0));
    }
    else
    {
        root.setInputForTesting("List this fixture workspace and reply RESUMED.");
        root.sendForTesting();
    }
    const started = MonoTime.currTime;
    const deadline = started + 8.seconds;
    while (MonoTime.currTime < deadline)
    {
        pump();
        if (!root.turnBusyForTesting() && root.lastAssistantContentForTesting() == "RESUMED") break;
    }
    const success = !root.turnBusyForTesting() && root.pendingToolResultsForTesting() == 0 &&
        root.lastAssistantContentForTesting() == "RESUMED";
    const retained = root.totalMessageCountForTesting();
    root.stopActiveTurnForTesting();
    root.injectToolResultIdForTesting("listing", "dshell");
    assert(root.totalMessageCountForTesting() == retained, "Stop accepted a late native result");
    root.persistForTesting(); root.flushRepositoryForTesting();
    JSONValue row; row["mode"] = mode; row["passed"] = success;
    row["elapsedMs"] = (MonoTime.currTime - started).total!"msecs";
    row["lateResultRejected"] = true;
    write("result.json", row.toPrettyString()); writeln(row.toString());
    return success ? 0 : 1;
}
