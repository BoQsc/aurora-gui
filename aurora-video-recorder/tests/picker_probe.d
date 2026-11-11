// Scratch probe: report the geometry checks for the Notepad window.
import aurorarecorder.windowpicker : windowCaptureRect, windowProcessName,
    windowRecordable, windowTitle;
import core.sys.windows.windows : GetWindowRect, HWND, IsWindow,
    IsWindowVisible, RECT, SetWindowPos;
import std.stdio : writeln;

void main(string[] args)
{
    import core.sys.windows.windows : FindWindowW;
    import std.utf : toUTF16z;
    HWND w = FindWindowW(toUTF16z("Notepad"), null);
    if (w is null) { writeln("no notepad window"); return; }
    // Bring it above the full-screen editor window.
    SetWindowPos(w, cast(HWND) -1, 120, 120, 900, 600, 0x0040);
    writeln("title=[", windowTitle(w), "] proc=[", windowProcessName(w), "]");
    writeln("IsWindow=", IsWindow(w), " visible=", IsWindowVisible(w));
    RECT r;
    writeln("GetWindowRect ok=", GetWindowRect(w, &r), " ",
        r.left, ",", r.top, " ", r.right - r.left, "x", r.bottom - r.top);
    const rect = windowCaptureRect(w);
    writeln("windowCaptureRect=", rect.x, ",", rect.y, " ", rect.width, "x",
        rect.height, " valid=", rect.valid());
    writeln("windowRecordable=", windowRecordable(w));
}
