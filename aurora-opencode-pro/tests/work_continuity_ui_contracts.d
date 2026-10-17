module work_continuity_ui_contracts;
import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import core.time : MonoTime, msecs, seconds;
import core.thread : Thread;
import std.conv : to;
import std.file : tempDir, mkdirRecurse, readText;
import std.path : buildPath;
import std.process : environment;
import std.json : parseJSON;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run test_work_continuity.py");
    const directory = buildPath(tempDir(), "aurora-work-continuity-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(directory, "workspace"); mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(directory);
    Settings settings; settings.baseUrl = base; settings.apiKey = "fixture";
    settings.model = "continuity-fixture"; settings.workspace = workspace;
    settings.toolsEnabled = true; settings.legacyTools = false; settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void pump() { window.onNativeTick(0.02); root.projectTranscriptForTesting(); assert(driver.paint()); Thread.sleep(5.msecs); }
    void until(bool delegate() done)
    {
        const deadline = MonoTime.currTime + 15.seconds;
        while (!done() && MonoTime.currTime < deadline) pump();
        assert(done(), root.lastAssistantContentForTesting() ~ " error=" ~ root.lastAssistantErrorForTesting());
    }
    void send(string value) { root.setInputForTesting(value); root.sendForTesting(); }
    void settled() { until(delegate(){return !root.turnBusyForTesting();}); assert(!root.lastAssistantErrorForTesting().length); }
    until(delegate(){return !root.startupPendingForTesting();});
    root.newChatForTesting();
    send("Implement the fixture project.");
    until(delegate(){return root.lastAssistantContentForTesting() == "Initial stage ready; continuing.";});
    root.clickSendButtonForTesting();
    assert(root.turnStatusForTesting() == "interrupted");
    const initial = parseJSON(root.taskStateJsonForTesting());
    const identity = initial["taskContract"]["id"].str;
    const work = initial["taskContract"]["workContext"];
    assert(root.taskStepCountForTesting() == 3 && root.taskStepStatusForTesting(0) == "completed");
    assert(work["stepId"].str == "migrate" && work["returnTo"].str == "Finish the second outcome");
    const artifact = readText(buildPath(workspace, "first.md"));
    send("Investigate the fixture migration. Do not change any files.");
    settled();
    assert(root.taskObjectiveForTesting() == "Complete the fixture project");
    assert(root.taskStatusForTesting() == "active" && root.taskStepCountForTesting() == 3);
    const investigated = parseJSON(root.taskStateJsonForTesting());
    assert(investigated["taskContract"]["id"].str == identity);
    assert(investigated["taskContract"]["workContext"] == work);
    assert(investigated["taskArchive"].array.length == 0);
    assert(readText(buildPath(workspace,"first.md")) == artifact);
    assert(root.lastAssistantContentForTesting() == "The migration preserves the old record IDs.");
    const compaction = root.compactionSourceForTesting(32_000);
    assert(compaction.indexOf("Requested outcome: Implement the fixture project.") >= 0);
    assert(compaction.indexOf("Return to: Finish the second outcome") >= 0,
        "Compaction source dropped the original objective or work position");
    root.persistForTesting(); root.reloadSessionsForTesting();
    assert(parseJSON(root.taskStateJsonForTesting())["taskContract"]["workContext"] == work);
    assert(root.taskStepCountForTesting() == 3 && root.taskStepStatusForTesting(0) == "completed");
    send("Continue and finish the fixture project.");
    settled();
    assert(root.taskStatusForTesting() == "completed" && root.taskStepCountForTesting() == 3);
    foreach(i;0..3) assert(root.taskStepStatusForTesting(i) == "completed");
    assert(readText(buildPath(workspace,"second.md")) == "Second outcome");
    assert(readText(buildPath(workspace,"third.md")) == "Third outcome");
    const completed = parseJSON(root.taskStateJsonForTesting());
    assert(completed["taskContract"]["id"].str == identity && completed["taskContract"]["workContext"]["stepId"].str == "");
    send("New task: analyze another fixture.");
    settled();
    assert(root.taskStepCountForTesting() == 0 && root.taskStatusForTesting() == "completed");
    assert(parseJSON(root.taskStateJsonForTesting())["taskContract"]["id"].str != identity);
    writeln("PASS real HTTP/tools: Stop, read-only investigation, durable return point, reload, retained completed steps, parent completion and explicit scope switch");
    return 0;
}
