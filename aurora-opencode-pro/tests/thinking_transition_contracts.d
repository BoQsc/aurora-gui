module thinking_transition_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings, setOpencodeStateDirectoryForTesting, opencodeTheme;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, tempDir;
import std.path : buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf;

/// The end of a reasoning burst must never read as a frozen transcript.
///
/// Ordering was already correct (user prompt, then the round's Thinking reply,
/// then its own action group), but after the reasoning stopped the header's
/// token count froze and the only movement was a small pulse until the provider
/// produced the answer. The live header now carries a `no new output for Ns`
/// clock for that window and drops it on the next fragment. This fixture drives
/// the real widget tree through both a synthetic turn and a real HTTP provider
/// that stalls between the reasoning stream and the answer.
int main()
{
    const state = buildPath(tempDir(), "aurora-thinking-transition-" ~
        to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(settings.baseUrl.length);
    settings.apiKey = "fixture";
    settings.model = "thinking-fixture";
    settings.workspace = state;
    settings.toolsEnabled = false;
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

    void until(bool delegate() ready)
    {
        const deadline = MonoTime.currTime + 15.seconds;
        while (!ready() && MonoTime.currTime < deadline)
        {
            window.onNativeTick(0.02);
            Thread.sleep(5.msecs);
        }
        assert(ready(), "Thinking transition condition was not reached: header=[" ~
            root.liveThinkingHeaderForTesting() ~ "] answer=[" ~
            root.lastAssistantContentForTesting() ~ "] error=[" ~
            root.lastAssistantErrorForTesting() ~ "] activity=[" ~
            root.activityTextForTesting() ~ "]");
    }

    until(delegate() { return !root.startupPendingForTesting(); });

    // A live reply shows its Thinking header at once, then explains the quiet
    // window instead of freezing, then drops the note when output resumes. The
    // answer stays in that same bubble, directly under the header.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["reasoning gap check"]);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    root.streamReasoningForTesting("Considering the request.");
    until(delegate() { return root.liveThinkingHeaderForTesting().indexOf("Thinking") >= 0; });
    assert(root.liveThinkingHeaderForTesting().indexOf("no new output") < 0,
        "quiet note appeared before the reply actually went quiet");
    until(delegate() { return root.liveThinkingHeaderForTesting().indexOf("no new output for") >= 0; });
    const gapRows = root.columnDebugForTesting();
    size_t userRow = size_t.max, replyRow = size_t.max;
    foreach (i, row; gapRows)
    {
        if (userRow == size_t.max && row.indexOf("role=user") >= 0) userRow = i;
        else if (replyRow == size_t.max && row.indexOf("bubble role=assistant") >= 0) replyRow = i;
    }
    assert(userRow != size_t.max && replyRow == userRow + 1,
        "live Thinking reply did not follow its prompt");
    assert(gapRows[replyRow].indexOf("think=1") >= 0 &&
        gapRows[replyRow].indexOf("content=0") >= 0,
        "the quiet reply left its Thinking header instead of staying in it");
    assert(root.lastAssistantContentForTesting().length == 0,
        "answer text arrived before the quiet window was observed");
    root.projectTranscriptForTesting();
    assert(driver.paint());
    window.saveScreenshot("build/thinking-transition-gap.ppm");
    root.streamContentForTesting("Answer after thinking.");
    until(delegate() { return root.lastAssistantContentForTesting() == "Answer after thinking."; });
    assert(root.liveThinkingHeaderForTesting().indexOf("no new output") < 0,
        "quiet note stayed after streamed output resumed");
    assert(root.thinkingHeaderCountForTesting() == 1,
        "the answer did not stay under the same Thinking header");
    writeln("PASS end-of-thinking quiet window explains itself without breaking reply order");

    // Real provider path: the reasoning stream ends, then the provider goes
    // quiet for several seconds before the answer. The same header note must
    // explain the gap and the answer must settle under the same Thinking row.
    root.newChatForTesting();
    root.setInputForTesting("explain the reasoning gap");
    root.sendForTesting();
    until(delegate() { return root.liveThinkingHeaderForTesting().indexOf("no new output for") >= 0; });
    assert(root.lastAssistantContentForTesting().length == 0,
        "the provider answer arrived before the quiet window was observed");
    until(delegate() { return root.lastAssistantContentForTesting() == "Answer after thinking."; });
    until(delegate() { return !root.turnBusyForTesting(); });
    root.projectTranscriptForTesting();
    assert(root.liveThinkingHeaderForTesting().length == 0,
        "the live Thinking header survived the completed turn");
    assert(root.thinkingHeaderCountForTesting() == 1,
        "the settled reply lost its Thinking header");
    assert(root.lastAssistantContentForTesting() == "Answer after thinking.",
        "the settled reply lost its answer: [" ~
        root.lastAssistantContentForTesting() ~ "]");
    writeln("PASS real provider reasoning gap shows a live quiet clock and settles in order");
    return 0;
}
