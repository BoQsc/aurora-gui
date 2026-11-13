module aurorarecorder.loopback;

/**
 * System ("screen") audio capture through WASAPI loopback.
 *
 * ffmpeg is deliberately not used for this: the bundled build has no `wasapi`
 * input device, and this class of machine may expose no "Stereo Mix" recording
 * device, so neither `dshow` nor `openal` can see what the speakers play.
 * WASAPI loopback opens the default *output* endpoint in loopback mode, which
 * every Windows audio device supports, and yields the same samples that are
 * being played.
 *
 * The vtables below are declared locally (the repo's "declare missing Win32
 * prototypes locally" rule) because druntime ships no WASAPI bindings. Calls
 * are kept explicit rather than using COM helpers so the exact ABI is visible.
 */

import core.atomic : MemoryOrder, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread, dur;

version (Windows)
{
    import core.sys.windows.windows;
    import core.sys.windows.com : CoInitializeEx, CoUninitialize,
        CoCreateInstance, CLSCTX_ALL;
    import core.sys.windows.objbase : CoTaskMemFree;
}

/// Audio format negotiated with the output device.
struct LoopbackFormat
{
    uint sampleRate;
    uint channels;

    bool valid() const pure nothrow @safe
    {
        return sampleRate > 0 && channels > 0;
    }
}

version (Windows)
{
    // ---- Minimal WASAPI declarations -------------------------------------

    private enum uint CLSCTX_ALL_VALUE = 23;
    private enum int COINIT_MULTITHREADED_VALUE = 0;
    private enum uint AUDCLNT_SHAREMODE_SHARED = 0;
    private enum uint AUDCLNT_STREAMFLAGS_LOOPBACK = 0x00020000;
    private enum uint AUDCLNT_BUFFERFLAGS_SILENT = 0x2;
    private enum uint WAVE_FORMAT_IEEE_FLOAT = 3;
    private enum uint WAVE_FORMAT_EXTENSIBLE = 0xFFFE;
    private enum uint KSDATAFORMAT_SUBTYPE_IEEE_FLOAT_TAIL = 3;

    private enum uint eRender = 0;
    private enum uint eConsole = 0;
    private enum uint devstateActive = 1;

    private struct WAVEFORMATEX
    {
        ushort wFormatTag;
        ushort nChannels;
        uint nSamplesPerSec;
        uint nAvgBytesPerSec;
        ushort nBlockAlign;
        ushort wBitsPerSample;
        ushort cbSize;
    }

    private struct WAVEFORMATEXTENSIBLE
    {
        WAVEFORMATEX Format;
        ushort wValidBitsPerSample;
        uint dwChannelMask;
        // The subtype GUID's Data1 field carries the format tag (3 = IEEE
        // float); the remaining GUID bytes are the fixed tail, so only Data1
        // has to be compared.
        GUID subFormat;
    }

    /// `GUID` has no array initialiser here, so Data4 is filled explicitly:
    /// an unset Data4 hands COM a corrupt IID (an immediate access violation).
    private GUID makeGuid(uint data1, ushort data2, ushort data3,
        ubyte[8] data4) pure nothrow @safe
    {
        GUID guid;
        guid.Data1 = data1;
        guid.Data2 = data2;
        guid.Data3 = data3;
        guid.Data4[0] = data4[0];
        guid.Data4[1] = data4[1];
        guid.Data4[2] = data4[2];
        guid.Data4[3] = data4[3];
        guid.Data4[4] = data4[4];
        guid.Data4[5] = data4[5];
        guid.Data4[6] = data4[6];
        guid.Data4[7] = data4[7];
        return guid;
    }

    // IID_IMMDeviceEnumerator  {A95664D2-9614-4F35-A746-DE8DB63617E6}
    // IID_IAudioClient           {1CB9AD4C-DBFA-4c32-B178-C2F568A703B2}
    // CLSID_MMDeviceEnumerator   {BCDE0395-E52F-467C-8E3D-C4579291692E}
    // IID_IAudioCaptureClient    {C8ADBD64-E71E-48A0-A4DE-185C395CD317}
    private __gshared GUID iidDeviceEnumerator = makeGuid(0xA95664D2, 0x9614,
        0x4F35, [0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6]);
    private __gshared GUID iidAudioClient = makeGuid(0x1CB9AD4C, 0xDBFA, 0x4C32,
        [0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2]);
    private __gshared GUID clsidMMDeviceEnumerator = makeGuid(0xBCDE0395,
        0xE52F, 0x467C, [0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E]);
    private __gshared GUID iidCaptureClient = makeGuid(0xC8ADBD64, 0xE71E,
        0x48A0, [0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17]);

    // COM call signatures: index into the vtable, `this` first.
    private alias QueryInterfaceFn = extern(Windows) HRESULT function(
        void* self, const(GUID)* iid, void** result);
    private alias ReleaseFn = extern(Windows) uint function(void* self);
    private alias GetDefaultAudioEndpointFn = extern(Windows) HRESULT function(
        void* self, uint dataFlow, uint role, void** device);
    private alias ActivateFn = extern(Windows) HRESULT function(void* self,
        const(GUID)* iid, uint clsctx, void* activationParams, void** result);
    private alias InitializeFn = extern(Windows) HRESULT function(void* self,
        uint shareMode, uint streamFlags, long bufferDuration, long periodicity,
        const(WAVEFORMATEX)* format, const(GUID)* sessionGuid);
    private alias GetMixFormatFn = extern(Windows) HRESULT function(
        void* self, WAVEFORMATEX** format);
    private alias GetBufferSizeFn = extern(Windows) HRESULT function(
        void* self, uint* frames);
    private alias GetServiceFn = extern(Windows) HRESULT function(void* self,
        const(GUID)* iid, void** result);
    private alias StartFn = extern(Windows) HRESULT function(void* self);
    private alias StopFn = extern(Windows) HRESULT function(void* self);
    private alias GetCurrentPaddingFn = extern(Windows) HRESULT function(
        void* self, uint* frames);
    // `GetBuffer(BYTE** ppData, UINT32* pNumFramesToRead, DWORD* pdwFlags,
    // UINT64* pu64DevicePosition, UINT64* pu64QPCPosition)`.
    private alias GetBufferFn = extern(Windows) HRESULT function(void* self,
        ubyte** data, uint* frames, uint* flags, ulong* devicePosition,
        ulong* qpcPosition);
    private alias ReleaseBufferFn = extern(Windows) HRESULT function(
        void* self, uint frames);

    private void* vtableEntry(void* object, size_t index) nothrow
    {
        return (cast(void**) *cast(void***) object)[index];
    }

    private uint comRelease(void* object)
    {
        if (object is null) return 0;
        return (cast(ReleaseFn) vtableEntry(object, 2))(object);
    }


    /// Reference-time units per second (100 ns ticks).
    private enum long refTimesPerSecond = 10_000_000;
}

/**
 * Captures the default output device in loopback mode on its own thread.
 *
 * `start` returns false when no output device exists or COM failed, so a
 * recording can continue without sound rather than failing.
 */
version (Windows)
final class SystemAudioCapture
{
    private Thread _thread;
    private Mutex _lock;
    private shared bool _stop;
    private bool _failed;
    private ubyte[] _pending;
    private LoopbackFormat _format;
    private string _error;

    this()
    {
        _lock = new Mutex();
    }

    /// Begin capturing; false when the device could not be opened.
    bool start()
    {
        _thread = new Thread({ runLoop(); });
        _thread.isDaemon = true;
        _thread.start();
        // Wait for the device handshake so the caller knows whether the
        // recording will carry sound.
        foreach (_; 0 .. 300)
        {
            synchronized (_lock)
            {
                if (_failed || _format.valid()) break;
            }
            Thread.sleep(dur!"msecs"(10));
        }
        bool ready;
        synchronized (_lock) ready = !_failed && _format.valid();
        // A failed or timed-out handshake must not leave a capture thread
        // running for the rest of the process; it exits at its next stop check.
        if (!ready) requestStop();
        return ready;
    }

    LoopbackFormat format()
    {
        synchronized (_lock) return _format;
    }

    string errorText()
    {
        synchronized (_lock) return _error;
    }

    /// Ask the capture thread to stop; it finishes its current packet.
    void requestStop()
    {
        atomicStore!(MemoryOrder.rel)(_stop, true);
    }

    /// Stop and wait for the device to be released.
    void shutdown()
    {
        requestStop();
        if (_thread !is null) _thread.join();
        _thread = null;
    }

    /// Audio captured since the last call (empty when nothing is ready).
    ubyte[] take()
    {
        synchronized (_lock)
        {
            if (_pending.length == 0) return null;
            ubyte[] data = _pending;
            _pending = null;
            return data;
        }
    }

    private void fail(string message)
    {
        synchronized (_lock)
        {
            _failed = true;
            _error = message;
        }
    }

    private void append(const(ubyte)[] data)
    {
        synchronized (_lock) _pending ~= data;
    }

    private void runLoop()
    {
        // Every COM call for the device happens on this thread.
        if (CoInitializeEx(null, COINIT_MULTITHREADED_VALUE) < 0)
        {
            fail("Windows audio (WASAPI) could not be initialized.");
            return;
        }
        scope (exit) CoUninitialize();

        void* enumerator;
        if (CoCreateInstance(&clsidMMDeviceEnumerator, null, CLSCTX_ALL_VALUE,
                &iidDeviceEnumerator, &enumerator) < 0 || enumerator is null)
        {
            fail("The Windows audio device list is unavailable.");
            return;
        }
        scope (exit) comRelease(enumerator);

        void* endpoint;
        {
            auto get = cast(GetDefaultAudioEndpointFn) vtableEntry(enumerator, 4);
            if (get(enumerator, eRender, eConsole, &endpoint) < 0 ||
                endpoint is null)
            {
                fail("No audio output device is available, so screen sound " ~
                    "cannot be recorded.");
                return;
            }
        }
        scope (exit) comRelease(endpoint);

        void* client;
        {
            auto activate = cast(ActivateFn) vtableEntry(endpoint, 3);
            if (activate(endpoint, &iidAudioClient, CLSCTX_ALL_VALUE, null,
                    &client) < 0 || client is null)
            {
                fail("The audio output device does not support recording.");
                return;
            }
        }
        scope (exit) comRelease(client);

        WAVEFORMATEX* mixFormat;
        const formatHr = (cast(GetMixFormatFn) vtableEntry(client, 8))(client,
            &mixFormat);
        if (formatHr < 0 || mixFormat is null)
        {
            fail("The audio output format could not be read.");
            return;
        }
        scope (exit) CoTaskMemFree(mixFormat);

        LoopbackFormat format;
        format.sampleRate = mixFormat.nSamplesPerSec;
        format.channels = mixFormat.nChannels;

        // For WAVE_FORMAT_EXTENSIBLE the 16-byte SubFormat GUID starts at
        // offset 24 (after the 18-byte WAVEFORMATEX, wValidBits and channel
        // mask) and its first four bytes carry the format tag. Reading it as a
        // D `GUID` field is unreliable across druntime versions, so the bytes
        // are compared directly.
        uint subTag;
        bool isFloat;
        if (mixFormat.wFormatTag == WAVE_FORMAT_IEEE_FLOAT)
        {
            isFloat = true;
        }
        else if (mixFormat.wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
            mixFormat.cbSize >= 22)
        {
            import core.stdc.string : memcpy;
            memcpy(&subTag, (cast(const(ubyte)*) mixFormat) + 24,
                uint.sizeof);
            isFloat = subTag == WAVE_FORMAT_IEEE_FLOAT;
        }
        // ffmpeg will treat the input as f32le, so refuse anything else rather
        // than writing mislabelled samples.
        if (!isFloat || format.sampleRate == 0 || format.channels == 0)
        {
            fail("The audio output format is not supported for capture.");
            return;
        }

        // 200 ms shared buffer, the usual loopback choice.
        const long bufferDuration = 2 * refTimesPerSecond;
        auto initialize = cast(InitializeFn) vtableEntry(client, 3);
        const initHr = initialize(client, AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_LOOPBACK, bufferDuration, 0, mixFormat, null);
        if (initHr < 0)
        {
            fail("The audio output device could not be opened for recording.");
            return;
        }

        void* capture;
        const serviceHr = (cast(GetServiceFn) vtableEntry(client, 14))(client,
            &iidCaptureClient, &capture);
        if (serviceHr < 0 || capture is null)
        {
            fail("Screen sound capture is not supported by this device.");
            return;
        }
        scope (exit) comRelease(capture);

        const startHr = (cast(StartFn) vtableEntry(client, 10))(client);
        if (startHr < 0)
        {
            fail("Screen sound capture could not start.");
            return;
        }
        // Publish the format only once the device is actually running:
        // `start()` uses this as its success handshake, and it must not return
        // true for a device that then fails at Start, leaving ffmpeg waiting
        // forever for an audio input that never produces samples.
        synchronized (_lock) _format = format;
        scope (exit)
        {
            (cast(StopFn) vtableEntry(client, 11))(client);
        }

        foreach (packet; 0 .. 3)
        {
            // Prime the loop; loopback delivers nothing until frames play.
            Thread.sleep(dur!"msecs"(20));
            drain(capture);
            if (packet >= 1) break;
        }

        while (!atomicLoad_stop())
        {
            drain(capture);
            Thread.sleep(dur!"msecs"(10));
        }
        drain(capture); // keep the tail that is still buffered
    }

    private bool atomicLoad_stop()
    {
        import core.atomic : atomicLoad;
        return atomicLoad!(MemoryOrder.acq)(_stop);
    }

    /// Read every available packet from the capture client.
    private void drain(void* capture)
    {
        auto getNext = cast(GetBufferFn) vtableEntry(capture, 3);
        auto releaseBuffer = cast(ReleaseBufferFn) vtableEntry(capture, 4);
        foreach (_; 0 .. 64)
        {
            ubyte* data;
            uint frames;
            uint flags;
            if (getNext(capture, &data, &frames, &flags, null, null) < 0)
                return;
            if (frames == 0) return;
            if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0)
            {
                // Silence still advances time; feed zeroes so the audio track
                // keeps pace with the video.
                ubyte[] zeros;
                zeros.length = _format.channels * 4 * frames;
                append(zeros);
            }
            else if (data !is null)
            {
                append(data[0 .. _format.channels * 4 * frames]);
            }
            releaseBuffer(capture, frames);
        }
    }
}

else
final class SystemAudioCapture
{
    bool start() { return false; }
    LoopbackFormat format() { return LoopbackFormat.init; }
    string errorText() { return "Screen audio is only available on Windows."; }
    void requestStop() {}
    void shutdown() {}
    ubyte[] take() { return null; }
}
