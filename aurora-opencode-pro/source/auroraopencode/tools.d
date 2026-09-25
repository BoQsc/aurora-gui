module auroraopencode.tools;

import auroraopencode.core : ChatImageAttachment, OpenCodeToolCall,
    OpenCodeToolDef, ensureStateDirectory, opencodeStateDirectory;
import auroraopencode.attachments : attachmentImageForData,
    attachmentImageKindForBytes, attachmentImageMaxBytes;
// experimental: websearch - delete with source/auroraopencode/websearch.d
import auroraopencode.websearch : experimentalWebSearchExecute,
    experimentalWebSearchTools;
import std.file : dirEntries, exists, isFile, isDir, isSymlink, SpanMode, read,
    readText, write, mkdirRecurse, fileCopy = copy, remove, rename,
    rmdir, rmdirRecurse, tempDir, getSize,
    timeLastModified;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildNormalizedPath, buildPath, dirName, expandTilde,
    extension, isAbsolute;
import std.process : Pid, Pipe, pipe, waitTimeout, kill, wait, spawnProcess,
    Config;
version (Windows)
{
    import core.sys.windows.windows : HANDLE, DWORD, BOOL, UINT, ULONG_PTR,
        LONG, WCHAR;
    import core.sys.windows.shellapi : ShellExecuteW;
}
import std.regex : Regex, matchFirst, regex;
import std.stdio : File, stdin, stdout, stderr;
import std.string : indexOf, lastIndexOf, replace, strip, toLower;
import std.utf : toUTF8, toUTF16z, validate;
import std.conv : to;
import std.exception : collectException;
import core.time : seconds, Duration, MonoTime, msecs;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.datetime : Clock;
import std.algorithm : canFind, sort, map, filter, startsWith;
import std.array : appender, array;
import std.range : take;
import std.typecons : Tuple;
import core.sync.mutex : Mutex;
import core.thread : Thread;

// ---------------------------------------------------------------------------
// Built-in tool definitions advertised to the model. The parameter schemas
// mirror the opencode app's tool registry so models behave the same here.
//
// Cross-platform strategy (mirrors the original opencode app): file and
// content tools (read/write/copy/move/rename/create_folder/glob/grep) are
// implemented natively in D, so they
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

/// The D-native `dshell` tool definition. It exposes short natural-English
/// operations while legacy abbreviations remain accepted by the dispatcher for
/// saved conversations. `list` also supports recursive and filtered discovery,
/// making dshell the one primary model-facing workspace navigator.
private OpenCodeToolDef dshellToolDefinition()
{
    return OpenCodeToolDef(
        "dshell",
        "A tiny shell implemented natively in this application (no external " ~
        "shell). `where` prints the workspace path when specifically needed, " ~
        "`list` discovers files and " ~
        "directories (optionally recursively or by glob pattern), and `info` " ~
        "shows metadata. `list` and `info` already return their resolved path, " ~
        "so do not pair them with `where`. This is the primary tool for " ~
        "navigating a workspace.",
        `{"type":"object","properties":{"command":{"type":"string","enum":["where","list","info"],"description":"Operation: where (workspace path), list (directory discovery), or info (metadata)"},"path":{"type":"string","description":"Optional path, relative to the workspace or absolute; defaults to the workspace"},"recursive":{"type":"boolean","description":"For list: descend into subdirectories"},"pattern":{"type":"string","description":"For list: optional glob matched against paths relative to the listed directory, e.g. **/*.d"}},"required":["command"]}`
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

/// The D-native `apply_patch` tool definition, shared by both tool sets. It
/// takes a Codex-format patch (multi-file, multi-hunk) and applies the whole
/// thing in one call, so a change spanning several files costs one round
/// instead of one round per edit.
private OpenCodeToolDef applyPatchToolDefinition()
{
    return OpenCodeToolDef(
        "apply_patch",
        "Apply a patch in the Codex format to one or more files in a single " ~
        "call. The patch is wrapped in `*** Begin Patch` / `*** End Patch` " ~
        "and may contain `*** Add File:`, `*** Update File:` and `*** Delete " ~
        "File:` sections. Inside an update, unchanged context lines start " ~
        "with a space, removed lines with `-` and added lines with `+`. " ~
        "Prefer this over several `edit` calls when a change touches " ~
        "multiple files or places.",
        `{"type":"object","properties":{"patch":{"type":"string","description":"The patch text, starting with *** Begin Patch and ending with *** End Patch"}},"required":["patch"]}`
    );
}

/// The D-native `update_plan` tool definition: records the task plan so the
/// user can see the steps and their progress. At most one step may be
/// `in_progress` at a time.
private OpenCodeToolDef updatePlanToolDefinition()
{
    return OpenCodeToolDef(
        "update_plan",
        "Update the task plan with a list of steps, each carrying a status " ~
        "of `pending`, `in_progress` or `completed`. Record the plan before " ~
        "starting a multi-step task: list every step up front, mark the first " ~
        "`in_progress` and the rest `pending`. Then keep it current: call " ~
        "this again whenever a step's status changes, marking a finished step " ~
        "`completed` and the next one `in_progress`, so the checklist never " ~
        "shows finished work as pending. At most one step may be in_progress " ~
        "at a time. Each call replaces the entire checklist. Keep the " ~
        "original checklist when working through one of its steps; put " ~
        "temporary substeps in the conversation or use update_subplan when " ~
        "available. Set replace_entire_plan " ~
        "only when the user explicitly asks to discard the existing plan.",
        `{"type":"object","properties":{"explanation":{"type":"string","description":"Optional explanation for this plan update"},"replace_entire_plan":{"type":"boolean","description":"True only when the user explicitly asks to discard the existing plan and replace it"},"plan":{"type":"array","items":{"type":"object","properties":{"step":{"type":"string","description":"Task step text"},"status":{"type":"string","enum":["pending","in_progress","completed"],"description":"Step status"}},"required":["step","status"]},"description":"The full checklist, including existing steps"}},"required":["plan"]}`
    );
}

/// The D-native `move` tool, shared by both tool sets. One operation handles
/// files, directory trees and batches without transferring bytes through the
/// model or relying on shell-specific quoting.
private OpenCodeToolDef moveToolDefinition()
{
    return OpenCodeToolDef(
        "move",
        "Move files and directories into an existing destination folder " ~
        "without using a shell. Provide `source` for one item or `sources` " ~
        "for a batch. Item names stay unchanged; use `rename` when a name " ~
        "must change. Existing targets are never overwritten.",
        `{"type":"object","properties":{"source":{"type":"string","description":"One file or directory to move, relative to the workspace or absolute"},"sources":{"type":"array","items":{"type":"string"},"minItems":1,"description":"Files and/or directories to move as one batch"},"destinationFolder":{"type":"string","description":"Existing folder that will receive the items"}},"required":["destinationFolder"]}`
    );
}

/// The D-native `copy` tool mirrors move's one-or-many shape while preserving
/// every source. Directory copies recurse in-process instead of invoking a
/// platform shell or sending file contents through the model.
private OpenCodeToolDef copyToolDefinition()
{
    return OpenCodeToolDef(
        "copy",
        "Copy files and directories into an existing destination folder " ~
        "without using a shell. Provide `source` for one item or `sources` " ~
        "for a batch. Directory trees are copied recursively and item names " ~
        "stay unchanged. Existing targets are never overwritten.",
        `{"type":"object","properties":{"source":{"type":"string","description":"One file or directory to copy, relative to the workspace or absolute"},"sources":{"type":"array","items":{"type":"string"},"minItems":1,"description":"Files and/or directories to copy as one batch"},"destinationFolder":{"type":"string","description":"Existing folder that will receive the copies"}},"required":["destinationFolder"]}`
    );
}

private OpenCodeToolDef renameToolDefinition()
{
    return OpenCodeToolDef(
        "rename",
        "Rename one file or folder without moving it to another folder. " ~
        "`newName` is a name only, not a path, and the destination must not " ~
        "already exist.",
        `{"type":"object","properties":{"path":{"type":"string","description":"File or folder to rename, relative to the workspace or absolute"},"newName":{"type":"string","description":"New name in the same parent folder; must not contain path separators"}},"required":["path","newName"]}`
    );
}

private OpenCodeToolDef createFolderToolDefinition()
{
    return OpenCodeToolDef(
        "create_folder",
        "Create a new folder, including any missing parent folders. The final " ~
        "folder must not already exist. Use `write` to create files.",
        `{"type":"object","properties":{"path":{"type":"string","description":"Folder path to create, relative to the workspace or absolute"}},"required":["path"]}`
    );
}

/// Experimental: one level of optional detail under an existing plan step.
private OpenCodeToolDef updateSubplanToolDefinition()
{
    return OpenCodeToolDef(
        "update_subplan",
        "Create or update temporary substeps under one existing top-level " ~
        "plan step without replacing the main checklist. parent_step is the " ~
        "1-based number of that step. The plan array replaces only that " ~
        "step's substeps. Use this only when the user enabled experimental " ~
        "nested plans and a real step needs more detail. One level only.",
        `{"type":"object","properties":{"parent_step":{"type":"integer","minimum":1,"description":"1-based top-level step number"},"explanation":{"type":"string","description":"Optional explanation"},"plan":{"type":"array","items":{"type":"object","properties":{"step":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed"]}},"required":["step","status"]}}},"required":["parent_step","plan"]}`
    );
}

/// Open a local file/directory or web URL with the operating system's default
/// application. This avoids platform shell commands such as Windows `start`,
/// whose nested quoting is fragile when paths contain spaces.
private OpenCodeToolDef openToolDefinition()
{
    return OpenCodeToolDef(
        "open",
        "Open a local file, directory, or HTTP(S) URL with the operating " ~
        "system's default application. Local paths may be workspace-relative " ~
        "or absolute. Use this instead of shell commands such as start, " ~
        "Start-Process, open, or xdg-open.",
        `{"type":"object","properties":{"target":{"type":"string","description":"Local file/directory path or HTTP(S) URL to open"}},"required":["target"]}`
    );
}

/// Load image pixels into the model's next turn. `open` only launches the
/// user's desktop viewer; this tool is the model-visible counterpart.
private OpenCodeToolDef viewImageToolDefinition()
{
    return OpenCodeToolDef(
        "view_image",
        "Load a local PNG, JPEG, WebP, or GIF and attach its pixels to your " ~
        "next turn for visual inspection. Use this when the user asks about " ~
        "an image by path: `read` is text-only, while `open` only shows the " ~
        "image to the user. Paths may be workspace-relative or absolute.",
        `{"type":"object","properties":{"filePath":{"type":"string","description":"Image path, relative to the workspace or absolute"}},"required":["filePath"]}`
    );
}

/// Inspect and control commands launched with `background:true`.
private OpenCodeToolDef processToolDefinition()
{
    return OpenCodeToolDef(
        "process",
        "Manage background processes started by `run` or `bash`. List them, " ~
        "inspect status, read accumulated output, write or close stdin, " ~
        "request termination, or remove a completed process record. Reuse " ~
        "the returned processId; " ~
        "do not relaunch a command merely because it is still running.",
        `{"type":"object","properties":{"action":{"type":"string","enum":["list","status","output","write","kill","remove"],"description":"Operation to perform"},"processId":{"type":"string","description":"Stable id returned by a background run/bash call; required except for list"},"input":{"type":"string","description":"Text to write for the write action"},"closeStdin":{"type":"boolean","description":"Close stdin after writing, or close it without input"}},"required":["action"]}`
    );
}

/// The D-native `webfetch` tool: fetch an HTTP(S) URL and return the response
/// body as text. Requests run through the system `curl` (present on Windows
/// 10+ and virtually every Unix) via the shared process runner, so no shell is
/// involved and URLs never need quoting. HTML pages are reduced to readable
/// text unless `raw` is set; bodies are truncated like other tool output.
private OpenCodeToolDef webFetchToolDefinition()
{
    return OpenCodeToolDef(
        "webfetch",
        "Fetch an HTTP(S) URL and return the response body as text. Use this " ~
        "to read a web page, API endpoint, or JSON document that is not in the " ~
        "workspace. Redirects are followed. HTML is converted to readable " ~
        "text unless `raw` is true, with script, style and SVG bodies " ~
        "dropped; large bodies are truncated.",
        `{"type":"object","properties":{"url":{"type":"string","description":"Absolute http(s) URL to fetch"},"timeout":{"type":"integer","description":"Timeout in milliseconds (default 30000)"},"raw":{"type":"boolean","description":"Return the response body untouched instead of converting HTML to text"}},"required":["url"]}`
    );
}

/// Agent-facing rebuild tool. It does no building itself: the executable is
/// locked while the app runs, so the work is delegated to the host application
/// through `rebuildRequestHandler` (see `runRebuildTool`).
private OpenCodeToolDef rebuildToolDefinition()
{
    return OpenCodeToolDef(
        "rebuild",
        "Rebuild the Aurora OpenCode application itself and relaunch it. Only " ~
        "useful when you are working on Aurora's own source. It persists the " ~
        "conversation, hands the build to a detached helper that waits for " ~
        "this process to exit, runs `dub build`, and relaunches the app, which " ~
        "then continues this conversation. The running executable is never " ~
        "overwritten in place, so this is the only safe way to apply source " ~
        "changes to the app. It needs no user approval or confirmation; use it " ~
        "whenever the app's own source is ready to build.",
        `{"type":"object","properties":{"reason":{"type":"string","description":"Short note on why a rebuild is needed; recorded in the conversation."}},"required":[]}`
    );
}

/// Keep the grep contract identical in shell-enabled and native-only modes.
private OpenCodeToolDef grepToolDefinition()
{
    return OpenCodeToolDef(
        "grep",
        "Search file contents under a directory. Uses regular expressions by " ~
        "default, or exact text when `literal` is true. Defaults to the " ~
        "workspace; set `path` for another directory or a specific file. " ~
        "`mode` selects matching lines, matching files, or per-file counts.",
        `{"type":"object","properties":{"pattern":{"type":"string","description":"Text or regular expression to search for"},"literal":{"type":"boolean","description":"Treat pattern as exact text instead of a regular expression (default false)"},"caseSensitive":{"type":"boolean","description":"Match letter case (default true)"},"context":{"type":"integer","minimum":0,"maximum":20,"description":"Context lines before and after each content match (default 0)"},"mode":{"type":"string","enum":["content","files","count"],"description":"Return matching lines, matching file paths, or per-file matching-line counts (default content)"},"limit":{"type":"integer","minimum":1,"maximum":1000,"description":"Maximum matching lines in content mode or matching files in files/count mode (default 200)"},"include":{"type":"string","description":"Optional file-name glob or suffix, e.g. *.d"},"path":{"type":"string","description":"Directory or file to search, relative to the workspace or absolute; defaults to the workspace"},"timeout":{"type":"integer","minimum":1,"maximum":600000,"description":"Soft deadline in milliseconds (default 10000). If progress justifies waiting, rerun with a longer value."}},"required":["pattern"]}`
    );
}

/// Advertised tool definitions. Built as a function (not an immutable global)
/// so the bash tool's description reflects the platform shell.
public OpenCodeToolDef[] builtinToolDefinitions()
{
    const shell = defaultShellName();
    OpenCodeToolDef[] defs = [
        OpenCodeToolDef(
            "bash",
            "Execute shell commands in the workspace. Use this to run build " ~
            "commands, inspect the environment, or manipulate files when the " ~
            "dedicated tools do not fit. Set background=true for work that may " ~
            "run long, then inspect it with the process tool. " ~
            shellUsageNotes(shell),
            `{"type":"object","properties":{"command":{"type":"string","description":"The command to execute"},"shell":{"type":"string","enum":["auto","bash","cmd","powershell","pwsh"],"description":"The shell to run the command in. Defaults to the platform shell."},"workdir":{"type":"string","description":"Working directory, relative to the workspace or absolute. Use this instead of cd."},"timeout":{"type":"integer","description":"Timeout in milliseconds (default 3600000)"},"background":{"type":"boolean","description":"Return immediately with a processId and supervise the command in the background"}},"required":["command"]}`
        ),
        processToolDefinition(),
        webFetchToolDefinition(),
        dshellToolDefinition(),
        openToolDefinition(),
        viewImageToolDefinition(),
        copyToolDefinition(),
        moveToolDefinition(),
        renameToolDefinition(),
        createFolderToolDefinition(),
        removeToolDefinition(),
        editToolDefinition(),
        applyPatchToolDefinition(),
        updatePlanToolDefinition(),
        updateSubplanToolDefinition(),
        rebuildToolDefinition(),
        OpenCodeToolDef(
            "read",
            "Read a text file from the workspace, one line per line, prefixed " ~
            "with its 1-indexed line number. Use `offset`/`limit` to page " ~
            "through large files. To inspect image pixels, use `view_image`.",
            `{"type":"object","properties":{"filePath":{"type":"string","description":"Path to the file, relative to the workspace or absolute"},"offset":{"type":"integer","description":"1-indexed line to start from (default 1)"},"limit":{"type":"integer","description":"Maximum number of lines to return (default: all, up to the output cap)"}},"required":["filePath"]}`
        ),
        OpenCodeToolDef(
            "write",
            "Create or overwrite a text file in the workspace. Creates parent " ~
            "directories as needed.",
            `{"type":"object","properties":{"filePath":{"type":"string","description":"Path to the file, relative to the workspace or absolute"},"content":{"type":"string","description":"The full text to write"}},"required":["filePath","content"]}`
        ),
        grepToolDefinition(),
    ];
    defs ~= experimentalWebSearchTools(); // experimental: websearch
    return defs;
}

/// Native-only tool definitions: the D-native `run` tool replaces the shell
/// tool, and every file operation uses a D implementation, so no shell syntax
/// is ever involved. This is the "our own tools instead of bash/cmd/powershell"
/// mode.
public OpenCodeToolDef[] nativeOnlyToolDefinitions()
{
    OpenCodeToolDef[] defs = [
        OpenCodeToolDef(
            "run",
            "Execute a program directly with an argument list, never through " ~
            "a shell. Use this to run build tools, compilers, git, or any " ~
            "executable. Program names are resolved against PATH; existing " ~
            "relative executable paths are resolved from workdir, including " ~
            "local .exe names on Windows. Pass each argument separately (no " ~
            "shell quoting or redirection). For DMD verification, prefer " ~
            "`-run` to compile and execute in one call; compiler options " ~
            "precede `-run` (example: `-Isource -i -run source/app.d`). " ~
            "Set background=true for work that may run long, " ~
            "then inspect status and output with the process tool.",
            `{"type":"object","properties":{"program":{"type":"string","description":"The executable to run (e.g. dmd, git, python)"},"args":{"type":"array","items":{"type":"string"},"description":"Arguments passed verbatim to the program"},"workdir":{"type":"string","description":"Working directory, relative to the workspace or absolute"},"timeout":{"type":"integer","description":"Timeout in milliseconds (default 3600000)"},"background":{"type":"boolean","description":"Return immediately with a processId and supervise the program in the background"}},"required":["program"]}`
        ),
        processToolDefinition(),
        webFetchToolDefinition(),
        dshellToolDefinition(),
        openToolDefinition(),
        viewImageToolDefinition(),
        copyToolDefinition(),
        moveToolDefinition(),
        renameToolDefinition(),
        createFolderToolDefinition(),
        removeToolDefinition(),
        editToolDefinition(),
        applyPatchToolDefinition(),
        updatePlanToolDefinition(),
        updateSubplanToolDefinition(),
        rebuildToolDefinition(),
        OpenCodeToolDef(
            "read",
            "Read a text file from the workspace, one line per line, prefixed " ~
            "with its 1-indexed line number. Use `offset`/`limit` to page " ~
            "through large files. To inspect image pixels, use `view_image`.",
            `{"type":"object","properties":{"filePath":{"type":"string","description":"Path to the file, relative to the workspace or absolute"},"offset":{"type":"integer","description":"1-indexed line to start from (default 1)"},"limit":{"type":"integer","description":"Maximum number of lines to return (default: all, up to the output cap)"}},"required":["filePath"]}`
        ),
        OpenCodeToolDef(
            "write",
            "Create or overwrite a text file in the workspace. Creates parent " ~
            "directories as needed.",
            `{"type":"object","properties":{"filePath":{"type":"string","description":"Path to the file, relative to the workspace or absolute"},"content":{"type":"string","description":"The full text to write"}},"required":["filePath","content"]}`
        ),
        grepToolDefinition(),
    ];
    defs ~= experimentalWebSearchTools(); // experimental: websearch
    return defs;
}

/// Stable, outcome-first instructions for the coding agent. Tool-specific
/// syntax lives in each tool definition; keeping it out of this prompt avoids
/// duplicate instructions and leaves the stable prefix eligible for caching.
public string buildSystemPrompt(bool nativeOnly, string workspace,
    string platformName, string verbosity = "default")
{
    import std.datetime : Clock;
    import std.file : exists;
    import std.path : buildPath;

    import auroraopencode.systemprompt : SystemPromptContext, renderSystemPrompt;

    const today = Clock.currTime.toLocalTime.toISOExtString();
    const isGitRepo = exists(buildPath(workspace, ".git"));

    // The prompt is assembled from modules (see auroraopencode.systemprompt).
    // The built-in modules reproduce the previous single-function text exactly,
    // so the rendered prompt is unchanged. New awareness (rebuilds, self-hosting,
    // ...) is added by registering an extra module rather than by editing this
    // function, which keeps the core text and the stable cached prefix untouched.
    // `verbosity` stays optional: "default" (the default) renders no style
    // section, so every existing caller keeps the byte-identical stock prompt.
    SystemPromptContext ctx;
    ctx.nativeOnly = nativeOnly;
    ctx.workspace = workspace;
    ctx.platformName = platformName;
    ctx.today = today;
    ctx.isGitRepo = isGitRepo;
    ctx.verbosity = verbosity;
    return renderSystemPrompt(ctx);
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
    // Change metadata for file-mutating tools. The UI renders
    // `additions`/`deletions` as the green/red `+N -M` counters and `diff` as
    // the expandable line-numbered diff body. Empty/zero for other tools.
    int additions;
    int deletions;
    string diff;
    // Wall-clock duration of the call, measured by `executeTool`. The UI shows
    // it on the tool row (and aggregated on the action-group header) the same
    // way the file-mutating tools show their `+N -M` counters.
    long elapsedMs;
    // Image payloads are staged by the UI until every result in the current
    // tool batch has been appended, then sent in a model-visible user message.
    // Keeping them off the `tool` message preserves strict tool-call ordering.
    ChatImageAttachment[] images;
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

private ulong stablePathHash(string value)
{
    ulong hash = 1469598103934665603UL;
    foreach (ubyte b; cast(const(ubyte)[]) value)
    {
        hash ^= b;
        hash *= 1099511628211UL;
    }
    return hash;
}

private string snapshotHash(bool existsValue, bool directory,
    const(ubyte)[] bytes)
{
    if (!existsValue) return "missing";
    if (directory) return "directory";
    return to!string(stablePathHash(cast(string) bytes)) ~ ":" ~
        to!string(bytes.length);
}

private bool snapshotIsText(const(ubyte)[] bytes)
{
    try
    {
        validate(cast(string) bytes);
        return true;
    }
    catch (Exception) return false;
}

private string changeWorkspaceDirectory(string workspace)
{
    ensureStateDirectory();
    const root = buildPath(opencodeStateDirectory(), "changes",
        to!string(stablePathHash(buildNormalizedPath(workspace).toLower())));
    if (!exists(root)) mkdirRecurse(root);
    const blobs = buildPath(root, "blobs");
    if (!exists(blobs)) mkdirRecurse(blobs);
    return root;
}

private FileSnapshot snapshotFile(string path)
{
    FileSnapshot result;
    result.path = buildNormalizedPath(path);
    result.exists = exists(result.path);
    result.directory = result.exists && isDir(result.path);
    if (result.exists && !result.directory && isFile(result.path))
        result.bytes = cast(ubyte[]) read(result.path);
    return result;
}

private FileSnapshot[] snapshotTargets(const string[] targets)
{
    FileSnapshot[] result;
    bool seen(string path)
    {
        foreach (item; result)
            if (item.path == path) return true;
        return false;
    }
    foreach (candidate; targets)
    {
        const path = buildNormalizedPath(candidate);
        if (exists(path) && isDir(path))
        {
            if (!seen(path)) result ~= snapshotFile(path);
            foreach (entry; dirEntries(path, SpanMode.depth))
                if ((entry.isFile || entry.isDir) &&
                    !seen(buildNormalizedPath(entry.name)))
                    result ~= snapshotFile(entry.name);
        }
        else if (!seen(path))
            result ~= snapshotFile(path);
    }
    return result;
}

private struct TransferPaths
{
    string[] sources;
    string[] targets;
    string error;
}

private string comparablePath(string path)
{
    auto result = buildNormalizedPath(path).replace("\\", "/");
    version (Windows) result = result.toLower();
    return result;
}

private bool pathIsInside(string child, string parent)
{
    const childKey = comparablePath(child);
    const parentKey = comparablePath(parent);
    return childKey.length > parentKey.length &&
        childKey.startsWith(parentKey) && childKey[parentKey.length] == '/';
}

/// Parse and fully resolve a copy/move request. Keeping target calculation in one
/// place makes execution and the before/after safety journal agree exactly.
private TransferPaths resolveTransferPaths(string args, string workspace,
    string operation)
{
    TransferPaths result;
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception)
    {
        result.error = operation ~ " requires a JSON object.";
        return result;
    }
    if (value.type != JSONType.object)
    {
        result.error = operation ~ " requires a JSON object.";
        return result;
    }

    void addSource(string raw)
    {
        const path = resolveToolPath(raw, workspace);
        if (path.length == 0) return;
        const key = comparablePath(path);
        foreach (existing; result.sources)
            if (comparablePath(existing) == key)
            {
                result.error = "the same source was provided more than once: " ~
                    path;
                return;
            }
        result.sources ~= path;
    }

    if (auto field = "source" in value.object)
        if (field.type == JSONType.string) addSource(field.str);
    if (auto field = "sources" in value.object)
    {
        if (field.type != JSONType.array)
            result.error = "`sources` must be an array of paths.";
        else foreach (entry; field.array)
        {
            if (entry.type != JSONType.string)
            {
                result.error = "every `sources` entry must be a path string.";
                break;
            }
            addSource(entry.str);
            if (result.error.length > 0) break;
        }
    }
    if (result.error.length > 0) return result;
    if (result.sources.length == 0)
    {
        result.error = operation ~
            " requires `source` or a non-empty `sources` array.";
        return result;
    }

    string destinationArg;
    if (auto field = "destinationFolder" in value.object)
        if (field.type == JSONType.string) destinationArg = field.str;
    if (destinationArg.strip().length == 0)
    {
        result.error = operation ~ " requires a `destinationFolder` path.";
        return result;
    }
    const destination = resolveToolPath(destinationArg, workspace);
    if (!exists(destination) || !isDir(destination))
    {
        result.error = "destination folder does not exist: " ~ destination;
        return result;
    }

    foreach (source; result.sources)
    {
        if (!exists(source))
        {
            result.error = "source not found: " ~ source;
            return result;
        }
        if (!isFile(source) && !isDir(source))
        {
            result.error = "source is not a file or directory: " ~ source;
            return result;
        }
        const target = buildNormalizedPath(buildPath(destination,
            baseName(source)));
        if (comparablePath(source) == comparablePath(target))
        {
            result.error = "source and destination are the same path: " ~ source;
            return result;
        }
        if (isDir(source) && pathIsInside(target, source))
        {
            result.error = "cannot " ~ operation ~
                " a directory inside itself: " ~ source ~
                " -> " ~ target;
            return result;
        }
        if (exists(target))
        {
            result.error = "destination already exists; nothing was " ~
                "overwritten: " ~ target;
            return result;
        }
        foreach (otherTarget; result.targets)
            if (comparablePath(otherTarget) == comparablePath(target))
            {
                result.error = "multiple sources resolve to the same " ~
                    "destination: " ~ target;
                return result;
            }
        result.targets ~= target;
    }

    foreach (index, source; result.sources)
        foreach (otherIndex, other; result.sources)
            if (index != otherIndex && pathIsInside(source, other))
            {
                result.error = "a " ~ operation ~
                    " batch cannot contain both a directory " ~
                    "and an item inside it: " ~ other ~ " and " ~ source;
                return result;
            }
    return result;
}

private struct RenamePaths
{
    string source;
    string target;
    string error;
}

private RenamePaths resolveRenamePaths(string args, string workspace)
{
    RenamePaths result;
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception)
    {
        result.error = "rename requires a JSON object.";
        return result;
    }
    if (value.type != JSONType.object)
    {
        result.error = "rename requires a JSON object.";
        return result;
    }
    string pathArg;
    string newName;
    if (auto field = "path" in value.object)
        if (field.type == JSONType.string) pathArg = field.str;
    if (auto field = "newName" in value.object)
        if (field.type == JSONType.string) newName = field.str.strip();
    if (pathArg.strip().length == 0 || newName.length == 0)
    {
        result.error = "rename requires `path` and `newName`.";
        return result;
    }
    if (newName == "." || newName == ".." || newName.indexOf('/') >= 0 ||
        newName.indexOf('\\') >= 0)
    {
        result.error = "`newName` must be a name only, without path separators.";
        return result;
    }
    result.source = resolveToolPath(pathArg, workspace);
    if (!exists(result.source) || (!isFile(result.source) && !isDir(result.source)))
    {
        result.error = "source not found: " ~ result.source;
        return result;
    }
    result.target = buildNormalizedPath(buildPath(dirName(result.source),
        newName));
    if (comparablePath(result.source) == comparablePath(result.target))
    {
        result.error = "the new name is unchanged: " ~ newName;
        return result;
    }
    if (exists(result.target))
    {
        result.error = "destination already exists; nothing was overwritten: " ~
            result.target;
        return result;
    }
    return result;
}

private string[] resolveCreateFolderPaths(string args, string workspace,
    out string error)
{
    string[] result;
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception)
    {
        error = "create_folder requires a JSON object.";
        return result;
    }
    string pathArg;
    if (value.type == JSONType.object)
        if (auto field = "path" in value.object)
            if (field.type == JSONType.string) pathArg = field.str;
    if (pathArg.strip().length == 0)
    {
        error = "create_folder requires a `path`.";
        return result;
    }
    auto cursor = resolveToolPath(pathArg, workspace);
    if (exists(cursor))
    {
        error = "folder already exists: " ~ cursor;
        return result;
    }
    while (!exists(cursor))
    {
        result ~= cursor;
        const parent = dirName(cursor);
        if (parent.length == 0 || comparablePath(parent) == comparablePath(cursor))
        {
            error = "could not find an existing parent folder for: " ~ cursor;
            return null;
        }
        cursor = parent;
    }
    if (!isDir(cursor))
    {
        error = "a parent path is not a folder: " ~ cursor;
        return null;
    }
    for (size_t left = 0, right = result.length; left < right / 2; ++left)
    {
        const other = result.length - 1 - left;
        auto swap = result[left];
        result[left] = result[other];
        result[other] = swap;
    }
    return result;
}

private string[] mutationTargetPaths(const OpenCodeToolCall call,
    string workspace)
{
    import std.string : splitLines;
    string[] result;
    void add(string value)
    {
        if (value.length == 0) return;
        const path = resolveToolPath(value, workspace);
        if (!result.canFind(path)) result ~= path;
    }
    JSONValue value;
    try value = parseJSON(call.arguments);
    catch (Exception) value = JSONValue.init;
    if (value.type != JSONType.object) return result;
    if (call.name == "write" || call.name == "edit")
    {
        if (auto field = "filePath" in value.object)
            if (field.type == JSONType.string) add(field.str);
    }
    else if (call.name == "move" || call.name == "copy")
    {
        const transfer = resolveTransferPaths(call.arguments, workspace,
            call.name);
        if (transfer.error.length == 0)
        {
            if (call.name == "move")
                foreach (path; transfer.sources) add(path);
            foreach (path; transfer.targets) add(path);
        }
    }
    else if (call.name == "rename")
    {
        const paths = resolveRenamePaths(call.arguments, workspace);
        if (paths.error.length == 0)
        {
            add(paths.source);
            add(paths.target);
        }
    }
    else if (call.name == "create_folder")
    {
        string error;
        foreach (path; resolveCreateFolderPaths(call.arguments, workspace,
            error)) add(path);
    }
    else if (call.name == "remove")
    {
        foreach (key; ["path", "filePath"])
            if (auto field = key in value.object)
                if (field.type == JSONType.string && field.str.length > 0)
                {
                    add(field.str);
                    break;
                }
    }
    else if (call.name == "apply_patch")
    {
        string patch;
        foreach (key; ["patch", "input", "text"])
            if (auto field = key in value.object)
                if (field.type == JSONType.string && field.str.length > 0)
                {
                    patch = field.str;
                    break;
                }
        foreach (line; patch.splitLines())
        {
            const text = line.strip();
            foreach (prefix; ["*** Add File:", "*** Update File:",
                "*** Delete File:"])
                if (text.length >= prefix.length &&
                    text[0 .. prefix.length] == prefix)
                    add(text[prefix.length .. $].strip());
        }
    }
    return result;
}

private JSONValue changeRecordToJson(const ref ChangeRecord record)
{
    JSONValue root;
    root["id"] = record.id;
    root["transactionId"] = record.transactionId;
    root["conversationId"] = record.conversationId;
    root["turnId"] = record.turnId;
    root["toolCallId"] = record.toolCallId;
    root["toolName"] = record.toolName;
    root["workspace"] = record.workspace;
    root["path"] = record.path;
    root["changeKind"] = record.changeKind;
    root["timestamp"] = record.timestamp;
    root["beforeExists"] = record.beforeExists;
    root["afterExists"] = record.afterExists;
    root["beforeDirectory"] = record.beforeDirectory;
    root["afterDirectory"] = record.afterDirectory;
    root["beforeHash"] = record.beforeHash;
    root["afterHash"] = record.afterHash;
    root["beforeBlob"] = record.beforeBlob;
    root["afterBlob"] = record.afterBlob;
    root["additions"] = record.additions;
    root["deletions"] = record.deletions;
    if (record.revertOf.length > 0) root["revertOf"] = record.revertOf;
    return root;
}

private string jsonString(ref const JSONValue root, string key)
{
    if (root.type == JSONType.object)
        if (auto field = key in root.object)
            if (field.type == JSONType.string) return field.str;
    return "";
}

private bool jsonBool(ref const JSONValue root, string key)
{
    if (root.type == JSONType.object)
        if (auto field = key in root.object)
            return field.type == JSONType.true_;
    return false;
}

private int jsonInt(ref const JSONValue root, string key)
{
    if (root.type == JSONType.object)
        if (auto field = key in root.object)
            if (field.type == JSONType.integer) return cast(int) field.integer;
    return 0;
}

private ChangeRecord changeRecordFromJson(ref const JSONValue root)
{
    ChangeRecord record;
    record.id = jsonString(root, "id");
    record.transactionId = jsonString(root, "transactionId");
    record.conversationId = jsonString(root, "conversationId");
    record.turnId = jsonString(root, "turnId");
    record.toolCallId = jsonString(root, "toolCallId");
    record.toolName = jsonString(root, "toolName");
    record.workspace = jsonString(root, "workspace");
    record.path = jsonString(root, "path");
    record.changeKind = jsonString(root, "changeKind");
    record.timestamp = jsonString(root, "timestamp");
    record.beforeExists = jsonBool(root, "beforeExists");
    record.afterExists = jsonBool(root, "afterExists");
    record.beforeDirectory = jsonBool(root, "beforeDirectory");
    record.afterDirectory = jsonBool(root, "afterDirectory");
    record.beforeHash = jsonString(root, "beforeHash");
    record.afterHash = jsonString(root, "afterHash");
    record.beforeBlob = jsonString(root, "beforeBlob");
    record.afterBlob = jsonString(root, "afterBlob");
    record.additions = jsonInt(root, "additions");
    record.deletions = jsonInt(root, "deletions");
    record.revertOf = jsonString(root, "revertOf");
    return record;
}

private void appendChangeRecord(const ref ChangeRecord record)
{
    auto file = File(buildPath(changeWorkspaceDirectory(record.workspace),
        "journal.jsonl"), "a");
    scope (exit) file.close();
    file.writeln(changeRecordToJson(record).toString());
    file.flush();
}

public ChangeRecord[] listChangeRecords(string workspace)
{
    import std.string : splitLines;
    synchronized (_changeJournalMutex)
    {
        const path = buildPath(changeWorkspaceDirectory(workspace),
            "journal.jsonl");
        if (!exists(path)) return [];
        ChangeRecord[] records;
        foreach (line; readText(path).splitLines())
        {
            if (line.strip().length == 0) continue;
            try
            {
                auto root = parseJSON(line);
                auto record = changeRecordFromJson(root);
                if (record.id.length > 0) records ~= record;
            }
            catch (Exception) {}
        }
        return records;
    }
}

private void writeSnapshotBlob(string path, const(ubyte)[] bytes)
{
    write(path, bytes);
}

private void recordMutation(const OpenCodeToolCall call, string workspace,
    const ChangeContext context, const FileSnapshot[] before,
    const FileSnapshot[] after, string transactionId,
    string[] revertIds = null)
{
    FileSnapshot[string] oldByPath;
    FileSnapshot[string] newByPath;
    string[] paths;
    foreach (item; before)
    {
        oldByPath[item.path] = FileSnapshot(item.path, item.exists,
            item.directory, item.bytes.dup);
        if (!paths.canFind(item.path)) paths ~= item.path;
    }
    foreach (item; after)
    {
        newByPath[item.path] = FileSnapshot(item.path, item.exists,
            item.directory, item.bytes.dup);
        if (!paths.canFind(item.path)) paths ~= item.path;
    }
    synchronized (_changeJournalMutex)
    {
        foreach (index, path; paths)
        {
            auto oldState = path in oldByPath ? oldByPath[path] :
                FileSnapshot(path, false, false, null);
            auto newState = path in newByPath ? newByPath[path] :
                FileSnapshot(path, false, false, null);
            if (oldState.exists == newState.exists &&
                oldState.directory == newState.directory &&
                oldState.bytes == newState.bytes) continue;
            const id = to!string(Clock.currTime.stdTime) ~ "-" ~
                to!string(++_changeSequence);
            const root = changeWorkspaceDirectory(workspace);
            ChangeRecord record;
            record.id = id;
            record.transactionId = transactionId;
            record.conversationId = context.conversationId;
            record.turnId = context.turnId;
            record.toolCallId = call.id;
            record.toolName = call.name;
            record.workspace = buildNormalizedPath(workspace);
            record.path = path;
            record.changeKind = !oldState.exists ? "Created" :
                (!newState.exists ? "Deleted" : "Modified");
            record.timestamp = Clock.currTime.toLocalTime.toISOExtString();
            record.beforeExists = oldState.exists;
            record.afterExists = newState.exists;
            record.beforeDirectory = oldState.directory;
            record.afterDirectory = newState.directory;
            record.beforeHash = snapshotHash(oldState.exists,
                oldState.directory, oldState.bytes);
            record.afterHash = snapshotHash(newState.exists,
                newState.directory, newState.bytes);
            if (oldState.exists && !oldState.directory)
            {
                record.beforeBlob = buildPath(root, "blobs", id ~ ".before");
                writeSnapshotBlob(record.beforeBlob, oldState.bytes);
            }
            if (newState.exists && !newState.directory)
            {
                record.afterBlob = buildPath(root, "blobs", id ~ ".after");
                writeSnapshotBlob(record.afterBlob, newState.bytes);
            }
            if (!oldState.directory && !newState.directory &&
                snapshotIsText(oldState.bytes) &&
                snapshotIsText(newState.bytes))
            {
                auto diff = computeTextDiff(cast(string) oldState.bytes,
                    cast(string) newState.bytes);
                record.additions = diff.additions;
                record.deletions = diff.deletions;
            }
            if (index < revertIds.length) record.revertOf = revertIds[index];
            appendChangeRecord(record);
        }
    }
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
    ref string[] argv, ref bool background)
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
    if (auto field = "background" in value.object)
        background = field.type == JSONType.true_;
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

private ToolExecution runBash(string args, string workspace,
    ToolCancellation cancellation = null)
{
    string command;
    string shell = "auto";
    string workdir;
    int timeoutMs = 3_600_000;
    string[] argvExtra;
    bool background;
    if (!parseToolArgs(args, command, shell, workdir, timeoutMs, argvExtra,
        background))
        return ToolExecution("bash",
            "Error: bash requires a JSON object payload.", true);
    if (command.length == 0)
        return ToolExecution("bash",
            "Error: bash requires a non-empty `command` argument.", true);
    if (timeoutMs <= 0)
        timeoutMs = 3_600_000;

    if (shell == "auto")
        shell = defaultShellName();
    auto argv = shellCommand(shell, command);
    const resolvedWorkdir = workdir.length > 0
        ? resolveToolPath(workdir, workspace) : workspace;

    if (background)
        return startBackgroundProcess(argv, resolvedWorkdir, timeoutMs, "bash");
    auto result = runProcess(argv, resolvedWorkdir, timeoutMs, "bash",
        cancellation);
    return ToolExecution("bash", truncateOutput(result[0]), result[1]);
}

/// The D-native `run` tool: execute a program directly with an argument list,
/// never through a shell. This is the cross-platform replacement for the
/// bash/cmd/powershell tool: the model names the program and its arguments,
/// and the app spawns it directly, so no shell syntax or quoting is involved.
private ToolExecution runProgramTool(string args, string workspace,
    ToolCancellation cancellation = null)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string program;
    string workdir;
    int timeoutMs = 3_600_000;
    bool background;
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
        if (auto field = "background" in value.object)
            background = field.type == JSONType.true_;
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
        timeoutMs = 3_600_000;

    // spawnProcess resolves bare names against PATH, but not against the
    // requested workdir. Resolve local executables there so a just-built
    // program works with either `app.exe` or `.\app.exe` on Windows.
    const resolvedWorkdir = workdir.length > 0
        ? resolveToolPath(workdir, workspace) : workspace;
    auto fullArgv = [program] ~ argv;
    if (!isAbsolute(program))
    {
        const hasSeparator = program.indexOf('/') >= 0 ||
            program.indexOf('\\') >= 0;
        version (Windows)
            const localName = extension(program).toLower() == ".exe";
        else
            const localName = false;
        if (hasSeparator || localName)
        {
            const localPath = buildNormalizedPath(buildPath(
                resolvedWorkdir, program));
            if (exists(localPath) && isFile(localPath))
                fullArgv[0] = localPath;
        }
    }

    if (background)
        return startBackgroundProcess(fullArgv, resolvedWorkdir, timeoutMs,
            "run");
    auto result = runProcess(fullArgv, resolvedWorkdir, timeoutMs, "run",
        cancellation);
    return ToolExecution("run", truncateOutput(result[0]), result[1]);
}

/// The D-native `webfetch` tool: fetch an HTTP(S) URL through the system
/// `curl` and return the body as text. `curl` ships with Windows 10+ and is
/// present on almost every Unix, so a fetch needs no shell and no URL
/// quoting. HTML is reduced to readable text unless `raw` is set, and the
/// result is truncated like every other tool's output. The reducer skips
/// script/style/SVG bodies, so a page whose inlined CSS is larger than its
/// text still shows its content inside that budget.
private ToolExecution runWebFetch(string args, string workspace,
    ToolCancellation cancellation = null)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;

    string url;
    int timeoutMs = 30_000;
    bool raw;
    if (value.type == JSONType.object)
    {
        if (auto field = "url" in value.object)
            if (field.type == JSONType.string)
                url = field.str;
        if (auto field = "timeout" in value.object)
            if (field.type == JSONType.integer)
                timeoutMs = cast(int) field.integer;
        if (auto field = "raw" in value.object)
            raw = field.type == JSONType.true_;
    }
    url = strip(url);
    if (url.length == 0)
        return ToolExecution("webfetch",
            "Error: webfetch requires a non-empty `url` argument.", true);
    if (indexOf(url, "://") < 0)
        url = "https://" ~ url;
    const loweredUrl = toLower(url);
    if (!startsWith(loweredUrl, "http://") &&
        !startsWith(loweredUrl, "https://"))
        return ToolExecution("webfetch",
            "Error: only http:// and https:// URLs are supported.", true);
    if (timeoutMs <= 0)
        timeoutMs = 30_000;

    version (Windows)
        auto argv = ["curl.exe"];
    else
        auto argv = ["curl"];
    argv ~= "-sS";
    argv ~= "-L";
    argv ~= "--max-time";
    argv ~= to!string((timeoutMs + 999) / 1000);
    argv ~= url;

    auto result = runProcess(argv, workspace, timeoutMs + 10_000, "webfetch",
        cancellation);
    string output = result[0];
    bool failed = result[1];

    // curl can exit non-zero (for example the schannel close_notify quirk on
    // some Windows builds) while still delivering a complete body. When a real
    // body was captured, drop the runner's exit-code note and treat the fetch
    // as successful so the model does not discard good content.
    if (failed)
    {
        const note = lastIndexOf(output, "\nProcess exited with code ");
        if (note > 0)
        {
            const body = output[0 .. cast(size_t) note];
            if (strip(body).length > 0)
            {
                output = body;
                failed = false;
            }
        }
    }

    if (!failed && !raw)
    {
        const loweredBody = toLower(output);
        if (canFind(loweredBody, "<html") ||
            canFind(loweredBody, "<!doctype html"))
            output = htmlToText(output);
    }

    if (strip(output).length == 0)
        output = "(empty response body)";

    return ToolExecution("webfetch", truncateOutput(output), failed);
}

/// Reduce an HTML document to readable plain text: tags are dropped, a small
/// set of common entities is decoded, and whitespace runs are collapsed. This
/// is deliberately tiny - enough to make a fetched page legible, not an HTML
/// parser. The bodies of non-content elements (`script`, `style`, `noscript`,
/// `svg`, `template`) and HTML comments are dropped: on a single-file page the
/// inlined CSS is many times larger than the text, so keeping it would spend
/// the whole output cap on styles and truncate away the actual content.
private string htmlToText(string html)
{
    static immutable string[] nonContentElements =
        ["script", "style", "noscript", "svg", "template"];

    auto builder = appender!string();
    string pending;
    string tagName;
    bool inTag;
    bool maybeEntity;
    bool inComment;
    string skipping;

    void flushEntity()
    {
        const name = toLower(pending);
        if (name == "amp") builder.put('&');
        else if (name == "lt") builder.put('<');
        else if (name == "gt") builder.put('>');
        else if (name == "quot") builder.put('"');
        else if (name == "apos" || name == "#39") builder.put('\'');
        else if (name == "nbsp") builder.put(' ');
        else if (name == "hellip") builder.put('.');
        else if (name == "mdash" || name == "ndash") builder.put('-');
        else if (name == "rsquo" || name == "lsquo" || name == "ldquo" ||
            name == "rdquo") builder.put('\'');
        else builder.put("&" ~ pending ~ ";");
        pending = "";
        maybeEntity = false;
    }

    size_t index;
    while (index < html.length)
    {
        const ch = html[index];

        // Inside a comment: drop everything up to the closing `-->`.
        if (inComment)
        {
            if (ch == '-' && index + 2 < html.length &&
                html[index + 1] == '-' && html[index + 2] == '>')
            {
                inComment = false;
                index += 3;
                continue;
            }
            ++index;
            continue;
        }

        // Inside a non-content element: drop everything up to its close tag.
        if (skipping.length > 0)
        {
            const hasClose = ch == '<' &&
                index + 2 + skipping.length <= html.length &&
                html[index + 1] == '/' &&
                toLower(html[index + 2 .. index + 2 + skipping.length]) == skipping;
            if (hasClose)
            {
                const close = indexOf(html[index .. $], ">");
                index = close < 0 ? html.length
                    : index + cast(size_t) close + 1;
                skipping = "";
                builder.put(' ');
                continue;
            }
            ++index;
            continue;
        }

        if (inTag)
        {
            if (ch == '>')
            {
                inTag = false;
                builder.put(' ');
                string lower = toLower(strip(tagName));
                if (lower.length > 0 && lower[0] != '/' && lower[$ - 1] != '/')
                {
                    size_t nameEnd;
                    while (nameEnd < lower.length && lower[nameEnd] != ' ' &&
                        lower[nameEnd] != '\t' && lower[nameEnd] != '\n' &&
                        lower[nameEnd] != '\r' && lower[nameEnd] != '/')
                        ++nameEnd;
                    if (nonContentElements.canFind(lower[0 .. nameEnd]))
                        skipping = lower[0 .. nameEnd];
                }
            }
            else
                tagName ~= ch;
            ++index;
            continue;
        }
        if (maybeEntity)
        {
            if (ch == ';')
            {
                flushEntity();
                ++index;
                continue;
            }
            if (ch != '&' && ch != '<' && ch != ' ' && pending.length < 10)
            {
                pending ~= ch;
                ++index;
                continue;
            }
            builder.put("&" ~ pending);
            pending = "";
            maybeEntity = false;
        }

        if (ch == '<')
        {
            if (index + 3 < html.length && html[index + 1] == '!' &&
                html[index + 2] == '-' && html[index + 3] == '-')
            {
                inComment = true;
                index += 4;
                continue;
            }
            inTag = true;
            tagName = "";
            ++index;
            continue;
        }
        if (ch == '&') { maybeEntity = true; pending = ""; ++index; continue; }
        builder.put(ch);
        ++index;
    }
    if (maybeEntity)
        builder.put("&" ~ pending);

    auto collapsed = appender!string();
    bool pendingSpace;
    foreach (ch; builder.data)
    {
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\f')
        {
            pendingSpace = true;
            continue;
        }
        if (pendingSpace && collapsed.data.length > 0)
            collapsed.put(' ');
        pendingSpace = false;
        collapsed.put(ch);
    }
    return strip(collapsed.data);
}

/// Identity attached to mutations initiated by a real GUI conversation. An
/// empty conversation id disables journaling, keeping standalone tool tests and
/// probes isolated from the user's durable history.
public struct ChangeContext
{
    string conversationId;
    string turnId;
}

/// One filesystem path in Aurora's append-only mutation journal. File contents
/// are stored as private blobs; directory presence is recorded explicitly so
/// empty-folder changes can also be reverted safely.
public struct ChangeRecord
{
    string id;
    string transactionId;
    string conversationId;
    string turnId;
    string toolCallId;
    string toolName;
    string workspace;
    string path;
    string changeKind;
    string timestamp;
    bool beforeExists;
    bool afterExists;
    bool beforeDirectory;
    bool afterDirectory;
    string beforeHash;
    string afterHash;
    string beforeBlob;
    string afterBlob;
    int additions;
    int deletions;
    string revertOf;
}

public struct ChangeRevertResult
{
    bool succeeded;
    bool conflict;
    string message;
    int files;
}

private struct FileSnapshot
{
    string path;
    bool exists;
    bool directory;
    ubyte[] bytes;
}

private __gshared ulong _changeSequence;
private __gshared Mutex _changeJournalMutex;

/// Open a target through the operating system without routing it through a
/// command shell. HTTP(S) targets pass through unchanged; local paths are
/// resolved against the conversation workspace and must already exist.
private ToolExecution runOpenTool(string args, string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string target;
    if (value.type == JSONType.object)
        if (auto field = "target" in value.object)
            if (field.type == JSONType.string)
                target = field.str.strip();
    if (target.length == 0)
        return ToolExecution("open",
            "Error: open requires a non-empty `target` argument.", true);

    const lower = target.toLower();
    const isWebUrl = lower.indexOf("https://") == 0 ||
        lower.indexOf("http://") == 0;
    if (!isWebUrl)
    {
        target = resolveToolPath(target, workspace);
        if (!exists(target))
            return ToolExecution("open",
                "Error: target does not exist: " ~ target, true);
    }

    version (Windows)
    {
        const result = ShellExecuteW(null, toUTF16z("open"),
            toUTF16z(target), null, null, 1);
        if (cast(size_t) result <= 32)
            return ToolExecution("open",
                "Error: Windows could not open the target (ShellExecute " ~
                to!string(cast(size_t) result) ~ "): " ~ target, true);
    }
    else version (OSX)
    {
        auto result = runProcess(["open", target], workspace, 30_000,
            "open");
        if (result[1])
            return ToolExecution("open", truncateOutput(result[0]), true);
    }
    else
    {
        auto result = runProcess(["xdg-open", target], workspace, 30_000,
            "open");
        if (result[1])
            return ToolExecution("open", truncateOutput(result[0]), true);
    }
    return ToolExecution("open", "Opened: " ~ target, false);
}

// ---------------------------------------------------------------------------
// Supervised background processes
// ---------------------------------------------------------------------------

private final class SupervisedProcess
{
    string id;
    string command;
    string workdir;
    string outputPath;
    Pid pid;
    File input;
    bool stdinClosed;
    MonoTime startedAt;
    bool running = true;
    bool killRequested;
    bool killed;
    bool timedOut;
    int exitCode;
    long elapsedMs;
}

private __gshared Mutex _processMutex;
private __gshared SupervisedProcess[string] _processes;
private __gshared ulong _processCounter;
private __gshared Mutex _workspaceLocksMutex;
private __gshared Mutex[string] _workspaceMutationLocks;

shared static this()
{
    _processMutex = new Mutex();
    _workspaceLocksMutex = new Mutex();
    _changeJournalMutex = new Mutex();
}

private Mutex workspaceMutationLock(string workspace)
{
    auto key = buildNormalizedPath(workspace);
    version (Windows) key = key.toLower();
    _workspaceLocksMutex.lock();
    scope (exit) _workspaceLocksMutex.unlock();
    if (auto found = key in _workspaceMutationLocks) return *found;
    auto created = new Mutex();
    _workspaceMutationLocks[key] = created;
    return created;
}

private string displayCommand(const(string)[] argv)
{
    auto result = appender!string();
    foreach (index, arg; argv)
    {
        if (index > 0) result.put(' ');
        result.put(arg);
    }
    return result.data;
}

private ToolExecution startBackgroundProcess(string[] argv, string workdir,
    int timeoutMs, string toolName)
{
    import core.atomic : atomicLoad;

    if (atomicLoad(_commandsCancelled))
        return ToolExecution(toolName,
            "Stopped: command cancelled before it started.", true);

    string id;
    _processMutex.lock();
    id = "p-" ~ to!string(cast(long) MonoTime.currTime.ticks) ~ "-" ~
        to!string(++_processCounter);
    _processMutex.unlock();
    const outPath = buildNormalizedPath(buildPath(cast(string) tempDir(),
        "aurora-opencode-process-" ~ id ~ ".out"));
    File outFile;
    if (!tryOpenOutput(outPath, outFile, toolName))
        return ToolExecution(toolName,
            "Error: could not open background process output.", true);

    Pipe inputPipe;
    try inputPipe = pipe();
    catch (Exception error)
    {
        collectException(outFile.close());
        collectException(remove(outPath));
        return ToolExecution(toolName,
            "Error: could not create process stdin: " ~ error.msg, true);
    }

    Pid pid;
    try pid = spawnProcess(argv, inputPipe.readEnd, outFile, outFile, null,
        Config.suppressConsole, workdir);
    catch (Exception error)
    {
        collectException(inputPipe.close());
        collectException(outFile.close());
        collectException(remove(outPath));
        return ToolExecution(toolName,
            "Error: could not start process: " ~ error.msg, true);
    }
    // The child owns its duplicated output handle. Closing our copy allows
    // status/output calls to read the file while the process is still active.
    collectException(inputPipe.readEnd.close());
    collectException(outFile.close());

    auto process = new SupervisedProcess();
    process.id = id;
    process.command = displayCommand(argv);
    process.workdir = workdir;
    process.outputPath = outPath;
    process.pid = pid;
    process.input = inputPipe.writeEnd;
    process.startedAt = MonoTime.currTime;
    _processMutex.lock();
    _processes[id] = process;
    _processMutex.unlock();

    auto monitor = new Thread({ monitorBackgroundProcess(process, timeoutMs); });
    monitor.isDaemon = true;
    monitor.start();
    return ToolExecution(toolName,
        "Background process started.\nprocessId: " ~ id ~
        "\nUse the process tool to inspect status or output.", false);
}

private void monitorBackgroundProcess(SupervisedProcess process, int timeoutMs)
{
    const timeout = msecs(timeoutMs);
    auto stopwatch = StopWatch(AutoStart.yes);
    while (true)
    {
        const waited = waitTimeout(process.pid, msecs(100));
        if (waited.terminated)
        {
            _processMutex.lock();
            process.running = false;
            process.exitCode = waited.status;
            process.elapsedMs = stopwatch.peek.total!"msecs";
            if (!process.stdinClosed)
            {
                collectException(process.input.close());
                process.stdinClosed = true;
            }
            _processMutex.unlock();
            return;
        }

        _processMutex.lock();
        const killRequested = process.killRequested;
        _processMutex.unlock();
        const timedOut = stopwatch.peek > timeout;
        if (!killRequested && !timedOut) continue;

        killProcessTree(process.pid);
        _processMutex.lock();
        process.running = false;
        process.killed = killRequested;
        process.timedOut = timedOut;
        process.exitCode = 1;
        process.elapsedMs = stopwatch.peek.total!"msecs";
        if (!process.stdinClosed)
        {
            collectException(process.input.close());
            process.stdinClosed = true;
        }
        _processMutex.unlock();
        return;
    }
}

private string processStatusText(const SupervisedProcess process)
{
    const elapsed = process.running
        ? (MonoTime.currTime - process.startedAt).total!"msecs"
        : process.elapsedMs;
    string state = process.running ? "running" :
        (process.timedOut ? "timed_out" :
        (process.killed ? "killed" : "exited"));
    auto result = "processId: " ~ process.id ~ "\nstatus: " ~ state;
    if (!process.running) result ~= "\nexitCode: " ~ to!string(process.exitCode);
    result ~= "\nelapsedMs: " ~ to!string(elapsed) ~
        "\nstdin: " ~ (process.stdinClosed ? "closed" : "open") ~
        "\nworkdir: " ~ process.workdir ~
        "\ncommand: " ~ process.command;
    return result;
}

private ToolExecution runProcessTool(string args)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    if (value.type != JSONType.object)
        return ToolExecution("process",
            "Error: process requires a JSON object payload.", true);
    string action;
    string id;
    string input;
    bool closeStdin;
    if (auto field = "action" in value.object)
        if (field.type == JSONType.string) action = field.str;
    if (auto field = "processId" in value.object)
        if (field.type == JSONType.string) id = field.str;
    if (auto field = "input" in value.object)
        if (field.type == JSONType.string) input = field.str;
    if (auto field = "closeStdin" in value.object)
        closeStdin = field.type == JSONType.true_;

    if (action == "list")
    {
        string result;
        _processMutex.lock();
        foreach (process; _processes)
            result ~= (result.length > 0 ? "\n\n" : "") ~
                processStatusText(process);
        _processMutex.unlock();
        return ToolExecution("process",
            result.length > 0 ? result : "No supervised processes.", false);
    }
    if (id.length == 0)
        return ToolExecution("process",
            "Error: processId is required for action '" ~ action ~ "'.", true);

    _processMutex.lock();
    auto found = id in _processes;
    auto process = found is null ? null : *found;
    if (process is null)
    {
        _processMutex.unlock();
        return ToolExecution("process",
            "Error: unknown processId '" ~ id ~ "'.", true);
    }
    if (action == "status")
    {
        const result = processStatusText(process);
        _processMutex.unlock();
        return ToolExecution("process", result, false);
    }
    if (action == "kill")
    {
        if (process.running) process.killRequested = true;
        const running = process.running;
        _processMutex.unlock();
        return ToolExecution("process", running
            ? "Termination requested for " ~ id ~ "."
            : "Process " ~ id ~ " has already finished.", false);
    }
    if (action == "write")
    {
        if (!process.running)
        {
            _processMutex.unlock();
            return ToolExecution("process",
                "Error: process " ~ id ~ " has already finished.", true);
        }
        if (process.stdinClosed)
        {
            _processMutex.unlock();
            return ToolExecution("process",
                "Error: stdin is already closed for " ~ id ~ ".", true);
        }
        try
        {
            if (input.length > 0) process.input.write(input);
            if (input.length > 0) process.input.flush();
            if (closeStdin)
            {
                process.input.close();
                process.stdinClosed = true;
            }
        }
        catch (Exception error)
        {
            _processMutex.unlock();
            return ToolExecution("process",
                "Error: could not write process stdin: " ~ error.msg, true);
        }
        const closed = process.stdinClosed;
        _processMutex.unlock();
        return ToolExecution("process",
            (input.length > 0 ? "Wrote " ~ to!string(input.length) ~
                " bytes to " ~ id ~ "." : "No input bytes written.") ~
            (closed ? " Stdin closed." : ""), false);
    }
    if (action == "remove")
    {
        if (process.running)
        {
            _processMutex.unlock();
            return ToolExecution("process",
                "Error: kill or wait for " ~ id ~ " before removing it.", true);
        }
        if (!process.stdinClosed) collectException(process.input.close());
        _processes.remove(id);
        const path = process.outputPath;
        _processMutex.unlock();
        collectException(remove(path));
        return ToolExecution("process", "Removed process record " ~ id ~ ".",
            false);
    }
    _processMutex.unlock();

    if (action == "output")
    {
        string output;
        try output = exists(process.outputPath)
            ? decodeBytesLenient(cast(const(ubyte)[]) read(process.outputPath))
            : "";
        catch (Exception error)
            return ToolExecution("process",
                "Error: could not read process output: " ~ error.msg, true);
        return ToolExecution("process", output.length > 0
            ? truncateOutput(output) : "(no output yet)", false);
    }
    return ToolExecution("process",
        "Error: action must be list, status, output, write, kill, or remove.",
        true);
}

/// Set while the user has asked to stop the current turn. A command launched by
/// `runProcess` polls this flag and terminates its process as soon as it is
/// observed. It is cleared at the start of each tool batch so an earlier stop
/// cannot abort a later turn.
private shared bool _commandsCancelled;

/// Per-conversation cancellation token. Each running chat owns one, so
/// stopping a command in one conversation cannot terminate commands launched
/// by another conversation.
public final class ToolCancellation
{
    private shared bool _cancelled;

    public void cancel()
    {
        import core.atomic : atomicStore;
        atomicStore(_cancelled, true);
    }

    public void reset()
    {
        import core.atomic : atomicStore;
        atomicStore(_cancelled, false);
    }

    public bool cancelled()
    {
        import core.atomic : atomicLoad;
        return atomicLoad(_cancelled);
    }
}

/// Request termination of any in-flight command process. Safe to call from the
/// UI thread while the process runs on a worker thread.
public void cancelRunningCommands()
{
    import core.atomic : atomicStore;
    atomicStore(_commandsCancelled, true);
}

/// Clear the stop request before a new batch of tool calls begins.
public void resetRunningCommands()
{
    import core.atomic : atomicStore;
    atomicStore(_commandsCancelled, false);
}

/// Terminate `pid` and every process it spawned. Commands are launched through
/// a shell wrapper (cmd/powershell/bash), so the real work runs in
/// grandchildren; `std.process.kill` only signals the direct child and leaves
/// those running. On Windows the descendant tree is walked natively and each
/// process terminated with `TerminateProcess` (no external `taskkill`).
private void killProcessTree(Pid pid)
{
    version (Windows)
        killProcessTreeWindows(cast(DWORD) pid.processID);
    else
    {
        try kill(pid);
        catch (Exception) {}
    }
    try wait(pid);
    catch (Exception) {}
}

version (Windows)
{
    private struct PROCESSENTRY32W
    {
        DWORD dwSize;
        DWORD cntUsage;
        DWORD th32ProcessID;
        ULONG_PTR th32DefaultHeapID;
        DWORD th32ModuleID;
        DWORD cntThreads;
        DWORD th32ParentProcessID;
        LONG pcPriClassBase;
        DWORD dwFlags;
        WCHAR[260] szExeFile;
    }

    private enum DWORD TH32CS_SNAPPROCESS = 0x00000002;
    private enum DWORD PROCESS_TERMINATE = 0x0001;

    // Bound by mangled name so they do not clash with druntime's own decls.
    pragma(mangle, "CreateToolhelp32Snapshot")
    private extern(Windows) HANDLE _CreateToolhelp32Snapshot(DWORD, DWORD);
    pragma(mangle, "Process32FirstW")
    private extern(Windows) BOOL _Process32FirstW(HANDLE, PROCESSENTRY32W*);
    pragma(mangle, "Process32NextW")
    private extern(Windows) BOOL _Process32NextW(HANDLE, PROCESSENTRY32W*);
    pragma(mangle, "OpenProcess")
    private extern(Windows) HANDLE _OpenProcess(DWORD, BOOL, DWORD);
    pragma(mangle, "TerminateProcess")
    private extern(Windows) BOOL _TerminateProcess(HANDLE, UINT);
    pragma(mangle, "CloseHandle")
    private extern(Windows) BOOL _CloseHandle(HANDLE);

    /// Native whole-tree termination. Snapshot every process once, then walk
    /// parent -> child links so all descendants die, not just the direct child.
    private void killProcessTreeWindows(DWORD rootPid)
    {
        DWORD[] pids;
        DWORD[] parents;
        auto snapshot = _CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot != cast(HANDLE) -1 && snapshot !is null)
        {
            PROCESSENTRY32W entry;
            entry.dwSize = cast(DWORD) PROCESSENTRY32W.sizeof;
            if (_Process32FirstW(snapshot, &entry))
            {
                do
                {
                    pids ~= entry.th32ProcessID;
                    parents ~= entry.th32ParentProcessID;
                    entry.dwSize = cast(DWORD) PROCESSENTRY32W.sizeof;
                } while (_Process32NextW(snapshot, &entry));
            }
            _CloseHandle(snapshot);
        }

        void killRecursive(DWORD target, int depth)
        {
            // Descendants first so nothing can respawn work, depth-capped in
            // case the snapshot ever reports a cyclic parent chain.
            if (depth < 32)
                foreach (i, parent; parents)
                    if (parent == target && pids[i] != target)
                        killRecursive(pids[i], depth + 1);
            auto handle = _OpenProcess(PROCESS_TERMINATE, false, target);
            if (handle !is null)
            {
                _TerminateProcess(handle, 1);
                _CloseHandle(handle);
            }
        }
        killRecursive(rootPid, 0);
    }
}

/// Shared process runner used by the shell tool and the native `run` tool.
/// Spawns `argv` directly (no shell), redirects stdout+stderr to a temp file,
/// waits up to `timeoutMs`, and kills on timeout. Output is decoded leniently
/// (console tools emit the OEM codepage, not UTF-8). Returns (output,
/// timedOut).
private Tuple!(string, bool) runProcess(string[] argv, string workdir,
    int timeoutMs, string toolName, ToolCancellation cancellation = null)
{
    import std.typecons : tuple;
    import core.atomic : atomicLoad;

    // A stop may have been requested after the previous command finished but
    // before this one launched; honor it without starting the process at all.
    if ((cancellation !is null && cancellation.cancelled()) ||
        (cancellation is null && atomicLoad(_commandsCancelled)))
        return tuple("Stopped: command cancelled before it started.", true);

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
    auto stopwatch = StopWatch(AutoStart.yes);
    bool timedOut;
    bool cancelled;
    int exitCode;
    // Poll rather than blocking for the whole timeout so a stop request can
    // terminate a long-running command promptly instead of waiting it out.
    while (true)
    {
        const waited = waitTimeout(pid, msecs(100));
        if (waited.terminated)
        {
            exitCode = waited.status;
            break;
        }
        if ((cancellation !is null && cancellation.cancelled()) ||
            (cancellation is null && atomicLoad(_commandsCancelled)))
        {
            cancelled = true;
            break;
        }
        if (stopwatch.peek > timeout)
        {
            timedOut = true;
            break;
        }
    }
    if (timedOut || cancelled)
        killProcessTree(pid);

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
    if (cancelled)
        output = (output.length > 0 ? output ~ "\n" : "") ~
            "\n…(stopped by user; process terminated)";
    else if (timedOut)
        output = (output.length > 0 ? output ~ "\n" : "") ~
            "\n…(process timed out after " ~ to!string(timeoutMs) ~
            "ms and was killed)";
    else if (exitCode != 0)
        output = (output.length > 0 ? output ~ "\n" : "") ~
            "Process exited with code " ~ to!string(exitCode) ~ ".";
    if (output.length == 0) output = "(no output)";
    return tuple(output, timedOut || cancelled || exitCode != 0);
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

private ToolExecution runViewImage(string args, string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string filePath;
    if (value.type == JSONType.object)
        if (auto field = "filePath" in value.object)
            if (field.type == JSONType.string)
                filePath = field.str;
    if (filePath.length == 0)
        return ToolExecution("view_image",
            "Error: view_image requires a `filePath` argument.", true);

    const path = resolveToolPath(filePath, workspace);
    if (!exists(path) || !isFile(path))
        return ToolExecution("view_image", "Error: image file not found: " ~
            path, true);

    ulong size;
    try size = getSize(path);
    catch (Exception error)
        return ToolExecution("view_image", "Error: could not inspect image: " ~
            error.msg, true);
    if (size == 0)
        return ToolExecution("view_image", "Error: image file is empty: " ~
            path, true);
    if (size > attachmentImageMaxBytes)
        return ToolExecution("view_image", "Error: image is " ~
            to!string(size) ~ " bytes; the maximum is " ~
            to!string(attachmentImageMaxBytes) ~ " bytes. Resize or convert " ~
            "it before viewing.", true);

    ubyte[] data;
    try data = cast(ubyte[]) read(path);
    catch (Exception error)
        return ToolExecution("view_image", "Error: could not read image: " ~
            error.msg, true);
    const mimeType = attachmentImageKindForBytes(data);
    if (mimeType.length == 0)
        return ToolExecution("view_image", "Error: unsupported image format: " ~
            path ~ ". Expected PNG, JPEG, WebP, or GIF.", true);

    ToolExecution result;
    result.name = "view_image";
    result.output = "Loaded image for visual inspection: " ~ path ~ " (" ~
        to!string(size) ~ " bytes, " ~ mimeType ~ ").";
    result.images = [attachmentImageForData(mimeType, baseName(path), data)];
    return result;
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
        import std.path : dirName;
        if (dirName(path).length > 0) mkdirRecurse(dirName(path));
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

/// Join patch lines with the newline the patch format uses.
private string joinPatchLines(string[] items)
{
    auto builder = appender!string();
    foreach (index, item; items)
    {
        if (index > 0) builder.put("\n");
        builder.put(item);
    }
    return builder.data;
}

/// Normalize CRLF/CR to LF while retaining a map from each normalized byte
/// offset back to the original string. apply_patch uses this only as a context
/// fallback, so matching ignores line-ending style without rewriting unrelated
/// lines or normalizing an entire mixed-ending file.
private string normalizePatchContext(string input, ref size_t[] offsets)
{
    auto normalized = appender!string();
    size_t index;
    while (index < input.length)
    {
        offsets ~= index;
        if (input[index] == '\r')
        {
            if (index + 1 < input.length && input[index + 1] == '\n')
                ++index;
            normalized.put('\n');
        }
        else
            normalized.put(input[index]);
        ++index;
    }
    offsets ~= input.length;
    return normalized.data;
}

private bool findPatchContextIgnoringNewlines(string content,
    string oldBlock, size_t searchPos, out size_t start, out size_t end)
{
    size_t[] contentOffsets;
    size_t[] unused;
    const normalizedContent = normalizePatchContext(content, contentOffsets);
    const normalizedOld = normalizePatchContext(oldBlock, unused);
    if (normalizedOld.length == 0) return false;
    size_t normalizedFrom;
    while (normalizedFrom < contentOffsets.length &&
        contentOffsets[normalizedFrom] < searchPos)
        ++normalizedFrom;
    const found = normalizedContent.indexOf(normalizedOld, normalizedFrom);
    if (found < 0) return false;
    start = contentOffsets[cast(size_t) found];
    end = contentOffsets[cast(size_t) found + normalizedOld.length];
    return true;
}

/// True when `line` (after trimming) starts with one of the `*** ...`
/// section markers used by the Codex patch format.
private bool isPatchDirective(string line)
{
    const trimmed = strip(line);
    foreach (prefix; ["*** Begin Patch", "*** End Patch", "*** Add File:",
        "*** Update File:", "*** Delete File:", "*** Move to:"])
    {
        if (trimmed.length >= prefix.length &&
            trimmed[0 .. prefix.length] == prefix)
            return true;
    }
    return false;
}

/// Apply a Codex-format patch to one or more files in a single call. The
/// patch is a sequence of `*** Add File:` / `*** Update File:` /
/// `*** Delete File:` sections wrapped in `*** Begin Patch` / `*** End
/// Patch`. This is the multi-file editing workflow: many hunks across many
/// files cost one round instead of one round per edit.
private ToolExecution runApplyPatch(string args, string workspace)
{
    import std.string : splitLines;

    struct PatchChange
    {
        string relativePath;
        string path;
        bool beforeExists;
        string before;
        bool afterExists;
        string after;
    }

    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string patch;
    if (value.type == JSONType.object)
    {
        foreach (key; ["patch", "input", "text"])
        {
            if (auto field = key in value.object)
            {
                if (field.type == JSONType.string && field.str.length > 0)
                {
                    patch = field.str;
                    break;
                }
            }
        }
    }
    if (patch.length == 0)
        return ToolExecution("apply_patch",
            "Error: apply_patch requires a `patch` string.", true);

    patch = patch.replace("\r\n", "\n").replace("\r", "\n");
    auto lines = patch.splitLines();
    if (lines.length > 0 && lines[$ - 1].length == 0)
        lines = lines[0 .. $ - 1];

    // `*** Move to:` is part of another patch dialect. This parser used to
    // treat it only as a section boundary, then report success after rewriting
    // the original file unchanged. Never fake that move: the dedicated tool
    // handles files, trees and batches with collision checks and journaling.
    foreach (line; lines)
        if (strip(line).startsWith("*** Move to:"))
            return ToolExecution("apply_patch",
                "Error: apply_patch does not move paths. Use the `move` tool " ~
                "with `source` and `destinationFolder` instead.", true);

    // Locate the envelope; be lenient if the model omitted the markers.
    size_t bodyStart = 0;
    size_t bodyEnd = lines.length;
    foreach (index, line; lines)
        if (strip(line) == "*** Begin Patch")
        {
            bodyStart = index + 1;
            break;
        }
    for (size_t index = lines.length; index > 0; --index)
        if (strip(lines[index - 1]) == "*** End Patch")
        {
            bodyEnd = index - 1;
            break;
        }
    if (bodyStart > bodyEnd) bodyStart = bodyEnd;

    PatchChange[] changes;
    string[] failures;

    bool alreadyStaged(string path)
    {
        const comparable = comparableSearchPath(path);
        foreach (change; changes)
            if (comparableSearchPath(change.path) == comparable) return true;
        return false;
    }

    size_t cursor = bodyStart;
    while (cursor < bodyEnd)
    {
        const directive = strip(lines[cursor]);
        if (directive.length == 0)
        {
            ++cursor;
            continue;
        }
        if (directive.length >= "*** Add File:".length &&
            directive[0 .. "*** Add File:".length] == "*** Add File:")
        {
            const rel = strip(directive["*** Add File:".length .. $]);
            ++cursor;
            auto builder = appender!string();
            bool first = true;
            while (cursor < bodyEnd && !isPatchDirective(lines[cursor]))
            {
                const raw = lines[cursor];
                if (!first) builder.put("\n");
                first = false;
                builder.put(raw.length > 0 && raw[0] == '+' ? raw[1 .. $] : raw);
                ++cursor;
            }
            if (rel.length == 0)
            {
                failures ~= "Add File: path is empty";
                continue;
            }
            const path = resolveToolPath(rel, workspace);
            try
            {
                if (alreadyStaged(path))
                    failures ~= rel ~ ": duplicate patch section";
                else if (exists(path))
                    failures ~= rel ~ ": path already exists";
                else
                    changes ~= PatchChange(rel, path, false, "", true,
                        builder.data);
            }
            catch (Exception error)
                failures ~= rel ~ ": " ~ error.msg;
            continue;
        }
        if (directive.length >= "*** Delete File:".length &&
            directive[0 .. "*** Delete File:".length] == "*** Delete File:")
        {
            const rel = strip(directive["*** Delete File:".length .. $]);
            ++cursor;
            if (rel.length == 0)
            {
                failures ~= "Delete File: path is empty";
                continue;
            }
            const path = resolveToolPath(rel, workspace);
            try
            {
                if (alreadyStaged(path))
                    failures ~= rel ~ ": duplicate patch section";
                else if (!exists(path) || !isFile(path))
                    failures ~= rel ~ ": file not found";
                else
                    changes ~= PatchChange(rel, path, true, readText(path),
                        false, "");
            }
            catch (Exception error)
                failures ~= rel ~ ": " ~ error.msg;
            continue;
        }
        if (directive.length >= "*** Update File:".length &&
            directive[0 .. "*** Update File:".length] == "*** Update File:")
        {
            const rel = strip(directive["*** Update File:".length .. $]);
            ++cursor;
            if (rel.length == 0)
            {
                failures ~= "Update File: path is empty";
                while (cursor < bodyEnd && !isPatchDirective(lines[cursor]))
                    ++cursor;
                continue;
            }
            const path = resolveToolPath(rel, workspace);
            if (alreadyStaged(path))
            {
                failures ~= rel ~ ": duplicate patch section";
                while (cursor < bodyEnd && !isPatchDirective(lines[cursor]))
                    ++cursor;
                continue;
            }
            if (!exists(path) || !isFile(path))
            {
                failures ~= rel ~ ": file not found";
                while (cursor < bodyEnd && !isPatchDirective(lines[cursor]))
                    ++cursor;
                continue;
            }
            string original;
            try original = readText(path);
            catch (Exception error)
            {
                failures ~= rel ~ ": " ~ error.msg;
                while (cursor < bodyEnd && !isPatchDirective(lines[cursor]))
                    ++cursor;
                continue;
            }

            string content = original;
            size_t searchPos;
            bool hunkFailed;
            string failReason;
            string[] oldLines;
            string[] newLines;

            void flushHunk()
            {
                if (oldLines.length == 0 && newLines.length == 0) return;
                const oldBlock = joinPatchLines(oldLines);
                const newBlock = joinPatchLines(newLines);
                // `content.indexOf` returns `ptrdiff_t` and -1 means "not
                // found". Keep it signed until it is known to be valid: mixing
                // it with the unsigned `searchPos` in one expression makes the
                // result `ulong`, so -1 becomes size_t.max, the `at < 0` test is
                // dead, and the slice below runs off the end into a
                // size_t.max-length concatenation (the msvcr120 `memcpy` access
                // violation). Check the signed result first, then widen.
                size_t at;
                size_t oldEnd;
                if (oldBlock.length == 0)
                {
                    at = searchPos;
                    oldEnd = searchPos;
                }
                else
                {
                    const found = content.indexOf(oldBlock, searchPos);
                    if (found < 0)
                    {
                        if (!findPatchContextIgnoringNewlines(content,
                            oldBlock, searchPos, at, oldEnd))
                        {
                            hunkFailed = true;
                            failReason = "patch context not found";
                            return;
                        }
                    }
                    else
                    {
                        at = cast(size_t) found;
                        oldEnd = at + oldBlock.length;
                    }
                }
                const replacement = content.indexOf("\r\n") >= 0
                    ? newBlock.replace("\n", "\r\n") : newBlock;
                content = content[0 .. at] ~ replacement ~
                    content[oldEnd .. $];
                searchPos = at + replacement.length;
                oldLines.length = 0;
                newLines.length = 0;
            }

            while (cursor < bodyEnd)
            {
                const raw = lines[cursor];
                if (isPatchDirective(raw)) break;
                if (strip(raw).length >= 2 && strip(raw)[0 .. 2] == "@@")
                {
                    flushHunk();
                    if (hunkFailed) break;
                    ++cursor;
                    continue;
                }
                if (raw.length == 0)
                {
                    ++cursor;
                    continue;
                }
                const marker = raw[0];
                if (marker == '\\')
                {
                    ++cursor;
                    continue;
                }
                const text = raw.length > 0 ? raw[1 .. $] : "";
                switch (marker)
                {
                    case ' ':
                        oldLines ~= text;
                        newLines ~= text;
                        break;
                    case '-':
                        oldLines ~= text;
                        break;
                    case '+':
                        newLines ~= text;
                        break;
                    default:
                        hunkFailed = true;
                        failReason = "unexpected patch line: " ~ raw;
                        break;
                }
                if (hunkFailed) break;
                ++cursor;
            }
            if (!hunkFailed) flushHunk();
            if (hunkFailed)
            {
                failures ~= rel ~ ": " ~ failReason;
                continue;
            }
            changes ~= PatchChange(rel, path, true, original, true, content);
            continue;
        }
        failures ~= "unexpected patch line: " ~ lines[cursor];
        ++cursor;
    }

    if (changes.length == 0 && failures.length == 0)
        return ToolExecution("apply_patch",
            "Error: no files were changed; the patch had no sections.", true);

    // A patch is one transaction: every section must validate before the first
    // file is touched. This prevents an early successful section from leaking
    // through when a later hunk has stale context or names a missing file.
    if (failures.length > 0)
    {
        auto rejected = appender!string();
        rejected.put("Patch not applied; validation failed and no files were changed:");
        foreach (failure; failures)
            rejected.put("\n- " ~ failure);
        return ToolExecution("apply_patch", rejected.data, true);
    }

    string combinedDiff;
    int totalAdditions;
    int totalDeletions;
    foreach (change; changes)
    {
        auto diff = computeTextDiff(change.before, change.after);
        totalAdditions += diff.additions;
        totalDeletions += diff.deletions;
        combinedDiff ~= diff.unified ~ "\n";
    }

    bool stateMatches(ref PatchChange change)
    {
        if (exists(change.path) != change.beforeExists) return false;
        if (!change.beforeExists) return true;
        return isFile(change.path) && readText(change.path) == change.before;
    }

    string[] createdDirectories;
    void ensureParent(string path)
    {
        string parent = dirName(path);
        string[] missing;
        while (parent.length > 0 && !exists(parent))
        {
            missing ~= parent;
            const next = dirName(parent);
            if (next == parent) break;
            parent = next;
        }
        if (missing.length > 0)
        {
            mkdirRecurse(dirName(path));
            foreach (directory; missing)
                if (!createdDirectories.canFind(directory))
                    createdDirectories ~= directory;
        }
    }

    size_t attempted;
    string commitFailure;
    foreach (index, ref change; changes)
    {
        try
        {
            if (!stateMatches(change))
            {
                commitFailure = change.relativePath ~
                    ": file changed while the patch was being prepared";
                break;
            }
        }
        catch (Exception error)
        {
            commitFailure = change.relativePath ~ ": " ~ error.msg;
            break;
        }

        attempted = index + 1;
        try
        {
            if (change.afterExists)
            {
                ensureParent(change.path);
                write(change.path, change.after);
            }
            else
                remove(change.path);
        }
        catch (Exception error)
        {
            commitFailure = change.relativePath ~ ": " ~ error.msg;
            break;
        }
    }

    if (commitFailure.length > 0)
    {
        string[] rollbackFailures;
        for (size_t index = attempted; index > 0; --index)
        {
            auto change = changes[index - 1];
            try
            {
                if (change.beforeExists)
                {
                    if (dirName(change.path).length > 0)
                        mkdirRecurse(dirName(change.path));
                    write(change.path, change.before);
                }
                else if (exists(change.path))
                    remove(change.path);
            }
            catch (Exception error)
                rollbackFailures ~= change.relativePath ~ ": " ~ error.msg;
        }
        // Remove newly-created empty directories. Repeated passes also remove
        // parents shared by multiple added files once their children are gone.
        foreach (_; 0 .. createdDirectories.length)
            foreach (directory; createdDirectories)
                if (isDir(directory)) collectException(rmdir(directory));

        auto rejected = appender!string();
        rejected.put("Patch commit failed: " ~ commitFailure ~ ".");
        if (rollbackFailures.length == 0)
            rejected.put(" All attempted file changes were rolled back.");
        else
        {
            rejected.put(" Rollback also failed:");
            foreach (failure; rollbackFailures)
                rejected.put("\n- " ~ failure);
        }
        return ToolExecution("apply_patch", rejected.data, true);
    }

    auto builder = appender!string();
    builder.put("Applied patch to " ~ to!string(changes.length) ~
        (changes.length == 1 ? " file" : " files") ~ " (+" ~
        to!string(totalAdditions) ~ " -" ~ to!string(totalDeletions) ~ ").");
    ToolExecution result;
    result.name = "apply_patch";
    result.output = builder.data;
    result.additions = totalAdditions;
    result.deletions = totalDeletions;
    result.diff = combinedDiff;
    result.failed = false;
    return result;
}

/// The D-native `update_plan` tool: validate the model's plan and render it as
/// a checked list so the transcript shows the steps and their progress.
private ToolExecution runUpdatePlan(string args, string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    if (value.type != JSONType.object)
        return ToolExecution("update_plan",
            "Error: update_plan requires a `plan` array.", true);
    JSONValue[] plan;
    if (auto field = "plan" in value.object)
        if (field.type == JSONType.array)
            plan = field.array;
    if (plan.length == 0)
        return ToolExecution("update_plan",
            "Error: `plan` must be a non-empty array of steps.", true);

    string[] rendered;
    int inProgress;
    foreach (index, item; plan)
    {
        if (item.type != JSONType.object)
            return ToolExecution("update_plan",
                "Error: each plan item needs `step` and `status`.", true);
        string step;
        string status;
        if (auto field = "step" in item.object)
            if (field.type == JSONType.string)
                step = field.str;
        if (auto field = "status" in item.object)
            if (field.type == JSONType.string)
                status = field.str;
        if (step.length == 0)
            return ToolExecution("update_plan",
                "Error: every plan step needs non-empty `step` text.", true);
        string marker;
        switch (status)
        {
            case "completed": marker = "[x]"; break;
            case "in_progress": marker = "[>]"; ++inProgress; break;
            case "pending": marker = "[ ]"; break;
            default:
                return ToolExecution("update_plan",
                    "Error: invalid status '" ~ status ~
                    "' (use pending, in_progress or completed).", true);
        }
        rendered ~= to!string(index + 1) ~ ". " ~ marker ~ " " ~ step;
    }
    if (inProgress > 1)
        return ToolExecution("update_plan",
            "Error: at most one step may be in_progress.", true);

    string explanation;
    if (auto field = "explanation" in value.object)
        if (field.type == JSONType.string)
            explanation = field.str;
    auto builder = appender!string();
    builder.put("Plan updated");
    if (explanation.length > 0) builder.put(" (" ~ explanation ~ ")");
    builder.put(":");
    foreach (line; rendered)
        builder.put("\n" ~ line);
    ToolExecution result;
    result.name = "update_plan";
    result.output = builder.data;
    return result;
}

/// The D-native `move` tool: rename one file/directory or move a batch into an
/// existing directory. All collisions are rejected before the first rename.
private ToolExecution runMove(string args, string workspace)
{
    const paths = resolveTransferPaths(args, workspace, "move");
    if (paths.error.length > 0)
        return ToolExecution("move", "Error: " ~ paths.error, true);

    string[] movedSources;
    string[] movedTargets;
    try
    {
        foreach (index, source; paths.sources)
        {
            rename(source, paths.targets[index]);
            movedSources ~= source;
            movedTargets ~= paths.targets[index];
        }
    }
    catch (Exception error)
    {
        string[] rollbackFailures;
        for (size_t index = movedSources.length; index > 0; --index)
        {
            const source = movedSources[index - 1];
            const target = movedTargets[index - 1];
            try
            {
                if (exists(target) && !exists(source)) rename(target, source);
            }
            catch (Exception rollbackError)
                rollbackFailures ~= target ~ ": " ~ rollbackError.msg;
        }
        auto message = "Error: move failed: " ~ error.msg;
        if (rollbackFailures.length == 0 && movedSources.length > 0)
            message ~= " Earlier items in the batch were restored.";
        else if (rollbackFailures.length > 0)
        {
            message ~= " Rollback also failed:";
            foreach (failure; rollbackFailures) message ~= "\n- " ~ failure;
        }
        return ToolExecution("move", message, true);
    }

    auto builder = appender!string();
    builder.put("Moved " ~ to!string(paths.sources.length) ~
        (paths.sources.length == 1 ? " item:" : " items:"));
    foreach (index, source; paths.sources)
        builder.put("\n- " ~ source ~ " -> " ~ paths.targets[index]);
    return ToolExecution("move", builder.data, false);
}

private ToolExecution runRename(string args, string workspace)
{
    const paths = resolveRenamePaths(args, workspace);
    if (paths.error.length > 0)
        return ToolExecution("rename", "Error: " ~ paths.error, true);
    try rename(paths.source, paths.target);
    catch (Exception error)
        return ToolExecution("rename", "Error: rename failed: " ~ error.msg,
            true);
    return ToolExecution("rename", "Renamed:\n- " ~ paths.source ~ " -> " ~
        paths.target, false);
}

private ToolExecution runCreateFolder(string args, string workspace)
{
    string validationError;
    const paths = resolveCreateFolderPaths(args, workspace, validationError);
    if (validationError.length > 0)
        return ToolExecution("create_folder", "Error: " ~ validationError,
            true);
    try mkdirRecurse(paths[$ - 1]);
    catch (Exception error)
    {
        string[] cleanupFailures;
        for (size_t index = paths.length; index > 0; --index)
        {
            const path = paths[index - 1];
            try
            {
                if (exists(path) && isDir(path)) rmdir(path);
            }
            catch (Exception cleanupError)
                cleanupFailures ~= path ~ ": " ~ cleanupError.msg;
        }
        auto message = "Error: could not create folder: " ~ error.msg;
        if (cleanupFailures.length > 0)
        {
            message ~= " Cleanup also failed:";
            foreach (failure; cleanupFailures) message ~= "\n- " ~ failure;
        }
        return ToolExecution("create_folder", message, true);
    }
    return ToolExecution("create_folder", "Created folder " ~ paths[$ - 1],
        false);
}

private void copyPathRecursive(string source, string target)
{
    // Following a directory symlink can recurse back into an ancestor, while
    // dereferencing a file symlink silently changes its semantics. Keep copy's
    // behavior explicit until the tool has a preserve-links contract.
    if (isSymlink(source))
        throw new Exception("symbolic links are not supported: " ~ source);
    if (isFile(source))
    {
        fileCopy(source, target);
        return;
    }
    if (!isDir(source))
        throw new Exception("source is not a file or directory: " ~ source);

    mkdirRecurse(target);
    foreach (entry; dirEntries(source, SpanMode.shallow))
    {
        const childTarget = buildPath(target, baseName(entry.name));
        if (entry.isDir)
            copyPathRecursive(entry.name, childTarget);
        else if (entry.isFile)
            fileCopy(entry.name, childTarget);
        else
            throw new Exception("unsupported filesystem entry: " ~ entry.name);
    }
}

/// The D-native `copy` tool. A partially copied item or batch is removed on
/// failure; source paths are never modified.
private ToolExecution runCopy(string args, string workspace)
{
    const paths = resolveTransferPaths(args, workspace, "copy");
    if (paths.error.length > 0)
        return ToolExecution("copy", "Error: " ~ paths.error, true);

    size_t attempted;
    try
    {
        foreach (index, source; paths.sources)
        {
            attempted = index + 1;
            copyPathRecursive(source, paths.targets[index]);
        }
    }
    catch (Exception error)
    {
        string[] cleanupFailures;
        for (size_t index = attempted; index > 0; --index)
        {
            const target = paths.targets[index - 1];
            try
            {
                if (exists(target) && isDir(target)) rmdirRecurse(target);
                else if (exists(target)) remove(target);
            }
            catch (Exception cleanupError)
                cleanupFailures ~= target ~ ": " ~ cleanupError.msg;
        }
        auto message = "Error: copy failed: " ~ error.msg;
        if (cleanupFailures.length == 0 && attempted > 0)
            message ~= " Partial copies were removed; sources are unchanged.";
        else if (cleanupFailures.length > 0)
        {
            message ~= " Cleanup also failed:";
            foreach (failure; cleanupFailures) message ~= "\n- " ~ failure;
        }
        return ToolExecution("copy", message, true);
    }

    auto builder = appender!string();
    builder.put("Copied " ~ to!string(paths.sources.length) ~
        (paths.sources.length == 1 ? " item:" : " items:"));
    foreach (index, source; paths.sources)
        builder.put("\n- " ~ source ~ " -> " ~ paths.targets[index]);
    return ToolExecution("copy", builder.data, false);
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
    string pathArg;
    if (value.type == JSONType.object)
    {
        if (auto field = "pattern" in value.object)
            if (field.type == JSONType.string)
                pattern = field.str;
        if (auto field = "path" in value.object)
            if (field.type == JSONType.string)
                pathArg = field.str;
    }
    if (pattern.length == 0)
        return ToolExecution("glob",
            "Error: glob requires a `pattern` argument.", true);

    const root = pathArg.length > 0
        ? resolveToolPath(pathArg, workspace) : workspace;
    if (pathArg.length > 0 && isWorkspaceAncestor(root, workspace))
        return ToolExecution("glob", "Error: refusing to search a parent of " ~
            "the active workspace. Narrow `path` to the workspace, a " ~
            "subdirectory, or an explicitly named sibling repository.", true);
    if (!exists(root) || !isDir(root))
        return ToolExecution("glob", "Error: search directory not found: " ~
            root, true);
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
        foreach (entry; dirEntries(root, SpanMode.depth))
        {
            string relative = entry.name;
            if (relative.length >= root.length &&
                relative[0 .. root.length] == root)
                relative = relative[root.length .. $];
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

private bool grepIgnoredDirectory(string directory)
{
    const name = toLower(baseName(directory));
    switch (name)
    {
        case ".git", ".hg", ".svn", ".dub", ".cache", ".idea", ".vscode",
            "build", "dist", "out", "target", "node_modules", "coverage",
            "__pycache__":
            return true;
        default:
            return false;
    }
}

private bool grepIgnoredFile(string filePath)
{
    const ext = toLower(extension(filePath));
    switch (ext)
    {
        case ".exe", ".dll", ".pdb", ".obj", ".lib", ".o", ".a", ".so",
            ".dylib", ".bin", ".zip", ".7z", ".rar", ".gz", ".tar",
            ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf",
            ".mp3", ".mp4", ".wav", ".woff", ".woff2", ".ttf", ".otf",
            ".db", ".sqlite", ".class", ".jar", ".pyc":
            return true;
        default:
            return false;
    }
}

private string comparableSearchPath(string path)
{
    auto result = buildNormalizedPath(path).replace("\\", "/");
    while (result.length > 1 && result[$ - 1] == '/')
        result = result[0 .. $ - 1];
    version (Windows) result = result.toLower();
    return result;
}

private ToolExecution runUpdateSubplan(string args, string workspace)
{
    JSONValue root;
    try root = parseJSON(args);
    catch (Exception) root = JSONValue.init;
    if (root.type != JSONType.object)
        return ToolExecution("update_subplan",
            "Error: update_subplan requires parent_step and plan.", true);
    auto parent = "parent_step" in root.object;
    if (parent is null || parent.type != JSONType.integer ||
        parent.integer < 1)
        return ToolExecution("update_subplan",
            "Error: parent_step must be a 1-based step number.", true);
    auto result = runUpdatePlan(args, workspace);
    result.name = "update_subplan";
    if (!result.failed)
        result.output = "Subplan for step " ~ to!string(parent.integer) ~
            ":\n" ~ result.output;
    return result;
}

/// Reject the especially dangerous case where a tool expands a project search
/// to one of its parent directories (for example, from one repository to the
/// directory containing every repository). Explicit sibling repositories and
/// precise files remain supported.
private bool isWorkspaceAncestor(string candidate, string workspace)
{
    const root = comparableSearchPath(candidate);
    const project = comparableSearchPath(workspace);
    return root.length > 0 && project.length > root.length &&
        project[0 .. root.length] == root && project[root.length] == '/';
}

private ToolExecution runGrep(string args, string workspace,
    ToolCancellation cancellation = null)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string pattern;
    string include;
    string pathArg;
    string mode = "content";
    bool literal;
    bool caseSensitive = true;
    size_t contextLines;
    size_t maxResults = 200;
    int timeoutMs = 10_000;
    if (value.type == JSONType.object)
    {
        if (auto field = "pattern" in value.object)
            if (field.type == JSONType.string)
                pattern = field.str;
        if (auto field = "include" in value.object)
            if (field.type == JSONType.string)
                include = field.str;
        if (auto field = "path" in value.object)
            if (field.type == JSONType.string)
                pathArg = field.str;
        if (auto field = "mode" in value.object)
            if (field.type == JSONType.string)
                mode = toLower(field.str);
        if (auto field = "literal" in value.object)
            literal = field.type == JSONType.true_;
        if (auto field = "caseSensitive" in value.object)
        {
            if (field.type == JSONType.true_) caseSensitive = true;
            else if (field.type == JSONType.false_) caseSensitive = false;
        }
        if (auto field = "context" in value.object)
            if (field.type == JSONType.integer)
            {
                auto requested = field.integer;
                if (requested < 0) requested = 0;
                if (requested > 20) requested = 20;
                contextLines = cast(size_t) requested;
            }
        if (auto field = "limit" in value.object)
            if (field.type == JSONType.integer)
            {
                auto requested = field.integer;
                if (requested < 1) requested = 1;
                if (requested > 1_000) requested = 1_000;
                maxResults = cast(size_t) requested;
            }
        if (auto field = "timeout" in value.object)
            if (field.type == JSONType.integer)
            {
                timeoutMs = cast(int) field.integer;
                if (timeoutMs < 1) timeoutMs = 1;
                if (timeoutMs > 600_000) timeoutMs = 600_000;
            }
    }
    if (pattern.length == 0)
        return ToolExecution("grep",
            "Error: grep requires a `pattern` argument.", true);
    if (mode != "content" && mode != "files" && mode != "count")
        return ToolExecution("grep",
            "Error: grep `mode` must be content, files, or count.", true);

    const root = pathArg.length > 0
        ? resolveToolPath(pathArg, workspace) : workspace;
    if (pathArg.length > 0 && isWorkspaceAncestor(root, workspace))
        return ToolExecution("grep", "Error: refusing to search a parent of " ~
            "the active workspace. Narrow `path` to the workspace, a " ~
            "subdirectory, a specific file, or an explicitly named sibling " ~
            "repository.", true);
    if (!exists(root) || (!isDir(root) && !isFile(root)))
        return ToolExecution("grep", "Error: search path not found: " ~ root,
            true);

    Regex!(char) re;
    if (!literal)
    {
        try re = regex(pattern, caseSensitive ? "" : "i");
        catch (Exception error)
            return ToolExecution("grep", "Error: invalid pattern: " ~ error.msg,
                true);
    }
    const comparablePattern = caseSensitive ? pattern : toLower(pattern);

    bool lineMatches(string line)
    {
        if (!literal) return !matchFirst(line, re).empty;
        const candidate = caseSensitive ? line : toLower(line);
        return candidate.indexOf(comparablePattern) >= 0;
    }

    // Return matching lines (`path:line: text`) rather than just file paths, so
    // the model does not have to re-read every hit to see the surrounding code.
    // Files are streamed line-by-line, so a huge file never has to be loaded
    // whole just to find the first match. A match that spans multiple lines is
    // not reported (grep is line-based, matching ripgrep's default behaviour).
    enum size_t maxLineChars = 300;
    enum ulong maxRecursiveFileBytes = 8UL * 1024 * 1024;
    string[] hits;
    size_t totalMatches;
    size_t matchedFiles;
    bool capped;
    bool stopped;
    bool timedOut;
    size_t scannedDirectories;
    size_t scannedFiles;
    size_t scannedLines;
    const deadline = MonoTime.currTime + timeoutMs.msecs;
    bool scanFile(string filePath, bool explicitFile = false)
    {
        if (MonoTime.currTime >= deadline)
        {
            timedOut = true;
            return true;
        }
        if (cancellation !is null && cancellation.cancelled())
        {
            stopped = true;
            return true;
        }
        if (include.length > 0 &&
            !fileMatchesInclude(baseName(filePath), include)) return false;
        if (!explicitFile)
        {
            if (grepIgnoredFile(filePath)) return false;
            try
            {
                if (getSize(filePath) > maxRecursiveFileBytes) return false;
            }
            catch (Exception) return false;
        }
        File file;
        try file = File(filePath, "r");
        catch (Exception) return false;
        ++scannedFiles;
        scope (exit) collectException(file.close());
        size_t lineNo;
        size_t fileMatches;
        struct ContextLine
        {
            size_t number;
            string text;
        }
        ContextLine[] before;
        size_t afterRemaining;
        size_t lastEmittedLine;

        void emitLine(size_t number, string display, bool matched)
        {
            if (lastEmittedLine > 0 && number > lastEmittedLine + 1)
                hits ~= "--";
            hits ~= filePath ~ (matched ? ":" : "-") ~ to!string(number) ~
                (matched ? ": " : "- ") ~ display;
            lastEmittedLine = number;
        }
        try
        {
            foreach (line; file.byLine())
            {
                ++lineNo;
                ++scannedLines;
                if ((lineNo & 255) == 0 && MonoTime.currTime >= deadline)
                {
                    timedOut = true;
                    return true;
                }
                if ((lineNo & 255) == 0 && cancellation !is null &&
                    cancellation.cancelled())
                {
                    stopped = true;
                    return true;
                }
                const matched = lineMatches(
                    decodeBytesLenient(cast(const(ubyte)[]) line));
                string display =
                    decodeBytesLenient(cast(const(ubyte)[]) line);
                if (display.length > maxLineChars)
                    display = display[0 .. utf8SafeCut(
                        cast(const(ubyte)[]) display[0 .. maxLineChars])] ~ "…";
                while (display.length > 0 &&
                    (display[$ - 1] == '\n' || display[$ - 1] == '\r'))
                    display = display[0 .. $ - 1];
                if (!matched)
                {
                    if (mode == "content")
                    {
                        if (afterRemaining > 0)
                        {
                            emitLine(lineNo, display, false);
                            --afterRemaining;
                        }
                        else if (contextLines > 0)
                        {
                            before ~= ContextLine(lineNo, display);
                            if (before.length > contextLines)
                                before = before[$ - contextLines .. $];
                        }
                    }
                    continue;
                }

                ++fileMatches;
                ++totalMatches;
                if (mode == "files")
                {
                    ++matchedFiles;
                    hits ~= filePath;
                    if (matchedFiles >= maxResults)
                    {
                        capped = true;
                        return true;
                    }
                    return false;
                }
                if (mode == "content")
                {
                    if (fileMatches == 1) ++matchedFiles;
                    foreach (context; before)
                        if (context.number > lastEmittedLine)
                            emitLine(context.number, context.text, false);
                    before.length = 0;
                    emitLine(lineNo, display, true);
                    afterRemaining = contextLines;
                    if (totalMatches >= maxResults)
                    {
                        capped = true;
                        return true;
                    }
                }
            }
        }
        catch (Exception) {}
        if (mode == "count" && fileMatches > 0)
        {
            ++matchedFiles;
            hits ~= filePath ~ ": " ~ to!string(fileMatches) ~
                (fileMatches == 1 ? " matching line" : " matching lines");
            if (matchedFiles >= maxResults)
            {
                capped = true;
                return true;
            }
        }
        return false;
    }

    // Models frequently pass the known target file as `path`. Treat that as a
    // precise one-file search instead of failing and provoking another tool
    // round just to remove the filename from the argument.
    if (isFile(root))
        scanFile(root, true);
    else
    {
        bool scanDirectory(string directory)
        {
            ++scannedDirectories;
            if (MonoTime.currTime >= deadline)
            {
                timedOut = true;
                return true;
            }
            if (cancellation !is null && cancellation.cancelled())
            {
                stopped = true;
                return true;
            }
            try
            {
                foreach (entry; dirEntries(directory, SpanMode.shallow))
                {
                    if (MonoTime.currTime >= deadline)
                    {
                        timedOut = true;
                        return true;
                    }
                    if (cancellation !is null && cancellation.cancelled())
                    {
                        stopped = true;
                        return true;
                    }
                    if (entry.isDir)
                    {
                        if (!grepIgnoredDirectory(entry.name) &&
                            scanDirectory(entry.name)) return true;
                    }
                    else if (entry.isFile && scanFile(entry.name))
                        return true;
                }
            }
            catch (Exception) {}
            return false;
        }
        scanDirectory(root);
    }
    if (timedOut)
    {
        auto report = appender!string();
        report.put("Paused: grep reached its " ~ to!string(timeoutMs) ~
            " ms soft deadline after scanning " ~
            to!string(scannedDirectories) ~ " directories, " ~
            to!string(scannedFiles) ~ " files, and " ~
            to!string(scannedLines) ~ " lines; found " ~
            to!string(totalMatches) ~ " matches so far. Review this progress " ~
            "and decide whether waiting longer is reasonable. Rerun the same " ~
            "focused search with a larger `timeout` (up to 600000 ms), or " ~
            "narrow `path`, `pattern`, or `include`.\n");
        foreach (hit; hits) report.put(hit ~ "\n");
        return ToolExecution("grep", truncateOutput(report.data), true);
    }
    if (stopped)
        return ToolExecution("grep", "Stopped: grep cancelled.", true);
    if (totalMatches == 0)
        return ToolExecution("grep", "No matches for: " ~ pattern, false);
    auto builder = appender!string();
    foreach (hit; hits)
        builder.put(hit ~ "\n");
    if (mode == "count")
        builder.put("Total: " ~ to!string(totalMatches) ~ " matching " ~
            (totalMatches == 1 ? "line" : "lines") ~ " in " ~
            to!string(matchedFiles) ~
            (matchedFiles == 1 ? " file.\n" : " files.\n"));
    if (capped)
        builder.put("(Results capped at " ~ to!string(maxResults) ~
            (mode == "content" ? " matching lines" : " matching files") ~
            " — raise `limit` or narrow the search.)\n");
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

/// Execute a single tool call against the workspace directory and record how
/// long it took. The result is a plain-text string ready to be fed back to the
/// model as a `tool` message. A view_image result additionally carries pixels
/// out-of-band so the UI can attach them after the batch's tool messages.
public ToolExecution executeTool(const OpenCodeToolCall call,
    string workspace, ToolCancellation cancellation = null,
    ChangeContext changeContext = ChangeContext.init)
{
    const started = MonoTime.currTime;
    ToolExecution result;
    if (call.name == "write" || call.name == "edit" ||
        call.name == "apply_patch" || call.name == "copy" ||
        call.name == "move" || call.name == "rename" ||
        call.name == "create_folder" || call.name == "remove")
    {
        // Multiple conversations may work in one project. Serialize workspace
        // mutations so two tool workers can never write/delete concurrently;
        // context-checked edit/patch calls then detect stale anchors cleanly.
        auto mutationLock = workspaceMutationLock(workspace);
        mutationLock.lock();
        scope (exit) mutationLock.unlock();
        string[] journalTargets;
        FileSnapshot[] before;
        if (changeContext.conversationId.length > 0)
        {
            try
            {
                journalTargets = mutationTargetPaths(call, workspace);
                before = snapshotTargets(journalTargets);
            }
            catch (Exception error)
                return ToolExecution(call.name,
                    "Error: could not create the safety snapshot: " ~
                    error.msg, true);
        }
        result = dispatchTool(call, workspace, cancellation);
        if (changeContext.conversationId.length > 0)
        {
            try
            {
                const after = snapshotTargets(journalTargets);
                const transactionId = call.id.length > 0 ? call.id :
                    to!string(Clock.currTime.stdTime);
                recordMutation(call, workspace, changeContext, before, after,
                    transactionId);
            }
            catch (Exception error)
                result.output ~= "\nWarning: the change was made, but its " ~
                    "safety snapshot could not be saved: " ~ error.msg;
        }
    }
    else
        result = dispatchTool(call, workspace, cancellation);
    // Microsecond precision then round to ms. An in-process edit can finish in
    // well under a millisecond; clamping to 1 keeps the label visible and
    // honest ("<1ms" would just be noise) instead of dropping it as 0.
    const usecs = cast(long) (MonoTime.currTime - started).total!"usecs";
    result.elapsedMs = usecs <= 1000 ? 1 : (usecs + 500) / 1000;
    return result;
}

private bool currentMatchesAfter(const ref ChangeRecord record)
{
    const present = exists(record.path);
    if (present != record.afterExists) return false;
    if (!present) return true;
    if (isDir(record.path) != record.afterDirectory) return false;
    if (record.afterDirectory) return true;
    if (!isFile(record.path)) return false;
    if (record.afterBlob.length == 0 || !exists(record.afterBlob)) return false;
    return cast(ubyte[]) read(record.path) ==
        cast(ubyte[]) read(record.afterBlob);
}

/// Revert one journal row or every row from the same mutation transaction.
/// The current bytes must exactly match the recorded after-image, so later user
/// edits or another conversation's work can never be overwritten silently.
public ChangeRevertResult revertChangeRecord(string workspace, string recordId,
    bool wholeTransaction, ChangeContext context, bool wholeTurn = false)
{
    ChangeRevertResult result;
    auto mutationLock = workspaceMutationLock(workspace);
    mutationLock.lock();
    scope (exit) mutationLock.unlock();
    try
    {
        auto all = listChangeRecords(workspace);
        ChangeRecord* selected;
        foreach (ref record; all)
            if (record.id == recordId)
            {
                selected = &record;
                break;
            }
        if (selected is null)
        {
            result.message = "Change record was not found.";
            return result;
        }
        ChangeRecord[] targets;
        if (wholeTurn)
        {
            ChangeRecord[string] combined;
            string[] orderedPaths;
            foreach (record; all)
                if (record.conversationId == selected.conversationId &&
                    record.turnId == selected.turnId)
                {
                    if (record.path !in combined)
                    {
                        combined[record.path] = record;
                        combined[record.path].revertOf = record.id;
                        orderedPaths ~= record.path;
                    }
                    else
                    {
                        auto aggregate = &combined[record.path];
                        aggregate.afterExists = record.afterExists;
                        aggregate.afterDirectory = record.afterDirectory;
                        aggregate.afterHash = record.afterHash;
                        aggregate.afterBlob = record.afterBlob;
                        aggregate.revertOf ~= "|" ~ record.id;
                    }
                }
            foreach (path; orderedPaths) targets ~= combined[path];
        }
        else if (wholeTransaction)
        {
            foreach (record; all)
                if (record.transactionId == selected.transactionId)
                    targets ~= record;
        }
        else
            targets = [*selected];
        foreach (record; targets)
            if (!currentMatchesAfter(record))
            {
                result.conflict = true;
                result.message = "Cannot revert because the path changed " ~
                    "after Aurora recorded it: " ~ record.path;
                return result;
            }

        FileSnapshot[] before;
        string[] paths;
        string[] revertIds;
        ChangeRecord[] directoriesToCreate;
        ChangeRecord[] filesToRestore;
        ChangeRecord[] filesToRemove;
        ChangeRecord[] directoriesToRemove;
        foreach (record; targets)
        {
            before ~= snapshotFile(record.path);
            paths ~= record.path;
            revertIds ~= record.revertOf.length > 0 ? record.revertOf :
                record.id;
            if (record.beforeExists)
            {
                if (record.beforeDirectory)
                    directoriesToCreate ~= record;
                else
                    filesToRestore ~= record;
            }
            else if (record.afterDirectory)
                directoriesToRemove ~= record;
            else
                filesToRemove ~= record;
        }
        sort!((a, b) => a.path.length < b.path.length)(directoriesToCreate);
        foreach (record; directoriesToCreate)
            if (!exists(record.path)) mkdirRecurse(record.path);
        foreach (record; filesToRestore)
        {
            if (record.beforeBlob.length == 0 || !exists(record.beforeBlob))
                throw new Exception("missing before snapshot for " ~ record.path);
            const parent = dirName(record.path);
            if (parent.length > 0) mkdirRecurse(parent);
            write(record.path, read(record.beforeBlob));
        }
        foreach (record; filesToRemove)
            if (exists(record.path) && isFile(record.path)) remove(record.path);
        sort!((a, b) => a.path.length > b.path.length)(directoriesToRemove);
        foreach (record; directoriesToRemove)
            if (exists(record.path) && isDir(record.path)) rmdir(record.path);
        const after = snapshotTargets(paths);
        OpenCodeToolCall revertCall;
        revertCall.id = "revert-" ~ recordId ~ "-" ~
            to!string(Clock.currTime.stdTime);
        revertCall.name = "revert";
        const transactionId = revertCall.id;
        recordMutation(revertCall, workspace, context, before, after,
            transactionId, revertIds);
        result.succeeded = true;
        result.files = cast(int) targets.length;
        result.message = "Reverted " ~ to!string(targets.length) ~
            (targets.length == 1 ? " path." : " paths.");
    }
    catch (Exception error)
        result.message = "Revert failed: " ~ error.msg;
    return result;
}

public string changeRecordDiff(const ref ChangeRecord record)
{
    try
    {
        if (record.beforeDirectory || record.afterDirectory)
        {
            if (!record.beforeExists && record.afterDirectory)
                return "Folder created: " ~ record.path;
            if (record.beforeDirectory && !record.afterExists)
                return "Folder deleted: " ~ record.path;
            return "Folder changed: " ~ record.path;
        }
        ubyte[] before;
        ubyte[] after;
        if (record.beforeExists && exists(record.beforeBlob))
            before = cast(ubyte[]) read(record.beforeBlob);
        if (record.afterExists && exists(record.afterBlob))
            after = cast(ubyte[]) read(record.afterBlob);
        if (!snapshotIsText(before) || !snapshotIsText(after))
            return "Binary snapshot\n\nBefore: " ~ record.beforeHash ~
                "\nAfter:  " ~ record.afterHash ~
                "\n\nExact bytes are preserved and can be reverted, but a " ~
                "text diff is not available.";
        const diff = computeTextDiff(cast(string) before, cast(string) after);
        return "--- before\n+++ after\n" ~ diff.unified;
    }
    catch (Exception error)
        return "Could not load snapshot diff: " ~ error.msg;
}

/// The host application installs this to run its rebuild-and-relaunch flow.
/// The tool worker thread calls it, so it must only record the request; the
/// application performs the rebuild (which persists state and closes the
/// window) on its own UI thread. Returns false when a rebuild cannot be
/// started: none registered, one already pending, or the running app cannot
/// locate its own package to build.
///
/// `__gshared` is required: the app installs the handler on the UI thread but
/// the tool runs on a worker thread, and a plain module-level variable is
/// thread-local in D, so the worker would otherwise read its own null copy.
public __gshared bool delegate(string reason) rebuildRequestHandler;

/// Bridge the model's `rebuild` request to the host application. The tool
/// performs no build itself: `dub` cannot replace the running image, so only
/// the app can drive the detached-helper flow. Returns a clear result either
/// way so the model is never left believing a rebuild happened when it did not.
private ToolExecution runRebuildTool(string arguments)
{
    if (rebuildRequestHandler is null)
        return ToolExecution("rebuild",
            "Error: the rebuild tool is only available inside the Aurora " ~
            "OpenCode application, where a rebuild handler is registered.", true);
    string reason;
    try
    {
        auto root = parseJSON(arguments);
        if (root.type == JSONType.object)
            if (auto field = "reason" in root.object)
                if (field.type == JSONType.string) reason = field.str;
    }
    catch (Exception) {}
    if (!rebuildRequestHandler(reason))
        return ToolExecution("rebuild",
            "Rebuild was not started: a rebuild is already pending, or the " ~
            "running app is not built from its own source package.", true);
    return ToolExecution("rebuild",
        "Rebuild and relaunch started. The app will persist this " ~
        "conversation, close, run `dub build`, relaunch, and continue here. " ~
        "If the build fails to compile, the app relaunches the previous " ~
        "binary and reports the compiler errors in the resumed conversation " ~
        "so you can fix them and call the rebuild tool again.");
}

/// Dispatch a tool call. Split out of `executeTool` so the timing wrapper has a
/// single return point and every exit (including the unknown-tool error) is
/// measured.
private ToolExecution dispatchTool(const OpenCodeToolCall call,
    string workspace, ToolCancellation cancellation = null)
{
    switch (call.name)
    {
        case "bash":
            return runBash(call.arguments, workspace, cancellation);
        case "run":
            return runProgramTool(call.arguments, workspace, cancellation);
        case "process":
            return runProcessTool(call.arguments);
        case "dshell":
            return runDshell(call.arguments, workspace);
        case "open":
            return runOpenTool(call.arguments, workspace);
        case "read":
            return runRead(call.arguments, workspace);
        case "view_image":
            return runViewImage(call.arguments, workspace);
        case "write":
            return runWrite(call.arguments, workspace);
        case "edit":
            return runEdit(call.arguments, workspace);
        case "apply_patch":
            return runApplyPatch(call.arguments, workspace);
        case "update_plan":
            return runUpdatePlan(call.arguments, workspace);
        case "update_subplan":
            return runUpdateSubplan(call.arguments, workspace);
        case "copy":
            return runCopy(call.arguments, workspace);
        case "move":
            return runMove(call.arguments, workspace);
        case "rename":
            return runRename(call.arguments, workspace);
        case "create_folder":
            return runCreateFolder(call.arguments, workspace);
        case "remove":
            return runRemove(call.arguments, workspace);
        case "glob":
            return runGlob(call.arguments, workspace);
        case "grep":
            return runGrep(call.arguments, workspace, cancellation);
        case "webfetch":
            return runWebFetch(call.arguments, workspace, cancellation);
        // experimental: websearch - delete with source/auroraopencode/websearch.d
        case "websearch":
        {
            auto search = experimentalWebSearchExecute(call.arguments,
                workspace);
            return ToolExecution("websearch", search[0], search[1]);
        }
        case "rebuild":
            return runRebuildTool(call.arguments);
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

/// The unified diff a file-mutating tool's arguments already imply, for a row
/// whose tool has not reported a diff yet (an in-flight call, or a restored
/// message that lost its stored diff). `edit` diffs `oldString` against
/// `newString`; `write` renders the partial `content` as pure additions. Empty
/// for tools that do not edit, or when there is nothing to show yet.
public string previewToolDiffText(string toolName, string argsJson)
{
    if (toolName == "edit")
    {
        const oldText = partialStringArg(argsJson, "oldString");
        const newText = partialStringArg(argsJson, "newString");
        if (oldText.length == 0 && newText.length == 0) return "";
        return computeTextDiff(oldText, newText).unified;
    }
    if (toolName == "write")
    {
        import std.string : splitLines;

        const content = partialStringArg(argsJson, "content");
        if (content.length == 0) return "";
        auto builder = appender!string();
        foreach (line; content.splitLines())
        {
            builder.put("+");
            builder.put(line);
            builder.put("\n");
        }
        return builder.data;
    }
    return "";
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
    bool recursive;
    string pattern;
    if (value.type == JSONType.object)
    {
        if (auto field = "command" in value.object)
            if (field.type == JSONType.string)
                command = field.str;
        if (auto field = "path" in value.object)
            if (field.type == JSONType.string)
                path = field.str;
        if (auto field = "recursive" in value.object)
            if (field.type == JSONType.true_)
                recursive = true;
        if (auto field = "pattern" in value.object)
            if (field.type == JSONType.string)
                pattern = field.str;
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
            return dshellList(resolved, workspace, recursive, pattern);
        case "info":
        case "stat":
            return dshellStat(resolved, workspace);
        default:
            return ToolExecution("dshell",
                "Error: unknown dshell command '" ~ command ~
                "' (expected where, list, or info).", true);
    }
}

private struct DshellListEntry
{
    string name;
    string kind;
    string size;
}

private ToolExecution dshellList(string path, string workspace,
    bool recursive, string pattern)
{
    if (!exists(path) || !isDir(path))
        return ToolExecution("dshell",
            "Error: not a directory: " ~ path, true);
    Regex!(char) patternRegex;
    if (pattern.length > 0)
    {
        try patternRegex = globToRegex(pattern.replace("\\", "/"));
        catch (Exception error)
            return ToolExecution("dshell", "Error: invalid list pattern: " ~
                error.msg, true);
    }
    DshellListEntry[] entries;
    bool capped;
    try
    {
        const mode = recursive ? SpanMode.depth : SpanMode.shallow;
        foreach (entry; dirEntries(path, mode))
        {
            string relative = entry.name;
            if (relative.length >= path.length &&
                relative[0 .. path.length] == path)
                relative = relative[path.length .. $];
            while (relative.length > 0 && (relative[0] == '\\' ||
                relative[0] == '/'))
                relative = relative[1 .. $];
            relative = relative.replace("\\", "/");
            if (pattern.length > 0 && matchFirst(relative, patternRegex).empty)
                continue;

            DshellListEntry listed;
            listed.name = entry.name;
            listed.kind = entry.isDir ? "dir" : "file";
            if (entry.isDir)
                listed.size = "-";
            else
            {
                try listed.size = to!string(entry.size);
                catch (Exception) listed.size = "?";
            }
            entries ~= listed;
            if (entries.length >= 500)
            {
                capped = true;
                break;
            }
        }
    }
    catch (Exception error)
        return ToolExecution("dshell", "Error: could not list directory: " ~
            error.msg, true);
    entries.sort!((a, b) => a.name < b.name);
    auto builder = appender!string();
    builder.put("<path>" ~ path ~ "</path>\n");
    builder.put("<entries>\n");
    foreach (entry; entries)
        builder.put((entry.kind == "dir" ? "[d] " : "[f] ") ~
            entry.name ~ "  (" ~ entry.size ~ " bytes)\n");
    if (capped)
        builder.put("(Results capped at 500 entries; narrow path or pattern.)\n");
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
