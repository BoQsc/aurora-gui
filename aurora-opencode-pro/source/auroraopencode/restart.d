module auroraopencode.restart;

import std.array : appender, replace;
import std.conv : to;
import std.file : exists;
import std.path : buildPath, dirName;
import std.process : Config, spawnProcess;
import std.stdio : stderr, stdin, stdout;

// ---------------------------------------------------------------------------
// Rebuild-and-relaunch
// ---------------------------------------------------------------------------

/**
 * Restarting the app cannot be done in-process: DUB must overwrite
 * `aurora-opencode-pro.exe`, and Windows holds that file locked for as long as
 * this process is alive. So the work is handed to a small detached helper that
 * outlives us:
 *
 *   1. the window closes and `main` returns, releasing the .exe lock;
 *   2. the helper waits for this PID to disappear;
 *   3. it runs `dub build` in the package directory;
 *   4. it relaunches the binary.
 *
 * Every step is appended to a log next to the app's state, so a restart that
 * fails is diagnosable after the window is gone.
 */

/// How far above the executable to look for a DUB recipe before giving up.
private enum int maxBuildDirLevels = 8;

/// The recipe filenames DUB accepts.
private immutable string[] recipeNames = ["dub.json", "dub.sdl"];

/// Test-only: replace the generated helper body with a harmless script so the
/// detached-spawn and PID-wait path can be exercised without rebuilding or
/// relaunching anything.
private __gshared string helperScriptOverride;

/// Test-only: install the override installed by `setHelperOverrideForTesting`.
public void setHelperOverrideForTesting(string script)
{
    helperScriptOverride = script;
}

/// Everything the detached helper needs to rebuild and relaunch the app.
struct RestartPlan
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

/// A PowerShell single-quoted literal. Inside single quotes the only escape is
/// a doubled quote, so paths with spaces (or `$`) survive verbatim.
private string psQuote(string value)
{
    return "'" ~ value.replace("'", "''") ~ "'";
}

/// A POSIX shell single-quoted word (`'` becomes `'\''`).
private string shQuote(string value)
{
    return "'" ~ value.replace("'", "'\\''") ~ "'";
}

/**
 * The helper script for Windows: a hidden PowerShell process that waits for
 * `waitPid`, rebuilds with DUB, then relaunches the executable.
 *
 * The rebuild is forced. Incremental DUB builds have missed edits here, and a
 * restart that silently relaunches the old binary is worse than a slow one.
 * A failed build still leaves the previous .exe in place (DMD only writes at
 * link time), so the relaunch below is safe either way.
 */
version (Windows)
string restartScript(in RestartPlan plan)
{
    auto script = appender!string;
    script ~= "$log = " ~ psQuote(plan.logPath) ~ "\n";
    script ~= "Set-Content -LiteralPath $log -Value 'restart requested'\n";
    // Wait for the app to exit: the build cannot overwrite a running image.
    // Bounded wait for the app to exit. The bound only matters when the user
    // leaves the window open: the guard below then aborts instead of
    // relaunching a duplicate.
    script ~= "$pid0 = " ~ to!string(plan.waitPid) ~ "\n";
    script ~= "$deadline = (Get-Date).AddSeconds(600)\n";
    script ~= "while ((Get-Process -Id $pid0 -ErrorAction SilentlyContinue) " ~
        "-and ((Get-Date) -lt $deadline)) { Start-Sleep -Milliseconds 200 }\n";
    // If the app is still alive the wait timed out: it still holds the .exe,
    // so a build cannot succeed and relaunching would spawn a duplicate
    // instance. Abort and leave the log as the record.
    script ~= "if (Get-Process -Id $pid0 -ErrorAction SilentlyContinue) {\n";
    script ~= "  Add-Content -LiteralPath $log -Value " ~
        "'app did not exit; restart aborted'\n";
    script ~= "  exit 0\n";
    script ~= "}\n";
    script ~= "Start-Sleep -Milliseconds 300\n";
    if (plan.rebuild && plan.workingDir.length > 0)
    {
        script ~= "Set-Location -LiteralPath " ~ psQuote(plan.workingDir) ~ "\n";
        script ~= "if (Get-Command dub -ErrorAction SilentlyContinue) {\n";
        script ~= "  Add-Content -LiteralPath $log -Value 'rebuilding'\n";
        script ~= "  & dub build --build=release --force *>> $log\n";
        // A failed build must never be silent. The likeliest cause is the
        // .exe still being locked (another instance was started while the
        // build ran), which DMD reports as "Access is denied" at link time.
        // Without this check the helper relaunched the OLD binary and the
        // user saw the app come back, assuming the new code was in.
        script ~= "  $buildCode = $LASTEXITCODE\n";
        script ~= "  if ($buildCode -ne 0) {\n";
        script ~= "    Add-Content -LiteralPath $log -Value " ~
            "('build FAILED exit ' + $buildCode + '; relaunching previous binary')\n";
        script ~= "  } else {\n";
        script ~= "    Add-Content -LiteralPath $log -Value 'build ok'\n";
        script ~= "  }\n";
        script ~= "} else {\n";
        script ~= "  Add-Content -LiteralPath $log -Value " ~
            "'dub not found; relaunching the current build'\n";
        script ~= "}\n";
    }
    script ~= "Add-Content -LiteralPath $log -Value 'relaunching'\n";
    script ~= "Start-Process -FilePath " ~ psQuote(plan.exePath);
    if (plan.workingDir.length > 0)
        script ~= " -WorkingDirectory " ~ psQuote(plan.workingDir);
    script ~= "\n";
    return script.data;
}

/// The POSIX counterpart of `restartScript`, run through `/bin/sh -c`.
version (Posix)
string restartScript(in RestartPlan plan)
{
    auto script = appender!string;
    script ~= "log=" ~ shQuote(plan.logPath) ~ "\n";
    script ~= "echo 'restart requested' > \"$log\"\n";
    // Bounded wait (3000 x 0.2s = 600s); see the Windows branch above.
    script ~= "n=0\n";
    script ~= "while kill -0 " ~ to!string(plan.waitPid) ~
        " 2>/dev/null && [ $n -lt 3000 ]; do sleep 0.2; n=$((n+1)); done\n";
    // Timed out with the app alive: it still holds the .exe, so abort rather
    // than relaunch a duplicate (see the Windows branch).
    script ~= "if kill -0 " ~ to!string(plan.waitPid) ~
        " 2>/dev/null; then\n";
    script ~= "  echo 'app did not exit; restart aborted' >> \"$log\"\n";
    script ~= "  exit 0\n";
    script ~= "fi\n";
    script ~= "sleep 0.3\n";
    if (plan.rebuild && plan.workingDir.length > 0)
    {
        script ~= "cd " ~ shQuote(plan.workingDir) ~ " || exit 1\n";
        script ~= "if command -v dub >/dev/null 2>&1; then\n";
        script ~= "  echo 'rebuilding' >> \"$log\"\n";
        script ~= "  dub build --build=release --force >> \"$log\" 2>&1\n";
        script ~= "else\n";
        script ~= "  echo 'dub not found; relaunching the current build' " ~
            ">> \"$log\"\n";
        script ~= "fi\n";
    }
    script ~= "echo 'relaunching' >> \"$log\"\n";
    script ~= shQuote(plan.exePath) ~ " >/dev/null 2>&1 &\n";
    return script.data;
}

/// The argv for the detached helper process.
string[] restartHelperArgv(in RestartPlan plan)
{
    const script = helperScriptOverride.length > 0
        ? helperScriptOverride : restartScript(plan);
    version (Windows)
        return ["powershell", "-NoProfile", "-NonInteractive",
            "-WindowStyle", "Hidden", "-Command", script];
    else
        return ["/bin/sh", "-c", script];
}

/**
 * Start the helper detached, so it keeps running after this process exits.
 * The returned `Pid` is deliberately discarded: a detached process is not ours
 * to wait for or kill. Returns false when the helper could not be started, so
 * the caller can keep the window open instead of exiting into nothing.
 */
bool launchRestart(in RestartPlan plan)
{
    try
        spawnProcess(restartHelperArgv(plan), stdin, stdout, stderr, null,
            Config.detached | Config.suppressConsole);
    catch (Exception)
        return false;
    return true;
}

/// Test-only: the real generated helper script, so its quoting and paths can
/// be inspected without spawning anything.
public string restartScriptForTesting(in RestartPlan plan)
{
    return restartScript(plan);
}

/// Assemble a plan for the running build. `exePath` and `waitPid` are passed in
/// rather than read here so the shaping stays testable.
RestartPlan planRestart(string stateDirectory, bool rebuild, int waitPid,
    string exePath)
{
    RestartPlan plan;
    plan.exePath = exePath;
    plan.waitPid = waitPid;
    plan.rebuild = rebuild;
    plan.logPath = stateDirectory.length > 0
        ? buildPath(stateDirectory, "restart.log") : "restart.log";
    plan.workingDir = findBuildDirectory(exePath);
    return plan;
}
