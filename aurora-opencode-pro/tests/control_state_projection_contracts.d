module control_state_projection_contracts;

import auroraopencode.core;
import auroraopencode.controlhistory;
import auroraopencode.requestbuilder : projectRequestMessages;
import auroraopencode.taskcontinuation : taskContinuationMarker;
import std.conv : to;
import std.stdio : writeln;
import std.string : indexOf;

private ChatMessage add(ref ChatSession session, string role, string content,
    bool internal = false)
{
    ChatMessage message;
    message.id = "m" ~ to!string(session.messages.length);
    message.parentId = session.activeLeafId;
    message.role = role;
    message.content = content;
    message.internal = internal;
    session.messages ~= message;
    session.activeLeafId = message.id;
    return message;
}

private bool hasContent(const ChatRequestMessage[] messages, string fragment)
{
    foreach (message; messages)
        if (message.content.indexOf(fragment) >= 0) return true;
    return false;
}

int main()
{
    ChatSession session;
    add(session, "user", "Implement the feature.");
    add(session, "user", durableTaskCheckpointPrefix ~ " state-0", true);
    add(session, "user", taskContinuationMarker ~ " continuation-0", true);
    add(session, "user", progressGuidancePrefix ~ " guidance-0", true);

    // A real tool envelope must survive the control-state dedupe intact.
    ChatMessage call;
    call.id = "m" ~ to!string(session.messages.length);
    call.parentId = session.activeLeafId;
    call.role = "assistant";
    call.toolCalls = [OpenCodeToolCall("call-1", "read", `{"filePath":"a.txt"}`)];
    session.messages ~= call;
    session.activeLeafId = call.id;
    auto result = add(session, "tool", "file contents");
    session.messages[$ - 1].toolCallId = "call-1";
    session.messages[$ - 1].toolName = "read";

    add(session, "user", durableTaskCheckpointPrefix ~ " state-1", true);
    add(session, "user", taskContinuationMarker ~ " continuation-1", true);
    add(session, "user", progressGuidancePrefix ~ " guidance-1", true);

    const before = session.messages.length;
    const wire = projectRequestMessages(session);

    // One real request, one assistant/tool envelope, and exactly one newest
    // record of each superseded control kind.
    assert(wire.length == 6, "unexpected wire length " ~ to!string(wire.length));
    assert(wire[0].role == "user" && wire[0].content == "Implement the feature.");
    assert(wire[1].role == "assistant" && wire[1].toolCalls.length == 1 &&
        wire[1].toolCalls[0].id == "call-1");
    assert(wire[2].role == "tool" && wire[2].toolCallId == "call-1" &&
        wire[2].content == "file contents");
    assert(hasContent(wire, "state-1") && !hasContent(wire, "state-0"),
        "the newest checkpoint must supersede the older one");
    assert(hasContent(wire, "continuation-1") && !hasContent(wire, "continuation-0"),
        "the newest continuation must supersede the older one");
    assert(hasContent(wire, "guidance-1") && !hasContent(wire, "guidance-0"),
        "the newest progress guidance must supersede the older one");
    assert(session.messages.length == before,
        "projection must not delete stored control history");

    // A fresh human request starts a new instruction window: the prior turn's
    // controls are retired, and only the new turn's newest controls survive.
    add(session, "user", "Now verify it.");
    add(session, "user", durableTaskCheckpointPrefix ~ " state-2", true);
    add(session, "user", taskContinuationMarker ~ " continuation-2", true);
    add(session, "user", progressGuidancePrefix ~ " guidance-2", true);
    const next = projectRequestMessages(session);
    assert(next.length == 7, "unexpected next wire length " ~ to!string(next.length));
    assert(!hasContent(next, "state-1") && !hasContent(next, "continuation-1") &&
        !hasContent(next, "guidance-1"), "prior-turn controls leaked into the new turn");
    assert(hasContent(next, "state-2") && hasContent(next, "continuation-2") &&
        hasContent(next, "guidance-2"), "newest controls were lost");
    assert(next[0].content == "Implement the feature." &&
        next[1].content == "" && next[2].content == "file contents" &&
        next[3].content == "Now verify it.", "ordinary history changed");

    writeln("PASS superseded control state collapses to the newest per kind without touching tools or history");
    return 0;
}
