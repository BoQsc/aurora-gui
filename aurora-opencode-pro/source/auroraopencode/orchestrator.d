module auroraopencode.orchestrator;

// experimental: orchestrator (multi-agent routing).
// Tool execution produces a routing value. The owning conversation validates
// and applies it after correlated settlement; workers never publish routing
// decisions through shared mutable state.
//
// Off by default. Opt in with AURORA_ORCHESTRATOR=1 (also on/true/yes/y/
// enabled/enable).

import auroraopencode.core : AgentSpec, ChatSession, OpenCodeToolDef;
import auroraopencode.inputcontract : requestInputSchema;
import auroraopencode.taskcontinuation : taskBlockerError, taskInputError, unfinishedTask;
import std.algorithm.searching : canFind;
import std.array : appender;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.process : environment;
import std.string : strip, toLower;
import std.typecons : Tuple, tuple;

/// Only these values enable the routing tools, so an unset variable (the
/// common case) leaves the orchestrator off.
private enum enableValues = ["1", "on", "true", "yes", "y", "enabled", "enable"];

/// experimental: orchestrator - one participant to dispatch and the
/// self-contained task it must complete. A single `assign` may carry several,
/// which is how the orchestrator fans work out to multiple agents in one
/// dispatch instead of routing one hop at a time.
public struct OrchestratorAssignment
{
    string agentId;
    string task;
}

public struct OrchestratorDirective
{
    string output;
    bool failed;
    OrchestratorAssignment[] assignments;
    bool halt;
    string status, question;
}

/// Owned by one conversation's current tool batch, never by a tool worker.
public struct OrchestrationBatch
{
    OrchestratorAssignment[] assignments;
    bool halt;
    string status, question;

    void accept(OrchestratorDirective directive)
    {
        if (directive.failed) return;
        if (directive.halt)
        {
            assignments = null; halt = true;
            status = directive.status; question = directive.question;
            return;
        }
        if (halt) return;
        foreach (assignment; directive.assignments)
        {
            bool found;
            foreach (ref existing; assignments)
                if (existing.agentId == assignment.agentId)
                {
                    existing.task ~= "\n\nAdditional assignment:\n" ~ assignment.task;
                    found = true; break;
                }
            if (!found) assignments ~= assignment;
        }
    }

    OrchestrationBatch take()
    { auto result = this; this = OrchestrationBatch.init; return result; }
}

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
            "Orchestrator only. Dispatch one or more participants together. " ~
            "Each assigned agent then works on the shared conversation with " ~
            "its own tools as part of the same dispatch, so you assign the " ~
            "whole batch instead of one hop at a time. Prefer the " ~
            "`assignments` list (one {agent_id, task} per participant); " ~
            "`agent_id` + `task` is the single-agent shorthand.",
            `{"type":"object","properties":{"assignments":{"type":"array","description":"Participants to dispatch together in one parallel batch","items":{"type":"object","properties":{"agent_id":{"type":"string","description":"Id of the participant to dispatch"},"task":{"type":"string","description":"Short, self-contained task for that agent"}},"required":["agent_id","task"]}},"agent_id":{"type":"string","description":"Id of a single participant to dispatch"},"task":{"type":"string","description":"Short, self-contained task for that agent"}}}`
        ),
        OpenCodeToolDef(
            "ask_user",
            "Orchestrator only. Pause the dispatch and hand control back to the " ~
            "user with one specific question. Use only when a decision is " ~
            "required to continue. Supply the same evidence and blocked-outcome fields as request_input; complete independent work first.",
            requestInputSchema
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
/// The routing decision is emitted as the tool result so it is visible and
/// persisted in the transcript. `assign` records a whole batch of participants
/// (see `OrchestratorAssignment`); the app dispatches that batch as one
/// fan-out, so several agents are assigned together instead of one hop at a
/// time. This module stays free of UI: the app owns presentation and dispatch.
public Tuple!(string, bool) experimentalOrchestratorExecute(string name,
    string args)
{
    auto directive = parseOrchestratorDirective(name, args);
    return tuple(directive.output, directive.failed);
}

/// A recorded tool call fully determines its routing value. Executing it has
/// no process-global side effect; only its correlated successful settlement
/// may apply the directive to the owning conversation.
public OrchestratorDirective parseOrchestratorDirective(string name, string args)
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

    string objField(JSONValue obj, string key)
    {
        if (obj.type != JSONType.object) return string.init;
        if (auto found = key in obj.object)
            if (found.type == JSONType.string) return found.str;
        return string.init;
    }

    switch (name)
    {
        case "assign":
        {
            OrchestratorAssignment[] requested;
            // Preferred form: an explicit list dispatched as one batch.
            if (value.type == JSONType.object)
                if (auto list = "assignments" in value.object)
                {
                    if (list.type != JSONType.array || !list.array.length || list.array.length > 16)
                        return OrchestratorDirective("Error: assignments must contain between 1 and 16 participants.", true);
                        foreach (ref entry; list.array)
                        {
                            const agent = strip(objField(entry, "agent_id"));
                            const task = strip(objField(entry, "task"));
                            if (!agent.length || !task.length)
                                return OrchestratorDirective("Error: every assignment requires agent_id and task. No partial batch was dispatched.", true);
                            requested ~= OrchestratorAssignment(agent, task);
                        }
                }
            // Single-agent shorthand (also the backward-compatible form).
            if (requested.length == 0)
            {
                const agent = strip(field("agent_id"));
                const task = strip(field("task"));
                if (agent.length > 0 && task.length > 0)
                    requested ~= OrchestratorAssignment(agent, task);
            }
            if (requested.length == 0)
                return OrchestratorDirective("Error: assign requires `agent_id` and `task`, " ~
                    "or a non-empty `assignments` list of {agent_id, task}.",
                    true);
            if (requested.length > 16)
                return OrchestratorDirective("Error: assign accepts at most 16 participants per call.", true);
            // Never silently discard a second task for the same participant.
            OrchestratorAssignment[] batch;
            foreach (assignment; requested)
            {
                bool seen;
                foreach (existing; batch)
                    if (existing.agentId == assignment.agentId)
                    {
                        seen = true;
                        break;
                    }
                if (seen) return OrchestratorDirective("Error: assign contains a duplicate participant: " ~ assignment.agentId, true);
                batch ~= assignment;
            }
            auto summary = appender!string();
            summary.put(batch.length == 1 ? "Assigned " : "Assigned in parallel ");
            summary.put(to!string(batch.length));
            summary.put(batch.length == 1 ? " agent: " : " agents: ");
            foreach (i, assignment; batch)
            {
                if (i > 0) summary.put("; ");
                summary.put(assignment.agentId);
                summary.put(" — ");
                summary.put(assignment.task);
            }
            return OrchestratorDirective(summary.data, false, batch);
        }
        case "ask_user":
        {
            const question = strip(field("question"));
            const error = taskBlockerError(args);
            if (error.length) return OrchestratorDirective(error, true);
            return OrchestratorDirective("Waiting for the user: " ~ question, false,
                null, true, "waiting_input", question);
        }
        case "finish":
        {
            const summary = strip(field("summary"));
            return OrchestratorDirective(summary.length ? "Dispatch complete: " ~ summary : "Dispatch finished.",
                false, null, true, "completed");
        }
        default:
            return OrchestratorDirective("Error: unknown orchestrator tool '" ~ name ~ "'.",
                true);
    }
}

public string orchestratorDirectiveError(const ref ChatSession session,
    string name, string arguments, const ref OrchestratorDirective directive,
    bool enabled, bool halted)
{
    if (directive.failed) return directive.output;
    if (!enabled || !experimentalOrchestratorIsRouter(session, session.activeAgentId))
        return "Error: routing tools require this conversation's active orchestrator.";
    if (halted) return "Error: this batch already ended its dispatch. No further routing action was applied.";
    foreach (assignment; directive.assignments)
    {
        bool known;
        foreach (agent; session.agents)
            if (agent.id == assignment.agentId && !agent.router) { known = true; break; }
        if (!known) return "Error: unknown worker participant: " ~ assignment.agentId;
    }
    if (name == "ask_user") return taskInputError(session, arguments);
    if (name == "finish" && unfinishedTask(session, false))
        return "Error: unfinished outcomes or verification remain. Continue them before ending the dispatch.";
    return "";
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
            "You lead this conversation in rounds. Read the goal, then drive " ~
            "it one round at a time: in each round call `assign` with one or " ~
            "more {agent_id, task} entries (\"builder\" to implement, " ~
            "\"reviewer\" to verify, \"researcher\" to investigate). Every " ~
            "assigned subagent runs at the same time in its own chat and " ~
            "reports back; when their results arrive you lead the next round. " ~
            "Call `ask_user` when a decision belongs to the user; call " ~
            "`finish` when the goal is met. Prefer delegating over narrating, " ~
            "and never just wait.",
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

/// The worker participants (everyone except the router), in roster order. The
/// plan UI lists these as named subagents, each with its own nested chat.
public AgentSpec[] experimentalOrchestratorSubagents(const ref ChatSession session)
{
    AgentSpec[] workers;
    foreach (agent; session.agents)
        if (!agent.router) workers ~= agent;
    return workers;
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
        text.put("You lead this multi-agent conversation in rounds. In each " ~
            "round call assign with one or more {agent_id, task} entries; " ~
            "every assigned subagent runs at the same time in its own chat " ~
            "and reports back, then you lead the next round. Prefer " ~
            "delegating over narrating. When the goal is met call finish, and " ~
            "when a decision belongs to the user call ask_user. Never just " ~
            "wait.\n");
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
