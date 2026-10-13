module tool_feedback_ui_contracts;
import aurora;
import auroraopencode.core;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.logging : setLogDirectory, setDebugLogging, logInfo, logError, flushLogs;
import auroraopencode.crashguard : noteActivity, lastActivity;
import core.time : MonoTime, seconds, msecs;
import core.thread : Thread;
import std.file : mkdirRecurse, readText;
import std.path : buildPath, absolutePath;
import std.conv : to;
import std.array : replicate;
import std.string : indexOf;
import std.stdio : writeln;

int main()
{
    const state = absolutePath("tool-feedback-ui-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state); setOpencodeStateDirectoryForTesting(state);
    Settings settings; settings.baseUrl = "http://127.0.0.1:9"; settings.quickTitle = false; saveSettings(settings);
    WindowOptions options; options.width = 1200; options.height = 800; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme()); auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope (exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void pump() { window.onNativeTick(0.02); root.projectTranscriptForTesting(); assert(driver.paint()); Thread.sleep(5.msecs); }
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready) pump();
    assert(!root.startupPendingForTesting()); root.pauseToolContinuationForTesting();

    root.newChatForTesting(); root.addConversationForTesting(["user"], ["short"]); pump();
    assert(root.beginInlineEditForTesting(0)); pump();
    const shortHeight = root.inlineEditHeightForTesting();
    root.setInlineEditTextForTesting("line one\nline two\nline three\nline four\n"); pump();
    assert(root.inlineEditHeightForTesting() > shortHeight, "The inline editor remained sized to the original message");
    assert(root.messageContentForTesting(0) == "short", "Typing changed the original saved message");
    root.setInlineEditTextForTesting("a long draft line\n".replicate(80)); pump();
    assert(root.inlineEditHeightForTesting() <= 320 && root.inlineEditHeightForTesting() > shortHeight);
    assert(root.transcriptRowsSequentialForTesting());
    root.rebuildForTesting(); pump();
    assert(root.inlineEditActiveForTesting() && root.inlineEditTextForTesting() == "a long draft line\n".replicate(80),
        "Transcript rebuilding discarded the open inline draft");
    window.saveScreenshot("build/inline-growing-draft.ppm");
    root.cancelInlineEditForTesting(); pump();
    assert(root.messageContentForTesting(0) == "short" && root.totalMessageCountForTesting() == 1);
    assert(root.beginInlineEditForTesting(0));
    root.setInlineEditTextForTesting("saved\nmultiline");
    assert(root.commitInlineEditForTesting("saved\nmultiline") >= 0); pump();
    assert(root.totalMessageCountForTesting() == 2, "Save lost the original message version");
    root.persistForTesting(); root.reloadSessionsForTesting(); pump();
    assert(root.totalMessageCountForTesting() == 2);
    writeln("PASS inline drafts grow with edited text, cap height, cancel without changing history, and preserve both versions on Save/reload");

    root.newChatForTesting(); root.addConversationForTesting(["user", "assistant"], ["Implement and verify a change", ""]);
    root.injectToolResultForTesting("update_plan", "Plan updated", false,
        `{"plan":[{"step":"Investigate","status":"in_progress"},{"step":"Implement","status":"pending"},{"step":"Verify","status":"pending"}]}`);
    foreach (_; 0 .. 8) root.injectToolResultForTesting("read", "source evidence", false, `{"filePath":"source.d"}`);
    pump(); assert(root.planNeedsUpdateForTesting());
    assert(!root.queueStalePlanGuidanceForTesting(), "Same-phase guidance repeated");
    root.injectToolResultForTesting("edit", "Edited source", false, `{"filePath":"source.d"}`, 1, 1, "@@ -1 +1 @@\n-old\n+new\n");
    pump(); assert(root.lastUserMessageForTesting().indexOf("9 tool results") >= 0,
        "Moving from inspection to editing did not reissue the stale-plan reminder");
    assert(!root.queueStalePlanGuidanceForTesting());
    root.injectToolResultForTesting("update_plan", "Plan updated", false,
        `{"plan":[{"step":"Investigate","status":"completed"},{"step":"Implement","status":"completed"},{"step":"Verify","status":"in_progress"}]}`);
    pump(); assert(!root.planNeedsUpdateForTesting() && root.toolResultsSincePlanUpdateForTesting() == 0);
    writeln("PASS visible stale-plan status, one reminder per phase, editing transition and clearing the warning after a fresh plan");

    const logs = buildPath(state, "quiet-logs"); mkdirRecurse(logs); setLogDirectory(logs);
    setDebugLogging(false); noteActivity("rebuild quiet-marker");
    assert(lastActivity() == "rebuild quiet-marker");
    logInfo("important lifecycle metadata"); logError("important error"); assert(flushLogs());
    auto text = readText(buildPath(logs, "errors.log"));
    assert(text.indexOf("quiet-marker") < 0 && text.indexOf("important lifecycle metadata") >= 0 && text.indexOf("important error") >= 0);
    setDebugLogging(true); noteActivity("rebuild enabled-marker"); assert(flushLogs());
    assert(readText(buildPath(logs, "errors.log")).indexOf("[DEBUG] activity: rebuild enabled-marker") >= 0);
    setDebugLogging(false);
    writeln("PASS layout markers stay available for crash reporting, verbose disk output is opt-in, and normal lifecycle/error diagnostics remain enabled");
    return 0;
}
