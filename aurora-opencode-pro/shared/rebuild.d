/**
 * Self-rebuild, rebuilt around one idea: the app is its own rebuild agent.
 *
 * Windows keeps a running image locked, so an executable cannot overwrite
 * itself while it is alive. The previous design answered this with a *second*
 * program - `bin/aurora-rebuilder.exe` - that had to be compiled and kept in
 * sync with this one. That second program is the whole source of friction: it
 * can go stale, go missing, or disagree with the app about the protocol, and
 * every symptom looked like "the rebuild did nothing".
 *
 * The new design removes it. When the app wants to rebuild, it copies *itself*
 * to a throwaway image beside the package and runs that copy as the agent. The
 * copy is instant, always matches the running build, and never needs its own
 * build step. The app then closes; the copy waits for the image to be released,
 * shows a small progress window, builds in place, and relaunches the app.
 *
 * One module still owns the whole feature. Its three surfaces are:
 *
 *   - the ledger      `rebuildstate.json` (the lifecycle of one rebuild) plus
 *                     `build.log` / `rebuild-report.txt` (the compiler output),
 *                     written here so app, helper and reader never drift;
 *   - the app side    `planRebuild` / `launchRebuild`: copy self, record
 *                     `pending`, spawn the copy detached;
 *   - the agent       `runRebuildHelperMode`: wait, build, relaunch, supervise,
 *                     plus the tiny always-on-top progress window that reports
 *                     while the app is closed.
 *
 * The entry point lives in `source/app.d`, which dispatches on
 * `rebuildHelperFlag` before it touches the GUI, so the same binary is either
 * the app or the agent.
 */
module rebuild;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.array : join;
import std.conv : to;
import std.datetime : Clock, SysTime;
import std.file : append, copy, dirEntries, exists, getSize, mkdirRecurse,
    readText, remove, SpanMode, timeLastModified, write;
import std.json : JSONType, parseJSON;
import std.path : baseName, buildPath, dirName;
import std.process : Config, spawnProcess, wait;
import std.stdio : File, stderr, stdin, stdout;
import std.string : indexOf, lastIndexOf, replace, startsWith, strip;
import std.utf : toUTF16;

version (Windows)
    import core.sys.windows.windows;

/// The argv token that turns a copy of the app into the rebuild agent. It is
/// checked as `args[1]` by `main`, before anything else runs.
enum string rebuildHelperFlag = "--aurora-rebuild-helper";

// ===========================================================================
// Ledger: rebuildstate.json and the sibling build artifacts
// ===========================================================================
// The app writes `pending` before it hands off. The agent moves the record
// through `running` to `ok` or `failed`. The relaunched app reads it back to
// answer "are my edits live, and if not why". The file is the single source of
// truth; nothing infers state from timing or process presence.

/// The lifecycle recorded in `rebuildstate.json`.
enum RebuildStatus
{
    none,
    pending,
    running,
    ok,
    failed,
}

/// The wire token for a status.
string rebuildStatusName(RebuildStatus status)
{
    final switch (status)
    {
        case RebuildStatus.none: return "none";
        case RebuildStatus.pending: return "pending";
        case RebuildStatus.running: return "running";
        case RebuildStatus.ok: return "ok";
        case RebuildStatus.failed: return "failed";
    }
}

/// Parse a status token; unknown text is `none`, so corrupt state is inert.
RebuildStatus parseRebuildStatus(string text)
{
    switch (text)
    {
        case "pending": return RebuildStatus.pending;
        case "running": return RebuildStatus.running;
        case "ok": return RebuildStatus.ok;
        case "failed": return RebuildStatus.failed;
        default: return RebuildStatus.none;
    }
}

/// The lifecycle record inside the package directory.
string rebuildStatePath(string dir)
{
    return dir.length > 0 ? buildPath(dir, "rebuildstate.json") : "";
}

/// The failed-build summary (compiler errors), written only on failure.
string rebuildReportPath(string dir)
{
    return dir.length > 0 ? buildPath(dir, "rebuild-report.txt") : "";
}

/// The captured `dub build` transcript for the most recent rebuild.
string buildLogPath(string dir)
{
    return dir.length > 0 ? buildPath(dir, "build.log") : "";
}

/// A snapshot of `rebuildstate.json`. Absent or unknown fields default empty.
struct RebuildState
{
    RebuildStatus status;
    string phase;
    string reason;
    /// The build command line, recorded so the record says what ran.
    string command;
    /// The executable that was rebuilt and relaunched.
    string exePath;
    /// The package directory the build ran in.
    string packageDir;
    string startedAt;
    string finishedAt;
    long durationMs;
    int exitCode;
    string[] errors;
}

/// Read the persisted lifecycle. Missing or unreadable state is `none`, so a
/// damaged file never breaks startup.
RebuildState readRebuildState(string dir)
{
    RebuildState state;
    const path = rebuildStatePath(dir);
    if (path.length == 0 || !exists(path)) return state;
    try
    {
        auto value = parseJSON(readText(path));
        if (value.type != JSONType.object) return state;
        auto root = value.object;
        if (auto field = "status" in root)
            if (field.type == JSONType.string)
                state.status = parseRebuildStatus(field.str);
        if (auto field = "phase" in root)
            if (field.type == JSONType.string) state.phase = field.str;
        if (auto field = "reason" in root)
            if (field.type == JSONType.string) state.reason = field.str;
        if (auto field = "command" in root)
            if (field.type == JSONType.string) state.command = field.str;
        if (auto field = "exe" in root)
            if (field.type == JSONType.string) state.exePath = field.str;
        if (auto field = "dir" in root)
            if (field.type == JSONType.string) state.packageDir = field.str;
        if (auto field = "startedAt" in root)
            if (field.type == JSONType.string) state.startedAt = field.str;
        if (auto field = "finishedAt" in root)
            if (field.type == JSONType.string) state.finishedAt = field.str;
        if (auto field = "durationMs" in root)
            if (field.type == JSONType.integer) state.durationMs = field.integer;
        if (auto field = "exitCode" in root)
            if (field.type == JSONType.integer)
                state.exitCode = cast(int) field.integer;
        if (auto field = "errors" in root)
            if (field.type == JSONType.array)
                foreach (entry; field.array)
                    if (entry.type == JSONType.string)
                        state.errors ~= entry.str;
    }
    catch (Exception) {}
    return state;
}

/// Write the lifecycle record, replacing any earlier one. False when the
/// package directory was unknown or the write failed. The JSON is formatted by
/// hand (fixed key order) so the file reads the same no matter who wrote it.
bool writeRebuildState(string dir, in RebuildState state)
{
    const path = rebuildStatePath(dir);
    if (path.length == 0) return false;
    string json;
    json ~= "{\n";
    json ~= "  \"status\": " ~ jsonString(rebuildStatusName(state.status)) ~ ",\n";
    json ~= "  \"phase\": " ~ jsonString(state.phase) ~ ",\n";
    json ~= "  \"reason\": " ~ jsonString(state.reason) ~ ",\n";
    json ~= "  \"command\": " ~ jsonString(state.command) ~ ",\n";
    json ~= "  \"exe\": " ~ jsonString(state.exePath) ~ ",\n";
    json ~= "  \"dir\": " ~ jsonString(state.packageDir) ~ ",\n";
    json ~= "  \"startedAt\": " ~ jsonString(state.startedAt) ~ ",\n";
    json ~= "  \"finishedAt\": " ~ jsonString(state.finishedAt) ~ ",\n";
    json ~= "  \"durationMs\": " ~ to!string(state.durationMs) ~ ",\n";
    json ~= "  \"exitCode\": " ~ to!string(state.exitCode) ~ ",\n";
    json ~= "  \"errors\": [";
    foreach (index, line; state.errors)
    {
        if (index) json ~= ", ";
        json ~= jsonString(line);
    }
    json ~= "]\n";
    json ~= "}\n";
    try
    {
        mkdirRecurse(dir);
        write(path, json);
        return true;
    }
    catch (Exception)
        return false;
}

/// `2026-09-21 17:54:10` in local time, the timestamp form every artifact uses.
private string rebuildStamp(SysTime value)
{
    return value.toLocalTime.toISOExtString.replace("T", " ");
}

/// A JSON string literal, escaped correctly and minimally.
private string jsonString(string value)
{
    return "\"" ~ value.replace("\\", "\\\\").replace("\"", "\\\"")
        .replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t") ~
        "\"";
}

// ===========================================================================
// Notice: what the resumed conversation is told
// ===========================================================================

/// The rebuild lifecycle as the app needs it: what happened, whether the
/// running binary includes the edits, and the errors to quote when it does not.
struct RebuildOutcome
{
    /// A lifecycle record existed (a rebuild was recorded at all).
    bool found;
    RebuildStatus status;
    string phase;
    string reason;
    string startedAt;
    string finishedAt;
    long durationMs;
    int exitCode;
    string[] errors;
    /// The failed-build report text ("" otherwise).
    string report;
    /// Where the build transcript lives, for pointing the agent at the detail.
    string buildLog;
}

/// A rebuild that reached a verdict and succeeded.
bool rebuildSucceeded(in RebuildOutcome outcome)
{
    return outcome.found && outcome.status == RebuildStatus.ok;
}

/// A rebuild that reached a verdict and failed to compile.
bool rebuildFailed(in RebuildOutcome outcome)
{
    return outcome.found && outcome.status == RebuildStatus.failed;
}

/**
 * A rebuild that never reached a verdict. Only `running` qualifies: the agent
 * began building, yet we are already running again, so the build did not finish
 * and the edits are not live. `pending` is excluded - it means no agent ever
 * took the record over, which the caller resolves by source staleness.
 */
bool rebuildIncomplete(in RebuildOutcome outcome)
{
    return outcome.found && outcome.status == RebuildStatus.running;
}

/// The status token for display.
string rebuildStatusLabel(RebuildStatus status)
{
    return rebuildStatusName(status);
}

/**
 * Read the persisted rebuild outcome. A missing or unreadable state file yields
 * `found == false`, which the caller treats as "no rebuild on record".
 */
RebuildOutcome readRebuildOutcome(string dir)
{
    RebuildOutcome outcome;
    auto state = readRebuildState(dir);
    if (state.status == RebuildStatus.none) return outcome;
    outcome.found = true;
    outcome.status = state.status;
    outcome.phase = state.phase;
    outcome.reason = state.reason;
    outcome.startedAt = state.startedAt;
    outcome.finishedAt = state.finishedAt;
    outcome.durationMs = state.durationMs;
    outcome.exitCode = state.exitCode;
    outcome.errors = state.errors;
    outcome.buildLog = buildLogPath(dir);
    if (state.status == RebuildStatus.failed)
    {
        const path = rebuildReportPath(dir);
        if (exists(path))
        {
            try outcome.report = readText(path);
            catch (Exception) {}
        }
        if (outcome.report.length == 0 && outcome.errors.length > 0)
            outcome.report = "compiler errors (" ~
                to!string(outcome.errors.length) ~ "):\n  " ~
                join(outcome.errors, "\n  ") ~ "\n";
    }
    return outcome;
}

// ===========================================================================
// App side: plan the rebuild, copy self, hand off
// ===========================================================================

/// How far above the executable to look for a DUB recipe before giving up.
private enum int maxBuildDirLevels = 8;

/// The recipe filenames DUB accepts.
private immutable string[] recipeNames = ["dub.json", "dub.sdl"];

/// Everything needed to rebuild and relaunch the app.
struct RebuildPlan
{
    /// The running executable: rebuilt in place and relaunched.
    string exePath;
    /// Package directory (nearest ancestor holding a DUB recipe). Empty when
    /// the binary lives outside a package, in which case the rebuild is skipped
    /// but a relaunch still happens. Also the home of the ledger and artifacts.
    string workingDir;
    /// Agent log, under the app's state directory.
    string logPath;
    /// The process the agent waits for: this one, whose exit frees the image.
    int waitPid;
    /// Run `dub build` before relaunching.
    bool rebuild;
    /// Why the rebuild was requested, carried into the ledger and the agent.
    string reason;
}

/**
 * The nearest ancestor of `exePath` that holds a DUB recipe, or "" when there
 * is none. A binary launched by `dub run` sits in the package directory, but a
 * packaged/copied build may sit elsewhere; walking up a bounded number of
 * levels covers both without scanning the whole drive.
 */
string findBuildDirectory(string exePath)
{
    if (exePath.length == 0) return "";
    auto directory = dirName(exePath);
    foreach (_; 0 .. maxBuildDirLevels)
    {
        if (directory.length == 0) break;
        foreach (recipe; recipeNames)
            if (exists(buildPath(directory, recipe)))
                return directory;
        const parent = dirName(directory);
        if (parent.length == 0 || parent == directory) break;
        directory = parent;
    }
    return "";
}

/**
 * True when `dir` is Aurora OpenCode's own package: it ships this module's
 * source. Gates the agent-facing rebuild tool and its system-prompt awareness,
 * so a packaged copy with no sources never offers a rebuild it cannot perform.
 */
bool isAuroraProject(string dir)
{
    if (dir.length == 0) return false;
    return exists(buildPath(dir, "shared", "rebuild.d"));
}

/**
 * The general Aurora project root: the repository holding this app alongside
 * the rest of the Aurora family. Starting from the app's own package directory
 * it walks up to the nearest ancestor that is a checkout root (holds `.git`) or
 * that contains a sibling `aurora-*` package. Returns "" when the program runs
 * outside such a tree, so a caller omits the general pill rather than naming a
 * folder that is not the project.
 */
string findAuroraRoot(string packageDir)
{
    if (packageDir.length == 0) return "";
    const own = baseName(packageDir);
    auto directory = packageDir;
    foreach (_; 0 .. maxBuildDirLevels)
    {
        const parent = dirName(directory);
        if (parent.length == 0 || parent == directory) break;
        directory = parent;
        if (exists(buildPath(directory, ".git"))) return directory;
        if (hasAuroraSibling(directory, own)) return directory;
    }
    return "";
}

/// True when `directory` holds an `aurora-*` subdirectory other than `own`.
private bool hasAuroraSibling(string directory, string own)
{
    try
    {
        foreach (entry; dirEntries(directory, SpanMode.shallow))
        {
            if (!entry.isDir) continue;
            const name = baseName(entry.name);
            if (name != own && startsWith(name, "aurora-")) return true;
        }
    }
    catch (Exception) {}
    return false;
}

/**
 * The throwaway agent image: a copy of the running app, one per requesting
 * process. The pid in the name keeps a still-supervising older agent from
 * colliding with a new one; `launchRebuild` prunes the stale copies it can.
 * When no build is requested the app itself is the agent (there is nothing to
 * overwrite, so no copy is needed).
 */
string rebuildHelperPath(in RebuildPlan plan)
{
    if (!plan.rebuild) return plan.exePath;
    if (plan.workingDir.length == 0) return "";
    return buildPath(plan.workingDir, "bin",
        "aurora-rebuild-helper-" ~ to!string(plan.waitPid) ~ ".exe");
}

/// The argv for the detached agent process. Pure: it names the helper path even
/// when the file has not been copied yet, so callers can inspect it directly.
string[] rebuildHelperArgv(in RebuildPlan plan)
{
    const helper = rebuildHelperPath(plan);
    if (helper.length == 0) return [];
    string[] argv = [helper, rebuildHelperFlag, "--exe", plan.exePath];
    if (plan.workingDir.length > 0) argv ~= ["--dir", plan.workingDir];
    if (plan.logPath.length > 0) argv ~= ["--log", plan.logPath];
    argv ~= ["--pid", to!string(plan.waitPid)];
    if (plan.reason.length > 0) argv ~= ["--reason", plan.reason];
    if (!plan.rebuild) argv ~= "--no-rebuild";
    return argv;
}

/// Drop agent copies left by earlier rebuilds that are no longer running. A
/// live copy cannot be deleted (its image is locked) and is skipped by the
/// failed `remove`; `keep` is the copy this launch is about to write.
private void pruneStaleHelpers(string dir, string keep)
{
    if (dir.length == 0) return;
    try
    {
        foreach (entry; dirEntries(dir, "aurora-rebuild-helper-*.exe",
            SpanMode.shallow))
        {
            if (entry.name == keep) continue;
            try remove(entry.name);
            catch (Exception) {}
        }
    }
    catch (Exception) {}
}

/// Copy this executable to the agent path. Returns the path, or "" on failure.
private string provisionHelper(in RebuildPlan plan)
{
    const path = rebuildHelperPath(plan);
    if (path.length == 0 || !exists(plan.exePath)) return "";
    try
    {
        mkdirRecurse(dirName(path));
        pruneStaleHelpers(dirName(path), path);
        copy(plan.exePath, path);
        return path;
    }
    catch (Exception error)
    {
        appendLine(plan.logPath,
            "could not stage the rebuild agent: " ~ error.msg);
        return "";
    }
}

/**
 * Start the agent detached, so it keeps running after this process exits. The
 * returned `Pid` is discarded: a detached process is not ours to wait for.
 * Returns false when the agent could not be provisioned or started, so the
 * caller keeps the window open instead of exiting into nothing.
 */
bool launchRebuild(in RebuildPlan plan, string reason = "")
{
    if (plan.exePath.length == 0) return false;
    if (plan.rebuild && provisionHelper(plan).length == 0) return false;
    auto argv = rebuildHelperArgv(plan);
    if (argv.length == 0) return false;
    // Record the request before exiting. The agent overwrites this as it
    // advances; if the agent never starts, `pending` still explains why the app
    // came back with no new build.
    if (plan.workingDir.length > 0)
    {
        RebuildState state;
        state.status = RebuildStatus.pending;
        state.phase = "queued";
        state.reason = reason.length > 0 ? reason : plan.reason;
        state.exePath = plan.exePath;
        state.packageDir = plan.workingDir;
        state.startedAt = rebuildStamp(Clock.currTime);
        writeRebuildState(plan.workingDir, state);
    }
    try
        spawnProcess(argv, stdin, stdout, stderr, null,
            Config.detached | Config.suppressConsole);
    catch (Exception)
        return false;
    return true;
}

/// Assemble a plan for the running build. `exePath` and `waitPid` are passed in
/// rather than read here so the shaping stays testable.
RebuildPlan planRebuild(string stateDirectory, bool rebuild, int waitPid,
    string exePath)
{
    RebuildPlan plan;
    plan.exePath = exePath;
    plan.waitPid = waitPid;
    plan.rebuild = rebuild;
    plan.logPath = stateDirectory.length > 0
        ? buildPath(stateDirectory, "rebuild.log") : "rebuild.log";
    plan.workingDir = findBuildDirectory(exePath);
    return plan;
}

/// True when `path` can be opened for writing, i.e. no running process holds it
/// as its image. A missing file counts as free. Deliberately `r+`, not `w`, so
/// a locked file reports as locked rather than truncating.
private bool canWrite(string path)
{
    if (path.length == 0 || !exists(path)) return true;
    try
    {
        auto file = File(path, "r+");
        file.close();
        return true;
    }
    catch (Exception)
        return false;
}

// ===========================================================================
// Progress window: a small always-on-top Win32 status display
// ===========================================================================
// The app is closed while a full rebuild runs, so the feedback has to come from
// the agent. Plain Win32 with no Aurora dependency: the moment this window is
// most needed is the moment the app is broken.

version (Windows)
{

private __gshared Mutex _progressMutex;

// The paint path locks this, and `UpdateWindow` paints immediately, so it must
// exist before the window is created.
static this()
{
    _progressMutex = new Mutex();
}

private __gshared string _progressTitle = "Aurora OpenCode";
private __gshared string _progressDetail;
private __gshared string _progressPhase;
private __gshared double _progressFraction = -1.0;
private __gshared HWND _progressHwnd;
private __gshared bool _progressThreadRunning;
private __gshared Thread _progressThread;

private enum windowWidth = 460;
private enum windowHeight = 148;

private COLORREF rgb(ubyte r, ubyte g, ubyte b)
{
    return cast(COLORREF) (r | (cast(int) g << 8) | (cast(int) b << 16));
}

/**
 * A NUL-terminated UTF-16 copy of `text`. The result must be held in a local
 * across the Win32 call that consumes it: `toUTF16` returns a value whose
 * buffer nothing else keeps alive.
 */
private wstring wideString(string text)
{
    return toUTF16(text) ~ "\0"w;
}

/// Paint the whole window: background, title, phase, bar and detail line.
private void drawProgress(HWND hwnd)
{
    PAINTSTRUCT paint;
    auto dc = BeginPaint(hwnd, &paint);
    scope (exit) EndPaint(hwnd, &paint);

    RECT client;
    GetClientRect(hwnd, &client);
    auto background = CreateSolidBrush(rgb(24, 24, 28));
    FillRect(dc, &client, background);
    DeleteObject(background);
    SetBkMode(dc, TRANSPARENT);

    string title, detail, phase;
    double fraction;
    _progressMutex.lock();
    scope (exit) _progressMutex.unlock();
    title = _progressTitle;
    detail = _progressDetail;
    phase = _progressPhase;
    fraction = _progressFraction;

    SetTextColor(dc, rgb(240, 240, 245));
    RECT titleRect = client;
    titleRect.left = 20;
    titleRect.top = 14;
    titleRect.right -= 20;
    titleRect.bottom = titleRect.top + 28;
    auto titleWide = wideString(title);
    DrawTextW(dc, titleWide.ptr, -1, &titleRect, DT_LEFT | DT_SINGLELINE);

    SetTextColor(dc, rgb(170, 175, 190));
    RECT phaseRect = titleRect;
    phaseRect.top = titleRect.bottom;
    phaseRect.bottom = phaseRect.top + 22;
    auto phaseWide = wideString(phase);
    DrawTextW(dc, phaseWide.ptr, -1, &phaseRect, DT_LEFT | DT_SINGLELINE);

    // The bar: a darker track, then the filled portion. An unknown duration
    // sweeps on a fixed stride, so the window keeps moving while a step of
    // indeterminate length runs - a frozen bar and a hung tool look identical.
    RECT track;
    track.left = 20;
    track.right = client.right - 20;
    track.top = client.bottom - 54;
    track.bottom = track.top + 10;
    auto trackBrush = CreateSolidBrush(rgb(46, 48, 56));
    FillRect(dc, &track, trackBrush);
    DeleteObject(trackBrush);

    double shown = fraction;
    if (shown < 0.0)
        shown = cast(double) (GetTickCount() % 2400) / 2400.0;
    if (shown > 1.0) shown = 1.0;
    if (shown < 0.02) shown = 0.02;
    RECT fill = track;
    auto fillWidth = cast(int) (cast(long) (track.right - track.left) * shown);
    fill.right = track.left + fillWidth;
    auto fillBrush = CreateSolidBrush(rgb(96, 176, 240));
    FillRect(dc, &fill, fillBrush);
    DeleteObject(fillBrush);

    SetTextColor(dc, rgb(140, 145, 158));
    RECT detailRect;
    detailRect.left = 20;
    detailRect.right = client.right - 20;
    detailRect.top = track.bottom + 10;
    detailRect.bottom = detailRect.top + 22;
    auto detailWide = wideString(detail);
    DrawTextW(dc, detailWide.ptr, -1, &detailRect,
        DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
}

private extern (Windows) LRESULT progressProc(HWND hwnd, UINT message,
    WPARAM wParam, LPARAM lParam) nothrow
{
    switch (message)
    {
        case WM_PAINT:
            try drawProgress(hwnd);
            catch (Throwable) {}
            return 0;
        case WM_ERASEBKGND:
            return 1;
        case WM_TIMER:
            // Repainted on a timer so the unknown-duration sweep keeps moving.
            InvalidateRect(hwnd, null, TRUE);
            return 0;
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
        case WM_CLOSE:
            // A status display, not a control surface: closing it must not
            // cancel the rebuild halfway through.
            DestroyWindow(hwnd);
            return 0;
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

private void progressWindowThread()
{
    try
        runProgressWindowThread();
    catch (Throwable) {}
    _progressThreadRunning = false;
}

private void runProgressWindowThread()
{
    immutable className = "AuroraRebuildProgress";
    // Held in locals for the whole call: the window class keeps using these
    // strings after `RegisterClassW` returns.
    auto classNameWide = wideString(className);
    auto windowTitleWide = wideString(_progressTitle);
    auto instance = GetModuleHandleW(null);

    WNDCLASSW definition;
    definition.lpfnWndProc = &progressProc;
    definition.hInstance = instance;
    definition.lpszClassName = classNameWide.ptr;
    definition.hbrBackground = null;
    RegisterClassW(&definition);

    const style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU;
    auto hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        classNameWide.ptr, windowTitleWide.ptr,
        style, CW_USEDEFAULT, CW_USEDEFAULT, windowWidth, windowHeight,
        null, null, instance, null);
    if (hwnd is null) return;
    _progressHwnd = hwnd;
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    SetTimer(hwnd, 1, 120, null);

    MSG message;
    while (GetMessageW(&message, null, 0, 0) > 0)
    {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    _progressHwnd = null;
}

/// Show the window. Safe to call once; later calls only update it.
void openProgressWindow(string title)
{
    _progressMutex.lock();
    _progressTitle = title;
    _progressMutex.unlock();
    if (_progressThreadRunning) return;
    _progressThreadRunning = true;
    try
    {
        _progressThread = new Thread(&progressWindowThread);
        _progressThread.start();
    }
    catch (Throwable)
    {
        _progressThreadRunning = false;
        return;
    }
    // Wait briefly for the window to exist, so a fast first step still shows.
    foreach (_; 0 .. 20)
    {
        if (_progressHwnd !is null) return;
        Thread.sleep(25.msecs);
    }
}

/// Update the displayed phase. `fraction` below zero means unknown duration.
void setProgress(string phase, string detail, double fraction)
{
    _progressMutex.lock();
    _progressPhase = phase;
    _progressDetail = detail;
    _progressFraction = fraction;
    _progressMutex.unlock();
    if (_progressHwnd !is null)
        InvalidateRect(_progressHwnd, null, TRUE);
}

void closeProgressWindow()
{
    if (_progressHwnd !is null)
        PostMessageW(_progressHwnd, WM_CLOSE, 0, 0);
    // The window owns its message loop; closing it drains the queue and ends
    // the thread. Wait for that rather than killing the thread from outside.
    foreach (_; 0 .. 40)
    {
        if (!_progressThreadRunning) return;
        Thread.sleep(25.msecs);
    }
}

}

else
{

void openProgressWindow(string title) {}
void setProgress(string phase, string detail, double fraction) {}
void closeProgressWindow() {}

}

// ===========================================================================
// Agent: the detached copy of the app that does the work
// ===========================================================================
// A copy of this executable, run with `rebuildHelperFlag`, outlives the app and
// can therefore replace it. It is deliberately dependency-free (standard
// library and Win32 only) because it has to keep working when the app under it
// is broken.
//
// Usage:
//   aurora-opencode-pro.exe --aurora-rebuild-helper
//       --exe <app.exe> [--dir <packageDir>] [--log <logPath>] [--pid <pid>]
//       [--build <type>] [--timeout <seconds>] [--no-rebuild]
//       [--max-restarts <n>] [--force]

private struct HelperJob
{
    /// The executable to rebuild in place and relaunch.
    string exePath;
    /// Package directory holding the DUB recipe; empty means no rebuild.
    string packageDir;
    /// Append-only progress log.
    string logPath;
    string buildType = "release";
    /// Why the rebuild was requested, carried from the app so both agree.
    string reason;
    /// Only used to name the process in the log.
    int waitPid;
    int timeoutSeconds = 900;
    /// Pass `--force` to DUB: rebuild every package even when up to date.
    bool force;
    bool rebuild = true;
    /// Give up after this many unexpected exits, so a crash at startup does not
    /// become an endless restart loop.
    int maxRestarts = 5;
}

private HelperJob parseHelperArgs(string[] args)
{
    HelperJob job;
    size_t index = 2; // args[0] is the image, args[1] is the helper flag.
    while (index < args.length)
    {
        const arg = args[index];
        string take()
        {
            ++index;
            return index < args.length ? args[index] : "";
        }
        if (arg == "--exe") job.exePath = take();
        else if (arg == "--dir") job.packageDir = take();
        else if (arg == "--log") job.logPath = take();
        else if (arg == "--reason") job.reason = take();
        else if (arg == "--build") job.buildType = take();
        else if (arg == "--force") job.force = true;
        else if (arg == "--no-rebuild") job.rebuild = false;
        else if (arg == "--max-restarts")
        {
            const value = take();
            try job.maxRestarts = to!int(value);
            catch (Exception) {}
        }
        else if (arg == "--pid")
        {
            const value = take();
            try job.waitPid = to!int(value);
            catch (Exception) {}
        }
        else if (arg == "--timeout")
        {
            const value = take();
            try job.timeoutSeconds = to!int(value);
            catch (Exception) {}
        }
        ++index;
    }
    return job;
}

/**
 * The directory that owns the shared ledger and artifacts: the package root,
 * matching the app's view, so the record lands where the relaunched app looks.
 */
private string stateRoot(in HelperJob job)
{
    if (job.packageDir.length > 0) return job.packageDir;
    return job.logPath.length > 0 ? dirName(job.logPath) : "";
}

/// Where unexpected exits are summarised, alongside the app's own log.
private string notePath(in HelperJob job)
{
    if (job.logPath.length == 0) return "";
    return buildPath(dirName(job.logPath), "unexpected-exits.log");
}

/// The app's own log, where its `activity:` markers are written.
private string appLogPath(in HelperJob job)
{
    if (job.logPath.length == 0) return "";
    return buildPath(dirName(job.logPath), "logs", "errors.log");
}

private string timestamp()
{
    return rebuildStamp(Clock.currTime) ~ " ";
}

private void appendLine(string logPath, string text)
{
    if (logPath.length == 0) return;
    try mkdirRecurse(dirName(logPath));
    catch (Exception) {}
    try append(logPath, timestamp() ~ text ~ "\n");
    catch (Exception) {}
}

/**
 * Overwrite the ledger the app reads back. `startedAt` is passed in so every
 * transition of one rebuild names the same start; `began` measures elapsed.
 */
private void writeJobState(in HelperJob job, RebuildStatus status, string phase,
    string startedAt, int exitCode, string[] errors, MonoTime began)
{
    RebuildState state;
    state.status = status;
    state.phase = phase;
    state.reason = job.reason;
    state.command = join(dubArgv(job), " ");
    state.exePath = job.exePath;
    state.packageDir = job.packageDir;
    state.startedAt = startedAt;
    state.finishedAt = rebuildStamp(Clock.currTime);
    if (began != MonoTime.init)
        state.durationMs = (MonoTime.currTime - began).total!"msecs";
    state.exitCode = exitCode;
    state.errors = errors;
    writeRebuildState(stateRoot(job), state);
}

/// The DUB command line for the in-place rebuild.
private string[] dubArgv(in HelperJob job)
{
    string[] argv = ["dub", "build", "--build=" ~ job.buildType];
    if (job.force) argv ~= "--force";
    return argv;
}

/**
 * The compiler's own error lines, in order, from a captured build transcript.
 * DMD and DUB both mark these with `Error:` / `error:`; keeping only the
 * matching lines turns pages of progress output into the handful that explain
 * the failure.
 */
private string[] errorLines(string output)
{
    string[] found;
    size_t start;
    while (start < output.length)
    {
        auto end = output.indexOf('\n', start);
        if (end < 0) end = output.length;
        const line = strip(output[start .. end]);
        if (line.indexOf("Error:") >= 0 || line.indexOf("error:") >= 0)
            found ~= line;
        if (end == output.length) break;
        start = end + 1;
    }
    return found;
}

/// Keep a report bounded: the tail is what a reader needs.
private string tailText(string text, size_t maxChars)
{
    if (text.length <= maxChars) return text;
    return "...(earlier output omitted)...\n" ~ text[text.length - maxChars .. $];
}

/// Write the failed-build summary: command, location, exit code, extracted
/// compiler errors, and the tail of the full output.
private void writeBuildReport(in HelperJob job, string[] argv, int code,
    string output, const(string)[] errors)
{
    const path = rebuildReportPath(stateRoot(job));
    if (path.length == 0) return;
    string text;
    text ~= "Aurora OpenCode rebuild report\n";
    text ~= "time:    " ~ to!string(Clock.currTime) ~ "\n";
    text ~= "command: " ~ join(argv, " ") ~ "\n";
    text ~= "dir:     " ~ job.packageDir ~ "\n";
    text ~= "exit:    " ~ to!string(code) ~ "\n";
    text ~= "\ncompiler errors (" ~ to!string(errors.length) ~ "):\n";
    if (errors.length == 0)
        text ~= "  (no line matched 'error:'; see " ~
            buildLogPath(stateRoot(job)) ~ " for the full output)\n";
    else
        foreach (line; errors)
            text ~= "  " ~ line ~ "\n";
    text ~= "\nfull output (tail):\n" ~ tailText(output, 12_000) ~ "\n";
    try
    {
        mkdirRecurse(dirName(path));
        write(path, text);
    }
    catch (Exception) {}
}

/// Put the pre-build copy of the app exe back after a failed or truncated
/// build, so a restart can never leave the app unlaunchable. The linker
/// truncates the target before writing it, so a link that fails mid-write
/// leaves a 0-byte image even when the exit code is not meaningful.
private void restoreExe(string exePath, string backup, bool haveBackup,
    string logPath)
{
    if (!haveBackup || exePath.length == 0) return;
    try
    {
        copy(backup, exePath);
        appendLine(logPath, "restored " ~ exePath ~ " from " ~ backup);
    }
    catch (Exception error)
        appendLine(logPath, "could not restore the exe: " ~ error.msg);
}

/**
 * Run one DUB build and validate its output. `argv` is the command;
 * `targetExe` is the file that must exist and be non-empty afterwards.
 * `backupTarget` guards an in-place build, whose linker truncates the target
 * before writing it, by keeping a copy to restore on failure.
 */
private bool runDub(in HelperJob job, string[] argv, string targetExe,
    bool backupTarget, out int exitCode, out string[] errors)
{
    exitCode = 0;
    errors = null;
    const outputPath = buildLogPath(stateRoot(job));
    File sink;
    bool haveSink;
    if (outputPath.length > 0)
    {
        try
        {
            mkdirRecurse(dirName(outputPath));
            sink = File(outputPath, "w");
            haveSink = true;
        }
        catch (Exception) {}
    }
    const backup = targetExe.length > 0 ? targetExe ~ ".bak" : "";
    bool haveBackup;
    if (backupTarget && targetExe.length > 0 && exists(targetExe))
    {
        try
        {
            copy(targetExe, backup);
            haveBackup = true;
        }
        catch (Exception error)
            appendLine(job.logPath,
                "could not back up the exe: " ~ error.msg);
    }
    int code;
    try
    {
        // `dub` is a console program and this agent runs without a console, so
        // a bare spawn would flash a console window for the whole build.
        // `suppressConsole` keeps it (and its `cmd /c` post-build steps)
        // invisible while stdout/stderr still land in the capture file.
        auto pid = spawnProcess(argv,
            stdin, haveSink ? sink : stdout, haveSink ? sink : stderr, null,
            Config.suppressConsole, job.packageDir);
        code = wait(pid);
    }
    catch (Exception error)
    {
        if (haveSink) sink.close();
        appendLine(job.logPath, "dub could not be started: " ~ error.msg);
        errors = ["dub could not be started: " ~ error.msg];
        if (haveBackup)
            restoreExe(targetExe, backup, haveBackup, job.logPath);
        return false;
    }
    if (haveSink) sink.close();
    exitCode = code;
    const output = haveSink && exists(outputPath) ? readText(outputPath) : "";
    errors = errorLines(output);
    const firstError = errors.length > 0 ? errors[0]
        : "(no compiler error line; see " ~ outputPath ~ ")";
    // A zero exit code is not enough: the target must exist and be non-empty.
    if (code != 0 || targetExe.length == 0 || !exists(targetExe) ||
        getSize(targetExe) == 0)
    {
        appendLine(job.logPath, "build failed (exit " ~ to!string(code) ~
            "; target " ~ (targetExe.length == 0 ? "unspecified"
                : (exists(targetExe)
                    ? to!string(getSize(targetExe)) ~ " bytes"
                    : "missing")) ~ "); keeping the previous binary");
        appendLine(job.logPath, "build error: " ~ firstError);
        writeBuildReport(job, argv, code, output, errors);
        const appLog = appLogPath(job);
        if (appLog.length > 0)
            appendLine(appLog, "[ERROR] rebuild failed: " ~ firstError);
        // Shown on screen, not just on disk: a rebuild that silently reopens
        // the previous binary looks like nothing happened at all.
        setProgress("Rebuild failed: " ~ firstError,
            "see " ~ rebuildReportPath(stateRoot(job)), 1.0);
        if (haveBackup)
        {
            if (targetExe.length > 0 && exists(targetExe))
            {
                try remove(targetExe);
                catch (Exception) {}
            }
            restoreExe(targetExe, backup, haveBackup, job.logPath);
        }
        return false;
    }
    // A good build clears any report left by an earlier failure.
    const report = rebuildReportPath(stateRoot(job));
    if (report.length > 0 && exists(report))
    {
        try remove(report);
        catch (Exception) {}
    }
    return true;
}

private bool waitForUnlock(string exePath, int timeoutSeconds)
{
    const deadline = MonoTime.currTime + seconds(timeoutSeconds);
    while (MonoTime.currTime < deadline)
    {
        if (canWrite(exePath)) return true;
        Thread.sleep(200.msecs);
    }
    return canWrite(exePath);
}

/// Name a process exit code. `0xC0000005` and friends are the exception codes
/// Windows uses as the exit status of a process that died on a fault.
private string describeExitCode(int code)
{
    if (code == 0) return "clean exit";
    switch (cast(uint) code)
    {
        case 0xC0000005: return "access violation";
        case 0xC0000409: return "fast fail (stack buffer overrun, or a " ~
            "security check / abort that bypasses the normal exception path)";
        case 0xC0000374: return "heap corruption";
        case 0xC00000FD: return "stack overflow";
        case 0xC000001D: return "illegal instruction";
        case 0xC0000094: return "integer divide by zero";
        case 0xC0000017: return "out of memory";
        case 0xC000013A: return "terminated (console control event)";
        case 0x80000003: return "breakpoint";
        default: return "unknown";
    }
}

private string hex(uint value)
{
    char[] digits = "0123456789ABCDEF".dup;
    char[8] buffer;
    foreach (index; 0 .. buffer.length)
    {
        buffer[buffer.length - 1 - index] =
            digits[cast(size_t) (value & 0xF)];
        value >>= 4;
    }
    return "0x" ~ buffer.idup;
}

/// The last line of the app log containing `marker`, or `fallback`.
private string lastLogLine(in HelperJob job, string marker, string fallback)
{
    const appLog = appLogPath(job);
    if (appLog.length == 0 || !exists(appLog)) return "unknown";
    try
    {
        const text = readText(appLog);
        const index = text.lastIndexOf(marker);
        if (index < 0) return fallback;
        const lineStart = lastIndexOf(text[0 .. index], '\n');
        auto start = lineStart < 0 ? 0 : lineStart + 1;
        auto tail = text[start .. $];
        const stop = tail.indexOf('\n');
        if (stop >= 0) tail = tail[0 .. stop];
        return strip(tail);
    }
    catch (Exception)
        return "unreadable";
}

/**
 * Leave a note asking the next start to pick the conversation back up. The app
 * cannot ask for this itself: the deaths that matter are the ones it never gets
 * to handle. The supervisor is the one process that observes them.
 */
private void requestResume(in HelperJob job, int code)
{
    if (job.logPath.length == 0) return;
    // Idle crashes should reopen the app, but must not silently spend another
    // model request. The app owns this marker and removes it on done/error.
    if (!exists(buildPath(dirName(job.logPath), "turn-active"))) return;
    const path = buildPath(dirName(job.logPath), "restart-resume.json");
    string json;
    json ~= "{\n";
    json ~= "  \"time\": " ~ jsonString(to!string(Clock.currTime)) ~ ",\n";
    json ~= "  \"exitCode\": " ~ to!string(code) ~ ",\n";
    json ~= "  \"cause\": " ~ jsonString(describeExitCode(code)) ~ ",\n";
    json ~= "  \"activity\": " ~ jsonString(
        lastLogLine(job, "activity: ", "none recorded")) ~ "\n";
    json ~= "}\n";
    try write(path, json);
    catch (Exception error)
        appendLine(job.logPath, "could not write the resume request: " ~
            error.msg);
}

/**
 * Record an unexpected exit in one place, in a form meant to be read: the
 * events that ended the app without being asked to, newest last.
 */
private void noteUnexpectedExit(in HelperJob job, int code, int restartNumber)
{
    const path = notePath(job);
    if (path.length == 0) return;
    string text;
    text ~= "\n=== unexpected exit ===\n";
    text ~= "time:        " ~ to!string(Clock.currTime) ~ "\n";
    text ~= "exit code:   " ~ to!string(code) ~ " (" ~ hex(cast(uint) code) ~
        ": " ~ describeExitCode(code) ~ ")\n";
    text ~= "restart:     " ~ to!string(restartNumber) ~ " of " ~
        to!string(job.maxRestarts) ~ "\n";
    text ~= "executable:  " ~ job.exePath ~ "\n";
    text ~= "activity:    " ~ lastLogLine(job, "activity: ",
        "none recorded") ~ "\n";
    text ~= "last error:  " ~ lastLogLine(job, "[ERROR]", "none recorded") ~
        "\n";
    appendLine(path, text);
    appendLine(job.logPath, "unexpected exit " ~ to!string(code) ~ " (" ~
        describeExitCode(code) ~ "); restarting");
    requestResume(job, code);
}

/**
 * Run the app as a child and record how it ended. What the app cannot report
 * about itself is the important case: a fail-fast death terminates the process
 * without calling the app's crash handler, so the exit status is visible only
 * to a parent. Exit code 0 is a normal window close.
 */
private int runChild(in HelperJob job)
{
    appendLine(job.logPath, "running " ~ job.exePath);
    // The app has the window while it runs, so the agent's own window is put
    // away: two windows and one of them stale would be worse than none.
    closeProgressWindow();
    try
    {
        auto pid = spawnProcess([job.exePath], stdin, stdout, stderr, null,
            Config.suppressConsole,
            job.packageDir.length > 0 ? job.packageDir : null);
        const code = wait(pid);
        appendLine(job.logPath, "app exited: " ~ to!string(code) ~ " (" ~
            hex(cast(uint) code) ~ ": " ~ describeExitCode(code) ~ ")");
        if (code != 0)
        {
            openProgressWindow("Aurora OpenCode - restarting");
            setProgress("The app stopped unexpectedly. Restarting...",
                "exit code " ~ to!string(code) ~ " (" ~
                describeExitCode(code) ~ ")", -1.0);
        }
        return code;
    }
    catch (Exception error)
    {
        appendLine(job.logPath, "run failed: " ~ error.msg);
        return 1;
    }
}

/**
 * Run the app, and run it again if it stops without being asked to. A clean
 * exit code means the window was closed on purpose and the supervisor stops
 * there. Anything else is restarted, recorded, and retried up to
 * `maxRestarts` times so a permanent fault cannot spin forever.
 */
private int supervise(in HelperJob job)
{
    int restart = 0;
    while (true)
    {
        if (!exists(job.exePath))
        {
            appendLine(job.logPath,
                "executable missing; supervisor stopping instead of looping");
            return 2;
        }
        const code = runChild(job);
        if (code == 0)
        {
            appendLine(job.logPath, "clean exit; supervisor stopping");
            return 0;
        }
        ++restart;
        noteUnexpectedExit(job, code, restart);
        if (restart >= job.maxRestarts)
        {
            appendLine(job.logPath, "giving up after " ~
                to!string(job.maxRestarts) ~ " unexpected exits; see " ~
                notePath(job));
            return code;
        }
        Thread.sleep(2.seconds);
        appendLine(job.logPath, "restarting (" ~ to!string(restart) ~ "/" ~
            to!string(job.maxRestarts) ~ ")");
    }
}

/**
 * Claim the single-supervisor role. Multiple supervisors race to relaunch the
 * app and turn one crash into several processes and several restart loops.
 * A named mutex makes the role exclusive. `waitMs` lets a successor wait for a
 * predecessor that is still tearing down (a staged rebuild runs while the
 * previous supervisor is alive); a duplicate launcher passes 0 and leaves the
 * existing owner alone instead of waiting.
 */
version (Windows)
{
private bool claimSupervisor(string logPath, int waitMs)
{
    auto name = toUTF16("Local\\AuroraOpenCodeSupervisor") ~ "\0"w;
    auto mutex = CreateMutexW(null, 0, name.ptr);
    if (mutex is null) return true;
    const result = WaitForSingleObject(mutex, cast(uint) waitMs);
    if (result == 0 || result == 0x80) // acquired, or abandoned by a dead owner
        return true;
    CloseHandle(mutex);
    appendLine(logPath, "another supervisor already owns the app; exiting");
    return false;
}
}

else
{
private bool claimSupervisor(string logPath, int waitMs)
{
    return true;
}
}

/// Claim the supervisor role, then run (and keep running) the app. The wait is
/// only non-zero for an app-triggered rebuild, whose predecessor is the
/// supervisor that was watching the app as it closed.
private int superviseClaimed(in HelperJob job)
{
    if (!claimSupervisor(job.logPath, job.waitPid != 0 ? 30_000 : 0))
        return 0;
    return supervise(job);
}

// ===========================================================================
// Agent entry point
// ===========================================================================

/**
 * Entry point for the rebuild agent - a copy of the app invoked with
 * `rebuildHelperFlag`. `source/app.d` dispatches here before touching the GUI.
 */
int runRebuildHelperMode(string[] args)
{
    const job = parseHelperArgs(args);
    if (job.exePath.length == 0)
    {
        stderr.writeln("usage: aurora-opencode-pro " ~ rebuildHelperFlag ~
            " --exe <app.exe> [--dir <packageDir>] [--log <logPath>] " ~
            "[--pid <pid>] [--build <type>] [--timeout <seconds>] " ~
            "[--no-rebuild] [--max-restarts <n>] [--force]");
        return 2;
    }

    const haveBuild = job.rebuild && job.packageDir.length > 0;

    // The app closes itself before this runs, so while it is gone this small
    // window is the only feedback: show it whenever a build is going to happen.
    version (Windows)
        if (haveBuild)
            openProgressWindow("Aurora OpenCode - rebuild");
    scope (exit)
    {
        version (Windows) closeProgressWindow();
    }

    if (!haveBuild)
    {
        appendLine(job.logPath, "no rebuild requested; starting the app");
        return superviseClaimed(job);
    }

    // The app must be closed before its image can be written.
    if (job.waitPid != 0)
    {
        appendLine(job.logPath, "waiting for process " ~
            to!string(job.waitPid) ~ " to exit");
        setProgress("Waiting for Aurora OpenCode to close...", "", -1.0);
    }
    if (!waitForUnlock(job.exePath, job.timeoutSeconds))
    {
        appendLine(job.logPath, "app did not exit; rebuild aborted");
        setProgress("The app did not close; rebuild aborted", "", 1.0);
        return 0;
    }
    Thread.sleep(500.msecs);

    appendLine(job.logPath, "rebuilding: " ~ join(dubArgv(job), " "));
    setProgress("Rebuilding...", "dub build --build=" ~ job.buildType, -1.0);
    const began = MonoTime.currTime;
    const startedAt = strip(timestamp());
    writeJobState(job, RebuildStatus.running, "building", startedAt, 0, null,
        began);
    int exitCode;
    string[] errors;
    if (runDub(job, dubArgv(job), job.exePath, true, exitCode, errors))
    {
        appendLine(job.logPath, "build succeeded");
        setProgress("Rebuild finished. Starting...", "", 1.0);
        writeJobState(job, RebuildStatus.ok, "relaunching", startedAt, 0, null,
            began);
    }
    else
    {
        appendLine(job.logPath,
            "build FAILED; relaunching the previous binary");
        appendLine(job.logPath,
            "compiler errors: " ~ rebuildReportPath(stateRoot(job)));
        writeJobState(job, RebuildStatus.failed, "build-failed", startedAt,
            exitCode, errors, began);
    }
    return superviseClaimed(job);
}
