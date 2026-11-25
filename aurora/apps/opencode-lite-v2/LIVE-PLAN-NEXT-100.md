# Aurora OpenCode V2 — Next 100 Live Development Changes

## Scope and constraints

- One canonical app: `aurora/apps/opencode-lite-v2`.
- No new version folders or duplicate apps.
- Preserve the single visible host + one hidden controller.
- Use the universal component registry for reusable UI; use menu/context-menu actions for secondary commands.
- Each item is a live update, executed in order unless dependencies require regrouping.

## Live update protocol for every step

- Apply source/scene/controller changes in the canonical app and its watched live scene.
- Rebuild only the affected host, controller, or neither when scene-only.
- Reload or restart only what is required; keep one host and one controller.
- Capture the host-painted surface to `build/step-NNN.png`.
- Assert live node IDs, text, bounds, actions, and no unintended clipping through the control tree.
- Run the relevant `verify`/test check. A step is complete only when its live surface and check pass.

---

## Phase 1 — Universal widget foundation (1–10)

1. **Component contract audit** — document and validate `component` props, factory registration, and unsupported-prop errors.
2. **Widget token layer** — centralize spacing, radii, border, shadow, and typography tokens for all universal widgets.
3. **Universal auto-height** — compute minimum height from kicker/title/subtitle and expose it to scene layout.
4. **Universal text-fit policy** — centralize safe line allocation and clipping warnings in one widget helper.
5. **Intentional-clip marker** — support `allowTextClip` on every text-bearing scene node and report marked nodes.
6. **Universal toolbar widget** — a reusable toolbar component with menu, command, and status slots.
7. **Universal badge widget** — reusable compact status/health/model badges without text-symbol states.
8. **Universal empty-state widget** — consistent empty/loading/error cards for conversation, search, and inspector.
9. **Universal dialog widget** — reusable confirmation/rename dialog with keyboard focus and modal action routing.
10. **Widget gallery scene** — a hidden development scene route demonstrating each registered universal widget with live props.

## Phase 2 — Conversation surface (11–20)

11. **Message data model** — role, timestamp, status, content blocks, and stable message IDs outside the raw transcript string.
12. **Message-list component** — replace the transcript text area with a scrollable custom message list.
13. **Message header widget** — role, model, timestamp, and delivery state per message.
14. **Markdown-lite renderer** — headings, lists, emphasis, inline code, and fenced code blocks without raw markers.
15. **Code block component** — protected wrapping, copy action, and language label.
16. **Streaming message widget** — append deltas without reformatting the whole transcript.
17. **Error message widget** — visible failure state with Retry action.
18. **Stopped message state** — explicit cancellation marker and resume/retry action.
19. **Message context menu** — Copy, Retry, Regenerate, Export, and Delete for a selected message.
20. **Conversation empty state** — purposeful prompt examples and provider readiness, not a blank editor.

## Phase 3 — Layout, scrolling, and responsiveness (21–30)

21. **Responsive pane policy** — collapse inspector first, then sessions rail, based on width.
22. **Collapsible inspector** — header control and persisted open/closed state.
23. **Collapsible sessions rail** — header control and persisted state.
24. **Panel divider interaction** — drag boundaries with pointer capture and minimum widths.
25. **Window size persistence** — restore last safe size and never exceed the work area.
26. **DPI scaling audit** — verify layout at 100%, 125%, and 150% scaling.
27. **Transcript scroll persistence** — retain position across scene reload and controller refresh.
28. **Composer bottom anchoring** — keep composer visible at every supported size.
29. **Safe min-size enforcement** — clamp layout and prevent controls leaving the viewport.
30. **Live layout audit** — assert all visible text/control bounds against the logical viewport.

## Phase 4 — Menus and command discovery (31–40)

31. **Keyboard menu access** — Alt/F10 focus and arrow-key navigation through the menu bar.
32. **Session menu grouping** — New, Import, Export, Workspaces, Retry, Regenerate, Shortcuts.
33. **Model menu hierarchy** — Provider → model submenu with checked active entries.
34. **Help menu** — shortcuts, diagnostics, text-fit audit, and About.
35. **Command palette component** — searchable command list as a custom overlay widget.
36. **Command filtering** — fuzzy search by command title and shortcut.
37. **Command keyboard run** — arrows, Enter, Escape, and focus restoration.
38. **Recent commands** — persist and display last five commands.
39. **Context menu everywhere expected** — transcript, composer, session row, and inspector fields.
40. **Shortcut hint layer** — context-sensitive hints without duplicate permanent buttons.

## Phase 5 — Sessions and workspaces (41–50)

41. **Workspace rename dialog** — inline validation and duplicate-name prevention.
42. **Duplicate workspace** — copy transcript and settings into a new slot.
43. **Delete workspace confirmation** — explicit destructive confirmation and cancel.
44. **New workspace naming** — create with a meaningful default name and immediate focus.
45. **Session status indicators** — idle, busy, failed, and unread states on session rows.
46. **Session metadata summary** — message count, model, and last activity.
47. **Per-session provider memory** — restore each workspace’s provider/model choice.
48. **Workspace persistence versioning** — migration for older workspace files.
49. **Workspace filter** — search sessions by name and transcript content.
50. **Startup restore summary** — show restored workspace, model, and pending failures.

## Phase 6 — Provider, model, and credentials (51–60)

51. **Connection validation** — validate URL, model, and key before save.
52. **Model selector component** — popup list with provider grouping and active check states.
53. **Key visibility toggle** — reveal/hide key with explicit user action.
54. **Key replacement confirmation** — prevent accidental overwrite.
55. **Per-provider model memory** — restore last model for OpenCode and OpenAI.
56. **Provider health detail** — last check time, status, and reason.
57. **Connection save status** — persistent timestamped success/failure status.
58. **Default connection reset** — confirmed reset with current-state summary.
59. **Settings migration** — normalize old key/model/base settings safely.
60. **Credential redaction audit** — ensure keys never appear in transcript, logs, or screenshots.

## Phase 7 — Text safety and accessibility (61–70)

61. **Universal text-fit audit** — detect undersized labels, buttons, menus, and component text boxes.
62. **Audit warning surface** — visible count plus first offending node and an intentional marker.
63. **Intentional-clip review** — list every `allowTextClip` node in diagnostics.
64. **Minimum target sizes** — enforce accessible button/menu/row heights.
65. **Contrast audit** — verify text, muted text, disabled, and focus colors.
66. **Focus ring system** — visible keyboard focus on custom widgets and host controls.
67. **Keyboard-only walkthrough** — complete a send/receive/export flow without pointer input.
68. **Accessibility roles** — expose names, roles, and state for custom components.
69. **Zoom-safe typography** — font scaling without overflow or clipping.
70. **Reduced-motion mode** — disable nonessential animation and shadow transitions.

## Phase 8 — Performance and resilience (71–80)

71. **Scene generation handshake** — refresh controller labels only when a scene generation changes.
72. **Batched control updates** — update related node sets in one host transaction.
73. **Incremental transcript updates** — render only changed streaming/message nodes.
74. **Composer event debounce** — coalesce rapid text changes without lost characters.
75. **Font-layout cache** — reuse measured text layouts across repaint.
76. **Repaint budget** — keep interactive click p95 under 25 ms.
77. **Startup budget** — establish and verify window/controller ready-time target.
78. **Memory watchdog** — detect long-run node/message growth.
79. **Controller reconnect** — reconnect or restart without losing the live window.
80. **Scene validation watchdog** — reject invalid scenes, preserve last-good scene, and show a visible recovery warning.

## Phase 9 — Search, history, export, and import (81–90)

81. **Search results widget** — grouped result list with transcript snippets.
82. **Search navigation** — next/previous/result count without stale state.
83. **Search highlighting component** — highlight matches in message widgets.
84. **Prompt history menu** — recent prompts with keyboard selection.
85. **Export progress/status** — queued, writing, written, failed, with path.
86. **Import validation** — file existence, malformed transcript, and safe merge policy.
87. **Automatic session snapshot** — periodic safe snapshot and restore path.
88. **Export format options** — Markdown, plain text, and JSON metadata.
89. **Clipboard actions** — copy message, transcript, and connection diagnostics.
90. **File actions accessibility** — keyboard-driven import/export and clear cancellation.

## Phase 10 — Release quality (91–100)

91. **Golden screenshots** — stable host-painted captures for header, menus, cards, composer, inspector.
92. **Pixel regression checks** — detect clipped text, shifted bounds, and missing components.
93. **Live smoke command** — one command for reload, refresh, capture, audit, and topology.
94. **Recovery runbook** — scene rejection, controller loss, invalid settings, and bad import.
95. **Feature flags** — isolate risky widget/menu changes for live rollback.
96. **State coverage audit** — empty, loading, busy, error, stopped, disconnected, and success states.
97. **Theme/token final pass** — one visual vocabulary across host and universal widgets.
98. **Performance release gate** — startup, click p95, refresh cost, and memory thresholds.
99. **Accessibility release gate** — keyboard, focus, contrast, scaling, and text-fit audit.
100. **Final no-limitations review** — verify every planned live change, screenshot, test, and intentional opt-out; publish the final verified build.

---

## Execution rule

Do not batch arbitrary items into untestable changes. Each numbered item is a separate live update with its own screenshot/tree/check evidence. Adjacent items may share a build/restart when they are one coherent component, but each item must still be independently demonstrated.
