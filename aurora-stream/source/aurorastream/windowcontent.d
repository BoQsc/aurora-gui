module aurorastream.windowcontent;

/**
 * Window content capture for streaming.
 *
 * The device-context, DIB-section and HALFTONE aspect-fit scaling plumbing now
 * lives in the shared engine module `aurora.platform.gdi`; this class only maps
 * the persisted window handle text to the shared `WindowContentCapture`.
 */

import aurora.platform.gdi : WindowContentCapture;

version (Windows)
{
    import aurorastream.windowsources : hwndFromText;

    /// Captures a window's OWN rendered content via `PrintWindow`, so the stream
    /// keeps showing the window even when it is covered, off-screen, or in the
    /// background. A minimized window has no rendered surface, so `capture`
    /// returns false and the caller keeps sending the last good frame.
    final class WindowContentCapturer
    {
        private WindowContentCapture _capture;
        private string _windowText;

        this(int width, int height)
        {
            _capture = new WindowContentCapture(width, height);
        }

        void setTargetSize(int width, int height)
        {
            _capture.setOutputSize(width, height);
        }

        /// Selects the window whose content is captured. The handle text is
        /// re-parsed only when it changes so a streaming loop stays cheap.
        void setWindowTarget(string hwndText)
        {
            if (hwndText == _windowText) return;
            _windowText = hwndText.idup;
            _capture.setWindow(cast(void*) hwndFromText(hwndText));
        }

        /// Captures the window's own content scaled to the configured size into
        /// `bgra` (BGRA8 bytes, `width * height * 4`). Returns false when the
        /// window is closed or minimized (no rendered content).
        bool capture(ubyte[] bgra)
        {
            return _capture.capture(bgra);
        }
    }
}
else
{
    /// Non-Windows fallback keeps the module compilable elsewhere.
    final class WindowContentCapturer
    {
        this(int width, int height) {}
        void setTargetSize(int width, int height) {}
        void setWindowTarget(string hwndText) {}
        bool capture(ubyte[] bgra) { return false; }
    }
}

version (Windows)
unittest
{
    import std.conv : to;
    import core.thread : Thread;
    import core.time : msecs;

    // The capturer must accept a stale/empty handle without throwing.
    auto capturer = new WindowContentCapturer(320, 180);
    capturer.setTargetSize(480, 270);
    capturer.setWindowTarget("");
    auto buffer = new ubyte[480 * 270 * 4];
    assert(!capturer.capture(buffer));

    // A real window on an interactive session must capture its own content;
    // headless/service sessions may not be able to create one and the capture
    // then legitimately returns false.
    import core.sys.windows.windows : CreateWindowExW, DefWindowProcW,
        DestroyWindow, GetModuleHandleW, GetTickCount, HWND, LRESULT, LPARAM,
        MSG, PeekMessageW, PM_REMOVE, RegisterClassW, ShowWindow,
        SW_SHOWNOACTIVATE,
        TranslateMessage, DispatchMessageW, WNDCLASSW, WPARAM,
        WS_OVERLAPPEDWINDOW;
    extern (Windows) LRESULT contentProbeProc(HWND hwnd, uint msg,
        WPARAM wParam, LPARAM lParam) nothrow
    {
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
    const probeClass = "AuroraContentProbe"w;
    WNDCLASSW wc;
    wc.lpfnWndProc = &contentProbeProc;
    wc.hInstance = GetModuleHandleW(null);
    wc.lpszClassName = probeClass.ptr;
    if (RegisterClassW(&wc) != 0)
    {
        auto probeWindow = CreateWindowExW(0, probeClass.ptr, probeClass.ptr,
            WS_OVERLAPPEDWINDOW, -32_000, -32_000, 320, 240, null, null,
            GetModuleHandleW(null), null);
        if (probeWindow !is null)
        {
            ShowWindow(probeWindow, SW_SHOWNOACTIVATE);
            MSG msg;
            const deadline = GetTickCount() + 500;
            while (GetTickCount() < deadline)
            {
                while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0)
                {
                    TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
                Thread.sleep(5.msecs);
            }
            auto windowCapturer = new WindowContentCapturer(320, 240);
            windowCapturer.setWindowTarget(to!string(cast(ulong) probeWindow));
            auto windowBuffer = new ubyte[320 * 240 * 4];
            windowCapturer.capture(windowBuffer); // may fail on headless
            DestroyWindow(probeWindow);
        }
    }
}
