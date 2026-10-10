module app;

import aurora;
import aurorarustdesk.identity : loadOrCreateIdentity;
import aurorarustdesk.rendezvous : RendezvousServer;
import aurorarustdesk.ui : RustDeskRoot, rustDeskWindowOptions;
import aurorarustdesk.windowsintegration : TrayIcon;
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
            writeln("Aurora RustDesk 1.0.0");
            return 0;
        }
        if (arguments[1] == "--print-id")
        {
            const identity = loadOrCreateIdentity();
            writeln(identity.numericId);
            return 0;
        }
        if (arguments[1] == "--server")
        {
            ushort idPort = 21_116;
            ushort relayPort = 21_117;
            if (arguments.length > 2) idPort = to!ushort(arguments[2]);
            if (arguments.length > 3) relayPort = to!ushort(arguments[3]);
            auto server = new RendezvousServer;
            const actualIdPort = server.start(idPort, relayPort);
            writeln("Aurora RustDesk ID server listening on 0.0.0.0:", actualIdPort);
            writeln("Aurora RustDesk relay listening on 0.0.0.0:", server.relayPort());
            writeln("Close this window to stop the server.");
            while (true) Thread.sleep(1.seconds);
        }
    }

    bool background;
    foreach (argument; arguments)
        if (argument == "--background") background = true;

    const identity = loadOrCreateIdentity();
    auto options = rustDeskWindowOptions();
    options.startNoActivate = background;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new RustDeskRoot(identity, window, background);
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
