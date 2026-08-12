module auroraopencode.tools;

import auroraopencode.core : OpenCodeToolCall, OpenCodeToolDef;
import std.file : dirEntries, exists, isFile, isDir, SpanMode, readText,
    write, mkdirRecurse, remove, tempDir;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildNormalizedPath, buildPath, expandTilde, isAbsolute;
import std.process : Pid, waitTimeout, kill, spawnShell, wait;
import std.regex : Regex, matchFirst, regex;
import std.string : replace, strip;
import std.conv : to;
import std.exception : collectException;
import core.time : seconds, Duration, MonoTime;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.algorithm : sort, map, filter;
import std.array : appender, array;
import std.range : take;

// ---------------------------------------------------------------------------
// Built-in tool definitions advertised to the model. The parameter schemas
// mirror the opencode app's tool registry so models behave the same here.
// ---------------------------------------------------------------------------

public immutable OpenCodeToolDef[] builtinToolDefinitions = [
    OpenCodeToolDef(
        "bash",
        "Execute shell commands in the workspace. Use this to run build " ~
        "commands, inspect the environment, or manipulate files when the " ~
        "dedicated tools do not fit. Prefer the read/write/glob/grep tools " ~
        "for file access.",
        `{"type":"object","properties":{"command":{"type":"string","description":"The command to execute"}},"required":["command"]}`
    ),    OpenCodeToolDef(
        "read",
        "Read the contents of a text file from the workspace.",
        `{"type":"object","properties":{"filePath":{"type":"string","description":"Path to the file, relative to the workspace or absolute"}},"required":["filePath"]}`
    ),
    OpenCodeToolDef(
        "write",
        "Create or overwrite a text file in the workspace. Creates parent " ~
        "directories as needed.",
        `{"type":"object","properties":{"filePath":{"type":"string","description":"Path to the file, relative to the workspace or absolute"},"content":{"type":"string","description":"The full text to write"}},"required":["filePath","content"]}`
    ),
    OpenCodeToolDef(
        "glob",
        "List files and directories under the workspace matching a glob " ~
        "pattern (e.g. **/*.d).",
        `{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern relative to the workspace"}},"required":["pattern"]}`
    ),
    OpenCodeToolDef(
        "grep",
        "Search file contents in the workspace with a regular expression. " ~
        "Returns matching file paths.",
        `{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression to search for"},"include":{"type":"string","description":"Optional file extension filter, e.g. *.d"}},"required":["pattern"]}`
    ),
];

public struct ToolExecution
{
    string name;
    string output;
    bool failed;
}

/// Resolve a path argument against the workspace; absolute paths pass through.
public string resolveToolPath(string value, string workspace)
{
    auto path = value.strip();
    if (path.length == 0) return "";
    path = expandTilde(path);
    if (isAbsolute(path)) return buildNormalizedPath(path);
    return buildNormalizedPath(buildPath(workspace, path));
}

private int maxOutputLines = 400;
private int maxOutputBytes = 40_000;

private string truncateOutput(string text)
{
    if (text.length <= maxOutputBytes) return text;
    return text[0 .. maxOutputBytes] ~ "\n…(output truncated)";
}

private ToolExecution runBash(string args, string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string command;
    if (value.type == JSONType.object)
    {
        if (auto field = "command" in value.object)
            if (field.type == JSONType.string)
                command = field.str;
    }
    if (command.length == 0)
        return ToolExecution("bash",
            "Error: bash requires a non-empty `command` argument.", true);

    // Run through the platform shell with combined output captured to a
    // temp file so it can be read back after the process exits (the D
    // std.process execute/pipe helpers are not used because a hanging
    // command must be killable without blocking the UI thread).
    const outPath = buildNormalizedPath(buildPath(
        cast(string) tempDir(), "aurora-opencode-tool-" ~
        to!string(cast(long) MonoTime.currTime.ticks) ~ ".out"));
    string shellLine = command ~ " > \"" ~ outPath ~ "\" 2>&1";
    Pid pid;
    try pid = spawnShell(shellLine);
    catch (Exception error)
        return ToolExecution("bash", "Error: could not start shell: " ~
            error.msg, true);

    const timeout = 60.seconds;
    auto result = waitTimeout(pid, timeout);
    bool timedOut;
    if (!result.terminated)
    {
        timedOut = true;
        try kill(pid);
        catch (Exception) {}
        try wait(pid);
        catch (Exception) {}
    }

    string output;
    if (exists(outPath))
    {
        try output = readText(outPath);
        catch (Exception) {}
        try remove(outPath);
        catch (Exception) {}
    }
    if (timedOut)
        output = (output.length > 0 ? output ~ "\n" : "") ~
            "\n…(command timed out after 60s and was killed)";
    if (output.length == 0) output = "(no output)";
    return ToolExecution("bash", truncateOutput(output), timedOut);
}

private ToolExecution runRead(string args, string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string filePath;
    if (value.type == JSONType.object)
    {
        if (auto field = "filePath" in value.object)
            if (field.type == JSONType.string)
                filePath = field.str;
    }
    if (filePath.length == 0)
        return ToolExecution("read",
            "Error: read requires a `filePath` argument.", true);
    const path = resolveToolPath(filePath, workspace);
    if (!exists(path) || !isFile(path))
        return ToolExecution("read", "Error: file not found: " ~ path, true);
    string text;
    try text = readText(path);
    catch (Exception error)
        return ToolExecution("read", "Error: could not read file: " ~
            error.msg, true);
    return ToolExecution("read", truncateOutput(text), false);
}

private ToolExecution runWrite(string args, string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string filePath;
    string content;
    if (value.type == JSONType.object)
    {
        if (auto field = "filePath" in value.object)
            if (field.type == JSONType.string)
                filePath = field.str;
        if (auto field = "content" in value.object)
            if (field.type == JSONType.string)
                content = field.str;
    }
    if (filePath.length == 0)
        return ToolExecution("write",
            "Error: write requires `filePath` and `content` arguments.", true);
    const path = resolveToolPath(filePath, workspace);
    try
    {
        write(path, content);
    }
    catch (Exception error)
        return ToolExecution("write", "Error: could not write file: " ~
            error.msg, true);
    return ToolExecution("write", "Wrote " ~ path ~ " (" ~
        to!string(content.length) ~ " chars).", false);
}

/// Convert a glob pattern to a regular expression. `**` crosses directory
/// boundaries; `*` stays within one path segment. Path separators are treated
/// as `/` so patterns behave consistently on Windows.
private Regex!(char) globToRegex(string pattern)
{
    string translated;
    size_t index;
    while (index < pattern.length)
    {
        const ch = pattern[index];
        if (ch == '*')
        {
            const isDouble = index + 1 < pattern.length &&
                pattern[index + 1] == '*';
            const isTriple = isDouble && index + 2 < pattern.length &&
                pattern[index + 2] == '*';
            if (isTriple)
            {
                // `***` behaves like `**` at the end; treat as crossing.
                translated ~= `.*`;
                index += 3;
                continue;
            }
            if (isDouble && index + 2 < pattern.length &&
                (pattern[index + 2] == '/' || pattern[index + 2] == '\\'))
            {
                translated ~= `(?:.*/)?`;
                index += 3;
                continue;
            }
            if (isDouble)
            {
                translated ~= `.*`;
                index += 2;
                continue;
            }
            translated ~= `[^/]*`;
            ++index;
            continue;
        }
        if (ch == '?')
        {
            translated ~= `[^/]`;
            ++index;
            continue;
        }
        if (ch == '\\' || ch == '/')
        {
            translated ~= `/`;
            ++index;
            continue;
        }
        switch (ch)
        {
            case '.', '+', '(', ')', '[', ']', '{', '}', '^', '$', '|':
                translated ~= '\\';
                translated ~= ch;
                break;
            default:
                translated ~= ch;
                break;
        }
        ++index;
    }
    return regex("^" ~ translated ~ "$");
}

private ToolExecution runGlob(string args, string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string pattern;
    if (value.type == JSONType.object)
    {
        if (auto field = "pattern" in value.object)
            if (field.type == JSONType.string)
                pattern = field.str;
    }
    if (pattern.length == 0)
        return ToolExecution("glob",
            "Error: glob requires a `pattern` argument.", true);

    const normalizedPattern = pattern.replace("\\", "/");
    Regex!(char) re;
    try re = globToRegex(normalizedPattern);
    catch (Exception error)
        return ToolExecution("glob", "Error: invalid pattern: " ~
            error.msg, true);

    string[] matches;
    // Walk the whole tree and match each relative path (forward slashes)
    // against the compiled glob, which correctly handles `**` recursion.
    try
    {
        foreach (entry; dirEntries(workspace, SpanMode.depth))
        {
            string relative = entry.name;
            if (relative.length >= workspace.length &&
                relative[0 .. workspace.length] == workspace)
                relative = relative[workspace.length .. $];
            while (relative.length > 0 && (relative[0] == '\\' ||
                relative[0] == '/'))
                relative = relative[1 .. $];
            const rel = relative.replace("\\", "/");
            if (rel.length == 0) continue;
            if (matchFirst(rel, re).empty) continue;
            matches ~= entry.name;
            if (matches.length >= 500) break;
        }
    }
    catch (Exception) {}
    matches.sort();
    if (matches.length == 0)
        return ToolExecution("glob", "No matches for: " ~ pattern, false);
    auto builder = appender!string();
    foreach (match; matches)
        builder.put(match ~ "\n");
    return ToolExecution("glob", truncateOutput(builder.data), false);
}

private ToolExecution runGrep(string args, string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string pattern;
    string include;
    if (value.type == JSONType.object)
    {
        if (auto field = "pattern" in value.object)
            if (field.type == JSONType.string)
                pattern = field.str;
        if (auto field = "include" in value.object)
            if (field.type == JSONType.string)
                include = field.str;
    }
    if (pattern.length == 0)
        return ToolExecution("grep",
            "Error: grep requires a `pattern` argument.", true);

    Regex!(char) re;
    try re = regex(pattern);
    catch (Exception error)
        return ToolExecution("grep", "Error: invalid pattern: " ~ error.msg,
            true);

    string[] hits;
    foreach (entry; dirEntries(workspace, SpanMode.breadth))
    {
        if (!entry.isFile) continue;
        if (include.length > 0 &&
            !endsWith(entry.name, include))
            continue;
        try
        {
            const text = readText(entry.name);
            if (!matchFirst(text, re).empty)
                hits ~= entry.name;
        }
        catch (Exception) {}
        if (hits.length >= 200) break;
    }
    hits.sort();
    if (hits.length == 0)
        return ToolExecution("grep", "No matches for: " ~ pattern, false);
    auto builder = appender!string();
    foreach (hit; hits)
        builder.put(hit ~ "\n");
    return ToolExecution("grep", truncateOutput(builder.data), false);
}

private bool endsWith(string value, string suffix)
{
    return value.length >= suffix.length &&
        value[$ - suffix.length .. $] == suffix;
}

/// Execute a single tool call against the workspace directory. The result is
/// a plain-text string ready to be fed back to the model as a `tool` message.
public ToolExecution executeTool(const OpenCodeToolCall call,
    string workspace)
{
    switch (call.name)
    {
        case "bash":
            return runBash(call.arguments, workspace);
        case "read":
            return runRead(call.arguments, workspace);
        case "write":
            return runWrite(call.arguments, workspace);
        case "glob":
            return runGlob(call.arguments, workspace);
        case "grep":
            return runGrep(call.arguments, workspace);
        default:
            return ToolExecution(call.name,
                "Error: unknown tool '" ~ call.name ~ "'.", true);
    }
}
