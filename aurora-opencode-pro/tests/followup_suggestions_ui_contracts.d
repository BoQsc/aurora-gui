module followup_suggestions_ui_contracts;

// Suggested follow-ups: 3-4 clickable next messages at the end of a settled
// chat, on by default behind an experimental Settings switch. No provider
// request is completed here: the queued job is dropped with its conversation.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import core.time : MonoTime, msecs, seconds;
import core.thread : Thread;
import std.conv : to;
import std.file : mkdirRecurse, tempDir;
import std.path : buildPath;
import std.string : indexOf;
import std.stdio : writeln;

int main()
{
    const directory = buildPath(tempDir(),
        "aurora-followup-suggestions-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(directory, "workspace");
    mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(directory);
    Settings settings;
    settings.baseUrl = "http://127.0.0.1:9/v1";
    settings.apiKey = "fixture";
    settings.model = "followup-suggestion-fixture";
    settings.workspace = workspace;
    settings.quickTitle = false;
    settings.composerSuggestion = true;
    // Deliberately leave experimentalFollowUpSuggestions at its default.
    assert(settings.experimentalFollowUpSuggestions,
        "suggested follow-ups must default to on");
    saveSettings(settings);

    WindowOptions options;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope (exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);

    const startup = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < startup)
    {
        window.onNativeTick(0.02);
        root.projectTranscriptForTesting();
        assert(driver.paint(), "startup paint failed");
        Thread.sleep(1.msecs);
    }

    // The Settings switch exists and is on by default.
    auto followUpsSwitch = root.followUpsCheckboxForTesting();
    assert(followUpsSwitch !is null,
        "the suggested follow-ups setting is missing");
    assert(followUpsSwitch.checked(),
        "suggested follow-ups are not on by default");
    root.dismissPopupForTesting();

    // A settled conversation paints three chips at the end of the transcript.
    root.newChatForTesting();
    root.tickTree(0.02);
    root.addConversationForTesting(["user", "assistant"],
        ["Add a stop button", "The stop button is in place."]);
    root.setInputForTesting("");
    root.offerFollowUpsForTesting([
        "Run the tests and fix the failures",
        "Add a regression test for the stop button",
        "Explain the stop path's trade-off"]);
    root.tickTree(0.02);
    root.projectTranscriptForTesting();
    assert(driver.paint(), "the follow-up chips could not paint");
    const chips = root.followUpChipBoundsForTesting();
    assert(chips.length == 3,
        "expected three clickable follow-ups, got " ~ to!string(chips.length));
    foreach (chip; chips)
        assert(chip.width > 0 && chip.height > 0,
            "a follow-up chip has no clickable area");
    assert(chips[0].y < chips[1].y && chips[1].y < chips[2].y,
        "follow-up chips are not stacked in display order");
    const rows = root.messageColumnDumpForTesting();
    assert(rows.length > 0 &&
        rows[$ - 1].indexOf("FollowUpSuggestionsRow") >= 0,
        "the follow-up row is not at the end of the chat");
    assert(root.followUpsForTesting().length == 3,
        "the conversation lost its follow-up list");

    // Clicking with a draft keeps the draft and adds the chosen message.
    root.setInputForTesting("Keep this draft");
    assert(root.clickFollowUpForTesting(1), "the chip could not be pressed");
    const composed = root.inputTextForTesting();
    assert(composed.indexOf("Keep this draft") == 0,
        "the user's draft was lost: " ~ composed);
    assert(composed.indexOf("Add a regression test for the stop button") >= 0,
        "the chosen follow-up was not added: " ~ composed);

    // Turning the switch off removes the row and drops stored lists.
    // The dialog was dismissed above; its checkbox stays alive and still runs
    // the same change handler, exactly as a click in the open dialog would.
    followUpsSwitch.setChecked(false, true);
    root.tickTree(0.02);
    root.projectTranscriptForTesting();
    assert(driver.paint(), "the transcript could not repaint after disabling");
    assert(root.followUpChipBoundsForTesting().length == 0,
        "follow-up chips remained after the feature was disabled");
    assert(root.followUpsForTesting().length == 0,
        "stored follow-ups remained after the feature was disabled");

    // Re-enabling asks for the current settled reply again.
    followUpsSwitch.setChecked(true, true);
    root.tickTree(0.02);
    assert(root.followUpsPendingForTesting(),
        "re-enabling did not request follow-ups for the settled reply");

    // An unanswered conversation is never guessed at.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["An unanswered prompt"]);
    const int unanswered = cast(int) root.sessionCountForTesting() - 1;
    root.newChatForTesting();
    root.tickTree(0.02);
    root.selectSessionForTesting(unanswered);
    root.tickTree(0.02);
    assert(!root.followUpsPendingForTesting(),
        "an unanswered conversation requested follow-ups");

    // Opening an already-settled conversation starts its request too.
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"],
        ["Open the settled chat", "The settled chat is open."]);
    const int settled = cast(int) root.sessionCountForTesting() - 1;
    root.newChatForTesting();
    root.tickTree(0.02);
    root.selectSessionForTesting(settled);
    root.tickTree(0.02);
    assert(root.followUpsPendingForTesting(),
        "opening a settled conversation did not request follow-ups");

    writeln("PASS suggested follow-ups are on by default, render as " ~
        "clickable chips at the end of a settled chat, preserve a typed " ~
        "draft on click, disappear when disabled, and ask only for settled " ~
        "replies");
    window.close();
    return 0;
}
