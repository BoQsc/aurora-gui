module actor_recovery_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
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

    foreach (mode; ["retry", "retry-stop", "transient-cap", "budget", "quota", "bad-output", "summary", "summary-error"])
    {
        const workspace = buildPath(directory, mode); mkdirRecurse(workspace);
        ChatSession initial; initial.id = "recovery-" ~ mode; initial.model = "actor-" ~ mode;
        const persistent = mode == "budget" || mode == "transient-cap" || mode == "bad-output" || mode == "retry-stop";
        if (persistent) { initial.goal = "Deliver the user's requested analysis"; initial.goalStatus = "active"; }
        ActorConfiguration config; config.baseUrl = base; config.apiKey = "fixture";
        config.workspace = workspace; config.recordTrace = true;
        config.outageBudgetMs = mode == "budget" || mode == "quota" ? 250 : 15_000;
        config.request.toolsEnabled = mode == "bad-output" || mode == "summary" || mode == "summary-error";
        config.request.contextLimit = 64_000;
        config.request.baseSystemPrompt = buildSystemPrompt(config.request.toolsEnabled, workspace, "win32", "auto");
        config.request.availableTools = nativeOnlyToolDefinitions();
        auto actor = new ConversationActor(initial, config, null);
        assert(actor.post(ActorCommand(ActorCommandKind.start, "Analyze the tradeoffs of this design.")) == ActorAdmission.accepted);
        JSONValue latest;
        bool sawWait, sawFailure, stopped;
        auto quietUntil = MonoTime.init;
        const deadline = MonoTime.currTime + 20.seconds;
        bool settled;
        while (MonoTime.currTime < deadline)
        {
            foreach (change; actor.takeChanges())
            {
                assert(change.kind != ActorChangeKind.fault, change.text);
                if (change.kind != ActorChangeKind.metadata) continue;
                latest = parseJSON(change.text);
                if (latest["turnStatus"].str == "failed") sawFailure = true;
                if (latest["execution"]["retryRemainingMs"].integer >= 0) sawWait = true;
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
                else if (mode == "budget" || mode == "transient-cap" || mode == "bad-output")
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
