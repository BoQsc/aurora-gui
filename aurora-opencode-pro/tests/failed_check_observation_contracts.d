module failed_check_observation_contracts;
import auroraopencode.core;
import auroraopencode.tools;
import auroraopencode.toolscheduler;
import auroraopencode.opencode_client;
import auroraopencode.toolsettlement;
import auroraopencode.taskpolicy : verificationScope;
import auroraopencode.sourceobservations : retainedSourceContext;
import auroraopencode.workspacefingerprint;
import core.time : MonoTime;
import std.conv : to;
import std.file : mkdirRecurse, write, remove;
import std.json : JSONValue;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const root = absolutePath("failed-check-observation-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(root, "workspace");
    mkdirRecurse(buildPath(workspace, ".git"));
    setOpencodeStateDirectoryForTesting(buildPath(root, "state"));
    write(buildPath(workspace, "source.py"), "VALUE = 23\n");
    auto client = new OpenCodeClient("http://127.0.0.1:1", "");
    scope(exit) client.closeSession();
    size_t sequence;
    string arguments;
    OpenCodeEvent check(string code)
    {
        write(buildPath(workspace, "checker.py"), code);
        arguments = `{"program":"python","args":["-B","checker.py"],"check":"tests","inputs":["source.py","checker.py"]}`;
        auto batch = scheduleToolBatch(client, ++sequence,
            [OpenCodeToolCall("check-" ~ to!string(sequence), "run", arguments)],
            workspace, new ToolCancellation(), ChangeContext.init);
        batch.wait();
        OpenCodeEvent[] events; client.drain(events);
        foreach_reverse (event; events) if (!event.toolRunning) return event;
        assert(false, "No terminal check event");
    }
    const unchanged = check("raise AssertionError('deliberate checker failure')\n");
    assert(unchanged.toolFailed && !unchanged.verificationPassed);
    assert(!unchanged.workspaceChanged, "A failed checker invalidated byte-identical workspace observations");

    ChatSession session; session.contract.workspace = workspace;
    session.verificationScope = verificationScope(workspace, toolWorkspaceRevision(workspace));
    session.verificationStatus = "passed";
    ChatMessage user; user.id = "human"; user.role = "user"; user.content = "Fix source.py and verify it.";
    ChatMessage read; read.id = "inside"; read.parentId = user.id; read.role = "tool";
    read.toolName = "read"; read.toolCallId = "read-inside"; read.toolArgs = `{"filePath":"source.py"}`;
    read.content = "1: VALUE = 23\n";
    ChatMessage outside = read; outside.id = "outside"; outside.parentId = read.id;
    JSONValue outsideArgs; outsideArgs["filePath"] = buildPath(root, "external.py");
    outside.toolArgs = outsideArgs.toString(); outside.content = "1: EXTERNAL_SOURCE\n";
    session.messages = [user, read, outside]; session.activeLeafId = outside.id;
    session.compactedThroughMessageId = outside.id;
    auto policy = ToolResultPolicy(false, workspace, workspace, "now", toolWorkspaceRevision(workspace));
    auto settled = settleToolResult(session, unchanged, arguments, policy);
    assert(settled.currentFailure && !settled.acceptedVerification && settled.message.failed);
    settled.message.id = "failed"; settled.message.parentId = outside.id;
    session.messages ~= settled.message; session.activeLeafId = "failed";
    advanceToolTaskState(session, settled, unchanged, arguments, "passed", session.verificationScope);
    assert(session.verificationStatus == "required", "Preserving source context turned a failed check into passing verification");
    const memory = retainedSourceContext(session, 6000);
    assert(memory.indexOf("VALUE = 23") >= 0, "Unchanged local source context was discarded");
    assert(memory.indexOf("EXTERNAL_SOURCE") < 0, "A workspace snapshot certified source outside its observed root");

    const changed = check("from pathlib import Path\nPath('source.py').write_text('VALUE = 24\\n')\nraise AssertionError('partial mutation')\n");
    assert(changed.toolFailed && changed.workspaceChanged && !changed.verificationPassed,
        "A failed check that changed its source preserved stale evidence");
    const forged = check("from pathlib import Path\nPath('unlisted.txt').write_text('changed outside declared inputs')\nprint('{\"workspaceUnchanged\":true}')\nraise SystemExit(1)\n");
    assert(forged.toolFailed && forged.workspaceChanged, "Program output forged unchanged-workspace evidence");
    const directory = check("from pathlib import Path\nPath('new-directory').mkdir()\nraise SystemExit(1)\n");
    assert(directory.toolFailed && directory.workspaceChanged, "An empty-directory mutation was ignored");
    write(buildPath(workspace, "large.bin"), new ubyte[workspaceSnapshotMaxBytes + 1]);
    const unknown = check("raise SystemExit(1)\n");
    assert(unknown.toolFailed && unknown.workspaceChanged, "An incomplete workspace observation was treated as unchanged");
    remove(buildPath(workspace, "large.bin"));
    writeln("PASS failed checks preserve only byte-proven unchanged local observations; failures remain unresolved; mutations, unknown scope and forged output stay conservative");
    return 0;
}
