module stop_probe;

import aurora;
import aurora.testing : UiTestDriver;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : setOpencodeStateDirectoryForTesting, opencodeTheme;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;
import std.conv : to;

private Widget findById(Widget widget, string requestedId)
{
    if (widget is null) return null;
    if (widget.id() == requestedId) return widget;
    foreach (child; widget.children())
    {
        auto found = findById(child, requestedId);
        if (found !is null) return found;
    }
    return null;
}

private T requireWidget(T)(Widget root, string requestedId)
{
    auto widget = cast(T) findById(root, requestedId);
    assert(widget !is null, "Missing or wrong widget type for id: " ~ requestedId);
    return widget;
}

private void dump(OpenCodeRoot root, string tag)
{
    writeln("=== ", tag, " ===");
    const total = root.totalMessageCountForTesting();
    writeln("total=", total, " visible=", root.messageCountForTesting());
    foreach (i; 0 .. total)
        writeln("  [", i, "] ", root.messageRoleForTesting(i), " : ",
            root.messageContentForTesting(i).length > 60
                ? root.messageContentForTesting(i)[0 .. 60]
                : root.messageContentForTesting(i));
    writeln("  lastAssistant=", root.lastAssistantContentForTesting());
}

int main()
{
    const stateDir = buildPath(tempDir(), "aurora-stop-probe-state");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);

    WindowOptions options;
    options.title = "stop probe";
    options.width = 1000;
    options.height = 700;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    assert(driver.paint());
    root.tickTree(0.02);

    // Scenario 1: reasoning-only stream, then stop.
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"],
        ["prior question", "prior answer"]);
    root.setInputForTesting("second question");
    (cast(TextArea) requireWidget!Widget(root, "oc-input")).requestFocus();
    driver.pressKey(Key.enter);
    root.tickTree(0.02);
    root.beginStreamForTesting();
    root.streamReasoningForTesting("thinking hard about it");
    root.tickTree(0.02);
    dump(root, "S1 before stop (reasoning)");
    root.clickSendButtonForTesting();
    root.tickTree(0.02);
    dump(root, "S1 after stop (reasoning)");

    // Scenario 2: tool round, then stop during the follow-up round.
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"],
        ["prior q2", "prior a2"]);
    root.setInputForTesting("tool question");
    (cast(TextArea) requireWidget!Widget(root, "oc-input")).requestFocus();
    driver.pressKey(Key.enter);
    root.tickTree(0.02);
    root.beginStreamForTesting();
    root.streamContentForTesting("Let me read that file.");
    root.appendToolRequestTurnForTesting("", "call_probe", "read",
        `{"filePath":"x.txt"}`);
    root.appendToolReplyForTesting("call_probe", "file body");
    root.tickTree(0.02);
    dump(root, "S2 before stop (after tool round)");
    root.beginStreamForTesting();
    root.streamContentForTesting("round two partial");
    root.tickTree(0.02);
    dump(root, "S2 mid round two");
    root.clickSendButtonForTesting();
    root.tickTree(0.02);
    dump(root, "S2 after stop");
    root.persistForTesting();
    root.reloadSessionsForTesting();
    dump(root, "S2 after persist+reload");
    return 0;
}
