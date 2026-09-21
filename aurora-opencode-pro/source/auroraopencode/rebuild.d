module auroraopencode.rebuild;

import std.conv : to;
import std.file : exists;
import std.path : buildPath, dirName;
import std.process : Config, spawnProcess;
import std.stdio : stderr, stdin, stdout;

// ---------------------------------------------------------------------------
// Rebuild-and-relaunch
// ---------------------------------------------------------------------------
// Rebuilding cannot be done in-process: DUB must overwrite
// `aurora-opencode-pro.exe`, and Windows holds that file locked for as long as
// this process is alive. The work is therefore handed to the standalone
// `bin/aurora-rebuilder.exe`, which outlives us, waits for the lock to clear,
// rebuilds, and starts the new binary.
//
// There is exactly one implementation and one caller. An earlier version also
// generated a PowerShell helper inline as a fallback; that was a second
// implementation of the same operation, kept in step with the first by hand,
// and it has been removed. When the tool is missing the rebuild fails with a
// message saying so, rather than silently taking a different code path.

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
    /// skipped but the relaunch still happens.
    string workingDir;
    /// Helper output log, under the app's state directory.
    string logPath;
    /// The process the helper waits for: this one, whose exit frees the .exe.
    int waitPid;
    /// Run `dub build` before relaunching.
    bool rebuild;
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

/**
 * True when `dir` is Aurora OpenCode's own package: it ships this module's
 * source. Used both to decide whether the running app can rebuild itself and to
 * gate the agent-facing rebuild tool and its system-prompt awareness, so a
 * packaged copy with no sources never offers a rebuild it cannot perform.
 */
bool isAuroraProject(string dir)
{
    if (dir.length == 0) return false;
    return exists(buildPath(dir, "source", "auroraopencode", "rebuild.d"));
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
    // `--run` keeps the restarted app as the helper's child, so the helper can
    // record how it ended; `--supervise` also brings it back after an
    // unexpected exit and notes the event. The exit code matters because a
    // fail-fast death never reaches the app's own exception filter, so the
    // app cannot report it and the log stops mid-sentence.
    argv ~= "--run";
    argv ~= "--supervise";
    if (!plan.rebuild)
        argv ~= "--no-rebuild";
    return argv;
}

/**
 * Start the helper detached, so it keeps running after this process exits.
 * The returned `Pid` is deliberately discarded: a detached process is not ours
 * to wait for or kill. Returns false when the helper could not be started, or
 * when it has not been built, so the caller can keep the window open instead of
 * exiting into nothing.
 */
bool launchRebuild(in RebuildPlan plan)
{
    auto argv = rebuildHelperArgv(plan);
    if (argv.length == 0)
    {
        try stderr.writeln("rebuild helper missing: build it with " ~
            "`dub build --config=rebuilder`");
        catch (Exception) {}
        return false;
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
