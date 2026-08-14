module aurorastream.gamecapture;

import aurorastream.gamecapturebundle : extractBundledGameCaptureHook;
import aurorastream.gamecapprotocol : GameCaptureMessage,
    GameCapturePacketHeader, GameCaptureSharedHeader,
    GameCaptureSharedSlotState, gameCaptureErrorMessage,
    gameCaptureSharedHeaderSize, gameCaptureSharedMagic,
    gameCaptureSharedMappingSize, gameCaptureSharedSlotCount,
    gameCaptureSharedSlotOffset, gameCaptureSharedSlotStride,
    validGameCaptureHeader, validGameCaptureSharedHeader,
    gameCaptureHeaderSize, gameCaptureProtocolVersion;
import std.file : exists, remove, write;
import std.path : absolutePath, buildPath, dirName;
import std.process : environment;
import std.string : strip;

version (Windows)
{
    import aurorastream.windowsources : hwndFromText;
    import core.atomic : atomicStore, cas;
    import core.stdc.string : memcpy, memset;
    import core.sys.windows.windows;
    import core.sync.mutex : Mutex;
    import core.thread : Thread;
    import core.time : msecs;
    import std.conv : to;
    import std.utf : toUTF16, toUTF16z;
}

version (Windows)
{
private int sharedCompareExchange(ref shared int destination,
    int exchange, int comparison)
{
    int previous = comparison;
    cas(&destination, &previous, exchange);
    return previous;
}

private void sharedExchange(ref shared int destination, int value)
{
    atomicStore(destination, value);
}

final class GameCaptureFrame
{
    uint width;
    uint height;
    uint sourceFormat;
    ulong sequence;
    ulong captureQpc;
    ulong captureQpcFrequency;
    ubyte[] pixels;
    package int slotIndex = -1;
}

struct GameCaptureMetrics
{
    ulong framesReceived;
    ulong framesSuperseded;
    ulong sequenceGaps;
    uint hookDroppedFrames;
    uint sourceFormat;
}

/// Owns one injected-hook session. The pipe carries only versioned frame/control
/// headers; pixels cross through a three-slot shared-memory ring into a bounded
/// three-slot local latest-frame queue. Neither the game's render thread nor the
/// FFmpeg pacing thread performs pipe I/O. Superseded frames are intentionally
/// dropped to preserve low latency.
final class GameCaptureSession
{
    private enum frameSlotCount = 3;
    private enum slotFree = 0;
    private enum slotFilling = 1;
    private enum slotLatest = 2;
    private enum slotConsumer = 3;

    private HANDLE _pipe;
    private HANDLE _sharedMapping;
    private void* _sharedView;
    private GameCaptureSharedHeader* _sharedHeader;
    private string _mappingName;
    private string _configPath;
    private string _hookPath;
    private bool _connected;
    private bool _ready;
    private bool _failed;
    private bool _shutdown;
    private string _error;
    private Mutex _mutex;
    private Thread _pipeThread;
    private GameCaptureFrame[frameSlotCount] _frames;
    private int[frameSlotCount] _slotStates;
    private int _latestIndex = -1;
    private ulong _framesReceived;
    private ulong _framesSuperseded;
    private ulong _sequenceGaps;
    private ulong _lastSequence;
    private uint _hookDroppedFrames;
    private uint _lastSourceFormat;

    this(string hookPath)
    {
        _hookPath = hookPath.idup;
        _mutex = new Mutex();
        foreach (i; 0 .. frameSlotCount)
        {
            _frames[i] = new GameCaptureFrame();
            _frames[i].slotIndex = cast(int) i;
        }
    }

    ~this()
    {
        // Normal owners shut down explicitly. Avoid touching the GC-managed
        // Mutex/Thread graph a second time during runtime finalization, when
        // finalizer order between those objects is intentionally undefined.
        if (!_shutdown) shutdown();
    }

    private bool createSharedFrames(out string error)
    {
        error = "";
        const mappingBytes = cast(ulong) gameCaptureSharedMappingSize;
        _sharedMapping = CreateFileMappingW(INVALID_HANDLE_VALUE, null,
            PAGE_READWRITE, cast(DWORD) (mappingBytes >> 32),
            cast(DWORD) mappingBytes, toUTF16z(_mappingName));
        if (_sharedMapping is null)
        {
            error = "Could not create the game-capture shared-memory ring (Windows error " ~
                GetLastError().to!string ~ ").";
            return false;
        }
        _sharedView = MapViewOfFile(_sharedMapping, FILE_MAP_ALL_ACCESS,
            0, 0, gameCaptureSharedMappingSize);
        if (_sharedView is null)
        {
            error = "Could not map the game-capture shared-memory ring (Windows error " ~
                GetLastError().to!string ~ ").";
            closeSharedFrames();
            return false;
        }
        memset(_sharedView, 0, gameCaptureSharedMappingSize);
        _sharedHeader = cast(GameCaptureSharedHeader*) _sharedView;
        _sharedHeader.magic = gameCaptureSharedMagic;
        _sharedHeader.protocolVersion = gameCaptureProtocolVersion;
        _sharedHeader.headerSize = gameCaptureSharedHeaderSize;
        _sharedHeader.slotCount = gameCaptureSharedSlotCount;
        _sharedHeader.slotStride = gameCaptureSharedSlotStride;
        return validGameCaptureSharedHeader(*_sharedHeader);
    }

    private void closeSharedFrames()
    {
        _sharedHeader = null;
        if (_sharedView !is null) UnmapViewOfFile(_sharedView);
        _sharedView = null;
        if (_sharedMapping !is null) CloseHandle(_sharedMapping);
        _sharedMapping = null;
    }

    bool start(string windowText, out string error)
    {
        error = "";
        auto window = cast(HWND) hwndFromText(windowText);
        if (window is null)
        {
            error = "The selected game-capture window handle is invalid.";
            return false;
        }
        if (_hookPath.strip().length == 0 || !exists(_hookPath))
        {
            error = "gamecaphook.dll was not found beside Aurora Stream or in the embedded bundle.";
            return false;
        }

        DWORD pid;
        if (GetWindowThreadProcessId(window, &pid) == 0 || pid == 0)
        {
            error = "Could not identify the process owning the selected game-capture window.";
            return false;
        }
        if (!targetArchitectureSupported(pid, error)) return false;

        // The config name is process-stable because the injected hook discovers
        // it from its own PID. The pipe itself is session-unique so stale hook
        // instances and multiple Aurora processes cannot connect accidentally.
        const sessionId = GetCurrentProcessId().to!string ~ "-" ~
            GetTickCount().to!string;
        const pipeName = "\\\\.\\pipe\\aurora-gamecap-" ~ pid.to!string ~
            "-" ~ sessionId;
        _mappingName = "Local\\AuroraGameCapture-" ~ sessionId;
        _configPath = buildPath(environment.get("TEMP", "."),
            "aurora-gamecap-" ~ pid.to!string ~ ".cfg");
        if (!createSharedFrames(error)) return false;
        _pipe = CreateNamedPipeW(toUTF16z(pipeName), PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1,
            64 * 1024, 64 * 1024, 0, null);
        if (_pipe == INVALID_HANDLE_VALUE)
        {
            _pipe = null;
            error = "Could not create the game-capture named pipe (Windows error " ~
                GetLastError().to!string ~ ").";
            closeSharedFrames();
            return false;
        }

        auto pipeHandle = _pipe;
        _pipeThread = new Thread({ servePipe(pipeHandle); });
        _pipeThread.isDaemon = true;
        _pipeThread.start();

        try
        {
            write(_configPath, "hwnd=" ~ (cast(ulong) window).to!string ~
                "\npipe=" ~ pipeName ~ "\nmapping=" ~ _mappingName ~ "\n");
        }
        catch (Exception writeError)
        {
            error = "Could not write the game-capture hook configuration: " ~
                writeError.msg;
            shutdown();
            return false;
        }

        if (!inject(pid, error))
        {
            shutdown();
            return false;
        }

        const startTick = GetTickCount();
        while (GetTickCount() - startTick < 8_000)
        {
            _mutex.lock();
            const readyNow = _ready;
            const failedNow = _failed;
            const failure = _error;
            _mutex.unlock();
            if (readyNow) break;
            if (failedNow)
            {
                error = failure;
                shutdown();
                return false;
            }
            Thread.sleep(10.msecs);
        }

        _mutex.lock();
        const readyNow = _ready;
        const connectedNow = _connected;
        _mutex.unlock();
        if (!readyNow)
        {
            error = connectedNow ?
                "The injected game-capture hook connected but did not finish D3D11 initialization." :
                "The injected game-capture hook did not connect to its frame pipe. The game may block DLL injection or may not use D3D11 Present.";
            shutdown();
            return false;
        }
        try remove(_configPath);
        catch (Exception) {}
        return true;
    }

    private bool targetArchitectureSupported(DWORD pid, out string error)
    {
        error = "";
        auto process = OpenProcess(PROCESS_QUERY_INFORMATION, false, pid);
        if (process is null)
        {
            error = "Could not inspect the game process architecture (Windows error " ~
                GetLastError().to!string ~ "). The game may be protected or elevated.";
            return false;
        }
        BOOL currentWow64;
        BOOL targetWow64;
        const currentOk = IsWow64Process(GetCurrentProcess(), &currentWow64) != 0;
        const targetOk = IsWow64Process(process, &targetWow64) != 0;
        CloseHandle(process);
        if (!currentOk || !targetOk)
        {
            error = "Could not verify that the game is a 64-bit process.";
            return false;
        }
        if (!currentWow64 && targetWow64)
        {
            error = "This release contains a 64-bit D3D11 hook and cannot capture a 32-bit game process.";
            return false;
        }
        return true;
    }

    private void servePipe(HANDLE pipeHandle)
    {
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
        const connectedNow = ConnectNamedPipe(pipeHandle, null) != 0 ||
            GetLastError() == ERROR_PIPE_CONNECTED;
        _mutex.lock();
        if (connectedNow)
            _connected = true;
        else if (!_shutdown)
        {
            _failed = true;
            _error = "The game-capture hook could not connect to the named pipe (Windows error " ~
                GetLastError().to!string ~ ").";
        }
        _mutex.unlock();
        if (!connectedNow) return;

        while (true)
        {
            GameCapturePacketHeader header;
            if (!readExact(pipeHandle, cast(ubyte*) &header,
                gameCaptureHeaderSize))
                break;
            if (!validGameCaptureHeader(header))
            {
                markFailure("The game-capture hook sent an invalid or incompatible protocol header.");
                break;
            }

            if (header.messageType == GameCaptureMessage.ready)
            {
                _mutex.lock();
                _ready = true;
                _mutex.unlock();
                continue;
            }
            if (header.messageType == GameCaptureMessage.error)
            {
                markFailure(gameCaptureErrorMessage(header.errorCode,
                    header.sourceFormat));
                break;
            }

            const slotIndex = acquireFrameSlot();
            if (slotIndex < 0)
            {
                markFailure("The bounded game-capture frame queue became unavailable.");
                break;
            }
            auto frame = _frames[slotIndex];
            if (frame.pixels.length != header.byteCount)
                frame.pixels.length = header.byteCount;
            const sharedIndex = header.sharedSlot;
            if (_sharedHeader is null ||
                sharedCompareExchange(
                    _sharedHeader.slotStates[sharedIndex],
                    GameCaptureSharedSlotState.reading,
                    GameCaptureSharedSlotState.ready) !=
                    GameCaptureSharedSlotState.ready)
            {
                releaseFillingSlot(slotIndex);
                markFailure(
                    "The game-capture shared-memory slot was not ready for its frame header.");
                break;
            }
            auto sharedPixels = cast(const(ubyte)*) _sharedView +
                gameCaptureSharedSlotOffset(sharedIndex);
            memcpy(frame.pixels.ptr, sharedPixels, header.byteCount);
            sharedExchange(
                _sharedHeader.slotStates[sharedIndex],
                GameCaptureSharedSlotState.free);
            frame.width = header.width;
            frame.height = header.height;
            frame.sourceFormat = header.sourceFormat;
            frame.sequence = header.sequence;
            frame.captureQpc = header.captureQpc;
            frame.captureQpcFrequency = header.captureQpcFrequency;
            if (!publishFrame(slotIndex, header)) break;
        }

        _mutex.lock();
        const stopped = _shutdown;
        const alreadyFailed = _failed;
        _mutex.unlock();
        if (!stopped && !alreadyFailed)
            markFailure("The game-capture frame pipe closed unexpectedly.");
    }

    private bool readExact(HANDLE pipeHandle, ubyte* destination,
        size_t byteCount)
    {
        size_t offset;
        while (offset < byteCount)
        {
            const request = cast(DWORD) ((byteCount - offset) > uint.max ?
                uint.max : byteCount - offset);
            DWORD received;
            if (ReadFile(pipeHandle, destination + offset, request,
                &received, null) == 0 || received == 0)
                return false;
            offset += received;
        }
        return true;
    }

    private int acquireFrameSlot()
    {
        _mutex.lock();
        int result = -1;
        foreach (i; 0 .. frameSlotCount)
        {
            if (_slotStates[i] == slotFree)
            {
                result = cast(int) i;
                break;
            }
        }
        if (result < 0 && _latestIndex >= 0)
        {
            result = _latestIndex;
            _latestIndex = -1;
            ++_framesSuperseded;
        }
        if (result >= 0) _slotStates[result] = slotFilling;
        _mutex.unlock();
        return result;
    }

    private void releaseFillingSlot(int slotIndex)
    {
        _mutex.lock();
        if (slotIndex >= 0 && slotIndex < frameSlotCount &&
            _slotStates[slotIndex] == slotFilling)
            _slotStates[slotIndex] = slotFree;
        _mutex.unlock();
    }

    private bool publishFrame(int slotIndex,
        const ref GameCapturePacketHeader header)
    {
        _mutex.lock();
        if (_lastSequence > 0 && header.sequence <= _lastSequence)
        {
            _slotStates[slotIndex] = slotFree;
            _failed = true;
            _error = "The game-capture hook sent frames out of sequence.";
            _mutex.unlock();
            return false;
        }
        if (_latestIndex >= 0 && _latestIndex != slotIndex)
        {
            _slotStates[_latestIndex] = slotFree;
            ++_framesSuperseded;
        }
        if (_lastSequence > 0 && header.sequence > _lastSequence + 1)
            _sequenceGaps += header.sequence - _lastSequence - 1;
        _lastSequence = header.sequence;
        _hookDroppedFrames = header.droppedFrames;
        _lastSourceFormat = header.sourceFormat;
        ++_framesReceived;
        _slotStates[slotIndex] = slotLatest;
        _latestIndex = slotIndex;
        _mutex.unlock();
        return true;
    }

    private void markFailure(string message)
    {
        _mutex.lock();
        if (!_shutdown)
        {
            _failed = true;
            _error = message.length > 0 ? message.idup :
                "The game-capture hook failed.";
        }
        _mutex.unlock();
    }

    private bool inject(DWORD pid, out string error)
    {
        error = "";
        enum access = PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION |
            PROCESS_VM_OPERATION | PROCESS_VM_WRITE | PROCESS_VM_READ;
        auto process = OpenProcess(access, false, pid);
        if (process is null)
        {
            error = "Could not open the game process for DLL injection (Windows error " ~
                GetLastError().to!string ~ "). The game may be protected by anti-cheat or running elevated.";
            return false;
        }

        auto hookW = absolutePath(_hookPath).toUTF16;
        hookW ~= 0;
        const bytes = hookW.length * wchar.sizeof;
        auto remotePath = VirtualAllocEx(process, null, bytes,
            MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (remotePath is null)
        {
            error = "Could not allocate memory in the game process (Windows error " ~
                GetLastError().to!string ~ ").";
            CloseHandle(process);
            return false;
        }

        SIZE_T writtenBytes;
        if (WriteProcessMemory(process, remotePath, hookW.ptr, bytes,
            &writtenBytes) == 0 || writtenBytes != bytes)
        {
            error = "Could not copy gamecaphook.dll into the game process (Windows error " ~
                GetLastError().to!string ~ ").";
            VirtualFreeEx(process, remotePath, 0, MEM_RELEASE);
            CloseHandle(process);
            return false;
        }

        auto kernel32 = GetModuleHandleW(toUTF16z("kernel32.dll"));
        auto loadLibraryW = cast(LPTHREAD_START_ROUTINE)
            GetProcAddress(kernel32, "LoadLibraryW");
        if (loadLibraryW is null)
        {
            error = "Could not resolve kernel32.dll!LoadLibraryW.";
            VirtualFreeEx(process, remotePath, 0, MEM_RELEASE);
            CloseHandle(process);
            return false;
        }

        auto remoteThread = CreateRemoteThread(process, null, 0,
            loadLibraryW, remotePath, 0, null);
        if (remoteThread is null)
        {
            error = "Could not create the game injection thread (Windows error " ~
                GetLastError().to!string ~ "). The game may block DLL injection.";
            VirtualFreeEx(process, remotePath, 0, MEM_RELEASE);
            CloseHandle(process);
            return false;
        }
        const waitResult = WaitForSingleObject(remoteThread, 8_000);
        DWORD loadedModule;
        const exitCodeOk = waitResult == WAIT_OBJECT_0 &&
            GetExitCodeThread(remoteThread, &loadedModule) != 0;
        CloseHandle(remoteThread);
        // Never free a path that a timed-out remote LoadLibrary call might
        // still be reading. The tiny allocation is then owned until game exit.
        if (waitResult == WAIT_OBJECT_0)
            VirtualFreeEx(process, remotePath, 0, MEM_RELEASE);
        CloseHandle(process);
        if (!exitCodeOk || loadedModule == 0)
        {
            error = waitResult == WAIT_TIMEOUT ?
                "Loading gamecaphook.dll in the game process timed out." :
                "gamecaphook.dll was not loaded into the game process. The game may block DLL injection or use a protected process.";
            return false;
        }
        return true;
    }

    /// Claims the newest complete frame without blocking. The caller must call
    /// releaseFrame after it finishes reading the payload.
    bool readLatestFrame(out GameCaptureFrame frame)
    {
        frame = null;
        _mutex.lock();
        if (_latestIndex >= 0)
        {
            const index = _latestIndex;
            _latestIndex = -1;
            _slotStates[index] = slotConsumer;
            frame = _frames[index];
        }
        _mutex.unlock();
        return frame !is null;
    }

    void releaseFrame(GameCaptureFrame frame)
    {
        if (frame is null) return;
        const index = frame.slotIndex;
        _mutex.lock();
        if (index >= 0 && index < frameSlotCount &&
            _slotStates[index] == slotConsumer)
            _slotStates[index] = slotFree;
        _mutex.unlock();
    }

    string failure()
    {
        _mutex.lock();
        const result = _error;
        _mutex.unlock();
        return result;
    }

    string diagnosticsSummary()
    {
        const snapshot = metrics();
        return "frames_received=" ~ snapshot.framesReceived.to!string ~
            " hook_dropped=" ~ snapshot.hookDroppedFrames.to!string ~
            " pipe_superseded=" ~ snapshot.framesSuperseded.to!string ~
            " sequence_gaps=" ~ snapshot.sequenceGaps.to!string ~
            " source_dxgi_format=" ~ snapshot.sourceFormat.to!string;
    }

    GameCaptureMetrics metrics()
    {
        _mutex.lock();
        const result = GameCaptureMetrics(_framesReceived,
            _framesSuperseded, _sequenceGaps, _hookDroppedFrames,
            _lastSourceFormat);
        _mutex.unlock();
        return result;
    }

    void shutdown()
    {
        _mutex.lock();
        if (_shutdown)
        {
            _mutex.unlock();
            return;
        }
        _shutdown = true;
        auto pipeHandle = _pipe;
        _pipe = null;
        _mutex.unlock();

        if (pipeHandle !is null)
        {
            // The reader may be blocked in ConnectNamedPipe or ReadFile. This
            // cancellation is issued before closing the handle so shutdown is
            // deterministic even when injection fails before the hook connects.
            CancelIoEx(pipeHandle, null);
            DisconnectNamedPipe(pipeHandle);
            CloseHandle(pipeHandle);
        }
        if (_pipeThread !is null)
        {
            try _pipeThread.join();
            catch (Exception) {}
            _pipeThread = null;
        }
        closeSharedFrames();
        if (_configPath.length > 0)
        {
            try remove(_configPath);
            catch (Exception) {}
        }
    }
}

/// Finds the development-staged DLL or extracts the embedded single-exe copy.
string gameCaptureHookPath(string executablePath)
{
    const bundled = extractBundledGameCaptureHook();
    if (bundled.length > 0) return bundled;

    string[] candidates;
    if (executablePath.length > 0)
        candidates ~= buildPath(dirName(absolutePath(executablePath)),
            "gamecaphook.dll");
    candidates ~= absolutePath(buildPath(".", "gamecaphook.dll"));
    foreach (candidate; candidates)
        if (exists(candidate)) return candidate;
    return "";
}
}

else
{
    final class GameCaptureFrame {}
    struct GameCaptureMetrics {}

    final class GameCaptureSession
    {
        this(string hookPath) {}
        bool start(string windowText, out string error)
        {
            error = "Game capture is only available on Windows.";
            return false;
        }
        bool readLatestFrame(out GameCaptureFrame frame)
        {
            frame = null;
            return false;
        }
        void releaseFrame(GameCaptureFrame frame) {}
        string failure() { return ""; }
        string diagnosticsSummary() { return ""; }
        GameCaptureMetrics metrics() { return GameCaptureMetrics.init; }
        void shutdown() {}
    }

    string gameCaptureHookPath(string executablePath) { return ""; }
}
