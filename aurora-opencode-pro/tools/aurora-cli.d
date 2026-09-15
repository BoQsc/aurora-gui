// Instruction runner for Aurora OpenCode Pro.
//
// The app cannot be rebuilt or diagnosed while it is running: Windows keeps a
// running image locked, so `dub` cannot replace the .exe and an address cannot
// be resolved against symbols that a rebuild has already replaced. Every
// diagnostic task therefore has the same shape - stop the app, do the work,
// start it again - which is what this tool automates.
//
// It takes a short list of instructions and runs them in order, then resumes
// the app unless told not to:
//
//   stop              terminate the running app and wait for its .exe to unlock
//   build [config]    dub build --force (default config: application)
//   symbols           resolve the last crash address from the error log
//   logs [n]          print the last n lines of the error log (default 40)
//   sleep <seconds>   pause
//   start             launch the app
//
// Instructions come from the command line, one per argument, or from a script
// file with one instruction per line (`#` starts a comment):
//
//   aurora-cli --script diagnose.txt
//   aurora-cli stop "build application" symbols start
//
// Usage:
//   aurora-cli [--exe <app.exe>] [--dir <packageDir>] [--log <errors.log>]
//              [--image <process.exe>] [--no-resume] [--dry-run]
//              [instructions...]
module auroracli;

import core.stdc.stdio : fclose, fflush, fopen, fwrite;
import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.array : join;
import std.conv : parse, to;
import std.file : exists, readText;
import std.path : buildPath;
import std.process : Config, spawnProcess, wait;
import std.stdio : stderr, stdin, stdout;
import std.string : indexOf, lastIndexOf, split, strip, toLower;

import progresswindow : closeProgressWindow, openProgressWindow, setProgress;

private struct Options
{
    /// The app executable: the thing stopped, rebuilt and started.
    string exePath;
    /// Package directory holding the DUB recipe.
    string packageDir;
    /// The app's error log.
    string logPath;
    /// Process image name to terminate, as `taskkill /IM` wants it.
    string imageName = "aurora-opencode-pro.exe";
    /// Start the app again after the instructions finish.
    bool resume = true;
    /// Report what would happen without touching anything.
    bool dryRun;
    string[] instructions;
}

private void say(string text)
{
    stdout.writeln(text);
    stdout.flush();
}

/// Mirror every step into the log the app and its tools share, so a rebuild
/// and the app's own crash reporting can be read in one place.
private __gshared string toolLogPath;

private void logProgress(string text)
{
    try
    {
        import std.file : append;
        import std.datetime : Clock;
        if (toolLogPath.length == 0) return;
        auto now = Clock.currTime;
        append(toolLogPath, to!string(now) ~ " [TOOL] " ~ text ~ "\n");
    }
    catch (Exception) {}
}

private void warn(string text)
{
    stderr.writeln(text);
    stderr.flush();
}

// ---------------------------------------------------------------------------
// Progress display
// ---------------------------------------------------------------------------
// Steps like a build or a symbol resolution block for seconds or minutes, and
// a tool that prints nothing in the meantime is indistinguishable from one
// that has hung. While a step runs, a single line is redrawn in place with a
// spinner, the elapsed time, and - when the step has a known limit - a bar.
// The line is cleared before the step's own result is printed, so the result
// is never mixed into the progress text.

private __gshared bool progressActive;
private __gshared string progressLabel;
private __gshared int progressTotalSeconds;

private enum progressTickMs = 200;
private enum progressBarWidth = 24;

private string progressBar(int elapsedSeconds, int totalSeconds)
{
    if (totalSeconds <= 0) return "";
    auto fraction = cast(double) elapsedSeconds / totalSeconds;
    if (fraction > 1.0) fraction = 1.0;
    const filled = cast(int) (fraction * progressBarWidth);
    string bar;
    foreach (index; 0 .. progressBarWidth)
        bar ~= index < filled ? '#' : '-';
    return " [" ~ bar ~ "]";
}

private void progressLoop()
{
    immutable string spin = "|/-\\";
    size_t tick;
    while (atomicLoad(progressActive))
    {
        Thread.sleep(progressTickMs.msecs);
        if (!atomicLoad(progressActive)) break;
        ++tick;
        const elapsed = cast(int) (tick * progressTickMs / 1000);
        auto line = "\r  " ~ spin[tick % 4] ~ " " ~ progressLabel ~
            " " ~ to!string(elapsed) ~ "s";
        if (progressTotalSeconds > 0)
            line ~= "/" ~ to!string(progressTotalSeconds) ~ "s" ~
                progressBar(elapsed, progressTotalSeconds);
        // Trailing spaces overwrite any longer previous line.
        stdout.write(line, "    ");
        stdout.flush();
    }
}

private void clearProgressLine()
{
    immutable string blanks =
        "                                                                                ";
    stdout.write("\r", blanks, "\r");
    stdout.flush();
}

/**
 * Run `work` with a progress line underneath it. `totalSeconds` of 0 means the
 * duration is unknown, which draws the elapsed time alone.
 */
private bool runWithProgress(string label, int totalSeconds,
    scope bool delegate() work)
{
    const started = MonoTime.currTime;
    setProgress(label, "", totalSeconds > 0 ? 0.0 : -1.0);
    logProgress("begin: " ~ label);
    progressLabel = label;
    progressTotalSeconds = totalSeconds;
    atomicStore(progressActive, true);
    auto worker = new Thread(&progressLoop);
    worker.start();
    bool result;
    scope (exit)
    {
        atomicStore(progressActive, false);
        worker.join();
        clearProgressLine();
        // The finished step states its own duration, so a log of the run reads
        // as a sequence of completed steps rather than as guesses.
        const secondsTaken =
            (MonoTime.currTime - started).total!"msecs" / 1000.0;
        stdout.write("  done: ", label, " (",
            to!(string)(secondsTaken), "s)\n");
        stdout.flush();
        logProgress("done: " ~ label ~ " (" ~
            to!(string)(secondsTaken) ~ "s)");
    }
    result = work();
    return result;
}

private Options parseArgs(string[] args)
{
    Options options;
    bool sawInstruction;
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
        else if (arg == "--image") options.imageName = take();
        else if (arg == "--no-resume") options.resume = false;
        else if (arg == "--dry-run") options.dryRun = true;
        else if (arg == "--script")
        {
            const path = take();
            options.instructions ~= readInstructions(path);
            sawInstruction = true;
        }
        else if (arg.length > 2 && arg[0 .. 2] == "--")
            warn("ignoring unknown option " ~ arg);
        else
        {
            options.instructions ~= arg;
            sawInstruction = true;
        }
        ++index;
    }
    if (!sawInstruction)
    {
        // No instructions is still useful: stop, build, start.
        options.instructions = ["stop", "build", "start"];
    }
    // A name is enough to terminate the process; the full path is needed to
    // rebuild and relaunch it, so derive it when only the directory is known.
    if (options.exePath.length == 0 && options.packageDir.length > 0)
        options.exePath = buildPath(options.packageDir, options.imageName);
    return options;
}

/// One instruction per line; blank lines and `#` comments are ignored.
private string[] readInstructions(string path)
{
    string[] lines;
    try
    {
        foreach (line; readText(path).split("\n"))
        {
            const text = strip(line);
            if (text.length == 0 || text[0] == '#') continue;
            lines ~= text;
        }
    }
    catch (Exception error)
        warn("could not read " ~ path ~ ": " ~ error.msg);
    return lines;
}

/// True when the file is not held open as a running image.
private bool canWrite(string path)
{
    if (path.length == 0 || !exists(path)) return true;
    try
    {
        import std.stdio : File;
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

// ---------------------------------------------------------------------------
// Instructions
// ---------------------------------------------------------------------------

private bool instructionStop(in Options options)
{
    if (options.dryRun)
    {
        say("would stop " ~ options.imageName);
        return true;
    }
    say("stopping " ~ options.imageName);
    // Terminating a windowed app can take a moment, so the wait is shown.
    runWithProgress("stopping " ~ options.imageName, 15, ()
    {
        version (Windows)
        {
            try
            {
                auto pid = spawnProcess(["taskkill", "/IM", options.imageName,
                    "/F"], stdin, stdout, stderr, null, Config.none);
                wait(pid);
            }
            catch (Exception error)
                warn("taskkill failed: " ~ error.msg);
        }
        else
        {
            try
            {
                auto pid = spawnProcess(["pkill", "-f", options.imageName],
                    stdin, stdout, stderr, null, Config.none);
                wait(pid);
            }
            catch (Exception error)
                warn("pkill failed: " ~ error.msg);
        }
        return true;
    });
    // The exit of the process is not the same as the release of its image; the
    // lock is what the build needs, so wait for the lock.
    const released = runWithProgress("waiting for the app to release its .exe",
        30, () => waitForUnlock(options.exePath, 30));
    if (!released)
    {
        warn("the app did not release " ~ options.exePath);
        return false;
    }
    say("app stopped");
    return true;
}

private bool instructionBuild(in Options options, string argument)
{
    const config = argument.length > 0 ? argument : "application";
    if (options.dryRun)
    {
        say("would build config " ~ config);
        return true;
    }
    if (options.packageDir.length == 0)
    {
        warn("build needs --dir <packageDir>");
        return false;
    }
    say("building " ~ config);
    try
    {
        // DUB's own output goes to this console, so the progress line is only
        // drawn when there is no output to interleave with. The elapsed time
        // is still worth showing for the long silent stretches.
        int code;
        const ran = runWithProgress("building " ~ config, 0, ()
        {
            try
            {
                auto pid = spawnProcess(["dub", "build", "--config=" ~ config,
                    "--build=release", "--force"],
                    stdin, stdout, stderr, null, Config.none, options.packageDir);
                code = wait(pid);
                return true;
            }
            catch (Exception error)
            {
                warn("could not start dub: " ~ error.msg);
                return false;
            }
        });
        if (!ran) return false;
        if (code != 0)
        {
            warn("build failed with " ~ to!string(code));
            return false;
        }
        say("build succeeded");
        return true;
    }
    catch (Exception error)
    {
        warn("could not start dub: " ~ error.msg);
        return false;
    }
}

/// The last `native crash: ... at <address>` entry, or "" when there is none.
private string lastCrashAddress(string logPath)
{
    if (logPath.length == 0 || !exists(logPath)) return "";
    try
    {
        const text = readText(logPath);
        const index = text.lastIndexOf("native crash:");
        if (index < 0) return "";
        const tail = text[index .. $];
        const at = tail.indexOf(" at ");
        if (at < 0) return "";
        auto digits = tail[at + 4 .. $];
        size_t end;
        while (end < digits.length &&
            ((digits[end] >= '0' && digits[end] <= '9') ||
             (digits[end] >= 'A' && digits[end] <= 'F') ||
             (digits[end] >= 'a' && digits[end] <= 'f')))
            ++end;
        return digits[0 .. end];
    }
    catch (Exception error)
        warn("could not read " ~ logPath ~ ": " ~ error.msg);
    return "";
}

private bool instructionSymbols(in Options options)
{
    const digits = lastCrashAddress(options.logPath);
    if (digits.length == 0)
    {
        say("no crash recorded in " ~ options.logPath);
        return true;
    }
    say("last crash address: 0x" ~ digits);
    if (options.dryRun) return true;
    version (Windows)
    {
        import core.sys.windows.stacktrace : StackTrace;
        // Symbol resolution loads and searches a ~12 MB .pdb, which takes long
        // enough that silence looks like a hang.
        auto resolve = runWithProgress("resolving 0x" ~ digits, 0, ()
        {
            try
            {
                auto addressText = digits.dup;
                const address = parse!size_t(addressText, 16);
                auto resolved = StackTrace.resolve([address]);
                if (resolved.length == 0)
                {
                    // Symbols only describe the build beside them, so a
                    // rebuild since the crash leaves the address unresolvable
                    // here. The archive from that build is named in the log.
                    say("unresolved: no matching symbols for this build " ~
                        "(see logs/symbols/ and the crash's build key)");
                    return false;
                }
                foreach (frame; resolved)
                    say("crash site: " ~ frame.idup);
                return true;
            }
            catch (Exception error)
            {
                warn("resolution failed: " ~ error.msg);
                return false;
            }
        });
        return resolve;
    }
    else
        return true;
}

private bool instructionLogs(in Options options, string argument)
{
    int count = 40;
    if (argument.length > 0)
    {
        try count = parse!int(argument);
        catch (Exception) {}
    }
    if (options.logPath.length == 0 || !exists(options.logPath))
    {
        say("no log at " ~ options.logPath);
        return true;
    }
    try
    {
        auto lines = readText(options.logPath).split("\n");
        const from = lines.length > count ? lines.length - count : 0;
        foreach (line; lines[from .. $])
            say(line);
        return true;
    }
    catch (Exception error)
    {
        warn("could not read the log: " ~ error.msg);
        return false;
    }
}

private bool instructionStart(in Options options)
{
    if (options.dryRun)
    {
        say("would start " ~ options.exePath);
        return true;
    }
    if (options.exePath.length == 0 || !exists(options.exePath))
    {
        warn("cannot start: no executable at " ~ options.exePath);
        return false;
    }
    say("starting " ~ options.exePath);
    try
    {
        spawnProcess([options.exePath], stdin, stdout, stderr, null,
            Config.detached | Config.suppressConsole,
            options.packageDir.length > 0 ? options.packageDir : null);
        return true;
    }
    catch (Exception error)
    {
        warn("could not start the app: " ~ error.msg);
        return false;
    }
}

/// Run one instruction text. Returns false only for a failed instruction; the
/// caller decides whether that stops the script.
private bool runInstruction(in Options options, string text, out bool started)
{
    started = false;
    auto parts = text.split(" ");
    const verb = toLower(parts[0]);
    const argument = parts.length > 1 ? parts[1 .. $].join(" ") : "";
    switch (verb)
    {
        case "stop": return instructionStop(options);
        case "build": return instructionBuild(options, strip(argument));
        case "symbols": return instructionSymbols(options);
        case "logs": return instructionLogs(options, strip(argument));
        case "start": started = true; return instructionStart(options);
        case "sleep":
            int secondsCount = 1;
            auto sleepText = strip(argument).dup;
            if (sleepText.length > 0)
                try secondsCount = parse!int(sleepText);
                catch (Exception) {}
            if (!options.dryRun) Thread.sleep(seconds(secondsCount));
            say("slept " ~ to!string(secondsCount) ~ "s");
            return true;
        default:
            warn("unknown instruction: " ~ text);
            return false;
    }
}

int main(string[] args)
{
    const options = parseArgs(args);
    toolLogPath = options.logPath;
    say("aurora-cli: " ~ to!string(options.instructions.length) ~
        " instruction(s)" ~ (options.dryRun ? " (dry run)" : ""));

    // A small window mirrors the progress, because the app is closed during
    // most of this and the console may not be visible.
    if (!options.dryRun)
        openProgressWindow("Aurora OpenCode - maintenance");
    scope (exit)
    {
        if (!options.dryRun) closeProgressWindow();
    }

    bool started;
    foreach (text; options.instructions)
    {
        say("> " ~ text);
        logProgress(text);
        if (!runInstruction(options, text, started))
        {
            // A failed stop or build means the app is in an unknown state:
            // continuing would build against a locked file or report symbols
            // for the previous build. Resume anyway, so the user is not left
            // without the app.
            if (options.resume && !started)
                instructionStart(options);
            return 1;
        }
    }
    // Resume the app unless it was already started or resuming was declined.
    if (options.resume && !started)
        instructionStart(options);
    return 0;
}
