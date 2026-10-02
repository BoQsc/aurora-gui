# Multiple agents in one conversation — design idea

Status: proposal (not implemented). Scope: let two or more named agents
collaborate inside a **single** `ChatSession`/transcript, instead of the current
one-agent-per-conversation model.

## Why it is not possible today

The conversation is a single assistant channel:

- `ChatSession` (`aurora-opencode-core/source/auroraopencode/core.d:723`) holds
  one `model`, one transcript (`messages`), one durable plan. There is no roster.
- `ChatMessage` (`core.d:609`) has `role` (`user|assistant|tool`), graph ids
  (`id`/`parentId`), but **no author**, so two assistants are indistinguishable.
- `OpenCodeRoot.startChatRequest` (`source/auroraopencode/appui.d:17004`) builds
  exactly one system message (`buildSystemPrompt`, `systemprompt.d:129`), one
  transcript (`buildRequestMessages`, `appui.d:16757`) and one tool set
  (`nativeOnlyToolDefinitions`, `tools.d:400`), then sends with `session.model`.
- The wire body (`chatMessageToJson`, `opencode_client.d:1576`) emits only
  `role/content/reasoning_content/tool_call_id/tool_calls` — no per-message
  author/name, so the provider sees one voice.
- The only existing "second agent" is the nested computer-use loop
  (`runSubAgent`, `computeruse.d:3722`). It is deliberately **out of transcript**
  and one-shot, so it cannot share the conversation.

Good news: the message graph already supports ids, parents and branching
(`activeMessagePath`, `core.d:880`), and per-conversation execution state is
already isolated in `ConversationRuntime` (`appui.d:8740`). Both are the right
foundation for attribution and turn routing.

## Core idea: a conversation "roster" of agents

Promote the conversation from *one agent* to *a roster of agents sharing one
transcript*. An agent is a persona with its own identity, prompt, model and tool
subset; every assistant/tool message records which agent produced it; the
question "who speaks next" becomes an explicit, per-turn decision.

```
struct AgentSpec {
    string id;        // stable, e.g. "a-main"
    string name;      // "Designer", "Reviewer", "Aurora"
    string color;     // bubble/avatar accent
    string persona;   // extra system-prompt section for this agent
    string model;     // optional override; empty -> session.model
    string[] tools;   // optional allow-list; empty -> shared set
    string speakBy = "manual"; // manual | auto | mention
}
```

Session additions: `AgentSpec[] agents`, `string activeAgentId`.
Message addition: `string authorId` (empty = the default single agent, so old
transcripts stay valid).

## Key design decisions

### 1. Attribution is data, not prose
Add `authorId` to `ChatMessage` and `agents`/`activeAgentId` to `ChatSession`;
extend `sessionToJson` (`appui.d:21784`) and the loader. An empty roster is
upgraded to one default agent, so nothing changes for existing conversations.

### 2. The wire needs an author tag
OpenAI-compatible requests accept an optional `name` on messages. Add
`string author` to `ChatRequestMessage` and emit `json["name"] = author` in
`chatMessageToJson`. Also prepend a compact roster block to the system prompt:

```
# Conversation participants
You are "<you>". Others: <list>. Speak only as "<you>".
If another agent should act, call handoff(to, note); do not answer for them.
```

Ship a content-prefix fallback (`「Name」 `) behind a setting for providers that
reject `name`.

### 3. One request-shaping edit point
`startChatRequest` already centralizes everything, so multi-agent adds almost no
new control flow: resolve the speaking agent, then
- system prompt = `buildSystemPrompt(...) ~ agent persona ~ roster block`;
- `model` = `agent.model` if set, else `session.model`;
- tools = filter to `agent.tools` when non-empty.

### 4. Routing via reuse of the tool loop (auto handoff)
The tool-continuation loop already exists (`pendingToolCalls`, `toolRounds` in
`ConversationRuntime`; settle path at `appui.d:17004`+). Add one native tool,
`handoff(to, note)`, whose execution stores `session.pendingSpeakerId = to`.
When the current tool round settles, the existing "start the continuation
request" step resolves the speaker as `pendingSpeakerId` instead of the agent
that just spoke. That yields multi-agent turn-taking with **no new streaming
machinery** and one provider request per step.

### 5. Keep one active request per conversation (phasing)
`ConversationRuntime` assumes a single in-flight client/request. Phase 1–2 stay
sequential (agents take turns). True parallel "squad" reviews come later by
giving each concurrent agent its own client/request handle while writing into
the same transcript (see Phase 3).

### 6. Rendering
`buildMessageBubble` (`appui.d:13046`) reads `message.authorId` to draw a name
chip/color and pick the streaming bubble's speaker; the composer gets an agent
picker next to the model button; the session sidebar can list participants.

## Phased plan

**Phase 1 — attribution + manual multi-agent (backward compatible)**
1. `core.d`: add `AgentSpec`, `ChatMessage.authorId`, `ChatSession.agents`,
   `activeAgentId`; default roster on load.
2. `systemprompt.d`: add an agent-persona + roster section.
3. `appui.d`: agent picker in composer; `startChatRequest` resolves the speaker
   and shapes prompt/model/tools; `sessionToJson`/loader persistence.
4. `appui.d`: render author on bubbles; stamp `authorId` on every appended
   assistant/tool message (`appendMessage`, `appui.d:11825`).

**Phase 2 — automatic handoff**
5. `tools.d`: register `handoff(to, note)` in `nativeOnlyToolDefinitions`.
6. `appui.d`: on tool settle, honor `pendingSpeakerId`; teach the roster
   contract in the prompt.
7. Add a "review the other agent's reply" mention/reply policy.

**Phase 3 — orchestrated / parallel squad**
8. A lead/dispatcher agent and optional parallel reviewers, each with its own
   `OpenCodeClient`/request id writing into the shared transcript; a moderator
   turn merges the results.

## Edge cases / risks to handle

- **Provider variance** for `name` → content-prefix fallback.
- **Regenerate/branch** (`appui.d:17236`, `ensureMessageGraph`, `core.d:825`)
  must carry `authorId` so a re-run keeps its author.
- **Tool results** inherit their calling agent's `authorId`.
- **Prefix cache / routing** is unaffected: `sessionRoutingKey` (`core.d:807`)
  keys on the first message id, which does not change.
- **Compaction & title** requests keep using the speaking agent's model.
- **Token cost**: the roster block is extra system text → gate behind a setting.

## Smallest first step

Phase 1, steps 1–3 alone already deliver "two named agents you can switch
between in one conversation", reusing the existing turn machinery with no new
streaming code.

## Long-term recommendation

Most correct over the long run, in order of importance:

1. **The event-log transcript with `authorId` + a roster (Phase 1 data model) is
   non-negotiable.** Everything else is replaceable; this is the durable core.
   Make the conversation an append-only, authored log and let each request be a
   *projection* of it, rather than teaching the app that "the" assistant is one
   voice.
2. **Explicit, inspectable handoff control events beat hidden orchestration
   (Phase 2).** Sequential turns routed by a real `handoff`/assign event are
   debuggable, replayable and cache-friendly. This, not parallel streaming, is
   the long-term-correct turn model.
3. **Prefer the structured `name` field; treat the content-prefix as a fallback
   only.** Keep provider-format adaptation isolated inside the client
   serialization layer (`opencode_client.d`), never in the app/turn logic.
4. **Do *not* make a shared-transcript parallel squad the primary model
   (Phase 3).** Two agents streaming into one transcript at once breaks
   causality, ordering, compaction and the branch graph; keep it as an optional
   reviewer pattern layered on top of sequential handoff.

In one line: **Phase 1's data model + Phase 2's explicit handoff, sequential,
is the correct target; parallel squad is a feature, not the architecture.**

## Why not an orchestrator-first design?

An orchestrator is a *policy on top of the substrate*, not a competing
architecture — Phase 3's lead/dispatcher agent already is one. Two senses must
be separated:

- **Explicit orchestrator** — a named agent that emits visible, persisted
  assign/handoff control events. This is good, and it is exactly what Phase 2/3
  build toward.
- **Hidden orchestration** — a central layer that silently routes, rewrites
  history and merges parallel replies. This is what the design avoids.

Reasons to sequence it *after* the substrate:

1. **An orchestrator still needs the primitives.** It cannot attribute speakers,
   project per-agent views or replay after a crash until `authorId` + the roster
   + an authored log exist. It is downstream of Phase 1, not a replacement.
2. **Replay / crash recovery.** Aurora persists sessions and replays them; only
   deterministic, inspectable control events survive that faithfully. Opaque
   orchestration state is lost or diverges on restart.
3. **Cost / latency.** A separate orchestrator spends an extra model round per
   step just to decide routing. Two agents can route directly via explicit
   `handoff`; add a dispatcher only when N agents/branching needs arbitration.
4. **Failure modes are visible.** An orchestrator can ping-pong (A↔B) or become a
   single point of failure. Explicit handoff makes loops bounded and inspectable
   (the loop already has repeat guards, e.g. `lastToolRepeatCount`).
5. **One in-flight request invariant.** `ConversationRuntime` assumes a single
   active request/stream per conversation; an orchestrator that fans out to
   parallel sub-agents breaks it.
6. **The wire has one assistant channel.** No orchestration scheme removes the
   need for the `name`/roster encoding; it is format-solving, not
   architecture-solving.

So: **build the substrate first; the orchestrator is a policy you add on top of
explicit handoff when scale justifies it — explicit and inspectable, never
hidden.**

## Experimental orchestrator (easy to remove)

An opt-in, self-contained feature modeled on the existing
`experimentalComputerUseEnabled()` switch (`computeruse.d:57`): a module-level
enable function + a `__gshared` setting flag + a handful of guarded call sites.
Delete `orchestrator.d` and the guards and the app is byte-for-byte the old app.

### Enable / lifecycle (mirrors computer use)
- `source/auroraopencode/orchestrator.d`:
  `public bool experimentalOrchestratorEnabled()` reads `AURORA_ORCHESTRATOR`
  env (`1/on/true/...`) OR `orchestratorEnabledBySetting`, plus
  `public void setOrchestratorSetting(bool)`.
- Settings checkbox "Experimental: orchestrator (multi-agent)" (same shape as
  the nested-plans checkbox at `appui.d:18949`).
- Off (default) = no module reached, no extra tokens, no UI change.

### What it does
1. You define a small roster (2–4 agents: name + role prompt + optional model).
2. One participant is the **orchestrator**: it has *routing-only* tools and never
   runs file/computer tools itself.
3. You send one prompt. The orchestrator emits a visible plan of assignments as
   normal transcript rows: "Researcher → gather X", "Builder → implement Y",
   "Reviewer → check Z".
4. Each assignment runs as an ordinary turn by that agent on the shared
   transcript — its own tools/edit land and show as usual.
5. Control returns to the orchestrator after each hop; it either assigns the
   next, retries with feedback, `ask_user`s, or `finish`es with a summary.
6. Fully attributed and steerable: Stop cancels the whole dispatch; you can take
   over at any hop.

### Routing tools (only the orchestrator gets these)
- `assign(agent_id, task)` — route the next turn (Phase 2 `handoff` + a note).
- `ask_user(question)` — pause and return to you.
- `finish(summary)` — end the dispatch.
Agents other than the orchestrator do **not** get these, so routing stays a
single, visible decision each step.

### Guardrails
- **Sequential only** — one in-flight request per conversation (matches
  `ConversationRuntime`); no fan-out.
- **Hop budget** — max N hops; on exhaustion the orchestrator must `finish`, so
  no A↔B ping-pong (reuse the loop's repeat guards, e.g. `lastToolRepeatCount`).
- **No hidden history rewrites** — every hop is a persisted, inspectable event.

### Why it is easy to remove
- All logic lives in one module; the only hooks are guarded and additive:
  1. speaker/model/tool/prompt resolution in `startChatRequest`
     (`appui.d:17004`);
  2. three extra `case`s in the tool dispatch (`tools.d:4876`);
  3. one Settings checkbox + persisted bool.
- Extra persisted fields (`authorId`, `agents`) are ignored by the loader if the
  module is gone — no migration, no cleanup.
- Removal steps fit in a footnote: delete `orchestrator.d`, drop the flag + the
  three guarded call sites.

### Cheap variant (zero extra model rounds)
A deterministic router — no orchestrator model at all: "after Builder, ask
Reviewer; after Reviewer, ask Builder or finish", round-robin or rule-based.
Even easier to remove and free, but less adaptive. Offer both behind the same
flag (`orchestratorMode = model | rules`).

## Making features pluggable (so features like this drop in and out)

Yes — and the codebase already proves the pattern: the system-prompt module
registry (`systemprompt.d:84-129`, `registerSystemPromptModule` /
`setSystemPromptModules` / `textModule`) is a working plugin seam, and
`experimentalComputerUseEnabled()` (`computeruse.d:57`) is a working enable
gate. Generalize those two ideas; do **not** build a heavy plugin framework.

### Principle: a few narrow seams, not a framework
Aurora is one large `appui.d`; the win comes from pinning *the chokepoints that
already exist* and letting features attach to them. Add an extension only where
the code already funnels through one function. Candidate seams:

1. **Prompt** — the system-prompt module list (`systemprompt.d`), reused as-is.
2. **Tools** — `nativeOnlyToolDefinitions()`/`builtinToolDefinitions()`
   (`tools.d:348,400`) already return arrays; let features append definitions.
3. **Tool execution** — the dispatch `switch` (`tools.d:4876`); let features
   register a `handler(name, args)` before the built-in cases.
4. **Request shaping** — `startChatRequest` (`appui.d:17004`); let features
   adjust the resolved speaker/model/tool subset.
5. **Turn lifecycle** — after a turn settles; let features observe (e.g. routing).
6. **Render** — `buildMessageBubble` (`appui.d:13046`); let features decorate a
   row (author chip, activity text) without new widget types.

### A tiny registry (single file)
`shared/features.d`, ~60 lines:

```
struct Feature {
    string name;
    bool delegate() enabled;            // env + setting gate
    OpenCodeToolDef[] delegate() tools; // optional
    string delegate(string event, JSONValue args) run; // optional
}
void registerFeature(Feature f);
Feature[] activeFeatures();             // skips disabled
```

Call sites iterate `activeFeatures()` behind the existing guards. A feature is
then **one file + one `registerFeature` line**; removal is deleting the file and
that line, and a disabled feature costs nothing. Keep the env + `__gshared`
setting gate so a feature is off by default (the proven contract).

### Guardrails against over-abstraction
- Only promote a seam once **two** features need it — do not abstract speculatively.
- Keep hooks broad-event and low-count (`tools`, `prompt`, `beforeRequest`,
  `afterTurn`, `render`), not a per-widget callback zoo.
- Never let a feature own shared state; it reads/writes only through the seam's
  arguments.
- Deterministic order: features run in registration order so replay is stable.

### Suggested order
1. Extract the system-prompt registry usage into the registry (already 90% there).
2. Add the `tools` + tool-execution seams (smallest, highest reuse).
3. Add `beforeRequest` / `afterTurn`.
4. Port one real feature (orchestrator, or computer use) onto the registry as
   proof; then the rest are mechanical.
