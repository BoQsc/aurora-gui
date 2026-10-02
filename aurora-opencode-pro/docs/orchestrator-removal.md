# Removing the experimental orchestrator / multi-agent feature

Short handoff. Every block below is tagged `// experimental: orchestrator`
(plus a few plain helper methods). Grep for the tag to find them all:

```
grep -rn "experimental: orchestrator" source shared
grep -rn "experimentalOrchestrator\|orchestratorClientFor\|Orchestrator" source
```

Removal is: delete one module, delete the tagged blocks, delete the plain
helpers listed here, remove the `core.d` data/settings additions, then rebuild.

## 1. Delete files
- `source/auroraopencode/orchestrator.d` (the whole feature; all logic lives here).
- `docs/multi-agent-single-conversation.md`, `docs/orchestrator-removal.md` (this file).

## 2. `source/auroraopencode/tools.d` (3 blocks)
- Import block: `import auroraopencode.orchestrator : ...` (tagged).
- Two lines `defs ~= experimentalOrchestratorTools(); // experimental: orchestrator`
  (in `builtinToolDefinitions` and `nativeOnlyToolDefinitions`).
- Dispatch block in `dispatchTool`: `case "assign": case "ask_user": case "finish": { ... }`
  (tagged, calls `experimentalOrchestratorExecute`).

## 3. `aurora-opencode-core/source/auroraopencode/core.d`
- `ChatMessage.authorId` field.
- `AgentSpec` struct (whole struct).
- `ChatSession` fields: `agents`, `activeAgentId`, `nextSpeakerId`, `agentHops`.
- `Settings.experimentalOrchestrator` field.
- `Settings` JSON: the `"experimentalOrchestrator"` branch in the loader and the
  `root["experimentalOrchestrator"]` line in the writer.

## 4. `source/auroraopencode/appui.d`
Tagged blocks (`// experimental: orchestrator`):
- Import block of `auroraopencode.orchestrator` (lines ~43-55).
- `ConversationRuntime.agentClients` field (per-agent clients).
- `orchestratorClientFor(...)` method.
- Load wiring: `setOrchestratorSetting(_settings.experimentalOrchestrator);`.
- `appendMessage`: the `authorId` stamping block.
- Transcript rebuild: the internal dispatch-note row block
  (`isDispatchNote(message)` → `MessageBubble` with toolName "handoff").
- Settings dialog: the checkbox block (`oc-orchestrator`).
- `continueOrCompleteTask`: the whole multi-agent routing block
  (the `if (experimentalOrchestratorEnabled() && session.agents.length > 0)`
  block with the else-if terminal-status branch).
- Tool-settle: the routing-consume block
  (`experimentalOrchestratorTakePending*`).
- `startChatRequest`: speaker resolution block; identity-block append; tools
  filter; `contextAnchor` + `orchestratorRouter` request branch; per-agent
  `_client` swap; model override; `speakerLabel` status lines.
- `buildRequestMessages`: the `orchestratorSummaryView` parameter and its filter
  block.
- `sessionMetaToJson` / `parseSessionMetaJson`: the `agents` / `activeAgentId`
  blocks (tagged).
- `messageToJson` / `parseMessagesJson`: the `authorId` lines (tagged in the
  message parser; the two parse copies are identical).

Plain helper methods/fields to delete (no tag, searchable by name):
- `_speakerToolRoundsBase` field + its two uses (set in tool-settle, read in
  `continueOrCompleteTask`) and the `= -1` reset in `startChatRequest`.
- `authorHeaderWidget`, `showAuthorHeader`, `agentAccentColor`, `authorName`,
  `isRouterAgent`, `isDispatchNote`, `dispatchNoteText`,
  `multiAgentContextAnchor`.
- The two `if (showAuthorHeader(message)) _messageColumn.add(authorHeaderWidget(message));`
  inserts in the transcript rebuild.

Note: `saveLoadedRuntime`'s `rt.client = _client;` is the ORIGINAL behavior
(not part of the feature) — keep it.

## 5. Persisted data (no migration needed)
The feature only ADDS JSON keys, so after removal the loader ignores them:
- session: `authorId` (per message), `agents`, `activeAgentId`, `nextSpeakerId`,
  `agentHops`.
- settings: `experimentalOrchestrator`.
Optionally strip these from saved files with a one-off script; not required.

## 6. Verify
- `grep -rn "experimental: orchestrator" source shared` → no hits.
- `grep -rn "experimentalOrchestrator\|orchestratorClientFor" source` → no hits.
- `dub build --config=newbuild` → exit 0.
- Rebuild/relaunch; confirm normal single-agent chat with no author headers.
