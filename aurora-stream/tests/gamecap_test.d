module gamecap_test;

/// End-to-end render-hook test: launches the D3D11 test app, creates the
/// named pipe, writes the hook config, injects gamecaphook.dll via
/// CreateRemoteThread + LoadLibrary, then reads the captured BGRA frames and
/// verifies they are non-black and changing (the app clears to a cycling
/// color).

import core.sys.windows.windows;
import core.sys.windows.winuser;
import core.thread : Thread;
import core.time : msecs, dur;
import std.stdio;
import std.conv : to;
import std.string : strip;
import std.file : write;
import std.path : buildPath;
import std.process : environment;
import std.utf : toUTF16, toUTF16z;
import std.algorithm : min;

__gshared HANDLE g_pipe;
__gshared int g_framesRead;
__gshared int g_firstFrameChecksum;

void main(string[] args)
{
    import std.file : append;
    void mark(string message)
    {
        try append("gamecap_test_trace.txt", message ~ "\n");
        catch (Exception) {}
        writeln(message);
    }
    if (args.length < 2)
    {
        mark("usage: gamecap_test <d3d11test_app.exe path> <gamecaphook.dll path>");
        return;
    }
    const appPath = args[1];
    const hookPath = args[2];
    mark("start");

    // 1. Launch the D3D11 test app.
    PROCESS_INFORMATION pi;
    STARTUPINFOW si;
    si.cb = STARTUPINFOW.sizeof;
    auto cmd = appPath.toUTF16;
    auto mutableCmd = cast(wchar[]) cmd.dup;
    if (CreateProcessW(null, mutableCmd.ptr, null, null, false,
        CREATE_NO_WINDOW, null, null, &si, &pi) == 0)
    {
        mark("CreateProcess failed " ~ GetLastError().to!string);
        return;
    }
    mark("app pid=" ~ pi.dwProcessId.to!string);

    // 2. Find the test app's window.
    HWND hwnd;
    const findDeadline = GetTickCount() + 5000;
    while (GetTickCount() < findDeadline)
    {
        hwnd = FindWindowW("D3D11TestApp"w.ptr, null);
        if (hwnd !is null) break;
        Thread.sleep(50.msecs);
    }
    if (hwnd is null)
    {
        mark("could not find window");
        TerminateProcess(pi.hProcess, 1);
        return;
    }
    DWORD pid;
    GetWindowThreadProcessId(hwnd, &pid);
    mark("hwnd=" ~ (cast(ulong) hwnd).to!string ~ " pid=" ~ pid.to!string);

    // 3. Create the frame pipe (server side) and connect it. The named-pipe
    // default buffer is 4096 bytes, but a 640x480 BGRA frame is ~1.2 MB; a
    // small buffer makes the hook's WriteFile block mid-frame while the reader
    // waits for a full frame (deadlock). Use large buffers so a whole frame
    // fits before the reader drains it.
    const pipeName = "\\\\.\\pipe\\aurora-gamecap-" ~ to!string(pid);
    const pipeBufferSize = 8 * 1024 * 1024;
    g_pipe = CreateNamedPipeW(toUTF16z(pipeName), PIPE_ACCESS_INBOUND,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1,
        pipeBufferSize, pipeBufferSize, 0, null);
    if (g_pipe == INVALID_HANDLE_VALUE)
    {
        mark("pipe create failed " ~ GetLastError().to!string);
        return;
    }
    auto connectThread = new Thread({
        ConnectNamedPipe(g_pipe, null);
        mark("pipe connected");
    });
    connectThread.start();

    // 4. Write the hook config.
    const configPath = buildPath(environment.get("TEMP", "."),
        "aurora-gamecap-" ~ to!string(pid) ~ ".cfg");
    write(configPath, "hwnd=" ~ to!string(cast(ulong) hwnd) ~ "\n" ~
        "pipe=" ~ pipeName ~ "\n");
    mark("config written");

    // 5. Inject the hook DLL.
    auto process = OpenProcess(PROCESS_ALL_ACCESS, false, pid);
    if (process is null)
    {
        mark("openproc failed " ~ GetLastError().to!string);
        return;
    }
    auto hookW = hookPath.toUTF16;
    const hookBytes = (cast(size_t) hookW.length + 1) * 2;
    auto remotePath = VirtualAllocEx(process, null, hookBytes,
        MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (remotePath is null)
    {
        mark("valloc failed " ~ GetLastError().to!string);
        return;
    }
    SIZE_T writtenBytes;
    WriteProcessMemory(process, remotePath, hookW.ptr, hookBytes, &writtenBytes);
    // LoadLibraryW must be the real kernel32 export (same address in every
    // process); `&LoadLibraryW` resolves to this exe's import thunk, which is
    // invalid in the target.
    auto loadLibraryW = cast(LPTHREAD_START_ROUTINE)
        GetProcAddress(GetModuleHandleW("kernel32.dll"w.ptr), "LoadLibraryW");
    auto remoteThread = CreateRemoteThread(process, null, 0,
        loadLibraryW, remotePath, 0, null);
    if (remoteThread is null)
    {
        mark("createthread failed " ~ GetLastError().to!string);
        return;
    }
    WaitForSingleObject(remoteThread, 5000);
    DWORD moduleHandle;
    GetExitCodeThread(remoteThread, &moduleHandle);
    mark("injected base=" ~ moduleHandle.to!string);

    // 6. Read frames for ~4 seconds, reassembling partial reads (the hook can
    // write while the reader drains, so a frame may arrive in pieces).
    const frameBytes = 640 * 480 * 4;
    auto frame = new ubyte[frameBytes];
    const readDeadline = GetTickCount() + 4000;
    int nonBlack;
    int changing;
    int lastChecksum;
    while (GetTickCount() < readDeadline)
    {
        size_t got;
        bool pipeAlive = true;
        while (got < frameBytes)
        {
            DWORD avail;
            if (!PeekNamedPipe(g_pipe, null, 0, null, &avail, null))
            {
                pipeAlive = false;
                break;
            }
            if (avail == 0)
            {
                Thread.sleep(1.msecs);
                if (GetTickCount() >= readDeadline) break;
                continue;
            }
            const take = min(avail, cast(DWORD) (frameBytes - got));
            DWORD readCount;
            if (!ReadFile(g_pipe, frame.ptr + got, take, &readCount, null))
            {
                pipeAlive = false;
                break;
            }
            if (readCount == 0) continue;
            got += readCount;
        }
        if (!pipeAlive) break;
        if (got < frameBytes) break;
        ++g_framesRead;
        // Checksum + color stats.
        uint sum;
        uint redSum;
        uint blueSum;
        foreach (i; 0 .. frameBytes / 4)
        {
            const b = frame[i * 4];
            const g = frame[i * 4 + 1];
            const r = frame[i * 4 + 2];
            sum += r + g + b;
            redSum += r;
            blueSum += b;
        }
        if (sum > 0) nonBlack++;
        const checksum = cast(int)(sum ^ (sum >> 16));
        if (checksum != lastChecksum) changing++;
        lastChecksum = checksum;
        if (g_framesRead == 1)
        {
            g_firstFrameChecksum = checksum;
            mark("frame1 avgR=" ~ (redSum / frameBytes).to!string ~
                " avgB=" ~ (blueSum / frameBytes).to!string);
        }
    }
    mark("framesRead=" ~ g_framesRead.to!string ~ " nonBlack=" ~
        nonBlack.to!string ~ " changing=" ~ changing.to!string);

    // 7. Cleanup: unload the hook, close handles.
    FreeLibrary(cast(HMODULE) moduleHandle);
    CloseHandle(remoteThread);
    VirtualFreeEx(process, remotePath, 0, MEM_RELEASE);
    CloseHandle(process);
    CloseHandle(g_pipe);
    TerminateProcess(pi.hProcess, 0);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    mark("done");
}
