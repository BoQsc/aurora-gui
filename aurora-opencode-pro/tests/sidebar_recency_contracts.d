module sidebar_recency_contracts;

// The sidebar orders conversations by their persisted last-activity stamp and
// paints that same stamp on every row. Threads restore lazily, so a row must not
// depend on its message body being in memory to show a time.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;

import std.conv : to;
import std.datetime : Clock, SysTime;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;

private void writeSettings(string stateDir)
{
    JSONValue root;
    root["apiKey"] = "";
    root["baseUrl"] = "http://127.0.0.1:9/v1/";
    root["model"] = "probe-model";
    root["sortSessionsByRecency"] = true;
    write(buildPath(stateDir, "settings.json"), root.toString());
}

private string expectedTime(long unixSeconds)
{
    const when = SysTime.fromUnixTime(unixSeconds).toLocalTime;
    string pad(int value)
    {
        return value < 10 ? "0" ~ to!string(value) : to!string(value);
    }
    return pad(when.hour) ~ ":" ~ pad(when.minute);
}

private void expectRow(OpenCodeRoot root, int row, int session,
    string time, string context)
{
    assert(root.visibleSessionIndexAtRowForTesting(row) == session,
        context ~ ": wrong conversation at row " ~ to!string(row));
    assert(root.sessionRowSecondaryForTesting(row) == time,
        context ~ ": row time is '" ~
            root.sessionRowSecondaryForTesting(row) ~ "', expected '" ~
            time ~ "'");
}

int main()
{
    const stateDir = buildPath(tempDir(), "aurora-sidebar-recency-probe");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);
    writeSettings(stateDir);

    WindowOptions options;
    options.title = "Aurora sidebar recency probe";
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

    root.newChatForTesting();
    root.newChatForTesting();
    root.newChatForTesting();
    assert(root.sessionCountForTesting() == 3, "expected three conversations");

    // Distinct stamps order strictly by last activity regardless of creation
    // order. None of these threads has a loaded body.
    const now = Clock.currTime.toUnixTime();
    const oldAt = now - 3600;
    const midAt = now - 1800;
    const newAt = now - 60;
    root.setSessionUpdatedAtForTesting(0, oldAt);
    root.setSessionUpdatedAtForTesting(1, newAt);
    root.setSessionUpdatedAtForTesting(2, midAt);
    root.refreshSessionListForTesting();

    assert(root.sessionMessageCountForTesting(0) == 0,
        "probe must exercise rows without loaded messages");
    expectRow(root, 0, 1, expectedTime(newAt), "newest activity");
    expectRow(root, 1, 2, expectedTime(midAt), "middle activity");
    expectRow(root, 2, 0, expectedTime(oldAt), "oldest activity");

    // Equal activity stamps use creation order, newest first, so the order is
    // repeatable even after the sessions array is rearranged by copy or move.
    root.setSessionUpdatedAtForTesting(0, midAt);
    root.setSessionUpdatedAtForTesting(1, midAt);
    root.setSessionUpdatedAtForTesting(2, oldAt);
    root.refreshSessionListForTesting();
    expectRow(root, 0, 1, expectedTime(midAt), "equal stamp, newer chat");
    expectRow(root, 1, 0, expectedTime(midAt), "equal stamp, older chat");
    expectRow(root, 2, 2, expectedTime(oldAt), "equal stamp, oldest chat");

    // Merely opening a conversation is not activity and must not reorder it.
    root.selectSessionForTesting(0);
    root.refreshSessionListForTesting();
    expectRow(root, 0, 1, expectedTime(midAt), "after opening a chat");
    expectRow(root, 1, 0, expectedTime(midAt), "after opening a chat");

    // Moving a conversation between projects is organization, not activity: it
    // must keep its stamp instead of jumping to the top of the target list.
    root.addProjectForTesting("Target Project", buildPath(stateDir, "target"));
    root.selectProjectForTesting(0);
    root.refreshSessionListForTesting();
    int sourceRow = -1;
    foreach (row; 0 .. 3)
        if (root.visibleSessionIndexAtRowForTesting(row) == 0) sourceRow = row;
    assert(sourceRow >= 0, "source conversation is missing from the sandbox");
    assert(root.invokeSessionContextMenuItemForTesting(sourceRow,
        "Target Project"), "move action was not offered");
    root.selectProjectForTesting(1);
    root.refreshSessionListForTesting();
    assert(root.visibleSessionCountForTesting() == 1,
        "moved conversation should be the only row in the target project");
    expectRow(root, 0, 0, expectedTime(midAt), "after moving projects");

    writeln("PASS: sidebar uses persisted activity stamps and stable ordering");
    return 0;
}