module turn_flow_http_test;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.datetime : Clock;
import std.file : mkdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;
import std.algorithm : endsWith;

private void until(OpenCodeRoot root, bool delegate() ready)
{
    const deadline = MonoTime.currTime + 10.seconds;
    while (!ready() && MonoTime.currTime < deadline)
    {
        root.tickTree(0.02);
        Thread.sleep(20.msecs);
    }
    assert(ready(), "Provider flow did not reach the expected state");
}

int main(string[] args)
{
    assert(args.length == 2);
    const state = buildPath(tempDir(), "aurora-turn-flow-" ~ to!string(Clock.currTime.stdTime));
    mkdirRecurse(state);
    JSONValue settings;
    settings["baseUrl"] = args[1];
    settings["apiKey"] = "fixture";
    settings["model"] = "fixture";
    settings["workspace"] = state;
    settings["quickTitle"] = false;
    settings["toolsEnabled"] = true;
    write(buildPath(state, "settings.json"), settings.toString());
    setOpencodeStateDirectoryForTesting(state);
    WindowOptions options;
    options.width = 1000;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    foreach (_; 0 .. 30) { root.tickTree(0.02); Thread.sleep(10.msecs); }
    root.newChatForTesting();
    root.setInputForTesting("fixture: full flow");
    root.sendForTesting();
    until(root, delegate()
    {
        foreach (preview; root.liveToolRowPreviewsForTesting())
            if (preview.indexOf("fixture live output") >= 0) return true;
        return false;
    });
    root.setInputForTesting("fixture: steering applied once");
    root.sendForTesting();
    assert(root.queuedGuidanceCountForTesting() == 1);
    until(root, delegate() { return !root.turnBusyForTesting(); });
    assert(root.lastAssistantContentForTesting() == "Confirmed result and steering.");
    assert(root.toolMessageCountForTesting() == 1 && root.queuedGuidanceCountForTesting() == 0);
    assert(root.sendButtonTextForTesting() == "Send");
    writeln("Real Pro flow: send -> streamed command output -> queued guidance -> tool result -> final answer");

    root.newChatForTesting();
    root.setInputForTesting("fixture: quiet");
    root.sendForTesting();
    until(root, delegate() { return root.lastAssistantContentForTesting().indexOf("Initial fragment.") >= 0; });
    root.ageStreamOutputForTesting(31);
    root.tickTree(0.02);
    assert(root.activityDisplayTextForTesting().indexOf("No new output for 31s") >= 0,
        "A quiet mid-response request did not show its wait state");
    assert(root.turnBusyForTesting(), "Wait advisory cancelled a healthy turn");
    root.tickTree(1.1);
    driver.paint();
    assert(root.activityDisplayTextForTesting().endsWith("Stop is available"),
        "Wait advisory appended a second, contradictory timer");
    window.saveScreenshot("build/turn-flow-quiet.ppm");
    until(root, delegate() { return !root.turnBusyForTesting(); });
    assert(root.lastAssistantContentForTesting() == "Initial fragment. Resumed.");
    assert(!root.activityVisibleForTesting(), "Wait advisory survived completion");
    writeln("Quiet provider: visible wait advisory, automatic recovery, no forced timeout");

    root.newChatForTesting();
    root.setInputForTesting("fixture: quiet");
    root.sendForTesting();
    until(root, delegate() { return root.lastAssistantContentForTesting().indexOf("Initial fragment.") >= 0; });
    root.clickSendButtonForTesting();
    root.setInputForTesting("fixture: replacement");
    root.sendForTesting();
    until(root, delegate() { return !root.turnBusyForTesting(); });
    assert(root.lastAssistantContentForTesting() == "Replacement answer.", "Stop/resend mixed request output");
    Thread.sleep(2100.msecs);
    root.tickTree(0.02);
    assert(root.lastAssistantContentForTesting() == "Replacement answer.", "Late response leaked into replacement turn");
    root.shutdownClient();
    writeln("Real Pro flow: Stop immediately resends and discards delayed old output");
    return 0;
}
