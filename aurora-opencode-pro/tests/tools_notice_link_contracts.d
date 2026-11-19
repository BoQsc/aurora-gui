module tools_notice_link_contracts;

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

/// A tool request refused because tools are off must settle as one short notice
/// whose "Enable tools" link turns tools back on with a real click - and that
/// click must not be swallowed as the start of a text selection.
int main()
{
    const state = buildPath(tempDir(),
        "tools-notice-link-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = "http://127.0.0.1:9";
    settings.apiKey = "fixture";
    settings.model = "tools-notice-fixture";
    settings.quickTitle = false;
    settings.workspace = state;
    settings.autoGoalFromFirstMessage = false;
    settings.toolsEnabled = false;
    saveSettings(settings);

    WindowOptions options;
    options.width = 1100;
    options.height = 800;
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
    assert(!root.startupPendingForTesting(), "the app never finished starting");

    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"],
        ["Run build/live-compare.py.", "Ready."]);
    const sessionIndex = root.currentSessionForTesting();
    root.setImageToolsEnabledForTesting(false);

    // Deliver a real tool request while tools are off, exactly as the client
    // would when the reader disabled them mid-turn.
    OpenCodeToolCall call;
    call.id = "call-1";
    call.name = "run";
    call.arguments = `{"program":"python","args":["build/live-compare.py"]}`;
    root.injectToolCallsForTesting([call]);
    window.onNativeTick(0.02);

    const replyIndex = root.sessionMessageCountForTesting(sessionIndex) - 1;
    const content = root.messageContentForTesting(replyIndex);
    assert(content.indexOf("tools are disabled") >= 0, content);
    assert(content.indexOf("[Enable tools](aurora:enable-tools)") >= 0, content);
    assert(!root.toolsEnabledForTesting(),
        "the fixture started with tools enabled");

    auto driver = new UiTestDriver(window);
    driver.paint();
    const link = root.actionLinkPointForTesting(replyIndex,
        "aurora:enable-tools");
    assert(link.x >= 0 && link.y >= 0,
        "the disabled-tools notice rendered no Enable tools link");

    driver.click(link);
    window.onNativeTick(0.02);

    assert(root.toolsEnabledForTesting(),
        "clicking the notice's Enable tools link did not enable tools");
    assert(root.sessionToolsModeForTesting(sessionIndex) == -1,
        "the click left an explicit per-chat tools override in place");
    assert(root.selectedMessageTextForTesting(replyIndex).length == 0,
        "the click on the action link started a text selection instead");
    writeln("PASS the disabled-tools notice's link re-enables tools on a real click");
    return 0;
}
