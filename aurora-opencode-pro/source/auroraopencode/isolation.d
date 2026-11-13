module auroraopencode.isolation;
import std.process : environment;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : isAbsolute, absolutePath;
import std.string : startsWith;
import auroraopencode.checkout : canonicalPath;

/// Opt-in native path boundary for replay hosts. This checks structured tool
/// arguments; it is not an operating-system sandbox for arbitrary programs.
string isolatedToolError(string tool, string arguments, string workspace)
{
    const configured = environment.get("AURORA_TOOL_ROOT", "");
    if (!configured.length) return "";
    const root = canonicalPath(configured);
    bool inside(string path)
    {
        const full = canonicalPath(isAbsolute(path) ? path : absolutePath(path, workspace));
        return full == root || full.startsWith(root ~ "/") || full.startsWith(root ~ "\\");
    }
    if (!inside(workspace)) return "Isolated task workspace is outside the replay root.";
    if (tool == "computer" || tool == "rebuild" || tool == "sync" || tool == "open")
        return "This operation is unavailable in an isolated source replay.";
    JSONValue value;
    try value = parseJSON(arguments); catch (Exception) return "";
    string error;
    void check(JSONValue node, string key = "")
    {
        if (error.length) return;
        if (node.type == JSONType.object)
            foreach (name, child; node.object)
                if (name != "content" && name != "patch" && name != "oldString" && name != "newString" && name != "program") check(child, name);
        if (node.type == JSONType.array) foreach (child; node.array) check(child, key);
        if (node.type != JSONType.string) return;
        const path = node.str;
        if ((isAbsolute(path) || key == "filePath" || key == "workdir" || key == "path" || key == "destination") && !inside(path))
            error = "Path is outside this isolated task: " ~ path ~ ". Use the replay checkout or its private TEMP directory: " ~ configured;
    }
    check(value);
    return error;
}
