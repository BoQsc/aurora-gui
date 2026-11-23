module aurorahost.host_module;

import core.sys.windows.windows : FreeLibrary, GetProcAddress, HMODULE,
    LoadLibraryA;
import std.string : toStringz;

final class HostModule
{
    private HMODULE _handle;

    void load(string path)
    {
        unload();
        _handle = LoadLibraryA(toStringz(path));
        if (_handle is null)
            throw new Exception("could not load host module: " ~ path);
    }

    void* symbol(string name)
    {
        if (_handle is null)
            return null;
        return cast(void*) GetProcAddress(_handle, toStringz(name));
    }

    bool loaded() const { return _handle !is null; }

    void unload()
    {
        if (_handle !is null)
        {
            FreeLibrary(_handle);
            _handle = null;
        }
    }

    ~this() { unload(); }
}
