module conversation_job_contracts;

import auroraopencode.core;
import auroraopencode.conversationjobs;
import auroraopencode.conversationconfiguration;
import auroraopencode.contextcheckpoint;
import auroraopencode.titlepolicy;
import auroraopencode.opencode_client;
import auroraopencode.conversationencode;
import auroraopencode.conversationcodec;
import auroraopencode.tools : ToolCancellation;
import auroraopencode.repository : ConversationRepository, RepositoryRuntime;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import std.file : mkdirRecurse;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.json : parseJSON;
import std.stdio : writeln;
import std.string : split;
import std.utf : byDchar, validate;
import std.range : walkLength, repeat;
import std.array : join;

private void append(ref ChatSession session, string id, string role, string content)
{
    ChatMessage message; message.id = id; message.parentId = session.activeLeafId;
    message.role = role; message.content = content; session.messages ~= message; session.activeLeafId = id;
}
private void start(ConversationJobs jobs, ModelJobKind kind, ChatRequestMessage[] messages)
{
    ActorConfiguration config; jobs.start(kind, 7, messages, config, "offline", "route", 100, true, null, new ToolCancellation());
}
private bool finish(ConversationJobs jobs, ModelJobKind kind, ref ChatSession session, string text, string reason = "stop")
{
    OpenCodeEvent event; event.requestId = 7; event.kind = OpenCodeEventKind.delta; event.text = text;
    assert(!jobs.accept(kind, event, session, true));
    event.kind = OpenCodeEventKind.done; event.finishReason = reason;
    return jobs.accept(kind, event, session, true);
}
private final class Gate
{
    Mutex mutex; Condition wake; bool entered, released;
    this() { mutex = new Mutex(); wake = new Condition(mutex); }
    void block() { synchronized (mutex) { entered = true; wake.notifyAll(); while (!released) wake.wait(); } }
    void waitEntered() { synchronized (mutex) while (!entered) wake.wait(); }
    void release() { synchronized (mutex) { released = true; wake.notifyAll(); } }
}
int main()
{
    const unicode = repeat("😀", 70).join();
    const cleaned = cleanGeneratedTitle("\nTitle: `" ~ unicode ~ "`\nIgnored second line");
    validate(cleaned); assert(cleaned.byDchar.walkLength == 60);
    assert(cleanGeneratedTitle("Title: \"one two three four five six seven.\"").split().length == 6);
    assert(cleanGeneratedTitle("<think>private</think>") == "");
    assert(titlePrefix(unicode, 3) == "😀😀😀");
    ChatSession title; title.id = "title"; append(title, "seed", "user", unicode);
    auto jobs = new ConversationJobs(); auto messages = jobs.prepareTitle(title);
    assert(title.titleAttempts == 1 && messages.length == 2); validate(messages[1].content);
    start(jobs, ModelJobKind.title, messages);
    assert(!jobs.expired(ModelJobKind.title, 15_099) && jobs.expired(ModelJobKind.title, 15_100));
    title.titleManual = true; title.title = "User title";
    assert(!finish(jobs, ModelJobKind.title, title, "Overwritten title")); assert(title.title == "User title");
    title.titleManual = false; title.title = "";
    messages = jobs.prepareTitle(title); assert(title.titleAttempts == 2);
    start(jobs, ModelJobKind.title, messages);
    assert(!finish(jobs, ModelJobKind.title, title, "Truncated title", "length"));
    assert(!jobs.prepareTitle(title).length);
    ChatSession restored; decodeSessionMetadata(parseJSON(sessionToJson(title).toString()), restored);
    assert(restored.titleAttempts == 2 && !jobs.prepareTitle(restored).length);

    ChatSession compact; compact.id = "compact"; compact.objective = "Preserve every constraint";
    append(compact, "anchor", "user", "Opening instruction");
    append(compact, "leaf", "user", "Most recent instruction");
    compact.compactedThroughMessageId = "anchor"; compact.compactionSummary = "Extractive fallback";
    const summary = "Goal: preserve the user's objective and constraints. Evidence: the initial analysis is saved. Remaining outcome: complete the requested analysis. Next action: continue from the preserved recent messages.";
    foreach (mode; 0 .. 6)
    {
        auto session = snapshotChatSessions([compact])[0];
        messages = jobs.prepareCompaction(session, "", "", 10_000); assert(messages.length == 2);
        start(jobs, ModelJobKind.compaction, messages);
        assert(!jobs.expired(ModelJobKind.compaction, 45_099) && jobs.expired(ModelJobKind.compaction, 45_100));
        if (mode == 0) append(session, "reply", "assistant", "Current work continued");
        if (mode == 1) session.activeLeafId = "anchor";
        if (mode == 2) session.goal = "Replacement goal";
        if (mode == 3) session.compactedThroughMessageId = "leaf";
        if (mode == 4)
        {
            OpenCodeEvent tool; tool.kind = OpenCodeEventKind.toolCalls; tool.requestId = 7;
            tool.toolCalls ~= OpenCodeToolCall("never-execute", "write", "{}");
            assert(!jobs.accept(ModelJobKind.compaction, tool, session, true));
        }
        const applied = finish(jobs, ModelJobKind.compaction, session, summary, mode == 5 ? "length" : "stop");
        assert(applied == (mode == 0));
        assert(session.messages.length == (mode == 0 ? 3 : 2));
        if (!applied) assert(session.compactionSummary == compact.compactionSummary);
    }
    messages = jobs.prepareCompaction(compact, "", "", 10_000); start(jobs, ModelJobKind.compaction, messages);
    assert(!finish(jobs, ModelJobKind.compaction, compact, repeat("x", compactionOutputLimit + 1).join()));
    assert(!jobs.busy());
    const directory = absolutePath("job-admission"); mkdirRecurse(directory);
    auto repository = new ConversationRepository(); auto gate = new Gate();
    scope (exit) { gate.release(); repository.close(); }
    auto journal = new RepositoryRuntime(repository, buildPath(directory, "events.jsonl"));
    assert(repository.submit(&gate.block)); gate.waitEntered();
    messages = jobs.prepareCompaction(compact, "", "", 10_000);
    auto stopGate = new ToolCancellation(); ActorConfiguration config;
    config.baseUrl = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "http://127.0.0.1:1");
    jobs.start(ModelJobKind.compaction, 10, messages, config, "queued-cancel", "route", 0, false, journal, stopGate);
    stopGate.cancel(); jobs.close(); gate.release(); repository.flush();
    assert(!jobs.busy());
    writeln("PASS Unicode titles, durable attempt cap, manual rename, descendant summary, stale branch/task/anchor rejection, output limits, tool rejection and deadlines");
    return 0;
}
