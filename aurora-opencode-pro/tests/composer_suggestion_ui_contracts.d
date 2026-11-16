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

    writeln("PASS Tab requests a composer guess when none is offered, " ~
        "falls back to recent conversations in a new chat, shows the pulse " ~
        "while it runs, and still accepts a guess");
    window.close();
    return 0;
}
