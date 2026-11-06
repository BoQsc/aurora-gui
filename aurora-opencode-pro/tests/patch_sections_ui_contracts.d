module patch_sections_ui_contracts;
import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;

/// The Patch card as the real transcript renders it: one row per patched file
/// with that file's own action and counts, and a multi-file patch opening
/// itself so the list is visible. A single card carrying every file's hunks
/// under one header was the reported defect.
int main()
{
    // Scratch state lives outside the package: a path inside Aurora's source
    // tree would be treated as a developer-source edit.
    const workspace = buildPath(tempDir(), "patch-sections-ui-" ~
        to!string(MonoTime.currTime.ticks));
    mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(buildPath(workspace, "state"));
    Settings settings;
    settings.workspace = workspace;
    settings.baseUrl = "http://127.0.0.1:9";
    settings.quickTitle = false;
    saveSettings(settings);

    WindowOptions options;
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope (exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void pump()
    {
        window.onNativeTick(0.02);
        root.projectTranscriptForTesting();
        assert(driver.paint());
        Thread.sleep(5.msecs);
    }
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready) pump();
    assert(!root.startupPendingForTesting());

    // A stored multi-file patch result, restored the way a reopened chat loads.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Patch these files"]);
    root.appendToolRequestTurnForTesting("", "patch-call", "apply_patch",
        `{"patch":"*** Begin Patch\n*** Add File: sub/new.txt\n+hello\n+world\n` ~
        `*** Update File: keep.txt\n@@\n keep\n-old\n+new\n*** End Patch"}`);
    root.appendOwnedToolResultForTesting("patch-call", "apply_patch",
        "Applied patch to 2 paths (+3 -1).", `{"patch":"multi"}`, 3, 1,
        "*** Add File: sub/new.txt\n@@ -1,0 +1,2 @@\n+hello\n+world\n" ~
        "*** Update File: keep.txt\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n", 12);
    root.persistForTesting();
    root.reloadSessionsForTesting();
    pump();
    root.openActivityDetailsForTesting();
    pump();

    const rows = root.toolPatchSectionRowsForTesting(0);
    assert(rows == ["sub/new.txt added +2 -0", "keep.txt updated +1 -1"],
        "the Patch card rendered " ~ to!string(rows.length) ~
        " per-file rows instead of one per patched file");
    assert(!root.firstToolBubbleCollapsedForTesting(),
        "a multi-file patch must open so its per-file rows are visible");
    assert(root.toolDiffAdditionsForTesting(0) == 3 &&
        root.toolDiffDeletionsForTesting(0) == 1,
        "the card's aggregate counters must still match the whole patch");
    window.saveScreenshot("build/patch-sections-ui.ppm");
    writeln("PASS the Patch card lists one row per patched file with its own " ~
        "counts and opens by default");

    // A single-file patch keeps the compact closed header.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Patch one file"]);
    root.appendToolRequestTurnForTesting("", "patch-solo", "apply_patch",
        `{"patch":"*** Begin Patch\n*** Update File: solo.txt\n@@\n-one\n+two\n*** End Patch"}`);
    root.appendOwnedToolResultForTesting("patch-solo", "apply_patch",
        "Applied patch to 1 path (+1 -1).", `{"patch":"solo"}`, 1, 1,
        "*** Update File: solo.txt\n@@ -1,1 +1,1 @@\n-one\n+two\n", 8);
    root.persistForTesting();
   root.reloadSessionsForTesting();
    pump();
    root.openActivityDetailsForTesting();
    pump();
    assert(root.toolPatchSectionRowsForTesting(0) == ["solo.txt updated +1 -1"],
        "a single-file patch lost its row");
    assert(root.firstToolBubbleCollapsedForTesting(),
        "a single-file patch should stay compact");
    writeln("PASS a single-file patch keeps the compact header");

    // A conversation saved before the sections existed keeps its plain diff.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Patch an old chat"]);
    root.appendToolRequestTurnForTesting("", "patch-legacy", "apply_patch",
        `{"patch":""}`);
    root.appendOwnedToolResultForTesting("patch-legacy", "apply_patch",
        "Applied patch to 1 path (+1 -1).", `{"patch":""}`, 1, 1,
        "@@ -1,1 +1,1 @@\n-old\n+new\n", 5);
    root.persistForTesting();
    root.reloadSessionsForTesting();
    pump();
    root.openActivityDetailsForTesting();
    pump();
    assert(root.toolPatchSectionRowsForTesting(0).length == 0,
        "a legacy hunk-only diff invented file rows");
    assert(root.toolHasDiffForTesting(0),
        "a legacy diff must still render its body");
    writeln("PASS restored hunk-only diffs still render without file rows");
    return 0;
}
