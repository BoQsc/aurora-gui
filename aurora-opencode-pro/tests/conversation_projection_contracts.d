module conversation_projection_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor : ActorChange, ActorChangeKind;
import auroraopencode.conversationprojection;
import auroraopencode.conversationencode;
import auroraopencode.conversationview;
import std.stdio : writeln;

int main()
{
    ChatSession view; view.id = "view";
    auto projection = new ConversationProjection(view);
    ChatMessage user; user.id = "u"; user.role = "user"; user.content = "Prompt";
    ChatMessage assistant; assistant.id = "a"; assistant.parentId = user.id; assistant.role = "assistant";
    auto header = view; header.activeLeafId = assistant.id; header.draft = "Draft";
    header.goal = "Saved goal"; header.goalStatus = "paused"; header.instructions = "Keep compatibility"; header.toolsMode = 1;
    ActorChange[] sequence = [
        ActorChange(ActorChangeKind.added, 1, 1, user.id, messageToJson(user).toString(), false, true),
        ActorChange(ActorChangeKind.added, 2, 1, assistant.id, messageToJson(assistant).toString(), false, true),
        ActorChange(ActorChangeKind.delta, 3, 1, assistant.id, "Reasoning", true, true),
        ActorChange(ActorChangeKind.delta, 4, 1, assistant.id, "Answer", false, true),
        ActorChange(ActorChangeKind.metadata, 5, 1, "", sessionMetaToJson(header).toString(), false, true)];
    auto applied = projection.apply(view, sequence.idup);
    assert(!applied.error.length && !applied.needsSnapshot && applied.structureChanged);
    assert(view.activeLeafId == "a" && view.messages.length == 2);
    assert(view.messages[1].content == "Answer" && view.messages[1].reasoning == "Reasoning");
    assert(view.draft == "Draft" && view.toolsMode == 1 && projection.indexForId("a") == 1);
    projection.apply(view, sequence.idup);
    assert(view.messages[1].content == "Answer", "Repeated UI delivery duplicated assistant text");
    header.draft = ""; header.goal = ""; header.goalStatus = ""; header.instructions = ""; header.toolsMode = -1;
    applied = projection.apply(view, [ActorChange(ActorChangeKind.metadata, 6, 1, "", sessionMetaToJson(header).toString())].idup);
    assert(!applied.error.length && !view.draft.length && !view.goal.length && !view.instructions.length && view.toolsMode == -1,
        "Complete metadata did not clear omitted optional fields");
    applied = projection.apply(view, [ActorChange(ActorChangeKind.delta, 8, 1, "a", "Missing predecessor")].idup);
    assert(applied.needsSnapshot && view.messages[1].content == "Answer");
    auto complete = view; complete.messages = view.messages.dup; complete.messages[1].content = "Recovered answer";
    applied = projection.apply(view, [ActorChange(ActorChangeKind.snapshot, 9, 1, "", sessionToJson(complete).toString())].idup);
    assert(!applied.needsSnapshot && view.messages[1].content == "Recovered answer");
    applied = projection.apply(view, [ActorChange(ActorChangeKind.delta, 10, 1, "unknown", "Misrouted")].idup);
    assert(applied.needsSnapshot && applied.error.length && view.messages[1].content == "Recovered answer");
    auto wrong = complete; wrong.id = "another-chat";
    applied = projection.apply(view, [ActorChange(ActorChangeKind.snapshot, 11, 1, "", sessionToJson(wrong).toString())].idup);
    assert(applied.needsSnapshot && applied.error.length && view.id == "view");
    applied = projection.apply(view, [ActorChange(ActorChangeKind.snapshot, 12, 1, "", sessionToJson(complete).toString())].idup);
    assert(!applied.needsSnapshot && projection.revision() == 12);
    wrong = complete;
    applied = projection.apply(wrong, [ActorChange(ActorChangeKind.metadata, 13, 1, "", sessionMetaToJson(header).toString())].idup);
    assert(!applied.error.length); // The caller can relocate its UI-owned session.
    auto unrelated = view; unrelated.id = "unrelated";
    applied = projection.apply(unrelated, [ActorChange(ActorChangeKind.delta, 14, 1, "a", "wrong owner")].idup);
    assert(applied.error.length && unrelated.messages[1].content == "Recovered answer");
    applied = projection.apply(view, [ActorChange(ActorChangeKind.fault, 14, 1, "", "Storage failed")].idup);
    assert(!projection.busy && !applied.needsSnapshot && applied.error == "Storage failed" && view.turnStatus == "failed");
    auto snapshot = sessionToJson(complete);
    ConversationExecutionView execution; execution.phase = "executingTools";
    ConversationToolView tool; tool.id = "live"; tool.name = "read"; tool.arguments = "{}"; tool.output = "Queued";
    execution.tools = [tool]; snapshot["execution"] = executionViewJson(execution);
    applied = projection.apply(view, [ActorChange(ActorChangeKind.snapshot, 15, 2, "", snapshot.toString(), false, true)].idup);
    assert(!applied.error.length && projection.busy && projection.execution.tools[0].state == ToolState.queued);
    tool.state = ToolState.running; tool.started = true; tool.elapsedMs = 120; tool.output = "Reading";
    applied = projection.apply(view, [ActorChange(ActorChangeKind.toolProgress, 16, 2, tool.id, toolViewJson(tool).toString(), false, true)].idup);
    assert(applied.executionChanged && !applied.needsSnapshot && projection.execution.tools[0].started &&
        projection.execution.tools[0].elapsedMs == 120 && projection.execution.tools[0].output == "Reading");
    assert(execution.tools[0].state == ToolState.queued, "Projection shared a mutable execution view with its source");
    tool.id = "unknown";
    applied = projection.apply(view, [ActorChange(ActorChangeKind.toolProgress, 17, 2, tool.id, toolViewJson(tool).toString(), false, true)].idup);
    assert(applied.needsSnapshot && applied.error.length, "Unknown live progress silently invented a tool call");
    writeln("PASS immutable UI projection, separate reasoning/text, cleared fields, duplicate delivery, gap resync and owner isolation");
    return 0;
}
