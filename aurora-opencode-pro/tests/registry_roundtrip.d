module registry_roundtrip;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.conversationregistry;
import auroraopencode.conversationprojection;
import auroraopencode.conversationencode : sessionToJson;
import auroraopencode.repository : ConversationRepository, RepositoryRuntime;
import auroraopencode.runtime : AgentEventKind;
import auroraopencode.tools : buildSystemPrompt, nativeOnlyToolDefinitions;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, readText, write;
import std.json : parseJSON;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run test_provider_roundtrip.py --registry");
    const directory = absolutePath("registry-roundtrip-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(directory, "workspace"); mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    if (environment.get("AURORA_CONTRACT_RECIPE", "") == "1") mkdirRecurse(buildPath(workspace, ".git"));
    auto repository = new ConversationRepository(); scope (exit) repository.close();
    auto journal = new RepositoryRuntime(repository, buildPath(directory, "events.jsonl"));
    ChatSession initial; initial.id = "registry-http-chat"; initial.model = "fixture";
    const stalled = environment.get("AURORA_CONTRACT_GOAL_STALL", "") == "1";
    if (stalled) { initial.goal = "Deliver and verify the fixture"; initial.goalStatus = "active"; }
    ActorConfiguration config; config.baseUrl = base; config.apiKey = "fixture"; config.workspace = workspace;
    config.request.toolsEnabled = true; config.request.contextLimit = 64_000;
    config.request.baseSystemPrompt = buildSystemPrompt(true, workspace, "win32", "auto");
    config.request.availableTools = nativeOnlyToolDefinitions();
    auto registry = new ConversationRegistry(journal, 1); scope (exit) registry.close();
    assert(registry.register(initial, config) == ActorAdmission.accepted);
    assert(registry.post(initial.id, ActorCommand(ActorCommandKind.start,
        "Write out.txt containing success, verify its contents with unittest, then reply READY.")) == ActorAdmission.accepted);
    bool finished;
    const deadline = MonoTime.currTime + 30.seconds;
    // Never drain or apply a presentation change until the entire turn is
    // durably terminal. No GUI, timer, window wake or rendering participates.
    while (!finished && MonoTime.currTime < deadline)
    {
        foreach (event; journal.history())
            if (event.kind == (stalled ? AgentEventKind.turnFailed : AgentEventKind.turnCompleted)) finished = true;
        assert(registry.activeWorkers() <= 1);
        Thread.sleep(10.msecs);
    }
    assert(finished, "Lifecycle-owned conversation depended on a presentation drain");
    registry.close();
    auto states = registry.takeClosedSessions(); assert(states.length == 1);
    assert(readText(buildPath(workspace, "out.txt")) == "success");
    const state = sessionToJson(states[0]);
    assert(state["messages"].array[$ - 1]["content"].str == "READY" && state["verificationStatus"].str == "passed");
    if (stalled) assert(state["goalStatus"].str == "active");
    ChatSession view = initial; auto projection = new ConversationProjection(view);
    foreach (delivery; registry.takeChanges(16))
    {
        assert(!delivery.error.length && delivery.generation == 1, delivery.error);
        auto applied = projection.apply(view, delivery.changes);
        assert(!applied.error.length && !applied.needsSnapshot, applied.error);
    }
    assert(sessionToJson(view) == state, "An unrendered turn could not resynchronize its full final state");
    write(buildPath(directory, "final.json"), state.toString());
    writeln("PASS lifecycle-owned HTTP/SSE/native tools settle durably without any presentation drain; final state resynchronizes");
    return 0;
}
