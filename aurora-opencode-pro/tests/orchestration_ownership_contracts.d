module orchestration_ownership_contracts;

import aurora;
import auroraopencode.core;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.execution : ThreadEngine;
import auroraopencode.orchestrator;
import auroraopencode.toolsettlement;
import auroraopencode.opencode_client : OpenCodeEvent;
import auroraopencode.turnpolicy : decideTurn, TurnPolicy, TurnAction;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.file : mkdirRecurse;
import std.path : absolutePath;
import std.conv : to;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const build = `{"agent_id":"builder","task":"Implement Alpha"}`;
    const review = `{"agent_id":"reviewer","task":"Review Beta"}`;
    auto first = new ThreadEngine("", ""); auto second = new ThreadEngine("", "");
    scope (exit) { first.close(); second.close(); }
    ChatSession session; experimentalOrchestratorEnsureRoster(session);
    session.activeAgentId = "orchestrator";
    ToolResultPolicy policy; policy.orchestratorEnabled = true;
    OpenCodeEvent result; result.toolName = "assign";
    auto one = settleToolResult(session, result, build, policy);
    auto two = settleToolResult(session, result, review, policy);
    first.pendingRouting.accept(one.routing); second.pendingRouting.accept(two.routing);
    assert(first.pendingRouting.assignments[0].agentId == "builder");
    assert(second.pendingRouting.assignments[0].agentId == "reviewer");
    first.acceptRequest(41);
    assert(first.busy(), "An admitted request was invisible before its network worker started");
    first.stop(); assert(first.pendingRouting.assignments.length == 0);
    assert(!first.busy(), "Stopping did not revoke the admitted request");
    assert(second.pendingRouting.take().assignments[0].task == "Review Beta");
    assert(!second.pendingRouting.assignments.length);
    assert(settleToolResult(session, result, `{"agent_id":"unknown","task":"Work"}`, policy).message.failed);
    assert(parseOrchestratorDirective("assign", `{"assignments":[{"agent_id":"builder","task":"A"},{}]}`).failed);
    assert(parseOrchestratorDirective("assign", `{"assignments":[{"agent_id":"builder","task":"A"},{"agent_id":"builder","task":"B"}]}`).failed);
    policy.routingHalted = true;
    assert(settleToolResult(session, result, build, policy).message.failed);
    policy.routingHalted = false;
    session.activeAgentId = "builder";
    assert(settleToolResult(session, result, review, policy).message.failed);
    session.activeAgentId = "orchestrator";
    result.toolName = "finish"; session.taskSteps = [TaskStep("Required work", "pending")];
    assert(settleToolResult(session, result, `{"summary":"Done"}`, policy).message.failed);
    session.taskSteps = null;
    result.toolName = "ask_user";
    assert(settleToolResult(session, result, `{"question":"Should I continue?"}`, policy).message.failed);
    const question = `{"reason":"No production deployment destination is recorded in the available configuration.","required_fact":"The production domain controlled by the user","question":"Which production domain should receive this deployment?","checked":["Repository deployment configuration","Project documentation"],"independent_work_complete":true}`;
    auto waiting = settleToolResult(session, result, question, policy);
    assert(!waiting.message.failed && waiting.routing.status == "waiting_input", waiting.message.content);
    waiting.message.id = "input"; session.messages ~= waiting.message;
    session.activeLeafId = "input"; session.taskStatus = "waiting_input";
    session.goal = "Deliver the deployment"; session.goalStatus = "active";
    TurnPolicy turn; turn.toolsEnabled = true; turn.orchestratorEnabled = true;
    assert(decideTurn(session, turn).action == TurnAction.waitInput,
        "A validated orchestration question restarted the active goal");
    session.messages = null; session.activeLeafId = "";
    session.taskStatus = "active"; session.activeAgentId = "builder";
    session.agentHops = 100; session.nextSpeakerId = "orchestrator";
    turn.speakerToolRoundsBase = 10; turn.toolRounds = 11;
    assert(decideTurn(session, turn).nextSpeaker == "orchestrator",
        "An arbitrary hop limit interrupted a productive handoff");

    const state = absolutePath("orchestration-owners-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state); setOpencodeStateDirectoryForTesting(state);
    Settings settings; settings.baseUrl = "http://127.0.0.1:1";
    settings.quickTitle = false; settings.workspace = state; saveSettings(settings);
    WindowOptions options; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme()); auto root = new OpenCodeRoot(window);
    window.setRoot(root); scope (exit) root.shutdownClient();
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    { window.onNativeTick(0.02); Thread.sleep(5.msecs); }
    assert(!root.startupPendingForTesting());
    int locate(string id)
    {
        foreach (i; 0 .. cast(int) root.sessionCountForTesting())
            if (root.sessionIdForTesting(i) == id) return i;
        assert(false, "Conversation disappeared");
    }
    string start(string title, string arguments)
    {
        root.newChatForTesting(); root.addConversationForTesting(["user"], [title]);
        root.setSessionTurnStatusForTesting(root.currentSessionForTesting(), "running");
        root.enableExperimentalOrchestratorForTesting(); root.beginStreamForTesting();
        const id = root.sessionIdForTesting(root.currentSessionForTesting());
        root.injectToolCallsForTesting([OpenCodeToolCall("assign", "assign", arguments)]);
        return id;
    }
    const alpha = start("Implement Alpha", build);
    const beta = start("Review Beta", review);
    // Both workers settle before the window consumes their correlated events.
    Thread.sleep(150.msecs);
    const dispatched = MonoTime.currTime + 5.seconds;
    while (MonoTime.currTime < dispatched)
    {
        window.onNativeTick(0.02);
        if (root.subagentChatCountForTesting(locate(alpha)) == 1 &&
            root.subagentChatCountForTesting(locate(beta)) == 1) break;
        Thread.sleep(5.msecs);
    }
    root.selectSessionForTesting(locate(alpha));
    assert(root.subagentChatCountForTesting(locate(alpha)) == 1, "Alpha: " ~ root.lastToolResultForTesting());
    root.selectSessionForTesting(locate(beta));
    assert(root.subagentChatCountForTesting(locate(beta)) == 1, "Beta: " ~ root.lastToolResultForTesting());
    foreach (i; 0 .. cast(int) root.sessionCountForTesting())
    {
        const parent = root.sessionParentForTesting(i);
        if (parent == alpha) assert(root.sessionSubagentForTesting(i) == "builder");
        if (parent == beta) assert(root.sessionSubagentForTesting(i) == "reviewer");
    }
    root.selectSessionForTesting(locate(alpha)); root.stopActiveTurnForTesting();
    root.selectSessionForTesting(locate(beta)); root.stopActiveTurnForTesting();
    foreach (_; 0 .. 12) { window.onNativeTick(0.02); Thread.sleep(5.msecs); }
    foreach (i; 0 .. cast(int) root.sessionCountForTesting())
        if (root.sessionParentForTesting(i) == alpha || root.sessionParentForTesting(i) == beta)
            assert(!root.sessionTurnBusyForTesting(i), "Stopping a parent left its child running: " ~ root.sessionBusyDetailsForTesting(i));

    root.newChatForTesting(); root.addConversationForTesting(["user"], ["Queued delegation"]);
    root.setSessionTurnStatusForTesting(root.currentSessionForTesting(), "running");
    root.enableExperimentalOrchestratorForTesting(); root.beginStreamForTesting();
    const cancelledParent = root.sessionIdForTesting(root.currentSessionForTesting());
    root.injectToolResultForTesting("assign", "Assigned builder", false, build);
    root.stopActiveTurnForTesting();
    foreach (_; 0 .. 8) window.onNativeTick(0.02);
    assert(root.subagentChatCountForTesting(locate(cancelledParent)) == 0,
        "A queued round started after its parent was stopped");
    assert(!root.sessionTurnBusyForTesting(locate(cancelledParent)), "A cancelled parent resumed");
    writeln("PASS correlated concurrent routing, roster/finish/input validation, parent Stop and queued dispatch revocation");
    return 0;
}
