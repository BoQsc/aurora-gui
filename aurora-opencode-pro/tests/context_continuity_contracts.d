module context_continuity_contracts;

import auroraopencode.core;
import auroraopencode.contextcheckpoint;
import auroraopencode.requestbuilder;
import auroraopencode.historyrecall;
import auroraopencode.workevidence : observedResultKey;
import core.time : MonoTime;
import std.array : replicate;
import std.conv : to;
import std.json : parseJSON;
import std.stdio : writeln;
import std.string : indexOf, startsWith;
import std.utf : validate;

void add(ref ChatSession session, string id, string role, string text)
{
    ChatMessage message;
    message.id = id; message.parentId = session.activeLeafId;
    message.role = role; message.content = text;
    session.messages ~= message; session.activeLeafId = id;
}

// The old algorithm is retained only as a differential test oracle.
size_t previousBoundary(const ref ChatSession s, const(size_t)[] path, size_t start, size_t budget)
{
    auto boundary = path.length;
    foreach_reverse (i; start .. path.length)
    {
        const ref m = s.messages[path[i]];
        if (i + 1 == path.length && m.role != "tool") continue;
        if (m.role == "assistant" && m.toolCalls.length) continue;
        if (m.role == "tool" && i + 1 < path.length && s.messages[path[i + 1]].role == "tool") continue;
        if (requestMessageBytes(projectRequestMessages(s, m.id)) > budget) break;
        boundary = i;
    }
    return boundary;
}

int main()
{
    ChatSession session;
    const original = "λ🙂 record\n".replicate(3000) ~ "CRITICAL_REFERENCE_VALUE=Q9-7316\n" ~ "tail\n".replicate(3000);
    add(session, "reference", "user", original);
    add(session, "internal", "user", "INTERNAL_SECRET"); session.messages[$ - 1].internal = true;
    add(session, "check", "tool", "Historical verification passed");
    session.messages[$ - 1].toolName = "verify";
    session.messages[$ - 1].toolCallId = "old-check";
    session.messages[$ - 1].toolArgs = `{"program":"python","args":["-m","unittest"]}`;
    add(session, "branch-a", "user", "SELECTED_BRANCH_ONLY");
    const active = session.activeLeafId;
    add(session, "branch-b", "user", "UNSELECTED_BRANCH_SECRET");
    session.activeLeafId = active;
    auto result = parseJSON(readHistory(session, `{"query":"CRITICAL_REFERENCE_VALUE"}`));
    assert(result["messages"].array.length == 1);
    auto row = result["messages"][0];
    assert(row["message_id"].str == "reference" && row["text"].str.indexOf("Q9-7316") >= 0);
    assert(parseJSON(readHistory(session, `{"query":"INTERNAL_SECRET"}`))["messages"].array.length == 0);
    assert(parseJSON(readHistory(session, `{"query":"UNSELECTED_BRANCH_SECRET"}`))["messages"].array.length == 0);
    assert(readHistory(session, `{"message_id":"branch-b"}`).startsWith("Error:"));
    assert(readHistory(session, `{"before_id":"branch-b"}`).startsWith("Error:"));
    result = parseJSON(readHistory(session, `{"message_id":"check","field":"tool_arguments"}`));
    assert(result["messages"][0]["text"].str.indexOf("unittest") >= 0);
    string reconstructed;
    size_t offset;
    do
    {
        result = parseJSON(readHistory(session, `{"message_id":"reference","limit":997,"offset":` ~ to!string(offset) ~ `}`));
        row = result["messages"][0];
        validate(row["text"].str);
        assert(row["offset"].integer == offset);
        reconstructed ~= row["text"].str;
        if (auto next = "next_offset" in row.object) offset = cast(size_t) next.integer;
        else break;
    } while (true);
    assert(reconstructed == original, "Paged recall lost or duplicated original bytes");
    result = parseJSON(readHistory(session, `{"max_results":1}`));
    assert(result["messages"][0]["message_id"].str == "branch-a");
    result = parseJSON(readHistory(session, `{"before_id":"branch-a","max_results":1}`));
    assert(result["messages"][0]["message_id"].str == "check");
    foreach (bad; [`[]`, `{"offset":-1}`, `{"query":false}`, `{"limit":0}`, `{"message_id":"reference","offset":9999999}`])
        assert(readHistory(session, bad).startsWith("Error:"));
    ChatMessage recalled; recalled.role = "tool"; recalled.toolName = "read_history";
    recalled.content = "Historical verification passed";
    assert(observedResultKey(recalled).length == 0, "Recall was counted as fresh work");
    assert(session.messages[0].content == original && session.activeLeafId == active);
    writeln("PASS exact middle-fact retrieval, UTF-8 paging, branch/internal isolation, argument recovery and evidence boundaries");

    ChatSession longChat;
    foreach (i; 0 .. 1600)
    {
        add(longChat, "m" ~ to!string(i), i % 2 ? "assistant" : "user", "Durable work λ🙂\n".replicate(10));
        if (i % 11 == 0) longChat.messages[$ - 1].internal = true;
    }
    add(longChat, "calls", "assistant", "Checking");
    longChat.messages[$ - 1].toolCalls = [OpenCodeToolCall("one", "read", "{}"), OpenCodeToolCall("two", "read", "{}")];
    add(longChat, "result-one", "tool", "First result"); longChat.messages[$ - 1].toolCallId = "one";
    add(longChat, "result-two", "tool", "Second result"); longChat.messages[$ - 1].toolCallId = "two";
    auto path = activeMessagePath(longChat);
    foreach (budget; [0, 64, 4000, 64000, 256000])
        foreach (start; [cast(size_t) 0, cast(size_t) 800])
            assert(compactionBoundary(longChat, path, start, budget) == previousBoundary(longChat, path, start, budget));
    auto began = MonoTime.currTime;
    const oldBoundary = previousBoundary(longChat, path, 0, 256000);
    const oldUs = (MonoTime.currTime - began).total!"usecs";
    began = MonoTime.currTime;
    const newBoundary = compactionBoundary(longChat, path, 0, 256000);
    const newUs = (MonoTime.currTime - began).total!"usecs";
    assert(newBoundary == oldBoundary);
    writeln("BOUNDARY_BENCHMARK messages=", path.length, " previous_us=", oldUs, " current_us=", newUs);
    add(longChat, "unfinished", "assistant", "Pending");
    longChat.messages[$ - 1].toolCalls = [OpenCodeToolCall("missing", "read", "{}")];
    path = activeMessagePath(longChat);
    assert(compactionBoundary(longChat, path, 0, 4000) == previousBoundary(longChat, path, 0, 4000));
    assert(completeCompactionResponse(false, "stop"));
    assert(completeCompactionResponse(false, ""));
    foreach (reason; ["length", "content_filter", "tool_calls", "error"])
        assert(!completeCompactionResponse(false, reason));
    assert(!completeCompactionResponse(true, "stop"));
    writeln("PASS cutoff equivalence, complete tool groups and summary completion policy");
    return 0;
}
