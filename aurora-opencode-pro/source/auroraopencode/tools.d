module auroraopencode.tools;

import auroraopencode.core : OpenCodeToolCall, OpenCodeToolDef;
import std.file : dirEntries, exists, isFile, isDir, SpanMode, read, readText,
    write, mkdirRecurse, remove, tempDir, getSize, timeLastModified;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildNormalizedPath, buildPath, expandTilde, isAbsolute;
import std.process : Pid, waitTimeout, kill, wait, spawnProcess, Config;
import std.regex : Regex, matchFirst, regex;
import std.stdio : File, stdin;
import std.string : replace, strip;
import std.conv : to;
import std.exception : collectException;
import core.time : seconds, Duration, MonoTime, msecs;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.algorithm : sort, map, filter;
import std.array : appender, array;
import std.range : take;
import std.typecons : Tuple;

// ---------------------------------------------------------------------------
// Built-in tool definitions advertised to the model. The parameter schemas
// mirror the opencode app's tool registry so models behave the same here.
//
// Cross-platform strategy (mirrors the original opencode app): file and
// content tools (read/write/glob/grep) are implemented natively in D, so they
// never touch a shell and behave identically everywhere. The single shell tool
// ("bash") is shell-aware per platform: on Windows it runs through cmd.exe or
// PowerShell and its description tells the model which shell syntax to use; on
// Unix it runs through /bin/bash. The model can pick a shell explicitly.
// ---------------------------------------------------------------------------

/// The shell the bash tool uses by default on this platform. On Windows we
/// pick cmd.exe (always present); PowerShell is available on demand via the
/// `shell` parameter.
private string defaultShellName()
{
    version (Windows)
        return "cmd";
    else
        return "bash";
}

/// Per-platform usage guidance embedded in the bash tool description so the
/// model writes valid commands for the shell that will actually run them.
private string shellUsageNotes(string shell)
{
    version (Windows)
    {
        if (shell == "powershell" || shell == "pwsh")
            return "Shell: PowerShell (" ~ (shell == "pwsh" ? "7+" : "5.1") ~
                "). Use Get-ChildItem / Get-Content / Set-Content / " ~
                "Test-Path / Remove-Item and $env: variables. Prefer the " ~
                "read/write/glob/grep tools for file access.";
        return "Shell: cmd.exe. Use dir / type / echo / %VAR% and `if exist` " ~
            "checks. Prefer the read/write/glob/grep tools for file access.";
    }
    else
        return "Shell: bash. Use ls / cat / echo / $VAR. Prefer the " ~
            "read/write/glob/grep tools for file access.";
}

/// The D-native `dshell` tool definition, shared by both tool sets: it covers
/// the plain directory-introspection commands (pwd/ls/dir/stat) natively so
/// the model never needs a shell for them.
private OpenCodeToolDef dshellToolDefinition()
{
    return OpenCodeToolDef(
        "dshell",
        "A tiny shell implemented natively in this application (no external " ~
        "shell). Use it for plain directory introspection: `pwd` prints the " ~
        "workspace path, `ls`/`dir` lists a directory with types and sizes, " ~
        "and `stat` shows file/directory metadata. Prefer this over the " ~
        "bash/cmd/powershell tool for these commands.",
        `{"type":"object","properties":{"command":{"type":"string","enum":["pwd","ls","dir","stat"],"description":"The command to run"},"path":{"type":"string","description":"Optional path (relative to the workspace or absolute); defaults to the workspace"}},"required":["command"]}`
    );
}

/// Advertised tool definitions. Built as a function (not an immutable global)
/// so the bash tool's description reflects the platform shell.
public OpenCodeToolDef[] builtinToolDefinitions()
{
    const shell = defaultShellName();
    return [
        OpenCodeToolDef(
            "bash",
            "Execute shell commands in the workspace. Use this to run build " ~
            "commands, inspect the environment, or manipulate files when the " ~
            "dedicated tools do not fit. " ~ shellUsageNotes(shell),
            `{"type":"object","properties":{"command":{"type":"string","description":"The command to execute"},"shell":{"type":"string","enum":["auto","bash","cmd","powershell","pwsh"],"description":"The shell to run the command in. Defaults to the platform shell."},"workdir":{"type":"string","description":"Working directory, relative to the workspace or absolute. Use this instead of cd."},"timeout":{"type":"integer","description":"Timeout in milliseconds (default 60000)"}},"required":["command"]}`
        ),
        dshellToolDefinition(),
        OpenCodeToolDef(
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
}

/// Native-only tool definitions: the D-native `run` tool replaces the shell
/// tool, and every file operation uses a D implementation, so no shell syntax
/// is ever involved. This is the "our own tools instead of bash/cmd/powershell"
/// mode.
public OpenCodeToolDef[] nativeOnlyToolDefinitions()
{
    return [
        OpenCodeToolDef(
            "run",
            "Execute a program directly with an argument list, never through " ~
            "a shell. Use this to run build tools, compilers, git, or any " ~
            "executable. The program name is resolved against PATH; pass " ~
            "each argument separately (no shell quoting or redirection).",
            `{"type":"object","properties":{"program":{"type":"string","description":"The executable to run (e.g. dmd, git, python)"},"args":{"type":"array","items":{"type":"string"},"description":"Arguments passed verbatim to the program"},"workdir":{"type":"string","description":"Working directory, relative to the workspace or absolute"},"timeout":{"type":"integer","description":"Timeout in milliseconds (default 60000)"}},"required":["program"]}`
        ),
        dshellToolDefinition(),
        OpenCodeToolDef(
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
}

/// System-prompt steering that mirrors the original opencode app: the model is
/// told to prefer the native tools for file work and reserve the shell for
/// things the native tools cannot do. In native-only mode there is no shell at
/// all, so the model is steered exclusively to the D tools.
public string toolSteeringPrompt(bool nativeOnly)
{
    if (nativeOnly)
        return "You have access to tools implemented natively in this " ~
            "application; there is no shell and no bash/cmd/powershell. " ~
            "Use `dshell` for directory introspection (pwd, ls/dir, stat), " ~
            "`glob` to list files by pattern, `read` to read them, `write` to " ~
            "create them, `grep` to search contents, and `run` to execute a " ~
            "program with an explicit argument list. Always prefer these tools " ~
            "over trying to reconstruct shell commands.";
    return "You have access to tools. For file and content operations prefer " ~
        "the dedicated native tools: `dshell` for directory introspection " ~
        "(pwd, ls/dir, stat), `glob` to list files by pattern, `read` to read " ~
        "them, `write` to create them, and `grep` to search contents. Use the " ~
        "`bash` tool only for running build commands, git, package managers, " ~
        "or other executables that the native tools cannot perform. Avoid " ~
        "using bash for pwd, listing, or reading files.";
}

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

/// Resolve the requested shell to the argv the platform should invoke.
/// Returns the full argument list (binary + flags + command). `auto` picks
/// the platform default.
private string[] shellCommand(string shell, string command)
{
    version (Windows)
    {
        switch (shell)
        {
            case "powershell":
                return ["powershell.exe", "-NoLogo", "-NoProfile",
                    "-NonInteractive", "-Command", command];
            case "pwsh":
                return ["pwsh", "-NoLogo", "-NoProfile",
                    "-NonInteractive", "-Command", command];
            case "bash":
                return ["bash", "-lc", command];
            case "cmd":
            default:
                return ["cmd.exe", "/d", "/s", "/c", command];
        }
    }
    else
        return ["/bin/bash", "-lc", command];
}

/// Parse the shared tool arguments object. Returns false when the payload is
/// not an object.
private bool parseToolArgs(string args, ref string command,
    ref string shell, ref string workdir, ref int timeoutMs,
    ref string[] argv)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    if (value.type != JSONType.object) return false;
    if (auto field = "command" in value.object)
        if (field.type == JSONType.string)
            command = field.str;
    if (auto field = "shell" in value.object)
        if (field.type == JSONType.string)
            shell = field.str;
    if (auto field = "workdir" in value.object)
        if (field.type == JSONType.string)
            workdir = field.str;
    if (auto field = "timeout" in value.object)
        if (field.type == JSONType.integer)
            timeoutMs = cast(int) field.integer;
    if (auto field = "args" in value.object)
    {
        if (field.type == JSONType.array)
        {
            foreach (entry; field.array)
            {
                if (entry.type == JSONType.string)
                    argv ~= entry.str;
            }
        }
    }
    return true;
}

private ToolExecution runBash(string args, string workspace)
{
    string command;
    string shell = "auto";
    string workdir;
    int timeoutMs = 60_000;
    string[] argvExtra;
    if (!parseToolArgs(args, command, shell, workdir, timeoutMs, argvExtra))
        return ToolExecution("bash",
            "Error: bash requires a JSON object payload.", true);
    if (command.length == 0)
        return ToolExecution("bash",
            "Error: bash requires a non-empty `command` argument.", true);
    if (timeoutMs <= 0)
        timeoutMs = 60_000;

    if (shell == "auto")
        shell = defaultShellName();
    auto argv = shellCommand(shell, command);
    const resolvedWorkdir = workdir.length > 0
        ? resolveToolPath(workdir, workspace) : workspace;

    auto result = runProcess(argv, resolvedWorkdir, timeoutMs, "bash");
    return ToolExecution("bash", truncateOutput(result[0]), result[1]);
}

/// The D-native `run` tool: execute a program directly with an argument list,
/// never through a shell. This is the cross-platform replacement for the
/// bash/cmd/powershell tool: the model names the program and its arguments,
/// and the app spawns it directly, so no shell syntax or quoting is involved.
private ToolExecution runProgramTool(string args, string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string program;
    string workdir;
    int timeoutMs = 60_000;
    string[] argv;
    if (value.type == JSONType.object)
    {
        if (auto field = "program" in value.object)
            if (field.type == JSONType.string)
                program = field.str;
        if (auto field = "workdir" in value.object)
            if (field.type == JSONType.string)
                workdir = field.str;
        if (auto field = "timeout" in value.object)
            if (field.type == JSONType.integer)
                timeoutMs = cast(int) field.integer;
        if (auto field = "args" in value.object)
        {
            if (field.type == JSONType.array)
            {
                foreach (entry; field.array)
                {
                    if (entry.type == JSONType.string)
                        argv ~= entry.str;
                }
            }
        }
    }
    if (program.length == 0)
        return ToolExecution("run",
            "Error: run requires a non-empty `program` argument.", true);
    if (timeoutMs <= 0)
        timeoutMs = 60_000;

    // The program name is resolved against PATH by spawnProcess; an explicit
    // path may be given instead. Remaining arguments pass through verbatim.
    const resolvedWorkdir = workdir.length > 0
        ? resolveToolPath(workdir, workspace) : workspace;
    auto fullArgv = [program] ~ argv;

    auto result = runProcess(fullArgv, resolvedWorkdir, timeoutMs, "run");
    return ToolExecution("run", truncateOutput(result[0]), result[1]);
}

/// Shared process runner used by the shell tool and the native `run` tool.
/// Spawns `argv` directly (no shell), redirects stdout+stderr to a temp file,
/// waits up to `timeoutMs`, and kills on timeout. Output is decoded leniently
/// (console tools emit the OEM codepage, not UTF-8). Returns (output,
/// timedOut).
private Tuple!(string, bool) runProcess(string[] argv, string workdir,
    int timeoutMs, string toolName)
{
    import std.typecons : tuple;

    const outPath = buildNormalizedPath(buildPath(
        cast(string) tempDir(), "aurora-opencode-tool-" ~
        to!string(cast(long) MonoTime.currTime.ticks) ~ ".out"));
    File outFile;
    if (!tryOpenOutput(outPath, outFile, toolName))
        return tuple("Error: could not open output file.", true);

    Pid pid;
    try pid = spawnProcess(argv, stdin, outFile, outFile, null,
        Config.none, workdir);
    catch (Exception error)
    {
        try outFile.close();
        catch (Exception) {}
        try remove(outPath);
        catch (Exception) {}
        return tuple("Error: could not start process: " ~ error.msg, true);
    }

    const timeout = msecs(timeoutMs);
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
        try
        {
            // Read raw bytes and decode leniently: console tools emit the OEM
            // codepage, which is not valid UTF-8. Strict decoding would throw
            // and the output would be swallowed as "(no output)".
            auto raw = read(outPath);
            auto bytes = cast(ubyte[]) raw;
            auto decoded = new char[](bytes.length);
            for (size_t index; index < bytes.length; ++index)
                decoded[index] = cast(char) bytes[index];
            output = cast(string) decoded;
        }
        catch (Exception) {}
        try remove(outPath);
        catch (Exception) {}
    }
    if (timedOut)
        output = (output.length > 0 ? output ~ "\n" : "") ~
            "\n…(process timed out after " ~ to!string(timeoutMs) ~
            "ms and was killed)";
    if (output.length == 0) output = "(no output)";
    return tuple(output, timedOut);
}

private bool tryOpenOutput(string outPath, out File outFile, string toolName)
{
    try
    {
        outFile.open(outPath, "w");
        return true;
    }
    catch (Exception)
    {
        return false;
    }
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
        case "run":
            return runProgramTool(call.arguments, workspace);
        case "dshell":
            return runDshell(call.arguments, workspace);
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

/// The D-native `dshell` tool: a tiny shell implemented in D that covers the
/// commands the model most often reaches for (pwd, ls/dir, stat) so it never
/// needs to invoke bash/cmd/powershell for plain directory introspection.
private ToolExecution runDshell(string args, string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string command;
    string path;
    if (value.type == JSONType.object)
    {
        if (auto field = "command" in value.object)
            if (field.type == JSONType.string)
                command = field.str;
        if (auto field = "path" in value.object)
            if (field.type == JSONType.string)
                path = field.str;
    }
    if (command.length == 0)
        return ToolExecution("dshell",
            "Error: dshell requires a `command` (pwd, ls, dir, or stat).",
            true);

    const resolved = path.length > 0
        ? resolveToolPath(path, workspace) : workspace;

    switch (command)
    {
        case "pwd":
            return ToolExecution("dshell",
                "<path>" ~ workspace ~ "</path>", false);
        case "ls":
        case "dir":
            return dshellList(resolved, workspace);
        case "stat":
            return dshellStat(resolved, workspace);
        default:
            return ToolExecution("dshell",
                "Error: unknown dshell command '" ~ command ~
                "' (expected pwd, ls, dir, or stat).", true);
    }
}

private ToolExecution dshellList(string path, string workspace)
{
    if (!exists(path) || !isDir(path))
        return ToolExecution("dshell",
            "Error: not a directory: " ~ path, true);
    string[] names;
    string[] kinds;
    string[] sizes;
    try
    {
        foreach (entry; dirEntries(path, SpanMode.shallow))
        {
            names ~= entry.name;
            kinds ~= entry.isDir ? "dir" : "file";
            if (entry.isDir)
                sizes ~= "-";
            else
            {
                try sizes ~= to!string(entry.size);
                catch (Exception) sizes ~= "?";
            }
        }
    }
    catch (Exception error)
        return ToolExecution("dshell", "Error: could not list directory: " ~
            error.msg, true);
    names.sort();
    auto builder = appender!string();
    builder.put("<path>" ~ path ~ "</path>\n");
    builder.put("<entries>\n");
    foreach (index; 0 .. names.length)
        builder.put((kinds[index] == "dir" ? "[d] " : "[f] ") ~
            names[index] ~ "  (" ~ sizes[index] ~ " bytes)\n");
    builder.put("</entries>\n");
    return ToolExecution("dshell", truncateOutput(builder.data), false);
}

private ToolExecution dshellStat(string path, string workspace)
{
    if (!exists(path))
        return ToolExecution("dshell", "Error: not found: " ~ path, true);
    auto builder = appender!string();
    builder.put("<path>" ~ path ~ "</path>\n");
    builder.put(isDir(path) ? "<type>directory</type>\n"
        : isFile(path) ? "<type>file</type>\n" : "<type>other</type>\n");
    if (isFile(path))
    {
        try builder.put("<size>" ~ to!string(getSize(path)) ~
            " bytes</size>\n");
        catch (Exception) {}
        try builder.put("<modified>" ~ to!string(timeLastModified(path)) ~
            "</modified>\n");
        catch (Exception) {}
    }
    return ToolExecution("dshell", builder.data, false);
}
