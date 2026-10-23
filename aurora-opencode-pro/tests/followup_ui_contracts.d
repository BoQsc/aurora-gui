module followup_ui_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import auroraopencode.followupsection;
import auroraopencode.taskcontinuation : taskContinuationMarker;
import auroraopencode.completionhandoff : completionHandoffMarker;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.datetime : Clock;
import std.conv : to;
import std.file : mkdirRecurse, tempDir;
import std.path : buildPath, absolutePath;
import std.string : indexOf;
import std.stdio : writeln;

private Widget find(Widget root, string id)
{
    if (root.id() == id) return root;
    foreach (child; root.children()) if (auto found = find(child, id)) return found;
    return null;
}
private bool exposed(Widget row)
{
    for (auto p = row; p !is null; p = p.parent()) if (!p.visible()) return false;
    return row !is null;
}

int main()
{
    ChatSession model;
    void add(string role, string text, bool internal = false)
    {
        ChatMessage m; m.id = newMessageId(); m.parentId = model.activeLeafId;
        m.role = role; m.content = text; m.internal = internal;
        model.messages ~= m; model.activeLeafId = m.id;
    }
    add("user", "Implement the requested change");
    add("assistant", "Delivered the change");
    add("user", taskContinuationMarker, true);
    model.messages[$-1].id = "m" ~ to!string(Clock.currTime.stdTime - 65 * 10_000_000L) ~ "-first";
    model.activeLeafId = model.messages[$-1].id;
    add("assistant", "Checking the result");
    add("user", completionHandoffMarker, true);
    add("assistant", "Final result");
    auto ranges = followUpRanges(model, activeMessagePath(model), true);
    assert(ranges.length == 1 && ranges[0].work && ranges[0].live && ranges[0].elapsedSeconds >= 65);
    auto timed = new AutomaticFollowUpSection(); timed.update(null, ranges[0]);
    assert(timed.label.indexOf("1m 5s") >= 0, timed.label);
    assert(ranges[0].finalAnswerIndex == 5);
    assert(freezeFollowUpTimers(model).length == 1);
    const frozen = model.messages[2].workedSeconds;
    assert(frozen >= 65 && !freezeFollowUpTimers(model).length);
    add("user", "A separate task");
    ranges = followUpRanges(model, activeMessagePath(model), true);
    assert(!ranges[0].live && ranges[0].endSlot == 6 && ranges[0].elapsedSeconds == frozen);
    model.activeLeafId = model.messages[1].id;
    assert(!followUpRanges(model, activeMessagePath(model), false).length, "Other branch leaked a follow-up");

    const state = absolutePath(buildPath(tempDir(), "aurora-follow-up-" ~ to!string(MonoTime.currTime.ticks)));
    mkdirRecurse(state); setOpencodeStateDirectoryForTesting(state);
    Settings settings; settings.baseUrl = "http://127.0.0.1:1/v1"; settings.apiKey = "fixture";
    settings.workspace = state; settings.toolsEnabled = false; settings.quickTitle = false;
    assert(!settings.experimentalFollowUpDivider, "Experimental follow-up UI must be off by default");
    saveSettings(settings);
    assert(!loadSettings().experimentalFollowUpDivider);
    WindowOptions options; options.width = 1100; options.height = 820;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) { root.shutdownClient(); window.close(); }
    auto driver = new UiTestDriver(window);
    void paint()
    {
        foreach (_; 0 .. 4) { root.tickTree(0.02); assert(driver.paint()); }
    }
    foreach (_; 0 .. 30) { root.tickTree(0.02); driver.paint(); Thread.sleep(10.msecs); }
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"], ["Make the change", "The requested change is ready."]);
    root.startTurnClockForTesting();
    root.appendAutomaticFollowUpForTesting(false);
    root.appendToolRequestTurnForTesting("Checking results", "read-extra", "read", `{"filePath":"out.txt"}`, "I will check the result once more.");
    root.appendOwnedToolResultForTesting("read-extra", "read", "Unique extra review receipt", `{"filePath":"out.txt"}`, 0, 0, "");
    root.beginStreamForTesting(); root.streamContentForTesting("The final result is ready. Checks are recorded above.");
    paint();
    assert(find(root, "oc-automatic-follow-up") is null, "Disabled divider still appeared");
    const beforeEnable = root.messageCountForTesting();
    auto option = root.automaticFollowUpCheckboxForTesting();
    assert(option !is null && !option.checked());
    root.toggleSettingsSectionForTesting("oc-settings-options"); paint();
    window.saveScreenshot("build/follow-up-option.ppm");
    option.setChecked(true); root.flushSettingsForTesting();
    assert(loadSettings().experimentalFollowUpDivider, "Enabled option was not saved");
    root.dismissPopupForTesting(); paint();
    assert(root.messageCountForTesting() == beforeEnable, "UI toggle changed conversation history");
    auto section = cast(AutomaticFollowUpSection) find(root, "oc-automatic-follow-up");
    assert(section !is null && section.collapsed());
    assert(section.notice.indexOf("may improve") >= 0 && section.label.indexOf("Running") >= 0);
    assert(section.children().length > 0);
    assert(root.followUpAnswerVisibleForTesting());
    foreach (row; section.children()) assert(!row.visible());
    window.saveScreenshot("build/follow-up-collapsed.ppm");
    const beforeTick = section.label;
    Thread.sleep(1100.msecs); paint();
    assert(section.label != beforeTick, "Live elapsed timer did not advance");
    Event click; click.button = MouseButton.left; click.position = Point(20, 20);
    assert(section.onMouseDown(click)); paint();
    assert(!section.collapsed());
    bool shown; foreach (row; section.children()) shown |= exposed(row);
    assert(shown);
    root.rebuildForTesting(); paint();
    assert(find(root, "oc-automatic-follow-up") is section && !section.collapsed());
    window.saveScreenshot("build/follow-up-expanded.ppm");
    Event key; key.key = Key.space; assert(section.onKeyDown(key)); paint();
    assert(section.collapsed());
    root.setChatSearchQueryForTesting("Unique extra review receipt"); paint();
    assert(root.chatSearchMatchCountForTesting() == 1 && !section.collapsed());
    root.setChatSearchQueryForTesting("");
    section.setCollapsed(true); root.finishStreamForTesting(); paint();
    assert(section.label.indexOf("Finished") >= 0, section.label);
    const finalLabel = section.label;
    assert(root.lastAssistantContentForTesting().indexOf("The final result") == 0);
    assert(root.followUpAnswerVisibleForTesting());
    const count = root.messageCountForTesting();
    root.persistForTesting(); root.reloadSessionsForTesting();
    foreach (_; 0 .. 30) { root.tickTree(0.02); driver.paint(); Thread.sleep(10.msecs); }
    section = cast(AutomaticFollowUpSection) find(root, "oc-automatic-follow-up");
    assert(section !is null && section.label == finalLabel, "Reload changed the settled elapsed time");
    assert(root.messageCountForTesting() == count && root.lastAssistantContentForTesting().indexOf("The final result") == 0);
    option = root.automaticFollowUpCheckboxForTesting(); assert(option.checked());
    option.setChecked(false); root.flushSettingsForTesting(); root.dismissPopupForTesting(); paint();
    assert(!loadSettings().experimentalFollowUpDivider && find(root, "oc-automatic-follow-up") is null);
    assert(root.messageCountForTesting() == count && root.followUpAnswerVisibleForTesting());
    option = root.automaticFollowUpCheckboxForTesting();
    option.setChecked(true); root.flushSettingsForTesting(); root.dismissPopupForTesting(); paint();
    assert(find(root, "oc-automatic-follow-up") !is null, "Re-enabling lost existing follow-up sections");
    root.addConversationForTesting(["user", "assistant"], ["A new question", "An ordinary answer"]); paint();
    assert(root.lastAssistantContentForTesting() == "An ordinary answer");

    foreach (redesign; [false, true])
    {
        root.newChatForTesting(); root.setExperimentalChatRedesignForTesting(redesign);
        root.addConversationForTesting(["user", "assistant"], ["Write the result", "The result is ready"]);
        root.startTurnClockForTesting(); root.appendAutomaticFollowUpForTesting(true);
        root.beginStreamForTesting(); root.streamContentForTesting("Result: Ready. Checks: recorded. Remaining: none.");
        root.finishStreamForTesting(); paint();
        auto summary = cast(AutomaticFollowUpSection) find(root, "oc-automatic-follow-up");
        assert(summary !is null && summary.collapsed() && summary.label.indexOf("Additional summary") >= 0);
        assert(root.lastAssistantContentForTesting().indexOf("Result: Ready") == 0);
        assert(root.followUpAnswerVisibleForTesting());
    }
    root.newChatForTesting(); root.setExperimentalChatRedesignForTesting(false);
    root.addConversationForTesting(["user", "assistant"], ["Keep the result", "The requested result is ready"]);
    root.startTurnClockForTesting(); root.appendAutomaticFollowUpForTesting();
    root.appendToolRequestTurnForTesting("Check once more", "failed-check", "run", `{"program":"python"}`, "Checking results");
    root.appendOwnedToolResultForTesting("failed-check", "run", "Check failed visibly", `{"program":"python"}`, 0, 0, "", 5, true);
    root.beginStreamForTesting(); root.streamContentForTesting("One check failed; the result is preserved.");
    paint(); root.stopActiveTurnForTesting(); paint();
    section = cast(AutomaticFollowUpSection) find(root, "oc-automatic-follow-up");
    assert(section !is null && section.label.indexOf("Stopped") >= 0, section.label);
    assert(root.followUpAnswerVisibleForTesting());
    const stopped = section.label; Thread.sleep(1100.msecs); paint();
    assert(section.label == stopped, "Stop left the section clock running");
    assert(root.messageCountForTesting() > 4);
    root.addConversationForTesting(["user", "assistant"], ["Another question", "An ordinary answer"]); paint();
    assert(section.label == stopped, "A later request erased the stopped state");

    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"], ["Long follow-up", "Requested result ready"]);
    root.appendAutomaticFollowUpForTesting();
    string[] roles, texts;
    foreach (i; 0 .. 155) { roles ~= "assistant"; texts ~= "Additional review note " ~ to!string(i); }
    root.addConversationForTesting(roles, texts); paint();
    assert(root.hiddenHistoryCountForTesting() > 0);
    section = cast(AutomaticFollowUpSection) find(root, "oc-automatic-follow-up");
    assert(section !is null && section.collapsed(), "Paging dropped the automatic follow-up boundary");
    assert(root.followUpAnswerVisibleForTesting());
    writeln("PASS experimental option defaults off, actual Settings toggle persists and applies immediately without changing history; divider, timer, search, reload and both layouts");
    return 0;
}
