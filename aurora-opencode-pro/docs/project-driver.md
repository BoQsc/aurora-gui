# Per-project project driver (special conversation)

Status: implemented as an EXPERIMENTAL opt-in feature. The master switch is in
Settings > Options ("Experimental: project manager"), off by default; the
per-project switches appear in the "Project manager" Settings section and on the
project rail's right-click menu when it is on.

An optional, per-project assistant that reads the recent activity of that
project's conversations and starts a fresh conversation to push the project
forward. Off by default; enabled per project.

## Shape (decided: one project manager per project)

Each project may have **one designated "project manager" conversation** - the
special conversation. It is an ordinary `ChatSession` in the project, marked as
the manager, badged/pinned in the sidebar, and reused across activations: its own
message history is the project's management log, so there is a single place to
see the project's direction and what has been done.

On each activation the manager reads a digest of the project's recent
conversations and then moves the project forward by opening a new conversation
for the next step (or by doing the step in-thread - see open decision 7).

Set aside: a driver that spawns a fresh review chat every time and keeps no
persistent thread. Rejected because it leaves no single place that holds a
project's direction and history.

## Existing primitives this builds on

| Need | Where it already exists |
|---|---|
| Projects | `Project {id,name,path}`; `saveProjects` / `PreferenceWriter!ProjectState` writing `projects.json` (`source/auroraopencode/../core.d`, `preferencewriter.d`) |
| Per-project chats | `ChatSession.projectId`; the sidebar already filters by active project (`updateSessionList`) |
| Start a turn autonomously | `fireEmergencyChat()` in `appui.d`: `newChat(); _input.setText(prompt); sendMessage();` |
| Create a chat in a specific project without disturbing the active one | `startConversationInProject(name, workspace)` (`appui.d`) |
| Periodic UI-thread check | `onTick` runs `drainEmergency()` / `runOverseer()`; add `drainProjectDrivers()` beside them |
| Idle/busy tracking, cooldown, single-flight | `_overseerBusySince`, `emergencyRepeatCooldownSeconds`, `_emergencyStarting` |
| Compress assistant prose | `turnOpeningSentence()` (`turnsummary.d`) |

## Triggers

1. **Manual** — "Move project forward" in the project context menu / header. The
   safe first cut; always available.
2. **Idle** — after N minutes with no turn activity in the project (off by
   default).
3. **Interval** — every N minutes while the app is open (off by default).
4. **On turn completion** — optionally, when a turn in the project ends.

Guard rails: single-flight per project, a cooldown between fires, skip while any
conversation in the project is busy or while `_startupLoadPending`, respect usage
limits. Emergency/overseer take precedence over the driver.

## What it examines

Bounded and cheap, from data the app already holds:

- The project's conversations sorted by `updatedAt`, most recent K (default ~5).
- Per conversation: `title`, `objective`, `taskStatus`, `verificationStatus`,
  `updatedAt`, the last few messages, and `compactionSummary` when present.
- Later: workspace facts (git status / diff summary) so the review knows what
  changed on disk.

Cap messages per thread and total prompt size against a token budget. Threads
whose messages are not yet loaded are read only for a bounded number of the most
recent conversations.

## Autonomy: stage vs. auto-run

- **Stage (recommended default)** — create the new conversation, fill the
  composer with the generated prompt, select it, and let the user press Send. No
  surprise token spend or edits.
- **Auto-run (opt-in per project)** — send immediately, like the emergency chat.
  More autonomous, more risk; can be constrained to planning only.

## Settings and config

- **Global**: a "Project driver" section in Settings — master enable plus
  defaults (cooldown, lookback, autonomy). Mirrors `overseerObserver` /
  `experimentalOrchestrator`; off by default.
- **Per project**: enable, trigger, autonomy, model override, lookback count.
  Stored per project id in `projects.json`, edited from the project context menu
  and listed in Settings.

## UI surfaces

- Project rail tile: small badge when the driver is on / has a pending
  suggestion.
- Project header: "Move forward" button.
- Context menu: "Project driver…" (configure) and "Run now".
- Spawned chat: titled "Project review — <date>", badged in the session list.
- The manager conversation is **auto-pinned** to the top of its project's
  conversation list when it is opened or created.

## Expectations

- A **proposer**, not an oracle: it sees conversation state + workspace, not the
  user's intent. Output quality tracks how much recent context the threads keep.
- Costs one model request per fire, hence cooldown and off by default.
- Does nothing to the project unless auto-run is on; staged prompts wait.
- Excludes its own driver chats from the activity it reads.
- Does not run while the project is busy.

## Non-goals (first cut)

- No cross-project orchestration.
- No autonomous edits without an explicit Send or the auto-run opt-in.
- No new storage format beyond `projects.json`.

## Open decisions

1. Shape - decided: one persistent project manager per project.
2. Default trigger: manual only, or idle-after-N-minutes too.
3. Default autonomy: stage (recommend) or auto-run.
4. Scope defaults (e.g. 5 recent conversations × 10 messages each).
5. Exclude the manager's own turns / spawned chats from review input
   (recommend yes).
6. Where the per-project switch lives: context menu, Settings table, or both.
7. Does the manager do the next step in-thread, or open a new working
   conversation for it? (The original request says "trigger a new
   conversation", so opening a new one is the default.)

## Build stages

1. Config struct + persistence + Settings / context-menu UI. **Done** -
   `ProjectDriver` in `core.d` (persisted in `projects.json`), a "Project
   manager" Settings section, and rail-menu actions.
2. Manual "Run now" over the assembled digest (stage mode only). **Done** -
   `buildProjectReviewPrompt` in `source/auroraopencode/projectdriver.d`;
   "Review project now" opens a new conversation with the prompt staged.
3. Idle / interval triggers. **Done** - `runProjectManagerTriggers` (idle,
   interval, and on-turn-end), active project only, with a one-second throttle
   and a five-minute cooldown.
4. Autonomy. **Done** - per-project `Auto-run` (sends the prompt instead of
   staging it) and `Plan only` (auto-run constrained to planning).
5. Rail badge + per-project settings. **Done** - an accent dot on enabled
   projects in the rail; per-project checkboxes in Settings.

## Removing the feature

This is experimental and self-contained. To drop it:
1. Delete `source/auroraopencode/projectdriver.d`.
2. Delete `ProjectDriver` and `ProjectState.drivers` plus their load/save code in
   `core.d`, the `experimentalProjectManager` `Settings` field, and the
   `value.drivers = value.drivers.dup;` line in `preferencewriter.d`.
3. Delete the `// experimental: project manager` hunks in `appui.d`: the
   `projectdriver` import, the rail `onManagedQuery` dot, the Options master
   checkbox, the "Project manager" Settings section, the rail-menu block, the
   `_manager*` trigger fields + enum, the `runProjectManagerTriggers` call in
   `onTick`, and the `projectDriverIndex`/`ensureProjectDriver`/
   `projectManagerEnabledForIndex`/`setProjectDriverFlag`/`managerFlagCheck`/
   `setProjectManagerEnabled`/`openProjectManager`/`reviewProjectNow` methods.
