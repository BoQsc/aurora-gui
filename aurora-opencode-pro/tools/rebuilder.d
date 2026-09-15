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
import std.file : append, exists, mkdirRecurse, remove;
import std.path : buildPath, dirName;
import std.process : Config, spawnProcess, wait;
import std.stdio : File, stderr, stdin, stdout;

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
    /// Launch the app now and rebuild when it exits; see `--reopen`.
    bool reopen;
}

/// Delete leftover symbol/sidecar files from a previous build.
///
/// They are only meaningful for the build that produced them, and leaving them
/// beside a fresh .exe makes the app's startup symbol audit report a mismatch
/// that no longer describes anything real.
private void purgeStaleSymbols(in Options options)
{
    if (options.exePath.length == 0) return;
    auto stem = options.exePath[0 .. $ - 4]; // drop ".exe"
    foreach (ext; [".exe.trace", ".map"])
    {
        const stale = stem ~ ext;
        if (exists(stale))
            try remove(stale);
            catch (Exception) {}
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
        else if (arg == "--reopen") options.reopen = true;
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

private void appendLine(string logPath, string text)
{
    if (logPath.length == 0) return;
    try mkdirRecurse(dirName(logPath));
    catch (Exception) {}
    try append(logPath, text ~ "\n");
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
            "[--build <type>] [--timeout <seconds>] [--no-rebuild] [--run]");
        stderr.writeln("  --run      launch the app as a child and record its " ~
            "exit code (names fail-fast deaths the app cannot report)");
        stderr.writeln("  --reopen   relaunch the app now, then rebuild when " ~
            "it exits: lets an already-running app trigger a rebuild");
        return 2;
    }

    if (options.waitPid != 0)
        appendLine(options.logPath, "waiting for process " ~
            to!string(options.waitPid) ~ " to exit");

    if (options.reopen)
    {
        // Launch the app (or a second copy of it) now, then rebuild the moment
        // that process ends. On the next start the new build is in place.
        // Stale symbols from the previous build are removed first, so the
        // app's startup audit does not report a mismatch that no longer means
        // anything.
        appendLine(options.logPath, "reopen: launching the app before rebuilding");
        if (!launchApp(options))
        {
            appendLine(options.logPath, "reopen: launch failed; rebuilding anyway");
        }
        Thread.sleep(2.seconds);
        if (!waitForUnlock(options.exePath, options.timeoutSeconds))
        {
            appendLine(options.logPath, "reopen: app did not exit; rebuild aborted");
            return 0;
        }
        purgeStaleSymbols(options);
        appendLine(options.logPath, "reopen: app exited; rebuilding");
        const rebuilt = runBuild(options);
        appendLine(options.logPath, rebuilt ? "rebuild complete; relaunching"
            : "rebuild FAILED");
        return launchApp(options) ? 0 : 1;
    }

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
    if (options.run) return runAndReport(options);
    return launchApp(options) ? 0 : 1;
}
