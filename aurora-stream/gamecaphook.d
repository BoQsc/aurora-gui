module gamecaphook;

/// Low-overhead D3D11 render hook for Aurora Stream. The injected DLL is built
/// with -betterC and a custom entry point: no D runtime, GC, or C compiler is
/// present in the game process.
///
/// The Present thread only submits an asynchronous GPU copy and opportunistically
/// maps an older staging texture with D3D11_MAP_FLAG_DO_NOT_WAIT. Completed CPU
/// frames enter a bounded latest-frame queue. A separate hook worker converts
/// and copies the newest image into a shared-memory ring; the named pipe carries
/// only small versioned headers. A slow broadcaster can therefore drop capture
/// frames but can never block the game's render thread.

import core.sys.windows.windows;
import core.atomic : atomicLoad, atomicOp, atomicStore, cas;
import core.simd : XMM, __simd_ib, uint4, void16;
import core.stdc.string : memcmp, memcpy, strlen;
import aurorastream.d3d11;
import aurorastream.gamecapprotocol : GameCaptureError,
    GameCaptureMessage, GameCapturePacketHeader, GameCapturePixelFormat,
    GameCaptureSharedHeader, GameCaptureSharedSlotState,
    gameCaptureHeaderSize, gameCaptureMagic, gameCaptureProtocolVersion,
    gameCaptureSharedMappingSize, gameCaptureSharedSlotCount,
    gameCaptureSharedSlotOffset, gameCaptureSharedSlotStride,
    validGameCaptureSharedHeader;

version (Windows)
{
    enum stagingSlotCount = 3;
    enum cpuFrameSlotCount = 3;
    enum frameSlotFree = 0;
    enum frameSlotFilling = 1;
    enum frameSlotReady = 2;
    enum frameSlotWriting = 3;

    struct StagingSlot
    {
        void* staging;
        void* resolve;
        bool pending;
        ulong sequence;
        ulong captureQpc;
    }

    struct CpuFrameSlot
    {
        void* data;
        size_t capacity;
        uint width;
        uint height;
        uint sourceFormat;
        ulong sequence;
        ulong captureQpc;
        shared LONG state;
    }

    // Configuration written before LoadLibrary.
    __gshared ulong g_targetHwnd;
    __gshared wchar[192] g_pipeName;
    __gshared wchar[192] g_mappingName;

    // Hook and transport state.
    private __gshared extern(C) HRESULT function(void*, uint, uint)
        g_originalPresent;
    private __gshared IDXGISwapChainVtbl* g_hookVtable;
    private __gshared HANDLE g_pipeHandle;
    private __gshared HANDLE g_sharedMapping;
    private __gshared void* g_sharedView;
    private __gshared GameCaptureSharedHeader* g_sharedHeader;
    private __gshared HANDLE g_frameEvent;
    private __gshared HMODULE g_d3d11Module;
    private shared LONG g_captureBusy;
    private shared LONG g_hookCalls;
    private shared LONG g_stopCapturing;
    private shared LONG g_fatalError;
    private shared LONG g_fatalSourceFormat;
    private shared LONG g_droppedFrames;
    private shared LONG g_hookActive;
    private __gshared ulong g_nextCaptureQpc;
    private __gshared ulong g_qpcFrequency;
    private __gshared ulong g_gpuSequence;

    // GPU staging resources are touched only by the serialized Present hook.
    private __gshared StagingSlot[stagingSlotCount] g_stagingSlots;
    private __gshared ID3D11DeviceObj* g_stagingDevice;
    private __gshared uint g_stagingWidth;
    private __gshared uint g_stagingHeight;
    private __gshared uint g_stagingFormat;
    private __gshared uint g_stagingSamples;

    // CPU slots are handed from Present to the pipe worker with Interlocked
    // state changes. No allocation or pipe I/O occurs after a slot is queued.
    private __gshared CpuFrameSlot[cpuFrameSlotCount] g_cpuFrames;

    private LONG atomicCompareExchange(ref shared LONG destination,
        LONG exchange, LONG comparison)
    {
        LONG previous = comparison;
        cas(&destination, &previous, exchange);
        return previous;
    }

    private void atomicExchange(ref shared LONG destination, LONG value)
    {
        atomicStore(destination, value);
    }

    private LONG atomicIncrement(ref shared LONG destination)
    {
        return atomicOp!"+="(destination, 1);
    }

    private LONG atomicDecrement(ref shared LONG destination)
    {
        return atomicOp!"-="(destination, 1);
    }

    private extern(C) HRESULT hookPresent(void* self, uint syncInterval,
        uint flags)
    {
        atomicIncrement(g_hookCalls);
        auto original = g_originalPresent;

        bool shouldCapture = g_targetHwnd != 0 && !g_stopCapturing &&
            atomicCompareExchange(g_captureBusy, 1, 0) == 0;
        if (shouldCapture)
        {
            LARGE_INTEGER counter;
            QueryPerformanceCounter(&counter);
            const now = cast(ulong) counter.QuadPart;
            const captureInterval = g_qpcFrequency > 0 ?
                g_qpcFrequency / 60 : 0;
            if (g_nextCaptureQpc == 0) g_nextCaptureQpc = now;
            if (captureInterval == 0 || now >= g_nextCaptureQpc)
            {
                auto swapchain = cast(IDXGISwapChainObj*) self;
                if (isTargetSwapchain(swapchain))
                {
                    captureFrame(swapchain, now);
                    g_nextCaptureQpc += captureInterval;
                    if (captureInterval > 0 &&
                        now > g_nextCaptureQpc + captureInterval)
                        g_nextCaptureQpc = now + captureInterval;
                }
            }
            atomicExchange(g_captureBusy, 0);
        }

        atomicDecrement(g_hookCalls);
        return original(self, syncInterval, flags);
    }

    private void comRelease(void* obj)
    {
        if (obj is null) return;
        auto fn = (cast(void***) obj)[0][2];
        if (fn is null) return;
        alias ReleaseFn = extern(C) uint function(void*);
        (cast(ReleaseFn) fn)(obj);
    }

    private bool isTargetSwapchain(IDXGISwapChainObj* swapchain)
    {
        if (swapchain is null || swapchain.lpVtbl is null) return false;
        DXGI_SWAP_CHAIN_DESC desc;
        if (swapchain.lpVtbl.GetDesc(swapchain, &desc) != 0 ||
            desc.OutputWindow is null)
            return false;
        if (cast(ulong) desc.OutputWindow == g_targetHwnd) return true;
        const root = GetAncestor(desc.OutputWindow, GA_ROOT);
        return root !is null && cast(ulong) root == g_targetHwnd;
    }

    private bool supportedFormat(uint format)
    {
        return format == DXGI_FORMAT_B8G8R8A8_UNORM ||
            format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB ||
            format == DXGI_FORMAT_R8G8B8A8_UNORM ||
            format == DXGI_FORMAT_R8G8B8A8_UNORM_SRGB ||
            format == DXGI_FORMAT_R10G10B10A2_UNORM;
    }

    private void reportFatal(GameCaptureError error, uint sourceFormat = 0)
    {
        if (atomicCompareExchange(g_fatalError, cast(LONG) error, 0) == 0)
        {
            atomicExchange(g_fatalSourceFormat, cast(LONG) sourceFormat);
            if (g_frameEvent !is null) SetEvent(g_frameEvent);
        }
    }

    private void resetStagingResources()
    {
        foreach (ref slot; g_stagingSlots)
        {
            comRelease(slot.staging);
            comRelease(slot.resolve);
            slot = StagingSlot.init;
        }
        comRelease(g_stagingDevice);
        g_stagingDevice = null;
        g_stagingWidth = 0;
        g_stagingHeight = 0;
        g_stagingFormat = 0;
        g_stagingSamples = 0;
    }

    private bool ensureStagingResources(ID3D11DeviceObj* device,
        const ref D3D11_TEXTURE2D_DESC sourceDesc, ref bool retainedDevice)
    {
        if (g_stagingDevice is device &&
            g_stagingWidth == sourceDesc.Width &&
            g_stagingHeight == sourceDesc.Height &&
            g_stagingFormat == sourceDesc.Format &&
            g_stagingSamples == sourceDesc.SampleDesc.Count)
            return true;

        resetStagingResources();
        g_stagingDevice = device; // Keep the GetDevice reference.
        retainedDevice = true;
        g_stagingWidth = sourceDesc.Width;
        g_stagingHeight = sourceDesc.Height;
        g_stagingFormat = sourceDesc.Format;
        g_stagingSamples = sourceDesc.SampleDesc.Count;

        D3D11_TEXTURE2D_DESC stagingDesc;
        stagingDesc.Width = sourceDesc.Width;
        stagingDesc.Height = sourceDesc.Height;
        stagingDesc.MipLevels = 1;
        stagingDesc.ArraySize = 1;
        stagingDesc.Format = sourceDesc.Format;
        stagingDesc.SampleDesc.Count = 1;
        stagingDesc.Usage = D3D11_USAGE_STAGING;
        stagingDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;

        D3D11_TEXTURE2D_DESC resolveDesc = stagingDesc;
        resolveDesc.Usage = D3D11_USAGE_DEFAULT;
        resolveDesc.CPUAccessFlags = 0;

        foreach (ref slot; g_stagingSlots)
        {
            if (device.lpVtbl.CreateTexture2D(device, &stagingDesc, null,
                &slot.staging) != 0 || slot.staging is null)
            {
                resetStagingResources();
                return false;
            }
            if (sourceDesc.SampleDesc.Count > 1 &&
                (device.lpVtbl.CreateTexture2D(device, &resolveDesc, null,
                    &slot.resolve) != 0 || slot.resolve is null))
            {
                resetStagingResources();
                return false;
            }
        }
        return true;
    }

    private int acquireCpuFrameSlot(size_t byteCount)
    {
        foreach (i; 0 .. cpuFrameSlotCount)
        {
            auto slot = &g_cpuFrames[i];
            if (atomicCompareExchange(slot.state, frameSlotFilling,
                frameSlotFree) != frameSlotFree)
                continue;

            if (slot.data is null || slot.capacity < byteCount)
            {
                if (slot.data !is null)
                    HeapFree(GetProcessHeap(), 0, slot.data);
                slot.data = HeapAlloc(GetProcessHeap(), 0, byteCount);
                slot.capacity = slot.data is null ? 0 : byteCount;
            }
            if (slot.data is null)
            {
                atomicExchange(slot.state, frameSlotFree);
                return -1;
            }
            return cast(int) i;
        }
        return -1;
    }

    private void copyMappedFrame(const ref D3D11_MAPPED_SUBRESOURCE mapped,
        uint width, uint height, uint sourceFormat, void* destination)
    {
        auto src = cast(const(ubyte)*) mapped.pData;
        auto dst = cast(ubyte*) destination;
        const outputPitch = cast(size_t) width * 4;
        if (mapped.RowPitch == outputPitch)
            memcpy(dst, src, outputPitch * height);
        else
        {
            foreach (y; 0 .. height)
                memcpy(dst + cast(size_t) y * outputPitch,
                    src + cast(size_t) y * mapped.RowPitch, outputPitch);
        }
    }

    /// Format conversion happens on the pipe worker, never on Present. Every
    /// supported source is four bytes per pixel, so the render thread can do a
    /// single row copy and return to the game quickly.
    private void convertFrameToBgra(CpuFrameSlot* frame)
    {
        if (frame.sourceFormat == DXGI_FORMAT_B8G8R8A8_UNORM ||
            frame.sourceFormat == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB)
            return;
        auto pixels = cast(uint*) frame.data;
        const pixelCount = cast(size_t) frame.width * frame.height;
        if (frame.sourceFormat == DXGI_FORMAT_R8G8B8A8_UNORM ||
            frame.sourceFormat == DXGI_FORMAT_R8G8B8A8_UNORM_SRGB)
        {
            // SSE2 is part of the x64 baseline. Avoid PSHUFB/SSSE3 so the
            // injected hook also works on older D3D11-capable x64 CPUs.
            uint4 fixedMask = [0xff00ff00U, 0xff00ff00U,
                0xff00ff00U, 0xff00ff00U];
            uint4 redMask = [0x000000ffU, 0x000000ffU,
                0x000000ffU, 0x000000ffU];
            uint4 blueMask = [0x00ff0000U, 0x00ff0000U,
                0x00ff0000U, 0x00ff0000U];
            auto vectors = cast(uint4*) pixels;
            const vectorCount = pixelCount / 4;
            foreach (i; 0 .. vectorCount)
            {
                const value = vectors[i];
                const red = cast(uint4) __simd_ib(XMM.PSLLD,
                    cast(void16) (value & redMask), 16);
                const blue = cast(uint4) __simd_ib(XMM.PSRLD,
                    cast(void16) (value & blueMask), 16);
                vectors[i] = (value & fixedMask) | red | blue;
            }
            foreach (i; vectorCount * 4 .. pixelCount)
            {
                const value = pixels[i];
                pixels[i] = (value & 0xff00ff00U) |
                    ((value & 0x000000ffU) << 16) |
                    ((value & 0x00ff0000U) >> 16);
            }
            return;
        }
        uint4 alpha = [0xff000000U, 0xff000000U,
            0xff000000U, 0xff000000U];
        uint4 byteMask = [0x000000ffU, 0x000000ffU,
            0x000000ffU, 0x000000ffU];
        uint4 greenMask = [0x0000ff00U, 0x0000ff00U,
            0x0000ff00U, 0x0000ff00U];
        uint4 redMask = [0x00ff0000U, 0x00ff0000U,
            0x00ff0000U, 0x00ff0000U];
        auto vectors = cast(uint4*) pixels;
        const vectorCount = pixelCount / 4;
        foreach (i; 0 .. vectorCount)
        {
            const value = vectors[i];
            const blue = cast(uint4) __simd_ib(XMM.PSRLD,
                cast(void16) value, 22);
            const green = cast(uint4) __simd_ib(XMM.PSRLD,
                cast(void16) value, 4);
            const red = cast(uint4) __simd_ib(XMM.PSLLD,
                cast(void16) value, 14);
            vectors[i] = alpha | (blue & byteMask) |
                (green & greenMask) | (red & redMask);
        }
        foreach (i; vectorCount * 4 .. pixelCount)
        {
            const value = pixels[i];
            pixels[i] = 0xff000000U |
                ((value >> 22) & 0x000000ffU) |
                ((value >> 4) & 0x0000ff00U) |
                ((value << 14) & 0x00ff0000U);
        }
    }

    private void drainReadyStaging(ID3D11DeviceContextObj* context)
    {
        // Immediate-context GPU work completes in submission order. Always
        // inspect the oldest pending copy first; walking by array index can
        // emit 4,2,3 after the ring wraps and makes transport diagnostics look
        // like frames vanished even though nothing was dropped.
        int oldestIndex = -1;
        ulong oldestSequence;
        foreach (i; 0 .. stagingSlotCount)
        {
            const slot = &g_stagingSlots[i];
            if (slot.pending && (oldestIndex < 0 ||
                slot.sequence < oldestSequence))
            {
                oldestIndex = cast(int) i;
                oldestSequence = slot.sequence;
            }
        }
        if (oldestIndex < 0) return;

        auto staging = &g_stagingSlots[oldestIndex];
        const byteCount = cast(size_t) g_stagingWidth * g_stagingHeight * 4;
        const cpuIndex = acquireCpuFrameSlot(byteCount);
        if (cpuIndex < 0) return;

        auto cpu = &g_cpuFrames[cpuIndex];
        D3D11_MAPPED_SUBRESOURCE mapped;
        const mapResult = context.lpVtbl.Map(context, staging.staging, 0,
            D3D11_MAP_READ, D3D11_MAP_FLAG_DO_NOT_WAIT, &mapped);
        if (mapResult != 0)
        {
            atomicExchange(cpu.state, frameSlotFree);
            return;
        }

        copyMappedFrame(mapped, g_stagingWidth, g_stagingHeight,
            g_stagingFormat, cpu.data);
        context.lpVtbl.Unmap(context, staging.staging, 0);

        cpu.width = g_stagingWidth;
        cpu.height = g_stagingHeight;
        cpu.sourceFormat = g_stagingFormat;
        cpu.sequence = staging.sequence;
        cpu.captureQpc = staging.captureQpc;
        staging.pending = false;
        atomicExchange(cpu.state, frameSlotReady);
        if (g_frameEvent !is null) SetEvent(g_frameEvent);
    }

    private void enqueueGpuCopy(ID3D11DeviceContextObj* context,
        void* backBuffer, uint sourceFormat, uint sampleCount,
        ulong captureQpc)
    {
        foreach (ref staging; g_stagingSlots)
        {
            if (staging.pending) continue;
            if (sampleCount > 1)
            {
                context.lpVtbl.ResolveSubresource(context, staging.resolve, 0,
                    backBuffer, 0, sourceFormat);
                context.lpVtbl.CopyResource(context, staging.staging,
                    staging.resolve);
            }
            else
                context.lpVtbl.CopyResource(context, staging.staging, backBuffer);
            staging.sequence = ++g_gpuSequence;
            staging.captureQpc = captureQpc;
            staging.pending = true;
            return;
        }
        atomicIncrement(g_droppedFrames);
    }

    private void captureFrame(IDXGISwapChainObj* swapchain, ulong captureQpc)
    {
        void* deviceRaw;
        if (swapchain.lpVtbl.GetDevice(swapchain, &IID_ID3D11Device,
            &deviceRaw) != 0 || deviceRaw is null)
            return;
        auto device = cast(ID3D11DeviceObj*) deviceRaw;
        bool retainedDevice;

        void* contextRaw;
        device.lpVtbl.GetImmediateContext(device, &contextRaw);
        auto context = cast(ID3D11DeviceContextObj*) contextRaw;
        if (context is null)
        {
            comRelease(device);
            return;
        }

        void* backBufferRaw;
        if (swapchain.lpVtbl.GetBuffer(swapchain, 0, &IID_ID3D11Texture2D,
            &backBufferRaw) != 0 || backBufferRaw is null)
        {
            comRelease(context);
            comRelease(device);
            return;
        }
        auto backBuffer = cast(ID3D11Texture2DObj*) backBufferRaw;
        D3D11_TEXTURE2D_DESC desc;
        backBuffer.lpVtbl.GetDesc(backBuffer, &desc);

        if (desc.Width == 0 || desc.Height == 0 ||
            cast(ulong) desc.Width * desc.Height * 4 > uint.max)
            goto cleanup;
        if (cast(ulong) desc.Width * desc.Height * 4 >
            gameCaptureSharedSlotStride)
        {
            reportFatal(GameCaptureError.sharedMemoryCapacityExceeded,
                desc.Format);
            goto cleanup;
        }
        if (!supportedFormat(desc.Format))
        {
            reportFatal(GameCaptureError.unsupportedSwapChainFormat,
                desc.Format);
            goto cleanup;
        }
        if (!ensureStagingResources(device, desc, retainedDevice))
        {
            reportFatal(GameCaptureError.stagingTextureFailed, desc.Format);
            goto cleanup;
        }

        drainReadyStaging(context);
        enqueueGpuCopy(context, backBufferRaw, desc.Format,
            desc.SampleDesc.Count, captureQpc);

    cleanup:
        comRelease(backBufferRaw);
        comRelease(contextRaw);
        if (!retainedDevice) comRelease(deviceRaw);
    }

    private bool writePipe(const(void)* data, size_t byteCount)
    {
        auto cursor = cast(const(ubyte)*) data;
        while (byteCount > 0)
        {
            const chunk = byteCount > uint.max ? uint.max :
                cast(uint) byteCount;
            DWORD written;
            if (WriteFile(g_pipeHandle, cursor, chunk, &written, null) == 0 ||
                written == 0)
                return false;
            cursor += written;
            byteCount -= written;
        }
        return true;
    }

    private void initializeHeader(ref GameCapturePacketHeader header,
        GameCaptureMessage message)
    {
        header.magic = gameCaptureMagic;
        header.protocolVersion = gameCaptureProtocolVersion;
        header.headerSize = gameCaptureHeaderSize;
        header.messageType = message;
        header.pixelFormat = GameCapturePixelFormat.none;
        header.captureQpcFrequency = g_qpcFrequency;
        header.droppedFrames = cast(uint)
            atomicCompareExchange(g_droppedFrames, 0, 0);
    }

    private bool writeStatus(GameCaptureMessage message,
        GameCaptureError error = GameCaptureError.none, uint sourceFormat = 0)
    {
        GameCapturePacketHeader header;
        initializeHeader(header, message);
        header.errorCode = error;
        header.sourceFormat = sourceFormat;
        return writePipe(&header, header.sizeof);
    }

    private int newestReadyFrame()
    {
        int result = -1;
        ulong newestSequence;
        foreach (i; 0 .. cpuFrameSlotCount)
        {
            auto slot = &g_cpuFrames[i];
            if (atomicCompareExchange(slot.state, frameSlotReady,
                frameSlotReady) == frameSlotReady &&
                (result < 0 || slot.sequence > newestSequence))
            {
                result = cast(int) i;
                newestSequence = slot.sequence;
            }
        }
        if (result < 0 ||
            atomicCompareExchange(g_cpuFrames[result].state,
                frameSlotWriting, frameSlotReady) != frameSlotReady)
            return -1;

        // Keep latency bounded: once the newest slot is claimed, older queued
        // frames are obsolete and become free without entering the pipe.
        foreach (i; 0 .. cpuFrameSlotCount)
        {
            if (cast(int) i == result) continue;
            auto slot = &g_cpuFrames[i];
            if (slot.sequence < newestSequence &&
                atomicCompareExchange(slot.state, frameSlotFree,
                    frameSlotReady) == frameSlotReady)
                atomicIncrement(g_droppedFrames);
        }
        return result;
    }

    private int acquireSharedFrameSlot()
    {
        if (g_sharedHeader is null) return -1;
        foreach (i; 0 .. gameCaptureSharedSlotCount)
        {
            if (atomicCompareExchange(g_sharedHeader.slotStates[i],
                GameCaptureSharedSlotState.filling,
                GameCaptureSharedSlotState.free) ==
                GameCaptureSharedSlotState.free)
                return cast(int) i;
        }
        return -1;
    }

    private bool writeNewestFrame()
    {
        const index = newestReadyFrame();
        if (index < 0) return true;
        auto slot = &g_cpuFrames[index];
        convertFrameToBgra(slot);
        const sharedIndex = acquireSharedFrameSlot();
        if (sharedIndex < 0)
        {
            atomicIncrement(g_droppedFrames);
            atomicExchange(slot.state, frameSlotFree);
            return true;
        }
        const byteCount = cast(size_t) slot.width * slot.height * 4;
        auto sharedPixels = cast(ubyte*) g_sharedView +
            gameCaptureSharedSlotOffset(cast(uint) sharedIndex);
        memcpy(sharedPixels, slot.data, byteCount);
        atomicExchange(g_sharedHeader.slotStates[sharedIndex],
            GameCaptureSharedSlotState.ready);

        GameCapturePacketHeader header;
        initializeHeader(header, GameCaptureMessage.frame);
        header.width = slot.width;
        header.height = slot.height;
        header.byteCount = cast(uint) byteCount;
        header.pixelFormat = GameCapturePixelFormat.bgra8;
        header.sequence = slot.sequence;
        header.captureQpc = slot.captureQpc;
        header.sourceFormat = slot.sourceFormat;
        header.sharedSlot = cast(uint) sharedIndex;
        const ok = writePipe(&header, header.sizeof);
        if (!ok)
            atomicExchange(g_sharedHeader.slotStates[sharedIndex],
                GameCaptureSharedSlotState.free);
        atomicExchange(slot.state, frameSlotFree);
        return ok;
    }

    private bool pipeAlive()
    {
        if (g_pipeHandle is null || g_pipeHandle == INVALID_HANDLE_VALUE)
            return false;
        DWORD available;
        return PeekNamedPipe(g_pipeHandle, null, 0, null, &available, null) != 0;
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
        version (GameCaptureDebug)
        {
            auto h = CreateFileA("C:\\temp\\gamecaphook_dbg.txt",
                GENERIC_WRITE, FILE_SHARE_READ, null, OPEN_ALWAYS,
                FILE_ATTRIBUTE_NORMAL, null);
            if (h == INVALID_HANDLE_VALUE) return;
            SetFilePointer(h, 0, null, FILE_END);
            DWORD written;
            WriteFile(h, text, cast(DWORD) strlen(text), &written, null);
            WriteFile(h, "\r\n".ptr, 2, &written, null);
            CloseHandle(h);
        }
    }

    private void appendText(char* buffer, size_t offset, string text)
    {
        foreach (i, c; text) buffer[offset + i] = cast(char) c;
        buffer[offset + text.length] = 0;
    }

    private void appendText(char* buffer, size_t offset, ulong value,
        string suffix)
    {
        char[24] digits;
        size_t n;
        if (value == 0) digits[n++] = '0';
        while (value > 0)
        {
            digits[n++] = cast(char) ('0' + value % 10);
            value /= 10;
        }
        foreach (i; 0 .. n) buffer[offset + i] = digits[n - 1 - i];
        foreach (i, c; suffix) buffer[offset + n + i] = cast(char) c;
        buffer[offset + n + suffix.length] = 0;
    }

    private bool readConfiguration()
    {
        const pid = GetCurrentProcessId();
        char[260] configPath;
        const tempLen = GetTempPathA(configPath.length, configPath.ptr);
        if (tempLen == 0 || tempLen >= configPath.length) return false;
        enum configPrefix = "aurora-gamecap-";
        appendText(configPath.ptr, tempLen, configPrefix);
        appendText(configPath.ptr, tempLen + configPrefix.length, pid, ".cfg");

        auto configFile = CreateFileA(configPath.ptr, GENERIC_READ,
            FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
        if (configFile == INVALID_HANDLE_VALUE) return false;
        char[768] config;
        DWORD configLen;
        const readOk = ReadFile(configFile, config.ptr, config.length,
            &configLen, null) != 0;
        CloseHandle(configFile);
        if (!readOk || configLen == 0) return false;

        const(char)* cur = config.ptr;
        const(char)* end = config.ptr + configLen;
        while (cur < end)
        {
            const(char)* lineStart = cur;
            while (cur < end && *cur != '\n' && *cur != '\r') ++cur;
            const(char)* lineEnd = cur;
            const(char)* eq = lineStart;
            while (eq < lineEnd && *eq != '=') ++eq;
            if (eq < lineEnd)
            {
                if (eq - lineStart == 4 &&
                    memcmp(lineStart, "hwnd".ptr, 4) == 0)
                    g_targetHwnd = parseDecimal(eq + 1);
                else if (eq - lineStart == 4 &&
                    memcmp(lineStart, "pipe".ptr, 4) == 0)
                {
                    const pipeLen = lineEnd - (eq + 1);
                    if (pipeLen > 0 && pipeLen < g_pipeName.length)
                    {
                        foreach (i; 0 .. pipeLen)
                            g_pipeName[i] = cast(wchar) (eq + 1)[i];
                        g_pipeName[pipeLen] = 0;
                    }
                }
                else if (eq - lineStart == 7 &&
                    memcmp(lineStart, "mapping".ptr, 7) == 0)
                {
                    const mappingLen = lineEnd - (eq + 1);
                    if (mappingLen > 0 && mappingLen < g_mappingName.length)
                    {
                        foreach (i; 0 .. mappingLen)
                            g_mappingName[i] = cast(wchar) (eq + 1)[i];
                        g_mappingName[mappingLen] = 0;
                    }
                }
            }
            while (cur < end && (*cur == '\n' || *cur == '\r')) ++cur;
        }
        return g_targetHwnd != 0 && g_pipeName[0] != 0 &&
            g_mappingName[0] != 0;
    }

    private extern(Windows) LRESULT dummyProc(HWND hwnd, uint msg,
        WPARAM wParam, LPARAM lParam) nothrow
    {
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    private bool installPresentHook(HINSTANCE hookInstance)
    {
        g_d3d11Module = LoadLibraryA("d3d11.dll");
        if (g_d3d11Module is null) return false;
        auto createDeviceAndSwapChain = cast(D3D11CreateDeviceAndSwapChainFn)
            GetProcAddress(g_d3d11Module, "D3D11CreateDeviceAndSwapChain");
        if (createDeviceAndSwapChain is null) return false;

        const className = "AuroraGameCapHook"w;
        WNDCLASSW wc;
        wc.lpfnWndProc = &dummyProc;
        wc.hInstance = hookInstance;
        wc.lpszClassName = className.ptr;
        if (RegisterClassW(&wc) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
            return false;
        HWND dummy = CreateWindowExW(0, className.ptr, className.ptr,
            WS_OVERLAPPEDWINDOW, -32_000, -32_000, 64, 64, null, null,
            hookInstance, null);
        if (dummy is null) return false;

        DXGI_SWAP_CHAIN_DESC scDesc;
        scDesc.BufferDesc.Width = 64;
        scDesc.BufferDesc.Height = 64;
        scDesc.BufferDesc.RefreshRate.Numerator = 60;
        scDesc.BufferDesc.RefreshRate.Denominator = 1;
        scDesc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        scDesc.SampleDesc.Count = 1;
        scDesc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        scDesc.BufferCount = 2;
        scDesc.OutputWindow = dummy;
        scDesc.Windowed = true;
        scDesc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

        void* swapchainRaw;
        void* deviceRaw;
        void* contextRaw;
        uint featureLevel;
        uint requestedLevel = D3D_FEATURE_LEVEL_11_0;
        auto result = createDeviceAndSwapChain(null, D3D_DRIVER_TYPE_HARDWARE,
            null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, &requestedLevel, 1,
            D3D11_SDK_VERSION, &scDesc, &swapchainRaw, &deviceRaw,
            &featureLevel, &contextRaw);
        if (result != 0)
            result = createDeviceAndSwapChain(null, D3D_DRIVER_TYPE_WARP,
                null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, &requestedLevel, 1,
                D3D11_SDK_VERSION, &scDesc, &swapchainRaw, &deviceRaw,
                &featureLevel, &contextRaw);

        bool installed;
        if (result == 0 && swapchainRaw !is null)
        {
            auto swapchain = cast(IDXGISwapChainObj*) swapchainRaw;
            auto vtable = swapchain.lpVtbl;
            if (vtable !is null && vtable.Present !is null)
            {
                g_originalPresent = vtable.Present;
                DWORD oldProtect;
                if (VirtualProtect(&vtable.Present, (vtable.Present).sizeof,
                    PAGE_READWRITE, &oldProtect) != 0)
                {
                    vtable.Present = &hookPresent;
                    DWORD ignored;
                    VirtualProtect(&vtable.Present, (vtable.Present).sizeof,
                        oldProtect, &ignored);
                    g_hookVtable = vtable;
                    atomicExchange(g_hookActive, 1);
                    installed = true;
                }
            }
        }

        comRelease(swapchainRaw);
        comRelease(contextRaw);
        comRelease(deviceRaw);
        DestroyWindow(dummy);
        UnregisterClassW(className.ptr, hookInstance);
        return installed;
    }

    private bool restorePresentHook()
    {
        if (!g_hookActive || g_hookVtable is null) return true;
        DWORD oldProtect;
        if (VirtualProtect(&g_hookVtable.Present,
            (g_hookVtable.Present).sizeof, PAGE_READWRITE, &oldProtect) == 0)
            return false;
        if (g_hookVtable.Present == &hookPresent)
            g_hookVtable.Present = g_originalPresent;
        DWORD ignored;
        VirtualProtect(&g_hookVtable.Present, (g_hookVtable.Present).sizeof,
            oldProtect, &ignored);
        atomicExchange(g_hookActive, 0);

        // The vtable no longer admits new calls. Allow any thread that already
        // fetched the old function pointer to enter, then wait for all tracked
        // calls to leave before the worker unloads this DLL.
        Sleep(50);
        const waitStart = GetTickCount();
        while ((atomicCompareExchange(g_captureBusy, 0, 0) != 0 ||
            atomicCompareExchange(g_hookCalls, 0, 0) != 0) &&
            GetTickCount() - waitStart < 5_000)
            Sleep(1);
        return atomicCompareExchange(g_captureBusy, 0, 0) == 0 &&
            atomicCompareExchange(g_hookCalls, 0, 0) == 0;
    }

    private bool openSharedFrames()
    {
        g_sharedMapping = OpenFileMappingW(FILE_MAP_ALL_ACCESS, false,
            g_mappingName.ptr);
        if (g_sharedMapping is null) return false;
        g_sharedView = MapViewOfFile(g_sharedMapping, FILE_MAP_ALL_ACCESS,
            0, 0, gameCaptureSharedMappingSize);
        if (g_sharedView is null) return false;
        g_sharedHeader = cast(GameCaptureSharedHeader*) g_sharedView;
        return validGameCaptureSharedHeader(*g_sharedHeader);
    }

    private bool runHook(HINSTANCE hookInstance)
    {
        hookDebug("setup: begin");
        LARGE_INTEGER frequency;
        if (QueryPerformanceFrequency(&frequency) == 0) return true;
        g_qpcFrequency = cast(ulong) frequency.QuadPart;
        if (!readConfiguration()) return true;

        // Duplex access lets this worker detect that the server disappeared
        // even while the game is paused and no Present call produces a frame.
        g_pipeHandle = CreateFileW(g_pipeName.ptr,
            GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
        if (g_pipeHandle == INVALID_HANDLE_VALUE)
        {
            g_pipeHandle = null;
            return true;
        }
        if (!openSharedFrames())
        {
            writeStatus(GameCaptureMessage.error,
                GameCaptureError.hookSetupFailed);
            return true;
        }
        g_frameEvent = CreateEventW(null, false, false, null);
        if (g_frameEvent is null)
        {
            writeStatus(GameCaptureMessage.error,
                GameCaptureError.hookSetupFailed);
            return true;
        }
        if (!installPresentHook(hookInstance))
        {
            writeStatus(GameCaptureMessage.error,
                GameCaptureError.hookSetupFailed);
            return true;
        }
        if (!writeStatus(GameCaptureMessage.ready)) return true;
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
        hookDebug("setup: ready");

        while (atomicCompareExchange(g_stopCapturing, 0, 0) == 0)
        {
            const fatal = cast(GameCaptureError)
                atomicCompareExchange(g_fatalError, 0, 0);
            if (fatal != GameCaptureError.none)
            {
                writeStatus(GameCaptureMessage.error, fatal,
                    cast(uint) atomicCompareExchange(
                        g_fatalSourceFormat, 0, 0));
                break;
            }
            if (!writeNewestFrame()) break;
            WaitForSingleObject(g_frameEvent, 100);
            if (!pipeAlive()) break;
        }
        return true;
    }

    private bool cleanupHook()
    {
        atomicExchange(g_stopCapturing, 1);
        const safeToUnload = restorePresentHook();
        // If a driver call is stuck inside the hook, leaking this small module
        // and its resources until game exit is safer than freeing memory that
        // an in-flight Present can still touch.
        if (!safeToUnload) return false;
        resetStagingResources();
        foreach (ref slot; g_cpuFrames)
        {
            if (slot.data !is null)
                HeapFree(GetProcessHeap(), 0, slot.data);
            slot = CpuFrameSlot.init;
        }
        if (g_frameEvent !is null) CloseHandle(g_frameEvent);
        g_frameEvent = null;
        g_sharedHeader = null;
        if (g_sharedView !is null) UnmapViewOfFile(g_sharedView);
        g_sharedView = null;
        if (g_sharedMapping !is null) CloseHandle(g_sharedMapping);
        g_sharedMapping = null;
        if (g_pipeHandle !is null && g_pipeHandle != INVALID_HANDLE_VALUE)
            CloseHandle(g_pipeHandle);
        g_pipeHandle = null;
        if (g_d3d11Module !is null) FreeLibrary(g_d3d11Module);
        g_d3d11Module = null;
        return safeToUnload;
    }

    private extern(Windows) DWORD setupThreadProc(void* parameter)
    {
        auto hookInstance = cast(HINSTANCE) parameter;
        runHook(hookInstance);
        const safeToUnload = cleanupHook();
        if (safeToUnload)
            FreeLibraryAndExitThread(hookInstance, 0);
        return 0;
    }
}

/// Custom DLL entry point. Loader work stays minimal; D3D11 and pipe setup run
/// on the worker after the loader lock is released.
extern(C) BOOL gamecaphookEntry(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    version (Windows)
    {
        if (reason == DLL_PROCESS_ATTACH)
        {
            DisableThreadLibraryCalls(hinst);
            auto thread = CreateThread(null, 0, &setupThreadProc,
                cast(void*) hinst, 0, null);
            if (thread !is null) CloseHandle(thread);
        }
        else if (reason == DLL_PROCESS_DETACH)
        {
            atomicExchange(g_stopCapturing, 1);
            if (g_frameEvent !is null) SetEvent(g_frameEvent);
        }
    }
    return true;
}
