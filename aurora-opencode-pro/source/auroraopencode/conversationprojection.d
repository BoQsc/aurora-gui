module auroraopencode.conversationprojection;

import auroraopencode.core : ChatSession, ChatMessage;
import auroraopencode.conversationcodec : decodeSessionMetadata, decodeMessages;
import auroraopencode.conversationactor : ActorChange, ActorChangeKind;
import auroraopencode.conversationview;
import std.json : JSONValue, JSONType, parseJSON;

public struct ConversationChanges
{
    string[] messages, notices;
    bool structureChanged, metadataChanged, executionChanged, needsSnapshot;
    string error;
}

/// UI-owned projection state. Applying a change never reads a client, journal,
/// attachment blob or filesystem, and never changes an execution owner's data.
/// The caller retains its own ChatSession, so sidebar insertion cannot leave a
/// dangling pointer into a relocated session array.
public final class ConversationProjection
{
    private string threadId;
    private ulong appliedRevision;
    private size_t[string] positions;
    private size_t count;
    private bool resync;
    public bool busy;
    public ulong requestId;
    public ConversationExecutionView execution;

    this(const ref ChatSession initial)
    { threadId = initial.id; resync = !index(initial); }

    ulong revision() const { return appliedRevision; }
    int indexForId(string id) const
    { if (auto position = id in positions) return cast(int) *position; return -1; }

    private bool index(const ref ChatSession session)
    {
        positions = null; count = session.messages.length;
        foreach (i, message; session.messages)
        {
            if (!message.id.length || message.id in positions) return false;
            positions[message.id] = i;
        }
        return true;
    }

    ConversationChanges apply(ref ChatSession view, immutable(ActorChange)[] changes)
    {
        ConversationChanges result;
        if (view.id != threadId)
        { result.error = "Conversation projection owner does not match its UI session"; return result; }
        if (view.messages.length != count && !index(view)) resync = true;
        foreach (change; changes)
        {
            if (change.revision <= appliedRevision) continue;
            if (change.kind == ActorChangeKind.resync)
            { resync = true; continue; }
            if (change.kind == ActorChangeKind.fault)
            {
                busy = false; view.turnStatus = "failed"; view.taskStatus = "blocked";
                execution.phase = "failed"; execution.tools = null;
                result.executionChanged = true;
                resync = false;
                result.error = change.text; result.metadataChanged = true;
                appliedRevision = change.revision; continue;
            }
            if (change.kind != ActorChangeKind.snapshot &&
                (resync || change.revision != appliedRevision + 1))
            { resync = true; continue; }
            try
            {
                switch (change.kind)
                {
                    case ActorChangeKind.snapshot:
                    case ActorChangeKind.metadata:
                    {
                        const value = parseJSON(change.text);
                        if (value.type != JSONType.object || !("id" in value.object) || value["id"].str != threadId)
                            throw new Exception("Worker metadata belongs to another conversation");
                        ChatSession header;
                        decodeSessionMetadata(value, header);
                        const executionValue = "execution" in value.object;
                        auto nextExecution = executionValue is null ? ConversationExecutionView.init : decodeExecutionView(*executionValue);
                        if (change.kind == ActorChangeKind.snapshot)
                        {
                            if (!("messages" in value.object) || value["messages"].type != JSONType.array)
                                throw new Exception("Worker snapshot has no message graph");
                            decodeMessages(value["messages"], header);
                            auto previous = positions;
                            if (!index(header))
                            { positions = previous; count = view.messages.length; throw new Exception("Worker snapshot contains ambiguous message IDs"); }
                            if (header.activeLeafId.length && !(header.activeLeafId in positions))
                            { positions = previous; count = view.messages.length; throw new Exception("Worker snapshot has an unavailable active branch"); }
                            view = header; resync = false; result.structureChanged = true;
                        }
                        else
                        {
                            if (header.activeLeafId.length && !(header.activeLeafId in positions))
                                throw new Exception("Worker metadata requires an unavailable active branch");
                            // Omitted fields in this complete header mean
                            // cleared fields, rather than a metadata patch.
                            header.messages = view.messages; view = header;
                        }
                        result.metadataChanged = true;
                        execution = nextExecution; result.executionChanged = true;
                        break;
                    }
                    case ActorChangeKind.added:
                    case ActorChangeKind.updated:
                    {
                        ChatSession decoded;
                        decodeMessages(JSONValue([parseJSON(change.text)]), decoded);
                        if (decoded.messages.length != 1 || decoded.messages[0].id != change.itemId)
                            throw new Exception("Worker item identity does not match its payload");
                        auto message = decoded.messages[0];
                        if (auto position = change.itemId in positions)
                        {
                            if (view.messages[*position].role != message.role ||
                                view.messages[*position].parentId != message.parentId)
                                throw new Exception("Worker changed the identity of an existing message");
                            view.messages[*position] = message;
                        }
                        else
                        {
                            if (change.kind != ActorChangeKind.added ||
                                (message.parentId.length && !(message.parentId in positions)))
                                throw new Exception("Worker item requires an unavailable graph parent");
                            positions[message.id] = view.messages.length;
                            view.messages ~= message; count = view.messages.length;
                            result.structureChanged = true;
                        }
                        result.messages ~= message.id;
                        if (change.kind == ActorChangeKind.added) view.activeLeafId = message.id;
                        break;
                    }
                    case ActorChangeKind.delta:
                    {
                        auto position = change.itemId in positions;
                        if (position is null || view.messages[*position].role != "assistant")
                            throw new Exception("Worker text requires an unavailable assistant message");
                        if (change.reasoning) view.messages[*position].reasoning ~= change.text;
                        else view.messages[*position].content ~= change.text;
                        result.messages ~= change.itemId;
                        break;
                    }
                    case ActorChangeKind.notice: result.notices ~= change.text; break;
                    case ActorChangeKind.toolProgress:
                    {
                        auto value = parseJSON(change.text);
                        auto tool = decodeToolView(value);
                        if (tool.id != change.itemId) throw new Exception("Live tool identity does not match its payload");
                        bool found;
                        foreach (ref row; execution.tools)
                            if (row.id == tool.id)
                            { row = tool; found = true; break; }
                        if (!found) throw new Exception("Live tool progress requires an unavailable call");
                        result.executionChanged = true; break;
                    }
                    case ActorChangeKind.usage: break;
                    default: throw new Exception("Unsupported conversation change");
                }
                appliedRevision = change.revision; requestId = change.requestId; busy = change.busy;
            }
            catch (Exception error)
            { resync = true; result.error = error.msg; }
        }
        result.needsSnapshot = resync;
        return result;
    }
}
