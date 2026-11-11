module floating_pet_live_probe;

// Real-window check for the companion fixes: taskbar visibility, the face, and
// whether a genuine mouse click reveals and focuses the input row.
//
// Build:
//   dmd -i -Isource -Ishared -I../aurora-opencode-core/source
//       -I../vendor/aurora-d-0.4.5/source -Jassets
//       -ofbuild/pet-smoke/live.exe tests/floating_pet_live_probe.d
//       user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib

import auroraopencode.pet : PetHost;
import core.thread : Thread;
import core.time : msecs, seconds;
import std.stdio : writeln;

version (Windows)
{
    private extern (Windows)
    {
        void* FindWindowW(const(wchar)* cls, const(wchar)* title);
        ptrdiff_t GetWindowLongPtrW(void* hwnd, int index);
        int GetWindowRect(void* hwnd, int* rect);
        void* GetForegroundWindow();
        int GetClientRect(void* hwnd, int* rect);
        int SetCursorPos(int x, int y);
        void mouse_event(uint flags, uint dx, uint dy, uint data, size_t extra);
    }
}

int main()
{
    auto host = new PetHost();
    host.publishText("Hi! Click me to write.");
    host.start();
    Thread.sleep(2.seconds);

    const overlay = host.renderedOverlayForTesting();
    writeln("overlay: ", overlay !is null);
    if (overlay !is null) writeln("input before click: ",
        overlay.inputVisibleForTesting());

    version (Windows)
    {
        auto hwnd = FindWindowW(null, "Aurora Companion");
        writeln("window: ", hwnd);
        if (hwnd !is null)
        {
            enum GWL_EXSTYLE = -20;
            enum WS_EX_TOOLWINDOW = 0x80;
            const style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
            writeln("toolwindow: ", (style & WS_EX_TOOLWINDOW) != 0);
            int[4] client;
            GetClientRect(hwnd, client.ptr);
            int[4] bounds;
            GetWindowRect(hwnd, bounds.ptr);
            writeln("client: ", client[2], "x", client[3], " at ",
                bounds[0], ",", bounds[1]);

            // A real pointer click on the companion BODY, away from the 48x48
            // face: any left click must open the input, not just the face.
            const x = bounds[0] + 200;
            const y = bounds[1] + 60;
            SetCursorPos(x, y);
            Thread.sleep(100.msecs);
            mouse_event(0x0002, 0, 0, 0, 0);
            mouse_event(0x0004, 0, 0, 0, 0);
            Thread.sleep(400.msecs);
            writeln("foreground: ", GetForegroundWindow() == hwnd);

            // The footer controls must be clickable now that the creature layer
            // is its own slot: click Pause and read the host flag back.
            SetCursorPos(bounds[0] + 355, bounds[1] + 152);
            Thread.sleep(100.msecs);
            mouse_event(0x0002, 0, 0, 0, 0);
            mouse_event(0x0004, 0, 0, 0, 0);
            Thread.sleep(300.msecs);
            writeln("paused after first Pause click: ", host.paused());
            mouse_event(0x0002, 0, 0, 0, 0);
            mouse_event(0x0004, 0, 0, 0, 0);
            Thread.sleep(300.msecs);
            writeln("paused after second Pause click: ", host.paused());

            // Right-click opens the companion menu.
            Thread.sleep(400.msecs);
            SetCursorPos(bounds[0] + 200, bounds[1] + 70);
            Thread.sleep(100.msecs);
            mouse_event(0x0008, 0, 0, 0, 0);
            mouse_event(0x0010, 0, 0, 0, 0);
            Thread.sleep(500.msecs);
            writeln("right-clicked for the menu");
        }
    }
    if (overlay !is null) writeln("input after click: ",
        overlay.inputVisibleForTesting());

    Thread.sleep(2.seconds);
    host.stop();
    Thread.sleep(1.seconds);
    return 0;
}
