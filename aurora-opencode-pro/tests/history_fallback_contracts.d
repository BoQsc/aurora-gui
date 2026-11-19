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

    writeln("PASS failed exact recall falls back to a bounded, newest-first, quoted retired-checkpoint digest");
    writeln("PASS the fallback is a successful history read; usage errors and conversations without retirement are unchanged");
    return 0;
}
