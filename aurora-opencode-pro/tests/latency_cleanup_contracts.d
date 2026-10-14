module latency_cleanup_contracts;

import auroraopencode.core;
import auroraopencode.controlhistory;
import auroraopencode.requestbuilder : projectRequestMessages;
import auroraopencode.tools : executeTool, ToolCancellation, ChangeContext;
import auroraopencode.toolscheduler : scheduleToolBatch, toolWorkspaceRevision;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent, OpenCodeEventKind;
import auroraopencode.verification;
import core.time : MonoTime;
import std.array : replicate;
import std.conv : to;
import std.file : mkdirRecurse, write, readText;
import std.json : JSONValue;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;
import std.string : indexOf;

void append(ref ChatSession session, string role, string text, bool internal = false)
{
    ChatMessage message;
    message.id = "m" ~ to!string(session.messages.length);
    message.parentId = session.activeLeafId;
    message.role = role; message.content = text; message.internal = internal;
    session.messages ~= message; session.activeLeafId = message.id;
}

OpenCodeToolCall git(string[] args)
{
    JSONValue value; value["program"] = "git";
    value["args"] = JSONValue.emptyArray;
    foreach (arg; args) value["args"].array ~= JSONValue(arg);
    return OpenCodeToolCall("git-fixture", "run", value.toString());
}

int main()
{
    size_t at;
    assert(workspaceCommandEffect("git.exe", ["-C", "repo", "status", "--porcelain"], at) == WorkspaceCommandEffect.readOnly && at == 2);
    assert(workspaceCommandEffect("git", ["config", "user.name"], at) == WorkspaceCommandEffect.readOnly);
    assert(workspaceCommandEffect("git", ["config", "user.name", "Changed"], at) == WorkspaceCommandEffect.unknown);
    assert(workspaceCommandEffect("git", ["commit", "-m", "checkpoint"], at) == WorkspaceCommandEffect.repositoryMetadata);
    foreach (args; [["reset", "--hard"], ["checkout", "main"], ["-c", "alias.status=!bad", "status"], ["log", "--output=source.d"]])
        assert(workspaceCommandEffect("git", args, at) == WorkspaceCommandEffect.unknown);
    assert(workspaceCommandEffect("powershell", ["-Command", "git status"], at) == WorkspaceCommandEffect.unknown);

    const root = absolutePath("latency-cleanup-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(root); setOpencodeStateDirectoryForTesting(buildPath(root, "state"));
    const repository = buildPath(root, "repo"); mkdirRecurse(repository);
    foreach (args; [["init"], ["config", "user.name", "Fixture"], ["config", "user.email", "fixture@example.invalid"]])
    {
        const result = executeTool(git(args), repository);
        assert(!result.failed, result.output);
    }
    write(buildPath(repository, "source.d"), "int value = 1;\n");
    auto client = new OpenCodeClient("http://127.0.0.1:9", "fixture");
    scope(exit) client.closeSession();
    const revision = toolWorkspaceRevision(repository);
    auto batch = scheduleToolBatch(client, 1,
        [git(["config", "user.name"]), git(["add", "-A"]), git(["commit", "-m", "checkpoint"]),
         git(["status", "--porcelain"]), git(["log", "--oneline", "-1"])],
        repository, new ToolCancellation(), ChangeContext.init);
    batch.wait();
    OpenCodeEvent[] events; client.drain(events);
    size_t results;
    foreach (event; events)
        if (event.kind == OpenCodeEventKind.toolResult && !event.toolRunning)
        {
            ++results;
            assert(!event.toolFailed, event.text);
            assert(!event.workspaceChanged, "Git metadata caused a false code-verification requirement: " ~ event.text);
            assert(!event.verificationPassed, "Git metadata must not certify code");
        }
    assert(results == 5 && toolWorkspaceRevision(repository) == revision);
    writeln("PASS real Git metadata/staging/commit leaves workspace revision and code verification unchanged");

    // A real commit hook modifies source without staging it: the content guard
    // must keep the normal verification requirement in this case.
    write(buildPath(repository, ".git", "hooks", "pre-commit"), "#!/bin/sh\nprintf '\\n// hook changed source\\n' >> source.d\n");
    const hooked = executeTool(git(["commit", "--allow-empty", "-m", "hook"]), repository);
    assert(!hooked.failed, hooked.output);
    assert(!hooked.workspaceUnchanged && readText(buildPath(repository, "source.d")).indexOf("hook changed source") >= 0);
    const relative = executeTool(git(["-C", "repo", "diff", "--stat"]), root);
    assert(!relative.failed && relative.workspaceUnchanged, relative.output);
    writeln("PASS hooks that change source remain mutations; relative -C paths are checked correctly");

    ChatSession session;
    append(session, "user", "Original user instruction");
    append(session, "user", durableTaskCheckpointPrefix ~ " user quotation", false);
    foreach (i; 0 .. controlHistoryLimit)
    {
        append(session, "user", durableTaskCheckpointPrefix ~ " old state " ~ to!string(i) ~ "x".replicate(1000), true);
        append(session, "assistant", "Historical answer " ~ to!string(i));
    }
    assert(!controlHistoryCompactionNeeded(session), "Projection changed during a tool turn");
    const oldLeaf = session.activeLeafId;
    const oldWire = projectRequestMessages(session);
    append(session, "user", "A new human request");
    assert(controlHistoryCompactionNeeded(session));
    append(session, "user", controlHistoryBoundary, true);
    append(session, "user", durableTaskCheckpointPrefix ~ " current authoritative state", true);
    const saved = session.messages.length;
    const wire = projectRequestMessages(session);
    assert(wire.length == controlHistoryLimit + 4);
    assert(wire[1].content == durableTaskCheckpointPrefix ~ " user quotation", "User content was discarded");
    assert(wire[$ - 1].content.indexOf("current authoritative state") >= 0);
    size_t oldBytes, compactBytes;
    foreach (message; oldWire) oldBytes += message.content.length;
    foreach (message; wire) compactBytes += message.content.length;
    assert(compactBytes * 5 < oldBytes);
    append(session, "assistant", "New work");
    append(session, "user", durableTaskCheckpointPrefix ~ " updated live state", true);
    assert(!controlHistoryCompactionNeeded(session));
    const next = projectRequestMessages(session);
    foreach (i; 0 .. wire.length) assert(next[i].role == wire[i].role && next[i].content == wire[i].content);
    assert(session.messages.length == saved + 2, "Projection deleted stored history");
    const compactLeaf = session.activeLeafId;
    session.activeLeafId = oldLeaf;
    const sibling = projectRequestMessages(session);
    assert(sibling.length == oldWire.length && sibling[$ - 1].content == oldWire[$ - 1].content);
    session.activeLeafId = compactLeaf;
    writeln("PASS bounded internal-state compaction preserves history, real user text, branch isolation and live request prefixes");
    writeln("MEASURE old_control_request_bytes=", oldBytes, " compact_control_request_bytes=", compactBytes);
    return 0;
}
