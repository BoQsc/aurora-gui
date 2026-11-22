module aurorahost.single_instance;

import core.thread : Thread;
import core.time : msecs;
import std.utf : toUTF16z;

version (Windows)
{
    import core.sys.windows.windows : CloseHandle, CreateMutexW, ERROR_ALREADY_EXISTS,
        FindWindowW, GetLastError, HANDLE, HWND, IsIconic, ReleaseMutex,
        SW_RESTORE, SW_SHOW, SetForegroundWindow, ShowWindow;
}

/**
 * One process-wide application instance claim.
 *
 * Apps that own a single top-level window should acquire one before creating
 * that window. The claim is a named local mutex, so a second launch can detect
 * the first process and activate its existing window instead of opening another.
 * The mutex is released automatically when the owning process exits.
 */
struct HostInstance
{
    version (Windows)
        private HANDLE _mutex;
    private bool _owned;

    bool owned() const
    {
        return _owned;
    }

    /**
     * Try to become the one host instance for `key`.
     * Returns false when another process already owns the key.
     */
    bool acquire(string key)
    {
        if (key.length == 0)
            return false;
        version (Windows)
        {
            if (_mutex !is null)
                return _owned;
            const name = "Local\\AuroraHost-" ~ key;
            _mutex = CreateMutexW(null, 0, toUTF16z(name));
            if (_mutex is null)
                return false;
            if (GetLastError == ERROR_ALREADY_EXISTS)
            {
                CloseHandle(_mutex);
                _mutex = null;
                return false;
            }
            _owned = true;
            return true;
        }
        else
        {
            _owned = true;
            return true;
        }
    }

    void release()
    {
        version (Windows)
        {
            if (_mutex is null)
                return;
            if (_owned)
                ReleaseMutex(_mutex);
            CloseHandle(_mutex);
            _mutex = null;
        }
        _owned = false;
    }

    ~this()
    {
        release();
    }
}

/**
 * Bring the already-running window with `title` to the foreground.
 * Returns false if no matching window exists within the short startup window.
 */
bool activateWindow(string title)
{
    if (title.length == 0)
        return false;
    version (Windows)
    {
        HWND window;
        foreach (_; 0 .. 20)
        {
            window = FindWindowW(null, toUTF16z(title));
            if (window !is null)
                break;
            Thread.sleep(50.msecs);
        }
        if (window is null)
            return false;
        if (IsIconic(window))
            ShowWindow(window, SW_RESTORE);
        else
            ShowWindow(window, SW_SHOW);
        SetForegroundWindow(window);
        return true;
    }
    else
    {
        return false;
    }
}