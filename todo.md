# Aurora Cut todo / complaints log

## 2026-08-12 — dshell: D-native replacement for pwd/ls/stat (user request)
- [x] User: "the last missing piece would be to have dshell so we don't use
      all these pwd and other commands." The model still reached for bash for
      plain directory introspection (pwd/ls/dir/stat) in default mode.
- [x] Added the D-native `dshell` tool: `pwd` (print workspace path), `ls`/`dir`
      (list a directory with `[f]`/`[d]` tags and sizes via `SpanMode.shallow`),
      and `stat` (file/directory type, size, modified time). Implemented
      entirely in D with `std.file` — no external shell is ever spawned.
- [x] `dshell` is advertised in BOTH the default and native-only toolsets, and
      the steering prompt tells the model to prefer it for pwd/ls/stat instead
      of bash/cmd/powershell.
- [x] Verified live (both modes): "where am I and what's in the workspace?"
      now calls `dshell pwd` + `dshell ls` then `read`, in 3 rounds with zero
      bash attempts; native mode uses `dshell ls` directly. Tools test covers
      dshell pwd/ls/stat + toolset membership; baseline + Pro debug/release
      builds and all smoke tests pass.

## 2026-08-12 — Model defaults to bash for file ops; native D tools instead (user feedback)
- [x] Reproduced the exact case: "what files are in the workspace?" made the
      model burn 5–6 rounds on `bash dir` variants. Root cause was TWO things:
      (1) cmd's `dir` emits the OEM codepage, so strict UTF-8 `readText` threw
      and the shell tool swallowed real output as "(no output)"; (2) bash was
      the model's default reflex and nothing steered it to the native tools.
- [x] Fixed the shell-output bug: stdout/stderr are now read as raw bytes and
      decoded leniently, so `dir`/`echo %CD%` return real listings. Verified:
      `dir` now returns the actual directory listing instead of "(no output)".
- [x] Added the D-native `run` tool (`program` + `args` array + `workdir` +
      `timeout`) that spawns a process directly — no shell, no quoting, fully
      cross-platform. This is the "our own tools instead of bash/cmd/powershell"
      replacement.
- [x] Added a system-prompt steering message sent with every tools-enabled
      request that directs the model to the native tools (glob/read/write/grep)
      and reserves bash for executables the native tools cannot run.
- [x] Added a "Native tools" toggle (off by default, `Settings.nativeTools`):
      when enabled the bash tool is not advertised at all and the model only
      sees run/read/write/glob/grep, plus the "no shell" steering prompt.
- [x] Verified live: native mode answers "what files are in the workspace?"
      with glob → read in 3 rounds (no shell). Default mode with steering now
      completes the same task in 3 rounds too. Pro tools/smoke tests, baseline
      + Pro debug and release builds all pass.

## 2026-08-12 — Cross-platform tool support (user question)
- [x] Answered the design question with how the original opencode app does it:
      BOTH native host-language tools AND a shell-aware shell tool. The file /
      content tools (read/write/glob/grep) are native D, so they are
      cross-platform by construction (no shell dependency). The single shell
      tool ("bash") is shell-aware per platform instead of being a separate
      cmd / powershell tool.
- [x] The `bash` tool now accepts `shell` (`auto`/`bash`/`cmd`/`powershell`/
      `pwsh`), `workdir`, and `timeout` parameters, and its description carries
      per-platform usage notes so the model writes valid syntax (dir/type/%VAR%
      on cmd, Get-ChildItem/$env: on PowerShell, ls/cat/$VAR on bash).
- [x] Execution switched from `spawnShell` (which silently wrapped everything
      in cmd /c) to `spawnProcess(argv)` with stdout/stderr redirected to a
      temp file and an explicit `workDir` — no per-shell quoting fragility, and
      hanging commands are still killed on timeout.
- [x] Verified on Windows: cmd, powershell, and workdir all round-trip; the
      live model loop now reads/globs correctly instead of emitting `ls -la`
      that fails on cmd. Pro tools test + smoke test, baseline + Pro debug and
      release builds pass.

## 2026-08-12 — Aurora OpenCode Pro "Edit & resend" stopped working (user complaint)
- [x] Diagnosed: the action-pill delegates were created inline inside the
      `foreach` over `_messageColumn.children()` in `refreshBubbleActions` (and
      the right-click `onEditRequested` in `rebuildMessageColumn`). D captures
      the reused `foreach` loop slot by reference, so EVERY bubble's pill was
      bound to the final message index. Clicking "Edit & resend" on an early
      user bubble silently targeted the last message (role mismatch → no-op).
- [x] Reproduced with a headless probe: `onMouseDown` on the pill returned
      `handled=true` but the callback edited the wrong message. Confirmed the
      D behavior with a minimal closure test (even a `const` local copy in the
      loop still captures the shared slot; only a factory function works).
- [x] Fixed with delegate factories `regenerateAction(sessionIndex,
      messageIndex)` and `editResendAction(...)` that bind the indices as
      parameters, mirroring the font-menu fix already documented in
      `AURORA-PATCHES.md`.
- [x] Added regression coverage that invokes a bubble's pill through the real
      captured delegate (`invokeBubbleActionForTesting`) and asserts it edits
      that bubble's own message. Pro smoke test, baseline + Pro debug/release
      builds pass.

## 2026-08-12 — portable-release link fails on this machine (libcmt.lib missing)
- [ ] `dub build --build=portable-release` fails with
      `lld-link: error: could not open 'libcmt.lib'` for **both** baseline and
      Pro (identical configs). `libcmt.lib` (MSVC static CRT) is not installed
      anywhere under `C:\D`. Debug builds and the headless/tool smoke tests
      (compiled with dmd -i) all pass. To restore release builds either
      install the MSVC Build Tools/CRT so `libcmt.lib` is findable, or change
      the `-mscrtlib=libcmt` policy in the `portable-release` buildTypes.

## 2026-08-12 — Aurora OpenCode Pro context-usage meter (user request)
- [x] Researched how the real opencode app meters context usage
      (`anomalyco/opencode`): it uses the **exact** provider `usage` object per
      assistant message (`tokens: {input, output, reasoning, cache:{read,
      write}}`) shown as `total / model.limit.context` percent, updating per
      step-finish — there is no live mid-stream estimate. The only local
      approximation is `chars/4` (`packages/core/src/util/token.ts`) used for
      compaction/overflow and the estimated breakdown bar. The context limit
      comes from provider metadata.
- [x] Pro toolbar now has a small rectangular `ContextUsageBadge` (fill bar +
      percent of the model's context window) that opens a hover
      `ContextUsageTooltip` with the full breakdown (model, limit, used,
      prompt, completion). The tooltip never steals the pointer (its `hitTest`
      reports the badge while hovered).
- [x] Shared client pushes a live `usage` event when the provider reports token
      counts mid-stream; the `done` event records final
      prompt/completion/total on `ChatMessage` (persisted in `sessions.json`).
      `contextLimitForModel()` in core mirrors `model.limit.context` from the
      **official opencode catalog** (`https://models.opencode.ai/api.json`,
      what the CLI itself fetches): deepseek-v4-flash/pro = 1M (user caught the
      old 128K fallback), gpt-5.6-luna 1.05M, qwen3.8-max/glm-5.2 1M, grok-4.5
      500K, kimi-k3 1,048,576, minimax-m3 512K, mimo-v2.5-pro 1,048,576,
      hy3 256K, unknown 128K.
- [x] Badge refreshes on `usage`/`done`, session switch, model picker, restore,
      and delete; shows `ctx` until usage is recorded. Covered by the Pro
      headless smoke test (empty state, 37% at 47213/128000, hover tooltip
      rows, leave dismissal, follows active session) + pixel-verified
      screenshot.

## 2026-08-12 — Aurora OpenCode Pro tool use support
- [x] Studied the original opencode app's tool architecture (built-in tools:
      bash/shell, read, write, glob, grep, webfetch, websearch, question, task,
      todo, skill, apply_patch, lsp, plan; registry + permission model) and
      confirmed the exact wire format the `/chat/completions` endpoint uses
      with a live probe: tool calls arrive as `delta.tool_calls` fragments
      (index, id, function.name, streamed function.arguments) and end with
      `finish_reason: "tool_calls"`; results are sent back as `role: "tool"`
      messages with `tool_call_id` and the loop repeats until `finish_reason:
      "stop"`.
- [x] Core client (`aurora-opencode-core/opencode_client.d`) now supports
      tools: `startChatMessages` (structured `ChatRequestMessage`[] +
      `OpenCodeToolDef`[]), SSE `delta.tool_calls` accumulation across
      fragments, a `toolCalls` terminal event, and `pushLocalEvent` so tool
      results ride the same event queue the UI drains each tick.
- [x] Shared data model extended: `OpenCodeToolCall`, `OpenCodeToolDef`,
      `ChatRequestMessage`, `ChatMessage.toolCalls/toolCallId/toolName`,
      `Settings.toolsEnabled/workspace` (persisted).
- [x] Pro tools module (`aurora-opencode-pro/auroraopencode/tools.d`):
      bash (cmd shell, 60 s kill timeout, temp-file output capture),
      read, write, glob (`**` recursive via own glob→regex), grep, all with
      opencode-mirroring JSON schemas.
- [x] Pro UI tool loop (`appui.d`): "Tools" checkbox in the toolbar, workspace
      path in Settings, tool-call chips on assistant bubbles, `tool` role
      result bubbles, a worker thread executes the batch and feeds results
      back, history (assistant tool_calls + tool results) is re-sent until the
      model answers with text (12-round cap), session persistence + export
      include tool calls/results.
- [x] Baseline client unchanged in behavior: it never advertises tools, and its
      `final switch` handles the new event kinds as no-ops.
- [x] Tests: `aurora-opencode-core/tests/tool_sse_test.d` (fragment
      accumulation + body serialization), `aurora-opencode-pro/tests/
      tools_test.d` (executors), Pro headless smoke extended to run the loop
      offline. Verified live: real API tool loop returns the expected result
      (`sum(1,2) -> 3`; workspace glob→read→summary) with clean `errors.log`.
      Baseline + Pro debug/release builds and smoke tests pass.

## 2026-08-12 — Aurora OpenCode Pro chat-quality actions
- [x] Regenerate/Retry: the last assistant bubble drops the reply and re-runs
      the request with the remaining history ("Retry" when it failed).
- [x] Edit & resend: user bubbles (footer pill or right-click) truncate the
      conversation at that message and prefill the input.
- [x] `ChatMessage.failed` persisted; shutdown-induced request cancellations
      are no longer logged as errors. Covered by the pro smoke test; baseline +
      Pro release builds pass.

## 2026-08-12 — Aurora OpenCode must use the real opencode API, not the demo
- [x] Clarified that `opencode-api.boqsc.eu` is only a test/demo web client;
      the real backend is the opencode API itself (`https://opencode.ai`).
- [x] Pointed the shared core at the real Go-plan endpoint
      (`https://opencode.ai/zen/go/v1`), read the key from the real opencode
      CLI auth store (`~/.local/share/opencode/auth.json`), added a browser
      `User-Agent` (Cloudflare returns 1010 otherwise), and switched thinking
      off to the standard `reasoning_effort: "none"` (the demo proxy used to
      translate a `thinking: false` boolean the real API rejects).
- [x] Removed the loopback/demo-proxy fallback that was built on the wrong
      assumption. Verified live: the smoke test's real chat returns the exact
      `AURORA-OPENCODE-GUI-OK` reply with a clean `errors.log`; baseline + Pro
      debug/release builds and smoke tests pass.

## 2026-08-12 — Aurora OpenCode must not depend on the public opencode-api host
- [x] Diagnosed `WinINet error 12029/12002`: the public `opencode-api.boqsc.eu`
      is unreachable from inside the LAN (NAT hairpin / firewall) even though
      the local `web_webserver` serves the same domain on `0.0.0.0:443` and
      DNS resolves to the machine's own public IP.
- [x] Integrated the local `opencode-api` mirror into the shared client
      (`aurora-opencode-core/opencode_client.d`): every request first tries a
      loopback mirror (`127.0.0.1`, same port/path, real `Host:` header, TLS
      hostname errors ignored for that attempt only), then falls back to the
      configured public host. HTTP/stream errors never trigger the fallback.
- [x] Verified live: the smoke test's chat now returns the exact expected reply
      with zero entries in `errors.log`; debug + release builds of baseline and
      Pro pass.

## 2026-08-12 — Aurora OpenCode runtime error logging (user request)
- [x] Added a shared thread-safe `auroraopencode.logging` module writing
      timestamped entries to `<state dir>\logs\errors.log`, with a per-launch
      banner line so each launch is easy to inspect.
- [x] Both clients wire it up at startup; chat/models request failures (e.g.
      WinINet 12029 cannot-connect), settings load/save failures, and session
      persist/restore failures are all logged. Verified by the smoke runs:
      the live API calls logged 12002 timeouts, confirming the reported 12029
      is a server-connectivity issue with `opencode-api.boqsc.eu`, not a bug.

## 2026-08-11 — Aurora OpenCode baseline vs extended version (structure)
- [x] Split Aurora OpenCode into `aurora-opencode-core` (shared library:
      `opencode_client.d`, `markdown.d`, `core.d`), `aurora-opencode`
      (baseline, unchanged UI), and `aurora-opencode-pro` (extended client with
      its own `appui.d`). Both clients depend on the core package by path.
- [x] Registered `aurora-opencode-pro` in `scripts/build-portable-windows.py`
      and the portable-windows CI artifact list; both new `dub.json` manifests
      carry the portable-release CRT policy.
- [x] Baseline debug/release builds and the headless smoke test pass with the
      new layout.
- [x] Layered the first Pro-only batch into `aurora-opencode-pro`: conversation
      delete (context menu + Delete key), rename dialog, title filter box,
      per-message and code-block Copy buttons, clickable Markdown links,
      message timestamps, token-usage status, and `.md` export. Covered by the
      new `headless_pro_smoke.d` test.
- [ ] Still ahead for Pro: conversation search across content, table Markdown,
      system prompt / temperature / max-token settings, multiple API profiles,
      retry/regenerate, syntax highlighting, tray support, and theme/font
      settings. Keep `aurora-opencode` as the standalone basic client.

## 2026-08-11 — Aurora OpenCode startup conversation scrollbar (user complaint)
- [x] Diagnosed the restored active conversation being selected before the
      sidebar had a real viewport. Selection visibility used height zero and
      initialized the conversation list offset near its bottom.
- [x] Restored the active selection without pre-layout auto-reveal and added a
      regression covering 25 restored sessions with the last one active.

## 2026-08-11 — Aurora-wide scrolling and native drag/drop
- [x] Enabled extended Windows scroll input and native range semantics by
      default; native scroll commands activate the retained scroll target under
      the pointer before reading its range.
- [x] Migrated `ScrollView`, `ListView`, and multiline `TextEditor` to real
      retained child `Scrollbar` widgets.
- [x] Added a platform-neutral rich drag/drop payload, action negotiation,
      widget dispatch, outbound API, and deterministic test-driver support.
- [x] Added Windows OLE inbound/outbound files, Unicode text, URI list,
      HTML/custom MIME, and copy/move/link support. File Manager transitions to
      the OS drag session when a file drag crosses its host-window boundary.
- [ ] Fundamental widgets (`RadioButton`/group, `ComboBox`, `TabView`,
      `TreeView`, `TableView`/data grid, tooltip, menu bar) are deliberately
      deferred until Aurora has an agreed styling/perspective. Revisit directly
      after the scrolling/drag-drop stabilization pass; do not let this remain
      an open-ended postponement.

## 2026-08-11 — Windows File Manager mouse/touchpad scroll (user complaint)
- [x] Added a real reusable `aurora.widgets.scrollbar.Scrollbar` widget.
- [x] Replaced the file manager's embedded list/sidebar scrollbar painting and
      drag logic with retained child scrollbar widgets.
- [x] Added Win32 wheel, pointer-wheel, gesture, and `WM_VSCROLL` input paths.
- [x] Added a synchronized native scroll-range contract for legacy drivers;
      `WM_NCCALCSIZE` leaves no visible native scrollbar area, so Aurora's
      custom widget remains the only rendered control.
- [x] Kept ordinary click-to-focus behavior and removed hover activation,
      synthetic focus input, raw-input duplication, and registry workarounds.
- [x] Added deterministic widget/file-manager tests and a native focus/range/
      exact-delta probe. Release build and both verification paths pass.


## 2026-08-11 — Window resize: stretched image / white blinking / freeze (user complaint)
- [x] Diagnosed the complete OpenCode path rather than only the native border
      message. Three independent problems were involved: the Windows launcher
      selected a debug build, long Markdown/code conversations took about
      650 ms to reflow, and Vulkan treated the expected live-resize
      `VK_SUBOPTIMAL_KHR` result as a request to recreate the swapchain.
- [x] `aurora.window`:
  - `WM_SIZE` stays constant-time, while timer-driven exact layout/paint frames
    reflow the newest size at a 60 Hz target on scaling-capable Vulkan drivers.
  - WSI keeps the last complete frame covering the surface between exact
    frames, so there is no unpainted/white client area.
  - Application polling/ticks remain outside Win32's modal sizing loop.
- [x] `aurora.render.vulkan`:
  - `recreateSwapchain()` no longer calls `waitForSubmittedFrames()` (was a GPU
    stall / freeze on every resize frame) and no longer destroys the old
    swapchain's present semaphores/framebuffers/views while a present is in
    flight (was the white flash). Old swapchain resources are now *retired*
    and reclaimed only after a newer swapchain has presented (`oldSwapchain`
    passed to `vkCreateSwapchainKHR`).
  - Geometry buffers are versioned (fresh allocation per revision, old buffers
    reclaimed after in-flight frames pass) so a live resize no longer forces
    `availableFrame(requireAllIdle=true)` → `vkWaitForFences(ulong.max)`.
  - Reduced post-recreation acquire timeout 16 ms → 2 ms.
  - `VK_SUBOPTIMAL_KHR` is accepted during scaling-enabled live resize instead
    of invalidating and recreating the swapchain inside the drag.
  - The exact final frame is presented immediately through the valid scaling
    swapchain; native-resolution recreation waits for presentation fences to
    become idle, avoiding the driver's occasional 100–450 ms release stall.
- [x] OpenCode Markdown flow is now width-independent at the shaping layer;
      fenced-code line layouts and Markdown output storage persist across
      widths. Measured reflow dropped from about 652 ms to normal 1–4 ms scene
      builds, with the observed live maximum below 8.5 ms.
- [x] `RUN-WINDOWS.bat` and `RUN-WINDOWS-SOFTWARE.bat` now launch release builds.
- [x] Final automated human-paced Vulkan resize: 97 exact live frames over 120
      size changes; resize p95 6.61 ms, max 9.40 ms, zero calls above 16 ms;
      post-resize p95 0.31 ms and max 14.10 ms.
- [ ] Final feel still needs confirmation from the user's real mouse drag and
      monitor/driver combination.

## 2026-08-10 — Sequence resolution matched to a timeline item
- [x] Implemented context-menu command "Set sequence resolution to NxN" on
      video clips (crop-aware), updating the composition/output resolution.
- [x] Verified via headless editor smoke test (menu wiring + action) and
      `dub build --force`; all editor/model/gpu-decode smoke tests pass.
- [x] Output resolution auto-follows the sequence resolution (MP4 export uses
      the composition canvas); preview quality stays a separate responsiveness
      cap. Design answer: yes, output defaults to the sequence resolution.
- [ ] Not yet manually tested in the running GUI / with Playwright screenshot.
- [ ] Not yet manually tested with a non-16:9 or portrait clip in export.

## Notes / open items found while working
- Pre-existing uncommitted work in the working tree (NOT mine):
  - `source/auroracut/ytdlp.d` + `source/auroracut/editor.d`: yt-dlp download
    progress labels ("Download X%", "Processing…", "Normalizing X%").
  - `aurora-opencode/source/auroraopencode/opencode_client.d`.
  - Untracked `aurora-image-viewer/` directory.
  Confirm whether these should be committed/continued.

## 2026-08-10 — Aurora Image Viewer (aurora-image-viewer)
- [x] Built a standalone image viewer in `aurora-image-viewer/` using Aurora-D
      and a custom mipmapped CPU scaler (performant pan/zoom, no aliasing on
      zoom-out, opaque retained compositor layer).
- [x] Complaint addressed: "avoid ffmpeg and it be standalone" — replaced the
      ffmpeg/ffprobe decode path with pure-D decoders for PNG (Aurora-D),
      BMP (24/32/16/8/4/1 bpp + BITFIELDS + RLE8/RLE4), TGA (truecolor/gray/
      colormap + RLE), PNM (P2/P3/P5/P6/P7) and GIF (first frame, LZW).
      No ffmpeg/ffprobe/pipeProcess anywhere in the app now.
- [x] Fixed: ffmpeg decode inside the loader thread crashed the headless UI
      test (process exited 0 silently). Removing the subprocess decode fixed it.
- [x] Headless smoke test passes (scaler + all decoders + UI wheel/fit/drag/
      drop/screenshot). `--screenshot` renders correctly (verified pixel
      colors: bright image center, dark UI chrome).
- [ ] Not yet manually launched as a real window / Playwright screenshot.
- [ ] JPEG/WebP/TIFF not supported (standalone constraint). If needed later,
      implement native decoders or add a documented opt-in ffmpeg path.
- [ ] Checkerboard/alpha, rotate, slideshow, EXIF orientation not yet added.

## Notes / open items found while working
- Preview decode surface is fixed 16:9 (`recommendedDecodeSize`), so a
  non-16:9 composition can appear stretched in the live preview even though
  export renders the correct canvas. Existing limitation, not introduced here.
