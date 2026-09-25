module auroraopencode.updater;

import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : copy, exists, getSize, mkdirRecurse, read, remove, rename,
    write;
import std.json : parseJSON;
import std.path : buildPath;
import std.process : Config, execute, spawnProcess, thisProcessID;
import std.stdio : stderr, stdin, stdout;
import std.string : toLower;

version (Windows)
{
    import core.sys.windows.windows : CloseHandle, DWORD, OpenProcess,
        SYNCHRONIZE, WaitForSingleObject;
}

private enum string releaseFile = "aurora-opencode-pro.exe";
private enum string projectId = "fg_9fdcaacf6d3ae23e";
private enum string releaseApi = "https://forge.boqsc.eu/api/release?project=" ~
    projectId;
private enum size_t maxReleaseBytes = 25 * 1024 * 1024;

struct UpdateCheck
{
    bool available;
    string stagedPath;
    string hash;
    string error;
}

private string fileHash(string path)
{
    return toLower(toHexString(sha256Of(read(path))));
}

/// Fetch a small release description, then stage and verify a newer EXE.
UpdateCheck checkForUpdate(string exePath, string stateDir)
{
    UpdateCheck result;
    try
    {
        auto metadata = execute(["curl.exe", "--fail", "--silent",
            "--show-error", "--location", "--max-time", "20", releaseApi]);
        if (metadata.status != 0)
            throw new Exception("Could not reach the release channel.");
        auto release = parseJSON(metadata.output);
        const hash = toLower(release["sha256"].str);
        const size = release["size"].integer;
        const url = release["url"].str;
        if (hash.length != 64 || size <= 0 || size > maxReleaseBytes ||
            url != "https://forge.boqsc.eu/~/" ~ projectId ~ "/" ~ releaseFile)
            throw new Exception("Release information is invalid.");
        if (hash == fileHash(exePath)) return result;

        mkdirRecurse(stateDir);
        const staged = buildPath(stateDir, "aurora-update-download.exe");
        auto download = execute(["curl.exe", "--fail", "--silent",
            "--show-error", "--location", "--max-time", "180",
            "--output", staged, url]);
        if (download.status != 0 || !exists(staged))
            throw new Exception("Could not download the update.");
        if (getSize(staged) != size || fileHash(staged) != hash)
        {
            remove(staged);
            throw new Exception("The downloaded EXE did not match its checksum.");
        }
        result.available = true;
        result.stagedPath = staged;
        result.hash = hash;
    }
    catch (Exception error) result.error = error.msg;
    return result;
}

/// Copy the current EXE to a temporary helper before the app closes.
bool launchUpdateHelper(string exePath, string stagedPath, string stateDir,
    string expectedHash)
{
    version (Windows)
    {
        try
        {
            mkdirRecurse(stateDir);
            const suffix = to!string(thisProcessID);
            const helper = buildPath(stateDir, "aurora-update-helper-" ~ suffix ~ ".exe");
            const pending = exePath ~ ".update-" ~ suffix;
            if (exists(helper)) remove(helper);
            if (exists(pending)) remove(pending);
            copy(exePath, helper);
            copy(stagedPath, pending);
            if (fileHash(pending) != expectedHash)
            {
                remove(pending);
                return false;
            }
            spawnProcess([helper, "--apply-update", exePath, pending, suffix,
                buildPath(stateDir, "update-error.txt")], stdin, stdout,
                stderr, null, Config.detached | Config.suppressConsole);
            return true;
        }
        catch (Exception) return false;
    }
    else return false;
}

/// Invoked by the temporary copy, after the original process exits.
/// Returns -1 when this is an ordinary app launch.
int runUpdateHelperMode(string[] args)
{
    if (args.length < 2 || args[1] != "--apply-update") return -1;
    if (args.length != 6) return 2;
    version (Windows)
    {
        const target = args[2];
        const pending = args[3];
        const errorPath = args[5];
        int pid;
        try pid = to!int(args[4]);
        catch (Exception) return 2;
        auto process = OpenProcess(SYNCHRONIZE, false, cast(DWORD) pid);
        if (process !is null)
        {
            WaitForSingleObject(process, 60_000);
            CloseHandle(process);
        }
        const backup = target ~ ".previous";
        bool moved;
        foreach (_; 0 .. 100)
        {
            try
            {
                if (exists(backup)) remove(backup);
                rename(target, backup);
                moved = true;
                break;
            }
            catch (Exception)
                Thread.sleep(300.msecs);
        }
        if (moved)
        {
            try
            {
                rename(pending, target);
                spawnProcess([target], stdin, stdout, stderr, null,
                    Config.detached | Config.suppressConsole);
                return 0;
            }
            catch (Exception)
            {
                try { if (exists(target)) remove(target); }
                catch (Exception) {}
                try rename(backup, target);
                catch (Exception) {}
            }
        }
        try write(errorPath, "Could not install the Aurora OpenCode update; " ~
            "the previous EXE was restored when possible.\n");
        catch (Exception) {}
        if (exists(target))
        {
            try spawnProcess([target], stdin, stdout, stderr, null,
                Config.detached | Config.suppressConsole);
            catch (Exception) {}
        }
        return 1;
    }
    else return 2;
}
