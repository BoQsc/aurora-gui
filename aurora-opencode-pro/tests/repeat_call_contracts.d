module repeat_call_contracts;

import auroraopencode.core : ChatMessage, ChatSession, OpenCodeToolCall;
import auroraopencode.toolprogresspolicy : isConsecutiveSuccessfulRepeat,
    isReadOnlyOrControlBatch;
import std.conv : to;
import std.stdio : writeln;

private ChatSession sessionWith(ChatMessage[] messages)
{
    ChatSession session;
    session.messages = messages;
    foreach (index, ref message; session.messages)
    {
        message.id = "message-" ~ to!string(index);
        message.parentId = index == 0 ? "" : session.messages[index - 1].id;
    }
    if (session.messages.length)
        session.activeLeafId = session.messages[$ - 1].id;
    return session;
}

int main()
{
    const readArgs = `{"filePath":"a.d"}`;
    auto readCall = OpenCodeToolCall("read-1", "read", readArgs);
    auto writeCall = OpenCodeToolCall("write-1", "write", `{"filePath":"a.d","content":"x"}`);
    auto sleepCall = OpenCodeToolCall("dshell-1", "dshell", `{"command":"sleep","seconds":1}`);
    auto listCall = OpenCodeToolCall("dshell-2", "dshell", `{"command":"list"}`);
    auto planCall = OpenCodeToolCall("plan-1", "update_plan", `{}`);

    assert(isReadOnlyOrControlBatch([readCall]));
    assert(isReadOnlyOrControlBatch([listCall]));
    assert(isReadOnlyOrControlBatch([planCall]));
    assert(!isReadOnlyOrControlBatch([writeCall]));
    assert(!isReadOnlyOrControlBatch([sleepCall]));

    ChatMessage user;
    user.role = "user";
    user.content = "go";
    ChatMessage assistant;
    assistant.role = "assistant";
    assistant.toolCalls = [readCall];
    ChatMessage success;
    success.role = "tool";
    success.toolName = "read";
    success.toolArgs = readArgs;
    success.content = "ok";
    auto successful = sessionWith([user, assistant, success]);
    assert(isConsecutiveSuccessfulRepeat(successful, [readCall]));

    auto failed = success;
    failed.failed = true;
    failed.content = "Error: no";
    auto failedSession = sessionWith([user, assistant, failed]);
    assert(!isConsecutiveSuccessfulRepeat(failedSession, [readCall]));

    auto skipped = success;
    skipped.failed = true;
    skipped.content = "Tool call skipped: duplicate";
    auto skippedSession = sessionWith([user, assistant, skipped]);
    assert(isConsecutiveSuccessfulRepeat(skippedSession, [readCall]));

    auto changed = OpenCodeToolCall("read-2", "read", `{"filePath":"b.d"}`);
    assert(!isConsecutiveSuccessfulRepeat(successful, [changed]));

    ChatMessage writeAssistant;
    writeAssistant.role = "assistant";
    writeAssistant.toolCalls = [writeCall];
    ChatMessage writeResult;
    writeResult.role = "tool";
    writeResult.toolName = "write";
    writeResult.toolArgs = writeCall.arguments;
    writeResult.content = "ok";
    auto writeSession = sessionWith([user, writeAssistant, writeResult]);
    assert(!isConsecutiveSuccessfulRepeat(writeSession, [readCall]));

    ChatMessage secondUser;
    secondUser.role = "user";
    secondUser.content = "again";
    auto newTurn = sessionWith([user, assistant, success, secondUser]);
    assert(!isConsecutiveSuccessfulRepeat(newTurn, [readCall]));

    writeln("PASS repeat guard skips only consecutive successful read-only/control batches");
    return 0;
}