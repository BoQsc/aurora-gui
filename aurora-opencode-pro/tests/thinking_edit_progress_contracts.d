module thinking_edit_progress_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings,
    sandboxFolderPath, setOpencodeStateDirectoryForTesting, opencodeTheme;
import auroraopencode.tools : previewToolDiff, previewToolDiffText,
    previewToolLineCount;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.array : join;
import std.conv : to;
import std.file : exists, mkdirRecurse, remove, tempDir;
import std.path : buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf, splitLines, strip;

/// Thinking followed by editing must keep showing the edit while it streams.
///
/// The reasoning burst ends, the provider spends a few seconds composing the
/// tool call (that gap is real, and the live Thinking header explains it with a
/// `no new output for Ns` clock), and then the `apply_patch` arguments arrive
/// over a couple of seconds. During that second phase the transcript must show
/// the live "Applying <path>" row with growing `+N -M` counters and the patch
/// body as it streams, and the Thinking header must stop claiming the reply is
/// quiet: tool-call arguments are progress even when no reasoning or answer
/// text arrives.
///
/// `apply_patch` is the app's batch editing tool, so it is the one a reasoning
/// model picks for a file edit. The check drives the real widget tree against a
/// real HTTP provider and lets the real tool run, so the whole path is covered:
/// SSE parser -> client queue -> app service -> live rows -> edit applied.
int main()
{
    verifyApplyPatchPreview();

    const state = buildPath(tempDir(), "aurora-thinking-edit-" ~
        to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    // A new chat belongs to the sandbox project, so the tools run there.
    const workspace = sandboxFolderPath(1);
    mkdirRecurse(workspace);
    // The streamed patch creates this file, so it must not exist yet.
    if (exists(buildPath(workspace, "notes.txt")))
        remove(buildPath(workspace, "notes.txt"));
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(settings.baseUrl.length, "provider base url missing");
    settings.apiKey = "fixture";
    settings.model = "thinking-edit-fixture";
    settings.workspace = state;
    settings.toolsEnabled = true;
    settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options;
    options.width = 1100;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope (exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);

    while (root.startupPendingForTesting())
    {
        window.onNativeTick(0.02);
        Thread.sleep(5.msecs);
    }

    root.newChatForTesting();
    root.setInputForTesting("edit the notes file");
    root.sendForTesting();

    bool sawThinkingHeader;
    bool sawQuietBeforeEdit;
    bool sawApplyingRow;
    bool quietWhileApplying;
    bool bodyStreamed;
    bool newestLineVisible;
    string[] distinctPreviews;
    int maxAdds;
    int maxDels;
    string lastRow;
    string lastDiff;
    string lastPreview;
    string[] lastVisibleLines;
    string lastHeaderWhileApplying;
    string lastActivity;
    auto nextSample = MonoTime.currTime;
    const deadline = MonoTime.currTime + 40.seconds;
    while (MonoTime.currTime < deadline)
    {
        window.onNativeTick(0.02);
        const header = root.liveThinkingHeaderForTesting();
        const activity = root.activityTextForTesting();
        auto rows = root.liveToolRowTextsForTesting();
        auto diffs = root.liveToolRowDiffTextsForTesting();
        auto previews = root.liveToolRowPreviewsForTesting();
        auto visibleRows = root.liveToolRowVisibleLinesForTesting();
        bool applying;
        foreach (i, row; rows)
        {
            // "Applying" is the in-flight title; the settled row reads "Patch".
            if (row.indexOf("Applying") < 0) continue;
            applying = true;
            sawApplyingRow = true;
            lastRow = row;
            lastHeaderWhileApplying = header;
            lastActivity = activity;
            if (i < diffs.length)
            {
                lastDiff = diffs[i];
                int adds, dels;
                parseDiffCounters(lastDiff, adds, dels);
                if (adds > maxAdds) maxAdds = adds;
                if (dels > maxDels) maxDels = dels;
            }
            if (i < previews.length)
            {
                lastPreview = previews[i];
                if (lastPreview.indexOf("+gamma") >= 0) bodyStreamed = true;
                if (distinctPreviews.length == 0 ||
                    distinctPreviews[$ - 1] != lastPreview)
                    distinctPreviews ~= lastPreview;
            }
            if (i < visibleRows.length)
            {
                lastVisibleLines = visibleRows[i];
                // The patch has more added lines than the preview can show, so
                // a frozen first-line block would never reach its last line.
                foreach (line; lastVisibleLines)
                    if (line.indexOf("+omega") >= 0) newestLineVisible = true;
            }
            if (header.indexOf("no new output") >= 0) quietWhileApplying = true;
        }
        if (header.indexOf("Thinking") >= 0) sawThinkingHeader = true;
        if (!applying && header.indexOf("no new output") >= 0)
            sawQuietBeforeEdit = true;
        if (MonoTime.currTime >= nextSample)
        {
            nextSample = MonoTime.currTime + 250.msecs;
            writeln("[sample] header=[", header, "] activity=[", activity,
                "] rows=", rows, " diffs=", diffs, " previews=",
                previews, " busy=", root.turnBusyForTesting());
        }
        if (!root.turnBusyForTesting() && sawApplyingRow &&
            root.toolMessageCountForTesting() > 0 &&
            root.lastAssistantContentForTesting().length > 0)
            break;
        Thread.sleep(5.msecs);
    }
    root.projectTranscriptForTesting();
    assert(driver.paint(), "thinking-edit transcript did not paint");

    writeln("observed: thinkingHeader=", sawThinkingHeader,
        " quietBeforeEdit=", sawQuietBeforeEdit,
        " applyingRow=", sawApplyingRow, " bodyStreamed=", bodyStreamed,
        " newestLineVisible=", newestLineVisible,
        " previewUpdates=", distinctPreviews.length,
        " maxAdds=", maxAdds, " maxDels=", maxDels);
    writeln("during edit: row=[", lastRow, "] diff=[", lastDiff, "] header=[",
        lastHeaderWhileApplying, "] activity=[", lastActivity, "]");
    writeln("last preview: [", lastPreview, "]");
    writeln("answer: [", root.lastAssistantContentForTesting(), "]");
    foreach (line; root.messageColumnDumpForTesting())
        writeln("column: ", line);
    writeln("settled change: +", root.totalToolGroupAdditionsForTesting(),
        " -", root.totalToolGroupDeletionsForTesting());
    foreach (message; root.requestMessagesForTesting())
        if (message.role == "tool")
            writeln("tool output: ", message.content.length > 200
                ? message.content[0 .. 200] : message.content);

    assert(sawThinkingHeader,
        "the reply never rendered a Thinking header for the reasoning burst");
    assert(sawApplyingRow,
        "the live 'Applying' row never appeared while the patch arguments streamed");
    assert(maxAdds >= 3,
        "the live patch row never showed its streamed +N -M counters: [" ~
        lastDiff ~ "]");
    assert(bodyStreamed,
        "the live patch row never previewed the patch body while it streamed: [" ~
        lastPreview ~ "]");
    assert(newestLineVisible,
        "the live patch row froze on its first lines instead of showing the " ~
        "newest streamed line: visible=[" ~
        (lastVisibleLines.length ? lastVisibleLines.join(" | ") : "(none)") ~ "]");
    assert(distinctPreviews.length >= 5,
        "the live patch preview did not advance line by line while it streamed " ~
        "(" ~ to!string(distinctPreviews.length) ~ " updates)");
    assert(!quietWhileApplying,
        "the Thinking header claimed 'no new output' while the live edit row was " ~
        "streaming: [" ~ lastHeaderWhileApplying ~ "]");
    assert(root.totalToolGroupAdditionsForTesting() >= 3,
        "the settled patch row lost the change the streamed patch carried");
    verifySettledPatchRow(root);
    writeln("PASS thinking followed by editing keeps the live edit visible");
    return 0;
}

/// The settled `apply_patch` result row shows the same preview the in-flight
/// row streamed. A result that carried no change metadata (a restored message,
/// an interrupted patch) must still render the change body *and* its `+N -M`,
/// while a failed patch keeps the text that says why it failed.
private void verifySettledPatchRow(OpenCodeRoot root)
{
    const args = `{"patch":"*** Begin Patch\n*** Update File: notes.txt\n@@\n alpha\n-beta\n+BETA\n*** End Patch"}`;
    root.newChatForTesting();
    root.appendToolRequestTurnForTesting("Patching the file.", "call_row",
        "apply_patch", args);
    root.appendOwnedToolResultForTesting("call_row", "apply_patch",
        "Applied patch to 1 path (+1 -1).", args, 0, 0, "");
    root.tickTree(0.02);
    auto bubbles = root.toolBubblesForTesting();
    assert(bubbles.length == 1,
        "expected one settled apply_patch row, got " ~ to!string(bubbles.length));
    assert(bubbles[0].hasDiffForTesting(),
        "the settled apply_patch row dropped the streamed change body");
    assert(bubbles[0].diffAdditionsForTesting() == 1 &&
        bubbles[0].diffDeletionsForTesting() == 1,
        "the settled apply_patch row lost its streamed +N -M: +" ~
        to!string(bubbles[0].diffAdditionsForTesting()) ~ " -" ~
        to!string(bubbles[0].diffDeletionsForTesting()));
    auto sections = bubbles[0].patchSectionRowsForTesting();
    assert(sections.length == 1 && sections[0].indexOf("notes.txt") >= 0,
        "the settled apply_patch row did not list its patched file: " ~
        to!string(sections));

    // A rejected patch reports why it failed; the attempted change must not
    // replace that reason.
    root.appendToolRequestTurnForTesting("Patching again.", "call_row_fail",
        "apply_patch", args);
    root.appendOwnedToolResultForTesting("call_row_fail", "apply_patch",
        "Patch not applied; validation failed: context not found.", args, 0, 0,
        "", 0, true);
    root.tickTree(0.02);
    auto rows = root.toolBubblesForTesting();
    assert(rows.length == 2, "expected two settled rows, got " ~
        to!string(rows.length));
    assert(!rows[1].hasDiffForTesting(),
        "a failed apply_patch row replaced its reason with the attempted change");
    assert(rows[1].contentSnippetForTesting().indexOf("validation failed") >= 0,
        "a failed apply_patch row lost its failure text: [" ~
        rows[1].contentSnippetForTesting() ~ "]");
}

/// Read a `+N -M` label into its two counters (0 when a side is absent).
private void parseDiffCounters(string label, out int additions, out int deletions)
{
    additions = counterAfter(label, '+');
    deletions = counterAfter(label, '-');
}

private int counterAfter(string label, char sign)
{
    const at = label.indexOf(sign);
    if (at < 0) return 0;
    int value;
    foreach (c; label[at + 1 .. $])
    {
        if (c < '0' || c > '9') break;
        value = value * 10 + (c - '0');
    }
    return value;
}

/// The live row derives its counters and body from the streamed arguments, so
/// lock the `apply_patch` cases a patch row depends on: partial JSON while the
/// text arrives, several files in one patch, and the envelope (including a
/// truncated closing marker) never being mistaken for diff lines.
private void verifyApplyPatchPreview()
{
    int adds, dels;
    assert(previewToolDiff("apply_patch",
        `{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n alpha\n-beta\n+BETA`,
        adds, dels), "partial apply_patch arguments produced no preview");
    assert(adds == 1 && dels == 1,
        "partial apply_patch counters wrong: +" ~ to!string(adds) ~
        " -" ~ to!string(dels));
    // The live row refreshes per streamed line, so the line count must grow
    // even for a context line that changes no counter.
    const contextFree = `{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n-one\n+two`;
    const withContext = `{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n-one\n+two\n unchanged`;
    assert(previewToolLineCount("apply_patch", withContext) >
        previewToolLineCount("apply_patch", contextFree),
        "a streamed apply_patch context line did not grow the preview line count");
    assert(previewToolLineCount("write",
        `{"filePath":"a.txt","content":"one\ntwo\nthree"}`) == 3,
        "the streamed write body did not report its line count");
    assert(previewToolLineCount("edit",
        `{"filePath":"a.txt","oldString":"x","newString":"one\ntwo"}`) == 2,
        "the streamed edit replacement did not report its line count");
    assert(previewToolLineCount("read", `{"filePath":"a.txt"}`) == 0,
        "a read call must not report a streamed body line count");

    const full = `{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n alpha\n-beta\n+BETA\n*** Add File: b.txt\n+one\n+two\n*** End Patch"}`;
    assert(previewToolDiff("apply_patch", full, adds, dels),
        "complete apply_patch arguments produced no preview");
    assert(adds == 3 && dels == 1,
        "apply_patch counters across files wrong: +" ~ to!string(adds) ~
        " -" ~ to!string(dels));
    const body = previewToolDiffText("apply_patch", full);
    assert(body.indexOf("*** Update File: a.txt") >= 0 &&
        body.indexOf("+BETA") >= 0 && body.indexOf("*** Add File: b.txt") >= 0 &&
        body.indexOf("+one") >= 0,
        "apply_patch preview lost the streamed patch: [" ~ body ~ "]");
    assert(body.indexOf("*** Begin Patch") < 0 &&
        body.indexOf("*** End Patch") < 0,
        "apply_patch preview kept the patch envelope: [" ~ body ~ "]");
    // The newest line can be half a closing marker while the args stream; it
    // must not paint as a stray "*" row.
    const truncated = previewToolDiffText("apply_patch",
        `{"patch":"*** Begin Patch\n*** Update File: a.txt\n+one\n*"`);
    bool strayMarker;
    foreach (line; truncated.splitLines())
    {
        const text = strip(line);
        if (text.length > 0 && ("*** Begin Patch".indexOf(text) == 0 ||
            "*** End Patch".indexOf(text) == 0)) strayMarker = true;
    }
    assert(truncated.indexOf("+one") >= 0 && !strayMarker,
        "apply_patch preview showed a partial envelope marker: [" ~
        truncated ~ "]");
    assert(!previewToolDiff("read", `{"filePath":"a.txt"}`, adds, dels),
        "a read call must not report a diff preview");
}
