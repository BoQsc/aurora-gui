module actor_diagnostic_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.conversationencode;
import auroraopencode.repository;
import auroraopencode.runtime : projectAgentRuntimeEvents;
import auroraopencode.tools : buildSystemPrompt, nativeOnlyToolDefinitions;
import actorview;
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
    assert(base.length && releases.length, "Run test_actor_diagnostics.py");
    const directory = absolutePath("actor-diagnostics-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    foreach (mode; ["read", "badtool", "unavailable", "stop", "bounded"])
    {
        const workspace = buildPath(directory, mode); mkdirRecurse(workspace); write(buildPath(workspace, "evidence.txt"), "Recorded diagnostic evidence");
        ChatSession initial; initial.id = mode; initial.model = "main-" ~ mode;
        initial.goal = "Preserve the user's acceptance condition"; initial.goalStatus = "paused";
        ActorConfiguration config; config.baseUrl = base; config.workspace = workspace; config.recordTrace = true;
        config.diagnosticModel = "review-" ~ mode; config.outageBudgetMs = 3000;
        config.request.toolsEnabled = true; config.request.contextLimit = 64_000;
        config.request.baseSystemPrompt = buildSystemPrompt(true, workspace, "win32", "auto");
        config.request.availableTools = nativeOnlyToolDefinitions();
        auto repository = new ConversationRepository(); auto journal = new RepositoryRuntime(repository, buildPath(directory, mode ~ "-events.jsonl"));
        auto actor = new ConversationActor(initial, config, journal); auto view = new ActorTestView(initial, actor);
        actor.post(ActorCommand(ActorCommandKind.start, "Analyze the tradeoffs of this design."));
        bool sawReview, stopped;
        const deadline = MonoTime.currTime + 15.seconds;
        while (MonoTime.currTime < deadline)
        {
            foreach (change; view.take())
                if (change.kind == ActorChangeKind.metadata || change.kind == ActorChangeKind.metadataPatch)
                {
                    const header = parseJSON(change.text);
                    if (auto execution = "execution" in header.object)
                        if ((*execution)["diagnosticReview"].boolean)
                        { sawReview = true; assert((*execution)["requestModel"].str == config.diagnosticModel); }
                }
            assert(!actor.fault().length, actor.fault());
            if (view.projection.execution.diagnosticReview)
            {
                sawReview = true; assert(view.projection.execution.requestModel == config.diagnosticModel);
                assert(view.model.model == initial.model, "Review replaced the user's selected model");
            }
            if (mode == "stop" && sawReview && !stopped && exists(buildPath(releases, "stop.started")))
            { actor.stop(); stopped = true; write(buildPath(releases, "stop.release"), "release"); }
            if (!actor.activity().busy && (view.model.turnStatus == "completed" || view.model.turnStatus == "interrupted")) break;
            Thread.sleep(2.msecs);
        }
        assert(sawReview, "No review observed: " ~ mode);
        assert(view.model.turnStatus == (mode == "stop" ? "interrupted" : "completed"), mode ~ " failed to return to the main model");
        assert(!exists(buildPath(workspace, "forbidden.txt")), "A diagnostic tool mutated the workspace");
        actor.close(); assert(!actor.fault().length, actor.fault());
        const state = parseJSON(actor.finalSnapshot()); const trace = actor.recordedTrace();
        write(buildPath(directory, mode ~ "-trace.json"), trace);
        auto recovered = projectAgentRuntimeEvents(journal.history()); repository.close();
        assert(recovered.length == 1 && sessionToJson(recovered[0]) == state, "Journal recovery lost diagnostic evidence");
        auto offline = config; offline.baseUrl = "http://127.0.0.1:1";
        assert(parseJSON(ConversationActor.replay(initial, offline, trace)) == state, "Offline diagnostic replay differs: " ~ mode);
        assert(state["goalStatus"].str == "paused");
        if (mode != "stop") assert(state["messages"].array[$ - 1]["content"].str.indexOf("MAIN RESULT") >= 0,
            "Diagnostic prose was presented as the final task result");
        writeln("PASS HTTP automatic diagnosis ", mode);
    }
    return 0;
}
