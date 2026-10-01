/**
 * Self-rebuild: the whole feature in one module.
 *
 * Aurora OpenCode Pro rebuilds itself by handing the work to a detached helper,
 * because Windows keeps a running image locked and `dub` cannot overwrite it
 * while the process is alive. This module owns every part of that flow:
 *
 *   - the protocol       the `rebuildstate.json` schema, its artifact paths,
 *                        and its reader/writer (one definition, no drift);
 *   - the application    building a plan, ensuring the helper is current, and
 *                        launching it detached before the app exits;
 *   - the notice         turning the persisted lifecycle back into "are my
 *                        edits live, and if not why" for the resumed chat;
 *   - the progress        a small always-on-top Win32 window shown while the
 *     window             app is closed for a rebuild;
 *   - the helper         the detached program itself: wait for the lock to
 *                        clear, `dub build`, relaunch, and supervise crashes.
 *
 * The helper is built from this module plus a one-line entry point,
 * `tools/rebuilder.d`, which owns `main` and calls `runRebuilder` below. The
 * application and the `aurora-cli` tool compile this module as an ordinary
 * library module. One file holds the whole feature; one thin file is the
 * executable's entry.
 */
module rebuild;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.array : join;
import std.conv : to;
import std.datetime : Clock, SysTime;
import std.file : append, copy, exists, getSize, mkdirRecurse, readText, remove,
    timeLastModified, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.process : Config, spawnProcess, wait;
import std.stdio : File, stderr, stdin, stdout;
import std.string : indexOf, lastIndexOf, replace, strip;
import std.utf : toUTF16, toUTF16z;

version (Windows)
    import core.sys.windows.windows;

// ===========================================================================
// Protocol: rebuildstate.json and its sibling artifacts
// ===========================================================================
// The whole rebuild is tracked in `rebuildstate.json` in the package
// directory. The app writes `pending` before it hands off and exits; the helper
// drives that record through `running` to `ok` or `failed`; the relaunched app
// reads the file back to decide whether its edits are live.

/// The rebuild lifecycle, as persisted in `rebuildstate.json`.
enum RebuildStatus
{
    none,
    pending,
    running,
    ok,
    failed,
}

/// The wire name of a status, the token stored in the file.
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

/// Parse a status token; unknown text is `none`, never an exception.
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

/// `rebuildstate.json`, the one record of the rebuild lifecycle.
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

/// A snapshot of `rebuildstate.json`. Unknown or absent fields default empty.
struct RebuildState
{
    RebuildStatus status;
    string phase;
    string reason;
    /// The `dub build` command line, recorded so the record says what it ran.
    string command;
    /// The executable rebuilt in place (helper record; empty when unimplemented).
    string exePath;
    /// The package directory the build ran in.
    string packageDir;
    string startedAt;
    string finishedAt;
    long durationMs;
    int exitCode;
    string[] errors;
}

/// Read the persisted lifecycle. A missing or unreadable file is a `none`
/// snapshot, so corrupt state never breaks startup.
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

/// Write the lifecycle record, replacing any earlier one. Returns false when the
/// package directory was unknown or the write failed. The JSON is formatted by
/// hand (fixed key order, two-space indent) so the file reads the same no matter
/// which process wrote it.
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

/// `2026-09-21 17:54:10` in local time, the timestamp form every rebuild
/// artifact uses.
string rebuildStamp(SysTime value)
{
    return value.toLocalTime.toISOExtString.replace("T", " ");
}

/// A JSON string literal, escaped minimally but correctly.
string jsonString(string value)
{
    return "\"" ~ value.replace("\\", "\\\\").replace("\"", "\\\"")
        .replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t") ~
        "\"";
}

// ===========================================================================
// Application side: build a plan and hand off to the helper
// ===========================================================================

/// How far above the executable to look for a DUB recipe before giving up.
private enum int maxBuildDirLevels = 8;

/// The recipe filenames DUB accepts.
private immutable string[] recipeNames = ["dub.json", "dub.sdl"];

/// Everything the helper needs to rebuild and relaunch the app.
struct RebuildPlan
{
    /// The running executable: what gets rebuilt (in place) and relaunched.
    string exePath;
    /// Package directory (the nearest ancestor holding a DUB recipe). Empty
    /// when the binary lives outside a package, in which case the rebuild is
    /// skipped but the relaunch still happens. Also the home of the lifecycle
    /// state file and the build artifacts.
    string workingDir;
    /// Helper output log, under the app's state directory.
    string logPath;
    /// The process the helper waits for: this one, whose exit frees the .exe.
    int waitPid;
    /// Run `dub build` before relaunching.
    bool rebuild;
    /// Why the rebuild was requested, carried into the state file and the
    /// helper's argv so both writers record the same reason.
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
        // Stop at a filesystem root, which dirName leaves unchanged.
        if (parent.length == 0 || parent == directory) break;
        directory = parent;
    }
    return "";
}

/// The standalone rebuilder's location: `bin/aurora-rebuilder.exe` in the
/// package directory, or "" when it has not been built.
string rebuilderPath(in RebuildPlan plan)
{
    if (plan.workingDir.length == 0) return "";
    const candidate = buildPath(plan.workingDir, "bin", "aurora-rebuilder.exe");
    return exists(candidate) ? candidate : "";
}

/// The helper source files whose change must produce a fresh helper binary.
/// `dub.json` is included because it is the recipe: a new source path or link
/// flag changes how the helper must be built.
private immutable string[] rebuilderSources =
    ["shared/rebuild.d", "tools/rebuilder.d", "dub.json"];

/**
 * True when `dir` is Aurora OpenCode's own package: it ships this module's
 * source. Used both to decide whether the running app can rebuild itself and to
 * gate the agent-facing rebuild tool and its system-prompt awareness, so a
 * packaged copy with no sources never offers a rebuild it cannot perform.
 */
bool isAuroraProject(string dir)
{
    if (dir.length == 0) return false;
    return exists(buildPath(dir, "shared", "rebuild.d"));
}

/// The argv for the detached helper process.
string[] rebuildHelperArgv(in RebuildPlan plan)
{
    const helper = rebuilderPath(plan);
    if (helper.length == 0)
        return [];
    string[] argv = [helper, "--exe", plan.exePath];
    if (plan.workingDir.length > 0)
        argv ~= ["--dir", plan.workingDir];
    if (plan.logPath.length > 0)
        argv ~= ["--log", plan.logPath];
    argv ~= ["--pid", to!string(plan.waitPid)];
    if (plan.reason.length > 0)
        argv ~= ["--reason", plan.reason];
    // `--run` keeps the restarted app as the helper's child, so the helper can
    // record how it ended; `--supervise` also brings it back after an
    // unexpected exit. The exit code matters because a fail-fast death never
    // reaches the app's own exception filter, so the app cannot report it.
    argv ~= "--run";
    argv ~= "--supervise";
    if (!plan.rebuild)
        argv ~= "--no-rebuild";
    return argv;
}

/**
 * Start the helper detached, so it keeps running after this process exits. The
 * returned `Pid` is deliberately discarded: a detached process is not ours to
 * wait for or kill. Returns false when the helper could not be started, or when
 * it has not been built, so the caller can keep the window open instead of
 * exiting into nothing.
 */
bool launchRebuild(in RebuildPlan plan, string reason = "")
{
    // The helper is a separate binary, so nothing else refreshes it when this
    // source or the protocol changes. Make sure it is current before handing
    // off; a stale helper would reintroduce bugs the app already fixed.
    if (plan.rebuild) ensureRebuilder(plan);
    auto argv = rebuildHelperArgv(plan);
    if (argv.length == 0)
    {
        try stderr.writeln("rebuild helper missing: build it with " ~
            "`dub build --config=rebuilder`");
        catch (Exception) {}
        return false;
    }
    // Record the request before exiting. The helper overwrites this record as
    // it advances; if the helper never starts, the `pending` record still
    // explains why the app came back with no new build.
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

/**
 * Make sure the detached helper exists and is newer than the sources it is
 * built from. The helper is a separate program, so nothing rebuilds it when the
 * app's source changes: a stale `bin/aurora-rebuilder.exe` silently
 * reintroduces bugs, and a missing one makes every rebuild fail. The app is the
 * one process positioned to fix this: it runs inside the package, and when it
 * was launched without a supervisor no helper is running to hold the image
 * locked.
 *
 * Best-effort: any failure leaves the existing helper alone. Returns true when a
 * helper is present afterwards.
 */
bool ensureRebuilder(in RebuildPlan plan)
{
    const helper = rebuilderPath(plan);
    if (plan.workingDir.length == 0 || !isAuroraProject(plan.workingDir))
        return helper.length > 0;

    bool haveHelper = helper.length > 0;
    SysTime helperTime = SysTime.init;
    if (haveHelper)
    {
        try helperTime = timeLastModified(helper);
        catch (Exception) haveHelper = false;
    }
    bool stale = !haveHelper;
    if (haveHelper)
        foreach (relative; rebuilderSources)
        {
            const path = buildPath(plan.workingDir, relative);
            try
            {
                if (exists(path) && timeLastModified(path) > helperTime)
                {
                    stale = true;
                    break;
                }
            }
            catch (Exception) {}
        }
    if (!stale) return true;

    // If the helper is the running supervisor (the usual case) its image is
    // locked: dub cannot replace it and the link would fail. Leave it alone and
    // refresh on the next unsupervised start.
    if (haveHelper && !canWrite(helper)) return true;

    // Build only the helper config; this writes `bin/aurora-rebuilder.exe` and
    // never touches the running app image, so it is safe in-process. Output is
    // captured next to the other rebuild artifacts for diagnosis.
    const logDir = plan.logPath.length > 0 ? dirName(plan.logPath) : "";
    const logPath = logDir.length > 0
        ? buildPath(logDir, "rebuilder-build.log") : "";
    File sink;
    bool haveSink;
    if (logPath.length > 0)
    {
        try
        {
            mkdirRecurse(logDir);
            sink = File(logPath, "w");
            haveSink = true;
        }
        catch (Exception) haveSink = false;
    }
    try
    {
        auto pid = spawnProcess(
            ["dub", "build", "--config=rebuilder", "--build=release"],
            stdin, haveSink ? sink : stdout, haveSink ? sink : stderr, null,
            Config.suppressConsole, plan.workingDir);
        wait(pid);
    }
    catch (Exception)
    {
        if (haveSink) sink.close();
    }
    if (haveSink) sink.close();
    return rebuilderPath(plan).length > 0;
}

/// True when `path` can be opened for writing, i.e. no running process holds it
/// as its image. A missing file counts as free. Deliberately `r+`, not `w`, so a
/// locked file reports as locked rather than truncating.
bool canWrite(string path)
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
// Notice: what the resumed conversation is told
// ===========================================================================

/// The rebuild lifecycle as the app needs to report it: what happened, whether
/// the running binary includes the edits, and the errors to quote when it does
/// not.
struct RebuildOutcome
{
    /// A lifecycle record existed (i.e. a rebuild was recorded at all).
    bool found;
    RebuildStatus status;
    string phase;
    string reason;
    string startedAt;
    string finishedAt;
    long durationMs;
    int exitCode;
    string[] errors;
    /// The failed-build report text, when one was written ("" otherwise).
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
 * A rebuild that never reached a verdict. Only `running` qualifies: the helper
 * advanced the record and began building, yet we are already running again, so
 * the build did not finish and the edits are not live. `pending` is excluded -
 * it means no helper ever took the record over, which the caller resolves by
 * source staleness rather than declaring failure from silence.
 */
bool rebuildIncomplete(in RebuildOutcome outcome)
{
    return outcome.found && outcome.status == RebuildStatus.running;
}

/// The status token for display, matching the helper's vocabulary.
string rebuildStatusLabel(RebuildStatus status)
{
    return rebuildStatusName(status);
}

/**
 * Read the persisted rebuild outcome from the package directory. A missing or
 * unreadable state file yields `found == false`, which the caller treats as
 * "no rebuild on record".
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
        // The report file is the full record; when it is missing, fall back to
        // the error lines the state itself stored.
        if (outcome.report.length == 0 && outcome.errors.length > 0)
            outcome.report = "compiler errors (" ~
                to!string(outcome.errors.length) ~ "):\n  " ~
                join(outcome.errors, "\n  ") ~ "\n";
    }
    return outcome;
}

// ===========================================================================
// Progress window: a small always-on-top Win32 status display
// ===========================================================================
// The app being rebuilt is closed while the helper runs, so the feedback has to
// come from the tool rather than from the app. It is deliberately plain Win32
// with no Aurora dependency: the moment this window is most needed is the
// moment the app is broken.

version (Windows)
{

private __gshared Mutex _progressMutex;

// The paint path locks this, and `UpdateWindow` paints immediately, so it has
// to exist before the window is created.
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
 * across the Win32 call that consumes it: `toUTF16z` returns a bare pointer
 * whose buffer nothing keeps alive.
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
        {
            // A window procedure must not throw across the Win32 boundary, so
            // the drawing is isolated here.
            try drawProgress(hwnd);
            catch (Throwable) {}
            return 0;
        }
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
            // The window is a status display, not a control surface: closing it
            // must not cancel the rebuild halfway through.
            DestroyWindow(hwnd);
            return 0;
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

private void progressWindowThread()
{
    // The window is a convenience, never a requirement: a fault while building
    // it must not take down the tool that is doing the actual work.
    try
        runProgressWindowThread();
    catch (Throwable) {}
    _progressThreadRunning = false;
}

private void runProgressWindowThread()
{
    immutable className = "AuroraProgressWindow";
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
// Detached helper
// ===========================================================================
// The application cannot rebuild itself: Windows keeps a running image locked,
// so the rebuild has to happen in a process that outlives the app. The helper
// is deliberately dependency-free (standard library and Win32 only) because it
// has to keep working when the app under it is broken.
//
// Usage:
//   aurora-rebuilder --exe <app.exe> [--dir <packageDir>] [--log <logPath>]
//                    [--pid <pid>] [--build <type>] [--timeout <seconds>]
//                    [--no-rebuild] [--run] [--supervise] [--max-restarts <n>]
//                    [--force]

private struct Options
{
    /// The executable to rebuild in place and relaunch.
    string exePath;
    /// Package directory holding the DUB recipe; empty means no rebuild.
    string packageDir;
    /// Append-only progress log.
    string logPath;
    string buildType = "release";
    /// Why the rebuild was requested, carried from the app so the state record
    /// and the app agree on the reason.
    string reason;
    /// Only used to name the process in the log.
    int waitPid;
    int timeoutSeconds = 600;
    /// Pass `--force` to DUB: rebuild every package even when up to date.
    bool force;
    bool rebuild = true;
    /// Launch the app as a child and wait for it, recording how it ended
    /// instead of detaching.
    bool run;
    /// Keep the app running: relaunch it after an unexpected exit rather than
    /// leaving the user with nothing.
    bool supervise;
    /// Give up after this many unexpected exits, so a crash at startup does not
    /// become an endless restart loop.
    int maxRestarts = 5;
}

/// Where unexpected exits are summarised, alongside the app's own log.
private string notePath(in Options options)
{
    if (options.logPath.length == 0) return "";
    return buildPath(dirName(options.logPath), "unexpected-exits.log");
}

/**
 * Record an unexpected exit in one place, in a form meant to be read: the events
 * that ended the app without being asked to, newest last, so the question "what
 * happened while I was not looking" has a short answer.
 */
private void noteUnexpectedExit(in Options options, int code, int restartNumber)
{
    const path = notePath(options);
    if (path.length == 0) return;
    string text;
    text ~= "\n=== unexpected exit ===\n";
    text ~= "time:        " ~ to!string(Clock.currTime) ~ "\n";
    text ~= "exit code:   " ~ to!string(code) ~ " (" ~ hex(cast(uint) code) ~
        ": " ~ describeExitCode(code) ~ ")\n";
    text ~= "restart:     " ~ to!string(restartNumber) ~ " of " ~
        to!string(options.maxRestarts) ~ "\n";
    text ~= "executable:  " ~ options.exePath ~ "\n";
    text ~= "activity:    " ~ recentActivity(options) ~ "\n";
    // The fault itself: a native access-violation line with its address, or an
    // `uncaught Error:` with a symbolized trace.
    text ~= "last error:  " ~ recentError(options) ~ "\n";
    appendLine(path, text);
    // Mirrored into the app's log as a single line, so the two files agree on
    // when the app went down.
    appendLine(options.logPath, "unexpected exit " ~ to!string(code) ~ " (" ~
        describeExitCode(code) ~ "); restarting");
    requestResume(options, code);
}

/**
 * Leave a note asking the next start to pick the conversation back up. The app
 * cannot ask for this itself: the deaths that matter are the ones it never gets
 * to handle. The supervisor is the one process that observes them, so it writes
 * the request, and the app consumes it on startup.
 */
private void requestResume(in Options options, int code)
{
    if (options.logPath.length == 0) return;
    // Idle crashes should reopen the app, but must not silently spend another
    // model request. The app owns this marker and removes it on done/error/stop.
    if (!exists(buildPath(dirName(options.logPath), "turn-active"))) return;
    const path = buildPath(dirName(options.logPath), "restart-resume.json");
    string json;
    json ~= "{\n";
    json ~= "  \"time\": " ~ jsonString(to!string(Clock.currTime)) ~ ",\n";
    json ~= "  \"exitCode\": " ~ to!string(code) ~ ",\n";
    json ~= "  \"cause\": " ~ jsonString(describeExitCode(code)) ~ ",\n";
    json ~= "  \"activity\": " ~ jsonString(recentActivity(options)) ~ "\n";
    json ~= "}\n";
    try write(path, json);
    catch (Exception error)
        appendLine(options.logPath, "could not write the resume request: " ~
            error.msg);
}

/// The app's own log, where its `activity:` markers are written. This is a
/// different file from `options.logPath`, which is the supervisor's
/// `restart.log`.
private string appLogPath(in Options options)
{
    if (options.logPath.length == 0) return "";
    return buildPath(dirName(options.logPath), "logs", "errors.log");
}

/// The last `activity:` marker the app wrote, naming the step it was executing
/// when it died. The whole timestamped line is returned so the exit record can
/// be correlated with the app log by time as well as step.
private string recentActivity(in Options options)
{
    return lastLogLine(options, "activity: ", "none recorded");
}

/// The last `[ERROR]` line the app wrote, i.e. the crash banner itself. The
/// address on the native line is resolved against the archived `.pdb` on the
/// next launch; naming it here keeps the exit summary self-contained.
private string recentError(in Options options)
{
    return lastLogLine(options, "[ERROR]", "none recorded");
}

/// The last line of the app log containing `marker`, or `fallback` when there
/// is no log, no marker, or the log cannot be read.
private string lastLogLine(in Options options, string marker, string fallback)
{
    const appLog = appLogPath(options);
    if (appLog.length == 0 || !exists(appLog)) return "unknown";
    try
    {
        const text = readText(appLog);
        const index = text.lastIndexOf(marker);
        if (index < 0) return fallback;
        // Walk back to the start of the line so the timestamp prefix is kept.
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
 * Run the app, and run it again if it stops without being asked to. A clean
 * exit code means the window was closed on purpose and the supervisor stops
 * there. Anything else is restarted, recorded in `unexpected-exits.log`, and
 * the cycle repeats up to `maxRestarts` times so a permanent fault cannot spin
 * forever.
 */
private int superviseApp(in Options options)
{
    int restart = 0;
    while (true)
    {
        if (!exists(options.exePath))
        {
            appendLine(options.logPath,
                "executable missing; supervisor stopping instead of looping");
            return 2;
        }
        const code = runAndReport(options);
        if (code == 0)
        {
            appendLine(options.logPath, "clean exit; supervisor stopping");
            return 0;
        }
        ++restart;
        noteUnexpectedExit(options, code, restart);
        if (restart >= options.maxRestarts)
        {
            appendLine(options.logPath, "giving up after " ~
                to!string(options.maxRestarts) ~ " unexpected exits; see " ~
                notePath(options));
            return code;
        }
        // A short pause keeps a fault that fires during startup from filling
        // the disk with process launches.
        Thread.sleep(2.seconds);
        appendLine(options.logPath, "restarting (" ~ to!string(restart) ~ "/" ~
            to!string(options.maxRestarts) ~ ")");
    }
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

/**
 * Run the app as a child and record how it ended. What the app cannot report
 * about itself is the important case: a fail-fast death terminates the process
 * without calling the app's crash handler, so the exit status is visible only
 * to a parent. Exit code 0 is a normal window close.
 */
private int runAndReport(in Options options)
{
    appendLine(options.logPath, "running " ~ options.exePath);
    // The app has the window while it runs, so the helper's own window is put
    // away: two windows and one of them stale would be worse than none.
    closeProgressWindow();
    try
    {
        auto pid = spawnProcess([options.exePath], stdin, stdout, stderr, null,
            Config.suppressConsole,
            options.packageDir.length > 0 ? options.packageDir : null);
        const code = wait(pid);
        appendLine(options.logPath, "app exited: " ~ to!string(code) ~ " (" ~
            hex(cast(uint) code) ~ ": " ~ describeExitCode(code) ~ ")");
        // An unexpected end is reported on screen as well as in the log: the
        // app vanishing with no explanation is what makes a crash look random.
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
        appendLine(options.logPath, "run failed: " ~ error.msg);
        return 1;
    }
}

private Options parseArgs(string[] args)
{
    Options options;
    size_t index = 1;
    while (index < args.length)
    {
        const arg = args[index];
        string take()
        {
            ++index;
            return index < args.length ? args[index] : "";
        }
        if (arg == "--exe") options.exePath = take();
        else if (arg == "--dir") options.packageDir = take();
        else if (arg == "--log") options.logPath = take();
        else if (arg == "--reason") options.reason = take();
        else if (arg == "--build") options.buildType = take();
        else if (arg == "--force") options.force = true;
        else if (arg == "--no-rebuild") options.rebuild = false;
        else if (arg == "--run") options.run = true;
        else if (arg == "--supervise") options.supervise = true;
        else if (arg == "--max-restarts")
        {
            const value = take();
            try options.maxRestarts = to!int(value);
            catch (Exception) {}
        }
        else if (arg == "--pid")
        {
            const value = take();
            try options.waitPid = to!int(value);
            catch (Exception) {}
        }
        else if (arg == "--timeout")
        {
            const value = take();
            try options.timeoutSeconds = to!int(value);
            catch (Exception) {}
        }
        ++index;
    }
    return options;
}

/// Wall-clock prefix for one log line, matching the format of `rebuildstate.json`
/// so an exit recorded here can be lined up against the app's own log.
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
 * The directory that owns the shared rebuild state and artifacts: the package
 * root, matching the app's view, so the state file and the report land where
 * the relaunched app looks for them.
 */
private string stateRoot(in Options options)
{
    if (options.packageDir.length > 0) return options.packageDir;
    return options.logPath.length > 0 ? dirName(options.logPath) : "";
}

/**
 * Overwrite the lifecycle record the app reads back. `startedAt` is passed in
 * so every transition of one rebuild names the same start; `began` measures the
 * elapsed time.
 */
private void writeState(in Options options, string status, string phase,
    string startedAt, int exitCode, string[] errors, MonoTime began)
{
    RebuildState state;
    state.status = parseRebuildStatus(status);
    state.phase = phase;
    state.reason = options.reason;
    state.command = join(dubBuildArgv(options), " ");
    state.exePath = options.exePath;
    state.packageDir = options.packageDir;
    state.startedAt = startedAt;
    state.finishedAt = rebuildStamp(Clock.currTime);
    if (began != MonoTime.init)
        state.durationMs = (MonoTime.currTime - began).total!"msecs";
    state.exitCode = exitCode;
    state.errors = errors;
    writeRebuildState(stateRoot(options), state);
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

/// Keep a report bounded: the tail is what a reader needs, not a transcript of
/// every module the compiler touched on the way down.
private string tailText(string text, size_t maxChars)
{
    if (text.length <= maxChars) return text;
    return "...(earlier output omitted)...\n" ~ text[text.length - maxChars .. $];
}

/// Write the failed-build summary: the command, where it ran, the exit code,
/// the extracted compiler errors, and the tail of the full output.
private void writeBuildReport(in Options options, int code, string output,
    const(string)[] errors)
{
    const path = rebuildReportPath(stateRoot(options));
    if (path.length == 0) return;
    string text;
    text ~= "Aurora OpenCode rebuild report\n";
    text ~= "time:    " ~ to!string(Clock.currTime) ~ "\n";
    text ~= "command: " ~ join(dubBuildArgv(options), " ") ~ "\n";
    text ~= "dir:     " ~ options.packageDir ~ "\n";
    text ~= "exit:    " ~ to!string(code) ~ "\n";
    text ~= "\ncompiler errors (" ~ to!string(errors.length) ~ "):\n";
    if (errors.length == 0)
        text ~= "  (no line matched 'error:'; see " ~
            buildLogPath(stateRoot(options)) ~ " for the full output)\n";
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

/// The DUB command line for a rebuild. `--force` is opt-in: when it is present
/// DUB rebuilds every package including the ones already up to date, which is
/// the difference between recompiling one edited package and the whole tree.
private string[] dubBuildArgv(in Options options)
{
    string[] argv = ["dub", "build", "--build=" ~ options.buildType];
    if (options.force) argv ~= "--force";
    return argv;
}

private bool runBuild(in Options options, out int exitCode, out string[] errors)
{
    exitCode = 0;
    errors = null;
    // DUB's output is captured to `build.log` rather than streamed into the
    // maintenance log: a failed compile needs its error lines quoted in the
    // report, and that is only possible if the text can be read back.
    const outputPath = buildLogPath(stateRoot(options));
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
    // Keep a copy of the good exe; a failed link can leave the target empty.
    const backup = options.exePath ~ ".bak";
    bool haveBackup;
    if (options.exePath.length > 0 && exists(options.exePath))
    {
        try
        {
            copy(options.exePath, backup);
            haveBackup = true;
        }
        catch (Exception error)
            appendLine(options.logPath,
                "could not back up the exe: " ~ error.msg);
    }
    int code;
    try
    {
        // `dub` is a console program and this helper runs without a console, so
        // a bare spawn would allocate a visible console window for the whole
        // build. `suppressConsole` keeps it (and its `cmd /c` post-build steps)
        // invisible while stdout/stderr still land in the capture file.
        auto pid = spawnProcess(dubBuildArgv(options),
            stdin, haveSink ? sink : stdout, haveSink ? sink : stderr, null,
            Config.suppressConsole, options.packageDir);
        code = wait(pid);
    }
    catch (Exception error)
    {
        if (haveSink) sink.close();
        appendLine(options.logPath, "dub could not be started: " ~ error.msg);
        errors = ["dub could not be started: " ~ error.msg];
        restoreExe(options.exePath, backup, haveBackup, options.logPath);
        return false;
    }
    if (haveSink) sink.close();
    exitCode = code;
    const output = haveSink && exists(outputPath) ? readText(outputPath) : "";
    errors = errorLines(output);
    const firstError = errors.length > 0 ? errors[0]
        : "(no compiler error line; see " ~ outputPath ~ ")";
    // A zero exit code is not enough: the target must exist and be non-empty.
    if (code != 0 || options.exePath.length == 0 ||
        !exists(options.exePath) || getSize(options.exePath) == 0)
    {
        appendLine(options.logPath, "build failed (exit " ~ to!string(code) ~
            "; exe " ~ (options.exePath.length == 0 ? "unspecified"
                : (exists(options.exePath)
                    ? to!string(getSize(options.exePath)) ~ " bytes"
                    : "missing")) ~ "); restoring the previous binary");
        appendLine(options.logPath, "build error: " ~ firstError);
        writeBuildReport(options, code, output, errors);
        // Named in the app's own log too, so the compiler failure lands where
        // the app's crash summary and the user's usual log both look.
        const appLog = appLogPath(options);
        if (appLog.length > 0)
            appendLine(appLog, "[ERROR] rebuild failed: " ~ firstError);
        // Shown on screen, not just on disk: a rebuild that silently reopens
        // the previous binary looks like nothing happened at all.
        setProgress("Rebuild failed: " ~ firstError,
            "see " ~ rebuildReportPath(stateRoot(options)), 1.0);
        if (options.exePath.length > 0 && exists(options.exePath))
        {
            try remove(options.exePath);
            catch (Exception) {}
        }
        restoreExe(options.exePath, backup, haveBackup, options.logPath);
        return false;
    }
    // A good build clears any report left by an earlier failure, so a stale one
    // never masquerades as the latest result.
    const report = rebuildReportPath(stateRoot(options));
    if (report.length > 0 && exists(report))
    {
        try remove(report);
        catch (Exception) {}
    }
    return true;
}

private bool launchApp(in Options options)
{
    try
    {
        spawnProcess([options.exePath], stdin, stdout, stderr, null,
            Config.detached | Config.suppressConsole,
            options.packageDir.length > 0 ? options.packageDir : null);
        return true;
    }
    catch (Exception error)
    {
        appendLine(options.logPath, "launch failed: " ~ error.msg);
        return false;
    }
}

// ===========================================================================
// Helper entry point
// ===========================================================================

/**
 * Entry point for the standalone `aurora-rebuilder` executable. `tools/rebuilder.d`
 * owns `main` and calls this, so every line of the feature lives in this module.
 */
int runRebuilder(string[] args)
{
    const options = parseArgs(args);
    // Show the progress window before any guard can return early: maintenance
    // that cannot proceed must not look like nothing happened at all.
    version (Windows) openProgressWindow("Aurora OpenCode - maintenance");
    version (Windows) HANDLE supervisorMutex;
    scope (exit)
    {
        version (Windows)
            if (supervisorMutex !is null)
            {
                ReleaseMutex(supervisorMutex);
                CloseHandle(supervisorMutex);
            }
    }
    if (options.exePath.length == 0)
    {
        stderr.writeln("usage: aurora-rebuilder --exe <app.exe> " ~
            "[--dir <packageDir>] [--log <logPath>] [--pid <pid>] " ~
            "[--build <type>] [--timeout <seconds>] [--no-rebuild] [--run] " ~
            "[--supervise] [--max-restarts <n>] [--force]");
        return 2;
    }

    // One parent must own the app. Multiple supervisors race to relaunch it and
    // turn one crash into several processes and several restart loops.
    version (Windows)
    if (options.supervise)
    {
        supervisorMutex = CreateMutexW(null, 0,
            toUTF16z("Local\\AuroraOpenCodeSupervisor"));
        // An in-app rebuild is launched before the current app exits. Its old
        // supervisor releases ownership immediately after that clean exit, so
        // this successor may wait briefly. Unsolicited duplicate launchers do
        // not wait and simply leave the existing owner alone.
        const waitMs = options.waitPid != 0 ? 30_000 : 0;
        const waitResult = supervisorMutex is null ? uint.max :
            WaitForSingleObject(supervisorMutex, waitMs);
        if (waitResult != 0 && waitResult != 0x80) // object / abandoned
        {
            if (supervisorMutex !is null)
            {
                CloseHandle(supervisorMutex);
                supervisorMutex = null;
            }
            appendLine(options.logPath,
                "another supervisor already owns the app; exiting");
            return 0;
        }
    }

    // The window was opened above, before any guard could return early; here we
    // only arrange for it to be closed again on the way out.
    scope (exit)
    {
        version (Windows) closeProgressWindow();
    }

    if (options.waitPid != 0)
    {
        appendLine(options.logPath, "waiting for process " ~
            to!string(options.waitPid) ~ " to exit");
        setProgress("Waiting for the app to close...", "", -1.0);
    }

    if (!waitForUnlock(options.exePath, options.timeoutSeconds))
    {
        // Still locked: the app is alive and this rebuild would be a duplicate.
        appendLine(options.logPath, "app did not exit; rebuild aborted");
        setProgress("The app did not close; rebuild aborted", "", 1.0);
        return 0;
    }

    // The lock can clear a moment before the image is fully released.
    Thread.sleep(500.msecs);

    if (options.rebuild && options.packageDir.length > 0)
    {
        appendLine(options.logPath, "rebuilding: " ~
            join(dubBuildArgv(options), " "));
        setProgress("Rebuilding...", "dub build --build=" ~ options.buildType,
            -1.0);
        const began = MonoTime.currTime;
        const startedAt = strip(timestamp());
        // The app wrote `pending` before it exited; take the record over and
        // mark the build in flight so a helper that dies mid-build is still
        // visible as "not finished" rather than looking like it never ran.
        writeState(options, "running", "building", startedAt, 0, null, began);
        int exitCode;
        string[] errors;
        const rebuilt = runBuild(options, exitCode, errors);
        appendLine(options.logPath, rebuilt ? "build succeeded"
            : "build FAILED; relaunching the previous binary");
        // On failure `runBuild` has already put the first compiler error on
        // screen; overwriting that with a generic line would hide the reason.
        if (rebuilt)
        {
            setProgress("Rebuild finished. Starting...", "", 1.0);
            writeState(options, "ok", "relaunching", startedAt, 0, null, began);
        }
        else
        {
            appendLine(options.logPath,
                "compiler errors: " ~ rebuildReportPath(stateRoot(options)));
            writeState(options, "failed", "build-failed", startedAt, exitCode,
                errors, began);
        }
    }
    else
        appendLine(options.logPath, "rebuild skipped; relaunching as built");

    appendLine(options.logPath, "relaunching " ~ options.exePath);
    if (options.supervise) return superviseApp(options);
    if (options.run) return runAndReport(options);
    return launchApp(options) ? 0 : 1;
}
