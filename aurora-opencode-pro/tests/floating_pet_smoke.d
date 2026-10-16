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
import auroraopencode.pet : PetHost;
import aurora.types : Rect;
import std.conv : to;
import std.file : mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;

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
        // bottom-left with a 16px margin. This asserts the real geometry rather
        // than trusting that "bottom-left" was coded correctly.
        auto driver = new UiTestDriver(overlayWindow);
        driver.setTestWorkArea(Rect(0, 0, 1920, 1040));
        probe.placeForTesting(overlayWindow);
        Rect placed;
        assert(driver.lastWindowBounds(placed), "window position was not recorded");
        assert(placed.x == 16,
            "overlay must sit 16px from the left edge, got x=" ~
            to!string(placed.x));
        assert(placed.bottom() == 1040 - 16,
            "overlay must sit 16px above the work-area bottom, got bottom=" ~
            to!string(placed.bottom()));
        assert(placed.right() <= 1920 && placed.y >= 0,
            "overlay must stay inside the work area");
        writeln("PASS overlay places itself in the bottom-left, inside the work area");
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

    root.shutdownClient();
    writeln("floating pet smoke passed");
    return 0;
}
