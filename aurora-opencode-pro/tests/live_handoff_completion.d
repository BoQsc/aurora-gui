// Opt-in real provider continuation from the live handoff's pre-completion
// checkpoint. No canned model responses, tool results or replacement assets.
module live_handoff_completion;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.conversationcodec : decodeSessionMetadata, decodeMessages;
import auroraopencode.conversationprojection : ConversationProjection;
import auroraopencode.taskflow : restoreBranchTask;
import auroraopencode.tools : buildSystemPrompt, nativeOnlyToolDefinitions;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.conv : to;
import std.file : mkdirRecurse, readText, write;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : startsWith;

void main()
{
    const replay = environment.get("AURORA_LIVE_HANDOFF_DIRECTORY", "");
    assert(replay.length, "Explicit live replay directory required; this makes real provider requests");
    const workspace = buildPath(replay, "TerraForest");
    const state = buildPath(replay, "appdata", "Aurora OpenCode");
    const saved = parseJSON(readText(buildPath(state, "threads.index.json")));
    ChatSession initial;
    foreach (row; saved["sessions"].array)
        if (row["title"].str.startsWith("Live player handoff")) decodeSessionMetadata(row, initial);
    assert(initial.id.length);
    auto history = parseJSON(readText(buildPath(state, "threads", initial.id ~ ".json")));
    decodeMessages(history["messages"], initial);
    size_t boundary = initial.messages.length;
    foreach (i, message; initial.messages)
    {
        bool completion;
        foreach (call; message.toolCalls) if (call.name == "goal_complete") completion = true;
        if (completion) { boundary = i; break; }
    }
    assert(boundary > 50 && boundary < initial.messages.length, "Not a real pre-completion checkpoint");
    initial.messages = initial.messages[0 .. boundary].dup;
    initial.activeLeafId = initial.messages[$ - 1].id;
    restoreBranchTask(initial);
    initial.goalStatus = "active";
    initial.turnStatus = "idle";
    initial.goalHistory = null; // Later completion history cannot leak backward.
    assert(initial.verificationStatus == "required", "Checkpoint must retain its actual unfinished verification");
    auto settings = loadSettings(); // Read provider credentials; never write them to artifacts.
    assert(settings.baseUrl.length && settings.apiKey.length);
    initial.thinking = effectiveThinkingForModel(settings, settings.baseUrl, initial.model);
    const output = absolutePath("live-handoff-completion-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(output);
    setOpencodeStateDirectoryForTesting(buildPath(output, "state"));
    ActorConfiguration config;
    config.baseUrl = settings.baseUrl; config.apiKey = settings.apiKey;
    config.workspace = workspace;
    config.request.toolsEnabled = true;
    config.request.contextLimit = 500_000;
    config.request.availableTools = nativeOnlyToolDefinitions();
    config.request.baseSystemPrompt = buildSystemPrompt(true, workspace, "win32");
    auto actor = new ConversationActor(initial, config, null);
    scope(exit) actor.close();
    auto projection = new ConversationProjection(initial);
    ChatSession view = initial;
    assert(actor.post(ActorCommand(ActorCommandKind.start)) == ActorAdmission.accepted);
    bool sawRunning, completed;
    const started = MonoTime.currTime;
    const deadline = started + 600.seconds;
    while (MonoTime.currTime < deadline && !completed)
    {
        const applied = projection.apply(view, actor.takeChanges());
        assert(!applied.error.length, applied.error);
        if (applied.requestSnapshot) actor.post(ActorCommand(ActorCommandKind.snapshot));
        sawRunning = sawRunning || projection.busy;
        completed = sawRunning && !projection.busy && view.turnStatus == "completed";
        assert(!actor.fault().length, actor.fault());
        Thread.sleep(20.msecs);
    }
    actor.close();
    auto finalState = parseJSON(actor.finalSnapshot());
    write(buildPath(output, "final.json"), finalState.toPrettyString());
    size_t historyLookups, verifications, failures, tools;
    foreach (message; finalState["messages"].array[boundary .. $])
        if (message["role"].str == "tool")
        {
            ++tools;
            const name = message["toolName"].str;
            const failed = "failed" in message.object && message["failed"].boolean;
            if (name == "read_history") ++historyLookups;
            if (name == "verify" && !failed) ++verifications;
            if (failed) ++failures;
        }
    JSONValue report;
    report["completed"] = completed;
    report["historyLookups"] = historyLookups;
    report["acceptedVerifications"] = verifications;
    report["toolResults"] = tools;
    report["failedTools"] = failures;
    report["seconds"] = (MonoTime.currTime - started).total!"seconds";
    report["model"] = initial.model;
    report["taskStatus"] = finalState["taskStatus"];
    report["goalStatus"] = finalState["goalStatus"];
    report["verificationStatus"] = finalState["verificationStatus"];
    write(buildPath(output, "result.json"), report.toPrettyString());
    writeln("LIVE COMPLETION ", report.toString(), " ARTIFACTS ", output);
    assert(completed && finalState["taskStatus"].str == "completed" &&
        finalState["goalStatus"].str == "completed" && finalState["verificationStatus"].str == "passed",
        "Real task continuation did not finish");
    assert(verifications > 0 && historyLookups <= 2, "Receipt bookkeeping still caused a history-search detour");
}
