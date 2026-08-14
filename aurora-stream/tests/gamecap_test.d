module gamecap_test;

/// Background-only end-to-end test for injection, versioned protocol,
/// asynchronous D3D11 capture, teardown, self-unload, and reinjection.

import aurorastream.gamecapprotocol : GameCaptureMessage,
    GameCapturePacketHeader, GameCaptureSharedHeader,
    GameCaptureSharedSlotState, gameCaptureErrorMessage,
    gameCaptureHeaderSize, gameCaptureProtocolVersion,
    gameCaptureSharedHeaderSize, gameCaptureSharedMagic,
    gameCaptureSharedMappingSize, gameCaptureSharedSlotCount,
    gameCaptureSharedSlotOffset, gameCaptureSharedSlotStride,
    validGameCaptureHeader, validGameCaptureSharedHeader;
import aurorastream.gamecapture : GameCaptureFrame, GameCaptureSession;
import core.atomic : atomicStore, cas;
import core.stdc.string : memcpy, memset;
import core.sys.windows.windows;
import core.sys.windows.winuser;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.file : append, remove, write;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.utf : toUTF16, toUTF16z;

struct CaptureStats
{
    int frames;
    int nonBlack;
    int changing;
    int colorCorrect;
    bool ready;
    uint hookDropped;
    ulong receivedFrames;
    ulong sequenceGaps;
    string error;
}

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

void mark(string message)
{
    try append("gamecap_test_trace.txt", message ~ "\n");
    catch (Exception) {}
    writeln(message);
}

void main(string[] args)
{
    if (args.length < 3)
        throw new Exception(
            "usage: gamecap_test <d3d11test_app.exe path> <gamecaphook.dll path> [--rgba|--rgb10]");

    const appPath = absolutePath(args[1]);
    const hookPath = absolutePath(args[2]);
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
    try remove("gamecap_test_trace.txt");
    catch (Exception) {}
    mark("start");

    PROCESS_INFORMATION processInfo;
    STARTUPINFOW startupInfo;
    startupInfo.cb = STARTUPINFOW.sizeof;
    const formatArgument = args.length >= 4 ? " " ~ args[3] : "";
    auto command = ("\"" ~ appPath ~ "\" --background" ~
        formatArgument).toUTF16;
    auto mutableCommand = cast(wchar[]) command.dup;
    if (CreateProcessW(null, mutableCommand.ptr, null, null, false,
        CREATE_NO_WINDOW, null, null, &startupInfo, &processInfo) == 0)
        throw new Exception("CreateProcess failed " ~
            GetLastError().to!string);
    scope(exit)
    {
        TerminateProcess(processInfo.hProcess, 0);
        CloseHandle(processInfo.hThread);
        CloseHandle(processInfo.hProcess);
    }
    mark("app pid=" ~ processInfo.dwProcessId.to!string);

    HWND hwnd = findProcessWindow(processInfo.dwProcessId);
    if (hwnd is null)
        throw new Exception("could not find the background D3D11 test window");
    mark("hwnd=" ~ (cast(ulong) hwnd).to!string);

    foreach (round; 1 .. 3)
    {
        const stats = captureRound(processInfo.hProcess,
            processInfo.dwProcessId, hwnd, hookPath, round);
        mark("round=" ~ round.to!string ~
            " ready=" ~ stats.ready.to!string ~
            " frames=" ~ stats.frames.to!string ~
            " nonBlack=" ~ stats.nonBlack.to!string ~
            " changing=" ~ stats.changing.to!string ~
            " colorCorrect=" ~ stats.colorCorrect.to!string ~
            " sequenceGaps=" ~ stats.sequenceGaps.to!string ~
            " hookDropped=" ~ stats.hookDropped.to!string);
        if (stats.error.length > 0)
            throw new Exception("round " ~ round.to!string ~ ": " ~
                stats.error);
        if (!stats.ready || stats.frames < 220 ||
            stats.nonBlack != stats.frames ||
            stats.colorCorrect != stats.frames ||
            stats.changing < 210 || stats.sequenceGaps > 12 ||
            stats.hookDropped > 12)
            throw new Exception("round " ~ round.to!string ~
                " failed frame-quality/performance thresholds");

        // Closing the server asks the hook worker to restore Present and
        // self-unload. Round two proves a real stop/start cycle in one game.
        Thread.sleep(500.msecs);
    }

    const sessionStats = captureProductionSession(hwnd, hookPath);
    mark("production-session frames=" ~ sessionStats.frames.to!string ~
        " received=" ~ sessionStats.receivedFrames.to!string ~
        " nonBlack=" ~ sessionStats.nonBlack.to!string ~
        " changing=" ~ sessionStats.changing.to!string ~
        " colorCorrect=" ~ sessionStats.colorCorrect.to!string ~
        " sequenceGaps=" ~ sessionStats.sequenceGaps.to!string ~
        " hookDropped=" ~ sessionStats.hookDropped.to!string);
    if (sessionStats.error.length > 0 || sessionStats.frames < 200 ||
        sessionStats.receivedFrames < 220 ||
        sessionStats.nonBlack != sessionStats.frames ||
        sessionStats.colorCorrect != sessionStats.frames ||
        sessionStats.changing < 195 || sessionStats.sequenceGaps > 12 ||
        sessionStats.hookDropped > 12)
        throw new Exception("production GameCaptureSession failed: " ~
            sessionStats.error);
    mark("PASS: protocol restart plus production session completed in background");
}

private HWND findProcessWindow(DWORD pid)
{
    const deadlineStart = GetTickCount();
    while (GetTickCount() - deadlineStart < 5_000)
    {
        HWND candidate;
        while ((candidate = FindWindowExW(null, candidate,
            "D3D11TestApp"w.ptr, null)) !is null)
        {
            DWORD candidatePid;
            GetWindowThreadProcessId(candidate, &candidatePid);
            if (candidatePid == pid) return candidate;
        }
        Thread.sleep(25.msecs);
    }
    return null;
}

private CaptureStats captureRound(HANDLE process, DWORD pid, HWND hwnd,
    string hookPath, int round)
{
    CaptureStats stats;
    const pipeName = "\\\\.\\pipe\\aurora-gamecap-test-" ~
        pid.to!string ~ "-" ~ round.to!string;
    const mappingName = "Local\\AuroraGameCaptureTest-" ~
        GetCurrentProcessId().to!string ~ "-" ~ pid.to!string ~ "-" ~
        round.to!string;
    const mappingBytes = cast(ulong) gameCaptureSharedMappingSize;
    auto mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, null,
        PAGE_READWRITE, cast(DWORD) (mappingBytes >> 32),
        cast(DWORD) mappingBytes, toUTF16z(mappingName));
    if (mapping is null)
    {
        stats.error = "shared mapping create failed " ~
            GetLastError().to!string;
        return stats;
    }
    scope(exit) CloseHandle(mapping);
    auto sharedView = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS,
        0, 0, gameCaptureSharedMappingSize);
    if (sharedView is null)
    {
        stats.error = "shared mapping view failed " ~ GetLastError().to!string;
        return stats;
    }
    scope(exit) UnmapViewOfFile(sharedView);
    memset(sharedView, 0, gameCaptureSharedMappingSize);
    auto sharedHeader = cast(GameCaptureSharedHeader*) sharedView;
    sharedHeader.magic = gameCaptureSharedMagic;
    sharedHeader.protocolVersion = gameCaptureProtocolVersion;
    sharedHeader.headerSize = gameCaptureSharedHeaderSize;
    sharedHeader.slotCount = gameCaptureSharedSlotCount;
    sharedHeader.slotStride = gameCaptureSharedSlotStride;
    if (!validGameCaptureSharedHeader(*sharedHeader))
    {
        stats.error = "shared mapping header initialization failed";
        return stats;
    }
    auto pipe = CreateNamedPipeW(toUTF16z(pipeName), PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1,
        64 * 1024, 64 * 1024, 0, null);
    if (pipe == INVALID_HANDLE_VALUE)
    {
        stats.error = "pipe create failed " ~ GetLastError().to!string;
        return stats;
    }
    scope(exit)
    {
        DisconnectNamedPipe(pipe);
        CloseHandle(pipe);
    }

    bool pipeConnected;
    auto connectThread = new Thread({
        pipeConnected = ConnectNamedPipe(pipe, null) != 0 ||
            GetLastError() == ERROR_PIPE_CONNECTED;
    });
    connectThread.start();

    const configPath = buildPath(environment.get("TEMP", "."),
        "aurora-gamecap-" ~ pid.to!string ~ ".cfg");
    write(configPath, "hwnd=" ~ to!string(cast(ulong) hwnd) ~ "\n" ~
        "pipe=" ~ pipeName ~ "\nmapping=" ~ mappingName ~ "\n");
    scope(exit) remove(configPath);

    const injectError = inject(process, hookPath);
    if (injectError.length > 0)
    {
        stats.error = injectError;
        return stats;
    }
    connectThread.join();
    if (!pipeConnected)
    {
        stats.error = "hook did not connect to the pipe";
        return stats;
    }

    ubyte[] frame;
    int lastChecksum;
    ulong lastSequence;
    const readStart = GetTickCount();
    while (GetTickCount() - readStart < 4_000)
    {
        DWORD available;
        if (PeekNamedPipe(pipe, null, 0, null, &available, null) == 0)
        {
            stats.error = "frame pipe closed before the test deadline";
            break;
        }
        if (available < gameCaptureHeaderSize)
        {
            Thread.sleep(1.msecs);
            continue;
        }

        GameCapturePacketHeader header;
        if (!readExact(pipe, cast(ubyte*) &header, gameCaptureHeaderSize) ||
            !validGameCaptureHeader(header))
        {
            stats.error = "invalid or incomplete game-capture protocol header";
            break;
        }
        if (header.messageType == GameCaptureMessage.ready)
            stats.ready = true;
        else if (header.messageType == GameCaptureMessage.error)
            stats.error = gameCaptureErrorMessage(header.errorCode,
                header.sourceFormat);
        else
        {
            if (header.width != 1920 || header.height != 1080)
            {
                stats.error = "unexpected frame size " ~
                    header.width.to!string ~ "x" ~
                    header.height.to!string;
                break;
            }
            frame.length = header.byteCount;
            const sharedIndex = header.sharedSlot;
            if (sharedCompareExchange(
                sharedHeader.slotStates[sharedIndex],
                GameCaptureSharedSlotState.reading,
                GameCaptureSharedSlotState.ready) !=
                GameCaptureSharedSlotState.ready)
            {
                stats.error = "shared frame slot was not ready";
                break;
            }
            auto sharedPixels = cast(const(ubyte)*) sharedView +
                gameCaptureSharedSlotOffset(sharedIndex);
            memcpy(frame.ptr, sharedPixels, header.byteCount);
            sharedExchange(
                sharedHeader.slotStates[sharedIndex],
                GameCaptureSharedSlotState.free);
            if (lastSequence > 0 && header.sequence <= lastSequence)
            {
                stats.error = "frames arrived out of sequence";
                break;
            }
            if (lastSequence > 0 && header.sequence > lastSequence + 1)
                stats.sequenceGaps += header.sequence - lastSequence - 1;
            lastSequence = header.sequence;
            uint checksum;
            // Sample the solid-color test surface. Walking every 1080p pixel
            // would throttle the pipe and measure the harness instead.
            for (size_t i = 0; i < frame.length / 4; i += 64)
                checksum += frame[i * 4] + frame[i * 4 + 1] +
                    frame[i * 4 + 2];
            ++stats.frames;
            if (checksum > 0) ++stats.nonBlack;
            if (frame.length >= 4 && frame[2] >= 250 && frame[3] == 255)
                ++stats.colorCorrect;
            const folded = cast(int) (checksum ^ (checksum >> 16));
            if (folded != lastChecksum) ++stats.changing;
            lastChecksum = folded;
            stats.hookDropped = header.droppedFrames;
        }
        if (stats.error.length > 0) break;
    }
    return stats;
}

private bool readExact(HANDLE pipe, ubyte* destination, size_t byteCount)
{
    size_t offset;
    while (offset < byteCount)
    {
        const request = cast(DWORD) ((byteCount - offset) > uint.max ?
            uint.max : byteCount - offset);
        DWORD received;
        if (ReadFile(pipe, destination + offset, request, &received, null) == 0 ||
            received == 0)
            return false;
        offset += received;
    }
    return true;
}

private CaptureStats captureProductionSession(HWND hwnd, string hookPath)
{
    CaptureStats stats;
    auto session = new GameCaptureSession(hookPath);
    string startError;
    if (!session.start((cast(ulong) hwnd).to!string, startError))
    {
        stats.error = startError;
        return stats;
    }
    stats.ready = true;
    scope(exit) session.shutdown();

    int lastChecksum;
    const readStart = GetTickCount();
    while (GetTickCount() - readStart < 4_000)
    {
        GameCaptureFrame frame;
        if (!session.readLatestFrame(frame))
        {
            const failure = session.failure();
            if (failure.length > 0)
            {
                stats.error = failure;
                break;
            }
            Thread.sleep(1.msecs);
            continue;
        }
        if (frame.width != 1920 || frame.height != 1080)
        {
            stats.error = "production session returned unexpected dimensions";
            session.releaseFrame(frame);
            break;
        }
        // The target is a solid-color render surface. Sampling its first pixel
        // verifies color and cadence without adding a cache-miss-heavy scan to
        // the production queue/pacing measurement.
        const uint checksum = frame.pixels[0] |
            (cast(uint) frame.pixels[1] << 8) |
            (cast(uint) frame.pixels[2] << 16);
        ++stats.frames;
        if (checksum > 0) ++stats.nonBlack;
        if (frame.pixels.length >= 4 && frame.pixels[2] >= 250 &&
            frame.pixels[3] == 255)
            ++stats.colorCorrect;
        const folded = cast(int) (checksum ^ (checksum >> 16));
        if (folded != lastChecksum) ++stats.changing;
        lastChecksum = folded;
        session.releaseFrame(frame);
    }
    const metrics = session.metrics();
    stats.receivedFrames = metrics.framesReceived;
    stats.sequenceGaps = metrics.sequenceGaps;
    stats.hookDropped = metrics.hookDroppedFrames;
    mark("production metrics: " ~ session.diagnosticsSummary());
    return stats;
}

private string inject(HANDLE process, string hookPath)
{
    auto hookW = hookPath.toUTF16;
    hookW ~= 0;
    const hookBytes = hookW.length * wchar.sizeof;
    auto remotePath = VirtualAllocEx(process, null, hookBytes,
        MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (remotePath is null)
        return "VirtualAllocEx failed " ~ GetLastError().to!string;

    SIZE_T writtenBytes;
    if (WriteProcessMemory(process, remotePath, hookW.ptr, hookBytes,
        &writtenBytes) == 0 || writtenBytes != hookBytes)
    {
        VirtualFreeEx(process, remotePath, 0, MEM_RELEASE);
        return "WriteProcessMemory failed " ~ GetLastError().to!string;
    }
    auto loadLibraryW = cast(LPTHREAD_START_ROUTINE)
        GetProcAddress(GetModuleHandleW("kernel32.dll"w.ptr), "LoadLibraryW");
    auto remoteThread = CreateRemoteThread(process, null, 0,
        loadLibraryW, remotePath, 0, null);
    if (remoteThread is null)
    {
        VirtualFreeEx(process, remotePath, 0, MEM_RELEASE);
        return "CreateRemoteThread failed " ~ GetLastError().to!string;
    }
    const waitResult = WaitForSingleObject(remoteThread, 5_000);
    DWORD moduleResult;
    const loaded = waitResult == WAIT_OBJECT_0 &&
        GetExitCodeThread(remoteThread, &moduleResult) != 0 &&
        moduleResult != 0;
    CloseHandle(remoteThread);
    if (waitResult == WAIT_OBJECT_0)
        VirtualFreeEx(process, remotePath, 0, MEM_RELEASE);
    return loaded ? "" : "remote LoadLibraryW failed or timed out";
}
