module auroraopencode.tools;

import auroraopencode.core : OpenCodeToolCall, OpenCodeToolDef,
    ensureStateDirectory, opencodeStateDirectory;
import std.file : dirEntries, exists, isFile, isDir, SpanMode, read, readText,
    write, mkdirRecurse, remove, rmdirRecurse, tempDir, getSize,
    timeLastModified;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildNormalizedPath, buildPath, expandTilde,
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
import std.string : indexOf, replace, strip, toLower;
import std.utf : toUTF8, toUTF16z, validate;
import std.conv : to;
import std.exception : collectException;
import core.time : seconds, Duration, MonoTime, msecs;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.datetime : Clock;
import std.algorithm : canFind, sort, map, filter;
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
        "of `pending`, `in_progress` or `completed`. Use it for multi-step " ~
        "work; at most one step may be in_progress at a time.",
        `{"type":"object","properties":{"explanation":{"type":"string","description":"Optional explanation for this plan update"},"plan":{"type":"array","items":{"type":"object","properties":{"step":{"type":"string","description":"Task step text"},"status":{"type":"string","enum":["pending","in_progress","completed"],"description":"Step status"}},"required":["step","status"]},"description":"The list of steps"}},"required":["plan"]}`
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
            "dedicated tools do not fit. Set background=true for work that may " ~
            "run long, then inspect it with the process tool. " ~
            shellUsageNotes(shell),
            `{"type":"object","properties":{"command":{"type":"string","description":"The command to execute"},"shell":{"type":"string","enum":["auto","bash","cmd","powershell","pwsh"],"description":"The shell to run the command in. Defaults to the platform shell."},"workdir":{"type":"string","description":"Working directory, relative to the workspace or absolute. Use this instead of cd."},"timeout":{"type":"integer","description":"Timeout in milliseconds (default 3600000)"},"background":{"type":"boolean","description":"Return immediately with a processId and supervise the command in the background"}},"required":["command"]}`
        ),
        processToolDefinition(),
        dshellToolDefinition(),
        openToolDefinition(),
        removeToolDefinition(),
        editToolDefinition(),
        applyPatchToolDefinition(),
        updatePlanToolDefinition(),
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
            "grep",
            "Search file contents under a directory with a regular expression. " ~
            "Defaults to the workspace; set `path` when the user's target is " ~
            "another directory. " ~
            "Returns matching lines as `path:line: text` (first 200 matches).",
            `{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression to search for"},"include":{"type":"string","description":"Optional file extension filter, e.g. *.d"},"path":{"type":"string","description":"Directory to search, relative to the workspace or absolute; defaults to the workspace"},"timeout":{"type":"integer","minimum":1,"maximum":600000,"description":"Soft deadline in milliseconds (default 10000). If progress justifies waiting, rerun with a longer value."}},"required":["pattern"]}`
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
            "each argument separately (no shell quoting or redirection). For " ~
            "DMD, compiler options precede `-run`; everything after the source " ~
            "file is a runtime argument (example: `-Isource -i -run " ~
            "source/app.d`). Set background=true for work that may run long, " ~
            "then inspect status and output with the process tool.",
            `{"type":"object","properties":{"program":{"type":"string","description":"The executable to run (e.g. dmd, git, python)"},"args":{"type":"array","items":{"type":"string"},"description":"Arguments passed verbatim to the program"},"workdir":{"type":"string","description":"Working directory, relative to the workspace or absolute"},"timeout":{"type":"integer","description":"Timeout in milliseconds (default 3600000)"},"background":{"type":"boolean","description":"Return immediately with a processId and supervise the program in the background"}},"required":["program"]}`
        ),
        processToolDefinition(),
        dshellToolDefinition(),
        openToolDefinition(),
        removeToolDefinition(),
        editToolDefinition(),
        applyPatchToolDefinition(),
        updatePlanToolDefinition(),
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
            "grep",
            "Search file contents under a directory with a regular expression. " ~
            "Defaults to the workspace; set `path` when the user's target is " ~
            "another directory. " ~
            "Returns matching lines as `path:line: text` (first 200 matches).",
            `{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression to search for"},"include":{"type":"string","description":"Optional file extension filter, e.g. *.d"},"path":{"type":"string","description":"Directory to search, relative to the workspace or absolute; defaults to the workspace"},"timeout":{"type":"integer","minimum":1,"maximum":600000,"description":"Soft deadline in milliseconds (default 10000). If progress justifies waiting, rerun with a longer value."}},"required":["pattern"]}`
        ),
    ];
}

/// Stable, outcome-first instructions for the coding agent. Tool-specific
/// syntax lives in each tool definition; keeping it out of this prompt avoids
/// duplicate instructions and leaves the stable prefix eligible for caching.
public string buildSystemPrompt(bool nativeOnly, string workspace,
    string platformName)
{
    import std.datetime : Clock;
    import std.file : exists;
    import std.path : buildPath;

    const today = Clock.currTime.toLocalTime.toISOExtString();
    const isGitRepo = exists(buildPath(workspace, ".git"));

    auto builder = appender!string();
    builder.put("You are Aurora OpenCode, an interactive coding agent running " ~
        "on the user's computer. Infer the intended outcome from the request " ~
        "and prior conversation, use reasonable assumptions for routine gaps, " ~
        "and carry authorized work to completion. A request such as \"can " ~
        "you fix this\" authorizes normal reversible implementation steps; " ~
        "do not merely acknowledge it, propose a plan, or offer to continue.\n");

    builder.put("\n# Operating contract\n");
    builder.put("- Bias toward action. Continue until the requested outcome is " ~
        "complete or a concrete blocker needs information only the user can " ~
        "provide. Ask a narrow question only when the answer would materially " ~
        "change the result or risk an irreversible action.\n");
    builder.put("- Before tool calls for a multi-step task, send one short " ~
        "user-visible sentence stating the outcome and first action. Send a " ~
        "new update only when the phase changes, a useful result is found, or " ~
        "a blocker appears.\n");
    builder.put("- Keep the user's whole request and any durable task state as " ~
        "the completion contract. Do not finish with pending checklist items, " ~
        "an unverified required change, or an unresolved tool error.\n");
    builder.put("- Use the minimum evidence sufficient for the next action. " ~
        "Every read or search must resolve a named unknown. Batch independent " ~
        "lookups, never reread known content, and do not search again merely " ~
        "for confidence or better phrasing.\n");
    builder.put("- Read-only exploration is finite. Once you know the target " ~
        "file, relevant code, and intended behavior, edit immediately. Reach " ~
        "the first mutation normally within six read/search calls. At the " ~
        "ten-call checkpoint, act unless one named unknown still prevents a " ~
        "safe edit; resolve only that unknown. Changing search terms is " ~
        "not progress. Reading files through `run`, Python, a shell, git, or " ~
        "another executable still counts as exploration and must never be " ~
        "used to evade an exploration checkpoint.\n");

    builder.put("\n# Execution loop\n");
    builder.put("1. Translate the request into a concrete result and success " ~
        "criteria. For multi-step work, record 2-7 outcome-oriented steps with " ~
        "`update_plan`; keep exactly one in progress and update it when a step " ~
        "finishes. If durable task state already contains a checklist, keep it " ~
        "current instead of replacing or ignoring it.\n");
    builder.put("2. Gather only the context needed for the first safe edit. " ~
        "Treat an explicit user path as the target even when it is outside the " ~
        "working directory. Read a file before changing it.\n");
    builder.put("3. Make the smallest complete change. Include all currently " ~
        "known related edits in one patch or mutation batch instead of saving " ~
        "known work for later rounds.\n");
    builder.put("4. Run focused verification proportional to the change. Once " ~
        "the relevant checks pass, broaden or repeat them only when a failure, " ~
        "new edit, or unresolved concern justifies it.\n");
    builder.put("Verification is a terminal phase: use at most three focused " ~
        "check attempts after an edit. After one relevant check passes, stop " ~
        "reading and answer; do not inspect the implementation again merely " ~
        "to reconfirm your explanation.\n");
    builder.put("For GUI, layout, or interaction changes, compilation alone is " ~
        "not verification: add or run a focused UI assertion, inspect rendered " ~
        "output, or clearly state that visual behavior remains unverified.\n");
    builder.put("5. Stop and report the outcome, changed locations, verification " ~
        "performed, and any real remaining blocker. Do not keep exploring after " ~
        "success criteria are met.\n");

    builder.put("\n# Editing and safety\n");
    builder.put("- Prefer `apply_patch` for related multi-file or multi-hunk " ~
        "edits, `edit` for one surgical replacement, and `write` for new files " ~
        "or complete rewrites. Add comments only when code is not self-explanatory.\n");
    builder.put("- Make every workspace file change through `apply_patch`, " ~
        "`edit`, `write`, or `remove` so Aurora can snapshot and safely revert " ~
        "it. Do not use `run`, `bash`, or an external script to mutate files; " ~
        "those programs operate outside the change journal.\n");
    builder.put("- A mutation must advance the requested artifact. Never add a " ~
        "comment, whitespace, or other unrelated change merely to unlock more " ~
        "exploration.\n");
    builder.put("- The worktree may be dirty. Preserve changes you did not " ~
        "make and work around unrelated edits. Ask only when they directly " ~
        "conflict with the requested change. Do not amend commits unless asked.\n");
    builder.put("- Other conversations may be active in the same workspace. " ~
        "Re-read the exact edit anchor immediately before mutating it, prefer " ~
        "context-checked `edit`/`apply_patch` over whole-file rewrites, and " ~
        "never overwrite a file from a stale earlier read.\n");
    builder.put("- Never run destructive commands such as `git reset --hard` " ~
        "or `git checkout --` unless the user explicitly requests them.\n");
    builder.put("- This application can edit its own source, so a rebuild or " ~
        "process kill may replace the process running this session. Never kill " ~
        "Aurora or run a build target that overwrites the live Aurora executable. " ~
        "Source tests and checks that use separate outputs are allowed; report " ~
        "when an external rebuild remains.\n");

    builder.put("\n# Tool policy\n");
    if (nativeOnly)
        builder.put("There is no shell and no bash/cmd/powershell. Use native " ~
            "`read`, `write`, `edit`, `apply_patch`, `remove`, `open`, `glob`, `grep`, " ~
            "and `dshell` file tools, plus `run` with an explicit program and " ~
            "argument list. Do not reconstruct shell commands.\n");
    else
        builder.put("Use native tools for file discovery, reads, searches, " ~
            "edits, writes, and removals. Use `bash` only for git, builds, " ~
            "tests, package managers, or executables the native tools cannot " ~
            "perform; do not use shell listing or content commands.\n");
    builder.put("Use `dshell list` for file discovery and `grep` for content " ~
        "search. Do not pair a successful discovery with a broader duplicate. " ~
        "Tool schemas contain exact syntax and parameter requirements.\n");
    builder.put("Use the native `open` tool to open files, folders, or web " ~
        "pages. Never reconstruct platform launch commands such as Windows " ~
        "`start` or PowerShell `Start-Process`.\n");
    builder.put("Use background execution for a command that may run longer " ~
        "than an ordinary interactive check. Inspect its elapsed time, status, " ~
        "and partial output with `process`; decide from observed progress " ~
        "whether waiting longer is reasonable. Never relaunch it merely " ~
        "because it is still running. A grep soft-deadline report requires the " ~
        "same decision: extend `timeout` only when its scope and progress " ~
        "justify the wait.\n");

    builder.put("\n# Special requests\n");
    builder.put("- For a code review, lead with concrete bugs, regressions, " ~
        "risks, and missing tests ordered by severity with file and line " ~
        "references. If there are no findings, say so and name residual risks.\n");
    builder.put("- For frontend design, choose an intentional visual direction, " ~
        "responsive layout, purposeful typography, coherent color tokens, and " ~
        "a few meaningful motions. Preserve an existing design system when one " ~
        "exists.\n");

    builder.put("\n# Communication\n");
    builder.put("- Be concise, direct, and collaborative. State the main point " ~
        "first, use plain language, and match the user's level and tone. Use " ~
        "lists only when they improve scanning and emojis only when asked.\n");
    builder.put("- For substantial work, lead with the completed outcome, then " ~
        "give the few details needed to understand and verify it. Do not dump " ~
        "large files; reference their paths.\n");
    builder.put("- Mention a next step only when useful or still required. If " ~
        "verification could not run, state why and give the exact remaining " ~
        "command or action.\n");
    builder.put("- Use GitHub-flavored Markdown lightly. Prefer short paragraphs " ~
        "and present-tense active voice; use backticks for commands, paths, " ~
        "environment variables, and code identifiers.\n");

    // Dynamic values stay last so the stable instruction prefix can be cached.
    builder.put("\n# Environment\n<env>\n");
    builder.put("  Working directory: " ~ workspace ~ "\n");
    builder.put("  Is directory a git repo: " ~
        (isGitRepo ? "yes" : "no") ~ "\n");
    builder.put("  Platform: " ~ platformName ~ "\n");
    builder.put("  Local date and time: " ~ today ~ "\n</env>\n");

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
    // Wall-clock duration of the call, measured by `executeTool`. The UI shows
    // it on the tool row (and aggregated on the action-group header) the same
    // way the file-mutating tools show their `+N -M` counters.
    long elapsedMs;
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

private string snapshotHash(bool existsValue, const(ubyte)[] bytes)
{
    if (!existsValue) return "missing";
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
    result.exists = exists(result.path) && isFile(result.path);
    if (result.exists)
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
            foreach (entry; dirEntries(path, SpanMode.depth))
                if (entry.isFile && !seen(buildNormalizedPath(entry.name)))
                    result ~= snapshotFile(entry.name);
        }
        else if (!seen(path))
            result ~= snapshotFile(path);
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
            item.bytes.dup);
        if (!paths.canFind(item.path)) paths ~= item.path;
    }
    foreach (item; after)
    {
        newByPath[item.path] = FileSnapshot(item.path, item.exists,
            item.bytes.dup);
        if (!paths.canFind(item.path)) paths ~= item.path;
    }
    synchronized (_changeJournalMutex)
    {
        foreach (index, path; paths)
        {
            auto oldState = path in oldByPath ? oldByPath[path] :
                FileSnapshot(path, false, null);
            auto newState = path in newByPath ? newByPath[path] :
                FileSnapshot(path, false, null);
            if (oldState.exists == newState.exists &&
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
            record.beforeHash = snapshotHash(oldState.exists, oldState.bytes);
            record.afterHash = snapshotHash(newState.exists, newState.bytes);
            if (oldState.exists)
            {
                record.beforeBlob = buildPath(root, "blobs", id ~ ".before");
                writeSnapshotBlob(record.beforeBlob, oldState.bytes);
            }
            if (newState.exists)
            {
                record.afterBlob = buildPath(root, "blobs", id ~ ".after");
                writeSnapshotBlob(record.afterBlob, newState.bytes);
            }
            if (snapshotIsText(oldState.bytes) &&
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

    // The program name is resolved against PATH by spawnProcess; an explicit
    // path may be given instead. Remaining arguments pass through verbatim.
    const resolvedWorkdir = workdir.length > 0
        ? resolveToolPath(workdir, workspace) : workspace;
    auto fullArgv = [program] ~ argv;

    if (background)
        return startBackgroundProcess(fullArgv, resolvedWorkdir, timeoutMs,
            "run");
    auto result = runProcess(fullArgv, resolvedWorkdir, timeoutMs, "run",
        cancellation);
    return ToolExecution("run", truncateOutput(result[0]), result[1]);
}

/// Identity attached to mutations initiated by a real GUI conversation. An
/// empty conversation id disables journaling, keeping standalone tool tests and
/// probes isolated from the user's durable history.
public struct ChangeContext
{
    string conversationId;
    string turnId;
}

/// One file in Aurora's append-only mutation journal. Before/after contents are
/// stored as private blobs outside the workspace; hashes make the table useful
/// without loading those blobs and exact after bytes guard every revert.
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

    string[] touched;
    string combinedDiff;
    int totalAdditions;
    int totalDeletions;
    string[] failures;

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
            const path = resolveToolPath(rel, workspace);
            try
            {
                import std.path : dirName;
                if (dirName(path).length > 0) mkdirRecurse(dirName(path));
                write(path, builder.data);
                auto diff = computeTextDiff("", builder.data);
                totalAdditions += diff.additions;
                totalDeletions += diff.deletions;
                combinedDiff ~= diff.unified ~ "\n";
                touched ~= rel;
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
            const path = resolveToolPath(rel, workspace);
            try
            {
                string previous = exists(path) ? readText(path) : "";
                if (exists(path)) remove(path);
                auto diff = computeTextDiff(previous, "");
                totalDeletions += diff.deletions;
                combinedDiff ~= diff.unified ~ "\n";
                touched ~= rel;
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
            const path = resolveToolPath(rel, workspace);
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
            try
            {
                write(path, content);
                auto diff = computeTextDiff(original, content);
                totalAdditions += diff.additions;
                totalDeletions += diff.deletions;
                combinedDiff ~= diff.unified ~ "\n";
                touched ~= rel;
            }
            catch (Exception error)
                failures ~= rel ~ ": " ~ error.msg;
            continue;
        }
        ++cursor;
    }

    if (touched.length == 0 && failures.length == 0)
        return ToolExecution("apply_patch",
            "Error: no files were changed; the patch had no sections.", true);

    auto builder = appender!string();
    builder.put("Applied patch to " ~ to!string(touched.length) ~
        (touched.length == 1 ? " file" : " files") ~ " (+" ~
        to!string(totalAdditions) ~ " -" ~ to!string(totalDeletions) ~ ").");
    if (failures.length > 0)
    {
        builder.put("\nFailed:");
        foreach (failure; failures)
            builder.put("\n- " ~ failure);
    }
    ToolExecution result;
    result.name = "apply_patch";
    result.output = builder.data;
    result.additions = totalAdditions;
    result.deletions = totalDeletions;
    result.diff = combinedDiff;
    result.failed = failures.length > 0;
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
    enum ulong maxRecursiveFileBytes = 8UL * 1024 * 1024;
    string[] hits;
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
                if (matchFirst(line, re).empty) continue;
                string display =
                    decodeBytesLenient(cast(const(ubyte)[]) line);
                if (display.length > maxLineChars)
                    display = display[0 .. utf8SafeCut(
                        cast(const(ubyte)[]) display[0 .. maxLineChars])] ~ "…";
                hits ~= filePath ~ ":" ~ to!string(lineNo) ~ ": " ~ display;
                if (hits.length >= maxHits)
                {
                    capped = true;
                    return true;
                }
            }
        }
        catch (Exception) {}
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
            to!string(hits.length) ~ " matches so far. Review this progress " ~
            "and decide whether waiting longer is reasonable. Rerun the same " ~
            "focused search with a larger `timeout` (up to 600000 ms), or " ~
            "narrow `path`, `pattern`, or `include`.\n");
        foreach (hit; hits) report.put(hit ~ "\n");
        return ToolExecution("grep", truncateOutput(report.data), true);
    }
    if (stopped)
        return ToolExecution("grep", "Stopped: grep cancelled.", true);
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

/// Execute a single tool call against the workspace directory and record how
/// long it took. The result is a plain-text string ready to be fed back to the
/// model as a `tool` message.
public ToolExecution executeTool(const OpenCodeToolCall call,
    string workspace, ToolCancellation cancellation = null,
    ChangeContext changeContext = ChangeContext.init)
{
    const started = MonoTime.currTime;
    ToolExecution result;
    if (call.name == "write" || call.name == "edit" ||
        call.name == "apply_patch" || call.name == "remove")
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
    const present = exists(record.path) && isFile(record.path);
    if (present != record.afterExists) return false;
    if (!present) return true;
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
                result.message = "Cannot revert because the file changed " ~
                    "after Aurora recorded it: " ~ record.path;
                return result;
            }

        FileSnapshot[] before;
        string[] paths;
        string[] revertIds;
        foreach (record; targets)
        {
            before ~= snapshotFile(record.path);
            paths ~= record.path;
            revertIds ~= record.revertOf.length > 0 ? record.revertOf :
                record.id;
            if (record.beforeExists)
            {
                if (record.beforeBlob.length == 0 ||
                    !exists(record.beforeBlob))
                    throw new Exception("missing before snapshot for " ~
                        record.path);
                import std.path : dirName;
                const parent = dirName(record.path);
                if (parent.length > 0) mkdirRecurse(parent);
                write(record.path, read(record.beforeBlob));
            }
            else if (exists(record.path) && isFile(record.path))
                remove(record.path);
        }
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
            (targets.length == 1 ? " file." : " files.");
    }
    catch (Exception error)
        result.message = "Revert failed: " ~ error.msg;
    return result;
}

public string changeRecordDiff(const ref ChangeRecord record)
{
    try
    {
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
        case "write":
            return runWrite(call.arguments, workspace);
        case "edit":
            return runEdit(call.arguments, workspace);
        case "apply_patch":
            return runApplyPatch(call.arguments, workspace);
        case "update_plan":
            return runUpdatePlan(call.arguments, workspace);
        case "remove":
            return runRemove(call.arguments, workspace);
        case "glob":
            return runGlob(call.arguments, workspace);
        case "grep":
            return runGrep(call.arguments, workspace, cancellation);
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
