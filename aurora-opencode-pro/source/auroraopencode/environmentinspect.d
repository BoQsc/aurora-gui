module auroraopencode.environmentinspect;

import auroraopencode.nativeio;
import std.algorithm : canFind;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, isDir, isFile, thisExePath;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildPath, dirName, isAbsolute;
import std.process : environment, thisProcessID;
import std.string : endsWith, indexOf, split, toLower;
import std.system : os;

version (Windows)
{
    import core.sys.windows.windows;
    import core.sys.windows.tlhelp32;
    import std.utf : toUTF16z, toUTF8;
}

private string findNativeExecutable(string name, string workspace)
{
    enforce(name.length && name.indexOf('\0') < 0, "Executable name is empty or invalid.");
    string[] directories;
    if (isAbsolute(name) || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0)
        directories = [workspace];
    else
    {
        version (Windows) directories = environment.get("PATH", "").split(';');
        else directories = environment.get("PATH", "").split(':');
    }
    string[] suffixes = [""];
    version (Windows)
        foreach (suffix; environment.get("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(';'))
            if (suffix.length && !suffixes.canFind(suffix.toLower())) suffixes ~= suffix.toLower();
    foreach (directory; directories)
        foreach (suffix; suffixes)
        {
            if (!directory.length) continue;
            const path = nativePath(buildPath(directory, name ~ suffix), workspace);
            if (!exists(path) || !isFile(path)) continue;
            version (Posix)
            {
                import core.sys.posix.unistd : access, X_OK;
                import std.string : toStringz;
                if (access(path.toStringz, X_OK) != 0) continue;
            }
            return path;
        }
    return "";
}

JSONValue environmentInspection(string arguments, string workspace, NativeCancel cancelled = null)
{
    auto args = parseJSON(arguments);
    enforce(args.type == JSONType.object, "environment requires an object.");
    const action = nativeString(args, "action", "system");
    JSONValue result;
    result["action"] = action;
    if (action == "system")
    {
        result["os"] = to!string(os);
        result["architectureBits"] = size_t.sizeof * 8;
        result["processId"] = thisProcessID;
        result["executable"] = thisExePath();
        result["workspace"] = nativePath(".", workspace);
        result["availableActions"] = JSONValue([JSONValue("system"), JSONValue("executables"), JSONValue("disk"), JSONValue("processes"), JSONValue("ports")]);
        return result;
    }
    if (action == "executables")
    {
        auto names = "names" in args.object;
        enforce(names !is null && names.type == JSONType.array && names.array.length && names.array.length <= 64, "names must contain 1..64 executable names.");
        result["executables"] = JSONValue.emptyArray;
        foreach (name; names.array)
        {
            checkNativeCancellation(cancelled);
            enforce(name.type == JSONType.string, "Executable names must be strings.");
            const path = findNativeExecutable(name.str, workspace);
            JSONValue row;
            row["name"] = name.str; row["found"] = path.length != 0; row["path"] = path;
            version (Windows) row["requiresShell"] = path.toLower().endsWith(".cmd") || path.toLower().endsWith(".bat");
            else row["requiresShell"] = false;
            result["executables"].array ~= row;
        }
        return result;
    }
    if (action == "disk")
    {
        const path = nativePath(nativeString(args, "path", "."), workspace);
        enforce(exists(path), "Disk inspection path does not exist.");
        result["path"] = path;
        version (Windows)
        {
            ULARGE_INTEGER available, total, free;
            enforce(GetDiskFreeSpaceExW(toUTF16z(isDir(path) ? path : dirName(path)), &available, &total, &free) != 0,
                "GetDiskFreeSpaceEx failed: " ~ to!string(GetLastError()));
            result["availableBytes"] = available.QuadPart; result["totalBytes"] = total.QuadPart; result["freeBytes"] = free.QuadPart;
        }
        else version (Posix)
        {
            import core.sys.posix.sys.statvfs : statvfs, statvfs_t;
            import std.string : toStringz;
            statvfs_t info;
            enforce(statvfs(path.toStringz, &info) == 0, "statvfs failed.");
            result["availableBytes"] = cast(ulong)info.f_bavail * info.f_frsize;
            result["totalBytes"] = cast(ulong)info.f_blocks * info.f_frsize;
            result["freeBytes"] = cast(ulong)info.f_bfree * info.f_frsize;
        }
        else enforce(false, "Disk inspection is unavailable on this platform.");
        return result;
    }
    const limit = nativeInteger(args, "limit", 100);
    enforce(limit >= 1 && limit <= 200, "limit must be 1..200.");
    if (action == "processes")
    {
        const filter = nativeString(args, "name").toLower();
        const pid = nativeInteger(args, "pid", 0);
        result["processes"] = JSONValue.emptyArray;
        size_t matches;
        version (Windows)
        {
            auto snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            enforce(snapshot != INVALID_HANDLE_VALUE, "Could not snapshot processes.");
            scope(exit) CloseHandle(snapshot);
            PROCESSENTRY32W entry; entry.dwSize = entry.sizeof;
            for (auto more = Process32FirstW(snapshot, &entry); more; more = Process32NextW(snapshot, &entry))
            {
                checkNativeCancellation(cancelled);
                size_t end; while (end < entry.szExeFile.length && entry.szExeFile[end]) ++end;
                const name = toUTF8(entry.szExeFile[0 .. end]);
                if ((pid && entry.th32ProcessID != pid) || (filter.length && name.toLower().indexOf(filter) < 0)) continue;
                ++matches;
                if (result["processes"].array.length >= limit) continue;
                JSONValue row;
                row["pid"] = entry.th32ProcessID; row["parentPid"] = entry.th32ParentProcessID;
                row["name"] = name; row["threads"] = entry.cntThreads;
                result["processes"].array ~= row;
            }
        }
        else version (linux)
        {
            import std.file : dirEntries, SpanMode, readText;
            import std.string : strip;
            foreach (entry; dirEntries("/proc", SpanMode.shallow))
            {
                checkNativeCancellation(cancelled);
                long foundPid;
                try foundPid = to!long(baseName(entry.name)); catch (Exception) continue;
                if (pid && pid != foundPid) continue;
                string name;
                try name = readText(buildPath(entry.name, "comm")).strip(); catch (Exception) continue;
                if (filter.length && name.toLower().indexOf(filter) < 0) continue;
                ++matches;
                if (result["processes"].array.length >= limit) continue;
                JSONValue row; row["pid"] = foundPid; row["name"] = name;
                result["processes"].array ~= row;
            }
        }
        else enforce(false, "Process inspection is unavailable on this platform.");
        result["matches"] = matches;
        result["truncated"] = matches > limit;
        return result;
    }
    if (action == "ports")
    {
        const port = nativeInteger(args, "port", 0), pid = nativeInteger(args, "pid", 0);
        enforce(port >= 0 && port <= 65535, "port must be 0..65535.");
        result["listeners"] = JSONValue.emptyArray;
        version (Windows)
        {
            // Load a platform DLL, not a packaged dependency or external tool.
            auto library = LoadLibraryW(toUTF16z("iphlpapi.dll"));
            enforce(library !is null, "Could not load the Windows network inspection API.");
            scope(exit) FreeLibrary(library);
            alias TcpTable = extern(Windows) DWORD function(void*, DWORD*, BOOL, ULONG, int, ULONG);
            const table = cast(TcpTable)GetProcAddress(library, "GetExtendedTcpTable");
            enforce(table !is null, "GetExtendedTcpTable is unavailable.");
            size_t matches;
            foreach (family; [2U, 23U]) // AF_INET and AF_INET6
            {
                checkNativeCancellation(cancelled);
                DWORD size;
                auto status = table(null, &size, false, family, 3, 0); // TCP_TABLE_OWNER_PID_LISTENER
                enforce(status == 0 || status == 122, "Could not size TCP table: " ~ to!string(status));
                ubyte[] buffer;
                foreach (attempt; 0 .. 4)
                {
                    enforce(size <= 16 * 1024 * 1024, "TCP table exceeds inspection limit.");
                    buffer.length = size;
                    status = table(buffer.ptr, &size, false, family, 3, 0);
                    if (status != 122) break;
                }
                enforce(status == 0 && buffer.length >= 4, "Could not read TCP table.");
                const count = *cast(uint*)buffer.ptr;
                const stride = family == 2 ? 24 : 56;
                enforce(count <= (buffer.length - 4) / stride, "Invalid TCP table size.");
                foreach (i; 0 .. count)
                {
                    auto row = buffer.ptr + 4 + i * stride;
                    const portAt = family == 2 ? 8 : 20;
                    const ownerAt = family == 2 ? 20 : 52;
                    const localPort = cast(uint)row[portAt] * 256 + row[portAt + 1];
                    const owner = *cast(uint*)(row + ownerAt);
                    if ((port && port != localPort) || (pid && pid != owner)) continue;
                    ++matches;
                    if (result["listeners"].array.length >= limit) continue;
                    JSONValue listener;
                    listener["port"] = localPort; listener["pid"] = owner;
                    listener["family"] = family == 2 ? "ipv4" : "ipv6";
                    if (family == 2)
                        listener["address"] = to!string(row[4]) ~ "." ~ to!string(row[5]) ~ "." ~ to!string(row[6]) ~ "." ~ to!string(row[7]);
                    else
                    {
                        import std.format : format;
                        string address;
                        foreach (word; 0 .. 8)
                            address ~= (word ? ":" : "") ~ format!"%x"(cast(uint)row[word * 2] * 256 + row[word * 2 + 1]);
                        listener["address"] = address;
                    }
                    result["listeners"].array ~= listener;
                }
            }
            result["matches"] = matches; result["truncated"] = matches > limit;
        }
        else enforce(false, "TCP listener inspection is currently available on Windows only.");
        return result;
    }
    enforce(false, "action must be system, executables, disk, processes or ports.");
    return result;
}
