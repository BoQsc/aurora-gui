module auroraopencode.orchestrator;

// experimental: orchestrator (multi-agent routing).
// Removable drop-in: delete this file and the three "experimental:
// orchestrator" markers in source/auroraopencode/tools.d and the feature is
// gone, with no other call site to update. Mirrors the websearch/computer-use
// pattern (see source/auroraopencode/websearch.d).
//
// Off by default. Opt in with AURORA_ORCHESTRATOR=1 (also on/true/yes/y/
// enabled/enable).

import auroraopencode.core : AgentSpec, ChatSession, OpenCodeToolDef;
import std.algorithm.searching : canFind;
import std.array : appender;
import std.json : JSONType, JSONValue, parseJSON;
import std.process : environment;
import std.string : strip, toLower;
import std.typecons : Tuple, tuple;

/// Only these values enable the routing tools, so an unset variable (the
/// common case) leaves the orchestrator off.
private enum enableValues = ["1", "on", "true", "yes", "y", "enabled", "enable"];

/// Whether the experimental orchestrator routing tools are active. Read on
/// every call so a relaunch with a different environment sees the change.
public bool experimentalOrchestratorEnabled()
{
    if (orchestratorEnabledBySetting) return true;
    const raw = strip(toLower(environment.get("AURORA_ORCHESTRATOR", "")));
    if (raw.length == 0) return false;
    return enableValues.canFind(raw);
}

/// Set by the host app from the persisted Settings checkbox. `__gshared` is
/// required: the app writes it on the UI thread while the tool builders read
/// it.
public __gshared bool orchestratorEnabledBySetting = false;

/// Apply the Settings choice. Called on load and whenever the checkbox
/// changes, so the next toolset build reflects the new value.
public void setOrchestratorSetting(bool value)
{
    orchestratorEnabledBySetting = value;
}

/// Routing-only tool definitions for the orchestrator participant. Returns an
/// empty array when disabled, so registration needs no conditional in the
/// caller (mirrors `experimentalWebSearchTools`).
///
/// These are control tools, not work tools: an orchestrator uses them to pick
/// who acts next, pause for the user, or end the dispatch. Ordinary
/// participants never receive them.
public OpenCodeToolDef[] experimentalOrchestratorTools()
{
    if (!experimentalOrchestratorEnabled()) return null;
    return [
        OpenCodeToolDef(
            "assign",
            "Orchestrator only. Route the next turn to another participant. " ~
            "That agent then works on the shared conversation with its own " ~
            "tools. Give the agent id and one short, self-contained task.",
            `{"type":"object","properties":{"agent_id":{"type":"string","description":"Id of the participant to run next"},"task":{"type":"string","description":"Short, self-contained task for that agent"}},"required":["agent_id","task"]}`
        ),
        OpenCodeToolDef(
            "ask_user",
            "Orchestrator only. Pause the dispatch and hand control back to the " ~
            "user with one specific question. Use only when a decision is " ~
            "required to continue.",
            `{"type":"object","properties":{"question":{"type":"string","description":"The single question to ask the user"}},"required":["question"]}`
        ),
        OpenCodeToolDef(
            "finish",
            "Orchestrator only. End the dispatch and return a concise summary " ~
            "of what the participants produced.",
            `{"type":"object","properties":{"summary":{"type":"string","description":"Concise summary of the completed work"}},"required":["summary"]}`
        ),
    ];
}

/// Execute one orchestrator routing call. Returns `(output, failed)`.
///
/// Pure control plumbing for now: the routing decision is emitted as the tool
/// result so it is visible and persisted in the transcript. Driving an actual
/// next turn needs the multi-agent substrate (per-message author + roster, see
/// docs/multi-agent-single-conversation.md, Phase 1) and is layered on later;
/// this stage makes the feature real, removable and observable.
public Tuple!(string, bool) experimentalOrchestratorExecute(string name,
    string args)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;

    string field(string key)
    {
        if (value.type != JSONType.object) return string.init;
        if (auto found = key in value.object)
            if (found.type == JSONType.string) return found.str;
        return string.init;
    }

    switch (name)
    {
        case "assign":
        {
            const agent = strip(field("agent_id"));
            const task = strip(field("task"));
            if (agent.length == 0 || task.length == 0)
                return tuple("Error: assign requires `agent_id` and `task`.",
                    true);
            orchestratorPendingSpeaker = agent;
            orchestratorPendingTask = task;
            return tuple("Assigned to " ~ agent ~ ": " ~ task, false);
        }
        case "ask_user":
        {
            const question = strip(field("question"));
            if (question.length == 0)
                return tuple("Error: ask_user requires `question`.", true);
            orchestratorPendingHalt = true;
            orchestratorPendingStatus = "blocked";
            return tuple("Waiting for the user: " ~ question, false);
        }
        case "finish":
        {
            const summary = strip(field("summary"));
            orchestratorPendingHalt = true;
            // Mark the dispatch done so the durable-task continuation does not
            // keep re-opening turns after the orchestrator has finished.
            orchestratorPendingStatus = "completed";
            if (summary.length == 0)
                return tuple("Dispatch finished.", false);
            return tuple("Dispatch complete: " ~ summary, false);
        }
        default:
            return tuple("Error: unknown orchestrator tool '" ~ name ~ "'.",
                true);
    }
}

/// Routing channel from the tool worker (which sets it) to the app (which
/// consumes it at the next turn boundary). `__gshared` because the tool runs on
/// a worker while the app reads it on the UI thread.
public __gshared string orchestratorPendingSpeaker = "";
public __gshared string orchestratorPendingTask = "";
public __gshared bool orchestratorPendingHalt = false;
// Terminal task status requested by a routing tool: "completed" (finish) or
// "blocked" (ask_user). Applied to the session so the durable-task
// continuation stops re-opening turns once the dispatch is over.
public __gshared string orchestratorPendingStatus = "";

/// Consume and clear the pending next-speaker (empty when none).
public string experimentalOrchestratorTakePendingSpeaker()
{
    const value = orchestratorPendingSpeaker;
    orchestratorPendingSpeaker = "";
    return value;
}

/// Consume and clear the pending assignment text (empty when none).
public string experimentalOrchestratorTakePendingTask()
{
    const value = orchestratorPendingTask;
    orchestratorPendingTask = "";
    return value;
}

/// Consume and clear the halt request (ask_user / finish).
public bool experimentalOrchestratorTakePendingHalt()
{
    const value = orchestratorPendingHalt;
    orchestratorPendingHalt = false;
    return value;
}

/// Consume and clear the terminal status requested by finish/ask_user.
public string experimentalOrchestratorTakePendingStatus()
{
    const value = orchestratorPendingStatus;
    orchestratorPendingStatus = "";
    return value;
}

/// True when `name` is one of the routing-only tools.
public bool experimentalOrchestratorIsRoutingTool(string name)
{
    return name == "assign" || name == "ask_user" || name == "finish";
}

/// The built-in roster used when the orchestrator is enabled. Kept in this
/// removable module: removing the file removes the roster too.
public AgentSpec[] experimentalOrchestratorRoster()
{
    return [
        AgentSpec("orchestrator", "Orchestrator",
            "You lead this conversation. Read the goal, then drive it: for " ~
            "implementation call `assign` with agent_id \"builder\"; for " ~
            "verification call `assign` with \"reviewer\"; call `ask_user` when " ~
            "a decision belongs to the user; call `finish` when the goal is " ~
            "met. Prefer delegating over narrating, and never just wait.",
            "", true),
        AgentSpec("builder", "Builder",
            "You are the Builder. Implement the requested work in the " ~
            "workspace using the available tools, then verify it.",
            "", false),
        AgentSpec("reviewer", "Reviewer",
            "You are the Reviewer. Inspect the work already in the " ~
            "conversation against the user's goal and report concrete problems, " ~
            "or state clearly that it is correct. Prefer read-only tools.",
            "", false),
        AgentSpec("researcher", "Researcher",
            "You are the Researcher. Gather the facts the task needs with " ~
            "read-only tools and report findings concisely.",
            "", false),
    ];
}

/// Install the built-in roster on a conversation the first time an
/// orchestrator-enabled turn runs. Idempotent.
public void experimentalOrchestratorEnsureRoster(ref ChatSession session)
{
    if (session.agents.length > 0) return;
    session.agents = experimentalOrchestratorRoster();
    if (session.activeAgentId.length == 0)
        session.activeAgentId = "orchestrator";
}

private const(AgentSpec)* findAgent(const ref ChatSession session, string id)
{
    foreach (ref agent; session.agents)
        if (agent.id == id) return &agent;
    return null;
}

/// Whether the given participant uses only the routing tools.
public bool experimentalOrchestratorIsRouter(const ref ChatSession session,
    string id)
{
    auto agent = findAgent(session, id);
    return agent is null ? false : agent.router;
}

/// The participant's model override, or empty to use the session's model.
public string experimentalOrchestratorAgentModel(const ref ChatSession session,
    string id)
{
    auto agent = findAgent(session, id);
    return agent is null ? "" : agent.model;
}

/// The participant's display name (falls back to the id).
public string experimentalOrchestratorAgentName(const ref ChatSession session,
    string id)
{
    auto agent = findAgent(session, id);
    return agent is null ? id : agent.name;
}

/// The system-prompt block that tells the active participant who it is and who
/// the others are.
public string experimentalOrchestratorIdentityBlock(
    const ref ChatSession session, string id)
{
    auto self = findAgent(session, id);
    const selfName = self is null ? id : self.name;
    auto names = appender!string();
    foreach (ref agent; session.agents)
    {
        if (names.data.length > 0) names.put(", ");
        names.put(agent.name);
        names.put(" (");
        names.put(agent.id);
        names.put(")");
    }
    auto text = appender!string();
    text.put("\n# Multi-agent conversation\n");
    text.put("You are \"");
    text.put(selfName);
    text.put("\" (id ");
    text.put(id);
    text.put("). Participants: ");
    text.put(names.data);
    text.put(".\nSpeak only as yourself; never write another participant's " ~
        "message or claim their work.\n");
    if (self !is null && self.router)
        text.put("You lead this multi-agent conversation. You may do small " ~
            "steps yourself, but for any real implementation you MUST call " ~
            "assign(builder, task); for verification call " ~
            "assign(reviewer, task). Prefer delegating over narrating. When " ~
            "the goal is met call finish, and when a decision belongs to the " ~
            "user call ask_user. Never just wait.\n");
    return text.data;
}

/// Keep only the tools the active participant should see. A router keeps every
/// tool (it can do work itself and delegate); other participants get the work
/// tools without the routing tools, so only the orchestrator routes.
public OpenCodeToolDef[] experimentalOrchestratorFilterTools(
    OpenCodeToolDef[] tools, bool router)
{
    if (router) return tools;
    OpenCodeToolDef[] kept;
    foreach (tool; tools)
        if (!experimentalOrchestratorIsRoutingTool(tool.name)) kept ~= tool;
    return kept;
}
