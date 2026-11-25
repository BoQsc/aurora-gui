module actor_recovery_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
import actorview : ActorTestView;
import auroraopencode.tools : buildSystemPrompt, nativeOnlyToolDefinitions;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, exists, write, tempDir;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf, split;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run test_actor_recovery.py");
    const directory = absolutePath("actor-recovery-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));

    string[] modes = ["retry", "retry-stop", "transient-cap", "budget", "quota", "bad-output", "summary", "summary-error", "task-stall", "goal-stall", "unoffered", "mixed-offer", "plan-approval"];
    const only = environment.get("AURORA_ACTOR_RECOVERY_MODES", "");
    if (only.length) modes = only.split(",");
    foreach (mode; modes)
    {
        // Fixture workspaces live outside the checkout: the filesystem host
        // serializes work on one checkout, so a concurrent source operation in
        // the running app would stall a fixture write for its whole timeout.
        const workspace = buildPath(tempDir(),
            "aurora-actor-recovery-" ~ mode ~ "-" ~ to!string(MonoTime.currTime.ticks));
        mkdirRecurse(workspace);
        ChatSession initial; initial.id = "recovery-" ~ mode; initial.model = "actor-" ~ mode;
        const persistent = mode == "budget" || mode == "transient-cap" || mode == "bad-output" ||
            mode == "retry-stop" || mode == "unoffered" || mode == "goal-stall";
        if (persistent)
        {
            // goal-stall needs an action-shaped goal: an analysis goal finishes
            // on its reply and never reaches goal continuation.
            initial.goal = mode == "goal-stall"
                ? "Deliver the requested deployment change" : "Deliver the user's requested analysis";
            initial.goalStatus = "active";
        }
        initial.planMode = mode == "plan-approval";
        ActorConfiguration config; config.baseUrl = base; config.apiKey = "fixture";
        config.workspace = workspace; config.recordTrace = true;
        config.outageBudgetMs = mode == "budget" || mode == "quota" ? 250 : 15_000;
        config.request.toolsEnabled = mode == "bad-output" || mode == "summary" || mode == "summary-error" ||
            mode == "task-stall" || mode == "goal-stall" || mode == "unoffered" ||
            mode == "mixed-offer" || mode == "plan-approval";
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
        bool sawWait, sawFailure, stopped, paused;
        auto quietUntil = MonoTime.init;
        const deadline = MonoTime.currTime + (mode == "goal-stall" ? 60 : 20).seconds;
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
            // A goal whose turns only answer with prose keeps running: the app
            // never pauses or completes the user's goal on the model's behalf.
            // The escalating directive is the only thing it may do, so the
            // reader's own pause is what ends this fixture.
            if (mode == "goal-stall" && !paused && view.model.goalStatus.length)
            {
                assert(view.model.goalStatus == "active",
                    "the app paused a goal it may only keep running");
                // The escalating "Progress audit" directive appears from the
                // third stalled turn, so let the goal spend enough recovery
                // turns that the escalation is certainly recorded before the
                // reader pauses it.
                if (view.model.goalTurns >= 5)
                {
                    assert(actor.post(ActorCommand(ActorCommandKind.pauseGoal)) == ActorAdmission.accepted);
                    paused = true; quietUntil = MonoTime.currTime + 500.msecs;
                }
            }
            if (latest.type == JSONType.object)
            {
                const status = latest["turnStatus"].str;
                if (mode == "retry-stop") settled = stopped && status == "interrupted" && MonoTime.currTime >= quietUntil;
                else if (mode == "task-stall") settled = status == "completed";
                else if (mode == "goal-stall")
                    settled = paused && status == "interrupted" && MonoTime.currTime >= quietUntil;
                else if (mode == "budget" || mode == "transient-cap" || mode == "bad-output" || mode == "unoffered")
                    settled = status == "failed" && latest["execution"]["retryRemainingMs"].integer < 0;
                else settled = status == "completed";
            }
            if (settled) break;
            Thread.sleep(5.msecs);
        }
        assert(settled, mode ~ " did not settle: " ~
            (latest.type == JSONType.object ? latest.toString() : "no state"));
        if (mode == "retry" || mode == "retry-stop" || mode == "quota") assert(sawWait && sawFailure, mode);
        if (mode == "transient-cap" || mode == "budget") assert(!sawWait, "Exhausted transport recovery restarted an outer loop");
        actor.close(); assert(!actor.fault().length, actor.fault());
        const snapshot = actor.finalSnapshot();
        const state = parseJSON(snapshot);

        if (persistent && mode != "retry-stop" && mode != "goal-stall")
            assert(state["goalStatus"].str == "active", mode ~ " discarded the active goal");
        if (mode == "retry-stop") assert(state["goalStatus"].str == "paused");
        if (mode == "goal-stall")
        {
            // The app keeps a stalled goal running and escalates its directive;
            // only the reader pauses it. Nothing is parked or fabricated.
            assert(state["goalStatus"].str == "paused",
                "the reader's pause did not stop the stalled goal");
            assert(state["taskStatus"].str != "completed",
                "pausing a stalled goal fabricated completion");
            assert(!sawFailure, "a stalled goal painted a failure");
            assert(state["goalTurns"].integer >= 5,
                "a stalled goal was not given another action turn");
            bool escalated;
            foreach (message; state["messages"].array)
                if (message["content"].str.indexOf("Progress audit") >= 0) escalated = true;
            assert(escalated, "a repeated goal stall did not escalate its directive");
        }
        if (mode == "task-stall")
        {
            assert(state["verificationStatus"].str == "required" && state["objective"].str.length,
                "No-action recovery discarded the unfinished verification/task");
            foreach (message; state["messages"].array)
                if (message["role"].str == "assistant")
                    assert(!("failed" in message.object) || !message["failed"].boolean,
                        "Recovery exhaustion marked the delivered answer as failed");
        }
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
            // Automatic summary rounds were removed: a truncated answer is
            // delivered as the answer, and recorded completion evidence only
            // finishes a handoff saved by an older build.
            assert(!exists(buildPath(workspace, "must-not-exist.txt")), "Summary executed an unavailable tool");
            assert(state["messages"].array[$ - 1]["content"].str.indexOf("A truncated analysis") == 0,
                "An automatic summary round rewrote the delivered answer");
            assert(latest["execution"]["phase"].str == "completed", "The delivered answer left execution in a tool phase");
        }
        if (mode == "plan-approval")
        {
            assert(state["taskStatus"].str == "waiting_input", "Plan approval did not pause the task");
            assert(state["planMode"].boolean, "Plan approval disarmed Plan mode");
            bool acceptedInput, blockedWrite;
            foreach (message; state["messages"].array)
            {
                if (message["role"].str != "tool") continue;
                const name = message["toolName"].str;
                const text = message["content"].str;
                assert(text.indexOf("Execution recovery did not resolve") < 0,
                    "Plan approval started execution recovery");
                assert(text.indexOf("Recover internally") < 0,
                    "Plan approval was rejected as a routine permission question");
                const failed = "failed" in message.object && message["failed"].boolean;
                if (name == "write") blockedWrite = failed;
                if (name == "request_input") acceptedInput = !failed;
            }
            assert(blockedWrite, "Plan mode did not block the write");
            assert(acceptedInput, "The plan approval request was not accepted");
            assert(!exists(buildPath(workspace, "splitpane.d")), "Plan mode allowed the blocked write");
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
