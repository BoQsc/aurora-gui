module auroraopencode.checkout;

import core.sync.mutex : Mutex;
import core.time : MonoTime, msecs, seconds;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : exists, isDir;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.string : startsWith, toLower;

version (Windows)
{
    import core.sys.windows.windows;
    import std.utf : toUTF16z, toUTF8;
}

/// Resolve existing ancestors too, so a new file and a junction to its parent
/// use the same identity. A worktree's .git file is its own working-tree root.
public string canonicalPath(string path)
{
    if (!path.length) path = ".";
    auto full = buildNormalizedPath(absolutePath(path));
    auto ancestor = full;
    while (!exists(ancestor))
    {
        const parent = dirName(ancestor);
        if (parent == ancestor) break;
        ancestor = parent;
    }
    version (Windows)
    {
        auto handle = CreateFileW(toUTF16z(ancestor), 0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null,
            OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
        if (handle != INVALID_HANDLE_VALUE)
        {
            scope (exit) CloseHandle(handle);
            wchar[] buffer = new wchar[32768];
            const size = GetFinalPathNameByHandleW(handle, buffer.ptr,
                cast(DWORD) buffer.length, 0);
            if (size && size < buffer.length)
            {
                auto physical = toUTF8(buffer[0 .. size]);
                if (physical.startsWith("\\\\?\\UNC\\")) physical = "\\\\" ~ physical[8 .. $];
                else if (physical.startsWith("\\\\?\\")) physical = physical[4 .. $];
                full = physical ~ full[ancestor.length .. $];
            }
        }
    }
    version (Windows) return full.toLower();
    else return full;
}

public string checkoutIdentity(string path)
{
    auto full = canonicalPath(path);
    auto cursor = exists(full) && !isDir(full) ? dirName(full) : full;
    while (true)
    {
        if (exists(buildPath(cursor, ".git")))
        {
            full = cursor;
            break;
        }
        const parent = dirName(cursor);
        if (parent == cursor) break;
        cursor = parent;
    }
    version (Windows) return full.toLower();
    else return full;
}

private __gshared Mutex registry;
private __gshared Mutex[string] locks;
shared static this() { registry = new Mutex(); }

/// Held until the physical operation ends, including after logical Stop.
/// Windows named mutexes also serialize other Aurora processes and helpers.
public final class CheckoutLease
{
    version (Windows) private HANDLE handle;
    else private Mutex mutex;

    this(string path, bool delegate() cancelled = null, int timeoutSeconds = 45,
        void delegate(string) waiting = null)
    {
        const identity = checkoutIdentity(path);
        version (Windows)
        {
            const name = "Local\\AuroraCheckout-" ~ toHexString(sha256Of(identity));
            handle = CreateMutexW(null, false, toUTF16z(name));
            enforce(handle !is null, "Could not create the Aurora checkout lock.");
            const deadline = MonoTime.currTime + seconds(timeoutSeconds);
            auto nextNotice = MonoTime.currTime;
            while (true)
            {
                if (cancelled !is null && cancelled())
                {
                    CloseHandle(handle); handle = null;
                    throw new Exception("Stopped while waiting for the source checkout.");
                }
                const state = WaitForSingleObject(handle, 50);
                if (state == WAIT_OBJECT_0 || state == WAIT_ABANDONED) break;
                if (waiting !is null && MonoTime.currTime >= nextNotice)
                {
                    waiting("Waiting for source checkout access: " ~ identity ~
                        ". No files are being searched yet; another source operation owns the lock.");
                    nextNotice = MonoTime.currTime + msecs(200);
                }
                if (state == WAIT_FAILED || MonoTime.currTime >= deadline)
                {
                    CloseHandle(handle); handle = null;
                    throw new Exception("Source checkout is still in use. Wait for its active tools before retrying.");
                }
            }
        }
        else
        {
            synchronized (registry)
            {
                if (identity !in locks) locks[identity] = new Mutex();
                mutex = locks[identity];
            }
            mutex.lock();
        }
    }

    void release()
    {
        version (Windows)
        {
            if (handle !is null) { ReleaseMutex(handle); CloseHandle(handle); handle = null; }
        }
        else if (mutex !is null) { mutex.unlock(); mutex = null; }
    }
}
