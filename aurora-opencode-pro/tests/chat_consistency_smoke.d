module chat_consistency_smoke;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.turnsummary;
import auroraopencode.core : OpenCodeToolCall, opencodeTheme,
    setOpencodeStateDirectoryForTesting;
import std.conv : to;
import std.file : mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.datetime : Clock;
import core.thread : Thread;
import core.time : msecs;

private Widget find(Widget root, string id)
{
    if (root.id() == id) return root;
    foreach (child; root.children())
        if (auto found = find(child, id)) return found;
    return null;
}

private void assertVisible(Widget widget, ScrollView view)
{
    assert(widget !is null, "Latest activity is missing");
    for (auto ancestor = widget; ancestor !is null; ancestor = ancestor.parent())
        assert(ancestor.visible(), "Latest activity is hidden by a collapsed parent");
    const top = widget.localToGlobal(Point(0, 0)).y;
    const viewport = view.localToGlobal(Point(0, 0)).y;
    assert(widget.bounds().height > 0 && top >= viewport &&
        top + widget.bounds().height <= viewport + view.bounds().height,
        "Latest activity extends below the viewport");
}

int main()
{
    const state = buildPath(tempDir(), "aurora-chat-consistency-" ~
        to!string(Clock.currTime.stdTime));
    mkdirRecurse(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:1/v1","apiKey":"fixture","model":"fixture","toolsEnabled":false}`);
    setOpencodeStateDirectoryForTesting(state);
    WindowOptions options;
    options.width = 1000;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    root.setExperimentalChatRedesignForTesting(true);
    window.setRoot(root);
    root.isolateClipboardForTesting(true);
    root.pauseToolContinuationForTesting();
    scope (exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    foreach (i; 0 .. 30)
    {
        root.tickTree(0.02);
        root.tickTree(0.02); driver.paint();
        Thread.sleep(10.msecs);
    }
    auto view = cast(ScrollView) find(root, "oc-scroll");
    assert(view !is null);

    root.newChatForTesting();
    string[] roles, bodies;
    foreach (i; 0 .. 30)
    {
        roles ~= "user"; bodies ~= "Prompt " ~ to!string(i);
        roles ~= "assistant"; bodies ~= "Reply " ~ to!string(i);
    }
    root.addConversationForTesting(roles, bodies);
    root.tickTree(0.02); driver.paint();
    root.beginStreamForTesting();
    root.tickTree(0.02); driver.paint();
    assertVisible(find(root, "oc-activity"), view);
    foreach (i; 0 .. 12)
    {
        root.streamContentForTesting("Newest paragraph " ~ to!string(i) ~
            " with enough text to wrap across the chat column.\n\n");
        root.tickTree(0.02); driver.paint();
        assert(root.followForTesting() && view.scrollY() == view.maxScroll(),
            "Streaming lost the latest line");
        assert(root.transcriptRowsSequentialForTesting(), "Rows overlap");
    }
    root.scrollTranscriptUpForTesting(200);
    const readerOffset = view.scrollY();
    root.streamContentForTesting("Another paragraph.\n\n");
    root.tickTree(0.02); driver.paint();
    assert(!root.followForTesting() && view.scrollY() == readerOffset,
        "Streaming moved a reader looking at history");
    root.scrollToForTesting(int.max);
    root.finishStreamForTesting();
    root.tickTree(0.02); driver.paint();
    assert(view.scrollY() == view.maxScroll(), "Completion hid the final line");
    writeln("Streaming and completion stay at the true bottom");

    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"], ["Do the work", ""]);
    OpenCodeToolCall first = OpenCodeToolCall("first", "read",
        `{"filePath":"first.txt"}`);
    OpenCodeToolCall second = OpenCodeToolCall("second", "write",
        `{"filePath":"second.txt","content":"hello"}`);
    root.injectToolProgressForTesting([first, second]);
    root.tickTree(0.02); driver.paint();
    assertVisible(find(root, "oc-live-tool"), view);
    Thread.sleep(100.msecs);
    const elapsed = root.totalLiveToolElapsedMsForTesting();
    root.rebuildForTesting();
    root.tickTree(0.02); driver.paint();
    assertVisible(find(root, "oc-live-tool"), view);
    assert(root.totalLiveToolElapsedMsForTesting() >= elapsed,
        "A transcript rebuild reset the active tool timer");
    window.saveScreenshot("build/chat-consistency-live.ppm");
    writeln("Active tool details survive collapsed groups and rebuilds");

    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Run parallel tools"]);
    root.appendToolRequestBatchForTesting([first, second]);
    root.seedPendingToolBatchForTesting([first, second]);
    root.rebuildForTesting();
    root.tickTree(0.02); driver.paint();
    root.toggleFirstToolGroupForTesting();
    root.tickTree(0.02); driver.paint();
    assert(!root.firstToolGroupCollapsedForTesting());
    root.injectToolResultIdForTesting("second", "write");
    root.tickTree(0.02); driver.paint();
    auto groups = root.toolGroupChildNamesForTesting();
    assert(groups.length == 2 && groups[0] == "read" && groups[1] == "write",
        "A later completed call moved ahead of an earlier running call");
    assertVisible(find(root, "oc-live-tool"), view);
    assert(!root.firstToolGroupCollapsedForTesting(),
        "A partial result reset the group's expanded state");
    root.injectToolResultIdForTesting("first", "read");
    root.tickTree(0.02); driver.paint();
    groups = root.toolGroupChildNamesForTesting();
    assert(groups.length == 2 && groups[0] == "read" && groups[1] == "write",
        "Completed tools changed their request order");
    assert(root.transcriptRowsSequentialForTesting(), "Settled rows overlap");
    assert(!root.firstToolGroupCollapsedForTesting(),
        "Completion reset the group's expanded state");
    auto batch = cast(auroraopencode.turnsummary.TurnWorkSummary) find(root, "oc-activity-batch");
    assert(batch !is null && batch.collapsed(),
        "Completed activity did not settle into a compact batch");
    assertVisible(batch, view);
    assert(root.lastToolResultBoundsForTesting().height == 0,
        "Raw tool details leaked out of the collapsed batch");
    root.openActivityDetailsForTesting();
    root.tickTree(0.02); driver.paint();
    auto resultBounds = root.lastToolResultBoundsForTesting();
    const viewportTop = view.localToGlobal(Point(0, 0)).y;
    assert(resultBounds.height > 0 && resultBounds.y >= viewportTop &&
        resultBounds.bottom() <= viewportTop + view.bounds().height,
        "The newest completed action was folded out of sight");
    window.saveScreenshot("build/chat-consistency-completed.ppm");
    root.persistForTesting();
    root.reloadSessionsForTesting();
    root.tickTree(0.02); driver.paint();
    groups = root.toolGroupChildNamesForTesting();
    assert(groups.length == 2 && groups[0] == "read" && groups[1] == "write",
        "Restoring the chat changed tool order");
    assert(root.lastToolResultBoundsForTesting().height > 0,
        "Restore hid the newest completed action");
    root.addConversationForTesting(["assistant"], ["Finished the work."]);
    root.tickTree(0.02); driver.paint();
    assert(root.lastToolResultBoundsForTesting().height > 0,
        "A newer reply unexpectedly folded the expanded action details");
    writeln("Parallel tool completion preserves request order");

    root.newChatForTesting();
    roles.length = bodies.length = 0;
    foreach (i; 0 .. 250)
    {
        roles ~= i % 2 == 0 ? "user" : "assistant";
        bodies ~= "History " ~ to!string(i) ~
            " with text long enough to wrap in a narrow viewport and test anchoring.";
    }
    root.addConversationForTesting(roles, bodies);
    root.tickTree(0.02); driver.paint();
    root.scrollToForTesting(100);
    root.tickTree(0.02); driver.paint();
    const beforeY = view.content().bounds().y + root.bubbleBoundsForTesting(1).y;
    root.loadOlderHistoryForTesting();
    root.tickTree(0.02); driver.paint();
    const afterY = view.content().bounds().y + root.bubbleBoundsForTesting(121).y;
    assert(beforeY == afterY, "Loading history moved the reader's original row");
    assert(!root.followForTesting());
    root.scrollTranscriptUpForTesting(int.max);
    root.tickTree(0.02); driver.paint();
    assert(root.hiddenHistoryCountForTesting() == 0,
        "Returning to the top did not re-arm history loading");
    writeln("History paging preserves the reader's position");
    root.newChatForTesting();
    roles.length = bodies.length = 0;
    foreach (i; 0 .. 750)
    {
        roles ~= i % 2 == 0 ? "user" : "assistant";
        string body = "Variable history " ~ to!string(i);
        foreach (_; 0 .. 1 + i % 5)
            body ~= "\n\nA paragraph with **formatting** and enough text to wrap across the viewport.";
        bodies ~= body;
    }
    root.addConversationForTesting(roles, bodies);
    root.tickTree(0.02); driver.paint();
    foreach (_; 0 .. 3)
    {
        root.scrollToForTesting(100);
        root.tickTree(0.02); driver.paint();
        const anchorBefore = view.content().bounds().y + root.bubbleBoundsForTesting(1).y;
        root.loadOlderHistoryForTesting();
        root.tickTree(0.02); driver.paint();
        const anchorAfter = view.content().bounds().y + root.bubbleBoundsForTesting(121).y;
        assert(anchorBefore == anchorAfter,
            "Repeated virtual paging shifted a retained variable-height row");
        assert(!root.followForTesting());
        assert(root.materializedTranscriptRowsForTesting() < 100,
            "Paging materialized the entire history to preserve its anchor");
    }
    writeln("Repeated virtual paging anchors variable-height rows without constructing the full history");
    return 0;
}
