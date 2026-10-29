module source_background_guard;

// The runner refuses to background a command that mutates Aurora's own source,
// so `sync` and the rebuild helper can wait for the physical operation. That
// rule must not misfire on a command that merely *reads* a path inside the
// checkout: launching a viewer, player or converter on a model or asset that
// happens to live in the repository is a read, not a source mutation.
//
// The fixture pins the developer source to a scratch checkout of its own, so the
// running app's lease on the real checkout cannot interfere.

import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.checkout : checkoutIdentity;
import auroraopencode.tools : ToolExecution, clearFinishedSupervisedProcesses,
    classifySourceCommand, executeTool, installDeveloperToolSource,
    listSupervisedProcesses, requestAllSupervisedProcessKills,
    resolveToolPath, restoreDeveloperToolSource;
import std.file : mkdirRecurse, tempDir, write;
import std.json : parseJSON;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;
import std.string : indexOf, replace;

private string payload(string program, string[] args, bool background)
{
    auto text = `{"program":"` ~ program.replace("\\", "\\\\") ~ `","args":[`;
    foreach (index, arg; args)
    {
        if (index > 0) text ~= ",";
        text ~= `"` ~ arg.replace("\\", "\\\\") ~ `"`;
    }
    text ~= background ? `],"background":true}` : `]}`;
    return text;
}

private bool refused(ToolExecution result)
{
    return result.failed &&
        result.output.indexOf("must run in the foreground") >= 0;
}

private string describe(bool targets, bool workingDir, bool program,
    bool mutatingTool)
{
    return "targets=" ~ (targets ? "yes" : "no") ~
        " workingDir=" ~ (workingDir ? "yes" : "no") ~
        " program=" ~ (program ? "yes" : "no") ~
        " mutatingTool=" ~ (mutatingTool ? "yes" : "no");
}

int main()
{
    const root = buildPath(tempDir(), "aurora-source-guard-contracts");
    mkdirRecurse(root);
    setOpencodeStateDirectoryForTesting(buildPath(root, "state"));
    // Scratch checkout: its own identity, separate from the live app's.
    const source = buildPath(root, "source");
    mkdirRecurse(buildPath(source, ".git"));
    write(buildPath(source, "tool.exe"), "not a real executable");

    const previous = installDeveloperToolSource(absolutePath(source));
    scope (exit)
    {
        requestAllSupervisedProcessKills();
        clearFinishedSupervisedProcesses();
        restoreDeveloperToolSource(previous);
    }

    // A reader that is handed a path inside the checkout may run detached.
    auto readerCall = OpenCodeToolCall("bg", "run",
        payload("where.exe", [absolutePath(source)], true));
    auto classified = classifySourceCommand(absolutePath(source), root, root,
        [], readerCall, parseJSON(readerCall.arguments), true);
    assert(!classified.mutation(),
        "a reader launch is classified as a source mutation: " ~
        describe(classified.targets.length > 0, classified.workingDir,
            classified.program, classified.mutatingTool) ~
        " | sourceIdentity=" ~ checkoutIdentity(absolutePath(source)) ~
        " | resolvedProgram=" ~ resolveToolPath("where.exe", root) ~
        " | programIdentity=" ~
            checkoutIdentity(resolveToolPath("where.exe", root)));
    auto launch = executeTool(readerCall, root);
    assert(!launch.failed,
        "a detached reader of a checkout path was refused: " ~ launch.output ~
        " [" ~ describe(classified.targets.length > 0, classified.workingDir,
            classified.program, classified.mutatingTool) ~ "]");
    assert(launch.output.indexOf("Background process started") >= 0,
        "the reader launch was not reported as a background process: " ~
        launch.output);
    writeln("PASS a viewer launched with a path inside the checkout may run in the background");

    // A VCS/build tool pointed at the checkout is still a source command.
    auto gitCall = OpenCodeToolCall("git", "run",
        payload("git", ["-C", absolutePath(source), "status", "--porcelain"],
            true));
    auto gitClass = classifySourceCommand(absolutePath(source), root, root, [],
        gitCall, parseJSON(gitCall.arguments), true);
    assert(gitClass.mutatingTool,
        "a build/VCS command against the checkout is not classified as a " ~
        "mutation: " ~ describe(false, gitClass.workingDir, gitClass.program,
            gitClass.mutatingTool));
    auto git = executeTool(gitCall, root);
    assert(refused(git),
        "a detached VCS command against the checkout was allowed: " ~ git.output);
    writeln("PASS a detached build/VCS command against the checkout is still refused");

    // So is any command whose working directory is the checkout.
    auto inTree = executeTool(OpenCodeToolCall("tree", "run",
        payload("where.exe", ["git"], true)), absolutePath(source));
    assert(refused(inTree),
        "a command inside the checkout was allowed to detach: " ~ inTree.output);
    writeln("PASS a command inside the checkout is still refused in the background");

    // And one whose own program lives in the checkout.
    auto binary = executeTool(OpenCodeToolCall("tool", "run",
        payload(buildPath(absolutePath(source), "tool.exe"), [], true)), root);
    assert(refused(binary),
        "a program inside the checkout was allowed to detach: " ~ binary.output);
    writeln("PASS a program inside the checkout is still refused in the background");

    // The rule is about backgrounding only: the same command may run inline.
    auto foreground = executeTool(OpenCodeToolCall("fg", "run",
        payload("where.exe", ["git"], false)), absolutePath(source));
    assert(!refused(foreground),
        "a foreground command inside the checkout was refused: " ~
        foreground.output);
    writeln("PASS foreground source commands still run");

    foreach (process; listSupervisedProcesses())
        assert(process.id.length > 0);
    writeln("source background guard contracts passed");
    return 0;
}