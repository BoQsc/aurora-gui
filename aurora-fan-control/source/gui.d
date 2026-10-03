module gui;

// Windowed front end built directly on Win32 (user32/gdi32) -- no GUI toolkit.

import core.sys.windows.windef;
import core.sys.windows.winnt;
import core.sys.windows.winbase;
import core.sys.windows.winuser;
import core.sys.windows.wingdi;

import std.utf : toUTF16z;
import std.conv : to;
import std.format : format;
import std.file : write;

import wmi;

// --- constants not guaranteed in the bindings ------------------------------
private enum UINT WM_PRINT            = 0x0317;
private enum UINT PRF_NONCLIENT       = 0x00000002;
private enum UINT PRF_CLIENT          = 0x00000004;
private enum UINT PRF_ERASEBKGND      = 0x00000008;
private enum UINT PRF_CHILDREN        = 0x00000010;

private enum int IDC_COOL_ON  = 201;
private enum int IDC_COOL_OFF = 202;
private enum int IDC_APPLY    = 203;
private enum int IDC_COMBO    = 204;
private enum int IDC_DEFAULTS = 205;
private enum int IDT_TIMER    = 1;

private COLORREF color(ubyte r, ubyte g, ubyte b) { return r | (g << 8) | (b << 16); }

private immutable wchar[] CLASS_NAME = "AuroraFanControlClass"w;

// --- state ------------------------------------------------------------------
private __gshared HWND gMain;
private __gshared HWND gValCpu, gValGpu, gValF1, gValF2, gValCool, gValTherm, gMsg, gCombo;
private __gshared HBRUSH gBg;
private __gshared FanDevice gDev;
private __gshared bool gDevFailed;
private __gshared string gDevError;

private ushort LOWORD(WPARAM v) { return cast(ushort)(v & 0xFFFF); }

private void setText(HWND h, string s) { SetWindowTextW(h, s.toUTF16z); }

private HWND childEx(DWORD exStyle, string cls, string text, DWORD style, int x, int y, int w, int h, int id)
{
    return CreateWindowExW(exStyle, toUTF16z(cls), toUTF16z(text), style, x, y, w, h,
                           gMain, cast(HMENU)cast(size_t)id, GetModuleHandleW(null), null);
}

private void buildControls(HWND hwnd)
{
    gMain = hwnd;
    gBg = CreateSolidBrush(color(30, 30, 36));

    DWORD labelStyle = WS_CHILD | WS_VISIBLE;
    DWORD valueStyle = WS_CHILD | WS_VISIBLE;

    setText(childEx(0, "STATIC", "LEGION Y520 - MANUAL FAN CONTROL", labelStyle, 16, 12, 408, 24, 100),
            "LEGION Y520 - MANUAL FAN CONTROL");

    childEx(0, "STATIC", "CPU temperature", labelStyle, 16, 52, 190, 22, 101);
    gValCpu = childEx(0, "STATIC", "--", valueStyle, 210, 52, 200, 22, 110);
    childEx(0, "STATIC", "GPU temperature", labelStyle, 16, 80, 190, 22, 102);
    gValGpu = childEx(0, "STATIC", "--", valueStyle, 210, 80, 200, 22, 111);
    childEx(0, "STATIC", "Fan 1 speed", labelStyle, 16, 108, 190, 22, 103);
    gValF1 = childEx(0, "STATIC", "--", valueStyle, 210, 108, 200, 22, 112);
    childEx(0, "STATIC", "Fan 2 speed", labelStyle, 16, 136, 190, 22, 104);
    gValF2 = childEx(0, "STATIC", "--", valueStyle, 210, 136, 200, 22, 113);
    childEx(0, "STATIC", "Cooling boost", labelStyle, 16, 164, 190, 22, 105);
    gValCool = childEx(0, "STATIC", "--", valueStyle, 210, 164, 220, 22, 114);
    childEx(0, "STATIC", "Thermal table", labelStyle, 16, 192, 190, 22, 106);
    gValTherm = childEx(0, "STATIC", "--", valueStyle, 210, 192, 200, 22, 115);

    childEx(0, "BUTTON", "Cooling ON", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 16, 232, 120, 32, IDC_COOL_ON);
    childEx(0, "BUTTON", "Cooling OFF", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 146, 232, 120, 32, IDC_COOL_OFF);
    childEx(0, "STATIC", "Thermal:", labelStyle, 286, 238, 56, 22, 107);
    gCombo = CreateWindowExW(0, toUTF16z("COMBOBOX"), null,
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | CBS_DROPDOWN | WS_VSCROLL,
        344, 235, 60, 200, hwnd, cast(HMENU)cast(size_t)IDC_COMBO, GetModuleHandleW(null), null);
    SendMessageW(gCombo, CB_ADDSTRING, 0, cast(LPARAM)"1"w.ptr);
    SendMessageW(gCombo, CB_ADDSTRING, 0, cast(LPARAM)"2"w.ptr);
    SendMessageW(gCombo, CB_ADDSTRING, 0, cast(LPARAM)"3"w.ptr);
    SendMessageW(gCombo, CB_SETCURSEL, 0, 0);

    childEx(0, "BUTTON", "Apply", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 16, 274, 200, 32, IDC_APPLY);
    childEx(0, "BUTTON", "Restore Defaults", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 224, 274, 200, 32, IDC_DEFAULTS);
    gMsg = childEx(0, "STATIC", "starting...", labelStyle, 16, 312, 408, 20, 108);
}

private void openDevice()
{
    try
    {
        gDev = new FanDevice();
    }
    catch (Exception e)
    {
        gDev = null;
        gDevFailed = true;
        gDevError = e.msg;
    }
}

private void refreshUi()
{
    if (gDev is null)
    {
        if (gDevFailed)
            setText(gMsg, "Access denied - run as Administrator. (" ~ gDevError ~ ")");
        return;
    }
    try
    {
        auto t = gDev.telemetry();
        setText(gValCpu,   format("%d C", t.cpuTemp));
        setText(gValGpu,   format("%d C", t.gpuTemp));
        setText(gValF1,    format("%d RPM", t.fan1Speed));
        setText(gValF2,    format("%d RPM", t.fan2Speed));
        setText(gValCool,  coolingText(t.coolingStatus) ~ format("   (max %d RPM)", t.fanMaxSpeed));
        setText(gValTherm, format("%d", t.thermalTable));
    }
    catch (Exception e)
    {
        setText(gMsg, "ERROR: " ~ e.msg);
    }
}

private void applyThermal()
{
    if (gDev is null) { setText(gMsg, "No device access."); return; }
    wchar[16] buf;
    int n = GetWindowTextW(gCombo, buf.ptr, cast(int)buf.length);
    try
    {
        uint id = to!uint(buf[0 .. n].to!string);
        gDev.setThermalTable(id);
        writelnMsg(format("Thermal table set to %d", id));
    }
    catch (Exception e) { setText(gMsg, "ERROR: " ~ e.msg); }
}

private void writelnMsg(string s) { setText(gMsg, s); }

// Cooling back to automatic and the firmware default thermal table.
private void applyDefaults()
{
    if (gDev is null) { setText(gMsg, "No device access."); return; }
    try
    {
        gDev.setCooling(false);
        gDev.setThermalTable(0);
        refreshUi();
        setText(gMsg, "Restored defaults: cooling auto, thermal table 0");
    }
    catch (Exception e) { setText(gMsg, "ERROR: " ~ e.msg); }
}

private extern (Windows) LRESULT wndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    switch (msg)
    {
        case WM_CREATE:
            buildControls(hwnd);
            openDevice();
            refreshUi();
            SetTimer(hwnd, IDT_TIMER, 1500, null);
            return 0;

        case WM_TIMER:
            refreshUi();
            return 0;

        case WM_COMMAND:
            switch (LOWORD(wParam))
            {
                case IDC_COOL_ON:
                    if (gDev) { try { gDev.setCooling(true);  refreshUi(); } catch (Exception e) { setText(gMsg, "ERROR: " ~ e.msg); } }
                    else setText(gMsg, "No device access.");
                    return 0;
                case IDC_COOL_OFF:
                    if (gDev) { try { gDev.setCooling(false); refreshUi(); } catch (Exception e) { setText(gMsg, "ERROR: " ~ e.msg); } }
                    else setText(gMsg, "No device access.");
                    return 0;
                case IDC_APPLY:
                    applyThermal();
                    return 0;
                case IDC_DEFAULTS:
                    applyDefaults();
                    return 0;
                default:
                    return 0;
            }

        case WM_CTLCOLORSTATIC:
        {
            HDC hdc = cast(HDC)wParam;
            SetBkMode(hdc, TRANSPARENT);
            SetBkColor(hdc, color(30, 30, 36));
            HWND who = cast(HWND)lParam;
            if (who == gValCpu || who == gValGpu || who == gValF1 || who == gValF2 || who == gValCool || who == gValTherm)
                SetTextColor(hdc, color(120, 200, 255));
            else if (who == gMsg)
                SetTextColor(hdc, color(170, 170, 180));
            else
                SetTextColor(hdc, color(230, 230, 235));
            return cast(LRESULT)cast(void*)gBg;
        }

        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;

        default:
            return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

private HINSTANCE thisInstance() { return GetModuleHandleW(null); }

private bool registerClass(HINSTANCE hInst)
{
    WNDCLASSEXW wc;
    wc.cbSize = WNDCLASSEXW.sizeof;
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = cast(WNDPROC)&wndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursorW(null, cast(const(wchar)*)cast(size_t)32512); // IDC_ARROW
    wc.hbrBackground = cast(HBRUSH)CreateSolidBrush(color(30, 30, 36));
    wc.lpszClassName = CLASS_NAME.ptr;
    return RegisterClassExW(&wc) != 0;
}

private HWND createMainWindow(HINSTANCE hInst)
{
    DWORD style = WS_OVERLAPPEDWINDOW & ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
    return CreateWindowExW(0, CLASS_NAME.ptr, "Aurora Fan Control"w.ptr, style,
        CW_USEDEFAULT, CW_USEDEFAULT, 470, 400, null, null, hInst, null);
}

private void saveClientBmp(HWND hwnd, string path)
{
    RECT rc;
    GetClientRect(hwnd, &rc);
    int w = rc.right, h = rc.bottom;

    HDC hdc = GetDC(hwnd);
    HDC mem = CreateCompatibleDC(hdc);
    HBITMAP bmp = CreateCompatibleBitmap(hdc, w, h);
    HGDIOBJ old = SelectObject(mem, bmp);

    SendMessageW(hwnd, WM_PRINT, cast(WPARAM)mem,
        PRF_CLIENT | PRF_ERASEBKGND | PRF_CHILDREN | PRF_NONCLIENT);

    BITMAPINFO bmi;
    bmi.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h; // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    int stride = w * 4;
    ubyte[] pixels = new ubyte[stride * h];
    GetDIBits(mem, bmp, 0, cast(UINT)h, pixels.ptr, &bmi, DIB_RGB_COLORS);

    SelectObject(mem, old);
    DeleteObject(bmp);
    DeleteDC(mem);
    ReleaseDC(hwnd, hdc);

    // 14-byte BITMAPFILEHEADER + 40-byte BITMAPINFOHEADER, written byte by byte
    // (a struct would get 4-byte alignment and shift the fields).
    ubyte[] hdr = new ubyte[54];
    void put16(size_t off, ushort v)
    {
        hdr[off] = cast(ubyte)v;
        hdr[off + 1] = cast(ubyte)(v >> 8);
    }
    void put32(size_t off, uint v)
    {
        hdr[off]     = cast(ubyte)v;
        hdr[off + 1] = cast(ubyte)(v >> 8);
        hdr[off + 2] = cast(ubyte)(v >> 16);
        hdr[off + 3] = cast(ubyte)(v >> 24);
    }
    uint pixBytes = cast(uint)pixels.length;
    put16(0, 0x4D42);           // 'BM'
    put32(2, 54 + pixBytes);    // bfSize
    put32(10, 54);              // bfOffBits
    put32(14, 40);              // biSize
    put32(18, cast(uint)w);     // biWidth
    put32(22, cast(uint)(-h));  // biHeight (negative = top-down)
    put16(26, 1);               // biPlanes
    put16(28, 32);              // biBitCount
    put32(30, 0);               // biCompression = BI_RGB
    put32(34, pixBytes);        // biSizeImage
    put32(38, 2835);            // biXPelsPerMeter
    put32(42, 2835);            // biYPelsPerMeter
    write(path, hdr ~ pixels);
}

private void pump(int times)
{
    MSG msg;
    foreach (_; 0 .. times)
    {
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0)
        {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

private string exePath()
{
    wchar[1024] buf;
    DWORD n = GetModuleFileNameW(null, buf.ptr, cast(DWORD)buf.length);
    return n ? buf[0 .. n].to!string : "";
}

int main(string[] args)
{
    bool selfTest = args.length > 1 && args[1] == "--selftest";
    string shot = args.length > 2 ? args[2] : "gui-selftest.bmp";

    // Request Administrator rights up front (root\WMI needs them).
    bool alreadyElevated = false;
    foreach (a; args)
        if (a == "--elevated") alreadyElevated = true;
    if (!selfTest && !alreadyElevated && !isElevated())
    {
        string exe = exePath();
        if (exe.length)
        {
            ShellExecuteW(null, "runas"w.ptr, exe.toUTF16z, "--elevated"w.ptr, null, 1);
            return 0;
        }
    }

    HINSTANCE hInst = thisInstance();
    if (!registerClass(hInst)) return 2;
    HWND hwnd = createMainWindow(hInst);
    if (hwnd is null) return 2;

    if (selfTest)
    {
        // Sample data so the capture exercises the real layout (no admin needed).
        setText(gValCpu,   "54 C");
        setText(gValGpu,   "47 C");
        setText(gValF1,    "2450 RPM");
        setText(gValF2,    "2380 RPM");
        setText(gValCool,  "off (auto)   (max 5200 RPM)");
        setText(gValTherm, "1");
        setText(gMsg,      "self-test preview");

        ShowWindow(hwnd, SW_SHOW);
        UpdateWindow(hwnd);
        pump(8);
        saveClientBmp(hwnd, shot);
        DestroyWindow(hwnd);
        return 0;
    }

    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);

    MSG msg;
    while (GetMessageW(&msg, null, 0, 0) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}
