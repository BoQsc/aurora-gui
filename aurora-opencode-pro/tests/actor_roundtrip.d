module actor_roundtrip;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.conversationencode;
import auroraopencode.conversationprojection;
import auroraopencode.repository : ConversationRepository, RepositoryRuntime;
import auroraopencode.tools : buildSystemPrompt, nativeOnlyToolDefinitions;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.file : mkdirRecurse, readText, rename, write;
import std.json : parseJSON;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.conv : to;
import std.stdio : writeln;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run test_provider_roundtrip.py --actor");
    const directory = absolutePath("actor-roundtrip-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(directory, "workspace");
    mkdirRecurse(workspace); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    if (environment.get("AURORA_CONTRACT_RECIPE", "") == "1") mkdirRecurse(buildPath(workspace, ".git"));
    auto repository = new ConversationRepository(); scope (exit) repository.close();
    auto journal = new RepositoryRuntime(repository, buildPath(directory, "events.jsonl"));
    ChatSession initial; initial.id = "autonomous-chat"; initial.model = "fixture";
    const stalledGoal = environment.get("AURORA_CONTRACT_GOAL_STALL", "") == "1";
    if (stalledGoal)
    { initial.goal = "Deliver and verify the requested fixture"; initial.goalStatus = "active"; }
    ActorConfiguration config; config.baseUrl = base; config.apiKey = "fixture";
    config.workspace = workspace; config.recordTrace = true;
    config.request.toolsEnabled = true; config.request.contextLimit = 64_000;
    config.request.baseSystemPrompt = buildSystemPrompt(true, workspace, "win32", "auto");
    config.request.availableTools = nativeOnlyToolDefinitions();
    auto actor = new ConversationActor(initial, config, journal);
    auto projection = new ConversationProjection(initial);
    ChatSession view = initial;
    bool sawRunningTool, sawCompletedTool;
    assert(actor.post(ActorCommand(ActorCommandKind.start,
        "Write out.txt containing success, verify its contents with unittest, then reply READY.")) == ActorAdmission.accepted);
    bool ready;
    const deadline = MonoTime.currTime + 30.seconds;
    // There is no GuiWindow, native tick, layout or UI service in this process.
    while (MonoTime.currTime < deadline && !ready)
    {
        auto changes = actor.takeChanges();
        auto applied = projection.apply(view, changes);
        assert(!applied.error.length, applied.error);
        if (applied.needsSnapshot) actor.post(ActorCommand(ActorCommandKind.snapshot));
        foreach (change; changes)
        {
            if (change.kind == ActorChangeKind.toolProgress)
            {
                const progress = parseJSON(change.text);
                sawRunningTool = sawRunningTool || progress["state"].str == "running";
                sawCompletedTool = sawCompletedTool || progress["state"].str == "completed";
            }
            if (change.kind == ActorChangeKind.metadata)
            {
                auto header = parseJSON(change.text);
                ready = header["turnStatus"].str == (stalledGoal ? "failed" : "completed");
            }
        }
        assert(!actor.fault().length, actor.fault());
        Thread.sleep(5.msecs);
    }
    assert(ready, "Autonomous turn never settled");
    actor.close(); assert(!actor.fault().length, actor.fault());
    auto applied = projection.apply(view, actor.takeChanges()); assert(!applied.error.length, applied.error);
    assert(sawRunningTool && sawCompletedTool, "Live tool state never reached the UI projection");
    assert(readText(buildPath(workspace, "out.txt")) == "success");
    const snapshot = actor.finalSnapshot();
    auto value = parseJSON(snapshot);
    assert(sessionToJson(view) == value, "Tool progress projection changed the conversation model");
    assert(value["messages"].array[$ - 1]["content"].str == "READY");
    assert(value["verificationStatus"].str == "passed");
    if (stalledGoal) assert(value["goalStatus"].str == "active", "Output recovery paused the user's persistent goal");
    const trace = actor.recordedTrace();
    write(buildPath(directory, "trace.json"), trace); write(buildPath(directory, "final.json"), snapshot);
    // Replay has neither the original workspace nor access to a provider.
    rename(workspace, workspace ~ "-offline");
    Thread.sleep(1100.msecs);
    config.baseUrl = "http://127.0.0.1:1";
    const replayed = ConversationActor.replay(initial, config, trace);
    write(buildPath(directory, "replayed.json"), replayed);
    assert(parseJSON(replayed) == value, "Replayed provider/tool trace changed transcript or task state");
    auto changed = config; changed.request.toolsEnabled = false;
    bool rejected;
    try ConversationActor.replay(initial, changed, trace); catch (Exception) { rejected = true; }
    assert(rejected, "Replay silently accepted a different behavioral configuration");
    auto incomplete = parseJSON(trace);
    foreach (ref entry; incomplete["frames"].array)
        if (entry["facts"].object.length)
        { entry["facts"] = parseJSON("{}"); break; }
    rejected = false;
    try ConversationActor.replay(initial, config, incomplete.toString()); catch (Exception) { rejected = true; }
    assert(rejected, "Replay silently consulted live state for a missing recorded fact");
    auto events = journal.history();
    assert(events.length > 12, "Actor effects bypassed durable history");
    writeln("PASS autonomous HTTP/provider/native-tool/continuation loop, durable admission and exact offline full-state replay");
    return 0;
}
