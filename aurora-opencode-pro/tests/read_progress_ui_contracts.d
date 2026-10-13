module read_progress_ui_contracts;
import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import auroraopencode.readprogress;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const workspace = absolutePath("read-ui-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(buildPath(workspace, "state"));
    Settings settings; settings.workspace = workspace; settings.baseUrl = "http://127.0.0.1:9";
    settings.quickTitle = false; saveSettings(settings);
    write(buildPath(workspace, "ordinary.txt"), "working after interruption\n");
    WindowOptions options; options.width = 1200; options.height = 800;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope (exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void pump() { window.onNativeTick(0.02); root.projectTranscriptForTesting(); assert(driver.paint()); Thread.sleep(5.msecs); }
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready) pump();
    assert(!root.startupPendingForTesting());
    root.newChatForTesting(); root.pauseToolContinuationForTesting();
    root.addConversationForTesting(["user"], ["Read this file and show activity"]);
    auto call = OpenCodeToolCall("visible-read", "read", `{"filePath":"ordinary.txt","offset":20,"limit":100}`);
    root.appendToolRequestBatchForTesting([call]); root.seedPendingToolBatchForTesting([call]);
    root.rebuildForTesting(); pump();
    auto row = root.liveToolRowForTesting(call.id);
    assert(row !is null && root.liveSearchCollapsedForTesting(call.id));
    const compact = row.bounds().height;
    driver.click(Point(row.globalOrigin().x + 48, row.globalOrigin().y + 12)); pump();
    assert(!root.liveSearchCollapsedForTesting(call.id) && row.bounds().height > compact);
    assert(root.liveToolRowPreviewsForTesting()[0].indexOf(workspace) >= 0);
    ReadProgress progress;
    progress.phase = "Reading file"; progress.path = buildPath(workspace, "ordinary.txt");
    progress.offset = 20; progress.limit = 100; progress.bytesRead = 2500;
    progress.elapsedMs = 3400;
    progress.line = 30; progress.collected = 11; progress.lastActivityMs = 3000;
    progress.preview = ["29: returned content", "30: more returned content"];
    root.injectToolOutputForTesting(call.id, encodeReadProgress(progress)); pump();
    assert(root.liveReadFractionsForTesting().length == 0);
    assert(root.liveToolRowPreviewsForTesting()[0].indexOf("no measured percentage") >= 0);
    progress.totalKnown = true; progress.totalBytes = 10000;
    root.injectToolOutputForTesting(call.id, encodeReadProgress(progress)); pump();
    assert(root.liveReadFractionsForTesting() == [0.25]);
    auto preview = root.liveToolRowPreviewsForTesting()[0];
    assert(preview.indexOf("line 20") >= 0 && preview.indexOf("25%") >= 0 &&
        preview.indexOf("30: more returned content") >= 0 && preview.indexOf("3s") >= 0);
    assert(root.transcriptRowsSequentialForTesting());
    window.saveScreenshot("build/read-progress.ppm");
    foreach (_; 0 .. 20) root.tickTree(0.1);
    assert(root.liveReadFractionsForTesting() == [0.25], "Quiet time invented Read progress");
    root.rebuildForTesting(); pump();
    assert(!root.liveSearchCollapsedForTesting(call.id) && root.liveReadFractionsForTesting() == [0.25]);
    root.stopActiveTurnForTesting(); pump();
    assert(root.pendingToolResultsForTesting() == 0 && root.toolMessageCountForTesting() == 1);
    assert(root.toolResultForTesting(call.id).indexOf("no completed Read") >= 0);
    assert(root.toolResultForTesting(call.id).indexOf("returned content") >= 0);
    assert(root.toolResultForTesting(call.id).indexOf("Read stopped - incomplete") >= 0 &&
        root.toolResultForTesting(call.id).indexOf("host deadline") < 0);
    root.persistForTesting(); root.reloadSessionsForTesting(); pump();
    assert(root.toolResultForTesting(call.id).indexOf("no completed Read") >= 0 && root.toolMessageCountForTesting() == 1);
    writeln("PASS running Read expands before dispatch, measured bar and numbered preview, quiet progress, fold state, Stop and durable failure after reload");

    root.newChatForTesting(); root.pauseToolContinuationForTesting();
    root.addConversationForTesting(["user", "assistant"], ["Read this file", ""]);
    auto blocked = OpenCodeToolCall("blocked-read", "read",
        `{"filePath":"ordinary.txt","_fixtureBlocked":true,"_fixtureProgress":true,"timeout":1400}`);
    root.injectToolCallsForTesting([blocked]);
    const deadline = MonoTime.currTime + 6.seconds;
    while (root.pendingToolResultsForTesting() && MonoTime.currTime < deadline) pump();
    assert(root.pendingToolResultsForTesting() == 0 && root.toolResultForTesting(blocked.id).indexOf("timed out") >= 0);
    root.addConversationForTesting(["assistant"], [""]);
    root.injectToolCallsForTesting([OpenCodeToolCall("fresh-read", "read", `{"filePath":"ordinary.txt"}`)]);
    const recovered = MonoTime.currTime + 4.seconds;
    while (root.pendingToolResultsForTesting() && MonoTime.currTime < recovered) pump();
    assert(root.pendingToolResultsForTesting() == 0 && root.toolResultForTesting("fresh-read").indexOf("working after interruption") >= 0);
    writeln("PASS actual chat dispatcher times out a stuck Read and completes the following Read");

    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Recover an old interrupted chat"]);
    auto old = OpenCodeToolCall("old-unanswered", "read", `{"filePath":"ordinary.txt"}`);
    root.appendToolRequestBatchForTesting([old]);
    root.setSessionTurnStatusForTesting(root.currentSessionForTesting(), "interrupted");
    root.persistForTesting(); root.reloadSessionsForTesting(); pump();
    assert(root.toolResultForTesting(old.id).indexOf("no completed Read result was saved") >= 0);
    root.persistForTesting(); root.reloadSessionsForTesting(); pump();
    assert(root.toolMessageCountForTesting() == 1, "Recovery duplicated the interrupted Read result");
    writeln("PASS restoring an old unanswered Read records an explicit incomplete result exactly once without executing it");
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Recover a Read interrupted by a crash"]);
    auto crashed = OpenCodeToolCall("crashed-read", "read", `{"filePath":"ordinary.txt"}`);
    root.appendToolRequestBatchForTesting([crashed]);
    root.setSessionTurnStatusForTesting(root.currentSessionForTesting(), "running");
    write(buildPath(workspace, "state", "restart-resume.json"), `{"cause":"crash","reason":"fixture"}`);
    root.prepareResumeForTesting(); root.clearPendingResumeForTesting(); pump();
    assert(root.toolResultForTesting(crashed.id).indexOf("no completed Read result was saved") >= 0);
    writeln("PASS crash resume records the unanswered Read before continuing the interrupted task");
    return 0;
}
