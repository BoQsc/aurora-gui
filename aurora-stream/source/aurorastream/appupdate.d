module aurorastream.appupdate;

import aurorastream.appversion : appBuildId, appVersion;
import core.sys.windows.windows;
import core.sys.windows.wininet;
import std.algorithm : endsWith, startsWith;
import std.array : appender;
import std.conv : to;
import std.file : SpanMode, copy, dirEntries, exists, getSize, mkdirRecurse,
    remove, rename, tempDir, thisExePath, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildPath, dirName;
import std.process : environment, spawnProcess;
import std.string : split, strip, toLower;
import std.utf : toUTF16z;

/// Update checking is only active in release builds; dev builds never poll.
bool updateCheckEnabled()
{
    return appBuildId != "dev";
}

private string releasesApiUrl()
{
    return "https://api.github.com/repos/BoQsc/aurora-gui/releases/latest";
}

private enum string _userAgent = "Aurora-Stream/" ~ appVersion ~
    " (+https://github.com/BoQsc/aurora-gui)";

private string httpGetText(string url)
{
    version (Windows)
    {
        auto hInternet = InternetOpenW(null, INTERNET_OPEN_TYPE_PRECONFIG,
            null, null, 0);
        if (hInternet is null) return "";
        scope (exit) InternetCloseHandle(hInternet);

        auto hUrl = InternetOpenUrlW(hInternet, toUTF16z(url),
            toUTF16z("User-Agent: " ~ _userAgent ~ "\r\n"), -1,
            INTERNET_FLAG_RELOAD | INTERNET_FLAG_SECURE | INTERNET_FLAG_NO_UI, 0);
        if (hUrl is null) return "";
        scope (exit) InternetCloseHandle(hUrl);

        auto output = appender!(ubyte[])();
        ubyte[8192] buffer;
        while (true)
        {
            DWORD bytesRead;
            if (!InternetReadFile(hUrl, buffer.ptr, cast(DWORD) buffer.length,
                &bytesRead)) break;
            if (bytesRead == 0) break;
            output.put(buffer[0 .. bytesRead]);
        }
        return cast(string) output.data;
    }
    else
    {
        return "";
    }
}

/// Returns the browser_download_url of the first asset whose name matches
/// "aurora-stream-v<version>.exe", or "" when none is found.
private string latestAssetUrl()
{
    string tag;
    string[] assetUrls;
    try
    {
        auto root = parseJSON(httpGetText(releasesApiUrl()));
        if (root.type != JSONType.object) return "";
        auto assets = "assets" in root.object;
        if (assets is null || assets.type != JSONType.array) return "";
        foreach (asset; assets.array)
        {
            if (asset.type != JSONType.object) continue;
            auto url = "browser_download_url" in asset.object;
            if (url is null || url.type != JSONType.string) continue;
            auto name = baseName(url.str).toLower();
            if (name.startsWith("aurora-stream-v") && name.endsWith(".exe"))
                return url.str;
        }
    }
    catch (Exception) {}
    return "";
}

/// Returns the latest release tag name (e.g. "v0.61.0") when it is newer than
/// the running version, otherwise "".
string newerReleaseTag()
{
    if (!updateCheckEnabled()) return "";
    string tag;
    try
    {
        auto root = parseJSON(httpGetText(releasesApiUrl()));
        if (root.type != JSONType.object) return "";
        auto value = "tag_name" in root.object;
        if (value is null || value.type != JSONType.string) return "";
        tag = value.str;
    }
    catch (Exception)
    {
        return "";
    }
    auto theirs = stripVersionPrefix(tag);
    if (theirs.length == 0) return "";
    return compareVersions(theirs, appVersion) > 0 ? tag : "";
}

private string stripVersionPrefix(string v)
{
    auto s = v.strip();
    if (s.startsWith("v")) s = s[1 .. $];
    return s;
}

private int compareVersions(string a, string b)
{
    auto pa = a.splitVersionParts();
    auto pb = b.splitVersionParts();
    const n = pa.length < pb.length ? pa.length : pb.length;
    foreach (i; 0 .. n)
    {
        if (pa[i] != pb[i])
            return pa[i] > pb[i] ? 1 : -1;
    }
    return pa.length > pb.length ? 1 : (pa.length < pb.length ? -1 : 0);
}

private int[] splitVersionParts(string v)
{
    int[] parts;
    foreach (part; v.split('.'))
    {
        int value;
        try value = to!int(part); catch (Exception) value = 0;
        parts ~= value;
    }
    return parts;
}

/// Downloads url to dest. Returns true on success.
bool downloadToFile(string url, string dest)
{
    version (Windows)
    {
        auto hInternet = InternetOpenW(null, INTERNET_OPEN_TYPE_PRECONFIG,
            null, null, 0);
        if (hInternet is null) return false;
        scope (exit) InternetCloseHandle(hInternet);

        auto hUrl = InternetOpenUrlW(hInternet, toUTF16z(url),
            toUTF16z("User-Agent: " ~ _userAgent ~ "\r\n"), -1,
            INTERNET_FLAG_RELOAD | INTERNET_FLAG_SECURE | INTERNET_FLAG_NO_UI, 0);
        if (hUrl is null) return false;
        scope (exit) InternetCloseHandle(hUrl);

        try
        {
            auto output = appender!(ubyte[])();
            ubyte[65536] buffer;
            while (true)
            {
                DWORD bytesRead;
                if (!InternetReadFile(hUrl, buffer.ptr, cast(DWORD) buffer.length,
                    &bytesRead)) break;
                if (bytesRead == 0) break;
                output.put(buffer[0 .. bytesRead]);
            }
            write(dest, output.data);
            return exists(dest) && getSize(dest) > 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    else
    {
        return false;
    }
}

/// Per-user rollback archive folder.
private string archiveRoot()
{
    return buildPath(environment.get("APPDATA"), "Aurora Stream", "versions");
}

string rollbackArchivePath(string ver)
{
    return buildPath(archiveRoot(), ver, "aurora-stream.exe");
}

/// Prune the archive to the most recent N versions.
private void pruneArchive(int keep = 3)
{
    try
    {
        if (!exists(archiveRoot())) return;
        string[] versions;
        foreach (entry; dirEntries(archiveRoot(), SpanMode.depth, false))
        {
            if (!entry.isDir) continue;
            versions ~= baseName(entry.name);
        }
        sortVersionsDesc(versions);
        if (versions.length > keep)
            foreach (old; versions[keep .. $])
            {
                try
                {
                    if (exists(buildPath(archiveRoot(), old)))
                        remove(buildPath(archiveRoot(), old));
                }
                catch (Exception) {}
            }
    }
    catch (Exception) {}
}

private void sortVersionsDesc(ref string[] versions)
{
    import std.algorithm : sort;
    sort!((a, b) => compareVersions(stripVersionPrefix(a),
        stripVersionPrefix(b)) > 0)(versions);
}

/// Downloads the latest release, returns the staged exe path or "".
string stageLatestUpdate()
{
    const url = latestAssetUrl();
    if (url.length == 0) return "";
    const dest = buildPath(tempDir(), "aurora-update",
        "aurora-stream-new.exe");
    try
    {
        if (!exists(dirName(dest))) mkdirRecurse(dirName(dest));
        if (exists(dest)) remove(dest);
        if (!downloadToFile(url, dest)) return "";
        return dest;
    }
    catch (Exception)
    {
        return "";
    }
}

/// Spawns the updater (a temp copy of this exe) and returns. The caller then
/// exits the app; the updater replaces the real exe and relaunches it.
bool launchUpdater(string stagedExe)
{
    version (Windows)
    {
        try
        {
            const realExe = thisExePath();
            const dir = buildPath(tempDir(), "aurora-update");
            if (!exists(dir)) mkdirRecurse(dir);
            const updater = buildPath(dir, "aurora-updater.exe");
            if (exists(updater)) remove(updater);
            copy(realExe, updater);
            const parentPid = to!string(GetCurrentProcessId());
            const rollback = rollbackArchivePath(stripVersionPrefix(appVersion));
            spawnProcess([updater, "--apply-update", stagedExe, realExe,
                rollback, parentPid]);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
    else
    {
        return false;
    }
}

/// Entry point for the `--apply-update` mode (run from the temp copy).
/// args: [exe, "--apply-update", stagedExe, realExe, rollbackDest, parentPid]
int runApplyUpdateMode(string[] args)
{
    if (args.length < 5) return 2;
    const stagedExe = args[2];
    const realExe = args[3];
    const rollbackDest = args[4];
    long parentPid = 0;
    if (args.length >= 6)
        try parentPid = to!long(args[5]); catch (Exception) {}

    version (Windows)
    {
        // Wait for the parent (main app) process to fully exit so its exe is
        // unlocked before we try to replace it.
        if (parentPid > 0)
        {
            auto handle = OpenProcess(PROCESS_QUERY_INFORMATION | SYNCHRONIZE,
                FALSE, cast(DWORD) parentPid);
            if (handle !is null)
            {
                WaitForSingleObject(handle, 30000);
                CloseHandle(handle);
            }
        }

        try
        {
            // Archive the current exe for rollback.
            if (rollbackDest.length > 0)
            {
                const dir = dirName(rollbackDest);
                if (!exists(dir)) mkdirRecurse(dir);
                if (exists(rollbackDest)) remove(rollbackDest);
                rename(realExe, rollbackDest);
            }
            // Install the staged exe.
            copy(stagedExe, realExe);
            pruneArchive();
            // Relaunch the freshly installed exe.
            spawnProcess([realExe]);
        }
        catch (Exception)
        {
            // Fallback: still try to launch the installed exe if it exists.
            try if (exists(realExe)) spawnProcess([realExe]); catch (Exception) {}
            return 1;
        }
        scope (exit) cleanupUpdateArtifacts(stagedExe);
        return 0;
    }
    else
    {
        return 0;
    }
}

/// Best-effort removal of the staged download and the temp updater copy.
private void cleanupUpdateArtifacts(string stagedExe)
{
    try
    {
        if (exists(stagedExe)) remove(stagedExe);
    }
    catch (Exception) {}
    try
    {
        if (exists(thisExePath())) remove(thisExePath());
    }
    catch (Exception) {}
}
