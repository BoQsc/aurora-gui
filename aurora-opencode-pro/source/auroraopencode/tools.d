module auroraopencode.tools;

import auroraopencode.core : OpenCodeToolCall, OpenCodeToolDef;
import std.file : dirEntries, exists, isFile, isDir, SpanMode, read, readText,
    write, mkdirRecurse, remove, rmdirRecurse, tempDir, getSize,
    timeLastModified;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildNormalizedPath, buildPath, expandTilde,
    isAbsolute;
import std.process : Pid, Pipe, pipe, waitTimeout, kill, wait, spawnProcess,
    Config;
version (Windows)
    import core.sys.windows.windows : HANDLE, DWORD, BOOL, UINT, ULONG_PTR,
        LONG, WCHAR;
import std.regex : Regex, matchFirst, regex;
import std.stdio : File, stdin, stdout, stderr;
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
            "dedicated tools do not fit. " ~ shellUsageNotes(shell),
            `{"type":"object","properties":{"command":{"type":"string","description":"The command to execute"},"shell":{"type":"string","enum":["auto","bash","cmd","powershell","pwsh"],"description":"The shell to run the command in. Defaults to the platform shell."},"workdir":{"type":"string","description":"Working directory, relative to the workspace or absolute. Use this instead of cd."},"timeout":{"type":"integer","description":"Timeout in milliseconds (default 3600000)"},"background":{"type":"boolean","description":"Return immediately with a processId and supervise the command in the background"}},"required":["command"]}`
        ),
        processToolDefinition(),
        dshellToolDefinition(),
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
            `{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression to search for"},"include":{"type":"string","description":"Optional file extension filter, e.g. *.d"},"path":{"type":"string","description":"Directory to search, relative to the workspace or absolute; defaults to the workspace"}},"required":["pattern"]}`
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
            "source/app.d`).",
            `{"type":"object","properties":{"program":{"type":"string","description":"The executable to run (e.g. dmd, git, python)"},"args":{"type":"array","items":{"type":"string"},"description":"Arguments passed verbatim to the program"},"workdir":{"type":"string","description":"Working directory, relative to the workspace or absolute"},"timeout":{"type":"integer","description":"Timeout in milliseconds (default 3600000)"},"background":{"type":"boolean","description":"Return immediately with a processId and supervise the program in the background"}},"required":["program"]}`
        ),
        processToolDefinition(),
        dshellToolDefinition(),
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
            `{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression to search for"},"include":{"type":"string","description":"Optional file extension filter, e.g. *.d"},"path":{"type":"string","description":"Directory to search, relative to the workspace or absolute; defaults to the workspace"}},"required":["pattern"]}`
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
    builder.put("You are Aurora OpenCode, an interactive coding agent that " ~
        "runs on the user's computer and works through the same agent " ~
        "workflow as Codex: plan, gather context, apply patches, run " ~
        "commands, verify, and report. Use the instructions below and the " ~
        "tools available to you to assist the user.\n");

    builder.put("\n# Environment\n");
    builder.put("<env>\n");
    builder.put("  Working directory: " ~ workspace ~ "\n");
    builder.put("  Is directory a git repo: " ~
        (isGitRepo ? "yes" : "no") ~ "\n");
    builder.put("  Platform: " ~ platformName ~ "\n");
    builder.put("  Today's date: " ~ today ~ "\n");
    builder.put("</env>\n");

    builder.put("\n## General\n");
    builder.put("- Work outcome-first. For a change request, start making the " ~
        "smallest correct change as soon as the relevant code is known; for " ~
        "an investigation, answer as soon as the evidence supports it.\n");
    builder.put("- Use the fewest useful tool rounds, but continue until the " ~
        "requested outcome is achieved or a concrete blocker requires user " ~
        "input. Successful reads, searches, builds, tests, and verified waits " ~
        "are progress when they resolve a relevant unknown; never stop merely " ~
        "because a task required several tool rounds. Batch independent " ~
        "lookups, avoid rereading known code, and do not search merely to gain " ~
        "confidence.\n");
    builder.put("- Define success before acting and stop when it is met. If you " ~
        "say you have the full picture or enough information, your next step " ~
        "must be an edit, a focused verification, or the final answer.\n");
    builder.put("- After a focused verification succeeds, stop and report. Do " ~
        "not inspect generated files, directory listings, or unrelated checks " ~
        "unless the verification output identifies a concrete problem.\n");
    builder.put("- Do not use two tools for the same discovery. In particular, " ~
        "do not list a directory when the relevant file paths are already " ~
        "known, and do not follow a successful search with a broader one.\n");
    builder.put("- Read-only exploration has a finite budget. By about ten " ~
        "read/search calls you must make the smallest correct edit or state a " ~
        "specific blocker; varying search arguments is not progress by itself.\n");
    builder.put("- Treat an explicit path in the user's request as the target. " ~
        "If it differs from the working directory, pass that absolute path to " ~
        "`read`, `dshell`, or `grep`, or use it as `run.workdir`; do not search " ~
        "the working directory and assume no files exist.\n");
    builder.put("- Use `dshell list` as the primary way to discover files; set " ~
        "`recursive` and `pattern` when needed. Use `grep` for file contents. " ~
        "Do not invoke external listing or search programs.\n");
    builder.put("- Your output is plain text rendered in a chat UI with " ~
        "GitHub-flavored Markdown. Be concise, direct, and active; mirror " ~
        "the user's tone; only use emojis if the user explicitly asks.\n");
    builder.put("- Do not narrate every individual tool call. Write one " ~
        "short sentence before a batch of calls so the user can follow " ~
        "along, then let the tools speak for themselves.\n");

    builder.put("\n## Editing constraints\n");
    builder.put("- Default to ASCII when creating or editing files. Only " ~
        "introduce non-ASCII when there is a clear justification and the " ~
        "file already uses it.\n");
    builder.put("- Add succinct comments only where the code is not " ~
        "self-explanatory; do not comment trivial statements.\n");
    builder.put("- Prefer `apply_patch` for file edits: it applies many " ~
        "files and hunks in one call, so a whole change costs one round. " ~
        "Use `edit`/`write` when a patch is awkward, and never use " ~
        "`apply_patch` for auto-generated files or bulk search-and-replace.\n");
    builder.put("- Before applying a patch, include every currently known " ~
        "requested file change in that one patch. Do not hold back a known " ~
        "edit for a second mutation round.\n");
    builder.put("- The worktree may be dirty. NEVER revert changes you did " ~
        "not make unless the user explicitly asks; work with them instead. " ~
        "Do not amend commits unless asked.\n");
    builder.put("- NEVER run destructive commands such as `git reset " ~
        "--hard` or `git checkout --` unless the user explicitly requests " ~
        "or approves them.\n");
    builder.put("- If you notice unexpected changes you did not make, stop " ~
        "and ask the user how to proceed.\n");
    builder.put("- This application can edit its own source, so the process " ~
        "running this session is the same one a build or a process kill would " ~
        "replace or terminate. NEVER run a build, rebuild, or stop command " ~
        "(`dub build`, `taskkill`, `Stop-Process`, or killing " ~
        "`aurora-opencode-pro`/`aurora-rebuilder`): ending that process ends " ~
        "your own session and the supervisor relaunches it, forcing the user " ~
        "to restart you. Make source-only edits and let the user rebuild " ~
        "externally.\n");

    builder.put("\n## Plan tool\n");
    builder.put("Use the `update_plan` tool to track multi-step work.\n");
    builder.put("- Skip the plan for straightforward tasks (roughly the " ~
        "easiest 25%) and never make a single-step plan.\n");
    builder.put("- Give each step a `status`: `pending`, `in_progress`, or " ~
        "`completed`. At most one step may be `in_progress` at a time.\n");
    builder.put("- Update the plan after completing a step, not on every " ~
        "tool call.\n");

    builder.put("\n# Tool usage policy\n");
    if (nativeOnly)
    {
        builder.put("You have access to tools implemented natively in this " ~
            "application; there is no shell and no bash/cmd/powershell. Use " ~
            "`dshell list` for all file discovery, `dshell info` for metadata, " ~
            "`dshell where` only when the user specifically asks for the " ~
            "location, and `read` to read " ~
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
            "native tools: `dshell where/list/info` for workspace navigation " ~
            "and discovery, `read` to read " ~
            "them, `write` to create them, `remove` to delete files or " ~
            "directories, and `grep` to search contents. " ~
            "Never use shell command words such as pwd, ls, dir, or stat for " ~
            "these operations. Use the `bash` tool only for running build " ~
            "commands, git, package managers, or other executables that the " ~
            "native tools cannot perform.\n");
    }
    builder.put("Use `dshell list` for directory, recursive, and pattern-based " ~
        "discovery. Its output includes the resolved path, so never pair it " ~
        "with `dshell where`. Before beginning work, identify the requested outcome and " ~
        "the smallest evidence needed.\n");

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
    builder.put("- `apply_patch` {\"patch\":\"*** Begin Patch\\n*** Update " ~
        "File: src/main.d\\n@@\\n context\\n-old\\n+new\\n*** End Patch\"} - " ~
        "apply a multi-file, multi-hunk patch in ONE call (Codex patch " ~
        "format). Use `*** Add File:`, `*** Update File:` and `*** Delete " ~
        "File:` sections; prefix unchanged lines with a space, removals " ~
        "with `-`, additions with `+`. This is the preferred way to make a " ~
        "change that touches several files or places.\n");
    builder.put("- `update_plan` {\"explanation\":\"why\",\"plan\":" ~
        "[{\"step\":\"read the code\",\"status\":\"completed\"}," ~
        "{\"step\":\"write the fix\",\"status\":\"in_progress\"}]} - record " ~
        "and update the task plan so the user can see the steps.\n");
    builder.put("- `grep` {\"pattern\":\"class\\s+Widget\",\"include\":\"*.d\"," ~
        "\"path\":\"C:/repo\"} — search contents under optional `path`; " ~
        "returns matching lines as path:line: text.\n");
    builder.put("- `remove` {\"path\":\"build\"} — delete a file or directory " ~
        "tree.\n");
    builder.put("- `dshell` {\"command\":\"list\",\"path\":\"src\"," ~
        "\"recursive\":true,\"pattern\":\"**/*.d\"} — primary native workspace " ~
        "navigator: `where`, filtered/recursive `list`, and metadata `info`.\n");
    if (nativeOnly)
        builder.put("- `run` {\"program\":\"dmd\",\"args\":[\"-Isource\"," ~
            "\"-i\",\"-run\",\"source/app.d\"],\"workdir\":\".\"} — run an " ~
            "executable directly with an " ~
            "argument list; no shell, no quoting or redirection.\n");
    else
        builder.put("- `bash` {\"command\":\"dub build\",\"workdir\":\".\"} — " ~
            "run a shell command. Use only for builds, git, package managers, " ~
            "or executables the native tools cannot handle.\n");
    builder.put("- Add `\"background\":true` to `run`/`bash` for long builds, " ~
        "servers, watchers, or commands that need not block the agent turn. " ~
        "The result returns a stable processId. Use `process` with action " ~
        "`status`, `output`, `write`, `kill`, or `remove` to manage it; use " ~
        "`write` with `input` and optional `closeStdin`; use `list` " ~
        "without an id to discover active processes. Never restart a command " ~
        "just because its status is still running.\n");
    builder.put("Workflow: gather context with `dshell`/`read`/`grep`, make the " ~
        "smallest change with `edit` (or `write` for new files or full " ~
        "rewrites), verify with `run`/`bash`, then briefly summarise what " ~
        "changed.\n");
    builder.put("Batch independent tool calls into a single response (for " ~
        "example read several files, or grep several patterns, at once) so a " ~
        "turn does not spend one round per tiny step. Only call tools one at a " ~
        "time when each call depends on the previous result.\n");
    builder.put("Before a batch of tool calls, write one short sentence saying " ~
        "what you are about to do and why, so the user can follow along; keep " ~
        "it to a line, do not narrate every individual call.\n");

    builder.put("\n## Special user requests\n");
    builder.put("- If the user makes a simple request you can fulfil with a " ~
        "terminal command (such as asking for the time), run the command.\n");
    builder.put("- If the user asks for a \"review\", default to a code " ~
        "review mindset: prioritise bugs, risks, behavioural regressions " ~
        "and missing tests. Findings are the primary focus, ordered by " ~
        "severity with file/line references, followed by open questions; " ~
        "keep any summary brief and last. If there are no findings, say so " ~
        "and name the residual risks or testing gaps.\n");

    builder.put("\n## Frontend tasks\n");
    builder.put("When doing frontend design tasks, avoid safe, average " ~
        "layouts and aim for interfaces that feel intentional and bold.\n");
    builder.put("- Typography: expressive, purposeful fonts; avoid default " ~
        "stacks (Inter, Roboto, Arial, system).\n");
    builder.put("- Color: choose a clear visual direction; define CSS " ~
        "variables; avoid purple-on-white and default dark-mode looks.\n");
    builder.put("- Motion: a few meaningful animations (page load, " ~
        "staggered reveals) instead of generic micro-motions.\n");
    builder.put("- Background: gradients, shapes or subtle patterns, not " ~
        "a flat single color.\n");
    builder.put("- Ensure the page works on desktop and mobile. Exception: " ~
        "when working inside an existing website or design system, preserve " ~
        "its established patterns and visual language.\n");

    builder.put("\n## Presenting your work and final message\n");
    builder.put("- Default: be very concise; a friendly coding-teammate " ~
        "tone. Skip heavy formatting for simple confirmations.\n");
    builder.put("- For substantial work, summarise clearly: lead with a " ~
        "quick explanation of the change, then the context of where and why " ~
        "it was made. Do not start with the word \"summary\".\n");
    builder.put("- Do not dump large files you wrote; reference paths only. " ~
        "The user is on the same machine, so never say \"save/copy this " ~
        "file\".\n");
    builder.put("- Offer logical next steps (tests, commits, build) " ~
        "briefly, and add verification steps if you could not do something.\n");
    builder.put("- When you list options for the user to choose from, use a " ~
        "numeric list so the user can reply with a single number.\n");
    builder.put("- Final answer style: plain text; short Title Case headers " ~
        "in **bold** only when they help; bullets with \"-\", 4-6 per list, " ~
        "one line each, most important first; backticks for commands, " ~
        "paths, env vars and code ids (never combined with bold); no " ~
        "nested bullets; present tense, active voice.\n");
    builder.put("- File references: wrap each path in backticks, give each " ~
        "reference its own path, and optionally a 1-based line/column " ~
        "(e.g. `src/app.d:42`). Do not use `file://` URIs or line ranges.\n");

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

private ToolExecution runBash(string args, string workspace)
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
    auto result = runProcess(fullArgv, resolvedWorkdir, timeoutMs, "run");
    return ToolExecution("run", truncateOutput(result[0]), result[1]);
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

shared static this()
{
    _processMutex = new Mutex();
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
    int timeoutMs, string toolName)
{
    import std.typecons : tuple;
    import core.atomic : atomicLoad;

    // A stop may have been requested after the previous command finished but
    // before this one launched; honor it without starting the process at all.
    if (atomicLoad(_commandsCancelled))
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
    // Poll rather than blocking for the whole timeout so a stop request can
    // terminate a long-running command promptly instead of waiting it out.
    while (true)
    {
        if (waitTimeout(pid, msecs(100)).terminated) break;
        if (atomicLoad(_commandsCancelled))
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
    if (output.length == 0) output = "(no output)";
    return tuple(output, timedOut || cancelled);
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
                if (oldBlock.length == 0)
                    at = searchPos;
                else
                {
                    const found = content.indexOf(oldBlock, searchPos);
                    if (found < 0)
                    {
                        hunkFailed = true;
                        failReason = "patch context not found";
                        return;
                    }
                    at = cast(size_t) found;
                }
                content = content[0 .. at] ~ newBlock ~
                    content[at + oldBlock.length .. $];
                searchPos = at + newBlock.length;
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

private ToolExecution runGrep(string args, string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;
    string pattern;
    string include;
    string pathArg;
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
    }
    if (pattern.length == 0)
        return ToolExecution("grep",
            "Error: grep requires a `pattern` argument.", true);

    const root = pathArg.length > 0
        ? resolveToolPath(pathArg, workspace) : workspace;
    if (!exists(root) || !isDir(root))
        return ToolExecution("grep", "Error: search directory not found: " ~
            root, true);

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
    outer: foreach (entry; dirEntries(root, SpanMode.breadth))
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

/// Execute a single tool call against the workspace directory and record how
/// long it took. The result is a plain-text string ready to be fed back to the
/// model as a `tool` message.
public ToolExecution executeTool(const OpenCodeToolCall call,
    string workspace)
{
    const started = MonoTime.currTime;
    auto result = dispatchTool(call, workspace);
    // Microsecond precision then round to ms. An in-process edit can finish in
    // well under a millisecond; clamping to 1 keeps the label visible and
    // honest ("<1ms" would just be noise) instead of dropping it as 0.
    const usecs = cast(long) (MonoTime.currTime - started).total!"usecs";
    result.elapsedMs = usecs <= 1000 ? 1 : (usecs + 500) / 1000;
    return result;
}

/// Dispatch a tool call. Split out of `executeTool` so the timing wrapper has a
/// single return point and every exit (including the unknown-tool error) is
/// measured.
private ToolExecution dispatchTool(const OpenCodeToolCall call,
    string workspace)
{
    switch (call.name)
    {
        case "bash":
            return runBash(call.arguments, workspace);
        case "run":
            return runProgramTool(call.arguments, workspace);
        case "process":
            return runProcessTool(call.arguments);
        case "dshell":
            return runDshell(call.arguments, workspace);
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
