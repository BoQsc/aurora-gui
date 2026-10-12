module auroraopencode.developerworkflow;

import core.thread : Thread;
import core.sync.mutex : Mutex;
import core.time : MonoTime, seconds, msecs;
import std.algorithm : endsWith, startsWith, canFind;
import std.array : join;
import std.conv : to;
import std.datetime : Clock;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : exists, isFile, read, readText, write, remove, mkdirRecurse,
    tempDir, dirEntries, SpanMode;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : buildPath, dirName, baseName, buildNormalizedPath, isAbsolute;
import std.process : Config, environment, spawnProcess, tryWait, wait, kill,
    thisProcessID, execute;
import std.stdio : File;
import std.string : strip, split, replace, indexOf, toLower;
import std.zip : ZipArchive;

private void removeTemporaryFile(string path)
{
    try { remove(path); } catch (Exception) {}
}

public alias DeveloperProgress = void delegate(string);
// The maintainer selects the source branch used for this release channel.
// Keep provisioning, sync, the rebuild guard, and PR bases on the same branch.
public enum string maintainerSourceBranch = import("maintainer-source-branch.txt").strip;
private __gshared Mutex _developerMutex;
shared static this() { _developerMutex = new Mutex(); }
public Mutex developerOperationMutex() { return _developerMutex; }
public struct DeveloperCommandResult { int status; string output; }
public alias DeveloperRunner = DeveloperCommandResult delegate(string[], string,
    int, string, DeveloperProgress);
public struct DeveloperSyncResult
{
    bool failed;
    bool available;
    string revision;
    string message;
}

/// Commands never inherit an interactive terminal or wait forever for credentials.
public DeveloperCommandResult runDeveloperCommand(string[] args, string dir,
    int timeoutSeconds, string input, DeveloperProgress progress)
{
    const token = to!string(thisProcessID) ~ "-" ~ to!string(MonoTime.currTime.ticks);
    const outputPath = buildPath(tempDir(), "aurora-dev-" ~ token ~ ".log");
    const errorPath = buildPath(tempDir(), "aurora-dev-" ~ token ~ ".err");
    const inputPath = buildPath(tempDir(), "aurora-dev-" ~ token ~ ".in");
    write(inputPath, input);
    scope (exit)
    {
        removeTemporaryFile(inputPath);
        removeTemporaryFile(outputPath);
        removeTemporaryFile(errorPath);
    }
    auto source = File(inputPath, "r");
    auto sink = File(outputPath, "w");
    auto errors = File(errorPath, "w");
    auto env = environment.toAA();
    env["GIT_TERMINAL_PROMPT"] = "0";
    env["GCM_INTERACTIVE"] = "Never";
    env["GH_PROMPT_DISABLED"] = "1";
    env["GH_NO_UPDATE_NOTIFIER"] = "1";
    // gh also invokes git; private portable git need not be installed globally.
    if (args.length > 0 && isAbsolute(args[0]))
        env["PATH"] = dirName(args[0]) ~ ";" ~ environment.get("PATH");
    auto pid = spawnProcess(args, source, sink, errors, env,
        Config.suppressConsole, dir.length > 0 ? dir : null);
    source.close();
    sink.close();
    errors.close();
    const started = MonoTime.currTime;
    auto nextProgress = started + seconds(1);
    int status;
    while (true)
    {
        auto state = tryWait(pid);
        if (state.terminated) { status = state.status; break; }
        if (MonoTime.currTime - started >= seconds(timeoutSeconds))
        {
            version (Windows)
                execute(["taskkill.exe", "/PID", to!string(pid.processID), "/T", "/F"],
                    null, Config.suppressConsole);
            else kill(pid);
            wait(pid);
            return DeveloperCommandResult(-1, "Operation timed out after " ~
                to!string(timeoutSeconds) ~ " seconds. Retry when the network is available.");
        }
        if (progress !is null && MonoTime.currTime >= nextProgress)
        {
            const elapsed = to!string((MonoTime.currTime - started).total!"seconds");
            // The device code must be visible while authentication is pending.
            const auth = args.length > 2 && args[1] == "auth" && args[2] == "login";
            progress(auth && exists(errorPath) ? readText(errorPath).strip()
                : "Working… " ~ elapsed ~ "s elapsed");
            nextProgress = MonoTime.currTime + seconds(1);
        }
        Thread.sleep(50.msecs);
    }
    auto output = exists(outputPath) ? readText(outputPath) : "";
    if (status != 0 && exists(errorPath)) output ~= readText(errorPath);
    return DeveloperCommandResult(status, output);
}

public string findDeveloperTool(string name, string stateDir)
{
    foreach (folder; environment.get("PATH").split(';'))
    {
        const path = buildPath(folder.strip().replace("\"", ""), name ~ ".exe");
        if (folder.length > 0 && exists(path)) return path;
    }
    const cached = buildPath(stateDir, "developer-tools", name,
        name == "git" ? "cmd" : "bin", name ~ ".exe");
    if (exists(cached)) return cached;
    if (name == "git")
    {
        foreach (root; [buildPath(environment.get("ProgramFiles"), "Git", "cmd"),
            buildPath(environment.get("LOCALAPPDATA"), "Programs", "Git", "cmd")])
            if (exists(buildPath(root, "git.exe"))) return buildPath(root, "git.exe");
        const desktop = buildPath(environment.get("LOCALAPPDATA"), "GitHubDesktop");
        if (exists(desktop))
            foreach (entry; dirEntries(desktop, "app-*", SpanMode.shallow))
            {
                const path = buildPath(entry.name, "resources", "app", "git", "cmd", "git.exe");
                if (exists(path)) return path;
            }
    }
    if (name == "gh")
    {
        const path = buildPath(environment.get("ProgramFiles"), "GitHub CLI", "gh.exe");
        if (exists(path)) return path;
    }
    return "";
}

/// On-demand private tools keep the normal app download small and need no installer.
public string ensureDeveloperTool(string name, string stateDir,
    DeveloperProgress progress = null)
{
    const found = findDeveloperTool(name, stateDir);
    if (found.length > 0) return found;
    enforce(name == "git" || name == "gh", "Unknown developer tool");
    if (progress !is null) progress("Preparing " ~ (name == "gh" ? "GitHub sign-in" : "Git") ~ "…");
    const repo = name == "gh" ? "cli/cli" : "git-for-windows/git";
    auto release = runDeveloperCommand(["curl.exe", "--fail", "--silent", "--show-error",
        "--location", "--max-time", "60", "https://api.github.com/repos/" ~ repo ~
        "/releases/latest"], "", 70, "", null);
    enforce(release.status == 0, "Could not prepare developer tools: " ~ release.output);
    auto data = parseJSON(release.output);
    string url, digest;
    foreach (asset; data["assets"].array)
    {
        const file = asset["name"].str;
        const matches = name == "gh" ? file.endsWith("_windows_amd64.zip")
            : file.startsWith("MinGit-") && file.endsWith("-64-bit.zip") &&
                file.indexOf("busybox") < 0;
        if (!matches) continue;
        url = asset["browser_download_url"].str;
        if (auto value = "digest" in asset.object)
            if (value.type == JSONType.string) digest = value.str;
        break;
    }
    enforce(url.startsWith("https://github.com/" ~ repo ~ "/releases/download/") &&
        digest.startsWith("sha256:") && digest.length == 71,
        "The developer tool release has no verified SHA-256 download.");
    const root = buildPath(stateDir, "developer-tools", name);
    mkdirRecurse(root);
    const archivePath = buildPath(root, "download.zip");
    auto download = runDeveloperCommand(["curl.exe", "--fail", "--silent", "--show-error",
        "--location", "--max-time", "300", "--output", archivePath, url], "", 310, "", progress);
    scope (exit) removeTemporaryFile(archivePath);
    enforce(download.status == 0, "Developer tool download failed: " ~ download.output);
    auto bytes = cast(ubyte[]) read(archivePath);
    enforce(sha256Of(bytes).toHexString().toLower() == digest[7 .. $].toLower(),
        "Developer tool checksum mismatch.");
    auto archive = new ZipArchive(bytes);
    foreach (file, member; archive.directory)
    {
        auto relative = file.replace('\\', '/');
        // gh may include a release directory; MinGit starts at cmd/ and mingw64/.
        if (name == "gh" && relative.startsWith("gh_"))
            relative = relative[relative.indexOf('/') + 1 .. $];
        enforce(!relative.startsWith("/") && relative.indexOf(':') < 0 &&
            !relative.split('/').canFind(".."), "Invalid developer tool archive path");
        if (relative.length == 0) continue;
        const target = buildPath(root, relative);
        if (relative.endsWith("/")) { mkdirRecurse(target); continue; }
        mkdirRecurse(dirName(target));
        write(target, archive.expand(member));
    }
    const ready = findDeveloperTool(name, stateDir);
    enforce(ready.length > 0, "The developer tool archive did not contain " ~ name);
    return ready;
}

public final class DeveloperWorkflow
{
    string git;
    string gh;
    string upstreamRepo = "BoQsc/aurora-gui";
    string upstreamUrl = "https://github.com/BoQsc/aurora-gui.git";
    string upstreamBranch = maintainerSourceBranch;
    string upstreamRef = "refs/remotes/aurora-maintainer/source";
    DeveloperRunner runner;
    DeveloperProgress progress;

    this(string git, string gh = "", DeveloperRunner runner = null,
        DeveloperProgress progress = null)
    {
        this.git = git;
        this.gh = gh;
        this.runner = runner is null ? (args, dir, timeout, input, progress) =>
            runDeveloperCommand(args, dir, timeout, input, progress) : runner;
        this.progress = progress;
    }

    private DeveloperCommandResult raw(string[] args, string dir,
        int timeout = 180, string input = "")
    { return runner(args, dir, timeout, input, progress); }

    private string checked(string[] args, string dir, string phase,
        int timeout = 180, string input = "")
    {
        if (progress !is null) progress(phase);
        DeveloperProgress report = progress is null ? null : (string value) {
            progress(phase ~ " — " ~ value);
        };
        auto result = runner(args, dir, timeout, input, report);
        enforce(result.status == 0, phase ~ " failed: " ~ result.output.strip());
        return result.output.strip();
    }

    private string gitCommand(string dir, string[] args, string phase)
    { return checked([git, "-C", dir] ~ args, dir, phase); }

    private string ghCommand(string dir, string[] args, string phase)
    { return checked([gh] ~ args, dir, phase); }

    private void requireCleanOperation(string dir)
    {
        auto conflicts = gitCommand(dir, ["diff", "--name-only", "--diff-filter=U"], "Checking conflicts");
        enforce(conflicts.length == 0, "Resolve these conflicts first: " ~ conflicts);
        foreach (state; ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD"])
        {
            const path = gitCommand(dir, ["rev-parse", "--git-path", state], "Checking repository state");
            enforce(!exists(isAbsolute(path) ? path : buildPath(dir, path)),
                "Finish the existing merge or rebase before continuing.");
        }
    }

    public DeveloperSyncResult sync(string dir, bool apply)
    {
        DeveloperSyncResult result;
        try
        {
            enforce(git.length > 0, "Git is unavailable. Use Get source to prepare development tools.");
            if (!apply)
            {
                gitCommand(dir, ["rev-parse", "--verify", "HEAD"], "Checking source checkout");
                const remote = checked([git, "-C", dir, "ls-remote", upstreamUrl,
                    "refs/heads/" ~ upstreamBranch], dir, "Checking maintainer updates", 45);
                const separator = remote.indexOf('\t');
                enforce(separator >= 40, "The maintainer source branch could not be found: " ~ upstreamBranch);
                result.revision = remote[0 .. separator];
                result.available = raw([git, "-C", dir, "merge-base", "--is-ancestor",
                    result.revision, "HEAD"], dir).status != 0;
                result.message = result.available
                    ? "Maintainer source changed (" ~ result.revision ~ "). Call `sync` between edits to reapply your work before rebuilding or publishing."
                    : "Aurora source is up to date with the maintainer.";
                return result;
            }
            requireCleanOperation(dir);
            gitCommand(dir, ["fetch", "--no-tags", upstreamUrl,
                "+refs/heads/" ~ upstreamBranch ~ ":" ~ upstreamRef], "Checking maintainer updates");
            result.revision = gitCommand(dir, ["rev-parse", upstreamRef], "Reading upstream revision");
            const count = gitCommand(dir, ["rev-list", "--count", "HEAD.." ~ upstreamRef], "Comparing source");
            result.available = to!ulong(count) > 0;
            if (!result.available) { result.message = "Aurora source is up to date with the maintainer."; return result; }
            const branch = gitCommand(dir, ["branch", "--show-current"], "Reading source branch");
            // Published review branches retain their history, so later updates
            // remain ordinary fast-forward pushes to the existing PR.
            if (branch.startsWith("aurora/contribution-"))
                gitCommand(dir, ["-c", "user.name=Aurora Developer", "-c",
                    "user.email=developer@users.noreply.github.com", "merge", "--no-edit",
                    "--autostash", upstreamRef], "Applying maintainer updates to your contribution");
            else
                gitCommand(dir, ["rebase", "--autostash", upstreamRef], "Reapplying local work");
            // Git can return success even when applying the autostash conflicted.
            const conflicts = gitCommand(dir, ["diff", "--name-only", "--diff-filter=U"], "Checking reapplied changes");
            enforce(conflicts.length == 0, "Upstream is applied, but restoring local changes conflicted: " ~
                conflicts ~ ". Resolve these files; Git kept the autostash for recovery.");
            result.message = count ~ " maintainer commit(s) applied; local changes reapplied.";
        }
        catch (Exception e) { result.failed = true; result.message = "Error: " ~ e.msg; }
        return result;
    }

    /// Read-only preflight. An unavailable network, non-Git snapshot, or
    /// unfinished conflict must never be mistaken for current source.
    public DeveloperSyncResult checkRebuildSource(string dir, bool required = true)
    {
        DeveloperSyncResult result;
        if (!required) return result;
        try
        {
            enforce(git.length > 0, "Git is unavailable; prepare the Developer tools first.");
            enforce(dir.length > 0, "Aurora source has not been located.");
            requireCleanOperation(dir);
            result = sync(dir, false);
            if (result.available)
                result.message = "Update Aurora's source before rebuilding. " ~ result.message;
        }
        catch (Exception e) { result.failed = true; result.message = "Error: " ~ e.msg; }
        if (result.failed)
            result.message ~= " Rebuild stopped because the source could not be verified. " ~
                "Keep local work, resolve any conflict, and retry. To build without this check, " ~
                "turn off Require latest maintainer source before rebuild in Settings > Developer.";
        return result;
    }

    /// No force-push, no upstream main push, and every failed stage stops the flow.
    public string publish(string dir, string title, string branchSuffix)
    {
        enforce(git.length > 0 && gh.length > 0, "Developer tools are not ready.");
        enforce(title.strip().length > 0 && title.indexOf('\n') < 0 && title.indexOf('\r') < 0,
            "Give your pull request a one-line title.");
        requireCleanOperation(dir);
        // Publishing must not silently change the source that was just tested.
        // Fetch refs only; the agent syncs, resolves, rebuilds and tests first.
        gitCommand(dir, ["fetch", "--no-tags", upstreamUrl,
            "+refs/heads/" ~ upstreamBranch ~ ":" ~ upstreamRef], "Checking maintainer source before publishing");
        enforce(raw([git, "-C", dir, "merge-base", "--is-ancestor",
            upstreamRef, "HEAD"], dir).status == 0,
            "Update Aurora source with sync, resolve conflicts, rebuild and test before publishing. " ~
            "The maintainer source is newer; publishing has not changed your files.");
        if (raw([gh, "auth", "status", "--hostname", "github.com"], dir).status != 0)
            checked([gh, "auth", "login", "--hostname", "github.com", "--web",
                "--git-protocol", "https", "--skip-ssh-key", "--clipboard"], dir,
                "Sign in to GitHub in your browser (one-time setup)", 900, "\n");
        const userData = parseJSON(ghCommand(dir, ["api", "user"], "Reading GitHub account"));
        const login = userData["login"].str;
        const userId = to!string(userData["id"].integer);
        const upstream = parseJSON(ghCommand(dir, ["api", "repos/" ~ upstreamRepo], "Reading project"));
        const base = upstreamBranch;
        string target = login.toLower() == upstream["owner"]["login"].str.toLower()
            ? upstreamRepo : login ~ "/" ~ upstream["name"].str;
        if (target != upstreamRepo)
        {
            // The API's POST forks endpoint reuses an existing fork.
            const created = parseJSON(ghCommand(dir, ["api", "--method", "POST",
                "repos/" ~ upstreamRepo ~ "/forks"], "Preparing your fork"));
            if (auto fullName = "full_name" in created.object) target = fullName.str;
            enforce(target.toLower().startsWith(login.toLower() ~ "/"), "GitHub returned an unexpected fork owner.");
            auto ready = raw([gh, "api", "repos/" ~ target], dir);
            foreach (_; 0 .. 5)
            {
                if (ready.status == 0 || ready.output.indexOf("404") < 0) break;
                if (progress !is null) progress("GitHub is preparing your fork…");
                Thread.sleep(2.seconds);
                ready = raw([gh, "api", "repos/" ~ target], dir);
            }
            enforce(ready.status == 0, "Your fork is not ready yet. Retry Publish pull request: " ~ ready.output);
            auto fork = parseJSON(ready.output);
            enforce(fork["fork"].type == JSONType.true_ &&
                fork["parent"]["full_name"].str.toLower() == upstreamRepo.toLower(),
                "A repository named " ~ target ~ " already exists and is not this project's fork.");
        }
        const branch = gitCommand(dir, ["branch", "--show-current"], "Reading contribution branch");
        string publishBranch = branch;
        if (!branch.startsWith("aurora/contribution-"))
        {
            publishBranch = "aurora/contribution-" ~ branchSuffix;
            gitCommand(dir, ["switch", "-c", publishBranch], "Creating contribution branch");
        }
        const status = gitCommand(dir, ["status", "--porcelain"], "Checking local changes");
        if (status.length > 0)
        {
            gitCommand(dir, ["add", "-A"], "Staging local changes");
            // Commit identity applies to this operation; global Git settings stay intact.
            gitCommand(dir, ["-c", "user.name=" ~ login, "-c", "user.email=" ~ userId ~
                "+" ~ login ~ "@users.noreply.github.com", "commit", "-m", title], "Committing local changes");
        }
        const commits = gitCommand(dir, ["rev-list", "--count", upstreamRef ~ "..HEAD"], "Checking contribution");
        enforce(to!ulong(commits) > 0, "There are no changes to publish.");
        const head = login ~ ":" ~ publishBranch;
        auto existing = parseJSON(ghCommand(dir, ["api", "--method", "GET",
            "repos/" ~ upstreamRepo ~ "/pulls", "-f", "head=" ~ head,
            "-f", "base=" ~ base, "-f", "state=open"], "Checking for an existing pull request"));
        // Authenticate just this push via gh; never rewrite the user's remotes or credentials.
        gitCommand(dir, ["-c", "credential.helper=", "-c", "credential.helper=!\"" ~
            gh.replace('\\', '/') ~ "\" auth git-credential", "push",
            "https://github.com/" ~ target ~ ".git", "HEAD:refs/heads/" ~ publishBranch], "Pushing your contribution");
        if (existing.array.length > 0) return existing[0]["html_url"].str;
        const body = "Submitted from Aurora OpenCode Developer mode.\n\n" ~ title ~
            "\n\nPlease review and merge when ready.";
        return ghCommand(dir, ["pr", "create", "--repo", upstreamRepo, "--base", base,
            "--head", head, "--title", title, "--body", body], "Creating pull request");
    }
}

public string rebuildSourceAgentPrompt(string source)
{
    return "Update Aurora OpenCode Pro's source at \"" ~ source ~
        "\" to the latest maintainer source from BoQsc/aurora-gui, branch " ~
        maintainerSourceBranch ~ ". Use the Aurora-specific sync tool between file operations. " ~
        "Preserve all local commits, tracked edits, and untracked files. Resolve any merge, " ~
        "rebase, or restored-local-change conflicts by integrating both changes; finish the " ~
        "Git operation and confirm that no conflicts remain. Do not discard work or force-push. " ~
        "Then use rebuild, verify the relaunched app, and test my changes before publishing a pull request.";
}
