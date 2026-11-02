module auroraopencode.conversationcoordination;

import auroraopencode.core;
import auroraopencode.conversationencode : sessionMetaToJson;
import auroraopencode.orchestrator : OrchestratorAssignment, experimentalOrchestratorAgentName;
import std.json : JSONValue, parseJSON;

public enum CoordinationKind { dispatch, report, cancel, failure }
/// Coordination has a bounded backend subscriber independent of UI delivery.
public struct CoordinationEffect
{
    CoordinationKind kind;
    string owner, round, payload;
    string behavior, connectionBase, connectionKey;
    bool recordTrace;
}
public alias CoordinationReceiver = bool delegate(CoordinationEffect);

public bool waitingForChildren(const ref ChatSession session)
{
    if (!session.orchestrationState.length) return false;
    try
    {
        auto state = parseJSON(session.orchestrationState);
        foreach (child; state["children"].array) if (!child["reported"].boolean) return true;
    }
    catch (Exception) {}
    return false;
}

public JSONValue dispatchState(const ref ChatSession parent, string round,
    const(OrchestratorAssignment)[] assignments, string[] childIds)
{
    assert(assignments.length == childIds.length);
    JSONValue state; state["round"] = round; state["children"] = JSONValue.emptyArray;
    foreach (i, assignment; assignments)
    {
        ChatSession child; child.id = childIds[i]; child.parentSessionId = parent.id;
        child.subagentId = assignment.agentId; child.parentDispatchId = round;
        child.title = experimentalOrchestratorAgentName(parent, assignment.agentId); child.titleManual = true;
        child.model = parent.model; child.thinking = parent.thinking; child.projectId = parent.projectId;
        child.instructions = parent.instructions; child.toolsMode = parent.toolsMode; child.updatedAt = parent.updatedAt;
        foreach (agent; parent.agents) if (agent.id == assignment.agentId)
        { child.agents ~= agent; if (agent.model.length) child.model = agent.model; }
        child.activeAgentId = assignment.agentId;
        JSONValue item; item["id"] = child.id; item["agent"] = assignment.agentId;
        item["task"] = assignment.task; item["reported"] = false; item["seed"] = sessionMetaToJson(child);
        state["children"].array ~= item;
    }
    return state;
}
