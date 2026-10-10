# Chat presentation

## Default: classic transcript; redesign is opt-in

The classic transcript before commit `4880315` is the default presentation:
original assistant thinking and prose, original collapsible tool groups, and the
latest-action tail behavior. No experimental activity batch wraps these rows.
Unrelated correctness and history fixes remain in place.

Settings includes **Highly experimental chat redesign**, off by default, persisted
as `experimentalChatRedesign`. Switching immediately rebuilds the presentation
without altering stored messages, branches or versions. The experimental layout
retains compact activity disclosures, nested Thinking indentation and the lighter
background for first-level expanded activity. Disabling it restores intrinsic
row visibility and normal tool-group behavior and removes presentation-only
reasoning copies from search routing.

Default-off, both switch directions, search, reload, and history checks passed
in `build/architecture-checks-j7o9ldjr/`. The default screenshot is
`build/chat-classic-default-review.png`.

## Experimental: chronological conversation

Original assistant prose is shown once at the chat edge, in message order. There
is no outer turn container, opening-sentence header, mirrored commentary, nested
guide line, or whole-turn collapse. One compact activity disclosure between prose
updates holds settled tools and reasoning. Its category wrappers remain flat;
expanding the row shows actions directly. Final-answer reasoning joins the
preceding activity so the final answer remains the last prose row. Plain replies
do not acquire empty activity disclosures.

Reasoning details use retained presentation widgets while original message records
remain unchanged. Tool and reasoning search reveals the containing activity row.
Prose keeps its original selection, context menu, branch navigation and reply
controls. Current progress, live tools, exact-retry recovery, chat scroll anchors
and saved history remain supported.

The sections below record earlier iterations and verification, not the active
outer-turn design.

## Previous iterations


## Flatter activity details

Within settled activity batches, action category containers are presentation-only:
their headers and indentation are suppressed and their action rows are immediately
visible when the batch opens. Individual outputs/diffs keep their disclosure
controls. Batch content shares the commentary inset and does not add a second
guide line. Live groups retain their existing progress visibility and controls.
The retained category containers still preserve tool ordering, original widgets,
search reveal, history and resume controls. Their flat presentation is reset
before each projection so a retained widget reused outside a batch behaves normally.

Verified by `build/architecture-checks-kb98k1sf/`: flat headers and action bounds,
shared indentation, batch choices, search, live progress, and saved history.


## Commentary timeline and activity batches

Delivery verified: full detailed UI smoke in `build/architecture-checks-s9d7blpz/`;
compact defaults, exact-retry recovery, search, chat consistency and history
preservation in `build/architecture-checks-18r_46b6/`. The rebuild helper completed
in 50.227 s and relaunched a responsive app. Forge publication and public download
verification passed. The production executable passed four provider/native-tool
round trips in `build/production-roundtrip-hstrpj61/`. Release delivery measurements
in `build/architecture-checks-58v85nyo/`: six token-to-paint samples, median 5.010 ms,
maximum 12.486 ms, excluding the fixture's intentional 100 ms provider wait.


Turns remain expanded by default. Between commentary updates, original reasoning
and action rows now live in a compact activity batch that starts collapsed. Its
single-line label summarizes the recorded actions, without timings, token stats,
raw commands or paths. Expanding the batch reveals the original widgets and all
of their detailed disclosures. Search opens both layers. Manual expansion choices
are retained during rebuilds. Consecutive tool rounds without commentary share a
batch; a new commentary update starts the next batch.

The opening sentence appears once in the timeline, as the turn header. Remaining
commentary uses retained, selectable markdown widgets with the original message
context menu. Original messages stay in details and in the saved message graph.
Completed assistant replies show Regenerate; Continue is reserved for unfinished
turns. Active tool rows remain visible while running, and settle into the compact
batches when completed.

Failed operations are excluded from successful action summaries and use their
specific tool title (for example, “Create folder failed”). A subsequent successful
retry with identical recorded tool name and nonempty arguments marks that failed
attempt “recovered”; a different operation does not imply recovery. The full error
and original failure styling remain available inside details.


## Immediate live headings and hierarchy

Delivered through the rebuild helper (92.083 s), with a responsive relaunched
production app and a verified public Forge download. Production HTTP/SSE + native
tool round trips passed in `build/production-roundtrip-n1k4k1w4/`. Immediate/live
heading tests passed in `build/architecture-checks-vkjnc6c1/`, full UI smoke in
`build/architecture-checks-flth5z9h/`, and chat/history contracts in
`build/architecture-checks-8lfv4ipi/`. Release GUI delivery passed in
`build/architecture-checks-cnv5jsru/`: six token-to-paint samples, median 5.217 ms,
maximum 9.784 ms, excluding the fixture's intentional 100 ms provider wait.


A busy request now gets an expanded “Starting your request…” header immediately,
including before chatBegin or provider text. The first assistant sentence replaces
that placeholder incrementally without rebuilding the transcript per token. The
provider still determines when actual text arrives; no extra generation request
is made for a title. Details are inset 18 px with a vertical guide. Nested action
groups open by default and preserve manual collapse choices. Individual outputs,
diffs and reasoning retain their independent disclosures. Active tools and wait
indicators remain visible outside folded history.

Reference: the public Codex terminal UI separates committed history from a mutable
active cell and renders a live tail immediately:
https://github.com/openai/codex/blob/main/codex-rs/tui/src/chatwidget.rs
and https://github.com/openai/codex/blob/main/codex-rs/tui/src/chatwidget/rendering.rs.
This reference is terminal UI source, not the desktop application implementation.


Opening-sentence update verified in `build/architecture-checks-g00ankuu/`:
turn summary, full headless UI, chat consistency and history preservation checks
passed. Tests cover initially expanded working turns, retained opening text,
expansion through completion and manual collapse through streaming/completion.
The release helper rebuilt and relaunched a responsive app; binary SHA-256 is
`b9fa3b51c0e40f996a7833d069a164069d842556d29ad25254f77b0d1b7a8621`.
Publication and public download verification succeeded. The production image
passed `build/production-roundtrip-pp41xo3p/`. Optimized GUI delivery with Vulkan
requested passed `build/architecture-checks-6zechemo/`: six token-to-render samples
had a 2.034 ms median, excluding the fixture's intentional provider wait.

The transcript groups intermediate assistant rounds beneath a clickable opening
sentence for each visible user request. Turns start expanded and stay expanded
through completion unless the user collapses them. The final answer remains
outside the details. Plain conversations keep their normal layout.

The header uses the first sentence of existing assistant prose, with a
Unicode-safe length limit for unusually long introductions. When no opening
prose exists, it uses **Activity and notes**. Status, action counts and optional
timing appear as secondary text, preserving the opening as work progresses.

- Current tool rows and provider activity remain visible outside folded history.
  The latest completed tool group also stays visible until a final answer arrives,
  preserving its Continue/Regenerate controls after an interruption.
- Expanding a summary reveals the original chronological commentary, reasoning,
  action groups, commands, outputs and diffs. No message records are merged or
  deleted; branch navigation and provider request projection retain their history.
- Summary rows are retained across projections. Expansion choices survive
  streaming refreshes and switching chats. Search opens both the enclosing turn
  summary and any nested tool group containing its match.
- Summary counts distinguish recorded tool actions from distinct normalized paths
  targeted by successful file operations. Repeated edits to the same path count
  once. Action-group labels count actions rather than claiming every read/search
  or patch call represents one distinct file. Commands are counted without
  implying they passed verification.
- Failed tool counts remain visible in the summary. The current interrupted turn
  is labeled as retained stopped work; a failed turn needs attention. The optional
  settled duration appears in the summary and its expanded completion boundary.
- Header text wraps in narrow columns and supports mouse, Enter and Space.

The existing presenter also measured unknown offscreen rows eagerly. Unknown
heights now retain estimates until their rows reach the viewport or overscan.
The 250-row fixture initially constructed 20 rows; the 10,000-row scrolling fixture
constructed 134 across its sampled viewports. These are isolated fixtures, not
production frame-rate claims. Complex expanded tool groups retain their existing
eager construction behavior.

## Initial verification and delivery

All six fixtures passed in `build/architecture-checks-m0x7svjk/`:
`turn_summary_contracts`, `headless_pro_smoke`, `chat_consistency_smoke`,
`history_preservation_contracts`, `chat_performance_contracts`, and
`presentation_contracts`. The new fixture includes distinct-file counts, retained
row identity, expansion, search reveal, history reload and narrow measurement.

The helper rebuilt the release successfully in 72.892 seconds and relaunched a
responsive desktop process. The binary is newer than the package sources.
SHA-256: `0576c579f585027cb641d61bd20a38847a0eb4f39a81d0ad69de7e4267bc0384`.
Forge publication and the public download were verified, including a subsequent
`python tools/publish-forge.py --required` check with publication skipping unset.

The rebuilt production image passed four real local HTTP/SSE rounds, native tools,
request pairing, final settlement and persistence:
`build/production-roundtrip-b5uz2upf/`. Transport contracts passed in
`build/architecture-checks-gnnvuiy3/`; six native GUI deliveries passed in
`build/architecture-checks-co1_qpu_/`. Provider latency in these fixtures includes
an intentional 100 ms delay and is separate from client delivery overhead.

After relaunch, optimized native GUI delivery with Vulkan requested passed in
`build/architecture-checks-svvuckgk/`: six token-to-render samples had a median of
2.705 ms and maximum of 8.697 ms; 40 native worker notifications had a median
of 0.061 ms. Rendering means submission, not display scanout. These local samples
do not establish production network latency or a universal minimum.

## Straightforward chronological chat delivery — 2026-10-10

Removed the outer turn panel and generated opener. Original assistant prose stays
in chronological order at the main chat edge, with compact expandable activity
rows between updates and the final answer after its activity. Reasoning and tool
search still reveal their activity; stored messages and history remain intact.

The final source passed headless UI, turn summary, chat consistency and history
preservation checks in `build/architecture-checks-wnxx3ijf/`, including legacy
unowned tool results. The detached helper rebuilt the release in 92.605 seconds
and relaunched a responsive app. The executable is newer than all package sources.
Forge publication and public download verification passed with skipping unset.
The production executable passed four HTTP/SSE rounds, native tools, pairing and
settlement in `build/production-roundtrip-0wquq2_z/`.

Release native GUI delivery passed in `build/architecture-checks-6sjxyhj_/`:
six token-to-render samples measured 3.979 ms median and 12.091 ms maximum.
These are client delivery measurements; the fixture's intentional 100 ms provider
wait is separate. Rendering measures submission rather than display scanout.

## Classic-default delivery verification

The detached helper rebuilt and relaunched the responsive production app in
80.268 seconds. The binary is newer than Pro and Core sources. Required Forge
publication and public download verification passed. Production HTTP/SSE, native
tools, pairing and settlement passed in `build/production-roundtrip-0cz875g1/`.
Six release native GUI delivery samples in `build/architecture-checks-r0_tm_pp/`
measured 2.396 ms median and 11.585 ms maximum from token receipt to render
submission, separate from the fixture's intentional 100 ms provider wait.
The user's saved settings had no experimentalChatRedesign opt-in at relaunch.
