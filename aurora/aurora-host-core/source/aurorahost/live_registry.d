module aurorahost.live_registry;

import core.sys.windows.windows : BOOL, FALSE, GetCurrentProcessId,
    GetExitCodeProcess, GetWindowTextLengthW, GetWindowTextW,
    GetWindowThreadProcessId, HWND, IsWindowVisible, LPARAM, OpenProcess,
    CloseHandle, EnumWindows, TRUE;
import std.array : replace;
import std.file : exists, mkdirRecurse, readText, remove, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment;
import std.utf : toUTF8;

struct LiveWindow
{
    HWND handle;
    uint pid;
    string title;
}

private struct CollectState
{
    LiveWindow[] windows;
}

private extern(Windows) nothrow BOOL collectWindow(HWND handle, LPARAM value)
{
    if (!IsWindowVisible(handle))
        return TRUE;
    const length = GetWindowTextLengthW(handle);
    if (length == 0)
        return TRUE;
    wchar[512] buffer;
    const count = GetWindowTextW(handle, buffer.ptr,
        cast(int) (buffer.length < length + 1 ? buffer.length : length + 1));
    if (count <= 0)
        return TRUE;
    uint pid;
    GetWindowThreadProcessId(handle, &pid);
    auto state = cast(CollectState*) value;
    LiveWindow window;
    window.handle = handle;
    window.pid = pid;
    try
        window.title = toUTF8(buffer[0 .. count]).idup;
    catch (Exception)
        return TRUE;
    state.windows ~= window;
    return TRUE;
}

LiveWindow[] visibleWindows()
{
    CollectState state;
    EnumWindows(&collectWindow, cast(LPARAM) &state);
    return state.windows;
}

LiveWindow[] windowsForProcess(uint pid)
{
    LiveWindow[] result;
    foreach (window; visibleWindows())
        if (window.pid == pid)
            result ~= window;
    return result;
}

private string liveDirectory()
{
    auto root = environment.get("LOCALAPPDATA", "");
    if (root.length == 0)
        root = environment.get("APPDATA", "");
    if (root.length == 0)
        root = ".";
    return buildPath(root, "AuroraHost", "live");
}

private string fileName(string key)
{
    return buildPath(liveDirectory(),
        key.replace("|", "_").replace(" ", "_") ~ ".json");
}

private bool processAlive(uint pid)
{
    if (pid == 0)
        return false;
    auto process = OpenProcess(0x1000, FALSE, pid);
    if (process is null)
        return false;
    uint code;
    const ok = GetExitCodeProcess(process, &code);
    CloseHandle(process);
    return ok && code == 259;
}

void registerLive(string key)
{
    if (key.length == 0)
        return;
    const directory = liveDirectory();
    if (!exists(directory))
        mkdirRecurse(directory);
    JSONValue document;
    document["key"] = key;
    document["pid"] = JSONValue(cast(long) GetCurrentProcessId());
    write(fileName(key), document.toString() ~ "\n");
}

void unregisterLive(string key)
{
    if (key.length == 0)
        return;
    const path = fileName(key);
    if (exists(path))
        remove(path);
}

bool isLive(string key)
{
    if (key.length == 0)
        return false;
    const path = fileName(key);
    if (!exists(path))
        return false;
    try
    {
        const document = parseJSON(readText(path));
        if (auto value = "pid" in document.object)
            if (value.type == JSONType.integer && value.integer > 0)
                return processAlive(cast(uint) value.integer);
    }
    catch (Exception)
    {
    }
    return false;
}

bool hasSingleWindow(uint pid)
{
    return windowsForProcess(pid).length == 1;
}
