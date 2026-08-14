module gamecaphook;

/// OBS-style render hook for Aurora Stream, implemented entirely in D as a
/// `-betterC` DLL with a custom entry point (`/ENTRY`) and no CRT
/// initialization. The normal `_DllMainCRTStartup` fail-fasts when a CRT-bearing
/// DLL is injected into a foreign process (verified: STATUS_STACK_BUFFER_OVERRUN
/// 0xC0000409 even for a trivial DLL), so this DLL skips CRT startup entirely —
/// which is what professional injectable capture DLLs do.
///
/// When injected (CreateRemoteThread + LoadLibrary):
///   1. Reads `%TEMP%\aurora-gamecap-<pid>.cfg` (`hwnd=<decimal>` + `pipe=<name>`).
///   2. Creates a dummy D3D11 device + swapchain to obtain the process-shared
///      `IDXGISwapChain` vtable, then replaces its `Present` slot (index 8) with
///      our hook so every present routes through us.
///   3. In the hook, if the presenting swapchain belongs to the target window,
///      copies the back buffer to a staging texture, maps it, and writes the
///      BGRA rows into the named pipe the broadcaster reads; the original
///      Present is always called so the game is unaffected.
///
/// No D runtime and no GC: the hook runs on the game's render thread using only
/// raw Win32, fixed buffers, and HeapAlloc'd memory.

import core.sys.windows.windows;
import core.stdc.string : memcmp, memcpy, strlen;
import aurorastream.d3d11;

version (Windows)
{
    // ---- config (written by the injector before LoadLibrary) ----
    __gshared ulong g_targetHwnd;
    __gshared wchar[128] g_pipeName;

    // ---- hook state (all process-global; betterC has no TLS runtime) ----
    private __gshared extern (C) HRESULT function(void*, uint, uint) g_originalPresent;
    private __gshared HANDLE g_pipeHandle;
    private __gshared int g_captureBusy;
    private __gshared int g_stopCapturing;
    private __gshared void* g_frameBuffer;
    private __gshared size_t g_frameCapacity;
    private __gshared int g_hookActive;
    private __gshared uint g_lastCaptureTick;

    private extern (C) HRESULT hookPresent(void* self, uint syncInterval,
        uint flags)
    {
        // Fast path: not the target swapchain, a capture is in flight, or we
        // already captured this frame slot. Rate-limit to ~60 fps so a game
        // rendering much faster (uncapped/4000 fps) does not saturate the GPU
        // with per-present copies and stall its render loop.
        if (g_targetHwnd == 0 || g_stopCapturing || g_captureBusy)
            return g_originalPresent(self, syncInterval, flags);
        const nowTick = GetTickCount();
        if (nowTick - g_lastCaptureTick < 16)
            return g_originalPresent(self, syncInterval, flags);

        auto swapchain = cast(IDXGISwapChainObj*) self;
        if (!isTargetSwapchain(swapchain))
            return g_originalPresent(self, syncInterval, flags);

        g_captureBusy = 1;
        captureFrame(swapchain);
        g_captureBusy = 0;
        g_lastCaptureTick = nowTick;

        return g_originalPresent(self, syncInterval, flags);
    }

    /// Releases any COM object through its OWN vtable (slot 2 = IUnknown
    /// Release, an extern(C) function). Never release an object through another
    /// object's vtable.
    private void comRelease(void* obj)
    {
        if (obj is null) return;
        auto fn = (cast(void**) obj)[2];
        if (fn is null) return;
        alias ReleaseFn = extern(C) uint function(void*);
        (cast(ReleaseFn) fn)(obj);
    }

    private bool isTargetSwapchain(IDXGISwapChainObj* swapchain)
    {
        DXGI_SWAP_CHAIN_DESC desc;
        if (swapchain.lpVtbl.GetDesc(swapchain, &desc) != 0) return false;
        return desc.OutputWindow != null &&
            cast(ulong) desc.OutputWindow == g_targetHwnd;
    }

    private void captureFrame(IDXGISwapChainObj* swapchain)
    {
        if (g_pipeHandle is null) return;

        void* deviceRaw;
        if (swapchain.lpVtbl.GetDevice(swapchain, &IID_ID3D11Device, &deviceRaw) != 0)
            return;
        auto device = cast(ID3D11DeviceObj*) deviceRaw;
        void* contextRaw;
        device.lpVtbl.GetImmediateContext(device, &contextRaw);
        auto context = cast(ID3D11DeviceContextObj*) contextRaw;
        if (context is null) return;

        void* backBuffer;
        if (swapchain.lpVtbl.GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, &backBuffer) != 0)
            return;

        DXGI_SWAP_CHAIN_DESC desc;
        if (swapchain.lpVtbl.GetDesc(swapchain, &desc) != 0)
        {
            comRelease(backBuffer);
            return;
        }
        const width = desc.BufferDesc.Width;
        const height = desc.BufferDesc.Height;
        if (width == 0 || height == 0)
        {
            comRelease(backBuffer);
            return;
        }
        const rowPitch = width * 4;
        const byteCount = cast(size_t) rowPitch * height;

        if (g_frameBuffer is null || g_frameCapacity < byteCount)
        {
            if (g_frameBuffer !is null) HeapFree(GetProcessHeap(), 0, g_frameBuffer);
            g_frameBuffer = HeapAlloc(GetProcessHeap(), 0, byteCount);
            g_frameCapacity = byteCount;
            if (g_frameBuffer is null)
            {
                comRelease(backBuffer);
                return;
            }
        }

        D3D11_TEXTURE2D_DESC stagingDesc;
        stagingDesc.Width = width;
        stagingDesc.Height = height;
        stagingDesc.MipLevels = 1;
        stagingDesc.ArraySize = 1;
        stagingDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        stagingDesc.SampleDesc.Count = 1;
        stagingDesc.Usage = D3D11_USAGE_STAGING;
        stagingDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        void* staging;
        if (device.lpVtbl.CreateTexture2D(device, &stagingDesc, null, &staging) != 0)
        {
            comRelease(backBuffer);
            return;
        }

        context.lpVtbl.CopyResource(context, staging, backBuffer);
        D3D11_MAPPED_SUBRESOURCE mapped;
        if (context.lpVtbl.Map(context, staging, 0, D3D11_MAP_READ, 0, &mapped) != 0)
        {
            comRelease(staging);
            comRelease(backBuffer);
            return;
        }

        auto src = cast(const(ubyte)*) mapped.pData;
        auto dst = cast(ubyte*) g_frameBuffer;
        if (mapped.RowPitch == rowPitch)
            memcpy(dst, src, byteCount);
        else
        {
            foreach (y; 0 .. height)
                memcpy(dst + cast(size_t) y * rowPitch,
                    src + cast(size_t) y * mapped.RowPitch, rowPitch);
        }

        // Explicit cleanup (no scope(exit) in the betterC hook).
        context.lpVtbl.Unmap(context, staging, 0);
        comRelease(staging);
        comRelease(backBuffer);

        writeFrame(g_frameBuffer, byteCount);
    }

    private void writeFrame(const(void)* data, size_t byteCount)
    {
        if (g_pipeHandle is null) return;
        DWORD written;
        if (WriteFile(g_pipeHandle, data, cast(DWORD) byteCount, &written, null) == 0)
            g_stopCapturing = true; // reader gone
    }

    private ulong parseDecimal(const(char)* text)
    {
        ulong value;
        while (text !is null && *text >= '0' && *text <= '9')
        {
            value = value * 10 + cast(ulong)(*text - '0');
            ++text;
        }
        return value;
    }

    private void hookDebug(const(char)* text)
    {
        auto h = CreateFileA("C:\\temp\\gamecaphook_dbg.txt", GENERIC_WRITE,
            FILE_SHARE_READ, null, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
        if (h == INVALID_HANDLE_VALUE) return;
        SetFilePointer(h, 0, null, FILE_END);
        DWORD written;
        WriteFile(h, text, cast(DWORD) strlen(text), &written, null);
        WriteFile(h, "\r\n".ptr, 2, &written, null);
        CloseHandle(h);
    }

    private void setupHook()
    {
        hookDebug("setup: begin");
        // ---- read config ----
        const pid = GetCurrentProcessId();
        char[160] configPath;
        const tempLen = GetTempPathA(configPath.length, configPath.ptr);
        if (tempLen == 0 || tempLen >= configPath.length) return;
        enum configPrefix = "aurora-gamecap-";
        appendText(configPath.ptr, tempLen, configPrefix);
        appendText(configPath.ptr, tempLen + configPrefix.length, pid, ".cfg");
        hookDebug("setup: config path");

        HANDLE configFile = CreateFileA(configPath.ptr, GENERIC_READ,
            FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
        if (configFile == INVALID_HANDLE_VALUE)
        {
            // Write the attempted path so mismatches are visible.
            hookDebug("setup: config open FAILED err=");
            char[32] errBuf;
            errBuf[0] = 0;
            hookDebug(configPath.ptr);
            return;
        }
        char[512] config;
        DWORD configLen;
        ReadFile(configFile, config.ptr, config.length, &configLen, null);
        CloseHandle(configFile);
        if (configLen == 0)
        {
            hookDebug("setup: config empty");
            return;
        }
        hookDebug("setup: config read ok");

        // Parse "hwnd=...\npipe=...".
        const(char)* cur = config.ptr;
        const(char)* end = config.ptr + configLen;
        while (cur < end)
        {
            const(char)* lineStart = cur;
            while (cur < end && *cur != '\n' && *cur != '\r') ++cur;
            const(char)* lineEnd = cur;
            if (lineEnd > lineStart)
            {
                const(char)* eq = lineStart;
                while (eq < lineEnd && *eq != '=') ++eq;
                if (eq < lineEnd)
                {
                    if (eq - lineStart == 4 && memcmp(lineStart, "hwnd".ptr, 4) == 0)
                        g_targetHwnd = parseDecimal(eq + 1);
                    else if (eq - lineStart == 4 && memcmp(lineStart, "pipe".ptr, 4) == 0)
                    {
                        const pipeLen = lineEnd - (eq + 1);
                        if (pipeLen > 0 && pipeLen < g_pipeName.length)
                        {
                            foreach (i; 0 .. pipeLen)
                                g_pipeName[i] = cast(wchar)(eq + 1)[i];
                            g_pipeName[pipeLen] = 0;
                        }
                    }
                }
            }
            while (cur < end && (*cur == '\n' || *cur == '\r')) ++cur;
        }
        if (g_targetHwnd == 0 || g_pipeName[0] == 0)
        {
            hookDebug("setup: bad config");
            return;
        }
        hookDebug("setup: config ok");

        // ---- obtain the shared IDXGISwapChain vtable ----
        HMODULE d3d11 = LoadLibraryA("d3d11.dll");
        if (d3d11 is null) { hookDebug("setup: no d3d11"); return; }
        auto createDeviceAndSwapChain = cast(D3D11CreateDeviceAndSwapChainFn)
            GetProcAddress(d3d11, "D3D11CreateDeviceAndSwapChain");
        if (createDeviceAndSwapChain is null) { hookDebug("setup: no createfn"); return; }
        hookDebug("setup: d3d11 loaded");

        HINSTANCE instance = GetModuleHandleA(null);
        const className = "AuroraGameCapHook"w;
        WNDCLASSW wc;
        wc.lpfnWndProc = &dummyProc;
        wc.hInstance = instance;
        wc.lpszClassName = className.ptr;
        RegisterClassW(&wc);
        HWND dummy = CreateWindowExW(0, className.ptr, className.ptr,
            WS_OVERLAPPEDWINDOW, -32000, -32000, 64, 64, null, null, instance,
            null);
        if (dummy is null) return;

        DXGI_SWAP_CHAIN_DESC scDesc;
        scDesc.BufferDesc.Width = 64;
        scDesc.BufferDesc.Height = 64;
        scDesc.BufferDesc.RefreshRate.Numerator = 60;
        scDesc.BufferDesc.RefreshRate.Denominator = 1;
        scDesc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        scDesc.SampleDesc.Count = 1;
        scDesc.SampleDesc.Quality = 0;
        scDesc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        scDesc.BufferCount = 2;
        scDesc.OutputWindow = dummy;
        scDesc.Windowed = true;
        scDesc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

        void* swapchainRaw;
        void* deviceRaw;
        void* contextRaw;
        uint featureLevel;
        uint featureLevels = D3D_FEATURE_LEVEL_11_0;
        auto hr = createDeviceAndSwapChain(null, D3D_DRIVER_TYPE_HARDWARE,
            null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, &featureLevels, 1,
            D3D11_SDK_VERSION, &scDesc, &swapchainRaw, &deviceRaw,
            &featureLevel, &contextRaw);
        if (hr != 0)
            hr = createDeviceAndSwapChain(null, D3D_DRIVER_TYPE_WARP,
                null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, &featureLevels, 1,
                D3D11_SDK_VERSION, &scDesc, &swapchainRaw, &deviceRaw,
                &featureLevel, &contextRaw);
        if (hr != 0 || swapchainRaw is null)
        {
            hookDebug("setup: dev+swapchain failed");
            return;
        }
        auto swapchain = cast(IDXGISwapChainObj*) swapchainRaw;
        hookDebug("setup: dev+swapchain ok");

        // ---- patch the shared vtable Present slot ----
        auto vtbl = swapchain.lpVtbl;
        if (vtbl is null) { hookDebug("setup: no vtbl"); return; }
        g_originalPresent = vtbl.Present;
        if (cast(ulong) g_originalPresent == 0) { hookDebug("setup: no present"); return; }
        DWORD oldProtect;
        if (VirtualProtect(vtbl, 4096, PAGE_READWRITE, &oldProtect) == 0)
        {
            hookDebug("setup: vprotect failed");
            return;
        }
        vtbl.Present = &hookPresent;
        VirtualProtect(vtbl, 4096, oldProtect, &oldProtect);
        g_hookActive = 1;
        hookDebug("setup: vtable patched");

        // ---- connect the frame pipe ----
        g_pipeHandle = CreateFileW(g_pipeName.ptr, GENERIC_WRITE, 0, null,
            OPEN_EXISTING, 0, null);
        if (g_pipeHandle == INVALID_HANDLE_VALUE)
        {
            hookDebug("setup: pipe connect failed");
            return;
        }
        hookDebug("setup: pipe connected");

        // Keep this thread alive so the DLL stays loaded and the hook remains
        // installed until the broadcaster closes the pipe (write fails).
        while (!g_stopCapturing) Sleep(200);
    }

    /// Adds `label=value` to a wide char buffer; used for the pipe name.
    private extern (Windows) LRESULT dummyProc(HWND hwnd, uint msg,
        WPARAM wParam, LPARAM lParam) nothrow
    {
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    private extern (Windows) DWORD setupThreadProc(void* param)
    {
        setupHook();
        return 0;
    }

    private void appendText(char* buffer, size_t offset, string text)
    {
        foreach (i, c; text)
            buffer[offset + i] = cast(char) c;
        buffer[offset + text.length] = 0;
    }

    private void appendText(char* buffer, size_t offset, ulong value,
        string suffix)
    {
        char[24] digits;
        size_t n = 0;
        ulong v = value;
        if (v == 0) { digits[n++] = '0'; }
        while (v > 0) { digits[n++] = cast(char)('0' + v % 10); v /= 10; }
        foreach (i; 0 .. n)
            buffer[offset + i] = digits[n - 1 - i];
        foreach (i, c; suffix)
            buffer[offset + n + i] = cast(char) c;
        buffer[offset + n + suffix.length] = 0;
    }
}

/// Custom DLL entry point (linked with `/ENTRY:gamecaphookEntry`) so no CRT
/// startup runs in the foreign process. Returns TRUE for every reason.
extern (C) BOOL gamecaphookEntry(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    version (Windows)
    {
        if (reason == DLL_PROCESS_ATTACH)
        {
            // Spawn a worker thread so no D3D11/loader work happens while the
            // loader lock is held.
            HANDLE thread = CreateThread(null, 0, &setupThreadProc, null, 0, null);
            if (thread !is null) CloseHandle(thread);
        }
        else if (reason == DLL_PROCESS_DETACH)
        {
            g_stopCapturing = 1;
        }
    }
    return true;
}
