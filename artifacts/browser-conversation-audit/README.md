# Aurora OpenCode Pro: browser conversation audit

Implemented and delivered in source commit `d882eb562bb1460cefa4b2f337585667f489e838`.
Aurora was rebuilt, relaunched and publicly verified. See the
[implementation and regression evidence](C:/Users/windows10/Documents/github_repositories/aurora-gui/artifacts/browser-conversation-audit/implementation-results.json)
and [usage documentation](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/docs/task-verification.md).
The historical audit snapshot below is preserved. The browser corpus correctly
exposes an existing rendering failure; delivery does not claim the browser engine
itself is correct.

Conversation: `t-m639276073661326566-0` ("web browser").

Snapshot: 16 October 2026, 10:15 Kyiv time (UTC+03:00). The conversation was still active. This investigation adds audit artifacts only; it does not change Aurora's production code, chat state, settings, or running processes.

The strongest finding is a mismatch between the task's real source checkout and the workspace used to accept verification. It explains why the model repeatedly says its checks passed while Aurora keeps requesting unfinished work. Two other mechanisms compound this: rebuild reasons cross conversation boundaries, and the continuation detector measures novel tool activity rather than improvement toward the requested result. A better browser evaluation loop is also needed: passing the engine's existing checks does not establish that a real page matches its intended appearance and behavior.

## What was measured

The audit follows saved parent IDs from the selected leaf. It excludes 54 stored messages on other branches from workload totals. Failures on other branches are reported separately. It reads the runtime journal and retained diagnostic logs, and compares the findings with the current source.

| Signal | Snapshot result | Interpretation |
| --- | ---: | --- |
| Conversation span | 34.53 hours | 14 October 23:44 to 16 October 10:15, Kyiv time; includes interruptions and waits |
| Stored / selected-path messages | 10,284 / 10,230 | A very large investigation and implementation history |
| Tool calls / tool rounds | 5,308 / 3,504 | Each tool round requires another model decision |
| `run` / `apply_patch` calls | 2,438 / 1,015 | Many small implementation and verification cycles |
| `update_plan` calls | 357 | Planning itself consumes substantial conversation traffic |
| Automatic task continuations | 231 | Every continuation reports `verified: false`; 211 report zero stalls |
| Median reported input tokens | 246,195 | Maximum 402,122; substantial history accompanies small decisions |
| Cumulative reported input tokens | 930,978,616 | Includes repeated history and potentially cached tokens; **not a billing total** |
| Durable checkpoints / progress guidance | 542 / 215 | Control state contributes to context and distraction |
| Successful image inspections / distinct blobs | 132 / 88 | Screenshots are being inspected; repeated pixels also occur |
| Successful recognized build/check commands | 1,019 | None has the selected project's working directory |
| Journal updates with verification `passed` | 0 | States observed are unset, `not_required`, and `required` |

Repeated commands are evidence of costly workflow granularity, not automatically wasted work. For example, the identical engine-test execution appears 317 times, a particular engine-test compile 272 times, a particular smoke-test compile 203 times, and a particular smoke-test execution 200 times. Many followed edits and were justified. The improvement is to make necessary verification cheaper and better targeted, while detecting repetitions that have no new reason.

Retained logs cover approximately 15 October 16:11 through 16 October 10:15. For 1,746 matched requests:

| Request milestone | Median |
| --- | ---: |
| Accepted | 39 ms |
| Serialized | 49 ms |
| Upload complete | 115 ms |
| First token | 7.60 s |
| Request settled | 13.65 s |

These are cumulative milestones from a common origin; do not add them together. Typical requests contain about 0.89 MB of wire data, including about 0.30 MB of historical reasoning. The client reaches upload completion quickly relative to the subsequent wait. Removing unnecessary model decisions therefore has greater demonstrated potential than optimizing a few more milliseconds of ordinary request preparation.

Request 2911 spans roughly three hours before failing without a first token. The logged transport attempt says the body was sent, but no headers were available. The cause is not established: machine suspension, an unusually delayed callback, or network/provider behavior must be distinguished. It would be incorrect to label the whole span model inference time. All stored branches also contain 44 failed assistant attempts, including WinHTTP errors and seven insufficient-credit errors.

## Ten concrete improvements, in priority order

### 1. Bind verification to the actual task checkout and build inputs

**Confirmed correctness issue.** The conversation starts in `sandbox 1` and later belongs to `sandbox 2`, whose path is under `%APPDATA%/Aurora OpenCode/sandbox/`. The requested source is the `aurora-gui` checkout. The 1,019 successful recognized checks have these working directories:

- Temporary `aurora-evtest`: 512.
- `aurora-gui/aurora-browser`: 502.
- `aurora-gui/aurora-web`: 5.
- Selected project workspace: **0**.

`tools.d` records a check's workspace as its command working directory. `applyToolResult` accepts a check only when that directory exactly equals `workspaceForSession`. Consequently, the successful checks cannot clear verification for this chat. Every saved automatic task continuation has `verified: false`; the journal never records `passed`.

Relevant source:

- [Check identification and working-directory evidence](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/source/auroraopencode/tools.d:2297).
- [Exact workspace and revision acceptance condition](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/source/auroraopencode/appui.d:18888).
- [Conversation workspace resolution](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/source/auroraopencode/appui.d:13292).

**Change:** record explicit task source roots and check targets. Associate check results with the source-input revision and produced artifact, even when compilation or execution happens in a temporary directory or subpackage. Resolve explicit user paths early and show the task checkout clearly. Do not replace the equality condition with unconditional acceptance of arbitrary successful commands.

**Acceptance case:** a chat in a sandbox edits a specified external checkout, compiles into a temporary directory, and runs a registered test. Correctly scoped evidence satisfies the corresponding requirement. A check from an unrelated checkout or older source revision cannot satisfy it. Parent checkout and subpackage paths resolve consistently.

### 2. Keep rebuild reasons within their owning conversation

**Confirmed consistency issue.** Seven rebuild notices appear in this browser chat. They include reasons such as adding the project manager, deploying project-rail drag reordering, and persisting the project-manager master switch. These are tasks from Aurora OpenCode Pro development, rather than the browser request. The model explicitly spends effort rejecting them and eventually calls `task_blocker` about the contradiction.

Evidence examples:

- `m639276099866439803-2`: resume reason requests project-manager stages 2–5.
- `m639276111680936849-2`: resume reason requests project-rail drag reordering.
- `m639276113830204173-2`: resume reason requests the master-switch and rail-dot fix.

The source constructs one `_resumePrompt` from the recorded rebuild reason, then appends that same prompt to every interrupted conversation.

- [Single resume prompt construction](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/source/auroraopencode/appui.d:11218).
- [Reason incorporated as continuation guidance](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/source/auroraopencode/appui.d:11347).
- [One prompt distributed to all targets](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/source/auroraopencode/appui.d:29218).

**Change:** retain the rebuild owner thread and turn IDs. Give the owner its specific rebuild result. Give other interrupted chats a neutral application-restart notice and their own task state. Keep build diagnostics separate from instructions about what to implement.

**Acceptance case:** rebuilding chat A while B is working resumes both; A's reason never appears in B's request, objective, or checklist. Queued guidance remains scoped to its owner.

### 3. Separate compilation, tests, runtime behavior, and acceptance evidence

**Confirmed policy limitation.** `verificationCheck` recognizes a `dmd` invocation with a `.d` input as verification. It does not recognize an arbitrary standalone smoke-test executable. The UI can collapse a recognized successful check into a single `verificationStatus = "passed"` when workspace/revision conditions match.

- [Checker classification](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-core/source/auroraopencode/verification.d:65).
- [Single verification status update](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/source/auroraopencode/appui.d:18888).

This conversation also demonstrates the model-level version of the problem. On 15 October at 08:54 it says the browser task is complete and verified; at 09:16 the user reports that the layout is tragically incorrect. Later, green engine/smoke checks coexist with a screenshot showing a still-overlapping wordmark. The transcript proves the acceptance mismatch without needing to assume all individual fixes were wrong.

**Change:** store evidence types and their coverage. A compiler result proves compilation. A registered smoke-test run proves its declared checks. Rendering and interaction requirements need their own results. Completion requires the relevant set, rather than one generic green status. Recognize standalone check executables through a verified project recipe or artifact provenance, rather than guessing from filenames.

**Acceptance case:** compilation alone cannot complete a rendering task. Passing unit tests cannot override a failed visual or interaction requirement. A tested binary older than its source inputs does not supply current evidence.

### 4. Detect stagnation in outcomes, then change approach automatically

**Reproduced policy limitation.** `taskContinuation` hashes successful tools. A distinct query or different read output increases the evidence count and resets the stall counter, even if no requested outcome improves. The isolated probe runs 12 distinct searches returning no matches: each counts as progress, with zero completed outcomes and no verification. A control with an identical repeated query correctly triggers the existing stall detector.

- [Progress and stagnation calculation](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/source/auroraopencode/taskcontinuation.d:60).
- [Probe results](C:/Users/windows10/Documents/github_repositories/aurora-gui/artifacts/browser-conversation-audit/policy-probe-results.json).

Novel investigation can be useful; simply rejecting all new searches would make the agent worse. The missing measure is whether investigation resolves a named uncertainty or changes a failing acceptance result over a bounded diagnostic window.

**Change:** track the active failure, hypothesis, new evidence, attempted fix, and result. After repeated attempts with no improvement, automatically reduce the case, inspect a different subsystem, or request an independent diagnosis. Preserve the user's objective and continue useful work. Reserve user-input blockers for actual missing information or external dependencies.

**Acceptance case:** changed query strings, renamed screenshots, timing noise, and plan rewrites cannot indefinitely conceal an unchanged defect. A reduced reproduction or a genuinely improved outcome permits continued work.

### 5. Establish a browser reference and failing acceptance fixture before patching

**Strong workflow finding.** There are 132 successful image inspections, so screenshot acquisition alone is insufficient. Existing screenshots are frequently compared with previous Aurora output. Byte-identical output proves preservation of that output; it cannot establish that an already-broken baseline is correct. The audit finds no direct Chrome/Edge/Chromium execution in the tool history. Manual reference viewing or opaque scripts cannot be excluded.

**Change:** capture reference behavior at matching viewport, DPI, fonts, theme, resources, and page state. Freeze local HTML/CSS/assets where possible. Record the largest discrepancies and the engine features they depend on. Reduce each defect into a small independently specified rendering or interaction fixture, then retain it as a regression check. Preserve both positive and negative visual evidence through compaction.

A useful loop is: reference behavior → failing small case → root cause → complete fix → focused checks → real-page comparison → current application verification.

**Acceptance case:** a visually broken page cannot become complete because text is readable, elements have nonzero boxes, or unchanged pixels match an earlier broken Aurora screenshot. Interaction checks actually activate links, input, scrolling, and required page state.

### 6. Use a smaller, evidence-focused working context

**Measured opportunity; effect needs an experiment.** The median prompt is about 246k tokens and historical reasoning contributes a median 302k bytes to retained-log requests. Long history preserves useful facts, but also replays rejected diagnoses, repeated conclusions, and obsolete control guidance.

- [History projection includes assistant reasoning](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/source/auroraopencode/requestbuilder.d:85).
- [Compaction activates near the context budget](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/source/auroraopencode/appui.d:20319).
- [Control-history compaction waits for a new human turn](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/source/auroraopencode/controlhistory.d:26).

**Change:** maintain a concise task state, source map, unresolved defects, tested hypotheses, and artifact references. Retrieve the relevant history and source windows when needed. Preserve the full transcript on disk. Compact at coherent work boundaries while keeping stable prefixes between them, and follow provider requirements for reasoning/tool-call continuity.

**Experiment:** compare 64k and 128k working-context targets with the current policy on the same frozen defects. Measure acceptance success, regressions, requests, cache behavior, and elapsed time. A smaller context is a candidate, not an established universal improvement.

### 7. Make build/test/render workflows one native supervised operation

**Measured opportunity.** Thousands of model turns coordinate relatively fast commands. The conversation repeatedly compiles, runs a test binary, compiles another probe, renders, converts PPM to PNG, and loads the result. These dependencies often force serial model decisions even when the command sequence is already known.

**Change:** support named project verification recipes that execute a known dependency graph with progress, cancellation, artifact provenance, and structured results. Batch related edits into coherent stages. Run targeted checks during iteration, then broader checks at integration boundaries or when a regression warrants them. Reuse compiled artifacts only when their source-input hashes still match.

**Acceptance case:** one operation returns build status, relevant test results, a current render, and the recorded defect comparison. A source change invalidates only the artifacts/checks that depend on it. Necessary tests remain intact; provider requests for orchestration are reduced.

### 8. Update plans at meaningful work boundaries

**Measured opportunity.** There are 357 plan calls and 215 progress-guidance messages. The stale-plan threshold is four tool results, although the system prompt asks for plan updates at phase boundaries. Refreshing a plan re-arms the reminder, producing another cycle of low-value maintenance during long tasks.

- [Four-result reminder threshold](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/source/auroraopencode/appui.d:10561).
- [Reminder re-arming and guidance](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/source/auroraopencode/appui.d:18386).

**Change:** make repeated identical state updates no-ops. Ask for a plan update when an outcome completes, evidence changes the approach, a dependency changes, or the plan genuinely diverges from work. Coalesce durable state for requests without deleting historical messages. Keep the checklist useful for resuming rather than a frequent tool-call obligation.

**Acceptance case:** a healthy multi-command verification phase does not repeatedly trigger plan maintenance. A genuinely obsolete plan still receives one actionable correction.

### 9. Add an application-level network inactivity watchdog and better attribution

**Observed incident; root cause remains open.** A request spent approximately three hours without headers or a first token. Current transport code configures WinHTTP timeouts, but waits for completion callbacks without an independent application deadline.

- [OS timeout configuration](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-core/source/auroraopencode/httptransport.d:51).
- [Callback completion wait](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-core/source/auroraopencode/httptransport.d:253).

**Change:** distinguish connect, upload, first-header, stream inactivity, provider retry, and system-suspension intervals. Add an application watchdog for missing progress, with cancellation that preserves callback and handle lifetime guarantees. Keep useful streaming separate from outage recovery. Report suspension separately if detected. Avoid an arbitrary short total-generation limit.

**Acceptance case:** a server that accepts the request but never supplies headers cannot leave the chat opaque indefinitely. Delayed callbacks, cancellation, reconnection, and suspend/resume do not corrupt the stream or replay tool side effects.

### 10. Escalate difficult diagnosis selectively and evaluate the result

**Unvalidated proposal.** The session uses `deepseek/deepseek-v4.1-flash` throughout. It performs substantial real implementation, but repeatedly makes broad correctness claims that the visible result contradicts. A different model may help with architectural diagnosis, spec reasoning, or visual evaluation; changing models alone does not fix workspace evidence or cross-chat control bugs.

**Change:** use an explicitly configured escalation policy for persistent defects or high-complexity design decisions. Give the diagnostic reviewer a compact reproduction, expected behavior, measured failures, and rejected hypotheses. Keep deterministic build/test work in the native runner. Evaluate the reviewer by whether its proposed fix closes an independent acceptance case, rather than the apparent quality of its explanation.

**Acceptance case:** model routing improves acceptance rate or time to a verified fix on the same defect set. Any extra cost and latency are measured. Parallel engineering work is useful only when tasks and source ownership are sufficiently independent.

## Suggested implementation sequence and proof of improvement

1. Correct workspace/evidence ownership and per-thread rebuild resumes. These are concrete client defects and should have focused end-to-end regression cases.
2. Separate evidence types, register project check recipes, and add outcome-aware stagnation recovery. Run synthetic cases through the actual conversation engine, including a chat whose source root differs from its selected project.
3. Build a small frozen corpus from the defects in this session: grid/flex box sizing, text indentation in different formatting contexts, image and background loading, and representative interaction. Specify expected behavior independently of the implementation being changed.
4. Compare current and candidate harnesses from identical starting source/fixtures. Record independent pass rate, regressions, model requests, prompt/cache tokens, native execution time, provider wait, and wall time. Preserve the full raw evidence and compare repeated runs.

The primary metric should be **time to a verified user outcome**, alongside acceptance pass rate. Tool count, successful builds, lines changed, and completed model-authored checklist items are supporting diagnostics.

This is substantial browser-engine work: the session spans native networking, TLS, DOM, CSS, layout, images, SVG, scripting, and application behavior under restrictive implementation/licensing constraints. The audit does not establish that full modern-browser correctness is achievable in a few hours, or quantify a future speedup. It does establish avoidable client loops and a path to testing whether changes improve both speed and correctness.

## Reproduction artifacts

- [Read-only analyzer](C:/Users/windows10/Documents/github_repositories/aurora-gui/artifacts/browser-conversation-audit/audit.py).
- [Measured snapshot and limitations](C:/Users/windows10/Documents/github_repositories/aurora-gui/artifacts/browser-conversation-audit/metrics.json).
- [Production-policy probe](C:/Users/windows10/Documents/github_repositories/aurora-gui/artifacts/browser-conversation-audit/policy_probe.d).
- [Probe build, source hashes, and execution results](C:/Users/windows10/Documents/github_repositories/aurora-gui/artifacts/browser-conversation-audit/policy-probe-results.json).

Run `python artifacts/browser-conversation-audit/audit.py` from the repository root to take a fresh aggregate snapshot. It never writes into live Aurora state. The probe-results JSON records the exact isolated compiler command. The probe compiled successfully and all assertions passed, confirming the stated current-policy behaviors; it does not implement or validate their proposed replacements.
