# Testing Progress and Methods (Aurora Cut)

## Aurora OpenCode Pro hidden tool-call wrapper (2026-08-12)

An assistant message that only requested tools (no content, no reasoning) no
longer renders as an empty bubble. `MessageBubble.setHidden` collapses it to a
zero-height, paint-nothing slot so the child↔message index mapping stays intact.
`handleToolCalls` rebuilds the column to hide the wrapper; `rebuildMessageColumn`
hides wrappers on session restore too.

Verify: Pro smoke test asserts every assistant wrapper is hidden, pill-free,
and usage-free. A probe confirms wrapper height = 0.

## Aurora OpenCode Pro tool-call wrapper cleanup (2026-08-12)

The assistant message that requests tools (the tool-call wrapper) is not a
reply, so it must not show a Regenerate pill or token usage. `handleToolCalls`
clears the wrapper's streamed usage text; `refreshBubbleActions` only pills the
latest assistant with no `toolCalls`; `rebuildMessageColumn` attaches usage
only to the latest real reply.

Verify in the Pro smoke test: after a read+grep tool loop, every assistant
wrapper bubble has no action pill and no usage text.

## Aurora OpenCode Pro latest-reply actions + message context menu (2026-08-12)

Only the latest assistant reply shows the Regenerate/Retry pill and the
token-usage footer; older bubbles are clean. Right-click on any message opens a
context menu with Copy message and, depending on role, Regenerate (assistant)
or Edit & resend (user).

Verify in the Pro smoke test: a user message has no pill, the latest assistant
reply has Regenerate; after regenerate the last bubble has no pill; the
right-click context menu Edit & resend truncates at the targeted message (the
foreach-closure regression is covered).

## Aurora OpenCode Pro opencode-style system prompt (2026-08-12)

Replaced the 2-line steering prompt with `buildSystemPrompt(nativeOnly,
workspace, platform)`, mirroring the original opencode app's system prompt
structure (from its source): identity, an `<env>` block with working
directory + "Is directory a git repo: yes/no" + platform + today's date, a
tone/style contract, a tool-usage policy, and "think about the task before
beginning work". This is what makes opencode's first answer feel deliberate.

Verify live with a temp probe against a real git repo: the model now gathers
context (git log/status/diff) and reads files instead of spamming shell
commands, and groups tool calls. Native mode runs `dshell where` + `run git
status` + `dshell list` in parallel.

## Aurora OpenCode Pro no console flash on tool calls (2026-08-12)

`runProcess` now calls `spawnProcess` with `Config.suppressConsole` (Windows
`CREATE_NO_WINDOW`), so the child process (cmd.exe / powershell.exe / a `run`
target) does not open a console window. Previously `Config.none` let Windows
flash a console for every bash/run/dshell tool call.

Verify: tools test still runs bash (`echo`), PowerShell, cmd, workdir, and the
D-native `run` tool successfully; Pro smoke passes.

## Aurora OpenCode Pro doom-loop recovery (2026-08-12)

User reported a runaway tool loop ("where we are at" kept calling tools until
the round limit). The original opencode app has a `doom_loop` permission: when
the same tool call repeats with identical input 3 times it stops and asks.

Our implementation: `handleToolCalls` builds a signature of each tool-call
batch (`name(arguments)`); when the same signature repeats 3× it breaks the
loop, injects a `user` recovery message ("You appear to be repeating the same
tool call... answer directly"), resets the counters, and runs one final request
so the model answers instead of looping. The 12-round cap now also injects a
"stop and answer" message rather than silently stopping.

Verify in the Pro smoke test: three identical `dshell list` injections
accumulate a repeat count (1, 2, 3) and the third triggers a recovery `user`
message.

## Aurora OpenCode Pro collapsed thinking with progress animation (2026-08-12)

Reasoning blocks now render as a slim collapsed `▸ Thinking` header (same
pattern as the tool result headers). Clicking toggles the full reasoning text.
While the assistant is still streaming, the header shows an animated pulsing
`▌`/`▐` indicator, driven by the root's per-frame tick (`tickThinking`), which
repaints only when the indicator phase changes (every ~0.5s), so the animation
is cheap. `finishAssistantMessage` freezes the indicator.

This mirrors the original opencode app: it renders reasoning as a streamed text
part behind a show/hide toggle (/thinking in the TUI) and tools as collapsible
cards — no full-spinner animation; the pulsing cursor is our lightweight
equivalent of the typing reveal.

Verify in the Pro smoke test: an assistant message with reasoning is created
via `addConversationForTestingWithReasoning`, starts collapsed, and toggles
open/closed on demand.

## Aurora OpenCode Pro tool collapse UX (2026-08-12)

A `tool` result bubble is now a single element: a header showing the command
(`▸ ⚙ name(args)`) that is always visible, with the output below shown only
when expanded (`▾` when open). Clicking the header toggles the output.

Two fixes shipped:
1. No scroll jump: the collapse/expand `onSizeChanged` handler no longer sets
   `_messagesScroll.follow = true`; it only invalidates the column + scroll, so
   the viewport is preserved when expanding a bubble above the fold.
2. Command + output unified: `toolArgs` (the command's JSON arguments) is
   stored on the tool message and persisted, and rendered compactly in the
   header (`key=value` pairs). The separate tool-call chips were removed from
   assistant bubbles.

Verify in the Pro smoke test: tool bubbles start collapsed; expand/collapse
toggles; and a scroll-position regression scrolls up, expands, and asserts the
offset does not snap to the bottom.

## Aurora OpenCode Pro collapsed tool outputs (2026-08-12)

`tool` role result bubbles start collapsed to a compact header
(`⚙ <name> · <first line> ▾`) and expand on click. The bubble calls
`onSizeChanged`, which invalidates the message column and scroll view so the
content re-measures, the scroll re-follows, and large outputs (e.g. `dir`
listings) don't blow up the conversation view by default.

Verify in the Pro smoke test: after the read+grep tool loop, the first tool
bubble is collapsed; `toggleFirstToolBubbleForTesting` expands then collapses
it with repaint + reflow each way. Screenshots of both states are written to
`%TEMP%\aurora-opencode-collapse-shots`.

## Aurora OpenCode Pro dshell advertises only natural words (2026-08-12)

The model sometimes emitted `pwd`/`ls`/`stat` because the dshell tool
description and JSON schema enum TAUGHT those aliases. Fixed:

- The advertised `dshell` schema `command` enum is now exactly
  `["where","list","info"]` and the description never mentions pwd/ls/stat.
- The runtime dispatcher still accepts pwd/ls/dir/stat as a safety net (calls
  never fail), but the model is never offered them.
- The steering prompt explicitly forbids shell command words.

Verify: `tools_test.d` runs `dir` through the shell tool, checks `where/list/
info` plus alias fallback, AND asserts the advertised schema/description
contain no legacy words (`dshell advertises only the natural words`). Live
probe: "where are we now?" calls `dshell where` (+ `list`) only, both modes.

## Aurora OpenCode Pro tool-output UTF-8 safety (2026-08-12)

The shell/run tools read console output as raw bytes (cmd emits the OEM
codepage, not UTF-8). A bug wrote those bytes straight into a `string`, which
is invalid UTF-8 and broke `sessions.json` persistence → `restore sessions
failed: Invalid UTF-8 sequence` on the next launch.

Fix in `runProcess`: each raw byte is mapped to its own `dchar` and UTF-8
encoded (`std.utf.toUTF8`), so tool output is always valid UTF-8.

Regression: `tools_test.d` runs `dir` (which emits the OEM thousands
separator), asserts `std.utf.validate` passes and the listing is complete.
Verified a clean app restart logs zero errors.

## Aurora OpenCode Pro dshell natural words (2026-08-12)

`dshell` deliberately uses short natural-English words instead of the legacy
shell abbreviations, so conversations read clearly:

- `where` — prints the workspace path (alias `pwd`).
- `list` — shows a directory with `[f]`/`[d]` tags and byte sizes (aliases
  `ls`/`dir`).
- `info` — file/directory metadata: type, size, modified time (alias `stat`).

Legacy words still work as aliases so a model that reaches for `ls`/`pwd`/
`stat` never fails. All implemented natively in D (`std.file`), no shell.

Verify with the tools test:
```
cd aurora-opencode-pro
dmd -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\tools_test.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\tools-test.exe
build\tools-test.exe
```
Pass = `D-native dshell where / list / info (+ aliases) OK`, `Default vs
native-only toolset shapes OK`, then `Aurora OpenCode Pro tools module test
passed.`

Live (temp probe): "where am I and what's in the workspace?" now answers via
`dshell where` + `dshell list` then `read` in 3 rounds — the model uses the
natural words.

## Aurora OpenCode Pro dshell tool (2026-08-12)

The model still reached for bash for plain directory introspection
(pwd/ls/dir/stat). Added a D-native `dshell` tool in
`aurora-opencode-pro/auroraopencode/tools.d`:

- `pwd` — prints the workspace path.
- `ls` / `dir` — lists a directory (`SpanMode.shallow`) with `[f]`/`[d]` tags
  and byte sizes.
- `stat` — file/directory type, size, and modified time.

It never spawns a shell; everything uses `std.file` (`dirEntries`, `getSize`,
`timeLastModified`). Advertised in both the default and native-only toolsets,
and the steering prompt directs the model to prefer it over bash for these
commands.

Verify with the tools test:
```
cd aurora-opencode-pro
dmd -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\tools_test.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\tools-test.exe
build\tools-test.exe
```
Pass = `D-native dshell pwd / ls / stat OK`, `Default vs native-only toolset
shapes OK`, then `Aurora OpenCode Pro tools module test passed.`

Live (temp probe): "where am I and what's in the workspace?" now answers via
`dshell pwd` + `dshell ls` then `read` in 3 rounds, no bash attempts. Native
mode uses `dshell ls` directly.

## Aurora OpenCode Pro native-tool mode (2026-08-12)

User feedback: the model defaulted to bash for file operations and fumbled
("list files" burned many rounds on `dir` variants). Two fixes shipped:

1. **Shell output capture bug** — cmd's `dir` emits the OEM codepage, which is
   not valid UTF-8; strict `readText` threw and the tool returned "(no
   output)". `runProcess` now reads stdout/stderr as raw bytes and decodes
   leniently, so `dir`/`echo %CD%` return real output.

2. **Native-tool mode** — a new D-native `run` tool (`program` + `args` array,
   spawned directly, no shell), a system-prompt steering message that directs
   the model to glob/read/write/grep, and a "Native tools" toggle (off by
   default). When enabled, the bash tool is not advertised and the model only
   sees run/read/write/glob/grep with a "no shell" prompt.

Verify with the tools test (covers run tool + toolset shapes + steering):
```
cd aurora-opencode-pro
dmd -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\tools_test.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\tools-test.exe
build\tools-test.exe
```
Pass = `D-native run tool executes a program directly`, `Default vs native-only
toolset shapes OK`, then `Aurora OpenCode Pro tools module test passed.`

Live probe (temp file `list_probe.d`): native mode answers "what files are in
the workspace?" with glob → read in 3 rounds, no shell. Default mode with the
steering prompt completes the same task in 3 rounds too.

## Aurora OpenCode Pro cross-platform tools (2026-08-12)

Design decision (mirrors the original opencode app): keep native D file/content
tools (`read`, `write`, `glob`, `grep`) — cross-platform by construction — and
make the one shell tool ("bash") shell-aware per platform rather than shipping
separate cmd / powershell tools.

- The bash tool schema now has `command` (required), `shell`
  (`auto|bash|cmd|powershell|pwsh`), `workdir`, and `timeout` (ms).
- The description embeds per-platform usage notes: on Windows it tells the
  model it runs in cmd.exe (or the chosen PowerShell) with the right commands,
  on Unix it says bash.
- Execution uses `spawnProcess(argv, stdin, outFile, outFile, null,
  Config.none, workdir)` — the shell binary is invoked directly with
  stdout/stderr redirected to a temp file, so no shell quoting is involved and
  a timeout can still kill the process.

Run the tools test (covers cmd, PowerShell, workdir):
```
cd aurora-opencode-pro
dmd -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\tools_test.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\tools-test.exe
build\tools-test.exe
```
Pass = `cmd / powershell / workdir shell selection OK` then
`Aurora OpenCode Pro tools module test passed.`

## Aurora OpenCode Pro action-pill foreach capture bug (2026-08-12)

User reported "I press edit & resend and nothing happens anymore". Root cause:
the Regenerate / Edit & resend pill callbacks were created inline inside the
`foreach` over `_messageColumn.children()` (`refreshBubbleActions`) and the
right-click `onEditRequested` (`rebuildMessageColumn`). D captures the reused
`foreach` loop slot by reference, so every closure was bound to the FINAL
message index; clicking a pill on any early bubble edited (or no-op'd against)
the last message instead.

Verification method:
```
dmd -version=AuroraHeadless -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\headless_pro_smoke.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\headless-pro-smoke.exe
build\headless-pro-smoke.exe
```
Pass = `Aurora OpenCode Pro headless smoke test passed.` The regression section
(`invokeBubbleActionForTesting`) drives the pill through the real captured
delegate on a mid-conversation user bubble and asserts it truncates at and
prefills that bubble's own message.

D gotcha confirmed independently: even `const int captured` / non-const locals
declared inside a `foreach` body capture the shared loop slot in DMD 2.112;
only a delegate factory function (binding indices as parameters) works. The
same pitfall and fix are documented in `AURORA-PATCHES.md` for font menus.

## Aurora OpenCode Pro tool use support (2026-08-12)

Studied the original opencode app's tool architecture (the tool registry in
`packages/opencode/src/tool`: bash/shell, read, write, glob, grep, webfetch,
websearch, question, task, todo, skill, apply_patch, lsp, plan) and confirmed
the exact wire format with a live probe against the real Go API:

- Tool calls stream as `choices[0].delta.tool_calls` fragments:
  `{index, id, type, function:{name, arguments}}` where `arguments` arrives in
  multiple fragments that must be concatenated.
- The stream ends with `finish_reason: "tool_calls"` (no text reply).
- Results are fed back as `role: "tool"` messages with `tool_call_id`
  (plus the assistant message with its `tool_calls`), and the loop repeats
  until the model returns a normal text reply.

The core client (`aurora-opencode-core/opencode_client.d`) gained
`startChatMessages(messages, tools, model, thinking)` with
`ChatRequestMessage`/`OpenCodeToolDef`, SSE `delta.tool_calls` accumulation,
a `toolCalls` terminal event, and `pushLocalEvent`. The Pro UI drives the
loop: Tools checkbox → workspace setting → tool-call chips + `tool` role
result bubbles → worker-thread batch execution → history re-sent until `stop`
(12-round cap).

### Tests

1. Core SSE parsing + body serialization:
```
cd aurora-opencode-core
dmd -i -Isource -I..\vendor\aurora-d-0.4.5\source tests\tool_sse_test.d wininet.lib -of=build\tool-sse-test.exe
build\tool-sse-test.exe
```
Pass = `aurora-opencode-core tool SSE tests passed.` Covers fragmented
`tool_calls` accumulation (id/name/arguments stitched), the `toolCalls`
terminal event, tools array serialization, and a tool-role message carrying
`tool_call_id`.

2. Pro tools executors:
```
cd aurora-opencode-pro
dmd -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\tools_test.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\tools-test.exe
build\tools-test.exe
```
Pass = `Aurora OpenCode Pro tools module test passed.` Covers read/write/glob
(`**` recursion)/grep/bash (echo) against a temp workspace, and unknown-tool
error handling.

3. Pro headless smoke (tool loop offline):
```
cd aurora-opencode-pro
dmd -version=AuroraHeadless -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\headless_pro_smoke.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\headless-pro-smoke.exe
build\headless-pro-smoke.exe
```
Pass = `Aurora OpenCode Pro headless smoke test passed.` The added section
injects a tool call (read + grep) with tools enabled, ticks the tree until the
worker results arrive, and asserts two `tool` role messages landed with the
right contents and the session history was preserved.

4. Live tool loop against the real API (verified): a sum tool request runs two
rounds (tool_calls → result → text `The result of adding 1 and 2 is 3.`), and
the built-in tool set (glob/read/bash) completes a workspace task with
`LIVE BUILTIN TOOL LOOP OK` and a clean `errors.log`.

## Aurora OpenCode Pro live context-usage meter (2026-08-12)

Pro shows the **exact API-reported token usage** as a percentage of the model's
context window in a small rectangular toolbar badge, with a hover tooltip that
breaks the usage down (mirrors how the real opencode app meters context):

- **How the real opencode meters context** (`anomalyco/opencode`): it uses the
  provider's `usage` object stored per assistant message
  (`tokens: {input, output, reasoning, cache:{read,write}}`), displayed as
  `total / model.limit.context` percent. There is **no live mid-stream
  estimate** in the real UI — the indicator updates at each `step-finish`. The
  only local approximation (`Math.round(chars/4)`) is used for compaction /
  overflow decisions and the estimated breakdown bar. The context limit comes
  from provider metadata (`model.limit.context`).
- **Implementation** in `aurora-opencode-pro/appui.d`: `ContextUsageBadge`
  (toolbar pill, fill bar + percent) + `ContextUsageTooltip` (hover panel,
  never steals the pointer — its `hitTest` reports the badge while hovered).
  The shared client pushes a live `usage` event when the provider reports token
  counts mid-stream (`opencode_client.d`, `_streamActive` guard), and the `done`
  event records the final `prompt/completion/total` on the `ChatMessage`
  (persisted in `sessions.json`).
- **Context limit**: `contextLimitForModel()` in `aurora-opencode-core/core.d`
  mirrors `model.limit.context` with the **official opencode model catalog**
  (`https://models.opencode.ai/api.json` — the exact source the opencode CLI
  fetches). Verified live against that catalog: deepseek-v4-flash and
  deepseek-v4-pro are 1,000,000 tokens, gpt-5.6-luna 1,050,000, qwen3.8-max
  and glm-5.2 1,000,000, grok-4.5 500,000, kimi-k3 1,048,576, minimax-m3
  512,000, mimo-v2.5-pro 1,048,576, hy3 256,000. Unknown models fall back to
  128K. The used-token count itself is always exact from the API.
- **Badge lifecycle**: updates live during streaming (`usage` event), on
  `done`, on session switch, model picker, restore, and delete. Shows `ctx`
  until usage is recorded.

Covered by `headless_pro_smoke.d`: initial empty state, 25% after recording
250000/1000000 (deepseek-v4-flash limit from the official catalog), hover
opens the tooltip (title/model/limit/used/prompt rows), leave dismisses it,
and the meter follows the active session. Verified visually via a PPM
screenshot (badge region: 24 distinct colors, tooltip region: 29).

## Aurora OpenCode Pro chat-quality actions (2026-08-12)

Pro-only chat quality (implemented in `aurora-opencode-pro/appui.d`, shared
`ChatMessage.failed` flag in core):

- **Regenerate / Retry** — the last assistant bubble shows a footer pill. It
  drops the last assistant reply and re-runs the request with the remaining
  history; labelled "Retry" when that reply failed.
- **Edit & resend** — a user bubble's footer pill (and right-click on any user
  bubble) truncates the conversation at that message and prefills the input so
  the edited text can be re-sent.

Covered by `headless_pro_smoke.d`: `editAndResendForTesting` truncates and
prefills, and `prepareRegenerateForTesting` removes the last assistant reply.

## Aurora OpenCode real API integration (2026-08-12)

The clients now talk to the **real opencode API** (`https://opencode.ai/zen/go/v1`,
the Go plan) instead of the demo proxy `opencode-api.boqsc.eu`:

- `defaultBaseUrl` in `aurora-opencode-core/core.d` points at
  `https://opencode.ai/zen/go/v1`.
- The API key is read from the real opencode CLI auth store
  (`~/.local/share/opencode/auth.json`, `opencode-go.key`, falling back to
  `deepseek.key`), then the legacy web-server key files, then
  `OPENCODE_API_KEY`.
- Every request sends a desktop-browser `User-Agent`. The real API sits behind
  Cloudflare and returns HTTP 1010 to non-browser clients otherwise.
- Thinking off is sent as the standard `reasoning_effort: "none"` (the demo
  proxy used to translate a custom `thinking: false` boolean, which the real
  API rejects).

Verified live: the smoke test's real chat returns exactly `AURORA-OPENCODE-GUI-OK`
(22 chars) with a clean `errors.log`. Debug + release builds of baseline and Pro
pass. The old loopback fallback to the local demo proxy was removed.

## Aurora OpenCode runtime error logging (2026-08-12)

Both OpenCode clients write runtime errors to
`%APPDATA%\Aurora OpenCode\logs\errors.log` (one shared file, appended). Each
launch writes a `========== <app> started ==========` banner, and every entry is
timestamped, so the latest session is easy to scan. The log directory is the
state directory plus `logs`; tests redirect it through the normal
`setOpencodeStateDirectoryForTesting` hook.

Captured sources:
- Chat and models request failures (WinINet errors such as 12029/12002) with
  the configured base URL, logged from the shared client worker threads.
- Settings load/save failures and session persist/restore failures.

A WinINet 12029 (`ERROR_INTERNET_CANNOT_CONNECT`) or 12002 (timeout) on
`chat request failed` means the API server was unreachable when the request was
sent, not a client bug.

## Aurora OpenCode Pro extended features (2026-08-11)

`aurora-opencode-pro` layers extended features on the shared core while the
baseline stays basic:

- Conversation **delete** (sidebar right-click menu + `Delete` key) and
  **rename** (context menu -> dialog).
- **Filter** box above the conversation list (title substring match).
- Per-message and **code-block Copy** buttons (hover the bubble or panel), and
  **clickable Markdown links** (open the default browser).
- **Message timestamps** (HH:MM) and **token usage** in the status line.
- **Export** the current conversation to a `.md` file under
  `%APPDATA%\Aurora OpenCode\exports`.

Run the Pro headless smoke test from `aurora-opencode-pro`:

```
dmd -version=AuroraHeadless -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\headless_pro_smoke.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\headless-pro-smoke.exe
build\headless-pro-smoke.exe
```

Pass = `Aurora OpenCode Pro headless smoke test passed.` Coverage: restored
sessions, filter narrowing/clearing, rename via the context menu, delete via the
list Delete hook, and Markdown code-block/link bubbles painting.

## Aurora OpenCode structure: baseline, core, and Pro (2026-08-11)

The OpenCode chat clients are split so the baseline stays small while the
extended version grows freely:

- `aurora-opencode-core` — DUB library (`targetType: library`) with the
  shared `auroraopencode.opencode_client`, `auroraopencode.markdown`, and
  `auroraopencode.core` modules. Both clients depend on it by path.
- `aurora-opencode` — the baseline client (thin `appui.d` on top of core).
- `aurora-opencode-pro` — the extended client with its own `appui.d`.

Build and run the baseline or Pro exactly like the other apps:

```
cd aurora-opencode
dub build --force
cd ..\aurora-opencode-pro
dub build --force
```

The headless tests compile with `dmd -i` and therefore need the core source
directory on the import path in addition to the app and Aurora-D sources.

## Aurora OpenCode startup conversation scrollbar (2026-08-11)

The OpenCode headless smoke test now creates an isolated persisted state with
25 conversations and the last conversation selected before constructing the
window. It paints the initial tree and asserts the restored selection remains
selected while the conversation `ListView` scroll offset is still zero. Run
from `aurora-opencode`:

```
dmd -version=AuroraHeadless -i -Isource -I..\aurora-opencode-core\source -I..\vendor\aurora-d-0.4.5\source tests\headless_smoke.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\headless-smoke.exe
build\headless-smoke.exe
```

The test also retains the existing OpenCode interaction, persistence, model
picker, message auto-follow, scrollbar drag, and scrolling shape-cache checks.

## Unified scrolling and rich drag/drop (2026-08-11)

Run the retained control and event-routing contracts:

```
cd vendor\aurora-d-0.4.5
dub run --config=widget-infrastructure-test --compiler=dmd
```

Pass = `Unified scrolling and rich drag/drop contracts passed.` Coverage
includes `ScrollView`, `ListView`, and `TextArea` using child `Scrollbar`
widgets, ordinary wheel and native absolute-position input, rich payload
enter/move/drop/leave dispatch, custom MIME preservation, and action
negotiation.

Run `dub test --compiler=dmd` on Windows to exercise the OLE data-object
round-trip for file paths, Unicode text, URI lists, and custom MIME bytes.

## Windows File Manager wheel / touchpad scrolling (2026-08-11)

The file manager now uses the reusable retained-mode
`aurora.widgets.scrollbar.Scrollbar` control for both its list and sidebar.
The widget owns range/value state, Aurora rendering, wheel accumulation,
keyboard input, page clicks, thumb hit-testing, and pointer capture. Aurora's
window host tracks the scrollable widget beneath the pointer and synchronizes
only that widget's range/value with Win32, so sibling list/sidebar controls
cannot overwrite one another. Windows does not draw the control or move the
file-manager content.

### 1. Deterministic widget and file-manager contracts
```
cd vendor\aurora-d-0.4.5
dub run --config=file-manager-scroll-test --compiler=dmd
```

Pass = `Windows file manager wheel/touchpad scroll contracts passed.` The test
covers standalone widget geometry, track paging, thumb capture/dragging,
standard wheel input, fine-grained touchpad deltas, native absolute scroll
commands, sidebar routing, ignored non-scroll areas, and independent windows.

### 2. Win32 focus, range, and exact-delta probe
```
cd vendor\aurora-d-0.4.5
python tools\file_manager_focus_scroll_probe.py ^
  aurora-windows-file-manager.exe build\fm-scroll-test
```

The probe checks that the HWND advertises a synchronized native scroll range,
a client click establishes foreground focus, `WM_VSCROLL` updates the real
widget, four standard notches move exactly 104 px, and twelve `-20` precision
deltas accumulate to exactly 52 additional px. Pass marker:
`NATIVE FOCUS + SCROLL VERIFIED`.

## Live resize verification (2026-08-11)

Use the checked-in Python probe to launch an app and drive the native window:

- `python vendor\aurora-d-0.4.5\tools\resize_latency_probe.py
  aurora-opencode\aurora-opencode.exe --renderer vulkan --iterations 120
  --step-delay 0.016 --profile-frame`
- The probe sends `WM_ENTERSIZEMOVE`, changes the window through
  `SetWindowPos`, and ends with `WM_EXITSIZEMOVE`. It reports median/p95/max
  native-call latency and the number of calls over 16 and 50 ms.
- `--profile-frame` reports final scene/layout/paint/render time plus the number
  of exact live-reflow frames completed during the drag.
- The default settle probe also reports p95/max message latency after
  `WM_EXITSIZEMOVE`, covering deferred native-resolution swapchain recreation.

OpenCode uses the automatic renderer (Vulkan by default when available).
`RUN-WINDOWS.bat` builds/runs release; `RUN-WINDOWS-SOFTWARE.bat` is the explicit
software fallback.

## How to build and test on Windows

### Build the app
- `dub build --force` (requires DMD/LDC + DUB, ffmpeg/ffprobe/ffplay on PATH).
- If the linker reports `aurora-cut.exe: Access is denied`, a previous instance
  is locking the file: `del aurora-cut.exe aurora-cut.pdb` and rebuild.
- Result: `aurora-cut.exe` in the repo root.

### Run the headless editor smoke test (editor_smoke.d)
The smoke test drives the real GUI headlessly (`RendererPreference.software`)
and needs three generated media files.

1. Generate media (mirrors `scripts/verify-headless.sh`):
   ```
   mkdir build\headless-smoke\media
   ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=blue:size=320x180:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 1.5 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 128k -shortest build\headless-smoke\media\base-av.mp4
   ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=red:size=160x90:rate=30" -t 1.2 -an -c:v libx264 -preset ultrafast -pix_fmt yuv420p build\headless-smoke\media\overlay.mp4
   ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=523.25:sample_rate=48000" -t 1.5 -c:a libmp3lame -q:a 4 build\headless-smoke\media\audio.mp3
   ```
2. Compile with the Windows system libs (Linux uses `-L-ldl` instead):
   ```
   dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source tests\editor_smoke.d -of=build\headless-smoke\editor-smoke.exe -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32 -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet
   ```
   (`dmd` uses `-version=X`, not `-d-version=X`; missing system libs surface as
   `lld-link: undefined symbol: IsClipboardFormatAvailable/GetClipboardData/...`.)
3. Run:
   ```
   set AURORA_RENDERER=software&& set SDL_AUDIODRIVER=dummy&& build\headless-smoke\editor-smoke.exe build\headless-smoke\media\base-av.mp4 build\headless-smoke\media\overlay.mp4 build\headless-smoke\media\audio.mp3
   ```
   Pass = prints `Aurora Cut multi-track editor smoke test passed.`

### Other smoke tests
- `model_smoke.d` and `gpu_decode_args_smoke.d` need no args; compile with the
  same `dmd -i -Isource -Ivendor\aurora-d-0.4.5\source` + system libs flags.
- `export_smoke.d` takes `<base-av.mp4> <overlay.mp4> <extra.mp3> <output-dir>`.
- Linux CI path: `scripts/verify-headless.sh`, `scripts/verify-export.sh`.

### Context menu / resolution feature notes (2026-08-10)
- Right-click a timeline video item -> "Set sequence resolution to NxN" matches
  the composition/output resolution to that item's source canvas (crop-aware).
- MP4 export uses the composition canvas, so output follows the sequence
  resolution automatically; the Preview quality control (720/1080/1440/2160)
  only caps the on-screen decode size for responsiveness.
- Covered by editor_smoke.d: menu wiring on V1 (320x180) and overlay (160x90)
  clips, plus the shared action via `matchClipResolutionForTesting`.

## Aurora Image Viewer (aurora-image-viewer)

Standalone viewer in `aurora-image-viewer/`. **No FFmpeg dependency** — decode
is pure D: PNG (Aurora-D built-in), BMP (24/32/16/8/4/1 bpp, BITFIELDS, RLE8/RLE4),
TGA (truecolor/gray/colormap, RLE, 16/24/32/8 bpp), PNM (P2/P3/P5/P6/P7), and
GIF (first frame, LZW, interlace, transparency). Rendering is a custom
mipmapped CPU scaler in `source/auroraimageviewer/scaler.d`: it picks the mip
level closest to screen scale and bilinear-samples only that level, so zooming
out on huge images is fast and aliasing-free. The ImageView widget is an
opaque retained compositor layer; pan/zoom re-render a reusable viewport RGB
buffer each paint.

### Build the app
```
cd aurora-image-viewer
dub build --force
```
Result: `aurora-image-viewer/aurora-image-viewer.exe` (GUI subsystem, no
console window). Run with `RUN-WINDOWS.bat` or `RUN-WINDOWS-SOFTWARE.bat`
(software renderer). CLI: pass an image path to open it directly.

### Headless smoke test (headless_smoke.d)
No media generation needed — the test writes its own PNG/BMP/TGA/PPM/PAM/GIF
files with pure D (std.zlib for PNG), so it also exercises the decoders
without any external tools.

```
cd aurora-image-viewer
dmd -version=AuroraHeadless -i -Isource -I..\vendor\aurora-d-0.4.5\source tests\headless_smoke.d user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib -of=build\headless-smoke.exe
build\headless-smoke.exe
```
Pass = prints `Aurora Image Viewer headless smoke test passed.`
Coverage: scaler pyramid dimensions + 100%/50% render correctness, letterbox,
negative-offset panning, alpha-over-checker compositing, all decoders, and a
UI pass driving wheel zoom / fit / drag-pan / file drop / actual-size and
saving a screenshot PPM.

### Screenshot mode
`aurora-image-viewer.exe --screenshot <image> <out.ppm>` renders the default
window (fit zoom) headlessly and writes a PPM. Verify by converting to PNG:
`ffmpeg -i out.ppm out.png` (ffmpeg only needed for this local visual check,
not by the app).

### Key scaler details / gotchas
- Mip levels stop when min(w,h) <= 8; box-averaged with premultiplied alpha.
- Level pick keeps per-dest level zoom in [1,2) so bilinear never skips data.
- Fixed-point 32.32 sampling mirrors the software renderer, so exact-size
  blits are row copies.
- Letterbox is a solid color; transparency composites over an anchored
  16px checkerboard inside the image region only.
- D gotchas hit while building: `out` is a D keyword (use `output`/`buf`),
  `byte` is a D keyword (use `packedByte`), dmd uses `-version=X` (not
  `-d-version=X`), and system libs must be passed as `user32.lib ...` file
  args to lld-link (dub passes them automatically).
- Previous ffmpeg-based decode crashed inside the worker thread during the
  UI drop test; removing the subprocess path (standalone decode) fixed it.
