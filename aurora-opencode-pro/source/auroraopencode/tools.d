module auroraopencode.tools;

import auroraopencode.core : OpenCodeToolCall, OpenCodeToolDef;
import std.file : dirEntries, exists, isFile, isDir, SpanMode, read, readText,
    write, mkdirRecurse, remove, rmdirRecurse, tempDir, getSize,
    timeLastModified;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildNormalizedPath, buildPath, expandTilde,
    isAbsolute;
import std.process : Pid, waitTimeout, kill, wait, spawnProcess, Config;
import std.regex : Regex, matchFirst, regex;
import std.stdio : File, stdin;
import std.string : indexOf, replace, strip;
import std.utf : toUTF8;
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
/// the plain directory-introspection operations with short natural-English
/// words (`where`, `list`, `info`) so conversations stay easy to read. The
/// schema only advertises the natural words; the legacy abbreviations
/// (pwd/ls/dir/stat) are still accepted by the dispatcher as a safety net so
/// calls never fail, but they are deliberately not taught to the model.
private OpenCodeToolDef dshellToolDefinition()
{
    return OpenCodeToolDef(
        "dshell",
        "A tiny shell implemented natively in this application (no external " ~
        "shell). Use short natural words: `where` prints the workspace path, " ~
        "`list` shows a directory with types and sizes, and `info` shows " ~
        "file/directory metadata. Prefer this over the bash/cmd/powershell " ~
        "tool for these operations.",
        `{"type":"object","properties":{"command":{"type":"string","enum":["where","list","info"],"description":"The operation: where (workspace path), list (directory listing), info (file metadata)"},"path":{"type":"string","description":"Optional path (relative to the workspace or absolute); defaults to the workspace"}},"required":["command"]}`
    );
}

/// The D-native `remove` tool definition, shared by both tool sets. Deletion
/// is a first-class native operation so the model never has to spawn
/// cmd.exe/powershell.exe (and get shell quoting wrong) just to delete a file.
private OpenCodeToolDef removeToolDefinition()
{
    return OpenCodeToolDef(
        "remove",
        "Delete a file or directory in the workspace. Directories are removed " ~
        "recursively. Use this instead of a shell command (del, rm, " ~
        "Remove-Item).",
        `{"type":"object","properties":{"path":{"type":"string","description":"Path to the file or directory, relative to the workspace or absolute"}},"required":["path"]}`
    );
}

/// The D-native `edit` tool definition, shared by both tool sets. It performs
/// an exact string replacement in a file (mirroring the opencode Edit tool), so
/// the model can make surgical changes without rewriting the whole file. The
/// result carries a unified diff that the UI renders as `+N -M` plus an
/// expandable, line-numbered diff.
private OpenCodeToolDef editToolDefinition()
{
    return OpenCodeToolDef(
        "edit",
        "Replace an exact string in a file. `oldString` must match the file " ~
        "contents exactly (including indentation) and be unique unless " ~
        "`replaceAll` is true. Prefer this over `write` for small, surgical " ~
        "changes; use `write` for new files or full rewrites.",
        `{"type":"object","properties":{"filePath":{"type":"string","description":"Path to the file, relative to the workspace or absolute"},"oldString":{"type":"string","description":"The exact text to replace"},"newString":{"type":"string","description":"The replacement text (use an empty string to delete)"},"replaceAll":{"type":"boolean","description":"Replace every occurrence instead of requiring a unique match"}},"required":["filePath","oldString","newString"]}`
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
        removeToolDefinition(),
        editToolDefinition(),
        OpenCodeToolDef(
            "read",
            "Read a text file from the workspace, one line per line, prefixed " ~
            "with its 1-indexed line number. Use `offset`/`limit` to page " ~
            "through large files.",
            `{"type":"object","properties":{"filePath":{"type":"string","description":"Path to the file, relative to the workspace or absolute"},"offset":{"type":"integer","description":"1-indexed line to start from (default 1)"},"limit":{"type":"integer","description":"Maximum number of lines to return (default: all, up to the output cap)"}},"required":["filePath"]}`
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
            "Returns matching lines as `path:line: text` (first 200 matches).",
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
        removeToolDefinition(),
        editToolDefinition(),
        OpenCodeToolDef(
            "read",
            "Read a text file from the workspace, one line per line, prefixed " ~
            "with its 1-indexed line number. Use `offset`/`limit` to page " ~
            "through large files.",
            `{"type":"object","properties":{"filePath":{"type":"string","description":"Path to the file, relative to the workspace or absolute"},"offset":{"type":"integer","description":"1-indexed line to start from (default 1)"},"limit":{"type":"integer","description":"Maximum number of lines to return (default: all, up to the output cap)"}},"required":["filePath"]}`
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
            "Returns matching lines as `path:line: text` (first 200 matches).",
            `{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression to search for"},"include":{"type":"string","description":"Optional file extension filter, e.g. *.d"}},"required":["pattern"]}`
        ),
    ];
}

/// Full system prompt mirroring the original opencode app. The original sends
/// the model its identity, a tone/style contract, an environment block
/// (working directory, git-repo status, platform, date), and a tool-usage
/// policy. That is why its first answer feels deliberate: the model knows it
/// is a coding agent inside a repo and gathers context (git, reads) instead of
/// improvising. We reproduce that structure for the same reason.
public string buildSystemPrompt(bool nativeOnly, string workspace,
    string platformName)
{
    import std.datetime : Clock;
    import std.file : exists;
    import std.path : buildPath;
    import std.conv : to;

    const today = Clock.currTime.toLocalTime.toISOExtString();
    const isGitRepo = exists(buildPath(workspace, ".git"));

    auto builder = appender!string();
    builder.put("You are Aurora OpenCode, an interactive desktop assistant " ~
        "that helps users with software engineering and file tasks. Use the " ~
        "instructions below and the tools available to you to assist the user.\n");

    builder.put("\n# Environment\n");
    builder.put("<env>\n");
    builder.put("  Working directory: " ~ workspace ~ "\n");
    builder.put("  Is directory a git repo: " ~
        (isGitRepo ? "yes" : "no") ~ "\n");
    builder.put("  Platform: " ~ platformName ~ "\n");
    builder.put("  Today's date: " ~ today ~ "\n");
    builder.put("</env>\n");

    builder.put("\n# Tone and style\n");
    builder.put("Be concise, direct, and to the point. When you run a " ~
        "non-trivial tool call, explain what it does and why you are running " ~
        "it. Your output is displayed in a chat UI and rendered with " ~
        "GitHub-flavored Markdown. Minimize output tokens while maintaining " ~
        "helpfulness, quality, and accuracy; only address the specific query " ~
        "at hand. Do not add unnecessary preamble or postamble. Only use " ~
        "emojis if the user explicitly requests them.\n");

    builder.put("\n# Tool usage policy\n");
    if (nativeOnly)
    {
        builder.put("You have access to tools implemented natively in this " ~
            "application; there is no shell and no bash/cmd/powershell. Use " ~
            "`dshell` with these natural words only: `where` for the " ~
            "workspace path, `list` to show a directory, `info` for file " ~
            "metadata. Use `glob` to list files by pattern, `read` to read " ~
            "them, `write` to create them, `remove` to delete files or " ~
            "directories, `grep` to search contents, and " ~
            "`run` to execute a program with an explicit argument list. " ~
            "Never use shell command words such as pwd, ls, dir, or stat; " ~
            "always prefer these tools over trying to reconstruct shell " ~
            "commands.\n");
    }
    else
    {
        builder.put("For file and content operations prefer the dedicated " ~
            "native tools: `dshell` with these natural words only (`where` " ~
            "for the workspace path, `list` to show a directory, `info` for " ~
            "file metadata), `glob` to list files by pattern, `read` to read " ~
            "them, `write` to create them, `remove` to delete files or " ~
            "directories, and `grep` to search contents. " ~
            "Never use shell command words such as pwd, ls, dir, or stat for " ~
            "these operations. Use the `bash` tool only for running build " ~
            "commands, git, package managers, or other executables that the " ~
            "native tools cannot perform.\n");
    }
    builder.put("When you need information about the workspace, prefer `dshell " ~
        "where` / `dshell list` over shell commands. Before beginning work, " ~
        "think about what the task is and what the files are supposed to do " ~
        "based on the filenames and directory structure.\n");

    builder.put("\n# Tools\n");
    builder.put("Call a tool by name with a JSON object of arguments. Pass " ~
        "workspace-relative (or absolute) paths and never guess file " ~
        "contents; read a file before you change it.\n");
    builder.put("- `read` {\"filePath\":\"src/main.d\"} — print a text file with " ~
        "1-indexed line numbers so you can inspect it; pass \"offset\" and " ~
        "\"limit\" to page through a large file.\n");
    builder.put("- `write` {\"filePath\":\"notes.txt\",\"content\":\"...\"} — " ~
        "create or fully overwrite a file (parent directories are made for " ~
        "you).\n");
    builder.put("- `edit` {\"filePath\":\"src/main.d\",\"oldString\":\"...\"," ~
        "\"newString\":\"...\"} — exact, surgical replacement. `oldString` must " ~
        "match the file text exactly (indentation included) and be unique; add " ~
        "\"replaceAll\":true to change every occurrence, or \"newString\":\"\" " ~
        "to delete. Prefer `edit` over `write` for small changes; the result " ~
        "shows a unified +adds/-dels diff.\n");
    builder.put("- `glob` {\"pattern\":\"src/**/*.d\"} — list files and " ~
        "directories matching a glob pattern.\n");
    builder.put("- `grep` {\"pattern\":\"class\\s+Widget\",\"include\":\"*.d\"} " ~
        "— regular-expression search of file contents; returns matching " ~
        "lines as path:line: text.\n");
    builder.put("- `remove` {\"path\":\"build\"} — delete a file or directory " ~
        "tree.\n");
    builder.put("- `dshell` {\"command\":\"list\",\"path\":\"src\"} — the native " ~
        "natural-word shell: `where` (workspace path), `list` (directory " ~
        "listing), `info` (file metadata).\n");
    if (nativeOnly)
        builder.put("- `run` {\"program\":\"dmd\",\"args\":[\"-run\"," ~
            "\"app.d\"],\"workdir\":\".\"} — run an executable directly with an " ~
            "argument list; no shell, no quoting or redirection.\n");
    else
        builder.put("- `bash` {\"command\":\"dub build\",\"workdir\":\".\"} — " ~
            "run a shell command. Use only for builds, git, package managers, " ~
            "or executables the native tools cannot handle.\n");
    builder.put("Workflow: gather context with `read`/`glob`/`grep`, make the " ~
        "smallest change with `edit` (or `write` for new files or full " ~
        "rewrites), verify with `run`/`bash`, then briefly summarise what " ~
        "changed.\n");

    builder.put("\n# Concise responses\n");
    builder.put("Keep answers short unless the user asks for detail. Answer " ~
        "directly, avoid introductions and conclusions, and do not repeat " ~
        "what the user already knows.\n");

    return builder.data;
}

/// Backwards-compatible alias for tests and callers that only need the tool
/// steering portion.
public string toolSteeringPrompt(bool nativeOnly)
{
    return buildSystemPrompt(nativeOnly, ".", "auto");
}

public struct ToolExecution
{
    string name;
    string output;
    bool failed;
    // Diff metadata for file-mutating tools (edit/write/remove). The UI renders
    // `additions`/`deletions` as the green/red `+N -M` counters and `diff` as
    // the expandable line-numbered diff body. Empty/zero for other tools.
    int additions;
    int deletions;
    string diff;
}

/// A line-based diff between two file bodies. `unified` uses the standard
/// `@@ -old,+new @@` hunk format with up to `diffContext` unchanged lines of
/// surrounding context, so the UI can render line numbers and green/red rows.
public struct TextDiff
{
    string unified;
    int additions;
    int deletions;
}

/// Unified-diff context lines around each changed run (like `git diff -U3`).
private enum int diffContext = 3;
/// Guards against quadratic LCS on pathological inputs: when the changed
/// middle is larger than this many lines on either side we fall back to a
/// whole-block replace (all removals, then all additions).
private enum int diffLcsLimit = 1600;
/// Hard cap on emitted diff lines so a giant rewrite can never blow up the
/// message column; the remainder is summarised with a trailing marker.
private enum int diffMaxLines = 1200;

/// Split a file body into lines, dropping a single trailing empty line so a
/// final newline does not show up as a spurious unchanged line.
private string[] diffLines(string text)
{
    import std.string : splitLines;
    if (text.length == 0) return null;
    auto lines = splitLines(text);
    if (lines.length > 0 && lines[$ - 1].length == 0)
        lines = lines[0 .. $ - 1];
    return lines;
}

/// Compute a unified diff between `oldText` and `newText`. A null/empty
/// `oldText` means a newly created file (every line an addition); an empty
/// `newText` means deletion (every line a removal).
public TextDiff computeTextDiff(string oldText, string newText)
{
    import std.algorithm : max;

    auto before = diffLines(oldText);
    auto after = diffLines(newText);

    // Tagged edit script: ' ' unchanged, '-' removed, '+' added.
    string[] ops;
    ops.reserve(before.length + after.length);

    size_t prefix;
    while (prefix < before.length && prefix < after.length &&
        before[prefix] == after[prefix])
        ++prefix;
    size_t suffix;
    while (suffix < before.length - prefix && suffix < after.length - prefix &&
        before[$ - 1 - suffix] == after[$ - 1 - suffix])
        ++suffix;

    TextDiff result;
    if (prefix > 0)
    {
        foreach (line; before[0 .. prefix]) ops ~= " " ~ line;
    }

    auto midBefore = before[prefix .. $ - suffix];
    auto midAfter = after[prefix .. $ - suffix];

    void emitFallback()
    {
        foreach (line; midBefore) ops ~= "-" ~ line;
        foreach (line; midAfter) ops ~= "+" ~ line;
    }

    if (midBefore.length == 0)
    {
        foreach (line; midAfter) ops ~= "+" ~ line;
    }
    else if (midAfter.length == 0)
    {
        foreach (line; midBefore) ops ~= "-" ~ line;
    }
    else if (cast(long) midBefore.length * midAfter.length > cast(long) diffLcsLimit * diffLcsLimit)
    {
        emitFallback();
    }
    else
    {
        // Classic LCS table + backtrack.
        const n = midBefore.length;
        const m = midAfter.length;
        auto table = new int[(n + 1) * (m + 1)];
        foreach (i; 0 .. n)
            foreach (j; 0 .. m)
            {
                if (midBefore[i] == midAfter[j])
                    table[(i + 1) * (m + 1) + j + 1] = table[i * (m + 1) + j] + 1;
                else
                    table[(i + 1) * (m + 1) + j + 1] =
                        max(table[i * (m + 1) + j + 1], table[(i + 1) * (m + 1) + j]);
            }
        string[] reversed;
        size_t i = n, j = m;
        while (i > 0 || j > 0)
        {
            if (i > 0 && j > 0 && midBefore[i - 1] == midAfter[j - 1])
            {
                reversed ~= " " ~ midBefore[i - 1];
                --i; --j;
            }
            else if (j > 0 && (i == 0 || table[(i) * (m + 1) + j - 1] >= table[(i - 1) * (m + 1) + j]))
            {
                reversed ~= "+" ~ midAfter[j - 1];
                --j;
            }
            else
            {
                reversed ~= "-" ~ midBefore[i - 1];
                --i;
            }
        }
        for (size_t k = reversed.length; k > 0; --k)
            ops ~= reversed[k - 1];
    }

    if (suffix > 0)
        foreach (line; before[$ - suffix .. $]) ops ~= " " ~ line;

    foreach (op; ops)
    {
        if (op.length == 0) continue;
        if (op[0] == '+') ++result.additions;
        else if (op[0] == '-') ++result.deletions;
    }

    // Group changed runs into hunks with up to `diffContext` context lines,
    // merging runs that are close together so context is never duplicated.
    size_t[] changeIdx;
    foreach (idx, op; ops)
        if (op.length > 0 && (op[0] == '+' || op[0] == '-'))
            changeIdx ~= idx;

    auto builder = appender!string();
    size_t emitted;
    if (changeIdx.length > 0)
    {
        size_t cursor;           // next op index to consider
        size_t oldNo = 1, newNo = 1; // line numbers at `cursor`
        // Precompute old/new line number before each op index.
        auto oldAt = new size_t[ops.length + 1];
        auto newAt = new size_t[ops.length + 1];
        size_t o = 1, nw = 1;
        foreach (idx, op; ops)
        {
            oldAt[idx] = o;
            newAt[idx] = nw;
            if (op.length == 0) continue;
            if (op[0] != '+') ++o;
            if (op[0] != '-') ++nw;
        }
        oldAt[ops.length] = o;
        newAt[ops.length] = nw;

        size_t ci;
        while (ci < changeIdx.length)
        {
            // Extend the hunk to include this change and any following change
            // within 2*context lines.
            size_t last = changeIdx[ci];
            size_t next = ci + 1;
            while (next < changeIdx.length &&
                changeIdx[next] - last <= cast(size_t) (2 * diffContext + 1))
            {
                last = changeIdx[next];
                ++next;
            }
            size_t start = changeIdx[ci] >= cast(size_t) diffContext
                ? changeIdx[ci] - diffContext : 0;
            size_t end = last + diffContext + 1;
            if (end > ops.length) end = ops.length;

            size_t oldCount, newCount;
            foreach (idx; start .. end)
            {
                if (ops[idx].length == 0) continue;
                if (ops[idx][0] != '+') ++oldCount;
                if (ops[idx][0] != '-') ++newCount;
            }
            if (emitted >= diffMaxLines)
            {
                builder.put("... (diff truncated)\n");
                break;
            }
            builder.put("@@ -" ~ to!string(oldAt[start]) ~ "," ~
                to!string(oldCount) ~ " +" ~ to!string(newAt[start]) ~ "," ~
                to!string(newCount) ~ " @@\n");
            foreach (idx; start .. end)
            {
                if (emitted >= diffMaxLines)
                    break;
                builder.put(ops[idx] ~ "\n");
                ++emitted;
            }
            ci = next;
        }
    }
    result.unified = builder.data;
    return result;
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

/// Decode raw bytes as UTF-8 when they are valid UTF-8, otherwise map each
/// byte to its own code point and UTF-8 encode it. Console tools on Windows
/// may emit the OEM codepage (invalid UTF-8) while modern tools emit UTF-8;
/// this keeps both readable and always returns valid UTF-8, so the text is
/// safe to persist into a JSON session file.
private string decodeBytesLenient(const(ubyte)[] bytes)
{
    if (bytes.length == 0) return "";
    try
    {
        import std.utf : validate;
        validate(cast(string) bytes);
        return cast(string) bytes.dup;
    }
    catch (Exception) {}
    auto chars = new dchar[](bytes.length);
    foreach (index; 0 .. bytes.length)
        chars[index] = cast(dchar) bytes[index];
    return toUTF8(chars);
}

/// Length of the longest prefix of `bytes` that does not end in the middle of
/// a UTF-8 sequence, so a byte-capped read/truncation never splits a multi-byte
/// character (which would yield invalid UTF-8). Returns 0 for empty input.
private size_t utf8SafeCut(const(ubyte)[] bytes)
{
    size_t index = bytes.length;
    while (index > 0 && (bytes[index - 1] & 0xC0) == 0x80)
        --index;
    if (index == 0) return 0;
    const lead = bytes[index - 1];
    const size_t need = lead < 0x80 ? 1
        : (lead & 0xE0) == 0xC0 ? 2
        : (lead & 0xF0) == 0xE0 ? 3
        : (lead & 0xF8) == 0xF0 ? 4
        : 1;
    if (index - 1 + need <= bytes.length) return bytes.length;
    return index - 1;
}

private string truncateOutput(string text)
{
    if (text.length <= maxOutputBytes) return text;
    const safe = utf8SafeCut(cast(const(ubyte)[]) text[0 .. maxOutputBytes]);
    return text[0 .. safe] ~ "\n…(output truncated)";
}

/// Read at most `cap` bytes from a file and decode them leniently. Avoids
/// materialising an arbitrarily large file just to show its first screenful.
private string readFileCapped(string path, size_t cap)
{
    auto file = File(path, "rb");
    scope (exit) collectException(file.close());
    auto buffer = new ubyte[cap];
    size_t total;
    while (total < buffer.length)
    {
        const got = file.rawRead(buffer[total .. $]).length;
        if (got == 0) break;
        total += got;
    }
    return decodeBytesLenient(buffer[0 .. total]);
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
        Config.suppressConsole, workdir);
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
            // Decode the captured bytes leniently: prefer valid UTF-8 (modern
            // console tools, git with a UTF-8 locale) and fall back to a
            // per-byte mapping for legacy OEM-codepage output. Either way the
            // result is valid UTF-8 and safe to persist into JSON sessions.
            output = decodeBytesLenient(cast(const(ubyte)[]) read(outPath));
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

/// A window of lines read from a file, for the `read` tool's paging.
private struct LineWindow
{
    string[] lines;    // decoded lines, terminators stripped, line numbers implicit
    size_t firstLine;  // 1-indexed number of lines[0]
    size_t lastLine;   // 1-indexed number of the last emitted line (0 if none)
    size_t totalLines; // total lines in the file (all scanned even when paging)
    bool hasMore;      // stopped at `limit`/byte cap before the end of the file
}

/// Longest line body the `read` tool returns before truncating that line.
private enum size_t maxLineChars = 2000;

/// Stream a file line-by-line and return at most `limit` lines starting at
/// 1-indexed `offset`, capped at `maxBytes` of line content. Lines are read
/// through `File.byLine`, so a huge file is never materialised in memory.
/// `totalLines` still reports the real line count because scanning continues
/// past `offset` to the end of file.
private LineWindow readLineWindow(string path, size_t offset, size_t limit,
    size_t maxBytes)
{
    LineWindow window;
    window.firstLine = offset;
    auto file = File(path, "r");
    scope (exit) collectException(file.close());
    size_t lineNo;
    size_t bytes;
    foreach (rawLine; file.byLine())
    {
        ++lineNo;
        window.totalLines = lineNo;
        if (lineNo < offset) continue;
        // `byLine` already strips the terminator; decode leniently so a
        // non-UTF-8 file still yields valid UTF-8 line text.
        string line = decodeBytesLenient(cast(const(ubyte)[]) rawLine);
        if (line.length > maxLineChars)
            line = line[0 .. utf8SafeCut(
                cast(const(ubyte)[]) line[0 .. maxLineChars])] ~
                " …(line truncated)";
        // Count the rendered `N: ` prefix too, so the byte budget tracks the
        // real output size for line-number-heavy reads.
        const prefix = to!string(lineNo).length + 2;
        if (bytes + prefix + line.length + 1 > maxBytes)
        {
            window.hasMore = true;
            break;
        }
        window.lines ~= line;
        bytes += prefix + line.length + 1;
        if (limit > 0 && window.lines.length >= limit)
        {
            window.hasMore = true;
            break;
        }
    }
    if (window.lines.length > 0)
        window.lastLine = window.firstLine + window.lines.length - 1;
    return window;
}

private ToolExecution runRead(string args, string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string filePath;
    size_t offset = 1;
    size_t limit;
    if (value.type == JSONType.object)
    {
        if (auto field = "filePath" in value.object)
            if (field.type == JSONType.string)
                filePath = field.str;
        if (auto field = "offset" in value.object)
            if (field.type == JSONType.integer && field.integer > 0)
                offset = cast(size_t) field.integer;
        if (auto field = "limit" in value.object)
            if (field.type == JSONType.integer && field.integer > 0)
                limit = cast(size_t) field.integer;
    }
    if (filePath.length == 0)
        return ToolExecution("read",
            "Error: read requires a `filePath` argument.", true);
    const path = resolveToolPath(filePath, workspace);
    if (!exists(path) || !isFile(path))
        return ToolExecution("read", "Error: file not found: " ~ path, true);

    // Numbered line window (line numbers give the model stable edit anchors).
    // Leave headroom under the byte cap for the `N: ` prefixes and the footer.
    LineWindow window;
    try window = readLineWindow(path, offset, limit,
        maxOutputBytes > 8192 ? maxOutputBytes - 8192 : maxOutputBytes);
    catch (Exception)
    {
        // Not readable as text (e.g. non-UTF-8 bytes): fall back to a bounded
        // raw read rather than failing outright.
        string text;
        try text = readFileCapped(path, maxOutputBytes + 4);
        catch (Exception error)
            return ToolExecution("read", "Error: could not read file: " ~
                error.msg, true);
        return ToolExecution("read", truncateOutput(text), false);
    }
    if (window.lines.length == 0)
    {
        if (offset > 1)
            return ToolExecution("read", "Error: offset " ~ to!string(offset) ~
                " is out of range (file has " ~
                to!string(window.totalLines) ~ " lines).", true);
        return ToolExecution("read", "", false);
    }
    auto builder = appender!string();
    foreach (i, line; window.lines)
        builder.put(to!string(window.firstLine + i) ~ ": " ~ line ~ "\n");
    builder.put("\n(Showing lines " ~ to!string(window.firstLine) ~ "-" ~
        to!string(window.lastLine) ~
        (window.hasMore
            ? ". Use offset=" ~ to!string(window.lastLine + 1) ~ " to continue.)"
            : ". End of file.)") ~ "\n");
    return ToolExecution("read", truncateOutput(builder.data), false);
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
    string previous;
    const existed = exists(path) && isFile(path);
    if (existed)
    {
        try previous = readText(path);
        catch (Exception) previous = "";
    }
    try
    {
        write(path, content);
    }
    catch (Exception error)
        return ToolExecution("write", "Error: could not write file: " ~
            error.msg, true);
    auto diff = computeTextDiff(existed ? previous : "", content);
    ToolExecution result;
    result.name = "write";
    result.output = (existed ? "Updated " : "Wrote ") ~ path ~ " (" ~
        to!string(content.length) ~ " chars, +" ~ to!string(diff.additions) ~
        " -" ~ to!string(diff.deletions) ~ ").";
    result.additions = diff.additions;
    result.deletions = diff.deletions;
    result.diff = diff.unified;
    return result;
}

/// Fuzzy fallback for `edit`: candidate substrings of `content` that match
/// `find` after ignoring each line's leading/trailing whitespace, so an edit
/// still lands when the model's anchor differs only by indentation or trailing
/// spaces. The returned strings are the exact text in `content`, so the caller
/// replaces them verbatim; the block is rejoined with the newline `content`
/// actually uses so the substring is really present.
private string[] lineTrimmedEditMatches(string content, string find)
{
    import std.string : splitLines;

    string[] matches;
    auto contentLines = splitLines(content);
    auto findLines = splitLines(find);
    if (findLines.length > 0 && findLines[$ - 1].length == 0)
        findLines = findLines[0 .. $ - 1];
    if (findLines.length == 0 || contentLines.length < findLines.length)
        return matches;
    const newline = indexOf(content, "\r\n") >= 0 ? "\r\n" : "\n";
    foreach (i; 0 .. contentLines.length - findLines.length + 1)
    {
        bool matched = true;
        foreach (j; 0 .. findLines.length)
        {
            if (strip(contentLines[i + j]) != strip(findLines[j]))
            {
                matched = false;
                break;
            }
        }
        if (matched)
        {
            auto builder = appender!string();
            foreach (k; i .. i + findLines.length)
            {
                if (k > i) builder.put(newline);
                builder.put(contentLines[k]);
            }
            matches ~= builder.data;
        }
    }
    return matches;
}

/// The D-native `edit` tool: replace an exact `oldString` with `newString` in a
/// file, then report a unified diff. Fails when the anchor is missing or (by
/// default) ambiguous, so edits never silently change the wrong place.
private ToolExecution runEdit(string args, string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string filePath;
    string oldString;
    string newString;
    bool hasNewString;
    bool replaceAll;
    if (value.type == JSONType.object)
    {
        if (auto field = "filePath" in value.object)
            if (field.type == JSONType.string)
                filePath = field.str;
        if (auto field = "oldString" in value.object)
            if (field.type == JSONType.string)
                oldString = field.str;
        if (auto field = "newString" in value.object)
            if (field.type == JSONType.string)
            {
                newString = field.str;
                hasNewString = true;
            }
        if (auto field = "replaceAll" in value.object)
            if (field.type == JSONType.true_)
                replaceAll = true;
    }
    if (filePath.length == 0 || oldString.length == 0 || !hasNewString)
        return ToolExecution("edit",
            "Error: edit requires `filePath`, `oldString` and `newString`.",
            true);
    if (oldString == newString)
        return ToolExecution("edit",
            "Error: `oldString` and `newString` are identical; nothing to " ~
            "change.", true);
    const path = resolveToolPath(filePath, workspace);
    if (!exists(path) || !isFile(path))
        return ToolExecution("edit", "Error: file not found: " ~ path, true);
    string previous;
    try previous = readText(path);
    catch (Exception error)
        return ToolExecution("edit", "Error: could not read file: " ~
            error.msg, true);

    // Count occurrences of the anchor.
    size_t occurrences;
    size_t searchFrom;
    while (true)
    {
        const at = previous.indexOf(oldString, searchFrom);
        if (at < 0) break;
        ++occurrences;
        searchFrom = at + oldString.length;
    }
    if (occurrences > 1 && !replaceAll)
        return ToolExecution("edit", "Error: `oldString` appears " ~
            to!string(occurrences) ~ " times in " ~ path ~
            "; add more context to make it unique or set replaceAll=true.",
            true);

    string updated;
    bool fuzzyUsed;
    if (occurrences == 0)
    {
        // Exact anchor missing: accept a whitespace/indentation-tolerant match
        // (still required to be unique unless replaceAll), so a valid edit is
        // not rejected just because the quoted block drifted slightly.
        string[] candidates;
        foreach (candidate; lineTrimmedEditMatches(previous, oldString))
        {
            if (previous.indexOf(candidate) < 0) continue;
            bool duplicate;
            foreach (seen; candidates)
                if (seen == candidate)
                {
                    duplicate = true;
                    break;
                }
            if (!duplicate) candidates ~= candidate;
        }
        size_t matchesInFile;
        foreach (candidate; candidates)
        {
            size_t from;
            while (true)
            {
                const at = previous.indexOf(candidate, from);
                if (at < 0) break;
                ++matchesInFile;
                from = at + candidate.length;
            }
        }
        if (matchesInFile == 0)
            return ToolExecution("edit",
                "Error: `oldString` was not found in " ~ path ~ ". Check the " ~
                "exact text (including indentation) or read the file again.",
                true);
        if (matchesInFile > 1 && !replaceAll)
            return ToolExecution("edit", "Error: `oldString` appears " ~
                to!string(matchesInFile) ~ " times in " ~ path ~
                "; add more context to make it unique or set replaceAll=true.",
                true);
        fuzzyUsed = true;
        if (replaceAll)
        {
            updated = previous;
            foreach (candidate; candidates)
                updated = updated.replace(candidate, newString);
        }
        else
        {
            const at = previous.indexOf(candidates[0]);
            updated = previous[0 .. at] ~ newString ~
                previous[at + candidates[0].length .. $];
        }
    }
    else if (replaceAll)
        updated = previous.replace(oldString, newString);
    else
    {
        const at = previous.indexOf(oldString);
        updated = previous[0 .. at] ~ newString ~ previous[at + oldString.length .. $];
    }

    try write(path, updated);
    catch (Exception error)
        return ToolExecution("edit", "Error: could not write file: " ~
            error.msg, true);

    auto diff = computeTextDiff(previous, updated);
    ToolExecution result;
    result.name = "edit";
    result.output = "Edited " ~ path ~
        (fuzzyUsed ? " (whitespace-tolerant match)" : "") ~ " (" ~
        (fuzzyUsed ? "1" : to!string(replaceAll ? occurrences : 1)) ~
        (replaceAll && !fuzzyUsed && occurrences > 1
            ? " replacements" : " replacement") ~
        ", +" ~ to!string(diff.additions) ~ " -" ~ to!string(diff.deletions) ~
        ").";
    result.additions = diff.additions;
    result.deletions = diff.deletions;
    result.diff = diff.unified;
    return result;
}

/// The D-native `remove` tool: deletes a file, or a directory tree. Accepts
/// `path` (or `filePath`, since models often reuse the read/write key).
private ToolExecution runRemove(string args, string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string pathArg;
    if (value.type == JSONType.object)
    {
        if (auto field = "path" in value.object)
            if (field.type == JSONType.string)
                pathArg = field.str;
        if (pathArg.length == 0)
            if (auto field = "filePath" in value.object)
                if (field.type == JSONType.string)
                    pathArg = field.str;
    }
    if (pathArg.length == 0)
        return ToolExecution("remove",
            "Error: remove requires a `path` argument.", true);
    const path = resolveToolPath(pathArg, workspace);
    if (!exists(path))
        return ToolExecution("remove", "Error: not found: " ~ path, true);
    try
    {
        if (isDir(path))
        {
            rmdirRecurse(path);
            return ToolExecution("remove",
                "Removed directory " ~ path, false);
        }
        if (isFile(path))
        {
            string previous;
            try previous = readText(path);
            catch (Exception) previous = "";
            auto diff = computeTextDiff(previous, "");
            remove(path);
            ToolExecution result;
            result.name = "remove";
            result.output = "Removed file " ~ path ~ " (+0 -" ~
                to!string(diff.deletions) ~ ").";
            result.deletions = diff.deletions;
            result.diff = diff.unified;
            return result;
        }
        return ToolExecution("remove",
            "Error: not a file or directory: " ~ path, true);
    }
    catch (Exception error)
        return ToolExecution("remove", "Error: could not remove: " ~
            error.msg, true);
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

    // Return matching lines (`path:line: text`) rather than just file paths, so
    // the model does not have to re-read every hit to see the surrounding code.
    // Files are streamed line-by-line, so a huge file never has to be loaded
    // whole just to find the first match. A match that spans multiple lines is
    // not reported (grep is line-based, matching ripgrep's default behaviour).
    enum size_t maxHits = 200;
    enum size_t maxLineChars = 300;
    string[] hits;
    bool capped;
    outer: foreach (entry; dirEntries(workspace, SpanMode.breadth))
    {
        if (!entry.isFile) continue;
        if (include.length > 0 &&
            !fileMatchesInclude(baseName(entry.name), include))
            continue;
        File file;
        try file = File(entry.name, "r");
        catch (Exception) continue;
        scope (exit) collectException(file.close());
        size_t lineNo;
        try
        {
            foreach (line; file.byLine())
            {
                ++lineNo;
                if (matchFirst(line, re).empty) continue;
                string display =
                    decodeBytesLenient(cast(const(ubyte)[]) line);
                if (display.length > maxLineChars)
                    display = display[0 .. utf8SafeCut(
                        cast(const(ubyte)[]) display[0 .. maxLineChars])] ~ "…";
                hits ~= entry.name ~ ":" ~ to!string(lineNo) ~ ": " ~ display;
                if (hits.length >= maxHits)
                {
                    capped = true;
                    break outer;
                }
            }
        }
        catch (Exception) {}
    }
    if (hits.length == 0)
        return ToolExecution("grep", "No matches for: " ~ pattern, false);
    auto builder = appender!string();
    foreach (hit; hits)
        builder.put(hit ~ "\n");
    if (capped)
        builder.put("(Results capped at " ~ to!string(maxHits) ~
            " matches — narrow the pattern or include filter.)\n");
    return ToolExecution("grep", truncateOutput(builder.data), false);
}

private bool endsWith(string value, string suffix)
{
    return value.length >= suffix.length &&
        value[$ - suffix.length .. $] == suffix;
}

/// True when a file name satisfies the grep `include` filter. The filter is
/// documented as a glob (e.g. `*.d`), but a bare extension or suffix (`d`,
/// `.d`, `main.d`) is also accepted as a convenience. Matching against the
/// name (not the full path) means `*.d` works regardless of directory depth;
/// the previous suffix test only matched a literal `*.d` never found in a name.
private bool fileMatchesInclude(string fileName, string include)
{
    if (include.length == 0) return true;
    try
    {
        if (!matchFirst(fileName, globToRegex(include)).empty) return true;
    }
    catch (Exception) {}
    return endsWith(fileName, include);
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
        case "edit":
            return runEdit(call.arguments, workspace);
        case "remove":
            return runRemove(call.arguments, workspace);
        case "glob":
            return runGlob(call.arguments, workspace);
        case "grep":
            return runGrep(call.arguments, workspace);
        default:
            return ToolExecution(call.name,
                "Error: unknown tool '" ~ call.name ~ "'.", true);
    }
}

/// Count the lines in a file body without allocating a line array. A single
/// trailing newline does not start a new line, matching `diffLines`.
private int countBodyLines(string text)
{
    if (text.length == 0) return 0;
    int lines = 1;
    foreach (ch; text)
        if (ch == '\n') ++lines;
    if (text[$ - 1] == '\n') --lines;
    return lines;
}

/// Extract a JSON string value for `key` from a possibly-truncated object
/// body. Unlike `parseJSON` this tolerates a value whose closing quote has not
/// streamed yet, so the UI can show a live `+N -M` while a file body is still
/// arriving. Escapes (`\n`, `\t`, `\"`, `\\`, `\/`, `\uXXXX`) are decoded;
/// an incomplete `\u` escape is dropped.
private string extractPartialJsonString(string body, string key)
{
    import std.string : indexOf;
    const needle = "\"" ~ key ~ "\"";
    auto at = body.indexOf(needle);
    if (at < 0) return "";
    size_t cursor = cast(size_t) at + needle.length;

    bool skipSpace()
    {
        while (cursor < body.length &&
            (body[cursor] == ' ' || body[cursor] == '\t' ||
             body[cursor] == '\n' || body[cursor] == '\r'))
            ++cursor;
        return cursor < body.length;
    }

    if (!skipSpace() || body[cursor] != ':') return "";
    ++cursor;
    if (!skipSpace() || body[cursor] != '"') return "";
    ++cursor;

    auto builder = appender!string();
    while (cursor < body.length)
    {
        const ch = body[cursor];
        if (ch == '"') break;
        if (ch != '\\')
        {
            builder.put(ch);
            ++cursor;
            continue;
        }
        if (cursor + 1 >= body.length) break;
        const esc = body[cursor + 1];
        switch (esc)
        {
            case 'n': builder.put('\n'); break;
            case 't': builder.put('\t'); break;
            case 'r': builder.put('\r'); break;
            case 'b': builder.put('\b'); break;
            case 'f': builder.put('\f'); break;
            case '"': builder.put('"'); break;
            case '\\': builder.put('\\'); break;
            case '/': builder.put('/'); break;
            case 'u':
                if (cursor + 5 >= body.length)
                {
                    cursor = body.length;
                    continue;
                }
                uint code;
                bool valid = true;
                foreach (k; 0 .. 4)
                {
                    const h = body[cursor + 2 + k];
                    uint digit;
                    if (h >= '0' && h <= '9') digit = h - '0';
                    else if (h >= 'a' && h <= 'f') digit = h - 'a' + 10;
                    else if (h >= 'A' && h <= 'F') digit = h - 'A' + 10;
                    else { valid = false; break; }
                    code = code * 16 + digit;
                }
                if (!valid)
                {
                    cursor = body.length;
                    continue;
                }
                builder.put(cast(dchar) code);
                cursor += 6;
                continue;
            default: builder.put(esc); break;
        }
        cursor += 2;
    }
    return builder.data;
}

/// The value of a string argument, preferring an exact `parseJSON` (the whole
/// tool call has arrived) and falling back to the tolerant partial extractor
/// (still streaming).
public string partialStringArg(string argsJson, string key)
{
    JSONValue value;
    try value = parseJSON(argsJson);
    catch (Exception) value = JSONValue.init;
    if (value.type == JSONType.object)
        if (auto field = key in value.object)
            if (field.type == JSONType.string)
                return field.str;
    return extractPartialJsonString(argsJson, key);
}

/// Best-effort additions/deletions for a file-mutating tool whose arguments
/// are still streaming (or have just arrived). `write` reports the line count
/// of the partial `content` as additions; `edit` diffs the partial
/// `oldString`/`newString`. Returns false when there is nothing meaningful to
/// show yet, or for tools that do not produce a diff. The exact diff replaces
/// this preview once the tool executes.
public bool previewToolDiff(string toolName, string argsJson,
    out int additions, out int deletions)
{
    additions = 0;
    deletions = 0;
    if (toolName == "write")
    {
        const content = partialStringArg(argsJson, "content");
        if (content.length == 0) return false;
        additions = countBodyLines(content);
        return additions > 0;
    }
    if (toolName == "edit")
    {
        const oldText = partialStringArg(argsJson, "oldString");
        const newText = partialStringArg(argsJson, "newString");
        if (oldText.length == 0 && newText.length == 0) return false;
        auto diff = computeTextDiff(oldText, newText);
        additions = diff.additions;
        deletions = diff.deletions;
        return additions > 0 || deletions > 0;
    }
    return false;
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
            "Error: dshell requires a `command` (where, list, or info).",
            true);

    const resolved = path.length > 0
        ? resolveToolPath(path, workspace) : workspace;

    switch (command)
    {
        case "where":
        case "pwd":
            return ToolExecution("dshell",
                "<path>" ~ workspace ~ "</path>", false);
        case "list":
        case "ls":
        case "dir":
            return dshellList(resolved, workspace);
        case "info":
        case "stat":
            return dshellStat(resolved, workspace);
        default:
            return ToolExecution("dshell",
                "Error: unknown dshell command '" ~ command ~
                "' (expected where, list, or info).", true);
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
