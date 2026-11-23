# Aurora OpenCode Lite v3 — Planning Review

Status: planning only. No v2 window, process, scene, or controller is changed by this work.

## 1. Product thesis

v3 is a new host/app architecture, not a copy of v2.

The long-lived unit is a stable host shell: one visible window, one instance, one
control server, lifecycle, and module host. The Lite app is a replaceable module
loaded by that shell. Scene, UI, controller, persistence, and CLI behavior can
be updated without closing, terminating, or replacing the main window.

## 2. Non-negotiable invariants

1. One visible main window.
2. One production instance by default; duplicate launch activates it.
3. No additional helper window during development or verification.
4. No cursor or synthetic keyboard automation against the desktop.
5. No host restart or shutdown for scene/controller/UI/test changes.
6. All app actions are reachable through the host control/CLI path.
7. A controller, when used, is windowless and supervised.
8. Live verification must not create a host or test window.
9. A shell-level release restart is a separate explicit operation, never a
   byproduct of build or test.
10. v2 data is read/migrated, never destroyed.

## 3. Architecture

### Stable v3 shell

- owns the single native window and scene runtime
- owns single-instance/activation and run lifecycle
- owns the loopback control protocol and CLI transport
- owns a hot-loadable app-module boundary
- supports a headless test mode that creates no OS window
- remains the same PID/window while the app module is replaced

### opencode-lite-v3 app module

- scene/UI definition and v3 node contract
- session, provider, model, key, and request policy
- controller implementation or external controller specification
- versioned persistence and v2 migration
- CLI operation definitions

### Controller

- optional, windowless, supervised
- hot-swappable independently of the shell
- console suppression is mandatory when spawned
- manual controller replacement must use a hidden launch path

## 4. v3 product scope

- multi-session sidebar: create, select, rename, search, delete
- persisted conversation history and active-session restore
- multiline composer: Enter sends; Shift+Enter inserts newline
- streaming, stop, retry, and regenerate
- provider/model/key state with validation
- session status, request state, and error details
- command-line parity for session and scene actions
- keyboard-first operation with no cursor requirement
- v2 conversation/settings migration
- separate v3 app-data directory

## 5. Data contract

Proposed files under the v3 app-data directory:

- `settings.json` — schema version, providers, model, key references
- `sessions/index.json` — session metadata and active session
- `sessions/<id>.json` — transcript and message records
- `conversation.json` — v2 import source only; copied, never modified
- `ui-state.json` — window bounds and non-sensitive UI state

Rules:

- all writes are atomic or rollback-safe
- schemaVersion 3 is required
- migration is idempotent
- secrets are never written into session/history files
- malformed data falls back without deleting the original

## 6. CLI contract

Minimum commands:

```text
status
list
sessions list
sessions new [name]
sessions use <id>
sessions rename <id> <name>
sessions delete <id>
send <text>
stop
retry
regenerate
get <node>
set <node> <text>
trigger <node> <action>
```

Rules:

- CLI connects to the existing shell
- it never launches a window
- it never restarts the shell
- it uses the same action path as keyboard/UI
- output is machine-readable where practical

## 7. Testing

- D unit tests for schema, migration, session model, and controller policy
- headless integration host with no OS window
- live-only check against the existing shell
- no host-lite helper windows in the development gate
- no synthetic desktop input
- controller hot-swap test preserving shell PID/window
- window geometry/DPI test without moving or focusing the user desktop

## 8. Milestones

### M0 — Contract and spike

- define module ABI and hot-load/version boundary
- prove scene/app reload while shell PID/window stay unchanged
- define v3 data schema and CLI protocol
- acceptance: one-window live proof and no helper-window test harness

### M1 — Stable shell

- shell package with window, control, instance, lifecycle, module host
- headless mode
- acceptance: module/scene replacement preserves shell PID/window

### M2 — v3 app surface

- two-pane multi-session UI
- composer and provider/model/key controls
- acceptance: full UI works from CLI/control without cursor

### M3 — Session model and migration

- session create/rename/search/delete
- history persistence and restore
- v2 migration
- acceptance: restart of app module restores sessions; v2 data intact

### M4 — Controller and streaming

- stop/retry/regenerate
- controller hot-swap hidden
- acceptance: controller failure/replacement leaves shell alive

### M5 — Release

- package version 3.0.0
- migration validation and rollback notes
- live gate and documentation
- acceptance: all milestones and invariants verified

## 9. Acceptance criteria

- shell PID and visible window unchanged across app-module updates
- exactly one visible app window at all times
- zero helper/test windows
- zero synthetic desktop-input code in tests/tools
- live verification creates no windows
- controller swap preserves shell PID/window
- CLI parity for all key actions
- v2 data migrates without destructive changes
- no host restart for scene/controller/UI work

## 10. Risks and decisions

- D module ABI and hot reload must be proven in M0 before broad app work
- zero-CRT/portable build constraints may restrict dynamic loading
- Windows DPI/window-placement behavior must be clamped safely
- external process termination is an OS permission boundary; the shell can
  reject controlled close paths, but an administrator can always terminate a
  process
- session file concurrency needs a single writer
- controller/CLI protocol compatibility must be versioned

## 11. Implementation order

1. M0 contract and hot-load spike
2. stable shell + headless test mode
3. v3 scene/session model
4. controller hot-swap and CLI parity
5. migration and release gate

Implementation starts only after the M0 contract/spike is reviewed.
