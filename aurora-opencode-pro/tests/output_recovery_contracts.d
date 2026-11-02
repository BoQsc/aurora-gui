module output_recovery_contracts;

import auroraopencode.core : ChatMessage, ChatSession;
import auroraopencode.outputrecovery;
import auroraopencode.outputguard : outputRecoveryMarker;
import std.stdio : writeln;
import std.conv : to;

int main()
{
    ChatSession session;
    session.goal = "Write and verify the requested artifact";
    session.goalStatus = "active";
    void add(string role, string content, bool internal = false, string tool = "")
    {
        ChatMessage message;
        message.role = role; message.content = content;
        message.internal = internal; message.toolName = tool;
        message.id = "m" ~ to!string(session.messages.length);
        message.parentId = session.activeLeafId;
        session.activeLeafId = message.id;
        session.messages ~= message;
    }
    add("user", session.goal);
    add("assistant", "READY");
    add("user", "Persistent goal continuation: audit the result", true);
    add("assistant", "READY");
    assert(answerReplayed(session), "Short goal replies must not escape the replay guard");
    foreach (_; 0 .. maxOutputRecoveries)
        add("user", outputRecoveryMarker ~ " use the function-call channel", true);
    assert(outputRecoveryCount(session) == maxOutputRecoveries);
    add("tool", "Plan unchanged", false, "update_plan");
    assert(outputRecoveryCount(session) == maxOutputRecoveries, "Plan chatter reset the failure circuit");
    add("tool", "Saved the artifact", false, "write");
    assert(outputRecoveryCount(session) == 0 && !goalAuditStalled(session));
    foreach (_; 0 .. 100)
    {
        add("user", "Persistent goal continuation: finish remaining work", true);
        add("tool", "A useful result", false, "read");
        assert(!goalAuditStalled(session), "Useful long-horizon work hit an arbitrary turn cap");
    }
    add("user", "Persistent goal continuation: audit the result", true);
    add("assistant", "Finished the work");
    add("user", "Persistent goal continuation: audit the result", true);
    add("assistant", "Everything looks good");
    assert(goalAuditStalled(session), "Varying prose must not create an endless goal audit");
    add("user", "Reply READY again");
    add("assistant", "READY");
    assert(!answerReplayed(session) && !goalAuditStalled(session));
    writeln("PASS bounded unusable output, varied goal chatter, useful long-horizon work and new-user boundaries");
    return 0;
}
