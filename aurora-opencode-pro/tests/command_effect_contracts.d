module command_effect_contracts;

import auroraopencode.core;
import auroraopencode.tools;
import auroraopencode.toolscheduler;
import auroraopencode.opencode_client;
import core.time : MonoTime;
import std.conv : to;
import std.file : mkdirRecurse, write, readText, tempDir;
import std.json : JSONValue;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;

OpenCodeToolCall run(string program, string[] args)
{
    JSONValue value; value["program"] = program; value["args"] = JSONValue(args);
    value["timeout"] = 5000;
    return OpenCodeToolCall("probe", "run", value.toString());
}

OpenCodeEvent dispatch(OpenCodeToolCall call, string workspace)
{
    auto client = new OpenCodeClient("http://127.0.0.1:9", "fixture");
    scope(exit) client.closeSession();
    auto batch = scheduleToolBatch(client, 1, [call], workspace,
        new ToolCancellation(), ChangeContext.init);
    batch.wait(); OpenCodeEvent[] events; client.drain(events);
    foreach(event; events)
        if(event.kind == OpenCodeEventKind.toolResult && !event.toolRunning) return event;
    assert(false, "No terminal tool event"); return OpenCodeEvent.init;
}

int main(string[] args)
{
    const helper = runFilesystemHelperMode(args); if(helper >= 0) return helper;
    assert(args.length == 3, "usage: fixture <child.exe> <results.json>");
    const workspace = buildPath(tempDir(), "aurora-command-workspace-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(absolutePath("state-" ~ to!string(MonoTime.currTime.ticks)));
    write(buildPath(workspace, "source.d"), "int value = 1;\n");
    JSONValue[] rows;
    void check(string name, OpenCodeToolCall call, bool expectedChanged, bool expectedFailed = false)
    {
        const before = toolWorkspaceRevision(workspace); const began = MonoTime.currTime;
        const event = dispatch(call, workspace);
        JSONValue row; row["case"] = name;
        row["correct"] = event.workspaceChanged == expectedChanged && event.toolFailed == expectedFailed &&
            !event.verificationPassed && toolWorkspaceRevision(workspace) == before + (event.workspaceChanged ? 1 : 0);
        row["changed"] = event.workspaceChanged; row["failed"] = event.toolFailed;
        row["milliseconds"] = (MonoTime.currTime - began).total!"msecs";
        rows ~= row; writeln(row.toString());
    }
    check("successful_readonly_executable", run(args[1], ["read", "source.d"]), false);
    check("successful_mutating_executable", run(args[1], ["write", "source.d"]), true);
    check("new_file_creation", run(args[1], ["write", "created.d"]), true);
    check("failed_executable_retains_requirement", run(args[1], ["fail"]), true, true);
    auto timeout = run(args[1], ["sleep"]); auto timeoutArgs = JSONValue.init;
    import std.json : parseJSON;
    timeoutArgs = parseJSON(timeout.arguments); timeoutArgs["timeout"] = 100; timeout.arguments = timeoutArgs.toString();
    check("timeout_retains_requirement", timeout, true, true);
    auto background = run(args[1], ["read", "source.d"]);
    auto bgArgs = parseJSON(background.arguments); bgArgs["background"] = true; background.arguments = bgArgs.toString();
    check("background_is_not_proven_readonly", background, true);
    check("retire_images_is_context_only", OpenCodeToolCall("retire", "retire_images",
        `{"imageIds":["synthetic-image"],"summary":"Synthetic visual facts preserved."}`), false);
    check("blocker_is_control_only", OpenCodeToolCall("blocker", "task_blocker",
        `{"kind":"external","reason":"Synthetic dependency unavailable"}`), false);
    const developer = buildPath(tempDir(), "aurora-command-source-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(developer);
    auto previous = installDeveloperToolSource(developer);
    scope(exit) restoreDeveloperToolSource(previous);
    const sourceRevision = toolWorkspaceRevision(developer);
    check("separate_developer_source_stays_conservative", run(args[1], ["read", "source.d"]), false);
    JSONValue sourceRow; sourceRow["case"] = "separate_source_revision_invalidated";
    sourceRow["correct"] = toolWorkspaceRevision(developer) == sourceRevision + 1;
    sourceRow["milliseconds"] = 0; rows ~= sourceRow;
    write(args[2], JSONValue(rows).toPrettyString()); return 0;
}
