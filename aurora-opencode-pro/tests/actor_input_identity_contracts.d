module actor_input_identity_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.conversationencode;
import auroraopencode.conversationcodec;
import auroraopencode.inputidentity;
import auroraopencode.conversationcoordination;
import auroraopencode.orchestrator : OrchestratorAssignment;
import auroraopencode.repository;
import auroraopencode.runtime : projectAgentRuntimeEvents;
import actorview;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, exists, write;
import std.json : parseJSON;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", ""), releases = environment.get("AURORA_CONTRACT_RELEASE_DIR", "");
    assert(base.length && releases.length, "Run test_actor_input_identity.py");
    const directory = absolutePath("input-identity-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    auto repository = new ConversationRepository(); scope (exit) repository.close();
    auto journal = new RepositoryRuntime(repository, buildPath(directory, "events.jsonl"));
    ChatSession initial; initial.id = "deduplicated-chat"; initial.model = "deduplicated-model";
    ActorConfiguration config; config.baseUrl = base; config.workspace = directory; config.recordTrace = true; config.outageBudgetMs = 3000;
    auto actor = new ConversationActor(initial, config, journal); auto view = new ActorTestView(initial, actor);
    auto mutex = new Mutex(); ActorInputAcknowledgement[] acknowledgements;
    actor.setInputReceiver((ActorInputAcknowledgement ack) { synchronized (mutex) acknowledgements ~= ack; });
    auto invalid = ActorCommand(ActorCommandKind.stop); invalid.inputId = "not-a-prompt";
    assert(actor.post(invalid) == ActorAdmission.invalid);
    auto first = ActorCommand(ActorCommandKind.start, "Analyze the initial design."); first.inputId = "submitted-first";
    actor.post(first);
    void waitFor(bool delegate() condition)
    {
        const deadline = MonoTime.currTime + 8.seconds;
        while (!condition() && MonoTime.currTime < deadline)
        { view.take(); assert(!actor.fault().length, actor.fault()); Thread.sleep(2.msecs); }
        view.take(); assert(condition(), "Identity fixture did not reach its boundary");
    }
    waitFor(() => exists(buildPath(releases, "request-1.started")) && view.model.messages.length >= 2);
    auto queue = ActorCommand(ActorCommandKind.followUp, "Analyze the second design independently."); queue.inputId = "submitted-second";
    actor.post(queue);
    waitFor(() => view.model.queuedFollowUps.length == 1);
    foreach (_; 0 .. 100) { assert(actor.post(first) == ActorAdmission.accepted); assert(actor.post(queue) == ActorAdmission.accepted); }
    auto duplicateEdit = ActorCommand(ActorCommandKind.editPrompt, "This must never replace the accepted prompt", view.model.messages[0].id);
    duplicateEdit.inputId = first.inputId; assert(actor.post(duplicateEdit) == ActorAdmission.accepted);
    auto durable = projectAgentRuntimeEvents(journal.history());
    assert(durable.length == 1 && inputRecorded(durable[0], first.inputId) && inputRecorded(durable[0], queue.inputId));
    assert(durable[0].queuedFollowUps.length == 1 && durable[0].queuedFollowUpContext[0].inputId == queue.inputId);
    write(buildPath(releases, "request-1.release"), "release");
    waitFor(() => exists(buildPath(releases, "request-2.started")));
    assert(actor.post(queue) == ActorAdmission.accepted); write(buildPath(releases, "request-2.release"), "release");
    waitFor(() => view.model.turnStatus == "completed" && !actor.activity().busy);
    actor.close(); auto state = parseJSON(actor.finalSnapshot());
    assert(parseJSON(ConversationActor.replay(initial, config, actor.recordedTrace())) == state);
    auto recovered = projectAgentRuntimeEvents(journal.history()); assert(recovered.length == 1 && sessionToJson(recovered[0]) == state);
    size_t users; foreach (message; recovered[0].messages) if (message.role == "user" && !message.internal) ++users;
    assert(users == 2);
    synchronized (mutex)
    {
        assert(acknowledgements.length >= 202);
        foreach (ack; acknowledgements) assert(ack.retained && ack.threadId == initial.id);
    }
    auto restored = new ConversationActor(recovered[0], config, journal, null, ActorStart.deferred);
    restored.setInputReceiver((ActorInputAcknowledgement ack) { assert(ack.retained); });
    restored.post(first); restored.post(duplicateEdit); restored.post(queue); restored.close();
    assert(parseJSON(restored.finalSnapshot()) == state, "Recovery retried or cancelled already admitted input");

    auto pendingInitial = recovered[0]; pendingInitial.id = "pending-input";
    auto pending = new ConversationActor(pendingInitial, config, journal, null, ActorStart.deferred);
    auto third = ActorCommand(ActorCommandKind.followUp, "Preserve this pending third instruction."); third.inputId = "submitted-third";
    pending.post(third); pending.post(third); pending.close();
    auto pendingState = parseJSON(pending.finalSnapshot()); ChatSession decoded;
    decodeSessionMetadata(pendingState, decoded); decodeMessages(pendingState["messages"], decoded);
    assert(decoded.queuedFollowUps.length == 1 && inputRecorded(decoded, third.inputId));
    assert(parseJSON(ConversationActor.replay(pendingInitial, config, pending.recordedTrace())) == pendingState);
    ChatSession partial; partial.id = "partial-append"; partial.model = "partial-model"; partial.turnStatus = "interrupted";
    ChatMessage prompt; prompt.id = "original-prompt-node"; prompt.role = "user";
    prompt.content = "Analyze the partial design."; prompt.inputId = "submitted-partial";
    partial.messages = [prompt]; partial.activeLeafId = prompt.id;
    actor = new ConversationActor(partial, config, journal); view = new ActorTestView(partial, actor);
    auto resume = ActorCommand(ActorCommandKind.start, prompt.content); resume.inputId = prompt.inputId;
    resume.context = "Exact hidden context retained by the pending submission.";
    write(buildPath(releases, "request-3.release"), "release"); actor.post(resume);
    waitFor(() => view.model.turnStatus == "completed" && !actor.activity().busy);
    actor.close(); const partialState = parseJSON(actor.finalSnapshot());
    assert(view.model.messages[0].id == prompt.id && view.model.messages[0].inputCommitted);
    users = 0; size_t hidden;
    foreach (message; view.model.messages) if (message.role == "user") { if (message.internal) ++hidden; else ++users; }
    assert(users == 1 && hidden == 1, "An append interrupted before commit duplicated its prompt/context");
    assert(parseJSON(ConversationActor.replay(partial, config, actor.recordedTrace())) == partialState);
    auto waiting = initial; waiting.id = "recovered-parent"; waiting.turnStatus = "running";
    waiting.orchestrationState = dispatchState(waiting, "old-round", [OrchestratorAssignment("builder", "Original task")], ["old-child"]).toString();
    auto stopped = new ConversationActor(waiting, config, journal, null, ActorStart.deferred);
    size_t dispatches, cancellations;
    stopped.setCoordinator((CoordinationEffect effect) { if (effect.kind == CoordinationKind.dispatch) ++dispatches; else if (effect.kind == CoordinationKind.cancel) ++cancellations; return true; });
    stopped.stop(); stopped.close();
    assert(dispatches == 0 && cancellations == 1, "Restore dispatched child work before reducing an already accepted Stop");
    assert(parseJSON(ConversationActor.replay(waiting, config, stopped.recordedTrace())) == parseJSON(stopped.finalSnapshot()));
    writeln("PASS durable submission identity, 202 acknowledged duplicates, no duplicate HTTP/branch cancellation, journal/trace recovery and pending-context identity");
    return 0;
}
