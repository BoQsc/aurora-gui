// Detached rebuild-and-relaunch helper for Aurora OpenCode Pro.
//
// The application cannot rebuild itself: Windows keeps a running image locked,
// so `dub` cannot replace the .exe while that process is alive, and the
// rebuild has to happen in a process that outlives the app it is replacing.
//
//   1. wait until the app's .exe can be opened for writing, which is what "the
//      app has exited" means in practice - the file lock is the real
//      constraint, so that is what is polled;
//   2. run `dub build --force` in the package directory, appending output to
//      the log. Note this is `dub build`, not `dub run`: with `dub run` a
//      crashed app and a failed compile both surface as a non-zero result, and
//      the old helper reacted to a crash by relaunching the stale binary -
//      which is how a crash became a crash loop;
//   3. launch the freshly built binary.
//
// It is deliberately dependency-free and shares no code with the app, because
// it has to keep working when the app under it is broken.
//
// Usage:
//   aurora-rebuilder --exe <app.exe> [--dir <packageDir>] [--log <logPath>]
//                    [--pid <pid>] [--build <type>] [--timeout <seconds>]
//                    [--no-rebuild]
module rebuilder;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.datetime : Clock;
import std.file : append, exists, mkdirRecurse, readText;
import std.path : buildPath, dirName;
import std.process : Config, spawnProcess, wait;
import std.stdio : File, stderr, stdin, stdout;
import std.string : indexOf, lastIndexOf, replace, strip;

private struct Options
{
    /// The executable to rebuild in place and relaunch.
    string exePath;
    /// Package directory holding the DUB recipe; empty means no rebuild.
    string packageDir;
    /// Append-only progress log.
    string logPath;
    string buildType = "release";
    /// Only used to name the process in the log.
    int waitPid;
    int timeoutSeconds = 600;
    bool rebuild = true;
    /// Launch the app as a child and wait for it, recording how it ended
    /// instead of detaching. See `runAndReport`.
    bool run;
    /// Keep the app running: relaunch it after an unexpected exit rather than
    /// leaving the user with nothing. See `superviseApp`.
    bool supervise;
    /// Give up after this many unexpected exits, so a crash at startup does
    /// not become an endless restart loop.
    int maxRestarts = 5;
}

/// Where unexpected exits are summarised, alongside the app's own log.
private string notePath(in Options options)
{
    if (options.logPath.length == 0) return "";
    return buildPath(dirName(options.logPath), "unexpected-exits.log");
}

/**
 * Record an unexpected exit in one place, in a form meant to be read.
 *
 * The crash handler, when it runs at all, writes into the app's log among
 * hundreds of ordinary lines. This file holds only the events that ended the
 * app without being asked to, newest last, so the question "what happened
 * while I was not looking" has a short answer.
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
    // `uncaught Error:` with a symbolized trace. Without this the summary named
    // the exit code but not the code that produced it.
    text ~= "last error:  " ~ recentError(options) ~ "\n";
    appendLine(path, text);
    // Mirrored into the app's log as a single line, so the two files agree on
    // when the app went down.
    appendLine(options.logPath, "unexpected exit " ~ to!string(code) ~ " (" ~
        describeExitCode(code) ~ "); restarting");
}

/**
 * The app's own log, where its `activity:` markers are written.
 *
 * This is a different file from `options.logPath`, which is the supervisor's
 * `restart.log`. `recentActivity` used to read `options.logPath`, so it always
 * reported "none recorded" even when the app had recorded exactly which step it
 * was running - the one field meant to explain an unexpected exit was inert.
 */
private string appLogPath(in Options options)
{
    if (options.logPath.length == 0) return "";
    return buildPath(dirName(options.logPath), "logs", "errors.log");
}

/**
 * The last `activity:` marker the app wrote, which names the step it was
 * executing when it died. The app records these precisely because a native
 * fault carries no trace of its own. The whole timestamped line is returned, so
 * the exit record can be correlated with the app log by time as well as step.
 */
private string recentActivity(in Options options)
{
    const appLog = appLogPath(options);
    if (appLog.length == 0 || !exists(appLog)) return "unknown";
    try
    {
        const text = readText(appLog);
        const index = text.lastIndexOf("activity: ");
        if (index < 0) return "none recorded";
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
 * Run the app, and run it again if it stops without being asked to.
 *
 * A clean exit code means the window was closed on purpose and the supervisor
 * stops there. Anything else is an unexpected end - a crash, a fail-fast
 * abort, a kill - and leaving the app closed makes the user the one who has to
 * notice and restart it. Instead it is restarted, the event is written to
 * `unexpected-exits.log` with the exit code and the last recorded activity,
 * and the cycle repeats up to `maxRestarts` times so a permanent fault cannot
 * spin forever.
 */
private int superviseApp(in Options options)
{
    int restart = 0;
    while (true)
    {
        const code = runAndReport(options);
        if (code == 0)
        {
            appendLine(options.logPath, "clean exit; supervisor stopping");
            return 0;
        }
        ++restart;
        noteUnexpectedExit(options, code, restart);
        if (restart > options.maxRestarts)
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

/**
 * The last `[ERROR]` line the app wrote, i.e. the crash banner itself: the
 * `native crash: access violation … at 0x…` line, or the `uncaught Error:` line
 * for a D `Error`. The address on the native line is resolved against the
 * archived `.pdb` on the next launch; naming it here makes the exit summary
 * self-contained instead of pointing at a separate file.
 */
private string recentError(in Options options)
{
    const appLog = appLogPath(options);
    if (appLog.length == 0 || !exists(appLog)) return "unknown";
    try
    {
        const text = readText(appLog);
        const index = text.lastIndexOf("[ERROR]");
        if (index < 0) return "none recorded";
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
            digits[cast(size_t)(value & 0xF)];
        value >>= 4;
    }
    return "0x" ~ buffer.idup;
}

/**
 * Run the app as a child and record how it ended.
 *
 * What the app cannot report about itself is the important case: a fail-fast
 * death (heap corruption, stack cookie, `abort`) terminates the process
 * without calling `SetUnhandledExceptionFilter`, so the app's own crash
 * handler writes nothing and the log stops mid-sentence. The exit status is
 * visible only to a parent, and it names the cause, so a launcher that waits
 * for the app is the only thing that can record those deaths. Exit code 0 is
 * a normal window close.
 */
private int runAndReport(in Options options)
{
    appendLine(options.logPath, "running " ~ options.exePath);
    try
    {
        auto pid = spawnProcess([options.exePath], stdin, stdout, stderr, null,
            Config.none,
            options.packageDir.length > 0 ? options.packageDir : null);
        const code = wait(pid);
        appendLine(options.logPath, "app exited: " ~ to!string(code) ~ " (" ~
            hex(cast(uint) code) ~ ": " ~ describeExitCode(code) ~ ")");
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
        else if (arg == "--build") options.buildType = take();
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

/// Wall-clock prefix for one log line. `restart.log` had no timestamps, so an
/// exit recorded there could not be lined up against the app's own
/// timestamped `errors.log`; the ISO form here matches that file's format.
private string timestamp()
{
    return Clock.currTime.toLocalTime.toISOExtString.replace("T", " ") ~ " ";
}

private void appendLine(string logPath, string text)
{
    if (logPath.length == 0) return;
    try mkdirRecurse(dirName(logPath));
    catch (Exception) {}
    try append(logPath, timestamp() ~ text ~ "\n");
    catch (Exception) {}
}

/// True when the file can be opened for writing, i.e. nothing is holding it as
/// a running image. Deliberately "r+" rather than "a": a missing file must not
/// be created here, because the path being probed is the app's own .exe.
private bool canWrite(string path)
{
    if (!exists(path)) return true;
    try
    {
        auto file = File(path, "r+");
        file.close();
        return true;
    }
    catch (Exception)
        return false;
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

private bool runBuild(in Options options)
{
    File log;
    bool hasLog;
    if (options.logPath.length > 0)
    {
        try
        {
            log = File(options.logPath, "a");
            hasLog = true;
        }
        catch (Exception) {}
    }
    try
    {
        auto pid = spawnProcess(["dub", "build", "--force",
            "--build=" ~ options.buildType],
            stdin, hasLog ? log : stdout, hasLog ? log : stderr, null,
            Config.none, options.packageDir);
        return wait(pid) == 0;
    }
    catch (Exception error)
    {
        appendLine(options.logPath, "dub could not be started: " ~ error.msg);
        return false;
    }
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

int main(string[] args)
{
    const options = parseArgs(args);
    if (options.exePath.length == 0)
    {
        stderr.writeln("usage: aurora-rebuilder --exe <app.exe> " ~
            "[--dir <packageDir>] [--log <logPath>] [--pid <pid>] " ~
            "[--build <type>] [--timeout <seconds>] [--no-rebuild] [--run] " ~
            "[--supervise] [--max-restarts <n>]");
        stderr.writeln("  --run      launch the app as a child and record its " ~
            "exit code (names fail-fast deaths the app cannot report)");
        stderr.writeln("  --supervise  run the app and reopen it after an " ~
            "unexpected exit, recording what happened in unexpected-exits.log");
        return 2;
    }

    if (options.waitPid != 0)
        appendLine(options.logPath, "waiting for process " ~
            to!string(options.waitPid) ~ " to exit");

    if (!waitForUnlock(options.exePath, options.timeoutSeconds))
    {
        // Still locked: the app is alive and this restart would be a duplicate.
        appendLine(options.logPath, "app did not exit; restart aborted");
        return 0;
    }

    // The lock can clear a moment before the image is fully released.
    Thread.sleep(500.msecs);

    if (options.rebuild && options.packageDir.length > 0)
    {
        appendLine(options.logPath, "rebuilding: dub build --force --build=" ~
            options.buildType);
        const rebuilt = runBuild(options);
        appendLine(options.logPath, rebuilt ? "build succeeded"
            : "build FAILED; relaunching the previous binary");
    }
    else
        appendLine(options.logPath, "rebuild skipped; relaunching as built");

    appendLine(options.logPath, "relaunching " ~ options.exePath);
    if (options.supervise) return superviseApp(options);
    if (options.run) return runAndReport(options);
    return launchApp(options) ? 0 : 1;
}
