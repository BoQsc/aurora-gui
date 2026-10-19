module decision_quality_contracts;

import auroraopencode.core;
import auroraopencode.taskflow;
import std.conv : to;
import std.stdio : writeln;

int main()
{
    ChatSession session;
    ChatMessage request;
    request.id = "request"; request.role = "user"; request.content = "Fix the parser.";
    session.messages = [request]; session.activeLeafId = request.id;
    acceptTaskRequest(session, request.content, request.id);
    foreach (i; 0 .. 17)
    {
        ChatMessage message;
        message.id = "probe-" ~ to!string(i); message.parentId = session.activeLeafId;
        message.role = "tool"; message.toolName = "run";
        message.toolArgs = `{"program":"git","args":["status","--porcelain",` ~ to!string(i) ~ `]}`;
        message.content = "Identical workspace status\nProcess exited with code 0.";
        session.messages ~= message; session.activeLeafId = message.id;
    }
    assert(stalledExecutionTools(session) == 16,
        "Changing command arguments disguised identical output as new evidence");
    assert(executionRecoveryDue(session), "Repeated observations did not trigger a new diagnosis");
    writeln("PASS varied commands with identical evidence cannot conceal stagnation");
    return 0;
}
