module compact_copy_probe;

// Focused headless probe for the conversation context-menu item
// "Copy & compact into new chat": it must be offered, and invoking it must
// create a NEW conversation that is a verbatim copy of the source AND carries a
// compaction checkpoint. Offline (no API key) the handler falls back to the
// extractive checkpoint, so this runs deterministically without a provider.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;

import std.array : appender, join;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : endsWith;

private string big(string seed)
{
    auto buf = appender!string();
    buf.put(seed);
    foreach (i; 0 .. 1100) buf.put(" lorem ipsum dolor sit amet");
    return buf.data;
}

private void writeSettings(string stateDir)
{
    JSONValue root;
    // An explicitly blank key keeps the handler on the offline extractive path.
    root["apiKey"] = "";
    root["baseUrl"] = "http://Probe.Local/v1/";
    root["model"] = "probe-model";
    JSONValue budgets = JSONValue(string[].init);
    JSONValue budget;
    budget["baseUrl"] = "http://probe.local/v1";
    budget["model"] = "probe-model";
    budget["tokens"] = 60000;
    budgets.array ~= budget;
    root["contextBudgets"] = budgets;
    write(buildPath(stateDir, "settings.json"), root.toString());
}

private void writeSessions(string stateDir)
{
    JSONValue root;
    JSONValue sessions = JSONValue(string[].init);
    JSONValue session;
    session["id"] = "t-probe-source";
    session["title"] = "Probe source";
    session["model"] = "probe-model";
    session["thinking"] = false;
    JSONValue messages = JSONValue(string[].init);
    const(string)[] roles = ["user", "assistant", "user", "assistant"];
    const(string)[] bodies = [big("first question"),
        big("first answer"), big("second question"), big("second answer")];
    foreach (i; 0 .. roles.length)
    {
        JSONValue message;
        message["role"] = roles[i];
        message["content"] = bodies[i];
        message["id"] = "pm-" ~ ["1", "2", "3", "4"][i];
        if (i > 0) message["parentId"] = "pm-" ~ ["1", "2", "3", "4"][i - 1];
        messages.array ~= message;
    }
    session["messages"] = messages;
    session["activeLeaf"] = "pm-4";
    sessions.array ~= session;
    root["sessions"] = sessions;
    root["current"] = 0;
    write(buildPath(stateDir, "sessions.json"), root.toString());
}

int main()
{
    const stateDir = buildPath(tempDir(), "aurora-compact-copy-probe");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);
    writeSettings(stateDir);
    writeSessions(stateDir);

    WindowOptions options;
    options.title = "Aurora compact-copy probe";
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    root.tickTree(0.02);

    writeln("budget seen: ",
        root.requestContextBudgetForTesting("probe-model"));

    // The item must be offered for the conversation.
    const labels = root.sessionContextMenuLabelsForTesting(0);
    writeln("menu: ", labels);
    bool sawItem;
    bool sawOpenFolder;
    foreach (label; labels)
    {
        if (label == "Copy & compact into new chat") sawItem = true;
        if (label == "Open folder") sawOpenFolder = true;
    }
    assert(sawItem, "the conversation menu never offered the copy+compact item");
    assert(sawOpenFolder,
        "the conversation menu never offered the open-folder item");

    const before = root.sessionCountForTesting();
    const sourceMessages = root.sessionMessageCountForTesting(0);
    const sourceTitle = root.sessionTitleForTesting(0);
    assert(sourceMessages == 4, "fixture did not seed four messages");

    assert(root.invokeSessionContextMenuItemForTesting(0,
        "Copy & compact into new chat"), "the copy+compact action did not run");

    assert(root.sessionCountForTesting() == before + 1,
        "the action did not add a conversation");

    const copy = root.currentSessionForTesting();
    writeln("new session index: ", copy,
        " title: ", root.sessionTitleForTesting(copy),
        " messages: ", root.sessionMessageCountForTesting(copy),
        " compacted: ", root.sessionCompactedForTesting(copy));

    assert(root.sessionTitleForTesting(copy).endsWith("(compacted)"),
        "the new conversation is not marked as a compacted copy");
    assert(root.sessionMessageCountForTesting(copy) == sourceMessages,
        "the new conversation did not copy every message");
    foreach (i; 0 .. sourceMessages)
        assert(root.sessionMessageContentForTesting(copy, i) ==
            root.sessionMessageContentForTesting(0, i),
            "copied message " ~ ["0", "1", "2", "3"][i] ~ " differs");
    assert(root.sessionCompactedForTesting(copy),
        "the new conversation carries no compaction checkpoint");
    assert(!root.sessionCompactedForTesting(0),
        "the original conversation was modified");

    writeln("PASS: copy & compact context menu item works (source ", sourceTitle, ")");
    return 0;
}
