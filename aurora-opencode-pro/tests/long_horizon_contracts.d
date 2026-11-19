// Long-horizon contract: a single task survives many compaction rolls and a
// restart without losing its durable state. The checks cover what the model
// actually sees (durable prompt plus checkpoint/tail), not just saved fields.
module long_horizon_contracts;

import auroraopencode.core;
import auroraopencode.contextpolicy;
import auroraopencode.contextcheckpoint : requestMessageBytes;
import auroraopencode.taskcontext : taskContext;
import auroraopencode.historyrecall : readHistory;
import auroraopencode.planhistory : recordPlanHistory;
import core.time : MonoTime;
import std.array : appender, replicate;
import std.conv : to;
import std.json : parseJSON;
import std.stdio : writefln, writeln;
import std.string : indexOf, split;

void addMessage(ref ChatSession session, string id, string role, string text)
{
    ChatMessage message;
    message.id = id;
    message.parentId = session.activeLeafId;
    message.role = role;
    message.content = text;
    session.messages ~= message;
    session.activeLeafId = id;
}

ChatSession longTask()
{
    ChatSession session;
    session.id = "long-horizon";
    session.objective = "Migrate the billing exporter to the new writer. CONSTRAINT-ALPHA never " ~
        "delete audit.log; the customer rate stays 0.0175. Report EXACT-FACT-ORIGIN=ZX-4412 " ~
        "when the migration is done.";
    session.goal = "Ship the exporter migration and keep audit.log intact";
    session.goalStatus = "active";
    session.taskStatus = "active";
    session.verificationStatus = "required";
    session.contract.id = "m-long-horizon-1";
    session.contract.startMessageId = "m-start";
    session.contract.intent = "implementation";
    session.contract.currentIntent = "implementation";
    session.contract.workspace = `C:\work\billing-exporter`;
    session.contract.requestedOutcome = "Deliver the migrated exporter with a verified audit trail";
    session.contract.constraints = [
        "CONSTRAINT-ALPHA never delete or rotate audit.log",
        "CONSTRAINT-BETA the customer rate stays 0.0175 per unit",
        "CONSTRAINT-C03 output encoding is UTF-8 without a BOM",
        "CONSTRAINT-C04 the CLI flag --dry-run must remain",
        "CONSTRAINT-C05 do not change the public JSON field names",
        "CONSTRAINT-C06 keep the existing retry count of three",
    ];
    session.contract.decisions = [
        "DECISION-GAMMA archive through the offline writer",
        "DECISION-H01 the legacy id maps through the compatibility table",
        "DECISION-H02 timestamps remain UTC ISO-8601",
        "DECISION-H03 the canary runs before the full export",
    ];
    session.contract.blocker = "BLOCKER-DELTA the signing key arrives from the release desk";
    session.contract.work.stepId = "step-2";
    session.contract.work.action = "Implement the audit-preserving export path";
    session.contract.work.nextAction = "Run the focused exporter suite";
    session.contract.work.doneWhen = "The audit log is intact and the fixture round-trips";
    session.contract.work.returnTo = "step-1 inventory";
    TaskStep step1;
    step1.id = "step-1"; step1.text = "Inventory the exporter entry points";
    step1.status = "completed"; step1.done = "Entry points listed in notes.md";
    TaskStep step2;
    step2.id = "step-2"; step2.text = "Implement the audit-preserving export path";
    step2.status = "in_progress";
    TaskStep step3;
    step3.id = "step-3"; step3.text = "Run the focused exporter suite";
    step3.status = "pending";
    TaskStep step4;
    step4.id = "step-4"; step4.text = "Update the operator runbook";
    step4.status = "pending";
    session.taskSteps = [step1, step2, step3, step4];
    session.turnStatus = "running";
    addMessage(session, "m-start", "user", session.objective);
    addMessage(session, "m-plan", "assistant",
        "Plan recorded: inventory, implement the audit-preserving path, run the suite, update the runbook.");
    recordPlanHistory(session, "update_plan", "Initial plan");
    return session;
}

void grow(ref ChatSession session, int cycle, size_t resultBytes = 90)
{
    foreach (i; 0 .. 8)
    {
        auto callId = "call-" ~ to!string(cycle) ~ "-" ~ to!string(i);
        ChatMessage call;
        call.id = callId; call.parentId = session.activeLeafId;
        call.role = "assistant"; call.content = "";
        call.toolCalls = [OpenCodeToolCall(callId, "read",
            `{"filePath":"source/export` ~ to!string(i) ~ `.d"}`)];
        session.messages ~= call; session.activeLeafId = callId;
        ChatMessage result;
        result.id = callId ~ "-result"; result.parentId = session.activeLeafId;
        result.role = "tool"; result.toolName = "read"; result.toolCallId = callId;
        result.content = ("source window " ~ to!string(i) ~ " line data\n").replicate(resultBytes);
        session.messages ~= result; session.activeLeafId = result.id;
    }
    if (cycle % 3 == 0)
        addMessage(session, "update-" ~ to!string(cycle), "user",
            "UPDATE-OMEGA" ~ to!string(cycle) ~ ": continuing with batch " ~ to!string(cycle) ~ ".");
    if (cycle % 4 == 0)
    {
        ChatMessage note;
        note.id = "note-" ~ to!string(cycle); note.parentId = session.activeLeafId;
        note.role = "assistant";
        note.content = "Investigated batch " ~ to!string(cycle) ~ "; the audit rule is unchanged.";
        session.messages ~= note; session.activeLeafId = note.id;
    }
}

string wireText(ref ChatSession session)
{
    auto text = appender!string();
    foreach (message; checkpointRequestMessages(session))
        text.put(message.content ~ "\n");
    return text.data;
}

bool has(string haystack, string needle)
{
    return haystack.indexOf(needle) >= 0;
}

void requireVisible(ref ChatSession session, string cycle, const(string)[] tokens)
{
    const prompt = durableTaskPrompt(session, true);
    const wire = wireText(session);
    foreach (token; tokens)
    {
        assert(has(prompt, token),
            "cycle " ~ cycle ~ ": durable prompt lost " ~ token);
        assert(has(wire, token),
            "cycle " ~ cycle ~ ": request lost " ~ token);
    }
}

int main()
{
    const fixedBytes = 36_000; // system prompt plus native tool schemas
    static immutable string[] coreTokens = [
        "Migrate the billing exporter",
        "CONSTRAINT-ALPHA", "CONSTRAINT-BETA", "CONSTRAINT-C03",
        "CONSTRAINT-C06",
        "DECISION-GAMMA", "DECISION-H03",
        "BLOCKER-DELTA",
        "step-2", "Implement the audit-preserving export path",
        "Verification: required",
        "Plan history:",
    ];
    auto session = longTask();
    int rolled;
    foreach (cycle; 0 .. 40)
    {
        grow(session, cycle);
        if (cycle == 4)
            addMessage(session, "late-rule", "user",
                "LATE-RULE-777: audit.log is append-only now; keep every historical row.");
        assert(rollCompactionCheckpoint(session, 32_768, fixedBytes),
            "cycle " ~ to!string(cycle) ~ ": the long task stopped rolling a checkpoint");
        ++rolled;
        const wire = checkpointRequestMessages(session);
        const bytes = requestMessageBytes(wire) + fixedBytes;
        assert(bytes <= compactionBudgetBytes(32_768),
            "cycle " ~ to!string(cycle) ~ ": checkpoint request exceeded the 32K budget: " ~
            to!string(bytes));
        requireVisible(session, to!string(cycle), coreTokens);
        if (cycle >= 5)
            requireVisible(session, to!string(cycle), ["LATE-RULE-777"]);
        assert(session.compactionSummary.length <=
                compactionSummaryCapacity(32_768, fixedBytes),
            "cycle " ~ to!string(cycle) ~ ": the checkpoint outgrew its summary budget");
    }
    assert(rolled == 40);

    // The newest retired entry must survive the next roll. Carrying the head of
    // the previous checkpoint duplicated durable text and dropped this entry.
    const previous = session.compactionSummary;
    string lastMarker;
    foreach_reverse (line; previous.split("\n"))
    {
        const at = line.indexOf("message_id=");
        if (at < 0) continue;
        const begin = at + "message_id=".length;
        const tail = line[begin .. $];
        const end = tail.indexOf(":");
        lastMarker = end < 0 ? tail : tail[0 .. end];
        if (lastMarker.length) break;
    }
    assert(lastMarker.length, "the checkpoint recorded no message entries");
    grow(session, 40);
    assert(rollCompactionCheckpoint(session, 32_768, fixedBytes));
    assert(session.compactionSummary.indexOf(lastMarker) >= 0,
        "the next roll dropped the most recent retired entry (" ~ lastMarker ~ ")");

    // Exact recovery remains available for detail the bounded prompt omits.
    auto recall = parseJSON(readHistory(session, `{"query":"EXACT-FACT-ORIGIN"}`));
    assert(recall["messages"].array.length == 1,
        "read_history no longer recovers the original exact fact");

    // Restart restores the same durable state without replaying the transcript.
    ChatSession restored;
    restoreActiveTaskState(restored, activeTaskStateJson(session));
    assert(restored.objective == session.objective);
    assert(restored.contract.constraints.length == 6);
    assert(restored.taskSteps.length == 4);
    assert(restored.contract.blocker == session.contract.blocker);
    assert(restored.verificationStatus == "required");
    const restoredPrompt = durableTaskPrompt(restored, true);
    foreach (token; ["CONSTRAINT-ALPHA", "BLOCKER-DELTA",
            "Implement the audit-preserving export path"])
        assert(has(restoredPrompt, token),
            "restart lost durable state " ~ token);

    // Many completed outcomes: the bounded list keeps the newest ones, which
    // continuation and review depend on, and marks the omitted older ones.
    auto finished = longTask();
    finished.taskSteps = null;
    foreach (i; 0 .. 160)
    {
        TaskStep step;
        step.id = "step-" ~ to!string(i + 1);
        step.text = "Outcome " ~ to!string(i + 1) ~ ": deliver the documented behavior change";
        step.status = "completed";
        step.done = "verified " ~ to!string(i + 1);
        finished.taskSteps ~= step;
    }
    const finishedPrompt = durableTaskPrompt(finished, true);
    assert(finishedPrompt.indexOf("step-160") >= 0,
        "the completed-outcome list truncated the newest outcome away");
    assert(finishedPrompt.indexOf("step-160") < finishedPrompt.indexOf("step-159"),
        "completed outcomes were not listed newest first");
    assert(finishedPrompt.indexOf(", ...") >= 0,
        "a truncated completed list did not mark the omitted older outcomes");

    // A long plan and many established decisions must not starve the blocker
    // or verification state out of the bounded prompt.
    auto crowded = longTask();
    crowded.taskSteps = null;
    foreach (i; 0 .. 60)
    {
        TaskStep step;
        step.id = "step-" ~ to!string(i + 1);
        step.text = "Outcome " ~ to!string(i + 1) ~ ": deliver the documented behavior change";
        step.status = i < 6 ? "completed" : (i == 6 ? "in_progress" : "pending");
        if (step.status == "completed") step.done = "done " ~ to!string(i + 1);
        crowded.taskSteps ~= step;
    }
    foreach (i; 0 .. 40)
        crowded.contract.decisions ~= "DECISION-CROWD-" ~ to!string(i) ~
            " record why the approach changed for this long-running outcome";
    foreach (i; 0 .. 24)
        crowded.contract.constraints ~= "CONSTRAINT-N" ~ to!string(i) ~
            " keep behavior " ~ to!string(i) ~ " unchanged and documented";
    const crowdedPrompt = durableTaskPrompt(crowded, true);
    assert(has(crowdedPrompt, "BLOCKER-DELTA"),
        "a long plan and decision log starved the blocker out of the prompt");
    assert(has(crowdedPrompt, "Verification: required"),
        "a long plan and decision log starved verification state");
    assert(has(crowdedPrompt, "CONSTRAINT-ALPHA"),
        "a long plan and decision log starved the user's original constraint");
    assert(has(crowdedPrompt, "DECISION-CROWD-39"),
        "the decision log was lost entirely behind the plan");

    const began = MonoTime.currTime;
    foreach (i; 0 .. 50)
    {
        const prompt = durableTaskPrompt(session, true);
        assert(prompt.length);
    }
    const averageMs = (MonoTime.currTime - began).total!"usecs" / 50.0 / 1000.0;
    assert(averageMs < 250,
        "durable prompt construction regressed to " ~ to!string(averageMs) ~ " ms");
    writefln("Long-horizon prompt: messages=%s rolls=%s avg_ms=%.3f",
        session.messages.length, rolled, averageMs);
    writeln("PASS 40 rolling checkpoints retain objective, constraints, decisions, blocker, plan, verification and a late user rule within budget");
    writeln("PASS the newest retired entry and exact history survive the next roll; restart restores the same durable state");
    writeln("PASS completed outcomes list newest first and a long plan cannot starve the blocker");
    return 0;
}
