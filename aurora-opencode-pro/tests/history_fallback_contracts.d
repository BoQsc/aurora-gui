// read_history fallback contract: when the exact record is gone or nothing
// matches, the retired checkpoint digest still gives the model usable quoted
// context instead of a dead-end error. The digest must stay bounded, keep the
// newest retired entries, preserve UTF-8, and be recorded as a successful tool
// result so the turn is not marked failed.
module history_fallback_contracts;

import auroraopencode.core;
import auroraopencode.contextpolicy : rollCompactionCheckpoint;
import auroraopencode.historyrecall : readHistory;
import auroraopencode.events : OpenCodeEvent;
import auroraopencode.toolsettlement : settleToolResult, ToolResultPolicy;
import std.array : appender, join, replicate;
import std.conv : to;
import std.json : JSONType, parseJSON;
import core.time : MonoTime;
import std.stdio : writeln;
import std.string : indexOf, lastIndexOf, startsWith;
import std.utf : validate;

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

ChatSession rollingTask()
{
    ChatSession session;
    session.id = "fallback";
    session.objective = "Keep the retired audit facts recoverable.";
    session.contract.id = "fallback-task";
    session.contract.startMessageId = "start";
    session.contract.intent = "implementation";
    session.contract.currentIntent = "implementation";
    addMessage(session, "start", "user", session.objective);
    foreach (i; 0 .. 100)
    {
        const callId = "call-" ~ to!string(i);
        ChatMessage call;
        call.id = callId; call.parentId = session.activeLeafId;
        call.role = "assistant";
        call.toolCalls = [OpenCodeToolCall(callId, "read",
            `{"filePath":"source/part` ~ to!string(i) ~ `.d"}`)];
        session.messages ~= call; session.activeLeafId = callId;
        ChatMessage result;
        result.id = callId ~ "-result"; result.parentId = session.activeLeafId;
        result.role = "tool"; result.toolName = "read"; result.toolCallId = callId;
        result.content = "RETIRED-FACT-" ~ to!string(i) ~ "\n" ~
            "retired window data λ🙂\n".replicate(12);
        session.messages ~= result; session.activeLeafId = result.id;
    }
    return session;
}

int main()
{
    // A real rolling checkpoint, then a lookup for a message that no longer
    // exists. The digest must describe what was retired.
    auto session = rollingTask();
    assert(rollCompactionCheckpoint(session, 8192, 6000),
        "the fallback fixture did not retire any messages");
    assert(session.compactionSummary.indexOf("## Earlier context") >= 0);
    const summary = session.compactionSummary;
    const marker = summary.lastIndexOf("RETIRED-FACT-");
    assert(marker >= 0, "no retired fact reached the checkpoint");
    const after = summary[marker .. $];
    const token = after[0 .. after.indexOf("\n")];

    const missing = readHistory(session, `{"message_id":"no-such-message"}`);
    assert(!missing.startsWith("Error:"),
        "a missing message still returned a dead-end error");
    auto parsed = parseJSON(missing);
    assert(parsed["fallback"].type == JSONType.true_);
    assert(parsed["fallback_reason"].str.indexOf("message_id") >= 0);
    assert(parsed["retired_through"].str == session.compactedThroughMessageId);
    assert(parsed["retired_messages"].integer > 0);
    assert(parsed["messages"].array.length == 1);
    const digest = parsed["messages"][0]["text"].str;
    validate(digest);
    assert(digest.indexOf(token) >= 0,
        "the fallback digest lost the newest retired fact " ~ token);
    assert(digest.indexOf("not current instructions") >= 0);
    assert(digest.length <= 4400, "the fallback digest escaped its budget: " ~ to!string(digest.length));

    // A search with no match falls back too, and a bad before_id does not
    // leave the model without context.
    const absent = parseJSON(readHistory(session, `{"query":"NEVER-RECORDED-TOKEN"}`));
    assert(absent["fallback"].type == JSONType.true_ &&
        absent["messages"][0]["text"].str.indexOf(token) >= 0,
        "a no-match search returned no usable fallback");
    const before = parseJSON(readHistory(session, `{"before_id":"no-such-message","query":"x"}`));
    assert(before["fallback"].type == JSONType.true_);

    // Usage errors stay errors: a fallback must not hide a malformed call.
    assert(readHistory(session, `{"limit":0}`).startsWith("Error:"));
    assert(readHistory(session, `{"offset":-1}`).startsWith("Error:"));

    // Tool settlement records the fallback as a successful read, not a failed
    // tool call that would trip recovery or verification bookkeeping.
    OpenCodeEvent event;
    event.toolName = "read_history";
    event.toolCallId = "history-fallback";
    event.text = "";
    ToolResultPolicy policy;
    auto settled = settleToolResult(session, event,
        `{"message_id":"no-such-message"}`, policy);
    assert(!settled.message.failed, "the fallback was recorded as a failed tool call");
    assert(settled.message.content.indexOf(`"fallback":true`) >= 0);

    // A very long retired checkpoint keeps the newest entries and a hard
    // bound; the oldest entry is the first thing dropped.
    ChatSession many;
    many.objective = "Long retired history";
    many.contract.id = "many";
    many.contract.startMessageId = "many-start";
    addMessage(many, "many-start", "user", many.objective);
    auto entries = appender!string();
    entries.put("Earlier conversation checkpoint. Use read_history for exact omitted messages.\n" ~
        "## Earlier context\n");
    foreach (i; 0 .. 300)
        entries.put("- user message_id=entry-" ~ to!string(i) ~ ": ENTRY-" ~ to!string(i) ~
            ": retired requirement λ🙂 " ~ "detail ".replicate(3) ~ "\n");
    many.compactionSummary = entries.data;
    many.compactedThroughMessageId = "many-start";
    auto bounded = parseJSON(readHistory(many, `{"message_id":"gone"}`));
    const boundedText = bounded["messages"][0]["text"].str;
    validate(boundedText);
    assert(boundedText.length <= 4400,
        "the bounded checkpoint digest exceeded its budget: " ~ to!string(boundedText.length));
    assert(boundedText.indexOf("ENTRY-299") >= 0,
        "the digest dropped the newest retired entry");
    assert(boundedText.indexOf("ENTRY-0:") < 0,
        "the digest retained the oldest entry ahead of newer ones");
    assert(boundedText.indexOf("ENTRY-199") < 0 ||
        boundedText.indexOf("ENTRY-299") < boundedText.indexOf("ENTRY-199"),
        "the digest was not ordered newest first");

    // A summary with no entry section (an older or model-refined checkpoint)
    // still yields a valid UTF-8 bounded tail rather than a broken byte slice.
    ChatSession headerOnly;
    headerOnly.objective = "Header only";
    headerOnly.contract.id = "header-only";
    headerOnly.contract.startMessageId = "header-start";
    addMessage(headerOnly, "header-start", "user", headerOnly.objective);
    headerOnly.compactionSummary = "Checkpoint header λ🙂\n" ~ "λ🙂 detail row\n".replicate(4000);
    headerOnly.compactedThroughMessageId = "header-start";
    auto headerFallback = parseJSON(readHistory(headerOnly, `{"message_id":"gone"}`));
    const headerText = headerFallback["messages"][0]["text"].str;
    validate(headerText);
    assert(headerText.length > 0 && headerText.length <= 4400,
        "the header-only fallback escaped its budget");
    assert(headerText.indexOf("λ🙂") >= 0);

    // Without a retired checkpoint the original behavior is unchanged.
    ChatSession plain;
    addMessage(plain, "only", "user", "UNIQUE-PLAIN-FACT");
    assert(readHistory(plain, `{"message_id":"gone"}`).startsWith("Error:"));
    auto none = parseJSON(readHistory(plain, `{"query":"ABSENT"}`));
    assert(none["messages"].array.length == 0 && !("fallback" in none.object));
    auto exact = parseJSON(readHistory(plain, `{"message_id":"only"}`));
    assert(exact["messages"][0]["text"].str == "UNIQUE-PLAIN-FACT");

    // A stale checkpoint (anchor not on the active branch) must not pretend the
    // digest describes this branch.
    ChatSession stale;
    addMessage(stale, "stale-only", "user", "Current branch fact");
    stale.compactionSummary = "## Earlier context\n- user message_id=old: OLD-BRANCH-FACT\n";
    stale.compactedThroughMessageId = "not-on-this-branch";
    assert(readHistory(stale, `{"message_id":"gone"}`).startsWith("Error:"),
        "a stale checkpoint produced a fallback for the wrong branch");
    auto staleNone = parseJSON(readHistory(stale, `{"query":"ABSENT"}`));
    assert(staleNone["messages"].array.length == 0 && !("fallback" in staleNone.object));

    // Internal control messages are not retired user work; the count and the
    // digest must reflect only messages the model could see.
    ChatSession counted;
    counted.objective = "Count retired work";
    counted.contract.id = "counted";
    counted.contract.startMessageId = "start";
    addMessage(counted, "start", "user", "Visible start");
    ChatMessage hidden;
    hidden.id = "hidden"; hidden.parentId = counted.activeLeafId;
    hidden.role = "user"; hidden.content = "INTERNAL-SECRET"; hidden.internal = true;
    counted.messages ~= hidden; counted.activeLeafId = hidden.id;
    addMessage(counted, "anchor", "user", "Visible anchor");
    counted.compactionSummary = "## Earlier context\n- user message_id=start: Visible start\n";
    counted.compactedThroughMessageId = "anchor";
    auto countedResult = parseJSON(readHistory(counted, `{"message_id":"gone"}`));
    assert(countedResult["retired_messages"].integer == 2,
        "the retired count included an internal control message: " ~
        to!string(countedResult["retired_messages"].integer));

    // A single huge entry is capped, and a UTF-8 cut lands on a character
    // boundary instead of emitting a broken byte sequence.
    ChatSession hugeEntry;
    hugeEntry.objective = "Huge entry";
    hugeEntry.contract.id = "huge";
    hugeEntry.contract.startMessageId = "huge-start";
    addMessage(hugeEntry, "huge-start", "user", hugeEntry.objective);
    hugeEntry.compactionSummary = "## Earlier context\n- user message_id=solo: " ~
        "λ🙂".replicate(4000) ~ "ENTRY-END-MARKER\n";
    hugeEntry.compactedThroughMessageId = "huge-start";
    auto huge = parseJSON(readHistory(hugeEntry, `{"message_id":"gone"}`));
    const hugeText = huge["messages"][0]["text"].str;
    validate(hugeText);
    assert(hugeText.length <= 4400, "a single huge entry escaped the digest budget");
    assert(hugeText.indexOf("ENTRY-END-MARKER") < 0,
        "the entry cap did not cut a long single entry");

    // Filters and argument validation keep their behavior with a checkpoint.
    assert(readHistory(session, `{"role":"tool","query":"NEVER-TOOL"}`)
        .indexOf(`"fallback":true`) >= 0);
    assert(readHistory(session, `{"field":"tool_arguments","query":"NEVER-ARGS"}`)
        .indexOf(`"fallback":true`) >= 0);
    assert(readHistory(session, `{"query":"` ~ "x".replicate(1025) ~ `"}`)
        .startsWith("Error:"));
    assert(readHistory(session, `{"message_id":"a","query":"b"}`).startsWith("Error:"));
    assert(readHistory(session, `{"query":false}`).startsWith("Error:"));

    // Repeated reads and the saved session are unchanged by a fallback.
    const beforeMessages = session.messages.length;
    const beforeLeaf = session.activeLeafId;
    const beforeSummary = session.compactionSummary;
    const beforeState = activeTaskStateJson(session);
    const firstCall = readHistory(session, `{"message_id":"no-such-message"}`);
    const secondCall = readHistory(session, `{"message_id":"no-such-message"}`);
    assert(firstCall == secondCall, "the fallback digest was not deterministic");
    assert(session.messages.length == beforeMessages &&
        session.activeLeafId == beforeLeaf &&
        session.compactionSummary == beforeSummary &&
        activeTaskStateJson(session) == beforeState,
        "a fallback read mutated the saved session");

    // Deterministic randomized stress: every argument path must either return
    // a parseable result or a stable error, within budget, without throwing or
    // mutating the session.
    uint seed = 0x5EED1234;
    uint next()
    {
        seed = seed * 1_664_525 + 1_013_904_223;
        return seed;
    }
    foreach (iteration; 0 .. 300)
    {
        ChatSession random;
        random.id = "random-" ~ to!string(iteration);
        const size = next() % 40;
        foreach (i; 0 .. size)
        {
            const role = ["user", "assistant", "tool"][next() % 3];
            const id = role == "tool" ? "r-" ~ to!string(i) : "r-" ~ to!string(i);
            ChatMessage message;
            message.id = id; message.parentId = random.activeLeafId;
            message.role = role;
            message.content = ["FACT-" ~ to!string(next() % 100), "λ🙂 row", ""]
                [next() % 3] ~ " " ~ "pad ".replicate(next() % 40);
            if (role == "tool") { message.toolName = "read"; message.toolCallId = id; }
            if (next() % 9 == 0) message.internal = true;
            random.messages ~= message; random.activeLeafId = id;
        }
        if (size && next() % 2 == 0)
        {
            auto checkpoint = appender!string();
            checkpoint.put("Earlier conversation checkpoint.\n## Earlier context\n");
            foreach (i; 0 .. 1 + next() % 80)
                checkpoint.put("- user message_id=x-" ~ to!string(i) ~ ": RANDOM-" ~
                    to!string(i) ~ " λ🙂 " ~ "text ".replicate(next() % 20) ~ "\n");
            random.compactionSummary = checkpoint.data;
            const anchor = "r-" ~ to!string(next() % size);
            random.compactedThroughMessageId = next() % 4 == 0 ? "missing-anchor" : anchor;
        }
        const savedMessages = random.messages.length;
        const savedLeaf = random.activeLeafId;
        const savedSummary = random.compactionSummary;
        const args = [
            `{"message_id":"gone-"` ~ to!string(iteration) ~ `"}`,
            `{"query":"RANDOM-"}`,
            `{"query":"NO-SUCH-FACT"}`,
            `{"before_id":"gone","query":"FACT"}`,
            `{"role":"user","query":"FACT"}`,
            `{"limit":0}`,
            `{"offset":-1}`,
            `{"query":true}`,
        ][next() % 8];
        string result;
        try result = readHistory(random, args);
        catch (Exception error)
            assert(false, "readHistory threw on iteration " ~ to!string(iteration) ~ ": " ~ error.msg);
        if (!result.startsWith("Error:"))
        {
            auto value = parseJSON(result);
            assert(value["messages"].type == JSONType.array);
            foreach (row; value["messages"].array)
            {
                const text = row["text"].str;
                validate(text);
                assert(text.length <= 12000);
            }
            if (value.object is null || !("fallback" in value.object))
            {
                // Normal recall or an empty result.
            }
            else
            {
                assert(value["fallback"].type == JSONType.true_);
                assert(value["messages"].array.length == 1);
                assert(value["messages"][0]["text"].str.length <= 4400);
                assert(value["fallback_reason"].str.length > 0);
            }
        }
        assert(random.messages.length == savedMessages &&
            random.activeLeafId == savedLeaf &&
            random.compactionSummary == savedSummary,
            "randomized fallback mutated the saved session");
        assert(readHistory(random, args) == result,
            "randomized fallback was not deterministic");
    }

    // Long session: the fallback stays fast enough for a tool boundary.
    ChatSession longSession;
    longSession.objective = "Long session";
    longSession.contract.id = "long-session";
    longSession.contract.startMessageId = "long-start";
    addMessage(longSession, "long-start", "user", "Start");
    foreach (i; 0 .. 20_000)
    {
        ChatMessage message;
        message.id = "long-" ~ to!string(i); message.parentId = longSession.activeLeafId;
        message.role = i % 2 ? "assistant" : "tool";
        if (message.role == "tool") { message.toolName = "read"; message.toolCallId = message.id; }
        message.content = "long row " ~ to!string(i);
        longSession.messages ~= message; longSession.activeLeafId = message.id;
    }
    longSession.compactionSummary = "## Earlier context\n" ~
        "- user message_id=long-0: LONG-RETIRED-FACT\n";
    longSession.compactedThroughMessageId = "long-start";
    const began = MonoTime.currTime;
    auto longResult = readHistory(longSession, `{"message_id":"missing-in-long-session"}`);
    const elapsedMs = (MonoTime.currTime - began).total!"usecs" / 1000.0;
    assert(longResult.indexOf(`"fallback":true`) >= 0);
    assert(elapsedMs < 2000,
        "fallback lookup on a 20k-message session took " ~ to!string(elapsedMs) ~ " ms");
    writeln("Long-session fallback: messages=20001 elapsed_ms=", elapsedMs);

    writeln("PASS failed exact recall falls back to a bounded, newest-first, quoted retired-checkpoint digest");
    writeln("PASS the fallback is a successful history read; usage errors and conversations without retirement are unchanged");
    writeln("PASS stale checkpoints, internal counting, entry caps, filters, determinism, immutability and 300 randomized cases");
    writeln("PASS a 20k-message session keeps the fallback inside a tool-boundary budget");
    return 0;
}
