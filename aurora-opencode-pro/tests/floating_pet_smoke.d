module floating_pet_smoke;

// Headless smoke for the experimental floating pet (source/auroraopencode/pet.d).
//
// Constructs the real OpenCodeRoot, drives the same switch the Settings
// checkbox drives, and asserts the two things that matter for a suggestion-only
// feature:
//   1. OFF (the default): the pet is dormant - no overlay host, no proposal.
//   2. ON: the switch starts the host, and the pet surfaces exactly one
//      approval-seeking suggestion (never an action).
// Runs against the software renderer, like the other *_smoke tests.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : loadSettings, saveSettings,
    setOpencodeStateDirectoryForTesting, opencodeTheme;
import auroraopencode.pet : PetHost, PetMood, PetScene, PetScreenWatch,
    petBubbleLine, petIdleLine, petNote, petNoteLineLimit, petNotesPath,
    petSceneDigest, sampleForegroundScene;
import aurora.types : Point, Rect;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, remove, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf, splitLines;


final class FakeScene
{
    PetScene scene;
}

int main()
{
    const state = buildPath(tempDir(), "aurora-floating-pet-smoke");
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    // Same minimal fixture the other smoke tests use. Crucially it must NOT
    // mention the pet switch, so the default (off) is what we exercise.
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:1/v1","apiKey":"fixture","model":"fixture","toolsEnabled":false}`);

    WindowOptions options;
    options.width = 1000;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    root.isolateClipboardForTesting(true);

    foreach (_; 0 .. 30) root.tickTree(0.02);

    // 1. Dormant by default.
    assert(!root.floatingPetEnabledForTesting(),
        "The pet must be absent until the user opts in");
    assert(root.petProposalTextForTesting().length == 0,
        "A dormant pet must never propose anything");
    writeln("PASS floating pet is dormant and silent while disabled");

    // 2. Opt in through the same path the checkbox uses.
    root.setFloatingPetForTesting(true);
    assert(root.floatingPetEnabledForTesting(),
        "Enabling the switch must start the pet overlay host");
    foreach (_; 0 .. 10) root.tickTree(0.02);
    const proposal = root.petProposalTextForTesting();
    assert(proposal.length > 0, "An enabled pet should surface a suggestion");
    assert(proposal.indexOf("Want me to") >= 0,
        "The suggestion must ask the user rather than act");
    writeln("PASS enabling the pet starts it and yields an approval-seeking suggestion");

    // 2b. The purpose: repeated tool failures must raise an offer to retry.
    // Two identical failures is the threshold; the pet reads only the count the
    // app already tracks, never the command or its output.
    const failureProposal = root.petFailureProposalForTesting(2);
    assert(failureProposal.indexOf("2 failed") >= 0,
        "A repeated failure should be surfaced, got: " ~ failureProposal);
    assert(failureProposal.indexOf("retry") >= 0,
        "The failure suggestion must offer a retry, got: " ~ failureProposal);
    assert(failureProposal.indexOf("Want me to") >= 0,
        "The retry offer must ask rather than announce, got: " ~ failureProposal);
    writeln("PASS repeated tool failures raise an approval-seeking retry offer");

    // 2c. The Settings toggle must persist. The checkbox writes
    // `experimentalFloatingPet`; assert the value survives save/load, so a
    // relaunch honours the user's choice rather than silently resetting to off.
    auto persisted = loadSettings();
    persisted.experimentalFloatingPet = true;
    saveSettings(persisted);
    assert(loadSettings().experimentalFloatingPet,
        "An enabled floating pet must survive a settings round-trip");
    persisted.experimentalFloatingPet = false;
    saveSettings(persisted);
    assert(!loadSettings().experimentalFloatingPet,
        "A disabled floating pet must persist as off");
    writeln("PASS the floating pet setting round-trips through settings.json");

    // 2d. A request typed into the overlay reaches the UI thread exactly once,
    // through the same submitOverlayPrompt path the main composer uses.
    root.petPromptForTesting("open notepad and type hi");
    assert(root.petTakePromptForTesting() == "open notepad and type hi",
        "a typed pet request must reach the UI thread intact");
    assert(root.petTakePromptForTesting().length == 0,
        "a typed pet request must be delivered exactly once");
    writeln("PASS a typed pet request reaches the UI thread exactly once");

    // 2d2. The companion writes in its own conversation and its own project,
    // never in the chat or project the reader happens to have open.
    const companionTitle = root.petCompanionSessionForTesting();
    assert(companionTitle == "Companion",
        "the companion needs its own conversation, got: " ~ companionTitle);
    const companionProject = root.petCompanionProjectForTesting();
    assert(companionProject.length > 0 && exists(companionProject),
        "the companion project folder must exist, got: " ~ companionProject);
    assert(companionProject.indexOf(buildPath("pet", "project")) >= 0,
        "the companion project must live under the pet state folder, got: " ~
        companionProject);
    assert(root.petCompanionSessionForTesting() == "Companion",
        "the companion conversation must be reused, not recreated");
    writeln("PASS the companion has its own conversation and project");

    // 2e. The bubble mirrors the conversation the pet was asked in: the user's
    // line first, then the reply, and the idle line when there is nothing yet.
    if (root.sessionCountForTesting() == 0) root.forceNewChatForTesting();
    root.tickTree(0.02);
    assert(root.sessionCountForTesting() > 0,
        "the fixture needs one conversation to mirror");
    root.addConversationForTesting(["user", "assistant"],
        ["open notepad and type hi", "Notepad is open with your text."]);
    const petLines = root.petConversationLines(3);
    assert(petLines.length >= 2,
        "the bubble must show the request and its reply, got " ~
        to!string(petLines.length));
    assert(petLines[$ - 2] == "You: open notepad and type hi",
        "the user's line must be labelled, got: " ~ petLines[$ - 2]);
    assert(petLines[$ - 1] == "Notepad is open with your text.",
        "the reply must reach the bubble, got: " ~ petLines[$ - 1]);
    writeln("PASS the pet bubble shows the request and then the reply");

    // 2f. Notes live in the pet's own file: one line per observation, and the
    // file is trimmed to the newest lines so it cannot grow without bound.
    const notesPath = petNotesPath();
    if (exists(notesPath)) remove(notesPath);
    petNote("first observation");
    petNote("second observation");
    auto noteLines = readText(notesPath).splitLines();
    assert(noteLines.length == 2,
        "two observations must produce two lines, got " ~
        to!string(noteLines.length));
    assert(noteLines[0] == "- first observation",
        "notes are markdown bullets, got: " ~ noteLines[0]);
    assert(notesPath.indexOf(buildPath("pet", "notes.md")) >= 0,
        "notes must live in the pet's own folder, got: " ~ notesPath);
    foreach (i; 0 .. 1200) petNote("observation " ~ to!string(i));
    noteLines = readText(notesPath).splitLines();
    assert(noteLines.length == petNoteLineLimit,
        "notes must stay capped at " ~ to!string(petNoteLineLimit) ~
        ", got " ~ to!string(noteLines.length));
    assert(noteLines[$ - 1] == "- observation 1199",
        "the cap must keep the newest note, got: " ~ noteLines[$ - 1]);
    writeln("PASS notes stay in the pet's own file and stay capped");

    // 2g. Scene awareness is text-only, bounded and throttled: no pixels, no
    // file contents, and an unchanged scene is not reported as a change.
    auto fake = new FakeScene;
    fake.scene = PetScene("code.exe", "notes.txt - Code");
    auto watch = new PetScreenWatch(delegate() { return fake.scene; });
    const firstScene = watch.sample(0);
    assert(firstScene.digest == "code.exe | notes.txt - Code",
        "the digest is app plus title, got: " ~ firstScene.digest);
    assert(!firstScene.changed, "the first sample is not a change");
    char[] longText;
    longText.length = 400;
    longText[] = 'z';
    fake.scene.title = longText.idup;
    assert(watch.sample(1000).digest.length == 0,
        "samples must be throttled to the slow cadence");
    const changedScene = watch.sample(20_000);
    assert(changedScene.changed, "a different title must read as a change");
    assert(changedScene.digest.length <= 60 + 3 + 81,
        "the digest must stay bounded, got " ~
        to!string(changedScene.digest.length));
    // 60 and 80 character caps plus " | " and two three-byte ellipses.
    assert(petSceneDigest(longText.idup, longText.idup).length <= 149,
        "long app names and titles must be clipped");
    // The real sampler must not invent text, and must report the same bounded
    // shape as the injected one.
    const realScene = sampleForegroundScene();
    assert(realScene.digest.length <= 145,
        "the real scene digest must stay bounded");
    writeln("foreground scene: ", realScene.digest);
    writeln("PASS screen sampling stays text-only, bounded and throttled");

    // 2h. Proactive rules are slow and silent by default: a scene comment needs
    // an actual change and ten minutes; an idle comment happens once per quiet
    // stretch, and only after ten minutes.
    assert(!root.petSceneCommentDue("a | b", "a | b", 60),
        "an unchanged scene must stay silent");
    assert(!root.petSceneCommentDue("a | b", "c | d", 9.9),
        "scene comments must wait ten minutes");
    assert(root.petSceneCommentDue("a | b", "c | d", 10),
        "a changed scene after ten minutes is due");
    assert(!root.petIdleCommentDue(9, false),
        "idle comments must wait ten minutes");
    assert(root.petIdleCommentDue(10, false),
        "a long idle stretch is due once");
    assert(!root.petIdleCommentDue(60, true),
        "one idle comment per idle stretch");
    writeln("PASS proactive comments are slow, change-driven and once per stretch");

    // 2i. Pause stops recording while the pet stays visible, and resumes.
    const pausePath = petNotesPath();
    if (exists(pausePath)) remove(pausePath);
    root.petNoteForTesting("before pause");
    assert(readText(pausePath).splitLines().length == 1,
        "a note is recorded before pausing");
    root.petPauseForTesting(true);
    assert(root.petPausedForTesting(), "pause must be a real host flag");
    root.petNoteForTesting("while paused");
    assert(readText(pausePath).splitLines().length == 1,
        "a paused pet must record nothing");
    root.petPauseForTesting(false);
    root.petNoteForTesting("after resume");
    assert(readText(pausePath).indexOf("after resume") >= 0,
        "unpausing must record again");
    writeln("PASS pause stops notes and resume records again");

    // 2j. The screen-watching sub-switch persists and reaches the running host;
    // the commentary cadence persists beside it.
    auto watchSettings = loadSettings();
    watchSettings.petScreenWatching = false;
    watchSettings.petCommentaryMinutes = 20;
    saveSettings(watchSettings);
    const reloaded = loadSettings();
    assert(!reloaded.petScreenWatching,
        "the screen-watching sub-switch must persist as off");
    assert(reloaded.petCommentaryMinutes == 20,
        "the commentary cadence must persist, got " ~
        to!string(reloaded.petCommentaryMinutes));
    root.petScreenWatchingForTesting(false);
    assert(!root.petScreenWatchingEnabledForTesting(),
        "switching watching off must reach the host");
    root.petScreenWatchingForTesting(true);
    assert(root.petScreenWatchingEnabledForTesting(),
        "switching watching on must reach the host");
    watchSettings.petScreenWatching = true;
    watchSettings.petCommentaryMinutes = 10;
    saveSettings(watchSettings);
    writeln("PASS screen watching and cadence settings round-trip and reach the host");

    // 2k. A pet-typed screen task goes through the same submitOverlayPrompt path
    // (so the approval gate applies) and hints when computer use is off.
    const offHint = root.petComputerUseHint("open notepad and type hi", false);
    assert(offHint.indexOf("Computer use is off") >= 0,
        "a screen task must hint when computer use is off, got: " ~ offHint);
    assert(root.petComputerUseHint("open notepad and type hi", true).length == 0,
        "no hint is needed when computer use is on");
    assert(root.petComputerUseHint("summarise this", false).length == 0,
        "a text-only request must not hint");
    writeln("PASS computer use off shows a hint, and on stays silent");

    // 3. Turning it off stops the overlay and returns to dormant.
    root.setFloatingPetForTesting(false);
    assert(!root.floatingPetEnabledForTesting(),
        "Disabling the switch must stop and drop the pet overlay");
    writeln("PASS disabling the pet stops the overlay and returns to dormant");

    // 4. Render the overlay itself and capture it, so the visible result is
    // checked rather than assumed. The production overlay lives on its own
    // thread; this builds the identical window on this thread.
    auto probe = new PetHost();
    auto overlayWindow = probe.renderForTesting(proposal);
    if (overlayWindow !is null)
    {
        overlayWindow.saveScreenshot(
            "build/pet-smoke/floating-pet-overlay.ppm");
        writeln("saved overlay render to build/pet-smoke/floating-pet-overlay.ppm");

        // 5. Placement: with an injected work area, the overlay must sit in the
        // bottom-right with a 16px margin, above the taskbar. This asserts the
        // real geometry rather than trusting that "bottom-right" was coded.
        auto driver = new UiTestDriver(overlayWindow);
        driver.setTestWorkArea(Rect(0, 0, 1920, 1040));
        probe.placeForTesting(overlayWindow);
        Rect placed;
        assert(driver.lastWindowBounds(placed), "window position was not recorded");
        assert(placed.right() == 1920 - 16,
            "overlay must sit 16px from the right edge, got right=" ~
            to!string(placed.right()));
        assert(placed.bottom() == 1040 - 16,
            "overlay must sit 16px above the work-area bottom, got bottom=" ~
            to!string(placed.bottom()));
        assert(placed.x >= 0 && placed.y >= 0,
            "overlay must stay inside the work area");
        writeln("PASS overlay places itself in the bottom-right, inside the work area");
    }

    // 6. Render the retry offer too. It is the headline behaviour of this
    // feature, and a substring assertion cannot show that the text actually
    // fits and stays legible - only pixels can.
    auto retryProbe = new PetHost();
    auto retryWindow = retryProbe.renderForTesting(failureProposal);
    if (retryWindow !is null)
    {
        retryWindow.saveScreenshot(
            "build/pet-smoke/floating-pet-retry.ppm");
        writeln("saved retry render to build/pet-smoke/floating-pet-retry.ppm");
    }
    else
        writeln("overlay window unavailable in this environment (no display)");

    // 7. The creature itself: drawn, clickable, and the click reveals the input
    // row that starts collapsed. This is the "click me and start writing"
    // gesture, so it is asserted rather than assumed from the layout code.
    auto creatureProbe = new PetHost();
    auto creatureWindow = creatureProbe.renderForTesting(proposal);
    if (creatureWindow !is null)
    {
        creatureWindow.saveScreenshot(
            "build/pet-smoke/floating-pet-creature.ppm");
        writeln("saved creature render to build/pet-smoke/floating-pet-creature.ppm");
        auto overlay = creatureProbe.renderedOverlayForTesting();
        assert(overlay !is null, "the rendered overlay must be reachable for the test");
        const faceBounds = overlay.faceBoundsForTesting();
        writeln("creature bounds: ", faceBounds.width, "x", faceBounds.height);
        assert(faceBounds.width >= 32 && faceBounds.height >= 32,
            "the creature needs a real box, got " ~ to!string(faceBounds.width) ~
            "x" ~ to!string(faceBounds.height));
        writeln("creature paints: ", overlay.facePaintCountForTesting());
        assert(overlay.facePaintCountForTesting() > 0,
            "the creature must reach the paint pass, not just the layout pass");
        const painted = overlay.facePaintBoxForTesting();
        writeln("creature painted at: ", painted.x, ",", painted.y, " ",
            painted.width, "x", painted.height);
        assert(painted.width >= 32 && painted.height >= 32,
            "the creature must be painted into a real box");
        assert(!overlay.inputVisibleForTesting(),
            "the input row must start collapsed so the resting pet stays small");
        assert(overlay.faceMoodForTesting() == PetMood.idle,
            "a resting creature must be idle, not signalling work");
        overlay.clickBodyForTesting(Point(200, 60));
        assert(overlay.inputVisibleForTesting(),
            "a left click anywhere on the companion must reveal the input");
        overlay.clickFaceForTesting();
        assert(overlay.inputVisibleForTesting(),
            "clicking the creature must reveal the input row");
        assert(overlay.faceMoodForTesting() == PetMood.listening,
            "the creature must show it is listening while the input is open");
        overlay.setInputForTesting("open notepad");
        assert(overlay.inputTextForTesting() == "open notepad",
            "typed text must reach the input without keystrokes");
        auto creatureDriver = new UiTestDriver(creatureWindow);
        creatureDriver.paint();
        creatureWindow.saveScreenshot(
            "build/pet-smoke/floating-pet-talking.ppm");
        writeln("saved talking render to build/pet-smoke/floating-pet-talking.ppm");
        writeln("PASS clicking the creature reveals the collapsed input row");
        const inputBox = overlay.inputBoundsForTesting();
        writeln("input bounds: ", inputBox.x, ",", inputBox.y, " ",
            inputBox.width, "x", inputBox.height);
        // The creature layer must not swallow the footer controls, the menu
        // must offer the actions, and Close must actually stop the companion.
        const layer = overlay.faceLayerBoundsForTesting();
        const pauseBox = overlay.pauseBoundsForTesting();
        assert(layer.width == 48 && layer.height == 48,
            "the creature layer must be its own 48x48 slot, got " ~
            to!string(layer.width) ~ "x" ~ to!string(layer.height));
        assert(pauseBox.width > 0 && pauseBox.height > 0,
            "the Pause button must be laid out");
        assert(layer.intersection(pauseBox).empty,
            "the creature layer must not cover the Pause button");
        overlay.clickPauseForTesting();
        assert(creatureProbe.paused(), "Pause must reach the host");
        overlay.clickPauseForTesting();
        assert(!creatureProbe.paused(), "Resume must reach the host");
        const menu = overlay.menuLabelsForTesting();
        assert(menu.length == 4 && menu[0] == "Write…" &&
            menu[$ - 1] == "Close companion",
            "the right-click menu must offer Write through Close companion");
        assert(petIdleLine.indexOf("write") >= 0 &&
            petIdleLine.indexOf("talk") < 0,
            "the resting line must say write, not talk, got: " ~ petIdleLine);
        writeln("PASS companion controls are clickable and the menu is present");
        overlay.clickCloseForTesting();
        assert(creatureProbe.stopRequested(), "Close must stop the companion");
    }
    else
        writeln("creature window unavailable in this environment (no display)");

    root.shutdownClient();
    writeln("floating pet smoke passed");
    return 0;
}
