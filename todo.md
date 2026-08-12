# Aurora Cut todo / complaints log

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
