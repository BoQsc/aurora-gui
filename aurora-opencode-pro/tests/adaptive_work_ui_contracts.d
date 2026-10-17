module adaptive_work_ui_contracts;
import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import core.time : MonoTime, seconds, msecs;
import core.thread : Thread;
import std.file : tempDir, mkdirRecurse, readText;
import std.path : buildPath;
import std.conv : to;
import std.process : environment;
import std.json : parseJSON;
import std.stdio : writeln;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run test_adaptive_work.py");
    const directory = buildPath(tempDir(), "aurora-adaptive-work-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(directory, "workspace"); mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(directory);
    Settings settings; settings.baseUrl = base; settings.apiKey = "fixture";
    settings.model = "adaptive-work-fixture"; settings.workspace = workspace;
    settings.toolsEnabled = true; settings.legacyTools = false; settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void pump() { window.onNativeTick(0.02); root.projectTranscriptForTesting(); assert(driver.paint()); Thread.sleep(5.msecs); }
    const startup = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < startup) pump();
    root.newChatForTesting();
    root.setInputForTesting("Implement the adaptive work fixture."); root.sendForTesting();
    const deadline = MonoTime.currTime + 25.seconds;
    while (root.turnBusyForTesting() && MonoTime.currTime < deadline) pump();
    assert(!root.turnBusyForTesting(), root.lastAssistantErrorForTesting());
    assert(root.lastAssistantContentForTesting() == "Both required documents completed.");
    assert(readText(buildPath(workspace,"main.md")) == "Main document");
    assert(readText(buildPath(workspace,"compat.md")) == "Legacy compatibility");
    assert(root.taskStepCountForTesting() == 0, "Mini work was forced into a full checklist");
    assert(root.taskStatusForTesting() == "completed");
    const state = root.taskStateJsonForTesting();
    auto task = parseJSON(state);
    const items = task["taskContract"]["workItems"].array;
    assert(items.length == 3 && items[0]["status"].str == "completed" && items[1]["status"].str == "completed");
    assert(items[2]["status"].str == "deferred");
    assert(task["taskContract"]["workContext"]["detourReason"].str.length == 0);
    root.persistForTesting(); root.reloadSessionsForTesting();
    assert(root.taskStateJsonForTesting() == state);
    assert(root.totalMessageCountForTesting() > 10);
    writeln("PASS native work records, discoveries, read-only focused views, automatic continuation, follow-ups and reload");
    window.close(); return 0;
}
