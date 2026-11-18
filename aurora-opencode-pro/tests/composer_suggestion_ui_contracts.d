module composer_suggestion_ui_contracts;

// TAB in the composer: an offered guess is inserted, and an empty composer with
// no guess asks for one instead of typing spaces. While that request runs the
// composer shows its tiny three-dot pulse. No provider request is started here:
// the queued job is dropped with its conversation before the next tick.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import core.time : MonoTime, msecs, seconds;
import core.thread : Thread;
import std.file : mkdirRecurse, tempDir;
import std.path : buildPath;
import std.conv : to;
import std.stdio : writeln;

int main()
{
    const directory = buildPath(tempDir(),
        "aurora-composer-suggestion-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(directory, "workspace");
    mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(directory);
    Settings settings;
    settings.baseUrl = "http://127.0.0.1:9/v1";
    settings.apiKey = "fixture";
    settings.model = "composer-suggestion-fixture";
    settings.workspace = workspace;
    settings.quickTitle = false;
    settings.composerSuggestion = true;
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

    // Nothing anywhere to read means nothing to guess from: Tab keeps its
    // ordinary behaviour and no request is queued.
    root.newChatForTesting();
    root.tickTree(0.02);
    root.focusComposerForTesting();
    // With nothing anywhere to read the tiny trigger is not offered at all.
    assert(root.composerSuggestionButtonBoundsForTesting().width == 0,
        "the tiny suggestion trigger appeared with nothing to read");
    driver.pressKey(Key.tab);
    assert(!root.composerSuggestionPendingForTesting(),
        "Tab requested a guess with nothing anywhere to read");
    root.setInputForTesting("");

    // With a settled conversation and no offered guess, Tab asks for one.
    root.addConversationForTesting(["user", "assistant"],
        ["Investigate the failing build", "The cause is the stale binary."]);
    root.tickTree(0.02);
    assert(!root.composerSuggestionPendingForTesting(),
        "seeding a conversation must not queue a suggestion by itself");
    assert(driver.paint(), "the composer could not paint before asking");
    assert(root.composerSuggestionButtonBoundsForTesting().width > 0,
        "the tiny suggestion trigger did not appear beside Send");
    root.focusComposerForTesting();
    driver.pressKey(Key.tab);
    assert(root.composerSuggestionPendingForTesting(),
        "Tab with no suggestion did not request prompt generation");
    assert(root.composerSuggestionBusyForTesting(),
        "the composer's generation pulse did not start with the request");
    assert(root.inputTextForTesting().length == 0,
        "Tab typed into the composer instead of requesting a guess: " ~
        root.inputTextForTesting());
    root.projectTranscriptForTesting();
    assert(driver.paint(), "the composer's generation pulse did not paint");

    // Drop the pending job with its conversation before any tick can start it.
    root.newChatForTesting();
    root.tickTree(0.02);
    assert(!root.composerSuggestionBusyForTesting(),
        "the generation pulse outlived its conversation");

    // A guess belongs to the conversation it was offered in: creating another
    // chat must not carry it over, and returning to it restores it.
    root.offerComposerSuggestionForTesting("Run the tests again");
    assert(root.composerSuggestionForTesting() == "Run the tests again");
    root.newChatForTesting();
    root.tickTree(0.02);
    assert(root.composerSuggestionForTesting().length == 0,
        "a new chat inherited the previous conversation's suggestion: " ~
        root.composerSuggestionForTesting());
    root.selectSessionForTesting(1);
    root.tickTree(0.02);
    assert(root.composerSuggestionForTesting() == "Run the tests again",
        "the conversation's own suggestion was not restored: " ~
        root.composerSuggestionForTesting());
    root.selectSessionForTesting(2);
    root.tickTree(0.02);
    assert(root.composerSuggestionForTesting().length == 0,
        "another conversation still shows this suggestion: " ~
        root.composerSuggestionForTesting());

    // Back in the conversation that owns the guess, Tab still accepts it.
    root.selectSessionForTesting(1);
    root.tickTree(0.02);
    root.focusComposerForTesting();
    driver.pressKey(Key.tab);
    assert(root.inputTextForTesting() == "Run the tests again",
        "Tab no longer accepts an offered suggestion: " ~
        root.inputTextForTesting());
    assert(root.composerSuggestionForTesting().length == 0,
        "accepting a suggestion should clear it");

    // A reply that settles while another conversation is open still earns its
    // automatic guess: coming back makes it now instead of losing it.
    root.setInputForTesting("");
    root.addConversationForTesting(["user", "assistant"],
        ["Add a stop button", "The stop button is in place."]);
    root.newChatForTesting();
    root.tickTree(0.02);
    root.finishStreamInSessionForTesting(1);
    root.selectSessionForTesting(1);
    root.tickTree(0.02);
    assert(root.composerSuggestionPendingForTesting(),
        "returning to a conversation that settled in the background " ~
        "did not request a guess");

    // A guess already requested must survive a switch away before it starts.
    root.newChatForTesting();
    root.tickTree(0.02);
    const int guessIndex = cast(int) root.sessionCountForTesting() - 1;
    root.focusComposerForTesting();
    driver.pressKey(Key.tab);
    assert(root.composerSuggestionPendingForTesting(),
        "Tab did not request a guess in the new chat");
    root.selectSessionForTesting(0);
    root.tickTree(0.02);
    root.selectSessionForTesting(guessIndex);
    root.tickTree(0.02);
    assert(root.composerSuggestionPendingForTesting(),
        "a queued guess was dropped when its conversation was left");

    // Opening an already-settled conversation starts its guess too: its reply
    // may have settled in an earlier run, so no job exists yet.
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"],
        ["Open the settled chat", "The settled chat is open."]);
    const int settledOpen = cast(int) root.sessionCountForTesting() - 1;
    root.newChatForTesting();
    root.tickTree(0.02);
    root.selectSessionForTesting(settledOpen);
    root.tickTree(0.02);
    assert(root.composerSuggestionPendingForTesting(),
        "opening a settled conversation did not request its guess");

    // A conversation whose last message is from the user is not settled and
    // must not be guessed at.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["An unanswered prompt"]);
    const int unanswered = cast(int) root.sessionCountForTesting() - 1;
    root.newChatForTesting();
    root.tickTree(0.02);
    root.selectSessionForTesting(unanswered);
    root.tickTree(0.02);
    assert(!root.composerSuggestionPendingForTesting(),
        "an unanswered conversation requested a guess");

    // A conversation whose history loads only when it is opened must get its
    // guess after the transcript arrives, not before it.
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"],
        ["Load the lazy history", "The lazy history is here."]);
    const int lazyTarget = cast(int) root.sessionCountForTesting() - 1;
    const string lazyId = root.sessionIdForTesting(lazyTarget);
    root.newChatForTesting();
    root.tickTree(0.02);
    root.persistForTesting();
    root.reloadSessionsForTesting();
    int lazyIndex = -1;
    foreach (i; 0 .. root.sessionCountForTesting())
        if (root.sessionIdForTesting(cast(int) i) == lazyId) { lazyIndex = cast(int) i; break; }
    assert(lazyIndex >= 0, "the reloaded conversation is missing");
    root.selectSessionForTesting(lazyIndex);
    const loadDeadline = MonoTime.currTime + 5.seconds;
    while (root.historyPendingForTesting() && MonoTime.currTime < loadDeadline)
    {
        window.onNativeTick(0.02);
        root.projectTranscriptForTesting();
        assert(driver.paint(), "a lazy history load could not paint");
        Thread.sleep(1.msecs);
    }
    assert(!root.historyPendingForTesting(), "lazy history did not load");
    assert(root.messageCountForTesting() > 0,
        "the lazily loaded conversation has no transcript");
    assert(root.composerSuggestionPendingForTesting(),
        "a lazily loaded settled conversation did not request its guess");

    // A new chat has no turns of its own, but Tab may read a bounded digest of
    // recent conversations. One small request, and only when asked.
    root.newChatForTesting();
    root.tickTree(0.02);
    root.focusComposerForTesting();
    driver.pressKey(Key.tab);
    assert(root.composerSuggestionPendingForTesting(),
        "Tab in a new chat did not fall back to recent conversations");
    assert(root.composerSuggestionBusyForTesting(),
        "the new chat's generation pulse did not start");

    // The very small trigger beside Send asks for the same guess with the
    // mouse. It is only a 16 px target, so it never competes with Send.
    root.newChatForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "the composer could not paint before the click");
    const trigger = root.composerSuggestionButtonBoundsForTesting();
    assert(trigger.width > 0 && trigger.height > 0,
        "the tiny suggestion trigger is missing");
    assert(trigger.width <= 20 && trigger.height <= 20,
        "the suggestion trigger is not very small: " ~ trigger.width.to!string ~
        "x" ~ trigger.height.to!string);
    assert(root.composerSuggestionButtonEnabledForTesting(),
        "the tiny suggestion trigger is not clickable");
    driver.click(Point(trigger.x + trigger.width / 2,
        trigger.y + trigger.height / 2));
    assert(root.composerSuggestionPendingForTesting(),
        "clicking the tiny suggestion trigger did not request a guess");
    assert(root.composerSuggestionBusyForTesting(),
        "the click did not start the generation pulse");
    assert(root.inputTextForTesting().length == 0,
        "the click typed into the composer");

    writeln("PASS Tab requests a composer guess when none is offered, " ~
        "falls back to recent conversations in a new chat, shows the pulse " ~
        "while it runs, still accepts a guess, and a very small trigger " ~
        "button asks with the mouse");
    window.close();
    return 0;
}
