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
    root.appendToolRequestTurnForTesting("Inspect the current grouping.", "read-1", "read",
        `{"filePath":"appui.d"}`, "I’ll inspect how the transcript groups activity.");
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
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
    root.beginStreamForTesting();
    root.streamContentForTesting("The chat now groups work beneath each request. Full activity remains available.");
    root.finishStreamForTesting();
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    assert(find(root, "oc-activity-batch") is null,
        "Chat redesign must be off by default");
    assert(root.messageCountForTesting() == 8 && root.toolMessageCountForTesting() == 3);
    window.saveScreenshot("build/chat-classic-default.ppm");
    root.setExperimentalChatRedesignForTesting(true);
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    assert(find(root, "oc-turn-work") is null, "Outer turn container remains");
    assert(find(root, "oc-timeline-commentary") is null, "A duplicate commentary projection remains");
    assert(root.messageCountForTesting() == 8 && root.toolMessageCountForTesting() == 3);
    TurnWorkSummary[] batches;
    auto first = cast(TurnWorkSummary) find(root, "oc-activity-batch");
    assert(first !is null);
    foreach (row; first.parent().children())
        if (row.id() == "oc-activity-batch") batches ~= cast(TurnWorkSummary) row;
    assert(batches.length == 3, "Expected one activity row between each prose update");
    foreach (batch; batches) assert(batch.collapsed());
    // Original prose rows remain visible at the chat edge with full opening text.
    assert(root.bubbleVisibleForTesting(1) && root.bubbleVisibleForTesting(3) &&
        root.bubbleVisibleForTesting(5) && root.bubbleVisibleForTesting(7));
    assert(root.messageContentForTesting(1) == "I’ll inspect how the transcript groups activity.");
    const edge = root.bubbleBoundsForTesting(0).x;
    foreach (index; [1, 3, 5, 7]) assert(root.bubbleBoundsForTesting(index).x == edge,
        "Assistant prose is indented inside a turn");
    window.saveScreenshot("build/chat-straightforward.ppm");
    first.setCollapsed(false);
    root.rebuildForTesting();
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    assert(find(root, "oc-activity-batch") is first && !first.collapsed());
    foreach (batch; batches) batch.setCollapsed(false);
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    assert(root.activityGroupsFlatForTesting());
    auto nestedThinking = find(root, "oc-activity-reasoning");
    assert(nestedThinking !is null && nestedThinking.bounds().x == 16,
        "Nested Thinking header must be indented inside its activity row");
    window.saveScreenshot("build/chat-straightforward-details.ppm");
    foreach (batch; batches) batch.setCollapsed(true);
    root.setChatSearchQueryForTesting("unique inspected output");
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    assert(root.chatSearchMatchCountForTesting() == 1 && !first.collapsed());
    first.setCollapsed(true);
    root.setChatSearchQueryForTesting("Inspect the current grouping");
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    assert(root.chatSearchMatchCountForTesting() == 1 && !first.collapsed(),
        "Reasoning search did not reveal its activity row");
    root.setChatSearchQueryForTesting("");
    root.setExperimentalChatRedesignForTesting(false);
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    assert(find(root, "oc-activity-batch") is null &&
        find(root, "oc-activity-reasoning") is null,
        "Disabling redesign left experimental rows in the classic transcript");
    assert(root.messageCountForTesting() == 8 && root.toolMessageCountForTesting() == 3);
    root.setExperimentalChatRedesignForTesting(true);
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    assert(find(root, "oc-activity-batch") !is null);
    root.persistForTesting();
    root.reloadSessionsForTesting();
    foreach (_; 0 .. 20) { root.tickTree(0.02); driver.paint(); Thread.sleep(10.msecs); }
    assert(root.messageCountForTesting() == 8 && root.toolMessageCountForTesting() == 3);
    assert(find(root, "oc-turn-work") is null);
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
    assert(failedBatch !is null && failedBatch.title == "Create folder failed");
    root.appendToolRequestTurnForTesting("Retry the folder", "retry-folder",
        "create_folder", `{"path":"aurora-shot"}`, "I’ll retry creating the folder.");
    root.appendOwnedToolResultForTesting("retry-folder", "create_folder",
        "Created", `{"path":"aurora-shot"}`, 0, 0, "", 5);
    root.beginStreamForTesting();
    root.streamContentForTesting("The retry succeeded.");
    root.finishStreamForTesting();
    assert(failedBatch.title == "Create folder failed · recovered");
    assert(root.tipSecondaryActionForTesting() == "");
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Check progress"]);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    assert(find(root, "oc-activity") !is null && find(root, "oc-turn-work") is null);
    root.streamContentForTesting("A direct reply.");
    root.finishStreamForTesting();
    assert(root.lastAssistantContentForTesting() == "A direct reply.");
    assert(find(root, "oc-activity-batch") is null, "A plain reply gained an empty activity row");
    root.newChatForTesting();
    root.addConversationForTestingWithReasoning(
        ["tool", "assistant", "tool", "assistant", "tool"],
        ["first output", "First update.", "second output", "Second update.", "third output"],
        [null, "first thought", null, "second thought", null]);
    foreach (_; 0 .. 3) { root.tickTree(0.02); assert(driver.paint()); }
    assert(root.messageCountForTesting() == 5 && root.transcriptRowsSequentialForTesting(),
        "Legacy orphan tool results reused a disclosure or overlapped prose");
    writeln("PASS original chronological prose, no outer headers, compact activity, reasoning/tool search, recovery and history");
    return 0;
}
