// A small always-on-top progress window for rebuild and recovery maintenance.
//
// The app being rebuilt is closed while this runs, so the feedback has to come
// from the tool rather than from the app. It is deliberately built on plain
// Win32 with no Aurora dependency: the moment this window is most needed is the
// moment the app is broken, and a helper that shares code with the thing it is
// repairing cannot be relied on then.
//
// Drawing is done by hand (two filled rectangles and some text) rather than
// with a progress-bar control, so there is no extra library to load and the
// bar can be driven from any thread.
module progresswindow;

version (Windows):

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.utf : toUTF16;

import core.sys.windows.windows;

private __gshared Mutex _mutex;

// The paint path locks this, and `UpdateWindow` paints immediately, so it has
// to exist before the window is created: a null mutex here faults inside the
// window thread at startup and takes the whole tool down with it.
static this()
{
    _mutex = new Mutex();
}
private __gshared string _title = "Aurora OpenCode";
private __gshared string _detail;
private __gshared string _phase;
private __gshared double _fraction = -1.0;
private __gshared HWND _hwnd;
private __gshared bool _threadRunning;
private __gshared Thread _thread;

private enum windowWidth = 460;
private enum windowHeight = 148;

private COLORREF rgb(ubyte r, ubyte g, ubyte b)
{
    return cast(COLORREF) (r | (cast(int) g << 8) | (cast(int) b << 16));
}

/**
 * A NUL-terminated UTF-16 copy of `text`.
 *
 * The result must be held in a local across the Win32 call that consumes it.
 * `toUTF16z` returns a bare pointer whose buffer nothing keeps alive, so
 * handing it straight to `RegisterClassW` / `DrawTextW` leaves those calls
 * reading freed memory - which crashes the tool at startup, exactly when it is
 * least able to report why.
 */
private wstring wideString(string text)
{
    return toUTF16(text) ~ "\0"w;
}

/// Paint the whole window: background, title, phase, bar and detail line.
private void drawProgress(HWND hwnd)
{
    PAINTSTRUCT paint;
    auto dc = BeginPaint(hwnd, &paint);
    scope (exit) EndPaint(hwnd, &paint);

    RECT client;
    GetClientRect(hwnd, &client);
    auto background = CreateSolidBrush(rgb(24, 24, 28));
    FillRect(dc, &client, background);
    DeleteObject(background);
    SetBkMode(dc, TRANSPARENT);

    string title, detail, phase;
    double fraction;
    _mutex.lock();
    scope (exit) _mutex.unlock();
    title = _title;
    detail = _detail;
    phase = _phase;
    fraction = _fraction;

    SetTextColor(dc, rgb(240, 240, 245));
    RECT titleRect = client;
    titleRect.left = 20;
    titleRect.top = 14;
    titleRect.right -= 20;
    titleRect.bottom = titleRect.top + 28;
    auto titleWide = wideString(title);
    DrawTextW(dc, titleWide.ptr, -1, &titleRect, DT_LEFT | DT_SINGLELINE);

    SetTextColor(dc, rgb(170, 175, 190));
    RECT phaseRect = titleRect;
    phaseRect.top = titleRect.bottom;
    phaseRect.bottom = phaseRect.top + 22;
    auto phaseWide = wideString(phase);
    DrawTextW(dc, phaseWide.ptr, -1, &phaseRect, DT_LEFT | DT_SINGLELINE);

    // The bar: a darker track, then the filled portion. An unknown duration
    // sweeps on a fixed stride, so the window keeps moving while a step of
    // indeterminate length runs - a frozen bar and a hung tool look identical.
    RECT track;
    track.left = 20;
    track.right = client.right - 20;
    track.top = client.bottom - 54;
    track.bottom = track.top + 10;
    auto trackBrush = CreateSolidBrush(rgb(46, 48, 56));
    FillRect(dc, &track, trackBrush);
    DeleteObject(trackBrush);

    double shown = fraction;
    if (shown < 0.0)
        shown = cast(double) (GetTickCount() % 2400) / 2400.0;
    if (shown > 1.0) shown = 1.0;
    if (shown < 0.02) shown = 0.02;
    RECT fill = track;
    auto fillWidth = cast(int) (cast(long) (track.right - track.left) * shown);
    fill.right = track.left + fillWidth;
    auto fillBrush = CreateSolidBrush(rgb(96, 176, 240));
    FillRect(dc, &fill, fillBrush);
    DeleteObject(fillBrush);

    SetTextColor(dc, rgb(140, 145, 158));
    RECT detailRect;
    detailRect.left = 20;
    detailRect.right = client.right - 20;
    detailRect.top = track.bottom + 10;
    detailRect.bottom = detailRect.top + 22;
    auto detailWide = wideString(detail);
    DrawTextW(dc, detailWide.ptr, -1, &detailRect,
        DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
}

private extern (Windows) LRESULT progressProc(HWND hwnd, UINT message,
    WPARAM wParam, LPARAM lParam) nothrow
{
    switch (message)
    {
        case WM_PAINT:
        {
            // A window procedure must not throw across the Win32 boundary, so
            // the drawing (which allocates and locks) is isolated here.
            try drawProgress(hwnd);
            catch (Throwable) {}
            return 0;
        }
        case WM_ERASEBKGND:
            return 1;
        case WM_TIMER:
            // Repainted on a timer so the unknown-duration sweep keeps moving.
            // A bar that only repaints when something calls setProgress looks
            // identical to a hung tool during a long, silent step - which is
            // exactly the state this window exists to rule out.
            InvalidateRect(hwnd, null, TRUE);
            return 0;
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
        case WM_CLOSE:
            // The window is a status display, not a control surface: closing it
            // must not cancel the rebuild halfway through. Destroying it here,
            // on the thread that owns it, is what lets the message loop end.
            DestroyWindow(hwnd);
            return 0;
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

private void windowThread()
{
    // The window is a convenience, never a requirement: a fault while building
    // it must not take down the tool that is doing the actual work.
    try
        runWindowThread();
    catch (Throwable) {}
    _threadRunning = false;
}

private void runWindowThread()
{
    immutable className = "AuroraProgressWindow";
    // Held in locals for the whole call: the window class keeps using this
    // string after RegisterClassW returns.
    auto classNameWide = wideString(className);
    auto windowTitleWide = wideString(_title);
    auto instance = GetModuleHandleW(null);

    WNDCLASSW definition;
    definition.lpfnWndProc = &progressProc;
    definition.hInstance = instance;
    definition.lpszClassName = classNameWide.ptr;
    definition.hbrBackground = null;
    RegisterClassW(&definition);

    const style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU;
    auto hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        classNameWide.ptr, windowTitleWide.ptr,
        style, CW_USEDEFAULT, CW_USEDEFAULT, windowWidth, windowHeight,
        null, null, instance, null);
    if (hwnd is null) return;
    _hwnd = hwnd;
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    SetTimer(hwnd, 1, 120, null);

    MSG message;
    while (GetMessageW(&message, null, 0, 0) > 0)
    {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    _hwnd = null;
}

/// Show the window. Safe to call once; later calls only update it.
void openProgressWindow(string title)
{
    _mutex.lock();
    _title = title;
    _mutex.unlock();
    if (_threadRunning) return;
    _threadRunning = true;
    try
    {
        _thread = new Thread(&windowThread);
        _thread.start();
    }
    catch (Throwable)
    {
        _threadRunning = false;
        return;
    }
    // Wait briefly for the window to exist, so a fast first step still shows.
    foreach (_; 0 .. 20)
    {
        if (_hwnd !is null) return;
        Thread.sleep(25.msecs);
    }
}

/// Update the displayed phase. `fraction` below zero means unknown duration.
void setProgress(string phase, string detail, double fraction)
{
    _mutex.lock();
    _phase = phase;
    _detail = detail;
    _fraction = fraction;
    _mutex.unlock();
    if (_hwnd !is null)
        InvalidateRect(_hwnd, null, TRUE);
}

void closeProgressWindow()
{
    if (_hwnd !is null)
        PostMessageW(_hwnd, WM_CLOSE, 0, 0);
    // The window owns its message loop; closing it drains the queue and ends
    // the thread. Wait for that rather than killing the thread from outside.
    foreach (_; 0 .. 40)
    {
        if (!_threadRunning) return;
        Thread.sleep(25.msecs);
    }
}

version (Posix):

void openProgressWindow(string title) {}
void setProgress(string phase, string detail, double fraction) {}
void closeProgressWindow() {}
