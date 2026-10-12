module developer_workflow_contracts;

import auroraopencode.developerworkflow;
import rebuild : installRebuiltImage;
import core.thread : Thread;
import core.time : MonoTime, seconds;
import std.algorithm : canFind;
import std.array : join;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, write, tempDir, thisExePath;
import std.path : buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf, startsWith, strip;

string git;
string command(string dir, string[] args)
{
    auto result = runDeveloperCommand([git, "-C", dir] ~ args, dir, 20, "", null);
    assert(result.status == 0, args.join(" ") ~ ": " ~ result.output);
    return result.output.strip();
}

final class FakeGitHub
{
    string fork;
    bool authenticated;
    bool existing;
    bool wrongFork;
    bool owner;
    uint pushes, creates, forks, logins;
    string pushedRef;
    string[][] calls;
    DeveloperCommandResult run(string[] args, string dir, int timeout,
        string input, DeveloperProgress progress)
    {
        calls ~= args;
        if (args[0] != "fake-gh")
        {
            if (args.canFind("push"))
            {
                ++pushes;
                assert(!args.canFind("--force") && !args.canFind("--force-with-lease"));
                pushedRef = args[$ - 1];
                assert(pushedRef.startsWith("HEAD:refs/heads/aurora/contribution-"));
                auto push = args.dup;
                push[$ - 2] = fork;
                return runDeveloperCommand(push, dir, timeout, input, progress);
            }
            return runDeveloperCommand(args, dir, timeout, input, progress);
        }
        const op = args[1 .. $].join(" ");
        if (op.startsWith("auth status")) return DeveloperCommandResult(authenticated ? 0 : 1, "");
        if (op.startsWith("auth login"))
        {
            assert(input == "\n" && args.canFind("--web"));
            ++logins; authenticated = true; return DeveloperCommandResult(0, "");
        }
        if (op == "api user") return DeveloperCommandResult(0,
            owner ? `{"login":"BoQsc","id":42}` : `{"login":"alice","id":42}`);
        if (op == "api repos/BoQsc/aurora-gui") return DeveloperCommandResult(0,
            `{"default_branch":"main","owner":{"login":"BoQsc"},"name":"aurora-gui"}`);
        if (op.startsWith("api --method POST")) { ++forks; return DeveloperCommandResult(0, "{}"); }
        if (op == "api repos/alice/aurora-gui") return DeveloperCommandResult(0,
            wrongFork ? `{"fork":false,"parent":{"full_name":"someone/else"}}`
                : `{"fork":true,"parent":{"full_name":"BoQsc/aurora-gui"}}`);
        if (op.startsWith("api --method GET repos/BoQsc/aurora-gui/pulls")) return DeveloperCommandResult(0, existing
            ? `[{"html_url":"https://github.com/BoQsc/aurora-gui/pull/123"}]` : `[]`);
        if (op.startsWith("pr create"))
        {
            ++creates; existing = true;
            assert(args.canFind("alice:aurora/contribution-test") || owner);
            return DeveloperCommandResult(0, "https://github.com/BoQsc/aurora-gui/pull/123\n");
        }
        assert(false, "Unexpected GitHub operation: " ~ op);
        return DeveloperCommandResult(1, "Unexpected operation");
    }
}

void expectFailure(void delegate() action, string contains)
{
    bool failed;
    try { action(); }
    catch (Exception e) { failed = true; assert(e.msg.indexOf(contains) >= 0, e.msg); }
    assert(failed, "Expected failure: " ~ contains);
}

void main(string[] args)
{
    if (args.canFind("--hang")) { Thread.sleep(20.seconds); return; }
    if (args.canFind("--prepare-gh"))
    {
        writeln(ensureDeveloperTool("gh", args[$ - 1], (string line) { writeln(line); }));
        return;
    }
    git = environment.get("AURORA_TEST_GIT", "git");
    const root = buildPath(tempDir(), "aurora-developer-contracts-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(root);
    const upstream = buildPath(root, "upstream.git");
    const author = buildPath(root, "author");
    const developer = buildPath(root, "developer");
    const fork = buildPath(root, "fork.git");
    command(root, ["init", "--bare", upstream]);
    command(root, ["init", "-b", "main", author]);
    command(author, ["config", "user.name", "Fixture"]);
    command(author, ["config", "user.email", "fixture@example.invalid"]);
    write(buildPath(author, "local.txt"), "base\n");
    write(buildPath(author, "upstream.txt"), "base\n");
    command(author, ["add", "-A"]);
    command(author, ["commit", "-m", "Initial"]);
    command(author, ["remote", "add", "origin", upstream]);
    command(author, ["push", "-u", "origin", "main"]);
    command(root, ["clone", "--branch", "main", upstream, developer]);
    command(root, ["clone", "--bare", upstream, fork]);
    auto github = new FakeGitHub();
    github.fork = fork;
    auto workflow = new DeveloperWorkflow(git, "fake-gh", &github.run);
    workflow.upstreamUrl = upstream;
    workflow.upstreamBranch = "main";
    const before = command(developer, ["rev-parse", "HEAD"]);
    write(buildPath(developer, "local.txt"), "developer's work\n");
    write(buildPath(author, "upstream.txt"), "maintainer's update\n");
    command(author, ["commit", "-am", "Maintainer update"]);
    command(author, ["push", "origin", "main"]);

    auto notice = workflow.sync(developer, false);
    assert(!notice.failed && notice.available, notice.message);
    assert(command(developer, ["rev-parse", "HEAD"]) == before);
    assert(readText(buildPath(developer, "local.txt")) == "developer's work\n");
    foreach (call; github.calls) assert(!call.canFind("rebase") && !call.canFind("merge"));
    writeln("PASS: update checks leave HEAD and in-progress edits untouched");

    auto gate = workflow.checkRebuildSource(developer);
    assert(gate.available && !gate.failed, gate.message);
    assert(command(developer, ["rev-parse", "HEAD"]) == before);
    assert(readText(buildPath(developer, "local.txt")) == "developer's work\n");
    expectFailure({ workflow.publish(developer, "Must test first", "test"); }, "rebuild and test before publishing");
    assert(github.logins == 0 && github.pushes == 0);
    auto applied = workflow.sync(developer, true);
    assert(!applied.failed, applied.message);
    auto current = workflow.checkRebuildSource(developer);
    assert(!current.failed && !current.available, current.message);
    writeln("PASS: stale rebuilds and publication stop without changing files; explicit sync makes source current");

    const url = workflow.publish(developer, "Fix a real problem", "test");
    assert(url == "https://github.com/BoQsc/aurora-gui/pull/123");
    assert(github.logins == 1 && github.forks == 1 && github.pushes == 1 && github.creates == 1);
    assert(command(developer, ["remote", "get-url", "origin"]) == upstream);
    assert(readText(buildPath(developer, "local.txt")).strip() == "developer's work");
    assert(readText(buildPath(developer, "upstream.txt")).strip() == "maintainer's update");
    assert(command(developer, ["status", "--porcelain"]).length == 0);
    const firstPublished = command(developer, ["rev-parse", "HEAD"]);
    workflow.publish(developer, "Fix a real problem", "unused");
    assert(github.creates == 1 && github.logins == 1);
    write(buildPath(author, "new.txt"), "another maintainer update\n");
    command(author, ["add", "-A"]);
    command(author, ["commit", "-m", "Another update"]);
    command(author, ["push", "origin", "main"]);
    expectFailure({ workflow.publish(developer, "Must retest update", "unused"); }, "rebuild and test before publishing");
    assert(github.pushes == 2);
    assert(!workflow.sync(developer, true).failed);
    workflow.publish(developer, "Fix a real problem", "unused");
    command(developer, ["merge-base", "--is-ancestor", firstPublished, "HEAD"]);
    assert(github.creates == 1 && github.pushes == 3);
    writeln("PASS: sign-in, fork, commit, push, PR creation and repeat publication; published history preserved");

    const conflicting = buildPath(root, "conflicting");
    command(root, ["clone", "--branch", "main", upstream, conflicting]);
    write(buildPath(conflicting, "local.txt"), "conflicting local work\n");
    write(buildPath(author, "local.txt"), "conflicting maintainer work\n");
    command(author, ["commit", "-am", "Conflict"]);
    command(author, ["push", "origin", "main"]);
    auto conflict = workflow.sync(conflicting, true);
    assert(conflict.failed && conflict.message.indexOf("conflict") >= 0, conflict.message);
    assert(command(conflicting, ["diff", "--name-only", "--diff-filter=U"]).indexOf("local.txt") >= 0);
    assert(command(conflicting, ["stash", "list"]).length > 0);
    assert(workflow.checkRebuildSource(conflicting).failed,
        "Unresolved autostash conflicts must block rebuild even after upstream is in HEAD");
    const pushCount = github.pushes;
    expectFailure({ workflow.publish(conflicting, "Conflicted", "fail"); }, "conflicts");
    assert(github.pushes == pushCount);
    writeln("PASS: autostash conflicts are failures, preserve recoverable work and block publication");

    const rebasing = buildPath(root, "rebasing");
    command(root, ["clone", "--branch", "main", upstream, rebasing]);
    command(rebasing, ["switch", "-c", "local-work", before]);
    write(buildPath(rebasing, "local.txt"), "my committed change\n");
    command(rebasing, ["add", "-A"]);
    command(rebasing, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
        "commit", "-m", "Local contribution"]);
    auto rebaseConflict = workflow.sync(rebasing, true);
    assert(rebaseConflict.failed, "An overlapping committed change must stop for conflict resolution");
    write(buildPath(rebasing, "local.txt"), "maintainer and local changes integrated\n");
    command(rebasing, ["add", "local.txt"]);
    auto unfinished = workflow.checkRebuildSource(rebasing);
    assert(unfinished.failed && unfinished.message.indexOf("Finish the existing") >= 0,
        "Staging a resolution is insufficient while the rebase remains unfinished: " ~ unfinished.message);
    command(rebasing, ["-c", "core.editor=true", "-c", "user.name=Fixture", "-c",
        "user.email=fixture@example.invalid", "rebase", "--continue"]);
    auto resolved = workflow.checkRebuildSource(rebasing);
    assert(!resolved.failed && !resolved.available, resolved.message);
    assert(readText(buildPath(rebasing, "local.txt")).strip() == "maintainer and local changes integrated");
    writeln("PASS: a real rebase conflict blocks until its resolution is staged and the rebase is completed");

    const rejected = buildPath(root, "rejected");
    command(root, ["clone", "--branch", "main", upstream, rejected]);
    write(buildPath(rejected, "local.txt"), "reject this commit\n");
    write(buildPath(rejected, ".git", "hooks", "pre-commit"), "#!/bin/sh\nexit 1\n");
    expectFailure({ workflow.publish(rejected, "Rejected", "reject"); }, "Committing local changes failed");
    assert(github.pushes == pushCount);
    github.wrongFork = true;
    expectFailure({ workflow.publish(rejected, "Wrong fork", "wrong"); }, "not this project's fork");
    assert(github.pushes == pushCount);
    github.wrongFork = false;
    const savedUpstream = workflow.upstreamUrl;
    workflow.upstreamUrl = buildPath(root, "missing.git");
    auto failedFetch = workflow.sync(developer, true);
    assert(failedFetch.failed, failedFetch.message);
    assert(workflow.checkRebuildSource(developer).failed,
        "Unavailable upstream must stop the default rebuild check");
    auto optedOut = workflow.checkRebuildSource(developer, false);
    assert(!optedOut.failed && !optedOut.available,
        "Explicitly disabling the guard must permit offline rebuilds");
    workflow.upstreamUrl = savedUpstream;
    writeln("PASS: rejected commits, mismatched forks and failed network checks never report success or push");

    const ownerDir = buildPath(root, "owner");
    command(root, ["clone", "--branch", "main", upstream, ownerDir]);
    auto ownerGithub = new FakeGitHub();
    ownerGithub.fork = fork;
    ownerGithub.owner = true;
    ownerGithub.authenticated = true;
    auto ownerWorkflow = new DeveloperWorkflow(git, "fake-gh", &ownerGithub.run);
    ownerWorkflow.upstreamUrl = upstream;
    ownerWorkflow.upstreamBranch = "main";
    write(buildPath(ownerDir, "owner.txt"), "owner work\n");
    ownerWorkflow.publish(ownerDir, "Owner contribution", "owner");
    assert(ownerGithub.forks == 0 && ownerGithub.creates == 1 && ownerGithub.pushes == 1);
    writeln("PASS: the maintainer also publishes a review branch without trying to fork their own project");

    // main stays unchanged while the actual shipped-source branch moves.
    const releaseDeveloper = buildPath(root, "release-developer");
    command(root, ["clone", "--branch", "main", upstream, releaseDeveloper]);
    command(author, ["switch", "-c", "release-source"]);
    write(buildPath(author, "release.txt"), "new shipped app source\n");
    command(author, ["add", "-A"]);
    command(author, ["commit", "-m", "Shipped source"]);
    command(author, ["push", "origin", "release-source"]);
    workflow.upstreamBranch = "release-source";
    write(buildPath(releaseDeveloper, "untracked.txt"), "keep this too\n");
    auto staleRelease = workflow.checkRebuildSource(releaseDeveloper);
    assert(staleRelease.available && !staleRelease.failed, staleRelease.message);
    assert(!exists(buildPath(releaseDeveloper, "release.txt")));
    auto releaseSync = workflow.sync(releaseDeveloper, true);
    assert(!releaseSync.failed, releaseSync.message);
    assert(readText(buildPath(releaseDeveloper, "release.txt")).strip() == "new shipped app source");
    assert(readText(buildPath(releaseDeveloper, "untracked.txt")) == "keep this too\n");
    assert(!workflow.checkRebuildSource(releaseDeveloper).available);
    assert(workflow.checkRebuildSource(root).failed, "A source snapshot without Git must not pass");
    assert(rebuildSourceAgentPrompt(releaseDeveloper).indexOf(releaseDeveloper) >= 0);
    assert(rebuildSourceAgentPrompt(releaseDeveloper).indexOf(maintainerSourceBranch) >= 0);
    writeln("PASS: rebuild and sync follow the release source branch rather than stale main; untracked work preserved");

    auto timed = runDeveloperCommand([thisExePath(), "--hang"], root, 1, "", null);
    assert(timed.status != 0 && timed.output.indexOf("timed out") >= 0);
    writeln("PASS: stalled commands have a bounded lifetime");

    const build = buildPath(root, "built.exe");
    const installed = buildPath(root, "installed.exe");
    write(build, "new executable");
    write(installed, "previous executable");
    string error;
    assert(installRebuiltImage(build, installed, error), error);
    assert(readText(installed) == "new executable");
    assert(readText(installed ~ ".bak") == "previous executable");
    assert(!installRebuiltImage(buildPath(root, "missing.exe"), installed, error));
    assert(readText(installed) == "new executable");
    writeln("PASS: rebuilding from a separate source folder replaces the original installed app; failed output preserves it");
    writeln("ARTIFACTS ", root);
}
