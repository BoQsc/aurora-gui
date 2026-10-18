module freeze_reuse_contracts;

// Focused headless probe for the freeze-diagnostic conversation. A burst of
// freezes must append to ONE investigation chat, while a freeze after the reuse
// window expires starts a fresh chat. It runs offline: the diagnostic turn is
// accepted locally, so only the conversation bookkeeping is asserted.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import auroraopencode.emergency : freezeInvestigationTitle;

import std.datetime : Clock;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;

private void writeSettings(string stateDir)
{
    JSONValue root;
    // A refused local port keeps the probe offline and fast.
    root["apiKey"] = "";
    root["baseUrl"] = "http://127.0.0.1:9/v1/";
    root["model"] = "probe-model";
    write(buildPath(stateDir, "settings.json"), root.toString());
}

int main()
{
    const stateDir = buildPath(tempDir(), "aurora-freeze-reuse-probe");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);
    writeSettings(stateDir);

    WindowOptions options;
    options.title = "Aurora freeze-reuse probe";
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    foreach (_; 0 .. 50)
    {
        root.tickTree(0.02);
        if (!root.startupPendingForTesting()) break;
    }
    assert(!root.startupPendingForTesting(), "startup restore never finished");

    const before = root.sessionCountForTesting();
    assert(root.emergencyReuseIndexForTesting() == -1,
        "reused an investigation chat before any freeze happened");

    // The first freeze opens exactly one investigation chat.
    root.fireEmergencyChatForTesting("first freeze");
    root.tickTree(0.02);
    assert(root.sessionCountForTesting() == before + 1,
        "the first freeze did not open a conversation");
    const first = root.currentSessionForTesting();
    assert(root.sessionTitleForTesting(first) == freezeInvestigationTitle,
        "the investigation chat is not titled for reuse");
    assert(root.emergencyChatsFiredForTesting() == 1,
        "the first freeze was not counted as a new chat");
    assert(root.emergencyReuseIndexForTesting() == first,
        "the freeze chat is not reusable while it is recent");

    // A repeat freeze soon after appends to the same chat, not a new one.
    root.fireEmergencyChatForTesting("second freeze");
    root.tickTree(0.02);
    assert(root.sessionCountForTesting() == before + 1,
        "a repeat freeze opened a new conversation instead of reusing one");
    assert(root.currentSessionForTesting() == first,
        "the repeat freeze switched away from the investigation chat");
    assert(root.emergencyChatsFiredForTesting() == 1,
        "reuse was counted as a new chat");

    // Past the reuse window a genuinely new conversation starts.
    root.setSessionUpdatedAtForTesting(first, Clock.currTime.toUnixTime() - 1000);
    assert(root.emergencyReuseIndexForTesting() == -1,
        "an expired investigation chat was still offered for reuse");
    root.fireEmergencyChatForTesting("a much later freeze");
    root.tickTree(0.02);
    assert(root.sessionCountForTesting() == before + 2,
        "a freeze past the window did not open a new conversation");
    assert(root.emergencyChatsFiredForTesting() == 2,
        "the post-window chat was not counted");

    writeln("PASS: freeze diagnostics reuse one conversation within the window");
    return 0;
}
