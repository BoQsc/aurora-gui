module actor_recovery_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
import actorview : ActorTestView;
import auroraopencode.tools : buildSystemPrompt, nativeOnlyToolDefinitions;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, exists, write;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run test_actor_recovery.py");
    const directory = absolutePath("actor-recovery-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));

    foreach (mode; ["retry", "retry-stop", "transient-cap", "budget", "quota", "bad-output", "summary", "summary-error", "task-stall", "unoffered", "mixed-offer"])
    {
        const workspace = buildPath(directory, mode); mkdirRecurse(workspace);
        ChatSession initial; initial.id = "recovery-" ~ mode; initial.model = "actor-" ~ mode;
        const persistent = mode == "budget" || mode == "transient-cap" || mode == "bad-output" || mode == "retry-stop" || mode == "unoffered";
        if (persistent) { initial.goal = "Deliver the user's requested analysis"; initial.goalStatus = "active"; }
        ActorConfiguration config; config.baseUrl = base; config.apiKey = "fixture";
        config.workspace = workspace; config.recordTrace = true;
        config.outageBudgetMs = mode == "budget" || mode == "quota" ? 250 : 15_000;
        config.request.toolsEnabled = mode == "bad-output" || mode == "summary" || mode == "summary-error" || mode == "task-stall" || mode == "unoffered" || mode == "mixed-offer";
        config.request.contextLimit = 64_000;
        config.request.baseSystemPrompt = buildSystemPrompt(config.request.toolsEnabled, workspace, "win32", "auto");
        config.request.availableTools = nativeOnlyToolDefinitions();
        if (mode == "unoffered" || mode == "mixed-offer")
        {
            config.request.availableTools = null;
            foreach (tool; nativeOnlyToolDefinitions()) if (tool.name == "read") config.request.availableTools ~= tool;
        }
        if (mode == "mixed-offer") write(buildPath(workspace, "allowed.txt"), "Allowed input");
        auto actor = new ConversationActor(initial, config, null);
        auto view = new ActorTestView(initial, actor);
        assert(actor.post(ActorCommand(ActorCommandKind.start, "Analyze the tradeoffs of this design.")) == ActorAdmission.accepted);
        JSONValue latest;
        bool sawWait, sawFailure, stopped;
        auto quietUntil = MonoTime.init;
        const deadline = MonoTime.currTime + 20.seconds;
        bool settled;
        while (MonoTime.currTime < deadline)
        {
            foreach (change; view.take())
            {
                assert(change.kind != ActorChangeKind.fault, change.text);
                if (change.kind == ActorChangeKind.updated)
                {
                    const message = parseJSON(change.text);
                    if (auto failed = "failed" in message.object) if (failed.boolean) sawFailure = true;
                }
            }
            latest = view.header;
            if (view.model.turnStatus == "failed") sawFailure = true;
            if (view.projection.execution.retryRemainingMs >= 0)
            {
                sawWait = true;
                assert(view.model.turnStatus == "running" && view.projection.busy, "Retry backoff advertised a terminal turn");
            }
            assert(!actor.fault().length, actor.fault());
            if (mode == "retry-stop" && sawWait && !stopped)
            {
                assert(actor.stop() == ActorAdmission.accepted);
                stopped = true; quietUntil = MonoTime.currTime + 3300.msecs;
            }
            if (latest.type == JSONType.object)
            {
                const status = latest["turnStatus"].str;
                if (mode == "retry-stop") settled = stopped && status == "interrupted" && MonoTime.currTime >= quietUntil;
                else if (mode == "budget" || mode == "transient-cap" || mode == "bad-output" || mode == "task-stall" || mode == "unoffered")
                    settled = status == "failed" && latest["execution"]["retryRemainingMs"].integer < 0;
                else settled = status == "completed";
            }
            if (settled) break;
            Thread.sleep(5.msecs);
        }
        assert(settled, mode ~ " did not settle");
        if (mode == "retry" || mode == "retry-stop" || mode == "quota") assert(sawWait && sawFailure, mode);
        if (mode == "transient-cap" || mode == "budget") assert(!sawWait, "Exhausted transport recovery restarted an outer loop");
        actor.close(); assert(!actor.fault().length, actor.fault());
        const snapshot = actor.finalSnapshot();
        const state = parseJSON(snapshot);
        if (persistent && mode != "retry-stop") assert(state["goalStatus"].str == "active", mode ~ " discarded the active goal");
        if (mode == "retry-stop") assert(state["goalStatus"].str == "paused");
        if (mode == "task-stall")
            assert(state["verificationStatus"].str == "required" && state["objective"].str.length,
                "No-action recovery discarded the unfinished verification/task");
        if (mode == "unoffered" || mode == "mixed-offer") assert(!exists(buildPath(workspace, "forbidden.txt")), "An unoffered tool executed");
        if (mode == "mixed-offer")
        {
            bool acceptedRead, rejectedWrite;
            foreach (message; state["messages"].array)
                if (message["role"].str == "tool")
                {
                    if (message["toolName"].str == "read") acceptedRead = !("failed" in message.object);
                    if (message["toolName"].str == "write") rejectedWrite = message["failed"].boolean;
                }
            assert(acceptedRead && rejectedWrite, "A mixed batch lost the accepted or rejected outcome");
        }
        if (mode == "summary" || mode == "summary-error")
        {
            assert(!exists(buildPath(workspace, "must-not-exist.txt")), "Summary executed an unavailable tool");
            assert(state["messages"].array[$ - 1]["content"].str.length > 80, "Missing evidence fallback");
            assert(latest["execution"]["phase"].str == "completed", "Summary fallback left execution in a tool phase");
        }
        const trace = actor.recordedTrace();
        write(buildPath(workspace, "trace.json"), trace); write(buildPath(workspace, "final.json"), snapshot);
        config.baseUrl = "http://127.0.0.1:1";
        assert(parseJSON(ConversationActor.replay(initial, config, trace)) == state,
            mode ~ " replay changed retry, cancellation, protocol recovery or handoff state");
        writeln("PASS actor recovery ", mode);
    }
    return 0;
}
