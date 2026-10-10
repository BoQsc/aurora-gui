module conversation_flow_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings, setOpencodeStateDirectoryForTesting, opencodeTheme;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, readText;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run test_conversation_flow.py");
    const state = absolutePath("conversation-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(state, "workspace");
    mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = base; settings.apiKey = "fixture"; settings.model = "conversation-fixture";
    settings.workspace = workspace; settings.toolsEnabled = true; settings.quickTitle = false;
    settings.legacyTools = false;
    saveSettings(settings);
    WindowOptions options;
    options.width = 1000; options.height = 700; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void pump()
    {
        window.onNativeTick(0.02);
        root.projectTranscriptForTesting();
        assert(driver.paint());
        assert(root.transcriptRowsSequentialForTesting(), "Conversation rows overlap");
        Thread.sleep(5.msecs);
    }
    void until(bool delegate() done)
    {
        const deadline = MonoTime.currTime + 15.seconds;
        while (!done() && MonoTime.currTime < deadline) pump();
        assert(done(), "Conversation did not reach expected state; last answer: " ~
            root.lastAssistantContentForTesting() ~ " error: " ~ root.lastAssistantErrorForTesting());
    }
    void send(string prompt)
    {
        root.setInputForTesting(prompt);
        root.sendForTesting();
    }
    void settle()
    {
        until(delegate() { return !root.turnBusyForTesting(); });
        assert(root.sendButtonTextForTesting() == "Send");
        assert(!root.activityVisibleForTesting(), "Activity survived completion");
    }
    until(delegate() { return !root.startupPendingForTesting(); });
    root.newChatForTesting();
    send("CHAT: I'm tired. Help plan a simple vegetarian dinner, no mushrooms, within 45 minutes.");
    settle();
    assert(root.toolMessageCountForTesting() == 0, "Casual reply fabricated tool activity");
    send("CORRECTION: There are four people and one needs gluten-free food. Keep my other constraints.");
    settle();
    assert(root.lastAssistantContentForTesting().indexOf("four") >= 0);
    send("SAVE: Save dinner-plan.md, read it back, then briefly confirm. Do not run commands.");
    settle();
    assert(root.lastAssistantContentForTesting() == "Saved and read back dinner-plan.md with all corrected constraints.");
    assert(root.toolMessageCountForTesting() == 2, "Document task executed extra tools");
    assert(root.verificationStatusForTesting() != "required",
        "Plain Markdown task still demanded executable verification after readback");
    const savedNote = readText(buildPath(workspace, "dinner-plan.md"));
    const mainChat = root.currentSessionForTesting();
    send("REPAIR: Fix and test the guest-count script. Preserve the dinner plan.");
    until(delegate() {
        if (root.toolMessageCountForTesting() < 4) return false;
        foreach (preview; root.liveToolRowPreviewsForTesting())
            if (preview.indexOf("checking guest count") >= 0) return true;
        return false;
    });
    assert(root.verificationStatusForTesting() == "required",
        "Executable changes bypassed focused verification");
    send("STEER: The corrected count is four; keep the dinner notes untouched.");
    assert(root.queuedGuidanceCountForTesting() == 1);
    root.setInputForTesting("RECAP: Summarize the corrected constraints and the fix after finishing.");
    root.queueComposerForTesting();
    assert(root.queuedFollowUpCountForTesting() == 1);
    until(delegate() {
        return !root.turnBusyForTesting() && root.lastAssistantContentForTesting().indexOf("Recap:") == 0;
    });
    assert(root.queuedGuidanceCountForTesting() == 0 && root.queuedFollowUpCountForTesting() == 0);
    assert(readText(buildPath(workspace, "dinner-plan.md")) == savedNote);
    assert(readText(buildPath(workspace, "test_dinner.py")).indexOf("SEATS = 4") >= 0);
    bool failedVisible;
    assert(root.verificationStatusForTesting() != "required",
        "Successful unbuffered unittest run did not settle verification");
    foreach (header; root.toolGroupHeaderTextsForTesting())
        if (header.indexOf("1 failed") >= 0) failedVisible = true;
    assert(failedVisible, "Collapsed tool group concealed its failed command");
    bool failedCommandLabel;
    foreach (header; root.toolResultHeaderTextsForTesting())
        if (header.indexOf("Shell · Failed") == 0) failedCommandLabel = true;
    assert(failedCommandLabel, "Failed command depended on color alone");
    window.saveScreenshot(buildPath(state, "conversation-recovered.ppm"));
    root.persistForTesting();
    root.reloadSessionsForTesting();
    assert(root.lastAssistantContentForTesting().indexOf("Recap:") == 0);

    send("SLOW: Think through another option slowly.");
    until(delegate() { return root.lastAssistantContentForTesting() == "Partial response."; });
    const partialIndex = cast(int) root.totalMessageCountForTesting() - 1;
    root.clickSendButtonForTesting(); // real Stop action
    assert(!root.turnBusyForTesting());
    send("NEW: Give a fresh brief reply after Stop.");
    settle();
    const drainDeadline = MonoTime.currTime + 950.msecs;
    while (MonoTime.currTime < drainDeadline) pump();
    assert(root.lastAssistantContentForTesting() == "Fresh response after Stop.");
    assert(root.messageContentForTesting(partialIndex) == "Partial response.",
        "Stop lost the partial reply or accepted its late tail");

    send("SLOW: Continue in this chat while I open another.");
    until(delegate() { return root.lastAssistantContentForTesting() == "Partial response."; });
    root.newChatForTesting();
    const otherChat = root.currentSessionForTesting();
    send("OTHER: Answer independently of the dinner conversation.");
    settle();
    assert(root.lastAssistantContentForTesting() == "Independent chat response.");
    root.newChatForTesting();
    root.pauseToolContinuationForTesting();
    root.addConversationForTesting(["user", "assistant"], ["Change code and document it", ""]);
    root.injectToolResultForTesting("write", "Wrote app.d", false,
        `{"filePath":"app.d"}`, 1, 0, "+code\n");
    assert(root.verificationStatusForTesting() == "required");
    root.injectToolResultForTesting("write", "Wrote notes.md", false,
        `{"filePath":"notes.md"}`, 1, 0, "+notes\n");
    root.injectToolResultForTesting("read", "1: notes", false, `{"filePath":"notes.md"}`);
    assert(root.verificationStatusForTesting() == "required",
        "Document work cleared outstanding executable verification");
    const backgroundDeadline = MonoTime.currTime + 950.msecs;
    while (MonoTime.currTime < backgroundDeadline) pump();
    root.selectSessionForTesting(mainChat);
    until(delegate() { return !root.historyPendingForTesting() && !root.turnBusyForTesting(); });
    assert(root.lastAssistantContentForTesting() == "Partial response. Late tail.",
        "Background response was lost or routed to another chat");
    root.persistForTesting();
    root.reloadSessionsForTesting();
    assert(root.lastAssistantContentForTesting() == "Partial response. Late tail.");
    root.selectSessionForTesting(otherChat);
    until(delegate() { return !root.historyPendingForTesting(); });
    assert(root.lastAssistantContentForTesting() == "Independent chat response.");
    writeln("PASS complex conversation: corrected context, document readback, executable verification, tool failure recovery, steering/follow-up exactly once, Stop, independent background chats and persisted reload");
    return 0;
}
