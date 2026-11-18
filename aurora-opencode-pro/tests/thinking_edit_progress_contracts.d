module thinking_edit_progress_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings,
    sandboxFolderPath, setOpencodeStateDirectoryForTesting, opencodeTheme;
import auroraopencode.tools : previewToolDiff, previewToolDiffText;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
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
    int maxAdds;
    int maxDels;
    string lastRow;
    string lastDiff;
    string lastPreview;
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
    assert(!quietWhileApplying,
        "the Thinking header claimed 'no new output' while the live edit row was " ~
        "streaming: [" ~ lastHeaderWhileApplying ~ "]");
    assert(root.totalToolGroupAdditionsForTesting() >= 3,
        "the settled patch row lost the change the streamed patch carried");
    writeln("PASS thinking followed by editing keeps the live edit visible");
    return 0;
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
