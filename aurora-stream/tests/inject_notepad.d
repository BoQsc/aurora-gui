module inject_notepad;

import core.sys.windows.windows;
import core.sys.windows.winuser;
import core.thread : Thread;
import core.time : msecs;
import std.stdio;
import std.utf : toUTF16, toUTF16z;
import std.conv : to;
import std.format : format;

void main(string[] args)
{
    const hookPath = args.length > 1 ? args[1] :
        "C:\\Users\\Windows10_new\\Documents\\github_repositories\\aurora-gui\\aurora-stream\\gamecaphook.dll";
    // Launch notepad (non-D process).
    PROCESS_INFORMATION pi;
    STARTUPINFOW si;
    si.cb = STARTUPINFOW.sizeof;
    auto cmd = "notepad.exe".toUTF16;
    auto mutableCmd = cast(wchar[]) cmd.dup;
    if (CreateProcessW(null, mutableCmd.ptr, null, null, false, 0, null, null,
        &si, &pi) == 0)
    {
        writeln("CreateProcess failed ", GetLastError());
        return;
    }
    writeln("notepad pid=", pi.dwProcessId);

    // Wait for the notepad window.
    HWND hwnd;
    const deadline = GetTickCount() + 5000;
    while (GetTickCount() < deadline)
    {
        hwnd = FindWindowW("Notepad"w.ptr, null);
        if (hwnd !is null) break;
        Thread.sleep(50.msecs);
    }
    DWORD pid;
    if (hwnd is null)
    {
        writeln("no notepad window");
        GetWindowThreadProcessId(null, &pid);
    }
    else GetWindowThreadProcessId(hwnd, &pid);
    writeln("target pid=", pid);

    auto process = OpenProcess(PROCESS_ALL_ACCESS, false, pid);
    if (process is null) { writeln("OpenProcess failed ", GetLastError()); return; }

    // LoadLibraryW must be the real kernel32 export address (same in every
    // process); `&LoadLibraryW` in D resolves to this exe's import thunk,
    // which is invalid in the target.
    auto loadLibraryW = cast(LPTHREAD_START_ROUTINE)
        GetProcAddress(GetModuleHandleW("kernel32.dll"w.ptr), "LoadLibraryW");
    writeln("LoadLibraryW addr=", cast(ulong) loadLibraryW);

    auto hookW = hookPath.toUTF16;
    const hookBytes = (cast(size_t) hookW.length + 1) * 2;
    auto remotePath = VirtualAllocEx(process, null, hookBytes,
        MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (remotePath is null) { writeln("VirtualAllocEx failed ", GetLastError()); return; }
    SIZE_T written;
    WriteProcessMemory(process, remotePath, hookW.ptr, hookBytes, &written);
    auto remoteThread = CreateRemoteThread(process, null, 0,
        loadLibraryW, remotePath, 0, null);
    if (remoteThread is null) { writeln("CreateRemoteThread failed ", GetLastError()); return; }
    WaitForSingleObject(remoteThread, 5000);
    DWORD exitCode;
    GetExitCodeThread(remoteThread, &exitCode);
    writeln("LoadLibrary remote exit code = ", exitCode, " (", format("0x%08X", exitCode), ")");

    CloseHandle(remoteThread);
    CloseHandle(process);
    TerminateProcess(pi.hProcess, 0);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
}
