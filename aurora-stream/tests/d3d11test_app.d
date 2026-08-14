module d3d11test_app;

import aurorastream.d3d11;
import core.sys.windows.windows;
import core.sys.windows.wingdi;
import core.sys.windows.winuser;
import core.thread : Thread;
import core.time : msecs;
import std.stdio;
import std.utf : toUTF16z;
import std.conv : to;
import std.file : append;
import std.math : sin, cos;

/// A minimal D3D11 swapchain app that clears the back buffer to a cycling
/// color and presents. Used to verify the raw D3D11 bindings and later as the
/// target for the game-capture render hook (the hook intercepts Present and
/// must capture these animated frames).

version (Windows)
extern (C)
{
    import core.sys.windows.windows : HRESULT;
    HRESULT CreateDXGIFactory1(const GUID* riid, void** ppFactory);
    HANDLE CreateWaitableTimerExW(LPSECURITY_ATTRIBUTES attributes,
        LPCWSTR name, DWORD flags, DWORD desiredAccess);
}

private enum uint createWaitableTimerHighResolution = 0x00000002;

void main(string[] args)
{
    import std.stdio : writeln;
    void mark(string message)
    {
        try append("d3dtest_debug.txt", message ~ "\n");
        catch (Exception) {}
        writeln(message);
    }
    mark("start");
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
    uint swapFormat = DXGI_FORMAT_B8G8R8A8_UNORM;
    foreach (argument; args[1 .. $])
    {
        if (argument == "--rgba") swapFormat = DXGI_FORMAT_R8G8B8A8_UNORM;
        if (argument == "--rgb10") swapFormat = DXGI_FORMAT_R10G10B10A2_UNORM;
    }
    mark("swap format=" ~ swapFormat.to!string);

    alias CreateDeviceFn = extern(C) HRESULT function(void*, uint, HMODULE,
        uint, const uint*, uint, uint, void**, uint*, void**);
    alias CreateDeviceAndSwapChainFn = extern(C) HRESULT function(void*,
        uint, HMODULE, uint, const uint*, uint, uint, const void*,
        void**, void**, uint*, void**);

    auto d3d11 = LoadLibraryW(toUTF16z("d3d11.dll"));
    if (d3d11 is null) { mark("no d3d11.dll"); return; }
    auto createDevice = cast(CreateDeviceAndSwapChainFn) GetProcAddress(d3d11, "D3D11CreateDeviceAndSwapChain");
    if (createDevice is null) { mark("no D3D11CreateDeviceAndSwapChain"); return; }

    // Window for the swapchain.
    HINSTANCE instance = GetModuleHandleW(null);
    const className = "D3D11TestApp"w;
    WNDCLASSW wc;
    wc.lpfnWndProc = &probeProc;
    wc.hInstance = instance;
    wc.lpszClassName = className.ptr;
    if (RegisterClassW(&wc) == 0) { mark("register failed"); return; }
    HWND hwnd = CreateWindowExW(0, className.ptr, className.ptr,
        WS_OVERLAPPEDWINDOW, 100, 100, 640, 480, null, null, instance, null);
    if (hwnd is null) { mark("create window failed"); return; }
    // The release gate must never steal focus or cover the user's desktop.
    // Keep presenting while minimized so the render hook is exercised exactly
    // like a background/minimized game that continues rendering.
    ShowWindow(hwnd, SW_SHOWMINNOACTIVE);
    mark("window minimized without activation");

    // Device + swapchain in one call (avoids the DXGI factory path).
    void* deviceRaw;
    void* contextRaw;
    void* swapchainRaw;
    uint featureLevel;
    uint featureLevels = D3D_FEATURE_LEVEL_11_0;

    DXGI_SWAP_CHAIN_DESC scDesc;
    scDesc.BufferDesc.Width = 1920;
    scDesc.BufferDesc.Height = 1080;
    scDesc.BufferDesc.RefreshRate.Numerator = 60;
    scDesc.BufferDesc.RefreshRate.Denominator = 1;
    scDesc.BufferDesc.Format = swapFormat;
    scDesc.SampleDesc.Count = 1;
    scDesc.SampleDesc.Quality = 0;
    scDesc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    scDesc.BufferCount = 2;
    scDesc.OutputWindow = hwnd;
    scDesc.Windowed = true;
    scDesc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    scDesc.Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH;

    auto hr = createDevice(null, D3D_DRIVER_TYPE_HARDWARE, null,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, &featureLevels, 1,
        D3D11_SDK_VERSION, &scDesc, &swapchainRaw, &deviceRaw,
        &featureLevel, &contextRaw);
    if (hr != 0)
    {
        hr = createDevice(null, D3D_DRIVER_TYPE_WARP, null,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT, &featureLevels, 1,
            D3D11_SDK_VERSION, &scDesc, &swapchainRaw, &deviceRaw,
            &featureLevel, &contextRaw);
    }
    if (hr != 0 || deviceRaw is null || contextRaw is null || swapchainRaw is null)
    {
        mark("create device+swapchain failed " ~ hr.to!string);
        return;
    }
    auto device = cast(ID3D11DeviceObj*) deviceRaw;
    auto context = cast(ID3D11DeviceContextObj*) contextRaw;
    auto swapchain = cast(IDXGISwapChainObj*) swapchainRaw;
    mark("device+swapchain ok fl=" ~ featureLevel.to!string);

    // Verify GetImmediateContext (slot 38) writes the context.
    void* ctxFromDevice = cast(void*) 0x1234;
    device.lpVtbl.GetImmediateContext(device, &ctxFromDevice);
    mark("GetImmediateContext ctx=" ~ (cast(ulong) ctxFromDevice).to!string ~
        " direct=" ~ (cast(ulong) context).to!string ~
        " match=" ~ (ctxFromDevice == context).to!string);
    mark("device vtable addr=" ~ (cast(ulong) device.lpVtbl).to!string);
    mark("slot0=" ~ (cast(ulong) (&device.lpVtbl.QueryInterface)[0]).to!string);
    mark("slot38=" ~ (cast(ulong) (&device.lpVtbl.QueryInterface)[38]).to!string);

    // Back buffer + RTV.
    void* backBuffer;
    hr = swapchain.lpVtbl.GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, &backBuffer);
    if (hr != 0 || backBuffer is null) { mark("getbuffer failed " ~ hr.to!string); return; }
    void* rtv;
    D3D11_RENDER_TARGET_VIEW_DESC rtvDesc;
    rtvDesc.Format = swapFormat;
    rtvDesc.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
    rtvDesc.Texture2D_MipSlice = 0;
    hr = device.lpVtbl.CreateRenderTargetView(device, backBuffer, &rtvDesc, &rtv);
    if (hr != 0 || rtv is null) { mark("rtv failed " ~ hr.to!string); return; }
    mark("rtv ok");

    // Render loop: clear to a cycling color and present until closed.
    const start = GetTickCount();
    auto presentTimer = CreateWaitableTimerExW(null, null,
        createWaitableTimerHighResolution, TIMER_ALL_ACCESS);
    if (presentTimer is null)
        presentTimer = CreateWaitableTimerW(null, false, null);
    scope(exit) if (presentTimer !is null) CloseHandle(presentTimer);
    LARGE_INTEGER firstPresent;
    firstPresent.QuadPart = -10_000; // one millisecond, in relative 100 ns units
    if (presentTimer !is null)
        SetWaitableTimer(presentTimer, &firstPresent, 4, null, null, false);
    uint frameCount;
    while (GetTickCount() - start < 30000)
    {
        MSG msg;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0)
        {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        const phase = cast(float) frameCount * 0.05f;
        float[4] color = [ 1.0f, 0.5f + 0.5f * sin(phase), 0.5f + 0.5f * cos(phase), 1.0f ];
        context.lpVtbl.ClearRenderTargetView(context, rtv, color.ptr);
        hr = swapchain.lpVtbl.Present(swapchain, 0, 0);
        // A minimized swapchain returns DXGI_STATUS_OCCLUDED (a positive
        // success status). Keep rendering; only negative HRESULTs are errors.
        if (hr < 0) { mark("present failed " ~ hr.to!string); break; }
        ++frameCount;
        // A 250 FPS high-resolution waitable timer models an uncapped game
        // without letting an invisible test swapchain monopolize a CPU/GPU.
        // This remains well above the hook's 60 FPS capture limiter.
        if (presentTimer !is null)
            WaitForSingleObject(presentTimer, INFINITE);
    }
    mark("presented=" ~ frameCount.to!string);

    swapchain.lpVtbl.Release(swapchain);
    context.lpVtbl.Release(context);
    device.lpVtbl.Release(device);
    DestroyWindow(hwnd);
    FreeLibrary(d3d11);
    mark("done");
}

private extern (Windows) LRESULT probeProc(HWND hwnd, uint msg, WPARAM wParam,
    LPARAM lParam) nothrow
{
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}
