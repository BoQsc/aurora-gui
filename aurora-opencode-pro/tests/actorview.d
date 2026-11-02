module actorview;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.conversationencode : sessionMetaToJson;
import auroraopencode.conversationprojection;
import auroraopencode.conversationview : executionViewJson;
import std.json : JSONValue;

/// Fixture observation goes through the production projection, including
/// metadata patches and resync, rather than treating a delta as a full header.
final class ActorTestView
{
    ConversationActor actor;
    ChatSession model;
    ConversationProjection projection;
    JSONValue header;
    this(const ref ChatSession initial, ConversationActor actor)
    {
        this.actor = actor; model = snapshotChatSessions([cast(ChatSession) initial])[0];
        projection = new ConversationProjection(model); refresh();
    }
    immutable(ActorChange)[] take()
    {
        auto changes = actor.takeChanges();
        auto applied = projection.apply(model, changes);
        assert(!applied.error.length, applied.error);
        if (applied.requestSnapshot) actor.post(ActorCommand(ActorCommandKind.snapshot));
        if (changes.length) refresh();
        return changes;
    }
    private void refresh()
    {
        header = sessionMetaToJson(model);
        header["turnStatus"] = model.turnStatus; header["taskStatus"] = model.taskStatus;
        header["execution"] = executionViewJson(projection.execution);
    }
}
