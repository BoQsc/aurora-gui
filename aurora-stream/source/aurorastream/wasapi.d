module aurorastream.wasapi;

import aurorastream.audioendpoint : AudioEndpoint;
import core.thread : Thread;
import core.time : msecs;
import std.file : exists, write;
import std.format : format;
import std.socket : AddressFamily, InternetAddress, Socket, UdpSocket;
import std.string : strip;
import std.utf : toUTF16z, toUTF8;

struct WasapiRtpMetrics
{
    bool synthetic;
    bool mmcssEnabled;
    ulong packetsCaptured;
    ulong capturedFramesQueued;
    ulong rtpPacketsSent;
    ulong audioFramesSent;
    ulong silentFramesSent;
    ulong framesDroppedOnOverflow;
    ulong staleFramesDiscarded;
    ulong pacingFramesSkipped;
    ulong startupDiscontinuities;
    ulong discontinuities;
    ulong sendFailures;
    ulong maximumPacketGapMilliseconds;
    ulong maximumCaptureDurationMicroseconds;
    ulong maximumSendDurationMicroseconds;
    ulong maximumRingDepthFrames;
    ulong eventWakeups;
    ulong eventTimeouts;
    ulong outputIntervals;
    uint rtpSourcePort;
    uint rtpDestinationPort;

    string text() const
    {
        return format(
            "mode=%s\r\n" ~
            "mmcss_enabled=%s\r\n" ~
            "packets_captured=%s\r\n" ~
            "captured_frames_queued=%s\r\n" ~
            "rtp_packets_sent=%s\r\n" ~
            "audio_frames_sent=%s\r\n" ~
            "silent_frames_sent=%s\r\n" ~
            "frames_dropped_on_overflow=%s\r\n" ~
            "stale_frames_discarded=%s\r\n" ~
            "pacing_frames_skipped=%s\r\n" ~
            "startup_discontinuities=%s\r\n" ~
            "discontinuities=%s\r\n" ~
            "send_failures=%s\r\n" ~
            "maximum_packet_gap_ms=%s\r\n" ~
            "maximum_capture_duration_us=%s\r\n" ~
            "maximum_send_duration_us=%s\r\n" ~
            "maximum_ring_depth_frames=%s\r\n" ~
            "event_wakeups=%s\r\n" ~
            "event_timeouts=%s\r\n" ~
            "output_intervals=%s\r\n" ~
            "rtp_source_port=%s\r\n" ~
            "rtp_destination_port=%s\r\n",
            synthetic ? "synthetic-rtp" : "wasapi-rtp", mmcssEnabled,
            packetsCaptured, capturedFramesQueued, rtpPacketsSent,
            audioFramesSent, silentFramesSent, framesDroppedOnOverflow,
            staleFramesDiscarded, pacingFramesSkipped,
            startupDiscontinuities, discontinuities,
            sendFailures, maximumPacketGapMilliseconds,
            maximumCaptureDurationMicroseconds, maximumSendDurationMicroseconds,
            maximumRingDepthFrames, eventWakeups, eventTimeouts, outputIntervals,
            rtpSourcePort, rtpDestinationPort);
    }
}

version (Windows)
{
    pragma(lib, "ole32");
    pragma(lib, "avrt");
    static assert(size_t.sizeof == 8,
        "Aurora Stream currently requires an x86_64 Windows build.");

    private alias HRESULT = int;
    private alias ULONG = uint;
    private alias DWORD = uint;
    private alias UINT = uint;
    private alias UINT32 = uint;
    private alias UINT64 = ulong;
    private alias WORD = ushort;
    private alias BYTE = ubyte;
    private alias BOOL = int;
    private alias HANDLE = void*;
    private alias REFERENCE_TIME = long;

    private struct Guid
    {
        uint data1;
        ushort data2;
        ushort data3;
        ubyte[8] data4;
    }

    private pure nothrow @nogc Guid makeGuid(uint data1, ushort data2,
        ushort data3, ubyte b0, ubyte b1, ubyte b2, ubyte b3,
        ubyte b4, ubyte b5, ubyte b6, ubyte b7)
    {
        Guid result;
        result.data1 = data1;
        result.data2 = data2;
        result.data3 = data3;
        result.data4[0] = b0;
        result.data4[1] = b1;
        result.data4[2] = b2;
        result.data4[3] = b3;
        result.data4[4] = b4;
        result.data4[5] = b5;
        result.data4[6] = b6;
        result.data4[7] = b7;
        return result;
    }

    private immutable Guid clsidMMDeviceEnumerator = makeGuid(
        0xbcde0395, 0xe52f, 0x467c,
        0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e);
    private immutable Guid iidIMMDeviceEnumerator = makeGuid(
        0xa95664d2, 0x9614, 0x4f35,
        0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6);
    private immutable Guid iidIAudioClient = makeGuid(
        0x1cb9ad4c, 0xdbfa, 0x4c32,
        0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2);
    private immutable Guid iidIAudioCaptureClient = makeGuid(
        0xc8adbd64, 0xe71e, 0x48a0,
        0xa4, 0xde, 0x18, 0x5c, 0x39, 0x5c, 0xd3, 0x17);
    private immutable Guid pkeyDeviceFriendlyNameGuid = makeGuid(
        0xa45c254e, 0xdf1c, 0x4efd,
        0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0);

    private struct PropertyKey
    {
        Guid formatId;
        uint propertyId;
    }

    private immutable PropertyKey pkeyDeviceFriendlyName =
        PropertyKey(pkeyDeviceFriendlyNameGuid, 14);

    private union PropVariantValue
    {
        wchar* wideString;
        void* pointer;
        ulong[2] storage;
    }

    private struct PropVariant
    {
        ushort valueType;
        ushort reserved1;
        ushort reserved2;
        ushort reserved3;
        PropVariantValue value;
    }

    private struct WaveFormatEx
    {
        align(1):
        ushort formatTag;
        ushort channels;
        uint samplesPerSecond;
        uint averageBytesPerSecond;
        ushort blockAlign;
        ushort bitsPerSample;
        ushort extraSize;
    }

    static assert(PropVariant.sizeof == 24);
    static assert(WaveFormatEx.sizeof == 18);

    extern (Windows)
    {
        alias UnknownRelease = ULONG function(void* object);
        alias EnumeratorEnumAudioEndpoints = HRESULT function(void* object,
            int dataFlow, DWORD stateMask, void** collection);
        alias EnumeratorGetDefaultAudioEndpoint = HRESULT function(void* object,
            int dataFlow, int role, void** endpoint);
        alias EnumeratorGetDevice = HRESULT function(void* object,
            const(wchar)* endpointId, void** endpoint);
        alias CollectionGetCount = HRESULT function(void* object, UINT* count);
        alias CollectionItem = HRESULT function(void* object, UINT index,
            void** endpoint);
        alias DeviceActivate = HRESULT function(void* object, const Guid* iid,
            DWORD classContext, PropVariant* activationParameters, void** result);
        alias DeviceOpenPropertyStore = HRESULT function(void* object,
            DWORD access, void** propertyStore);
        alias DeviceGetId = HRESULT function(void* object, wchar** endpointId);
        alias PropertyStoreGetValue = HRESULT function(void* object,
            const PropertyKey* key, PropVariant* value);
        alias AudioClientInitialize = HRESULT function(void* object,
            int shareMode, DWORD streamFlags, REFERENCE_TIME bufferDuration,
            REFERENCE_TIME periodicity, const WaveFormatEx* audioFormat,
            const Guid* sessionGuid);
        alias AudioClientStart = HRESULT function(void* object);
        alias AudioClientStop = HRESULT function(void* object);
        alias AudioClientSetEventHandle = HRESULT function(void* object,
            HANDLE eventHandle);
        alias AudioClientGetService = HRESULT function(void* object,
            const Guid* iid, void** service);
        alias CaptureGetBuffer = HRESULT function(void* object, BYTE** data,
            UINT32* frames, DWORD* flags, UINT64* devicePosition,
            UINT64* performanceCounterPosition);
        alias CaptureReleaseBuffer = HRESULT function(void* object,
            UINT32 frames);
        alias CaptureGetNextPacketSize = HRESULT function(void* object,
            UINT32* frames);

        HRESULT CoInitializeEx(void* reserved, DWORD concurrencyModel);
        void CoUninitialize();
        HRESULT CoCreateInstance(const Guid* classId, void* outer,
            DWORD classContext, const Guid* interfaceId, void** result);
        void CoTaskMemFree(void* memory);
        HRESULT PropVariantClear(PropVariant* value);

        ulong GetTickCount64();
        BOOL QueryPerformanceCounter(long* value);
        BOOL QueryPerformanceFrequency(long* value);
        HANDLE CreateEventW(void* eventAttributes, BOOL manualReset,
            BOOL initialState, const(wchar)* name);
        DWORD WaitForSingleObject(HANDLE handle, DWORD milliseconds);
        BOOL CloseHandle(HANDLE handle);
        HANDLE AvSetMmThreadCharacteristicsW(const(wchar)* taskName,
            DWORD* taskIndex);
        BOOL AvSetMmThreadPriority(HANDLE avrtHandle, int priority);
        BOOL AvRevertMmThreadCharacteristics(HANDLE avrtHandle);
    }

    private enum DWORD coinitMultithreaded = 0x0;
    private enum DWORD classContextAll = 0x17;
    private enum DWORD deviceStateActive = 0x1;
    private enum int dataFlowRender = 0;
    private enum int roleMultimedia = 1;
    private enum DWORD storageRead = 0;
    private enum ushort variantWideString = 31;

    private enum ushort waveFormatPcm = 0x0001;
    private enum int audioClientShareModeShared = 0;
    private enum DWORD audioClientStreamFlagLoopback = 0x00020000;
    private enum DWORD audioClientStreamFlagEventCallback = 0x00040000;
    private enum DWORD audioClientStreamFlagAutoConvertPcm = 0x80000000;
    private enum DWORD audioClientStreamFlagSrcDefaultQuality = 0x08000000;
    private enum DWORD audioClientBufferFlagDataDiscontinuity = 0x00000001;
    private enum DWORD audioClientBufferFlagSilent = 0x00000002;
    private enum int avrtPriorityHigh = 1;
    private enum DWORD waitObject0 = 0x00000000;
    private enum DWORD waitTimeout = 0x00000102;
    private enum DWORD waitFailed = 0xffffffff;
    private enum uint outputChunkFrames = 960;
    private enum ulong outputIntervalMicroseconds = 20_000;
    private enum ulong outputCatchUpWindowMicroseconds = 100_000;
    private enum size_t ringCapacityFrames = 9_600;
    private enum size_t ringRecoveryFrames = 1_920;

    private bool succeeded(HRESULT result)
    {
        return result >= 0;
    }

    /**
     * Register the helper's only capture/output thread with MMCSS. Keeping this
     * thread below normal process priority made it the first work to be starved
     * by desktop capture, color conversion, or an encoder spike—the exact
     * conditions under which audio must keep its 20 ms cadence.
     *
     * MMCSS registration is best-effort so an unavailable Windows service does
     * not prevent streaming. The result is exported in helper metrics and the
     * quality diagnostic rejects an unregistered run.
     */
    private struct MmcssRegistration
    {
        HANDLE handle;

        @property bool active() const
        {
            return handle !is null;
        }

        void activate()
        {
            DWORD taskIndex;
            handle = AvSetMmThreadCharacteristicsW(toUTF16z("Audio"),
                &taskIndex);
            if (handle !is null &&
                AvSetMmThreadPriority(handle, avrtPriorityHigh) == 0)
            {
                AvRevertMmThreadCharacteristics(handle);
                handle = null;
            }
        }

        void close()
        {
            if (handle !is null)
                AvRevertMmThreadCharacteristics(handle);
            handle = null;
        }
    }

    private string hresultText(string operation, HRESULT result)
    {
        return format("%s failed with HRESULT 0x%08X", operation,
            cast(uint) result);
    }

    private void checkResult(string operation, HRESULT result)
    {
        if (!succeeded(result))
            throw new Exception(hresultText(operation, result));
    }

    private void* methodPointer(void* object, size_t slot)
    {
        if (object is null) return null;
        return (*cast(void***) object)[slot];
    }

    private void releaseCom(ref void* object)
    {
        if (object is null) return;
        auto release = cast(UnknownRelease) methodPointer(object, 2);
        if (release !is null) release(object);
        object = null;
    }

    private string widePointerToUtf8(const(wchar)* value)
    {
        if (value is null) return "";
        size_t length;
        while (value[length] != 0) ++length;
        if (length == 0) return "";
        return toUTF8(value[0 .. length]).idup;
    }

    private string endpointId(void* device)
    {
        wchar* value;
        auto getId = cast(DeviceGetId) methodPointer(device, 5);
        checkResult("IMMDevice.GetId", getId(device, &value));
        scope (exit) if (value !is null) CoTaskMemFree(value);
        return widePointerToUtf8(value);
    }

    private string endpointFriendlyName(void* device)
    {
        void* propertyStore;
        auto openStore = cast(DeviceOpenPropertyStore) methodPointer(device, 4);
        checkResult("IMMDevice.OpenPropertyStore",
            openStore(device, storageRead, &propertyStore));
        scope (exit) releaseCom(propertyStore);

        PropVariant value;
        auto getValue = cast(PropertyStoreGetValue)
            methodPointer(propertyStore, 5);
        checkResult("IPropertyStore.GetValue",
            getValue(propertyStore, &pkeyDeviceFriendlyName, &value));
        scope (exit) PropVariantClear(&value);

        if (value.valueType != variantWideString ||
            value.value.wideString is null)
            return "";
        return widePointerToUtf8(value.value.wideString);
    }

    private void assignDistinctLabels(ref AudioEndpoint[] devices)
    {
        foreach (index; 0 .. devices.length)
        {
            size_t total;
            size_t occurrence;
            foreach (otherIndex; 0 .. devices.length)
            {
                if (devices[otherIndex].displayName !=
                    devices[index].displayName) continue;
                ++total;
                if (otherIndex <= index) ++occurrence;
            }

            string label = total > 1 ?
                format("%s — device %s", devices[index].displayName,
                    occurrence) : devices[index].displayName;
            if (devices[index].alternativeName == "default")
                label ~= " — default";
            devices[index].label = label;
        }
    }

    AudioEndpoint[] enumerateWasapiRenderEndpoints(out string error)
    {
        error = "";
        AudioEndpoint[] result;
        bool comInitialized;
        void* enumerator;
        void* collection;
        void* defaultDevice;
        string defaultId;

        try
        {
            checkResult("CoInitializeEx",
                CoInitializeEx(null, coinitMultithreaded));
            comInitialized = true;

            checkResult("CoCreateInstance(MMDeviceEnumerator)",
                CoCreateInstance(&clsidMMDeviceEnumerator, null,
                    classContextAll, &iidIMMDeviceEnumerator, &enumerator));

            auto getDefault = cast(EnumeratorGetDefaultAudioEndpoint)
                methodPointer(enumerator, 4);
            if (succeeded(getDefault(enumerator, dataFlowRender,
                roleMultimedia, &defaultDevice)) && defaultDevice !is null)
            {
                try defaultId = endpointId(defaultDevice);
                catch (Exception) {}
            }

            auto enumerate = cast(EnumeratorEnumAudioEndpoints)
                methodPointer(enumerator, 3);
            checkResult("IMMDeviceEnumerator.EnumAudioEndpoints",
                enumerate(enumerator, dataFlowRender, deviceStateActive,
                    &collection));

            UINT count;
            auto getCount = cast(CollectionGetCount)
                methodPointer(collection, 3);
            checkResult("IMMDeviceCollection.GetCount",
                getCount(collection, &count));

            auto item = cast(CollectionItem) methodPointer(collection, 4);
            foreach (index; 0 .. count)
            {
                void* device;
                try
                {
                    checkResult("IMMDeviceCollection.Item",
                        item(collection, index, &device));
                    const id = endpointId(device).strip().idup;
                    auto name = endpointFriendlyName(device).strip().idup;
                    if (name.length == 0) name = "Windows playback device";
                    if (id.length == 0) continue;

                    AudioEndpoint endpoint;
                    endpoint.displayName = name;
                    endpoint.inputName = id;
                    endpoint.alternativeName = id == defaultId ?
                        "default" : "WASAPI render endpoint";
                    result ~= endpoint;
                }
                catch (Exception deviceError)
                {
                    if (error.length == 0)
                        error = "One Windows playback endpoint could not be read: " ~
                            deviceError.msg;
                }
                finally
                {
                    releaseCom(device);
                }
            }
            assignDistinctLabels(result);
        }
        catch (Exception scanError)
        {
            error = "Could not enumerate Windows playback endpoints: " ~
                scanError.msg;
        }
        finally
        {
            releaseCom(defaultDevice);
            releaseCom(collection);
            releaseCom(enumerator);
            if (comInitialized) CoUninitialize();
        }
        return result;
    }

    private ulong clockMicroseconds(long frequency)
    {
        if (frequency <= 0) return GetTickCount64() * 1000UL;
        long counter;
        if (QueryPerformanceCounter(&counter) == 0 || counter < 0)
            return GetTickCount64() * 1000UL;
        const whole = counter / frequency;
        const remainder = counter % frequency;
        return cast(ulong) whole * 1_000_000UL +
            cast(ulong) remainder * 1_000_000UL /
                cast(ulong) frequency;
    }

    private void writeU16BigEndian(ref ubyte[] target, size_t offset,
        ushort value)
    {
        target[offset] = cast(ubyte)(value >> 8);
        target[offset + 1] = cast(ubyte)(value & 0xff);
    }

    private void writeU32BigEndian(ref ubyte[] target, size_t offset,
        uint value)
    {
        target[offset] = cast(ubyte)(value >> 24);
        target[offset + 1] = cast(ubyte)((value >> 16) & 0xff);
        target[offset + 2] = cast(ubyte)((value >> 8) & 0xff);
        target[offset + 3] = cast(ubyte)(value & 0xff);
    }

    private bool stopRequested(string stopPath, ulong nowMicroseconds,
        ref ulong nextCheckMicroseconds)
    {
        if (nowMicroseconds < nextCheckMicroseconds) return false;
        nextCheckMicroseconds = nowMicroseconds + 100_000;
        return stopPath.length > 0 && exists(stopPath);
    }

    private void publishMetrics(string path, const WasapiRtpMetrics metrics)
    {
        if (path.length == 0) return;
        try write(path, metrics.text());
        catch (Exception) {}
    }

    private void publishStatus(string path, string status)
    {
        if (path.length == 0) return;
        try write(path, status ~ "\r\n");
        catch (Exception) {}
    }

    private struct PcmFrameRing
    {
        ubyte[] storage;
        size_t readFrame;
        size_t queuedFrames;

        void initialize()
        {
            storage = new ubyte[ringCapacityFrames * 4];
            readFrame = 0;
            queuedFrames = 0;
        }

        @property size_t capacityFrames() const
        {
            return storage.length / 4;
        }

        void discardAll(ref WasapiRtpMetrics metrics)
        {
            metrics.staleFramesDiscarded += queuedFrames;
            readFrame = 0;
            queuedFrames = 0;
        }

        void discardOldest(size_t frameCount, ref WasapiRtpMetrics metrics,
            bool overflow)
        {
            const dropped = frameCount < queuedFrames ? frameCount : queuedFrames;
            if (dropped == 0) return;
            readFrame = (readFrame + dropped) % capacityFrames;
            queuedFrames -= dropped;
            if (overflow) metrics.framesDroppedOnOverflow += dropped;
            else metrics.staleFramesDiscarded += dropped;
        }

        void recoverNearRealTime(ref WasapiRtpMetrics metrics)
        {
            if (queuedFrames > ringRecoveryFrames)
                discardOldest(queuedFrames - ringRecoveryFrames, metrics, false);
        }

        void enqueue(const(ubyte)* source, uint sourceFrames, bool silent,
            ref WasapiRtpMetrics metrics)
        {
            if (sourceFrames == 0) return;
            size_t frames = sourceFrames;
            size_t sourceFrameOffset;
            // A single unexpectedly large packet must not force the live queue
            // to retain a full 200 ms. Keep only the newest recovery window.
            if (frames > ringRecoveryFrames)
            {
                sourceFrameOffset = frames - ringRecoveryFrames;
                metrics.framesDroppedOnOverflow += sourceFrameOffset;
                frames = ringRecoveryFrames;
            }

            const needed = queuedFrames + frames;
            if (needed > capacityFrames)
            {
                // Live latency wins over preservation of stale audio. Once an
                // overflow occurs, return the final queue close to 40 ms rather
                // than merely shaving enough frames to remain at 200 ms.
                const keepQueued = frames < ringRecoveryFrames ?
                    ringRecoveryFrames - frames : 0;
                if (queuedFrames > keepQueued)
                    discardOldest(queuedFrames - keepQueued, metrics, true);
            }

            const writeFrame = (readFrame + queuedFrames) % capacityFrames;
            const firstFrames = frames < capacityFrames - writeFrame ?
                frames : capacityFrames - writeFrame;
            const secondFrames = frames - firstFrames;
            auto firstDestination = storage[writeFrame * 4 ..
                (writeFrame + firstFrames) * 4];
            if (silent || source is null)
                firstDestination[] = 0;
            else
                firstDestination[] = source[sourceFrameOffset * 4 ..
                    (sourceFrameOffset + firstFrames) * 4];

            if (secondFrames > 0)
            {
                auto secondDestination = storage[0 .. secondFrames * 4];
                if (silent || source is null)
                    secondDestination[] = 0;
                else
                    secondDestination[] = source[
                        (sourceFrameOffset + firstFrames) * 4 ..
                        (sourceFrameOffset + frames) * 4];
            }

            queuedFrames += frames;
            metrics.capturedFramesQueued += frames;
            if (queuedFrames > metrics.maximumRingDepthFrames)
                metrics.maximumRingDepthFrames = queuedFrames;
        }

        size_t dequeue(ubyte[] output, size_t requestedFrames,
            ref WasapiRtpMetrics metrics)
        {
            output[] = 0;
            const available = requestedFrames < queuedFrames ?
                requestedFrames : queuedFrames;
            const firstFrames = available < capacityFrames - readFrame ?
                available : capacityFrames - readFrame;
            const secondFrames = available - firstFrames;
            if (firstFrames > 0)
                output[0 .. firstFrames * 4] = storage[readFrame * 4 ..
                    (readFrame + firstFrames) * 4];
            if (secondFrames > 0)
                output[firstFrames * 4 .. available * 4] =
                    storage[0 .. secondFrames * 4];
            readFrame = (readFrame + available) % capacityFrames;
            queuedFrames -= available;
            metrics.silentFramesSent += requestedFrames - available;
            return available;
        }
    }

    unittest
    {
        PcmFrameRing ring;
        WasapiRtpMetrics metrics;
        ubyte[outputChunkFrames * 4] packet;
        ring.initialize();
        foreach (_; 0 .. 10)
            ring.enqueue(packet.ptr, outputChunkFrames, false, metrics);
        assert(ring.queuedFrames == ringCapacityFrames);

        // The next packet triggers overflow and must recover the final queue
        // to the 40 ms target instead of preserving nearly 200 ms of stale PCM.
        ring.enqueue(packet.ptr, outputChunkFrames, false, metrics);
        assert(ring.queuedFrames == ringRecoveryFrames);
        assert(metrics.framesDroppedOnOverflow ==
            ringCapacityFrames - outputChunkFrames);

        ubyte[outputChunkFrames * 4] output;
        const realFrames = ring.dequeue(output[], outputChunkFrames, metrics);
        assert(realFrames == outputChunkFrames);
        assert(metrics.silentFramesSent == 0);
    }

    private struct RtpSender
    {
        UdpSocket socket;
        InternetAddress destination;
        ushort sequence;
        uint timestamp;
        uint ssrc;
        ubyte[] packet;
        long clockFrequency;
        uint consecutiveSendFailures;

        void initialize(ushort port, long frequency,
            ref WasapiRtpMetrics metrics)
        {
            clockFrequency = frequency;
            consecutiveSendFailures = 0;
            socket = new UdpSocket(AddressFamily.INET);
            // Bind the sender explicitly while the parent process still owns
            // reservations for the future FFmpeg RTP and RTCP receive ports.
            // An unbound sendTo socket may otherwise auto-bind to that same
            // recently released destination port on Windows and make FFmpeg
            // fail with WSAEADDRINUSE (-10048).
            socket.bind(new InternetAddress("127.0.0.1",
                InternetAddress.PORT_ANY));
            auto localAddress = cast(InternetAddress) socket.localAddress;
            if (localAddress is null || localAddress.port == 0)
                throw new Exception(
                    "Windows did not allocate a local RTP sender port.");
            if (localAddress.port == port ||
                (port < ushort.max && localAddress.port == port + 1))
                throw new Exception(
                    "The RTP sender collided with an FFmpeg receiver port.");
            metrics.rtpSourcePort = localAddress.port;
            metrics.rtpDestinationPort = port;
            socket.blocking = false;
            destination = new InternetAddress("127.0.0.1", port);
            const seed = cast(uint) GetTickCount64();
            sequence = cast(ushort)(seed & 0xffff);
            timestamp = seed * 1103515245U + 12345U;
            ssrc = seed ^ 0xa57a0d10U;
            packet = new ubyte[12 + outputChunkFrames * 4];
        }

        void close()
        {
            if (socket !is null) socket.close();
            socket = null;
        }

        void skipFrames(ulong frameCount)
        {
            timestamp += cast(uint) frameCount;
        }

        bool sendChunk(const ubyte[] littleEndianPcm,
            ref WasapiRtpMetrics metrics)
        {
            const frameCount = cast(uint)(littleEndianPcm.length / 4);
            const payloadBytes = littleEndianPcm.length;
            packet[0] = 0x80;
            packet[1] = 96;
            writeU16BigEndian(packet, 2, sequence);
            writeU32BigEndian(packet, 4, timestamp);
            writeU32BigEndian(packet, 8, ssrc);
            auto payload = packet[12 .. 12 + payloadBytes];
            foreach (sampleIndex; 0 .. littleEndianPcm.length / 2)
            {
                const sourceByte = sampleIndex * 2;
                payload[sourceByte] = littleEndianPcm[sourceByte + 1];
                payload[sourceByte + 1] = littleEndianPcm[sourceByte];
            }

            const expected = 12 + payloadBytes;
            const started = clockMicroseconds(clockFrequency);
            bool success;
            try
            {
                const sent = socket.sendTo(packet[0 .. expected], destination);
                success = sent != Socket.ERROR &&
                    sent == cast(typeof(sent)) expected;
            }
            catch (Exception)
            {
                success = false;
            }
            const elapsed = clockMicroseconds(clockFrequency) - started;
            if (elapsed > metrics.maximumSendDurationMicroseconds)
                metrics.maximumSendDurationMicroseconds = elapsed;

            if (success)
            {
                consecutiveSendFailures = 0;
                ++metrics.rtpPacketsSent;
                metrics.audioFramesSent += frameCount;
            }
            else
            {
                ++metrics.sendFailures;
                ++consecutiveSendFailures;
            }
            ++sequence;
            timestamp += frameCount;
            if (consecutiveSendFailures >= 5)
                throw new Exception(
                    "The local RTP receiver rejected five consecutive audio packets.");
            return success;
        }
    }

    private ulong reanchorOutputClock(ulong nowMicroseconds,
        ref ulong nextOutputMicroseconds)
    {
        // Normal Windows wake-up jitter must not become an audible RTP gap.
        // A short scheduling stall is recovered by sending the due packets in
        // a small local catch-up burst while preserving every RTP timestamp.
        // The receiver has ample localhost buffering for this. Only a delay
        // beyond 100 ms is treated as unrecoverable and skipped to prevent
        // stale audio from accumulating.
        if (nowMicroseconds < nextOutputMicroseconds +
            outputCatchUpWindowMicroseconds)
            return 0;
        const lateMicroseconds = nowMicroseconds - nextOutputMicroseconds;
        const missedIntervals = lateMicroseconds /
            outputIntervalMicroseconds;
        nextOutputMicroseconds += missedIntervals *
            outputIntervalMicroseconds;
        return missedIntervals * outputChunkFrames;
    }

    private DWORD waitMillisecondsUntil(ulong deadlineMicroseconds,
        ulong nowMicroseconds)
    {
        if (nowMicroseconds >= deadlineMicroseconds) return 0;
        const remaining = deadlineMicroseconds - nowMicroseconds;
        const rounded = (remaining + 999) / 1000;
        return cast(DWORD)(rounded > 20 ? 20 : rounded);
    }

    private int runSyntheticRtp(ushort port, string statusPath,
        string stopPath, string metricsPath)
    {
        WasapiRtpMetrics metrics;
        metrics.synthetic = true;
        RtpSender sender;
        MmcssRegistration mmcss;
        ubyte[outputChunkFrames * 4] silence;
        try
        {
            mmcss.activate();
            metrics.mmcssEnabled = mmcss.active;
            long frequency;
            if (QueryPerformanceFrequency(&frequency) == 0) frequency = 0;
            sender.initialize(port, frequency, metrics);
            publishStatus(statusPath, "ready");
            ulong nextOutput = clockMicroseconds(frequency) +
                outputIntervalMicroseconds;
            ulong nextStopCheck;

            while (true)
            {
                auto now = clockMicroseconds(frequency);
                if (stopRequested(stopPath, now, nextStopCheck)) break;
                if (now < nextOutput)
                {
                    const waitMs = waitMillisecondsUntil(nextOutput, now);
                    if (waitMs > 0) Thread.sleep(waitMs.msecs);
                    continue;
                }

                const skipped = reanchorOutputClock(now, nextOutput);
                if (skipped > 0)
                {
                    metrics.pacingFramesSkipped += skipped;
                    sender.skipFrames(skipped);
                }
                sender.sendChunk(silence[], metrics);
                metrics.silentFramesSent += outputChunkFrames;
                ++metrics.outputIntervals;
                nextOutput += outputIntervalMicroseconds;

            }
            publishMetrics(metricsPath, metrics);
            return 0;
        }
        catch (Exception error)
        {
            publishStatus(statusPath, "error:" ~ error.msg);
            publishMetrics(metricsPath, metrics);
            return 2;
        }
        finally
        {
            mmcss.close();
            sender.close();
        }
    }

    private int runWasapiRtp(string selectedEndpointId, ushort port,
        string statusPath, string stopPath, string metricsPath)
    {
        bool comInitialized;
        bool audioStarted;
        void* enumerator;
        void* device;
        void* audioClient;
        void* captureClient;
        HANDLE audioEvent;
        WasapiRtpMetrics metrics;
        RtpSender sender;
        MmcssRegistration mmcss;
        PcmFrameRing ring;
        ubyte[outputChunkFrames * 4] outputChunk;

        try
        {
            mmcss.activate();
            metrics.mmcssEnabled = mmcss.active;
            long frequency;
            if (QueryPerformanceFrequency(&frequency) == 0) frequency = 0;

            checkResult("CoInitializeEx",
                CoInitializeEx(null, coinitMultithreaded));
            comInitialized = true;
            checkResult("CoCreateInstance(MMDeviceEnumerator)",
                CoCreateInstance(&clsidMMDeviceEnumerator, null,
                    classContextAll, &iidIMMDeviceEnumerator, &enumerator));

            auto getDevice = cast(EnumeratorGetDevice)
                methodPointer(enumerator, 5);
            checkResult("IMMDeviceEnumerator.GetDevice",
                getDevice(enumerator, toUTF16z(selectedEndpointId), &device));

            auto activate = cast(DeviceActivate) methodPointer(device, 3);
            checkResult("IMMDevice.Activate(IAudioClient)",
                activate(device, &iidIAudioClient, classContextAll,
                    null, &audioClient));

            WaveFormatEx requestedFormat;
            requestedFormat.formatTag = waveFormatPcm;
            requestedFormat.channels = 2;
            requestedFormat.samplesPerSecond = 48_000;
            requestedFormat.bitsPerSample = 16;
            requestedFormat.blockAlign = 4;
            requestedFormat.averageBytesPerSecond = 192_000;
            requestedFormat.extraSize = 0;

            auto initialize = cast(AudioClientInitialize)
                methodPointer(audioClient, 3);
            checkResult("IAudioClient.Initialize(loopback event stream)",
                initialize(audioClient, audioClientShareModeShared,
                    audioClientStreamFlagLoopback |
                        audioClientStreamFlagEventCallback |
                        audioClientStreamFlagAutoConvertPcm |
                        audioClientStreamFlagSrcDefaultQuality,
                    1_000_000, 0, &requestedFormat, null));

            audioEvent = CreateEventW(null, 0, 0, null);
            if (audioEvent is null)
                throw new Exception("CreateEventW failed for WASAPI loopback.");
            auto setEventHandle = cast(AudioClientSetEventHandle)
                methodPointer(audioClient, 13);
            checkResult("IAudioClient.SetEventHandle",
                setEventHandle(audioClient, audioEvent));

            auto getService = cast(AudioClientGetService)
                methodPointer(audioClient, 14);
            checkResult("IAudioClient.GetService(IAudioCaptureClient)",
                getService(audioClient, &iidIAudioCaptureClient,
                    &captureClient));

            ring.initialize();
            sender.initialize(port, frequency, metrics);
            auto startAudio = cast(AudioClientStart)
                methodPointer(audioClient, 10);
            checkResult("IAudioClient.Start", startAudio(audioClient));
            audioStarted = true;

            auto nextPacket = cast(CaptureGetNextPacketSize)
                methodPointer(captureClient, 5);
            auto getBuffer = cast(CaptureGetBuffer)
                methodPointer(captureClient, 3);
            auto releaseBuffer = cast(CaptureReleaseBuffer)
                methodPointer(captureClient, 4);

            ulong lastPacketTick;
            bool captureStatusPublished;
            ulong nextOutput = clockMicroseconds(frequency) +
                outputIntervalMicroseconds;
            ulong nextStopCheck;
            publishStatus(statusPath, "ready");

            while (true)
            {
                auto now = clockMicroseconds(frequency);
                if (stopRequested(stopPath, now, nextStopCheck)) break;
                const waitMs = waitMillisecondsUntil(nextOutput, now);
                const waitResult = WaitForSingleObject(audioEvent, waitMs);
                if (waitResult == waitObject0) ++metrics.eventWakeups;
                else if (waitResult == waitTimeout) ++metrics.eventTimeouts;
                else if (waitResult == waitFailed)
                    throw new Exception("WaitForSingleObject failed for WASAPI loopback.");

                const captureStarted = clockMicroseconds(frequency);
                UINT32 packetFrames;
                checkResult("IAudioCaptureClient.GetNextPacketSize",
                    nextPacket(captureClient, &packetFrames));
                while (packetFrames > 0)
                {
                    BYTE* data;
                    UINT32 frames;
                    DWORD flags;
                    UINT64 devicePosition;
                    UINT64 counterPosition;
                    checkResult("IAudioCaptureClient.GetBuffer",
                        getBuffer(captureClient, &data, &frames, &flags,
                            &devicePosition, &counterPosition));
                    HRESULT releaseResult;
                    try
                    {
                        ++metrics.packetsCaptured;
                        if (!captureStatusPublished)
                        {
                            publishStatus(statusPath, "capturing");
                            captureStatusPublished = true;
                        }
                        const packetTick = GetTickCount64();
                        if (lastPacketTick != 0)
                        {
                            const gap = packetTick - lastPacketTick;
                            if (gap > metrics.maximumPacketGapMilliseconds)
                                metrics.maximumPacketGapMilliseconds = gap;
                        }
                        lastPacketTick = packetTick;
                        if ((flags & audioClientBufferFlagDataDiscontinuity) != 0)
                        {
                            // Windows commonly marks the first loopback packet
                            // discontinuous because there is no predecessor.
                            // Record that startup condition separately; only a
                            // later flag represents a broken live capture span.
                            if (metrics.packetsCaptured == 1)
                                ++metrics.startupDiscontinuities;
                            else
                            {
                                ++metrics.discontinuities;
                                ring.discardAll(metrics);
                            }
                        }
                        const silent =
                            (flags & audioClientBufferFlagSilent) != 0 ||
                            data is null;
                        ring.enqueue(data, frames, silent, metrics);
                    }
                    finally
                    {
                        releaseResult = releaseBuffer(captureClient, frames);
                    }
                    checkResult("IAudioCaptureClient.ReleaseBuffer",
                        releaseResult);
                    checkResult("IAudioCaptureClient.GetNextPacketSize",
                        nextPacket(captureClient, &packetFrames));
                }
                const captureDuration = clockMicroseconds(frequency) -
                    captureStarted;
                if (captureDuration > metrics.maximumCaptureDurationMicroseconds)
                    metrics.maximumCaptureDurationMicroseconds = captureDuration;

                now = clockMicroseconds(frequency);
                if (now >= nextOutput)
                {
                    const skipped = reanchorOutputClock(now, nextOutput);
                    if (skipped > 0)
                    {
                        metrics.pacingFramesSkipped += skipped;
                        sender.skipFrames(skipped);
                        ring.recoverNearRealTime(metrics);
                    }
                    ring.dequeue(outputChunk[], outputChunkFrames, metrics);
                    sender.sendChunk(outputChunk[], metrics);
                    ++metrics.outputIntervals;
                    nextOutput += outputIntervalMicroseconds;
                }

            }

            publishMetrics(metricsPath, metrics);
            return 0;
        }
        catch (Exception error)
        {
            publishStatus(statusPath, "error:" ~ error.msg);
            publishMetrics(metricsPath, metrics);
            return 2;
        }
        finally
        {
            if (audioStarted && audioClient !is null)
            {
                auto stopAudio = cast(AudioClientStop)
                    methodPointer(audioClient, 11);
                if (stopAudio !is null) stopAudio(audioClient);
            }
            if (audioEvent !is null) CloseHandle(audioEvent);
            mmcss.close();
            sender.close();
            releaseCom(captureClient);
            releaseCom(audioClient);
            releaseCom(device);
            releaseCom(enumerator);
            if (comInitialized) CoUninitialize();
        }
    }

    int runWasapiRtpBridge(string selectedEndpointId, ushort port,
        string statusPath, string stopPath, string metricsPath,
        bool synthetic)
    {
        if (port == 0)
        {
            publishStatus(statusPath, "error:Invalid RTP port.");
            return 2;
        }
        if (synthetic)
            return runSyntheticRtp(port, statusPath, stopPath, metricsPath);
        if (selectedEndpointId.strip().length == 0)
        {
            publishStatus(statusPath,
                "error:No Windows playback endpoint was supplied.");
            return 2;
        }
        return runWasapiRtp(selectedEndpointId.strip(), port, statusPath,
            stopPath, metricsPath);
    }
}
else
{
    AudioEndpoint[] enumerateWasapiRenderEndpoints(out string error)
    {
        error = "WASAPI playback enumeration is only supported on Windows.";
        return [];
    }

    int runWasapiRtpBridge(string selectedEndpointId, ushort port,
        string statusPath, string stopPath, string metricsPath,
        bool synthetic)
    {
        try write(statusPath,
            "error:WASAPI RTP bridge is only supported on Windows.\r\n");
        catch (Exception) {}
        return 2;
    }
}
