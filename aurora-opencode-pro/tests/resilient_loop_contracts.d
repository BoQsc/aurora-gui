module resilient_loop_contracts;

import auroraopencode.core;
import auroraopencode.outputguard : agentOutputIssue, outputRecoveryMarker;
import auroraopencode.agentloop;
import auroraopencode.requestbuilder : projectRequestMessages;
import auroraopencode.contextpolicy : checkpointRequestMessages;
import auroraopencode.controlhistory : controlHistoryBoundary, durableTaskCheckpointPrefix;
import auroraopencode.turnpolicy;
import auroraopencode.executioncontrol : executionState;
import auroraopencode.taskmutation : planReplacementError;
import std.conv : to;
import std.string : indexOf;
import std.stdio : writeln;

void add(ref ChatSession s, string role, string text, bool internal = false, string tool = "")
{
    ChatMessage m; m.id = "m" ~ to!string(s.messages.length); m.parentId = s.activeLeafId;
    m.role = role; m.content = text; m.internal = internal; m.toolName = tool;
    s.activeLeafId = m.id; s.messages ~= m;
}

int main()
{
    const leaked = `<｜DSML｜ calls> <｜DSML｜ invoke name="run"> <｜DSML｜ parameter name="args" string="false">["add","--","x"]</｜DSML｜ parameter> </｜DSML｜ invoke> </｜DSML｜ calls>`;
    assert(agentOutputIssue(leaked, ["run"], true) == "text_tool_calls");
    assert(agentOutputIssue(`<｜DSML｜ calls> <｜DSML｜ invoke name="run">`, ["run"], true) == "text_tool_calls");
    assert(agentOutputIssue("```text\n" ~ leaked ~ "\n```", ["run"], true) == "");
    assert(agentOutputIssue("> " ~ leaked, ["run"], true) == "");
    assert(agentOutputIssue("Example: " ~ leaked, ["run"], true) == "");
    assert(agentOutputIssue(leaked, ["run"], true, true) == "");
    assert(providerContextLimit("exceeds available context size (32000 tokens)") == 32000);
    assert(providerContextLimit("Maximum context length is 64,000 tokens") == 64000);
    assert(rejectedContextBudget("context_length_exceeded", 32000) == 24000);
    assert(rejectedContextBudget("context_length_exceeded", 24000) == 18000);
    assert(rejectedContextBudget("HTTP 503 busy", 32000) == 0);

    ChatSession s;
    add(s, "user", "Implement and verify the requested behavior");
    s.contract.id = "task"; s.contract.intent = "implementation";
    s.contract.currentIntent = "implementation"; s.verificationStatus = "required";
    TurnPolicy policy; policy.toolsEnabled = true;
    s.taskSteps = [TaskStep("Deliver behavior", "in_progress")];
    foreach (i; 0 .. 20)
    {
        add(s, "assistant", "Same unsupported completion answer");
        const next = decideTurn(s, policy);
        assert(next.action == TurnAction.request && next.turnStatus == "running");
        assert(next.recoveryDelayMs >= 0 && next.recoveryDelayMs <= 30_000);
        add(s, "user", next.guidance, true);
    }
    const wire = projectRequestMessages(s);
    int repairPrompts;
    foreach (message; wire)
    {
        assert(message.content != "Same unsupported completion answer", "Stalled prose poisoned recovery context");
        if (message.content.indexOf("cause=unfinished_outcome") >= 0) ++repairPrompts;
    }
    assert(repairPrompts == 1, "Failure-only directives filled the working context");
    assert(s.messages.length == 41, "Recovery projection deleted durable history");
    assert(decideTurn(s, policy).recoveryDelayMs > 0, "Repeated failures spun without a delay");
    policy.cancelled = true;
    assert(decideTurn(s, policy).action == TurnAction.interrupted);

    // A real long goal compacted through its latest tool result. A subsequent
    // constrained control boundary then discarded the fresh repair directive,
    // producing an identical system-only request after a repeated-prose error.
    ChatSession compacted;
    add(compacted, "user", "Complete all six milestones and verify the delivered files.");
    compacted.compactedThroughMessageId = compacted.activeLeafId;
    compacted.compactionSummary = "Five milestones passed; implement and verify the sixth.";
    string previous;
    foreach (i; 0 .. 4)
    {
        add(compacted, "assistant", "Rejected printed tool calls and looping prose");
        const repair = recoverAgent(compacted, "repeated_prose", i).guidance;
        add(compacted, "user", repair, true);
        add(compacted, "user", controlHistoryBoundary, true);
        add(compacted, "user", durableTaskCheckpointPrefix ~ " Phase 6 remains active.", true);
        const request = checkpointRequestMessages(compacted);
        int repairs;
        bool human;
        string projection;
        foreach (message; request)
        {
            projection ~= message.content;
            if (message.content.indexOf("cause=repeated_prose") >= 0) ++repairs;
            if (message.role == "user" && message.content == compacted.messages[0].content) human = true;
        }
        assert(human && repairs == 1 && projection.indexOf(repair) >= 0,
            "Compaction lost the current repair strategy or user's conversational request");
        assert(projection != previous, "An output failure retried the identical provider prompt");
        previous = projection;
    }
    compacted.compactedThroughMessageId = compacted.activeLeafId;
    bool checkpointedRepair;
    foreach (message; checkpointRequestMessages(compacted))
        if (message.content.indexOf("attempt=4 cause=repeated_prose") >= 0) checkpointedRepair = true;
    assert(checkpointedRepair, "Rolling the summary past a pending repair discarded it");
    add(compacted, "tool", "A real tool result now owns the next action.", false, "read");
    add(compacted, "user", controlHistoryBoundary, true);
    foreach (message; checkpointRequestMessages(compacted))
        assert(message.content.indexOf("cause=repeated_prose") < 0,
            "An old repair remained authoritative after actual tool progress");
    add(compacted, "user", "New request: inspect only.");
    foreach (message; projectRequestMessages(compacted))
        assert(message.content.indexOf("cause=repeated_prose") < 0,
            "An earlier repair leaked into a new human instruction");
    writeln("PASS live repair and actual user request survive constrained compaction; retries change the wire prompt");

    ChatSession repeated;
    add(repeated, "user", "Repair the file");
    foreach (_; 0 .. 3) add(repeated, "tool", "unchanged facts", false, "read");
    assert(stagnantToolGuidance(repeated).length);
    add(repeated, "user", stagnantToolGuidance(repeated), true);
    assert(!stagnantToolGuidance(repeated).length, "One diagnosis was injected repeatedly without new activity");
    foreach (_; 0 .. 10) add(repeated, "tool", "still running", false, "process");
    assert(!stagnantToolGuidance(repeated).length, "A live process poll was treated as a loop");
    assert(!planReplacementError(repeated,
        `{"plan":[{"step":"Independent A","status":"in_progress"},{"step":"Independent B","status":"in_progress"}]}`).length);
    writeln("PASS inline/truncated DSML, persistent scheduled recovery, history preservation, observation loops, process polls and advisory planning");
    return 0;
}
