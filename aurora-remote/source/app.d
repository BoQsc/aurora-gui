module app;

import aurora;
import auroraremote.capsule : decodeConnectionCapsule, deviceIdText;
import auroraremote.identity : loadOrCreateIdentity;
import auroraremote.relay : RelayServer;
import auroraremote.ui : RemoteRoot, remoteWindowOptions;
import auroraremote.windowsintegration : TrayIcon;
import core.thread : Thread;
import core.time : seconds;
import std.conv : to;
import std.stdio : writeln;

version (Windows)
{
    import core.sys.windows.windows : AllocConsole, FILE_TYPE_UNKNOWN,
        GetFileType, GetStdHandle, INVALID_HANDLE_VALUE, STD_OUTPUT_HANDLE;
}

private void attachDiagnosticConsole()
{
    version (Windows)
    {
        import core.stdc.stdio : stdout;
        const output = GetStdHandle(STD_OUTPUT_HANDLE);
        if (output !is null && output != INVALID_HANDLE_VALUE &&
            GetFileType(cast(void*) output) != FILE_TYPE_UNKNOWN)
            return;
        if (!AllocConsole()) return;
        import core.stdc.stdio : freopen;
        freopen("CONOUT$", "w", stdout);
    }
}

int main(string[] arguments)
{
    if (arguments.length > 1)
    {
        attachDiagnosticConsole();
        if (arguments[1] == "--version" || arguments[1] == "-v")
        {
            writeln("Aurora Remote 1.0.0");
            return 0;
        }
        if (arguments[1] == "--print-identity")
        {
            const identity = loadOrCreateIdentity();
            writeln(deviceIdText(identity.id[]));
            return 0;
        }
        if (arguments[1] == "--relay")
        {
            attachDiagnosticConsole();
            ushort port = 47_832;
            if (arguments.length > 2) port = to!ushort(arguments[2]);
            auto relay = new RelayServer;
            const actualPort = relay.start(port);
            writeln("Aurora Remote relay listening on 0.0.0.0:", actualPort);
            writeln("Close this window to stop the relay.");
            while (true) Thread.sleep(1.seconds);
        }
        if (arguments[1] == "--decode-code" && arguments.length > 2)
        {
            const capsule = decodeConnectionCapsule(arguments[2]);
            writeln("host=", capsule.host);
            writeln("port=", capsule.port);
            writeln("device=", deviceIdText(capsule.deviceId[]));
            writeln("expires_unix=", capsule.expiresUnix);
            return 0;
        }
    }

    bool background;
    foreach (argument; arguments)
        if (argument == "--background") background = true;

    const identity = loadOrCreateIdentity();
    auto options = remoteWindowOptions();
    options.startNoActivate = background;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new RemoteRoot(identity, "", 47_831, window, background);
    window.setRoot(root);
    TrayIcon tray;
    bool trayAvailable;
    bool exitRequested;
    try
    {
        tray = new TrayIcon;
        tray.onShow = delegate()
        {
            if (window.isMinimized()) window.restore();
            window.setVisible(true);
        };
        tray.onExit = delegate()
        {
            exitRequested = true;
            window.close();
        };
        trayAvailable = tray.show();
    }
    catch (Exception) tray = null;
    window.onCloseRequested = delegate()
    {
        if (!exitRequested && trayAvailable && root.keepRunningInTray())
        {
            window.setVisible(false);
            return false;
        }
        root.shutdown();
        if (tray !is null) tray.shutdown();
        return true;
    };
    return window.run();
}
