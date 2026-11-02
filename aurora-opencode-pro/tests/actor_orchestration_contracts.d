module actor_orchestration_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.conversationregistry;
import auroraopencode.conversationconfiguration : decodeActorBehavior;
import auroraopencode.conversationencode;
import auroraopencode.conversationcodec;
import auroraopencode.repository;
import auroraopencode.runtime : projectAgentRuntimeEvents;
import auroraopencode.orchestrator : experimentalOrchestratorRoster, experimentalOrchestratorTools;
import auroraopencode.tools : nativeOnlyToolDefinitions;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, exists, write;
import std.json : parseJSON;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", ""), releases = environment.get("AURORA_CONTRACT_RELEASE_DIR", "");
    assert(base.length && releases.length, "Run test_actor_orchestration.py");
    const directory = absolutePath("actor-orchestration-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    foreach (mode; ["serial", "parallel", "stop", "queued-stop", "concurrent"])
    {
        auto repository = new ConversationRepository(); auto journal = new RepositoryRuntime(repository, buildPath(directory, mode ~ "-events.jsonl"));
        ConversationTrace[] recordings;
        auto registry = new ConversationRegistry(journal, mode == "serial" ? 1 : 2, null,
            (ConversationTrace trace) { recordings ~= trace; });
        ChatSession parent; parent.id = "parent-" ~ mode; parent.model = parent.id;
        parent.agents = experimentalOrchestratorRoster(); parent.activeAgentId = "orchestrator";
        foreach (ref agent; parent.agents) if (!agent.router) agent.model = "worker-" ~ mode ~ "-" ~ agent.id;
        ActorConfiguration config; config.baseUrl = base; config.workspace = directory; config.recordTrace = true;
        config.turn.orchestratorEnabled = true; config.request.toolsEnabled = true; config.request.contextLimit = 64_000;
        config.request.availableTools = nativeOnlyToolDefinitions();
        assert(experimentalOrchestratorTools().length > 0);
        assert(registry.register(parent, config) == ActorAdmission.accepted);
        registry.post(parent.id, ActorCommand(ActorCommandKind.start, "Analyze this design using the named participants."));
        string secondId;
        if (mode == "concurrent")
        {
            auto second = parent; second.id ~= "-second"; second.model = second.id; second.agents = second.agents.dup;
            foreach (ref agent; second.agents) if (!agent.router) agent.model = "worker-concurrent-second-" ~ agent.id;
            secondId = second.id; registry.register(second, config);
            registry.post(second.id, ActorCommand(ActorCommandKind.start, "Analyze another independent design."));
        }
        bool stopped, settled; ChatSession[] recovered;
        const deadline = MonoTime.currTime + 20.seconds;
        while (MonoTime.currTime < deadline)
        {
            // Deliberately never drain presentation. Backend dispatch, report
            // collection and continuation must remain autonomous.
            recovered = projectAgentRuntimeEvents(journal.history());
            bool stopReady = mode == "queued-stop" ? exists(buildPath(releases, "queued-stop.started")) :
                mode == "stop" && exists(buildPath(releases, "stop-builder.started")) && exists(buildPath(releases, "stop-reviewer.started"));
            if (stopReady && !stopped)
            {
                registry.post(parent.id, ActorCommand(ActorCommandKind.stop)); stopped = true;
                write(buildPath(releases, mode ~ ".release"), "release");
            }
            foreach (session; recovered) if (session.id == parent.id)
                settled = session.turnStatus == (stopped ? "interrupted" : "completed");
            if (secondId.length)
            {
                bool secondDone;
                foreach (session; recovered) if (session.id == secondId) secondDone = session.turnStatus == "completed";
                settled = settled && secondDone;
            }
            assert(registry.activeWorkers() <= (mode == "serial" ? 1 : 2));
            if (settled) break;
            Thread.sleep(5.msecs);
        }
        assert(settled, "Coordination stalled: " ~ mode);
        registry.close(); assert(!registry.traceFailures().length, "A lifecycle trace was incomplete");
        auto states = registry.takeClosedSessions(); recovered = projectAgentRuntimeEvents(journal.history()); repository.close();
        assert(states.length == (mode == "queued-stop" ? 1 : mode == "concurrent" ? 6 : 3), "Named children were duplicated across rounds");
        foreach (state; states)
        {
            bool found;
            foreach (saved; recovered) if (saved.id == state.id)
            {
                if (sessionToJson(saved) != sessionToJson(state))
                {
                    write(buildPath(directory, mode ~ "-saved.json"), sessionToJson(saved).toString());
                    write(buildPath(directory, mode ~ "-canonical.json"), sessionToJson(state).toString());
                }
                assert(sessionToJson(saved) == sessionToJson(state), "Journal state differs: " ~ mode ~ "/" ~ state.id); found = true;
            }
            assert(found);
        }
        assert(recordings.length >= states.length);
        foreach (trace; recordings)
        {
            ChatSession initial; auto value = parseJSON(trace.initial); decodeSessionMetadata(value, initial); decodeMessages(value["messages"], initial);
            auto behavior = parseJSON(trace.behavior); auto offline = decodeActorBehavior(ActorConfiguration.init, behavior);
            offline.baseUrl = "http://127.0.0.1:1";
            assert(parseJSON(ConversationActor.replay(initial, offline, trace.recording)) == parseJSON(trace.finalState),
                "A lifecycle generation failed exact offline replay: " ~ mode ~ "/" ~ trace.threadId);
            write(buildPath(directory, mode ~ "-" ~ trace.threadId ~ "-" ~ to!string(trace.generation) ~ ".json"), trace.recording);
        }
        writeln("PASS autonomous orchestration ", mode, " states=", states.length, " replayed_generations=", recordings.length);
    }
    return 0;
}
