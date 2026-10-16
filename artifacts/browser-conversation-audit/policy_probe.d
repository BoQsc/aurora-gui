module policy_probe;

import auroraopencode.core : ChatSession, ChatMessage, TaskStep;
import auroraopencode.taskcontinuation : taskContinuation, TaskContinuationAction;
import auroraopencode.verification : verificationCheck;
import std.conv : to;
import std.stdio : writeln;

void append(ref ChatSession session, string role, string content,
    bool internal = false, string name = "", string arguments = "{}")
{
    ChatMessage message;
    message.id = "probe-" ~ to!string(session.messages.length);
    message.parentId = session.activeLeafId;
    message.role = role;
    message.content = content;
    message.internal = internal;
    message.toolName = name;
    message.toolArgs = arguments;
    session.messages ~= message;
    session.activeLeafId = message.id;
}

ChatSession pending()
{
    ChatSession session;
    session.taskStatus = "active";
    session.verificationStatus = "required";
    session.taskSteps = [TaskStep("Match the reference rendering", "in_progress")];
    append(session, "user", "Fix the page rendering and verify it.");
    return session;
}

int main()
{
    auto session = pending();
    foreach (i; 0 .. 12)
    {
        const previous = taskContinuation(session, true);
        append(session, "user", previous.guidance(), true);
        // No edit, passed acceptance check, or completed outcome. The same
        // search output with a distinct query is enough to reset stagnation.
        append(session, "tool", "No matches", false, "grep", "query-" ~ to!string(i));
        const next = taskContinuation(session, true);
        assert(next.action == TaskContinuationAction.continueWork);
        assert(next.stalled == 0 && next.completed == 0 && !next.verified);
    }
    writeln("REPRODUCED: 12 distinct unsuccessful searches count as progress; zero outcomes complete.");

    session = pending();
    append(session, "tool", "No matches", false, "grep", "same query");
    foreach (i; 0 .. 3)
    {
        const previous = taskContinuation(session, true);
        append(session, "user", previous.guidance(), true);
        append(session, "tool", "No matches", false, "grep", "same query");
    }
    assert(taskContinuation(session, true).action == TaskContinuationAction.needsAttention);
    writeln("CONTROL: identical searches do trigger the existing stall detector.");

    assert(verificationCheck("dmd", ["-i", "probe.d", "-of=probe.exe"]) == "dmd compile");
    assert(verificationCheck("headless-smoke.exe", []) == "");
    writeln("REPRODUCED: compilation is recognized as verification; a standalone smoke-test executable is not.");
    return 0;
}
