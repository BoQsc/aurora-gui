module auroraopencode.nativeio;

import std.file : exists, isSymlink, mkdirRecurse, remove, rename, write;
import std.path : absolutePath, buildNormalizedPath, dirName;
import std.json : JSONType, JSONValue;
import std.exception : enforce, collectException;
import std.uuid : randomUUID;

alias NativeCancel = bool delegate();
alias NativeProgress = void delegate(string);

void checkNativeCancellation(NativeCancel cancelled)
{
    enforce(cancelled is null || !cancelled(), "Stopped: operation cancelled.");
}

string nativePath(string path, string workspace)
{
    enforce(path.length > 0, "A non-empty path is required.");
    return buildNormalizedPath(absolutePath(path, workspace));
}

string nativeString(const ref JSONValue args, string key, string fallback = "")
{
    auto field = key in args.object;
    if (field is null) return fallback;
    enforce(field.type == JSONType.string, key ~ " must be a string.");
    return field.str;
}

long nativeInteger(const ref JSONValue args, string key, long fallback)
{
    auto field = key in args.object;
    if (field is null) return fallback;
    enforce(field.type == JSONType.integer, key ~ " must be an integer.");
    return field.integer;
}

bool nativeBool(const ref JSONValue args, string key, bool fallback = false)
{
    auto field = key in args.object;
    if (field is null) return fallback;
    enforce(field.type == JSONType.true_ || field.type == JSONType.false_, key ~ " must be a boolean.");
    return field.type == JSONType.true_;
}

// Check every existing component, including the final component. Archive and
// data operations must not silently write through links outside their target.
void rejectNativeLinks(string path)
{
    for (auto part = path; part.length; part = dirName(part))
    {
        if (exists(part))
            enforce(!isSymlink(part), "Symbolic-link/reparse path is unsupported: " ~ part);
        const parent = dirName(part);
        if (parent == part) break;
    }
}

string nativeTemporaryPath(string target)
{
    return target ~ ".aurora-" ~ randomUUID().toString() ~ ".tmp";
}

void atomicNativeWrite(string path, const(void)[] bytes)
{
    rejectNativeLinks(path);
    mkdirRecurse(dirName(path));
    const temporary = nativeTemporaryPath(path);
    scope(exit) if (exists(temporary)) collectException(remove(temporary));
    write(temporary, bytes);
    rename(temporary, path);
}
