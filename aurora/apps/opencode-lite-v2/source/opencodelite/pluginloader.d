module opencodelite.pluginloader;

import aurorahost.scene : NodeRegistry;
import aurorahost.console : errLine;
import core.sys.windows.windows : FreeLibrary, GetCurrentProcessId, GetProcAddress,
    HMODULE, LoadLibraryW, SetErrorMode;
import std.conv : to;
import std.datetime : SysTime;
import std.file : copy, exists, read, remove, tempDir, timeLastModified;
import std.path : buildPath;

import std.string : fromStringz, toStringz;
import std.utf : toUTF16z;

alias PluginInit = extern(C) int function(LitePluginApi*);
alias PluginAction = extern(C) void function(const(char)*, const(char)*);
alias PluginTick = extern(C) void function();
alias PluginRefresh = extern(C) void function();
alias PluginShutdown = extern(C) void function();

struct LitePluginApi
{
    void* context;
    extern(C) void function(void*, const(char)*, const(char)*) setText;
    extern(C) const(char)* function(void*, const(char)*) getText;
    extern(C) void function(void*, const(char)*, int) setEnabled;
}

extern(C) private void pluginSetText(void* context, const(char)* node,
    const(char)* text)
{
    auto self = cast(LitePlugin) context;
    self.registry.setText(fromStringz(node).idup, fromStringz(text).idup);
}

extern(C) private const(char)* pluginGetText(void* context, const(char)* node)
{
    auto self = cast(LitePlugin) context;
    self.textBuffer = self.registry.text(fromStringz(node).idup);
    return toStringz(self.textBuffer);
}

extern(C) private void pluginSetEnabled(void* context, const(char)* node,
    int enabled)
{
    auto self = cast(LitePlugin) context;
    self.registry.setEnabled(fromStringz(node).idup, enabled != 0);
}

/// Loads an optional controller DLL. The host scene and window are never
/// recreated when the DLL is replaced; only the controller is reinitialized.
///
/// A candidate is copied to a unique cache path before loading, so the source
/// DLL remains replaceable. A failed candidate is discarded without disturbing
/// the last good module.
final class LitePlugin
{
    NodeRegistry registry;
    private string _path;
    private HMODULE _module;
    private string _loadedPath;
    private SysTime _stamp;
    private size_t _serial;
    private string _lastError;
    private LitePluginApi _api;
    private PluginAction _action;
    private PluginTick _tick;
    private PluginRefresh _refresh;
    private PluginShutdown _shutdown;
    string textBuffer;

    this(NodeRegistry registry, string path)
    {
        this.registry = registry;
        _path = path;
        _api.context = cast(void*) this;
        _api.setText = &pluginSetText;
        _api.getText = &pluginGetText;
        _api.setEnabled = &pluginSetEnabled;
        // A malformed DLL must be rejected without Windows showing a loader
        // error dialog over the running host.
        SetErrorMode(0x0001 | 0x8000);
        _stamp = sourceStamp();
        if (!loadCandidate())
            throw new Exception(_lastError);
        registry.onAction = delegate(string node, string action)
        {
            if (_action is null)
                return;
            try
                _action(toStringz(node), toStringz(action));
            catch (Throwable error)
                reportError("action", error);
        };
        registry.onService = delegate(double delta)
        {
            if (_tick !is null)
            {
                try
                    _tick();
                catch (Throwable error)
                    reportError("service", error);
            }
            poll();
        };
        registry.onAfterApply = delegate()
        {
            if (_refresh is null)
                return;
            try
                _refresh();
            catch (Throwable error)
                reportError("refresh", error);
        };
    }

    private SysTime sourceStamp()
    {
        try
            return timeLastModified(_path);
        catch (Exception)
            return SysTime.init;
    }

    private bool loadCandidate()
    {
        if (!exists(_path))
        {
            _lastError = "controller plugin is missing: " ~ _path;
            return false;
        }
        const stamp = sourceStamp();
        string cachePath;
        HMODULE candidate;
        try
        {
            cachePath = buildPath(tempDir(),
                "aurora-lite-controller-" ~ to!string(GetCurrentProcessId()) ~
                "-" ~ to!string(++_serial) ~ ".dll");
            copy(_path, cachePath);
            if (!validImage(cachePath))
            {
                remove(cachePath);
                _lastError = "controller plugin is not a valid DLL image";
                stampAndReport();
                return false;
            }
            candidate = LoadLibraryW(toUTF16z(cachePath));
            if (candidate is null)
            {
                _lastError = "cannot load controller plugin: " ~ _path;
                stampAndReport();
                return false;
            }

            auto init = cast(PluginInit) GetProcAddress(candidate,
                "aurora_lite_plugin_init".ptr);
            auto action = cast(PluginAction) GetProcAddress(candidate,
                "aurora_lite_plugin_action".ptr);
            auto tick = cast(PluginTick) GetProcAddress(candidate,
                "aurora_lite_plugin_tick".ptr);
            auto refresh = cast(PluginRefresh) GetProcAddress(candidate,
                "aurora_lite_plugin_refresh".ptr);
            auto shutdown = cast(PluginShutdown) GetProcAddress(candidate,
                "aurora_lite_plugin_shutdown".ptr);
            if (init is null || action is null || tick is null
                    || refresh is null)
            {
                FreeLibrary(candidate);
                remove(cachePath);
                _lastError = "controller plugin exports are incomplete";
                stampAndReport();
                return false;
            }
            if (init(&_api) != 0)
            {
                if (shutdown !is null)
                    shutdown();
                FreeLibrary(candidate);
                remove(cachePath);
                _lastError = "controller plugin init failed";
                stampAndReport();
                return false;
            }

            // Swap in the initialized candidate. The old module is retired
            // without unloading while the process may still have a worker
            // thread; its cache file remains valid until process exit.
            auto oldShutdown = _shutdown;
            _module = candidate;
            _loadedPath = cachePath;
            _action = action;
            _tick = tick;
            _refresh = refresh;
            _shutdown = shutdown;
            if (oldShutdown !is null)
            {
                try
                    oldShutdown();
                catch (Throwable)
                {
                }
            }
            _lastError = "";
            _stamp = stamp;
            return true;
        }
        catch (Exception error)
        {
            if (candidate !is null)
                FreeLibrary(candidate);
            if (cachePath.length != 0 && exists(cachePath))
                remove(cachePath);
            _lastError = "controller plugin load failed: " ~ error.msg;
            stampAndReport();
            return false;
        }
    }

    private bool validImage(string path)
    {
        try
        {
            const bytes = cast(const(ubyte)[]) read(path);
            if (bytes.length < 0x40 || bytes[0] != 'M' || bytes[1] != 'Z')
                return false;
            const pe = cast(size_t) bytes[0x3C] |
                cast(size_t) bytes[0x3D] << 8 |
                cast(size_t) bytes[0x3E] << 16 |
                cast(size_t) bytes[0x3F] << 24;
            if (pe + 24 + 2 > bytes.length ||
                bytes[pe] != 'P' || bytes[pe + 1] != 'E' ||
                bytes[pe + 2] != 0 || bytes[pe + 3] != 0)
                return false;
            const machine = cast(ushort) (bytes[pe + 4] |
                bytes[pe + 5] << 8);
            const characteristics = cast(ushort) (bytes[pe + 22] |
                bytes[pe + 23] << 8);
            const magic = cast(ushort) (bytes[pe + 24] |
                bytes[pe + 25] << 8);
            return machine == 0x8664 && (characteristics & 0x2000) != 0 &&
                magic == 0x20B;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private void stampAndReport()
    {
        _stamp = sourceStamp();
        errLine("aurora-host: " ~ _lastError);
        registry.setText("lite-status", "Controller error: " ~ _lastError);
    }

    private void reportError(string where, Throwable error)
    {
        errLine("aurora-host: controller " ~ where ~ " failed: " ~
            error.msg);
        registry.setText("lite-status", "Controller error: " ~ error.msg);
    }

    private void poll()
    {
        const stamp = sourceStamp();
        if (stamp == _stamp)
            return;
        loadCandidate();
    }
}
