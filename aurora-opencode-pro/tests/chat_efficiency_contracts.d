module chat_efficiency_contracts;

import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : executeTool, ToolExecution, ToolCancellation,
    runFilesystemHelperMode, builtinToolDefinitions;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.algorithm : canFind;
import std.array : replicate;
import std.conv : to;
import std.file : copy, exists, mkdirRecurse, readText, thisExePath, write;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath, buildNormalizedPath, dirName;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf, replace, toLower;
import std.utf : validate;

JSONValue[] outcomes;
string root;

void record(string name, bool correct, long microseconds, string detail = "")
{
    JSONValue row;
    row["case"] = name; row["correct"] = correct;
    row["microseconds"] = microseconds; row["detail"] = detail;
    outcomes ~= row;
    writeln(row.toString());
}

OpenCodeToolCall call(string name, JSONValue args)
{
    return OpenCodeToolCall("fixture", name, args.toString());
}

JSONValue runArgs(string program, string[] args, bool background = false)
{
    JSONValue value; value["program"] = program;
    value["args"] = JSONValue(args); value["timeout"] = 5000;
    value["background"] = background;
    return value;
}

void probe(string name, string program, string expected, string[] arguments = null)
{
    const began = MonoTime.currTime;
    auto sent = ["--probe"] ~ arguments;
    const result = executeTool(call("run", runArgs(program, sent)), root);
    bool correct;
    if (!result.failed)
    {
        try
        {
            const got = parseJSON(result.output);
            correct = buildNormalizedPath(got["executable"].str).replace('/', '\\').toLower() ==
                buildNormalizedPath(expected).replace('/', '\\').toLower() &&
                got["arguments"] == JSONValue(arguments);
        }
        catch (Exception) {}
    }
    record(name, correct, (MonoTime.currTime - began).total!"usecs",
        !correct ? result.output : "exact executable and argument round-trip");
}

void fakeGit(string path)
{
    mkdirRecurse(dirName(path)); copy(thisExePath(), path);
}

void grepCase(string name, JSONValue args, string[] required, string[] forbidden = null)
{
    const began = MonoTime.currTime;
    const result = executeTool(call("grep", args), root);
    bool correct = !result.failed;
    foreach (text; required) correct = correct && result.output.indexOf(text) >= 0;
    foreach (text; forbidden) correct = correct && result.output.indexOf(text) < 0;
    try validate(result.output); catch (Exception) { correct = false; }
    record(name, correct, (MonoTime.currTime - began).total!"usecs",
        result.failed ? result.output[0 .. (result.output.length < 300 ? $ : 300)] : "expected matches and valid UTF-8");
}

int main(string[] args)
{
    if (args.length > 1 && args[1] == "--probe")
    {
        JSONValue value; value["executable"] = thisExePath();
        value["arguments"] = JSONValue(args[2 .. $]); writeln(value.toString()); return 0;
    }
    const helper = runFilesystemHelperMode(args);
    if (helper >= 0) return helper;
    assert(args.length == 3, "usage: fixture <workspace> <results.json>");
    root = absolutePath(args[1]); mkdirRecurse(root);
    const state = buildPath(root, "state");
    setOpencodeStateDirectoryForTesting(state);
    const oldPath = environment.get("PATH");
    const oldLocal = environment.get("LOCALAPPDATA");
    const oldProgram = environment.get("ProgramFiles");
    const runtimePath = environment.get("AURORA_TEST_RUNTIME_PATH");
    assert(runtimePath.length && !exists(buildPath(runtimePath, "git.exe")),
        "The fixture runtime directory must not contain Git");
    const noGitPath = buildPath(root, "empty-path") ~ ";" ~ runtimePath;
    scope(exit)
    {
        environment["PATH"] = oldPath; environment["LOCALAPPDATA"] = oldLocal;
        environment["ProgramFiles"] = oldProgram;
    }
    environment["PATH"] = noGitPath;
    environment["LOCALAPPDATA"] = buildPath(root, "local-data");
    environment["ProgramFiles"] = buildPath(root, "program-files");
    const cached = buildPath(state, "developer-tools", "git", "cmd", "git.exe");
    fakeGit(cached);
    probe("git_private_cache_without_PATH", "git", cached);
    probe("git_exe_private_cache_without_PATH", "git.exe", cached);

    const desktop = buildPath(root, "local-data", "GitHubDesktop", "app-9.8.7", "resources", "app", "git", "cmd", "git.exe");
    fakeGit(desktop);
    setOpencodeStateDirectoryForTesting(buildPath(root, "empty-state"));
    probe("git_desktop_without_PATH", "git", desktop);
    probe("git_arguments_with_spaces_unicode_and_backslash", "git", desktop,
        ["-C", "project with spaces", "--format=%H %ci %s", "", "Київ", "ends\\"]);

    const installed = buildPath(root, "program-files", "Git", "cmd", "git.exe");
    fakeGit(installed);
    probe("git_standard_install_without_PATH", "git", installed);
    const pathGit = buildPath(root, "path-tools", "git.exe"); fakeGit(pathGit);
    environment["PATH"] = dirName(pathGit) ~ ";" ~ runtimePath;
    probe("git_PATH_precedes_fallback", "git", pathGit);
    probe("git_explicit_path_preserved", desktop, desktop);
    const localGit = buildPath(root, "git.exe"); fakeGit(localGit);
    probe("git_local_exe_preserved", "git.exe", localGit);
    probe("git_relative_path_preserved", ".\\git.exe", localGit);
    const missing = executeTool(call("run", runArgs(buildPath(root, "absent", "git.exe"), ["--probe"])), root);
    record("git_missing_explicit_path_not_substituted", missing.failed, 0);
    environment["PATH"] = noGitPath;
    environment["LOCALAPPDATA"] = buildPath(root, "no-install-local");
    environment["ProgramFiles"] = buildPath(root, "no-install-program");
    const unavailable = executeTool(call("run", runArgs("git", ["--probe"])), root);
    record("git_unavailable_remains_explicit_failure", unavailable.failed, 0);
    environment["PATH"] = dirName(pathGit) ~ ";" ~ runtimePath;
    environment["LOCALAPPDATA"] = buildPath(root, "local-data");
    environment["ProgramFiles"] = buildPath(root, "program-files");
    auto cancellation = new ToolCancellation(); cancellation.cancel();
    const cancelled = executeTool(call("run", runArgs("git", ["--probe"])), root, cancellation);
    record("git_prelaunch_cancellation", cancelled.failed && cancelled.output.indexOf("cancelled") >= 0, 0);

    const background = executeTool(call("run", runArgs("git", ["--probe", "background-ok"], true)), root);
    bool backgroundCorrect;
    if (!background.failed)
    {
        const marker = background.output.indexOf("processId: ");
        if (marker >= 0)
        {
            auto tail = background.output[cast(size_t) marker + 11 .. $];
            const end = tail.indexOf('\n');
            const id = end < 0 ? tail : tail[0 .. cast(size_t) end];
            foreach (_; 0 .. 40)
            {
                JSONValue value; value["action"] = "output"; value["processId"] = id;
                const output = executeTool(call("process", value), root);
                if (output.output.indexOf("background-ok") >= 0) { backgroundCorrect = true; break; }
                Thread.sleep(25.msecs);
            }
        }
    }
    record("git_background_resolution", backgroundCorrect, 0);

    // The real installed Git is read-only here; its repository is synthetic.
    const realGit = environment.get("AURORA_TEST_GIT");
    assert(realGit.length, "AURORA_TEST_GIT must name the installed Git executable");
    const repository = buildPath(root, "real-repository"); mkdirRecurse(repository);
    const init = executeTool(call("run", runArgs(realGit, ["init", repository])), root);
    environment["PATH"] = noGitPath;
    environment["LOCALAPPDATA"] = oldLocal; environment["ProgramFiles"] = oldProgram;
    const status = executeTool(call("run", runArgs("git", ["-C", repository, "status", "--porcelain"])), root);
    record("real_git_status_without_PATH", !init.failed && !status.failed && status.workspaceUnchanged, 0,
        status.failed ? status.output : "real Git status; synthetic repository; read-only evidence preserved");

    // Search workloads mirror large code/log trees, without copying any chat text.
    const corpus = buildPath(root, "corpus"); mkdirRecurse(corpus);
    const line = "ordinary source line with ASCII words and no search marker at all\n";
    foreach (i; 0 .. 16) write(buildPath(corpus, "source" ~ to!string(i) ~ ".d"), line.replicate(30_000));
    write(buildPath(corpus, "source-hit.d"), "CANARY_CHAT_EVAL\n");
    write(buildPath(corpus, "notes.log"), line.replicate(30_000) ~ "CANARY_CHAT_EVAL\n");
    mkdirRecurse(buildPath(corpus, "build"));
    write(buildPath(corpus, "build", "ignored.d"), "CANARY_CHAT_EVAL\n");
    write(buildPath(corpus, "ignored.exe"), "CANARY_CHAT_EVAL\n");
    JSONValue search; search["pattern"] = "CANARY_CHAT_EVAL";
    search["literal"] = true; search["mode"] = "count";
    search["path"] = corpus; search["timeout"] = 60_000;
    grepCase("grep_large_ascii_tree", search, ["Total: 2 matching lines in 2 files."], ["ignored.d:", "ignored.exe:"]);
    search["include"] = "*.d";
    grepCase("grep_focused_ascii_tree", search, ["Total: 1 matching line in 1 file."], ["notes.log:"]);

    const context = buildPath(root, "context.txt");
    write(context, "початок\nbefore\nneedle-é\nafter\nend\nneedle-é\ntail\n");
    search = parseJSON(`{"pattern":"needle-é","literal":true,"context":1,"format":"classic"}`);
    search["path"] = context;
    grepCase("grep_unicode_context_buffer_lifetime", search,
        ["-2- before", ":3: needle-é", "-4- after", "-5- end", ":6: needle-é", "-7- tail"], ["-1-"]);
    write(buildPath(root, "legacy.txt"), "before\ncaf\xE9\nafter\n");
    search["path"] = buildPath(root, "legacy.txt"); search["pattern"] = "café";
    grepCase("grep_legacy_encoding_context", search, ["-1- before", ":2: café", "-3- after"]);
    write(buildPath(root, "long.txt"), "é".replicate(500) ~ "needle-tail\n");
    search = parseJSON(`{"pattern":"needle-tail","literal":true}`);
    search["path"] = buildPath(root, "long.txt");
    grepCase("grep_matches_beyond_display_truncation", search, ["1:", "…"]);
    search = parseJSON(`{"pattern":"NEEDLE.É","caseSensitive":false,"mode":"count"}`);
    search["path"] = context;
    grepCase("grep_case_insensitive_regex_count", search, ["Total: 2 matching lines in 1 file."]);
    search["mode"] = "files";
    grepCase("grep_file_names_only", search, ["context.txt"], ["needle-é"]);

    const validPlan = executeTool(call("update_plan", parseJSON(`{"plan":[{"step":"Inspect fixture","kind":"research","status":"completed"},{"step":"Make change","kind":"edit","status":"in_progress"}]}`)), root);
    const invalidPlan = executeTool(call("update_plan", parseJSON(`{"plan":[{"step":"Make change","kind":"in_progress"}]}`)), root);
    record("plan_schema_status_and_kind_remain_distinct", !validPlan.failed && invalidPlan.failed && invalidPlan.output.indexOf("invalid kind") >= 0, 0);
    write(args[2], JSONValue(outcomes).toPrettyString());
    return 0;
}
