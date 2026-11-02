module projection_cache_contracts;

import auroraopencode.core;
import auroraopencode.projectioncache;
import auroraopencode.requestbuilder : projectRequestMessages;
import auroraopencode.controlhistory : controlHistoryBoundary;
import std.conv : to;
import std.stdio : writeln;
import std.array : replicate;

void append(ref ChatSession session, ChatMessage message)
{
    message.id = "m" ~ to!string(session.messages.length);
    message.parentId = session.activeLeafId;
    session.activeLeafId = message.id;
    session.messages ~= message;
}

int main()
{
    ChatSession session;
    session.id = "cache-contract";
    session.agents = [AgentSpec("worker", "Worker", "", "", false)];
    foreach (i; 0 .. 12)
    {
        ChatMessage user;
        user.role = "user"; user.content = "Task " ~ to!string(i);
        user.images = [ChatImageAttachment("image/png", "eA==", "image-" ~ to!string(i))];
        append(session, user);
        ChatMessage reply;
        reply.role = "assistant"; reply.content = "Inspecting " ~ to!string(i);
        reply.reasoning = "Recorded reasoning";
        reply.authorId = i % 2 ? "worker" : "";
        reply.toolCalls = [OpenCodeToolCall("call-" ~ to!string(i), "read", `{"filePath":"a.txt"}`)];
        append(session, reply);
        // Include incomplete groups and orphan replies in the source graph.
        if (i % 3)
        {
            ChatMessage tool;
            tool.role = "tool"; tool.content = "Observed result";
            tool.toolCallId = reply.toolCalls[0].id;
            tool.toolName = "read"; tool.authorId = reply.authorId;
            append(session, tool);
        }
    }
    ChatMessage boundary;
    boundary.role = "user"; boundary.internal = true;
    boundary.content = controlHistoryBoundary ~ "Current task state";
    append(session, boundary);
    ChatMessage ending;
    ending.role = "assistant"; ending.content = "Current answer";
    append(session, ending);
    auto cache = new RequestProjectionCache();
    ProjectionRevision revision = ProjectionRevision(1, 1);
    size_t cases;
    foreach (summary; [false, true])
        foreach (images; [0, 1, 3])
        {
            string[] anchors = ["", "missing-id"];
            foreach (message; session.messages) anchors ~= message.id;
            foreach (anchor; anchors)
            {
                size_t[] expectedSlots, cachedSlots;
                const expected = projectRequestMessages(session, anchor, summary, images, &expectedSlots);
                const actual = cache.project(session, revision, anchor, summary, images, &cachedSlots);
                assert(actual == expected && cachedSlots == expectedSlots,
                    "Cached suffix changed tool envelopes, images or source positions: " ~ anchor);
                ++cases;
            }
        }
    assert(cache.builds == 6 && cache.hits == cases - 6, "Suffixes rebuilt the full graph");
    auto mutableView = cache.project(session, revision);
    foreach (ref message; mutableView)
    {
        message.content = "Caller mutation";
        if (message.toolCalls.length) message.toolCalls[0].arguments = "changed";
        if (message.images.length) message.images[0].name = "changed";
    }
    assert(cache.project(session, revision) == projectRequestMessages(session), "Caller mutated cached arrays");
    const builds = cache.builds;
    ++revision.capabilities;
    cache.project(session, revision);
    assert(cache.builds == builds + 1);
    session.messages[0].content = "Changed instruction";
    ++revision.graph;
    assert(cache.project(session, revision) == projectRequestMessages(session));
    session.activeLeafId = session.messages[9].id;
    assert(cache.project(session, revision) == projectRequestMessages(session), "Branch selection reused another leaf");
    auto bounded = new RequestProjectionCache(512);
    assert(bounded.project(session, revision) == projectRequestMessages(session));
    assert(bounded.retainedBytes() == 0, "Oversized projection escaped the retention budget");
    ChatSession hidden;
    hidden.id = "control-only";
    foreach (i; 0 .. 100)
    {
        ChatMessage control;
        control.role = "user"; control.internal = true;
        control.content = controlHistoryBoundary ~ "Task state";
        append(hidden, control);
    }
    auto indexed = new RequestProjectionCache(4096);
    assert(indexed.project(hidden, revision) == projectRequestMessages(hidden));
    assert(indexed.retainedBytes() == 0, "Omitted history index escaped the retention budget");
    cache.clear();
    assert(cache.retainedBytes() == 0);
    writeln("PASS ", cases, " cached suffix equivalence cases; branch/capability invalidation, private arrays and byte budget");
    return 0;
}
