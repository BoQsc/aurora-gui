module tests.ui_flow_smoke;

import aurora;
import aurorarustdesk.crypto : randomBytes;
import aurorarustdesk.identity : DeviceIdentity, deviceFingerprint,
    numericIdFromSecret;
import aurorarustdesk.rendezvous : RendezvousServer;
import aurorarustdesk.ui : RustDeskRoot, rustDeskWindowOptions;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm.searching : startsWith;
import std.exception : enforce;
import std.stdio : writeln;
import std.utf : toUTF32;

private Point center(Rect value)
{
    return Point(value.x + value.width / 2, value.y + value.height / 2);
}

private void pump(RustDeskRoot root, UiTestDriver driver)
{
    root.tickTree(0.11);
    driver.paint();
}

unittest
{
    const secret = randomBytes(32);
    DeviceIdentity identity;
    identity.secret[] = secret[];
    identity.id = deviceFingerprint(secret);
    identity.numericId = numericIdFromSecret(secret);

    auto server = new RendezvousServer;
    const idPort = server.start(0, 0);
    scope (exit) server.stop();

    auto options = rustDeskWindowOptions();
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new RustDeskRoot(identity, window, false, "127.0.0.1", idPort);
    scope (exit) root.shutdown();
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    driver.paint();

    enforce(root.testingPrimaryActionsLaidOut(),
        "Primary workflow actions collapsed during layout.");
    assertLayoutClean(root);

    driver.click(center(root.testingSettingsButtonBounds()));
    driver.paint();
    enforce(root.testingSettingsVisible(), "Settings did not open.");
    assertLayoutClean(root);
    driver.click(center(root.testingSettingsButtonBounds()));
    driver.paint();
    enforce(!root.testingSettingsVisible(),
        "Settings did not return to the main workflow.");

    const id = root.testingShareId();
    const password = root.testingPassword();
    enforce(id == identity.numericId,
        "The share column did not display the numeric ID.");
    enforce(password.length > 0, "No password was generated for sharing.");

    driver.click(center(root.testingIdFieldBounds()));
    driver.text(toUTF32(id));
    enforce(root.testingEnteredId() == id,
        "The remote ID field did not accept the ID.");
    driver.click(center(root.testingPasswordFieldBounds()));
    driver.text(toUTF32(password));
    driver.click(center(root.testingConnectButtonBounds()));

    bool openedSession;
    foreach (_; 0 .. 300)
    {
        pump(root, driver);
        if (root.testingSessionVisible() && root.testingRemoteFrameReady())
        {
            openedSession = true;
            break;
        }
        Thread.sleep(25.msecs);
    }
    enforce(openedSession,
        "Connect did not open a session with a rendered remote frame.");
    enforce(!root.testingHomeVisible(),
        "Home remained visible over the connected session.");

    driver.click(center(root.testingDisconnectButtonBounds()));
    pump(root, driver);
    enforce(root.testingHomeVisible() && !root.testingSessionVisible(),
        "End session did not return to the home workflow.");

    root.testingReplaceEnteredId("999999999");
    root.testingReplacePassword("not-the-password");
    driver.click(center(root.testingConnectButtonBounds()));
    pump(root, driver);
    foreach (_; 0 .. 80)
    {
        pump(root, driver);
        if (root.testingConnectStatus().startsWith("ID not found"d)) break;
        Thread.sleep(25.msecs);
    }
    enforce(root.testingConnectStatus().startsWith("ID not found"d),
        "An unknown ID did not produce the expected visible error.");
    enforce(root.testingConnectEnabled(),
        "Connect remained disabled after rejecting an unknown ID.");
    writeln("Aurora RustDesk UI flow passed: show ID/password, connect, render, end, reject unknown ID");
}
