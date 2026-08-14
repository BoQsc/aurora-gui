module diagmincheck;

import std.stdio;

import aurorastream.broadcast : BroadcastQuality, BroadcastSettings,
    EncoderSelection, validateBroadcastSettings;
import aurorastream.windowsources : enumerateWindows, windowIsMinimized;

void main(string[] args)
{
    const windows = enumerateWindows();
    writeln("enumerated=", windows.length);
    // Report any currently-minimized windows in the list (they must be flagged).
    int minimizedCount;
    foreach (window; windows)
    {
        const hwnd = toHwnd(window.hwnd);
        if (windowIsMinimized(hwnd))
        {
            minimizedCount++;
            writeln("  minimized: [", window.processName, "] [", window.title, "]");
        }
    }
    writeln("minimizedCount=", minimizedCount);

    // validateBroadcastSettings must reject a minimized selection.
    foreach (window; windows)
    {
        const hwnd = toHwnd(window.hwnd);
        if (!windowIsMinimized(hwnd)) continue;
        BroadcastSettings settings;
        settings.twitchEnabled = true;
        settings.twitchKey = "test-key";
        settings.youtubeEnabled = false;
        settings.windowCaptureHwnd = hwnd;
        settings.windowCaptureLabel = window.processName ~ " — " ~ window.title;
        EncoderSelection encoder;
        encoder.ffmpegAvailable = true;
        encoder.name = "libx264";
        const error = validateBroadcastSettings(settings, encoder);
        writeln("  validation for minimized window => [", error, "]");
        break;
    }
}

string toHwnd(ulong hwnd)
{
    import std.conv : to;
    return to!string(hwnd);
}
