# Chat turn summaries

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
