module experiment.aurorahost.scene_icon;

import std.base64 : Base64;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : exists, getSize, mkdirRecurse, tempDir, write;
import std.path : buildPath;

/// A scene icon is small enough to live inline without bloating the parser.
enum MaxSceneIconBase64 = 512 * 1024;

/// Decode the base64 ICO carried by `scene.window.icon`.
ubyte[] decodeSceneIcon(string encoded)
{
    return decodeIcon(encoded, "scene.window.icon");
}

/// Decode a base64 ICO field, naming the field in validation errors.
ubyte[] decodeIcon(string encoded, string label)
{
    enforce(encoded.length > 0,
        label ~ " must not be empty");
    enforce(encoded.length <= MaxSceneIconBase64,
        label ~ " is too large");
    try
        return Base64.decode(encoded);
    catch (Exception error)
        throw new Exception(
            label ~ " is not valid base64: " ~ error.msg);
}

/**
 * Write an embedded ICO to a content-addressed temp file and return its path.
 *
 * The platform icon API is path-based. Hashing the bytes keeps repeated scene
 * loads on the same file while a changed icon always gets a new path, so a live
 * reload cannot reuse a stale icon. The file is a runtime cache, not a package
 * sidecar.
 */
string sceneIconPath(const(ubyte)[] bytes)
{
    if (bytes.length == 0)
        return "";
    try
    {
        const directory = buildPath(tempDir(), "Aurora-Host-scenes");
        const name = sha256Of(bytes).toHexString().idup ~ ".ico";
        const path = buildPath(directory, name);
        if (!exists(directory))
            mkdirRecurse(directory);
        if (!exists(path) || getSize(path) != bytes.length)
            write(path, bytes);
        return path;
    }
    catch (Exception)
        return "";
}