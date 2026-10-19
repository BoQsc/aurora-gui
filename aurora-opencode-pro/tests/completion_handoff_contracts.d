module completion_handoff_contracts;

import auroraopencode.core;
import auroraopencode.completionhandoff;
import auroraopencode.requestbuilder : projectRequestMessages;
import auroraopencode.systemprompt : promptVerbosityDirective;
import std.conv : to;
import std.string : indexOf, startsWith;
import std.stdio : writeln;

void append(ref ChatSession session, string role, string content,
    string tool = "", bool internal = false, bool failed = false)
{
    ChatMessage message;
    message.id = "m" ~ to!string(session.messages.length);
    message.parentId = session.activeLeafId;
    message.role = role;
    message.content = content;
    message.toolName = tool;
    message.internal = internal;
    message.failed = failed;
    session.messages ~= message;
    session.activeLeafId = message.id;
}

ChatSession substantial(string request = "Implement the requested documents.")
{
    ChatSession session;
    append(session, "user", request);
    foreach (i; 0 .. 4)
    {
        append(session, "tool", "Saved document " ~ to!string(i), "write");
        session.messages[$ - 1].workspaceChanged = true;
        session.messages[$ - 1].toolArgs = `{"filePath":"document-` ~ to!string(i) ~ `.md"}`;
    }
    append(session, "assistant", "Done.");
    return session;
}

int main()
{
    enum summary = "Result: Four documents saved.\nChecks: Contents inspected.\nRemaining: None.";
    assert(hasCompletionHandoff(summary));
    assert(hasCompletionHandoff("## Result\nDocuments saved.\n**Checks:** Not run.\n- Remaining: Deployment address missing."));
    assert(!hasCompletionHandoff("Done."));
    assert(!hasCompletionHandoff("Result:\nChecks: Passed.\nRemaining: None."));
    assert(!hasCompletionHandoff("```\n" ~ summary ~ "\n```"));
    assert(!hasCompletionHandoff("> Result: Saved\n> Checks: Passed\n> Remaining: None"));
    auto session = substantial();
    assert(completionHandoffNeeded(session));
    assert(!completionHandoffPending(session));
    const oldLeaf = session.activeLeafId;
    append(session, "user", completionHandoffMarker ~ completionHandoffInstruction, "", true);
    assert(completionHandoffPending(session));
    append(session, "assistant", summary);
    assert(!completionHandoffNeeded(session));
    assert(completionHandoffNeeded(session, "length"));
    session.messages[$ - 1].finishReason = "length";
    assert(completionHandoffNeeded(session));
    session.messages[$ - 1].finishReason = "";
    auto reloaded = session;
    assert(completionHandoffPending(reloaded) && !completionHandoffNeeded(reloaded));
    session.activeLeafId = oldLeaf;
    assert(!completionHandoffPending(session) && completionHandoffNeeded(session));
    writeln("PASS summaries require three populated sections; truncation, reload and branch boundaries survive");

    foreach (request; ["Write documents, then reply READY.", "Write documents. Reply with only JSON.",
            "Implement it without a summary.", "Save the files. Respond in JSON.",
            "Implement it and return a valid JSON object.", "Implement it. Do not summarize."])
    {
        auto exact = substantial(request);
        assert(!completionHandoffNeeded(exact), request);
    }
    ChatSession small;
    append(small, "user", "What is the file name?");
    append(small, "tool", "file.md", "read");
    append(small, "assistant", "file.md");
    assert(!completionHandoffNeeded(small));
    auto checked = small;
    checked.messages = small.messages.dup;
    checked.messages[$ - 2].workspaceChanged = true;
    checked.messages[$ - 2].verificationCheck = "Fixture check";
    assert(completionHandoffNeeded(checked), "A change and check need a handoff even with few tools");
    auto planned = small;
    append(planned, "tool", "Plan updated", "update_plan");
    planned.taskSteps = [TaskStep("First outcome", "completed"), TaskStep("Second outcome", "completed")];
    assert(completionHandoffNeeded(planned), "A multi-outcome plan lost its handoff");
    append(small, "tool", "Plan updated", "update_plan");
    foreach (i; 0 .. 8) append(small, "tool", "Process running", "process");
    assert(!completionHandoffNeeded(small));
    session = substantial();
    append(session, "user", completionHandoffMarker ~ completionHandoffInstruction, "", true);
    append(session, "assistant", summary);
    append(session, "user", "What happened?");
    append(session, "assistant", "The documents were saved.");
    assert(!completionHandoffPending(session) && !completionHandoffNeeded(session));
    foreach (message; projectRequestMessages(session))
        assert(message.content.indexOf(completionHandoffMarker) < 0,
            "Old summary-only control state disabled tools in the next turn");
    assert(session.messages[$ - 4].content.startsWith(completionHandoffMarker));
    session.parentSessionId = "parent";
    session.subagentId = "worker";
    append(session, "user", completionHandoffMarker ~ completionHandoffInstruction, "", true);
    append(session, "user", "Task from the orchestrator: inspect the new assignment", "", true);
    session.messages[$ - 1].authorId = "worker";
    assert(!completionHandoffPending(session));
    foreach (message; projectRequestMessages(session))
        assert(message.content.indexOf(completionHandoffMarker) < 0);
    writeln("PASS short answers, exact output requests and polling avoid repairs; later requests retain history without stale control");

    session = substantial();
    session.taskSteps = [TaskStep("Delivery is pending", "pending")];
    session.verificationStatus = "failed";
    session.contract.blocker = "Publication address is missing";
    const fallback = recordedCompletionHandoff(session);
    assert(hasCompletionHandoff(fallback));
    assert(fallback.indexOf("write document-0.md") >= 0);
    assert(fallback.indexOf("No current successful verification receipt") >= 0);
    assert(fallback.indexOf("Required verification failed") >= 0);
    assert(fallback.indexOf("Delivery is pending") >= 0 && fallback.indexOf("Publication address is missing") >= 0);
    assert(session.taskSteps[0].status == "pending" && session.verificationStatus == "failed");
    foreach (style; ["compact", "caveman"])
    {
        assert(promptVerbosityDirective(style).indexOf("no closing summary") < 0);
        assert(promptVerbosityDirective(style).indexOf("Result/Checks/Remaining") >= 0);
    }
    writeln("PASS fallback uses actual changes, exposes failed/unrun checks and blockers, and preserves task state; brief styles keep handoffs");
    return 0;
}
