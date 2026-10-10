module turn_summary_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.turnsummary : TurnWorkSummary, turnOpeningSentence;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import std.file : mkdirRecurse, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;
import core.thread : Thread;
import core.time : msecs;

private Widget find(Widget root, string id)
{
    if (root.id() == id) return root;
    foreach (child; root.children()) if (auto found = find(child, id)) return found;
    return null;
}

int main()
{
    assert(turnOpeningSentence("I’ll inspect appui.d first. Then simplify it.") ==
        "I’ll inspect appui.d first.");
    assert(turnOpeningSentence(" \n  Inspect the layout\n and keep history. More detail.") ==
        "Inspect the layout and keep history.");
    const state = buildPath("build", "turn-summary-state");
    mkdirRecurse(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:1/v1","apiKey":"fixture","model":"fixture","toolsEnabled":false}`);
    setOpencodeStateDirectoryForTesting(state);
    WindowOptions options;
    options.width = 1100;
    options.height = 820;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    scope(exit) { root.shutdownClient(); window.close(); }
    foreach (_; 0 .. 30) { root.tickTree(0.02); driver.paint(); Thread.sleep(10.msecs); }
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Streamline the chat and keep all the details."]);
    root.startTurnClockForTesting();
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    auto pendingSummary = cast(TurnWorkSummary) find(root, "oc-turn-work");
    assert(pendingSummary !is null && !pendingSummary.collapsed() &&
        pendingSummary.title == "Starting your request…",
        "The turn header waited for provider output");
    root.appendToolRequestTurnForTesting("Inspect the current grouping.", "read-1", "read",
        `{"filePath":"appui.d"}`, "I’ll inspect how the transcript groups activity.");
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    auto startingSummary = cast(TurnWorkSummary) find(root, "oc-turn-work");
    assert(startingSummary !is null && !startingSummary.collapsed(),
        "A new working turn did not start expanded");
    assert(startingSummary.title == "I’ll inspect how the transcript groups activity." &&
        startingSummary.detail.indexOf("Working") >= 0);
    root.appendOwnedToolResultForTesting("read-1", "read", "unique inspected output",
        `{"filePath":"appui.d"}`, 0, 0, "");
    root.appendToolRequestTurnForTesting("Change the presentation.", "edit-1", "edit",
        `{"filePath":"appui.d"}`, "I found the grouping boundary and am updating it.");
    root.appendOwnedToolResultForTesting("edit-1", "edit", "Edited appui.d",
        `{"filePath":"appui.d"}`, 8, 2, "@@ -1 +1 @@\n-old\n+new");
    root.appendToolRequestTurnForTesting("Keep state stable.", "edit-2", "edit",
        `{"filePath":"appui.d"}`, "I’ll retain history and expansion choices.");
    root.appendOwnedToolResultForTesting("edit-2", "edit", "Edited appui.d again",
        `{"filePath":"appui.d"}`, 3, 1, "@@ -2 +2 @@\n-old\n+new");
    assert(!startingSummary.collapsed(), "Updates automatically folded an expanded turn");
    root.beginStreamForTesting();
    root.streamContentForTesting("The chat now groups work beneath each request. Full activity remains available.");
    root.finishStreamForTesting();
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    auto summary = cast(TurnWorkSummary) find(root, "oc-turn-work");
    assert(summary is startingSummary && !summary.collapsed(),
        "Completion folded the turn or replaced its header");
    assert(summary.title == "I’ll inspect how the transcript groups activity.");
    TurnWorkSummary[] batches;
    foreach (row; summary.children())
        if (row.id() == "oc-activity-batch") batches ~= cast(TurnWorkSummary) row;
    assert(batches.length == 3, "Activity was not grouped between commentary updates");
    foreach (batch; batches)
        assert(batch.collapsed() && batch.title.indexOf("tokens") < 0 &&
            batch.title.indexOf("ms") < 0, "Technical detail leaked into the timeline");
    assert(summary.children().length == 5,
        "The opening sentence was repeated in the timeline");
    batches[0].setCollapsed(false);
    root.rebuildForTesting();
    assert(!batches[0].collapsed(), "A refresh lost the batch expansion choice");
    batches[0].setCollapsed(true);
    assert(summary.detail.indexOf("3 actions recorded") >= 0 &&
        summary.detail.indexOf("1 file changed") >= 0,
        "Repeated edits were counted as distinct files");
    assert(root.messageCountForTesting() == 8 && root.toolMessageCountForTesting() == 3);
    summary.setCollapsed(true);
    root.rebuildForTesting();
    assert(summary.collapsed(), "A refresh ignored the user's collapse choice");
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    window.saveScreenshot("build/turn-summary-collapsed.ppm");
    const collapsedHeight = summary.bounds().height;
    summary.setCollapsed(false);
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    assert(summary.bounds().height > collapsedHeight);
    foreach (row; summary.children())
        if (row.visible()) assert(row.bounds().x == 18,
            "Turn details did not receive their hierarchy indentation");
    root.rebuildForTesting();
    assert(find(root, "oc-turn-work") is summary && !summary.collapsed(),
        "Projection lost row identity or the reader's expansion choice");
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    window.saveScreenshot("build/turn-summary-expanded.ppm");
    summary.setCollapsed(true);
    root.setChatSearchQueryForTesting("unique inspected output");
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    assert(root.chatSearchMatchCountForTesting() == 1 && !summary.collapsed(),
        "Search did not open the enclosing work summary");
    assert(!batches[0].collapsed(), "Search did not reveal the containing activity batch");
    root.setChatSearchQueryForTesting("");
    root.persistForTesting();
    root.reloadSessionsForTesting();
    foreach (_; 0 .. 20) { root.tickTree(0.02); driver.paint(); Thread.sleep(10.msecs); }
    assert(root.messageCountForTesting() == 8 && root.toolMessageCountForTesting() == 3,
        "Presentation grouping changed saved history");
    auto restored = cast(TurnWorkSummary) find(root, "oc-turn-work");
    assert(restored !is null && restored.detail.indexOf("1 file changed") >= 0);
    // Header wrapping must remain usable in narrow chat columns.
    auto narrow = restored.measure(Size(230, int.max));
    assert(narrow.width == 230 && narrow.height > 40);
    root.addConversationForTesting(["user"], ["A new request"]);
    assert(find(root, "oc-turn-work") is restored,
        "Starting another request ungrouped the previous task");
    restored.setCollapsed(true);
    root.rebuildForTesting();
    assert(restored.collapsed() && root.messageCountForTesting() == 9);
    root.startTurnClockForTesting();
    root.appendToolRequestTurnForTesting("", "next-read", "read", "{}",
        "I’ll inspect the next request. Extra context belongs in the details.");
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    TurnWorkSummary nextSummary;
    foreach (row; find(root, "oc-turn-work").parent().children())
        if (auto candidate = cast(TurnWorkSummary) row)
            if (candidate !is restored) nextSummary = candidate;
    assert(nextSummary !is null && !nextSummary.collapsed());
    nextSummary.setCollapsed(true);
    root.beginStreamForTesting();
    root.streamContentForTesting("Next request complete.");
    root.finishStreamForTesting();
    assert(root.tipSecondaryActionForTesting() == "",
        "A completed response still offers Continue");
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    assert(nextSummary.collapsed() && nextSummary.title == "I’ll inspect the next request.",
        "Streaming or completion reset a manually collapsed turn");
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Check live headings"]);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    root.streamContentForTesting("I’ll inspect ");
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    auto liveSummary = cast(TurnWorkSummary) find(root, "oc-turn-work");
    assert(liveSummary !is null && liveSummary.title == "I’ll inspect");
    root.streamContentForTesting("the layout. Then check details.");
    assert(liveSummary.title == "I’ll inspect the layout.",
        "Opening sentence waited for a completed assistant/tool round");
    root.finishStreamForTesting();
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Capture the page"]);
    root.appendToolRequestTurnForTesting("Prepare the folder", "failed-folder",
        "create_folder", `{"path":"aurora-shot"}`, "I’ll capture the page.");
    root.appendOwnedToolResultForTesting("failed-folder", "create_folder",
        "Access denied", `{"path":"aurora-shot"}`, 0, 0, "", 14, true);
    root.beginStreamForTesting();
    root.streamContentForTesting("I could not create the folder.");
    root.finishStreamForTesting();
    auto failedBatch = cast(TurnWorkSummary) find(root, "oc-activity-batch");
    assert(failedBatch !is null && failedBatch.collapsed() &&
        failedBatch.title == "Create folder failed",
        "A failed folder operation was labeled as a successful edit");
    root.appendToolRequestTurnForTesting("Retry the folder", "retry-folder",
        "create_folder", `{"path":"aurora-shot"}`, "I’ll retry creating the folder.");
    root.appendOwnedToolResultForTesting("retry-folder", "create_folder",
        "Created", `{"path":"aurora-shot"}`, 0, 0, "", 5);
    root.beginStreamForTesting();
    root.streamContentForTesting("The retry succeeded.");
    root.finishStreamForTesting();
    assert(failedBatch.title == "Create folder failed · recovered",
        "An exact successful retry did not explain recovery");
    assert((cast(TurnWorkSummary) find(root, "oc-turn-work")).detail.indexOf(
        "recovered after 1 failed attempt") >= 0);
    writeln("PASS immediate and streaming headings, turn grouping, expansion identity, search, history and indentation");
    return 0;
}
