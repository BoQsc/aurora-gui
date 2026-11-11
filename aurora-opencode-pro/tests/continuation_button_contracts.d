module continuation_button_contracts;
import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, tempDir;
import std.path : buildPath;
import std.string : indexOf;
import std.stdio : writeln;

/// The idle Send button is the explicit Continue action while durable plan work
/// remains. This must not depend on a provider or on the turn being interrupted.
int main()
{
    const state = buildPath(tempDir(),
        "continuation-button-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = "http://127.0.0.1:9";
    settings.apiKey = "fixture";
    settings.model = "continuation-fixture";
    settings.quickTitle = false;
    settings.workspace = state;
    settings.autoGoalFromFirstMessage = false;
    saveSettings(settings);
    WindowOptions options;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    {
        window.onNativeTick(0.02);
        Thread.sleep(5.msecs);
    }
    assert(!root.startupPendingForTesting());

    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"],
        ["What does the pending plan mean?", "Partial work is done."]);
    root.setTaskStateForTesting("Implement the fixture plan", "active", "not_required");
    root.applyPlanForTesting(`{"plan":[{"step":"First outcome","status":"in_progress"}]}`);
    const sessionIndex = root.currentSessionForTesting();
    // Settle through the same done-event path that builds the reply pill.
    root.completeTurnInSessionForTesting(sessionIndex);
    window.onNativeTick(0.02);
    assert(root.turnStatusForTesting() == "completed");
    assert(root.taskStatusForTesting() == "active");

    assert(root.sendButtonTextForTesting() == "Continue",
        "The idle Send button did not offer Continue for unfinished plan work");
    assert(root.sendEnabledForTesting(),
        "Continue was visible but the Send button stayed disabled");
    assert(root.lastAssistantBubbleSecondaryActionForTesting() == "Continue",
        "The transcript's reply pill did not offer Continue for unfinished plan work");
    const before = root.sessionMessageCountForTesting(sessionIndex);
    root.clickSendButtonForTesting();
    assert(root.sessionMessageCountForTesting(sessionIndex) > before,
        "Clicking Continue did not append a continuation turn");
    const continuation = root.messageContentForTesting(before);
    assert(continuation.indexOf("Continuation request: resume the current task") >= 0,
        continuation);
    writeln("PASS idle Send offers Continue and resumes unfinished plan work without typed text");
    return 0;
}
