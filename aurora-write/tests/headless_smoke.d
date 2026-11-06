module aurora_write_smoke;

import aurora;
import aurorawrite.llmclient : parseRefinement;
import aurorawrite.settings : loadSettings, WriteSettings;
import aurorawrite.suggestioncard : SuggestionCard;
import aurorawrite.theme : writeTheme;
import aurorawrite.writeroot : WriteRoot, WritingSurface;
import core.thread : Thread;
import core.time : msecs;
import std.file : write;
import std.conv : to;
import std.path : buildPath;
import std.process : environment;
import std.string : indexOf;
import std.stdio : writeln;
import std.utf : toUTF32;

private int failures;
private int checks;

/// One production frame: the native loop ticks widgets, then paints.
private bool frame(GuiWindow window, UiTestDriver driver, ref double delta)
{
    window.onNativeTick(delta);
    delta = 1.0 / 60.0;
    return driver.paint();
}

private void check(bool condition, string what)
{
    ++checks;
    if (condition) return;
    ++failures;
    writeln("FAIL: ", what);
}

private int run()
{
    WindowOptions options;
    options.title = "Aurora Write";
    options.width = 1120;
    options.height = 760;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, writeTheme(false));
    auto root = new WriteRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    check(driver.paint(), "initial paint");

    auto editor = root.editor();
    auto card = root.card();
    check(editor !is null && card !is null, "editor and card exist");
    check(editor.focused(), "the editor owns the caret at startup");
    check(card !is null && !card.open(), "no card before anything is typed");

    // --- The instant pass answers on the keystroke ---------------------
    driver.text("We utilize".toUTF32);
    check(driver.paint(), "paint after typing");
    check(editor.textUtf8() == "We utilize", "typed text landed: " ~
        editor.textUtf8());
    check(root.analysis.target == "utilize", "target resolved: " ~
        root.analysis.target);
    check(root.analysis.definition == "To put something to practical use.",
        "one-sentence definition: " ~ root.analysis.definition);
    check(card.open(), "card opened with the instant analysis");
    check(card.choiceCount() >= 4, "instant shortlist has several choices");
    check(card.choiceCount() <= 8, "shortlist stays inside eight choices");
    check(root.statusLeftText().length > 0, "status line reports the document");

    // On the first line there is no room above, so the card flips below the
    // caret line instead of covering the word being typed.
    const caret = editor.caretRect();
    check(caret.y >= 0 && caret.y + caret.height <= editor.bounds().height,
        "caret rect lies inside the editor");
    const cardRect = card.bounds();
    const caretTop = editor.bounds().y + caret.y;
    check(card.open() && cardRect.y >= caretTop + caret.height,
        "card flips below the caret when the top of the page leaves no room");
    check(card.open() && cardRect.x >= 0 &&
        cardRect.x + cardRect.width <= options.width,
        "card is clamped inside the window horizontally");

    // With the caret lower on the page the card really does sit above the words.
    editor.setText("One line here.\n\nAnother line here.\n\nA third line here." ~
        "\n\nWe demonstrate the point clearly.", false);
    const demonstrateAt = editor.textUtf8().indexOf("demonstrate");
    editor.setCursorIndex(cast(size_t) demonstrateAt + 3);
    root.refreshSuggestions();
    check(driver.paint(), "paint with the caret lower on the page");
    check(card.open(), "card opens for a word on a later line");
    const lowCaret = editor.caretRect();
    const lowCaretTop = editor.bounds().y + lowCaret.y;
    const lowCard = card.bounds();
    check(lowCard.y + lowCard.height <= lowCaretTop,
        "card sits above the caret line (card bottom " ~
        (lowCard.y + lowCard.height).to!string ~ ", caret top " ~
        lowCaretTop.to!string ~ ")");
    check(lowCard.x + lowCard.width <= card.parent.bounds().width,
        "card stays inside the window on a later line");

    // A scrolled document keeps reporting a caret inside the field, which is
    // exactly the geometry an application-side copy of the caret math loses.
    string longDocument;
    foreach (line; 0 .. 40) longDocument ~= "A line of prose here.\n\n";
    longDocument ~= "We utilize it.";
    editor.setText(longDocument, false);
    // "We utilize it." is the last 14 units, so len-11 is inside "utilize".
    editor.setCursorIndex(longDocument.length - 11);
    root.refreshSuggestions();
    check(driver.paint(), "paint with a scrolled document");
    check(root.analysis.target == "utilize", "scrolled target: " ~
        root.analysis.target);
    const scrolled = editor.caretRect();
    check(scrolled.y >= 0 &&
        scrolled.y + scrolled.height <= editor.bounds().height,
        "scrolled caret stays inside the field");
    const scrolledCard = card.bounds();
    check(card.open() && scrolledCard.y + scrolledCard.height <=
        editor.bounds().y + scrolled.y,
        "card anchors above a scrolled caret too");

    editor.setText("We utilize", false);
    editor.setCursorIndex(editor.textUtf8().length);
    root.refreshSuggestions();

    // --- Keyboard shortlist: Tab cycles, Ctrl+Enter applies ------------
    const beforeTab = editor.textUtf8();
    driver.pressKey(Key.tab);
    check(card.selected() == 0, "Tab selects the first choice");
    check(editor.textUtf8() == beforeTab, "Tab never inserts into the document");
    driver.pressKey(Key.tab);
    check(card.selected() == 1, "Tab advances the selection");
    driver.pressKey(Key.tab, cast(uint) KeyModifier.shift);
    check(card.selected() == 0, "Shift+Tab goes back");

    driver.pressKey(Key.enter, cast(uint) KeyModifier.control);
    check(editor.textUtf8() == "We use", "Ctrl+Enter applies the choice: " ~
        editor.textUtf8());
    check(!card.open(), "the card closes after applying");

    // The replacement is one plain undo step.
    editor.undo();
    check(editor.textUtf8() == "We utilize", "undo restores the original: " ~
        editor.textUtf8());

    // Finishing a word with a space must keep the suggestion. This was the bug
    // that hid suggestions during ordinary prose: the span search found nothing
    // once the caret sat after the trailing space.
    editor.setText("", false);
    driver.text("We utilize ".toUTF32);
    check(driver.paint(), "paint after a word plus its space");
    check(root.analysis.target == "utilize", "word before a single space: " ~
        root.analysis.target);
    check(card.open(), "card stays open while the finished word is current");
    driver.text(" ".toUTF32);
    check(driver.paint(), "paint after the second space");
    check(!card.open(), "card closes once the writer moves on");

    // --- A wordy phrase spans the whole phrase and saves words ---------
    editor.setText("", false);
    driver.text("It failed due to the fact that".toUTF32);
    check(driver.paint(), "paint after typing the phrase");
    check(root.analysis.target == "due to the fact that", "phrase span: " ~
        root.analysis.target);
    check(card.open(), "phrase finding opens the card");
    check(card.choice(0) !is null && card.choice(0).text == "because",
        "phrase offers one-word rewrites");
    driver.pressKey(Key.enter, cast(uint) KeyModifier.control);
    check(editor.textUtf8() == "It failed because", "phrase applied: " ~
        editor.textUtf8());
    check(root.savedWords() == 4, "four words saved: " ~
        root.savedWords().to!string);

    // --- A plain word never opens the card -----------------------------
    editor.setText("", false);
    driver.text("We calibrate the rig.".toUTF32);
    editor.setCursorIndex(7); // inside "calibrate"
    root.refreshSuggestions();
    check(driver.paint(), "paint after a plain word");
    check(!card.open(), "no card for a word with no local rewrite");
    check(root.analysis.target == "calibrate", "span still reported for the model");

    // --- Shortcuts -------------------------------------------------------
    const thinkingBefore = root.settings().thinking;
    driver.pressKey(Key.t, cast(uint) KeyModifier.control);
    check(root.settings().thinking != thinkingBefore, "Ctrl+T toggles thinking");
    driver.pressKey(Key.t, cast(uint) KeyModifier.control);

    // --- Settings ---------------------------------------------------------
    auto settings = loadSettings();
    check(settings.model.length >= 0, "settings load without throwing");
    check(environment.get("AURORA_WRITE_OFFLINE", "") == "1",
        "smoke test runs with the network disabled");
    check(root.settings().offline, "offline switch reaches the root");

    // --- The card cannot steal typing focus -----------------------------
    editor.setText("", false);
    driver.text("We demonstrate".toUTF32);
    check(driver.paint(), "paint before the click test");
    check(card.open(), "card open for a click test");
    check(!card.focusable(), "card is not focusable");
    // A click on a chip applies that chip without moving keyboard focus.
    const chip = card.chipRect(0);
    const chipPoint = Point(card.bounds().x + chip.x + chip.width / 2,
        card.bounds().y + chip.y + chip.height / 2);
    driver.click(chipPoint);
    check(editor.focused(), "editor keeps focus after clicking a chip");
    check(editor.textUtf8() != "We demonstrate", "chip click applies a rewrite: " ~
        editor.textUtf8());

    // --- A model answer in the card's shape -----------------------------
    auto refined = parseRefinement(
        "{\"definition\":\"To show something clearly.\",\"choices\":[" ~
        "{\"text\":\"show\",\"gloss\":\"Plain verb.\"}," ~
        "{\"text\":\"demonstrate\",\"gloss\":\"itself\"}]}", "demonstrate");
    check(refined.ok, "model answer parsed");
    check(refined.choices.length == 1, "the target itself is dropped from a reply");
    check(refined.choices[0].refined, "model choices are marked refined");

    window.close();
    checkLiveWiring(options);
    return failures == 0 ? 0 : 1;
}

/// The debounce -> worker -> apply wiring, end to end, against a closed port.
///
/// A dead endpoint must leave the instant choices alone and put the failure in
/// the card's status instead of hanging the editor or clearing the shortlist.
private void checkLiveWiring(WindowOptions baseOptions)
{
    const settingsFile = buildPath(environment.get("TEMP", "."),
        "aurora-write-smoke-live.json");
    write(settingsFile, "{\"baseUrl\":\"http://127.0.0.1:9/v1\"," ~
        "\"model\":\"smoke\",\"apiKey\":\"\",\"thinking\":false," ~
        "\"optimizer\":true,\"offline\":false}");
    environment["AURORA_WRITE_OFFLINE"] = "";
    environment["AURORA_WRITE_SETTINGS"] = settingsFile;

    auto options = baseOptions;
    auto window = new GuiWindow(options, writeTheme(false));
    auto root = new WriteRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    double delta = 1.0 / 60.0;
    check(frame(window, driver, delta), "live: initial paint");
    root.editor().requestFocus();
    check(root.settings().configured() && !root.settings().offline,
        "live: test settings name a provider and are online");

    driver.text("We utilize".toUTF32);
    check(frame(window, driver, delta), "live: paint after typing");
    check(root.cardOpen(), "live: instant card shows before any model reply");
    const instantChoices = root.card().choiceCount();

    // Frames must be driven through onNativeTick: `UiTestDriver.paint()` alone
    // never ticks widgets, so an earlier version of this check passed without
    // a request ever starting. Require seeing the pending state first.
    bool sawRefining;
    bool settled;
    foreach (attempt; 0 .. 120)
    {
        frame(window, driver, delta);
        const status = root.card().status();
        if (root.statusRightText().indexOf("refining") >= 0 ||
            status == "refining…")
            sawRefining = true;
        if (sawRefining && status.length > 0 && status != "refining…")
        {
            settled = true;
            break;
        }
        Thread.sleep(20.msecs);
    }
    check(sawRefining, "live: the provider request actually started");
    check(settled, "live: refinement settled instead of hanging on refining…");
    check(root.card().status() != "refining…", "live: card left the refining state");
    check(root.card().choiceCount() == instantChoices,
        "live: instant choices survive a failed refinement");
    check(root.cardOpen(), "live: card stays open after a failed refinement");
    check(root.editor().textUtf8() == "We utilize",
        "live: a failed refinement never edits the document");
    window.close();
}

int main()
{
    // No provider traffic from the smoke test: the live path is probed
    // separately, on purpose, by `--probe-llm`.
    environment["AURORA_WRITE_OFFLINE"] = "1";
    // Never touch the writer's real settings: the shortcut checks persist.
    environment["AURORA_WRITE_SETTINGS"] = buildPath(
        environment.get("TEMP", "."), "aurora-write-smoke-settings.json");
    try
    {
        const code = run();
        writeln(failures == 0
            ? "ALL PASSED — " ~ checks.to!string ~ " checks"
            : failures.to!string ~ " of " ~ checks.to!string ~ " checks failed");
        return code;
    }
    catch (Throwable error)
    {
        writeln("EXCEPTION: ", error.msg);
        return 2;
    }
}
