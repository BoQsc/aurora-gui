module aurorahost.runtime_policy;

import std.datetime : SysTime;
import std.file : exists, readText, timeLastModified;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment;

struct RuntimePolicy
{
    bool protectHost = true;
    bool allowInjectedInput = false;
    bool clampGeometry = true;
}

interface RuntimePolicyModule
{
    RuntimePolicy current();
    bool reload();
}

final class FileRuntimePolicy : RuntimePolicyModule
{
    private string _path;
    private RuntimePolicy _policy;
    private SysTime _mtime;

    this(string path = "")
    {
        _path = path.length ? path : defaultPolicyPath();
        reload();
    }

    RuntimePolicy current() { return _policy; }

    bool reload()
    {
        if (!exists(_path))
            return false;
        try
        {
            const parsed = parseJSON(readText(_path));
            RuntimePolicy next;
            if (auto value = "protectHost" in parsed.object)
                next.protectHost = value.get!bool;
            if (auto value = "allowInjectedInput" in parsed.object)
                next.allowInjectedInput = value.get!bool;
            if (auto value = "clampGeometry" in parsed.object)
                next.clampGeometry = value.get!bool;
            _policy = next;
            _mtime = timeLastModified(_path);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    bool changed()
    {
        if (!exists(_path))
            return false;
        return _mtime != timeLastModified(_path);
    }

    private static string defaultPolicyPath()
    {
        auto root = environment.get("LOCALAPPDATA", "");
        if (root.length == 0)
            root = ".";
        return buildPath(root, "AuroraHost", "runtime-policy.json");
    }
}
