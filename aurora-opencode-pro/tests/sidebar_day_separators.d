module sidebar_day_separators;

// The conversation list groups rows by the local calendar day of their last
// activity. A heading opens each day ("Today", "Yesterday", then a date) and
// owns the extra vertical slot above its first row, so hit-testing must skip
// that slot instead of mapping it to the row above.

import aurora;
import auroraopencode.appui : OpenCodeRoot, SessionListView;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;

import std.algorithm : startsWith;
import std.conv : to;
import std.datetime : Clock, days;
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

int main()
{
    const stateDir = buildPath(tempDir(), "aurora-sidebar-day-probe");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);
    writeSettings(stateDir);

    WindowOptions options;
    options.title = "Aurora sidebar day-separator probe";
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    assert(driver.paint(), "initial paint failed");
    root.tickTree(0.02);
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
    auto sessions = requireWidget!SessionListView(root, "oc-sessions");

    const now = Clock.currTime;
    const today = now.toUnixTime();
    const yesterday = (now - days(1)).toUnixTime();
    const older = (now - days(4)).toUnixTime();
    root.setSessionUpdatedAtForTesting(0, older);
    root.setSessionUpdatedAtForTesting(1, today);
    root.setSessionUpdatedAtForTesting(2, yesterday);
    root.refreshSessionListForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "paint after refresh failed");

    // Recency order: today, yesterday, then the older conversation. Each day
    // opens a heading at its first row.
    assert(root.visibleSessionIndexAtRowForTesting(0) == 1,
        "today's conversation should lead the list");
    assert(root.visibleSessionIndexAtRowForTesting(1) == 2,
        "yesterday's conversation should follow");
    assert(root.visibleSessionIndexAtRowForTesting(2) == 0,
        "the oldest conversation should be last");
    const separators = root.sessionDaySeparatorsForTesting();
    assert(separators.startsWith("0=Today,1=Yesterday,2="),
        "unexpected day separators: " ~ separators);
    const olderLabel = separators["0=Today,1=Yesterday,2=".length .. $];
    assert(olderLabel.length > 0 && olderLabel != "Today" &&
        olderLabel != "Yesterday",
        "the older day should carry a date heading, was '" ~ olderLabel ~ "'");
    writeln("Day separators: ", separators);

    // A heading opens real vertical room above its day's first row.
    const rowHeight = sessions.rowHeight();
    const span = sessions.daySeparatorSpanForTesting();
    assert(span > 0, "a day heading must occupy some vertical room");
    const first = sessions.rowCenterForTesting(0);
    const second = sessions.rowCenterForTesting(1);
    const third = sessions.rowCenterForTesting(2);
    assert(second.y - first.y == rowHeight + span,
        "a day boundary should add the heading span, was " ~
            to!string(second.y - first.y));
    assert(third.y - second.y == rowHeight + span,
        "every day boundary should add the heading span, was " ~
            to!string(third.y - second.y));

    // The heading slot is not a row: a click there selects nothing, while the
    // rows on either side still resolve.
    const origin = sessions.localToGlobal(Point(0, 0));
    const headingY = second.y - origin.y - rowHeight / 2 - 1;
    assert(sessions.indexAt(Point(20, headingY)) == -1,
        "the day heading slot must not resolve to a conversation row");
    assert(sessions.indexAt(Point(20, second.y - origin.y)) == 1,
        "the row under a day heading must still resolve");
    assert(sessions.indexAt(Point(20, first.y - origin.y)) == 0,
        "the first row of a day must still resolve");

    // Rows on the same day share one heading and keep the plain row pitch.
    root.setSessionUpdatedAtForTesting(0, today);
    root.setSessionUpdatedAtForTesting(2, today);
    root.refreshSessionListForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "paint after same-day refresh failed");
    assert(root.sessionDaySeparatorsForTesting() == "0=Today",
        "a single day should show one heading, was " ~
            root.sessionDaySeparatorsForTesting());
    const sameFirst = sessions.rowCenterForTesting(0);
    const sameSecond = sessions.rowCenterForTesting(1);
    assert(sameSecond.y - sameFirst.y == rowHeight,
        "rows on the same day should keep the plain row pitch");

    // Moving one conversation to yesterday splits it into its own group.
    root.setSessionUpdatedAtForTesting(2, yesterday);
    root.refreshSessionListForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "paint after regrouping failed");
    assert(root.sessionDaySeparatorsForTesting() == "0=Today,2=Yesterday",
        "the new day group should open its own heading, was " ~
            root.sessionDaySeparatorsForTesting());
    const splitFirst = sessions.rowCenterForTesting(0);
    const splitSecond = sessions.rowCenterForTesting(1);
    const splitThird = sessions.rowCenterForTesting(2);
    assert(splitSecond.y - splitFirst.y == rowHeight,
        "the remaining today rows should stay on the plain pitch");
    assert(splitThird.y - splitSecond.y == rowHeight + span,
        "the yesterday heading should open room before its row");

    // Pinning a conversation must leave the pinned section and its divider
    // untouched: no day heading opens above the pinned group, and the day
    // headings start at the first unpinned row.
    assert(root.invokeSessionContextMenuItemForTesting(2, "Pin conversation"),
        "the conversation menu did not offer Pin conversation");
    root.tickTree(0.02);
    assert(root.sessionPinnedForTesting(2), "the conversation was not pinned");
    assert(root.sessionPinnedSeparatorRowForTesting() == 1,
        "the pinned divider should sit under the one pinned row");
    assert(root.sessionDaySeparatorsForTesting() == "1=Today",
        "day headings must start at the first unpinned row, was " ~
            root.sessionDaySeparatorsForTesting());

    writeln("PASS: the conversation list separates conversations by day");
    return 0;
}
