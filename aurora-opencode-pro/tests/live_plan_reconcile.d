// Opt-in hosted-model replay of a genuinely ignored plan transition.
module live_plan_reconcile;

import auroraopencode.core;
import auroraopencode.opencode_client;
import auroraopencode.requestpolicy : RequestPolicy, prepareAgentRequest;
import auroraopencode.conversationcodec : decodeSessionMetadata, decodeMessages;
import auroraopencode.taskflow : restoreBranchTask;
import auroraopencode.planprogress : planProgressMarker, planReconciliationDue;
import auroraopencode.tools : buildSystemPrompt, nativeOnlyToolDefinitions;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.conv : to;
import std.file : mkdirRecurse, readText, write;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : startsWith, indexOf;

void main()
{
    const replay = environment.get("AURORA_LIVE_PLAN_DIRECTORY", "");
    assert(replay.length, "Explicit isolated live replay required; this uses the real provider");
    const workspace = buildPath(replay, "TerraForest");
    const state = buildPath(replay, "appdata", "Aurora OpenCode");
    const saved = parseJSON(readText(buildPath(state, "threads.index.json")));
    ChatSession initial;
    foreach (row; saved["sessions"].array)
        if (row["title"].str.startsWith("Live player handoff")) decodeSessionMetadata(row, initial);
    auto history = parseJSON(readText(buildPath(state, "threads", initial.id ~ ".json")));
    decodeMessages(history["messages"], initial);
    size_t marker;
    foreach (i, message; initial.messages)
        if (message.internal && message.content.startsWith(planProgressMarker) &&
            message.content.indexOf(`"phase":1`) >= 0) marker = i;
    assert(marker > 50, "Not the real late-plan checkpoint");
    size_t boundary;
    int replies;
    foreach (i; marker + 1 .. initial.messages.length)
        if (initial.messages[i].role == "assistant" && ++replies == 2) { boundary = i; break; }
    assert(boundary > marker);
    initial.messages = initial.messages[0 .. boundary].dup;
    initial.activeLeafId = initial.messages[$ - 1].id;
    restoreBranchTask(initial);
    initial.turnStatus = "idle";
    assert(planReconciliationDue(initial), "Checkpoint is not awaiting its bounded plan review");
    const settings = loadSettings();
    initial.thinking = effectiveThinkingForModel(settings, settings.baseUrl, initial.model);
    const output = absolutePath("live-plan-reconcile-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(output);
    setOpencodeStateDirectoryForTesting(buildPath(output, "state"));
    RequestPolicy policy;
    policy.toolsEnabled = true; policy.contextLimit = 500_000;
    policy.availableTools = nativeOnlyToolDefinitions();
    policy.baseSystemPrompt = buildSystemPrompt(true, workspace, "win32");
    auto prepared = prepareAgentRequest(initial, policy);
    assert(prepared.tools.length > 1);
    auto client = new OpenCodeClient(settings.baseUrl, settings.apiKey);
    scope(exit) { client.cancel(); client.closeSession(); }
    const started = MonoTime.currTime;
    assert(client.startChatMessages(prepared.messages, prepared.tools, initial.model, initial.thinking) == ChatStartResult.accepted);
    OpenCodeToolCall[] calls;
    bool terminal;
    while (MonoTime.currTime < started + 110.seconds && !terminal)
    {
        OpenCodeEvent[] events;
        client.drain(events);
        foreach (event; events)
        {
            assert(event.kind != OpenCodeEventKind.error, event.text);
            if (event.kind == OpenCodeEventKind.toolCalls) { calls = event.toolCalls; terminal = true; }
            if (event.kind == OpenCodeEventKind.done) terminal = true;
        }
        Thread.sleep(10.msecs);
    }
    JSONValue report;
    report["seconds"] = (MonoTime.currTime - started).total!"seconds";
    report["model"] = initial.model; report["checkpointMessages"] = boundary;
    report["calls"] = JSONValue.emptyArray;
    foreach (call; calls)
    {
        JSONValue row; row["name"] = call.name; row["arguments"] = call.arguments;
        report["calls"].array ~= row;
    }
    write(buildPath(output, "result.json"), report.toPrettyString());
    writeln("LIVE PLAN ", report.toString(), " ARTIFACTS ", output);
    assert(terminal && calls.length == 1 && calls[0].name == "update_plan",
        "Real model skipped reconciliation again; no file operations were executed");
    const plan = parseJSON(calls[0].arguments)["plan"].array;
    assert(plan.length == 4 && plan[1]["status"].str == "completed" &&
        plan[2]["status"].str == "in_progress" && plan[3]["status"].str == "pending",
        "Actual finished investigation and current assembly were not reflected in the plan");

}
