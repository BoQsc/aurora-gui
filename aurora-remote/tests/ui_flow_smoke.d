module tests.ui_flow_smoke;

import aurora;
import auroraremote.crypto : randomBytes, sha256;
import auroraremote.identity : DeviceIdentity;
import auroraremote.ui : RemoteRoot, remoteWindowOptions;
import core.thread : Thread;
import core.time : msecs;
import std.exception : enforce;
import std.stdio : writeln;
import std.utf : toUTF32;

private Point center(Rect value)
{
    return Point(value.x + value.width / 2, value.y + value.height / 2);
}

private void pump(RemoteRoot root, UiTestDriver driver)
{
    root.tickTree(0.11);
    driver.paint();
}

unittest
{
    DeviceIdentity identity;
    identity.secret[] = randomBytes(identity.secret.length);
    const digest = sha256(identity.secret[]);
    identity.id[] = digest[0 .. identity.id.length];

    auto options = remoteWindowOptions();
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new RemoteRoot(identity, "127.0.0.1", 0);
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
    enforce(root.testingSettingsVisible(),
        "Connection settings did not open.");
    assertLayoutClean(root);
    driver.click(center(root.testingSettingsButtonBounds()));
    driver.paint();
    enforce(!root.testingSettingsVisible(),
        "Connection settings did not return to the main workflow.");

    const firstLink = root.testingConnectionLink();
    const firstShareText = root.testingShareText();
    enforce(firstLink.length > 0, "Host did not create a connection link.");
    driver.click(center(root.testingConnectFieldBounds()));
    driver.text(toUTF32(firstLink));
    enforce(root.testingEnteredLink() == firstLink,
        "The connection field did not accept a pasted invitation.");
    driver.click(center(root.testingConnectButtonBounds()));

    bool openedSession;
    foreach (_; 0 .. 240)
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

    root.testingReplaceEnteredLink("not-a-connection-link");
    driver.click(center(root.testingConnectButtonBounds()));
    pump(root, driver);
    enforce(root.testingConnectStatus() ==
        "That connection link is invalid or has expired. Ask for a new link."d,
        "Invalid invitation did not produce the expected visible error.");
    enforce(root.testingConnectEnabled(),
        "Connect remained disabled after rejecting an invalid invitation.");

    driver.click(center(root.testingNewLinkButtonBounds()));
    const secondLink = root.testingConnectionLink();
    enforce(secondLink.length > 0 && secondLink != firstLink,
        "Create a new link did not rotate the invitation secret.");
    enforce(root.testingShareText() != firstShareText,
        "Create a new link gave no visible indication that it changed.");
    enforce(root.testingHostStatus().length > 0,
        "Create a new link gave no visible status confirmation.");
    root.testingReplaceEnteredLink(secondLink);
    driver.click(center(root.testingConnectButtonBounds()));

    bool reconnected;
    foreach (_; 0 .. 240)
    {
        pump(root, driver);
        if (root.testingSessionVisible() && root.testingRemoteFrameReady())
        {
            reconnected = true;
            break;
        }
        Thread.sleep(25.msecs);
    }
    enforce(reconnected, "The UI could not reconnect with a fresh link.");
    writeln("Aurora Remote UI flow passed: enter link, connect, render, end, reject invalid, reconnect");
}
