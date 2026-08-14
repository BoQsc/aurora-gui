# Testing Progress and Methods (Aurora Cut)

## Aurora Stream: VLC composed-window correction (2026-08-14)

- User's 0.66.0 screenshot proved that the supposed VLC "screen" fallback still
  used the HWND GDI surface: VLC chrome painted, the Direct3D video stayed black,
  and an unpainted child/UI area stayed white.
- VLC selection now routes preview and broadcast to its visible client rectangle
  on the composed desktop. The rectangle is clipped to the virtual screen (the
  observed VLC restore geometry was x=-4 and extended below 1080p), then captured
  through a Desktop Duplication region or cropped `gdigrab desktop` fallback.
- The headless clipped-GDI probe returned the exact 1532×710 BGRA byte count
  (4,350,880) with 31.8% non-black pixels. D unittests exercise VLC selection,
  DDA/GDI argument construction, black-frame probe rejection, label matching,
  geometry failures, and the preview's visible-screen-DC branch.
- The bundled 0.66.0 FFmpeg exposed the packaging bug: `ddagrab` was configured
  as an input device even though FFmpeg implements it as a source filter. The
  build flag, Actions inventory assertion, and portable payload gate are fixed.
- `dub test --compiler=dmd --force` passes all 45 modules; forced x64 debug
  `application` and `notitlebar` builds pass. Direct/FIFO RTP+SDP, transport,
  output isolation, synthetic audio, GUI/static-CRT policies, and both 720-frame
  loaded A/V phases pass. The rebuilt minimized BGRA/RGBA/RGB10 hook matrix also
  passes with zero production drops/gaps.
- Minimal-FFmpeg Actions run #16 (`31833093268`) compiled `vsrc_ddagrab.o`,
  passed the explicit inventory, and produced artifact SHA-256
  `17c51737afb30eec18b4d4dd20498183672be9b16636740cf3cce56f1a3cdf55`.
  Portable Windows run #39 (`31833093342`), attempt 2, accepted that new
  payload, rebuilt the D-only hook and all single-exe applications, passed the
  static-CRT checks, and produced artifact SHA-256
  `67bffc2a7e926cfec23ad9ca6c6ffa150716f1564779497d99989c468bbd9e53`.

## Aurora Stream: D3D11 game-capture release integration (2026-08-14)

- `dub test --compiler=dmd --force` passed all 45 modules. Forced x64 debug
  builds passed for both `application` and `notitlebar`.
- The optimized standalone D-only hook built with `-betterC`,
  `/NODEFAULTLIB`, and `/ENTRY:gamecaphookEntry`; no C compiler is involved.
- The final background-only 1920×1080 harness matrix passed BGRA8, RGBA8, and
  RGB10A2. Each format completed two injection → capture → restore → self-unload
  rounds and a third round through the production `GameCaptureSession`. Manual
  rounds delivered 236–237 non-black/color-correct frames in four seconds; the
  production reader received 238–239. Final production metrics had zero hook
  drops and zero sequence gaps for every format.
- The 72-byte v2 protocol covers ready/frame/error messages, QPC timestamps,
  source DXGI format, cumulative drops, sequence validation, and bounded shared
  BGRA8 slots. The named pipe carries headers only. Settings cover persisted mutually-exclusive game
  and PrintWindow modes; broadcaster tests require raw BGRA stdin.
- Present submits reusable asynchronous GPU copies and performs only a
  nonblocking readback/CPU-slot handoff. Channel conversion and named-pipe I/O
  run on the hook worker. Both hook and host use bounded latest-frame queues;
  Aurora duplicates the held image on exact 60 FPS cadence for A/V stability.
- The portable staging helper passed. A verified minimal-FFmpeg Actions artifact
  (SHA-256 matched GitHub's artifact digest) allowed the complete local
  `--single-exe` workflow to reach the final link. This DMD installation lacks
  `libcmt.lib`. Official Windows Actions run #37 (`31830461788`, commit
  `081ece8`) supplied the release toolchain, built the optimized D-only hook and
  all single-exe applications, passed every PE static-runtime check, and
  produced the 27.4 MB `aurora-windows-portable` artifact (SHA-256
  `b2c53367506888071127fa1ef89aaea0bf0eb00add4f0bf5f55b2b827abd2730`).
- No authenticated YouTube stream or fullscreen foreground test was run.

## Standard-flow verification and non-interference rule (2026-08-14)

- Headless checks passed: `verify-audio-transport.py`, `verify-rtp-sdp.py`
  (direct + FIFO FLV), `verify-network-output-isolation.py`,
  `--audio-bridge-session-test --synthetic`, endpoint JSON parsing, and
  `dub test` (44 modules).
- `run-quality-diagnostic.py --loaded-audio` passed both phases: 720 frames
  each, final speeds 1.020x and 0.996x, no queue/RTP/pacing/send failures.
- Actual VLC validation was performed without fullscreen: the existing VLC
  HWND playing a real video was captured through the normalized gdigrab chain;
  1920×1080, 60/1, 300 frames, exactly 5.000 seconds, and no timestamp
  warnings. The raw unnormalized probe produced repeated DTS warnings; the
  production `fps/settb/setpts/scale/pad` chain removed them.
- GUI diagnostic stdout was fixed to preserve inherited subprocess pipes;
  endpoint JSON now parses and the loaded-audio diagnostic completes normally.
- The full visual harness was stopped because it opens a fullscreen test card
  and interferes with normal desktop use. It is not accepted as passed. Future
  autonomous validation must be headless or explicitly backgrounded/minimized;
  no fullscreen interactive test may be launched without user approval.

## Aurora Stream: improved always-on activity logging (2026-08-14)

User request: "can we improve logging so that final release of aurora stream
would show exactly what errors and what problems happen and what actions are
taken, so we know exactly how to resolve things once problems appear or target
things faster and resolve faster."

Implemented: the always-on `aurora-stream-activity.log` (beside the exe, same
folder as `aurora-stream-startup.log`) is now the single session-spanning
record of what happened and what the app did about it. Every line carries a
severity tag:

- `[INFO]` normal lifecycle: version at startup, encoder/capture selection,
  settings load/save, stream start (with destinations + encoder + capture),
  FFmpeg launch attempts, update available, audio device inventory.
- `[WARNING]` recoverable problems: D3D11-direct-to-NVENC probe fail (CPU path
  fallback), audio scan errors, UDP -10048 bind race, FFmpeg warning lines,
  silent audio endpoint, stale/minimized capture-window fallback.
- `[ERROR]` failures with the exact reason: stream start rejected, FFmpeg
  startup timeout, live-output stall, desktop-capture stall, captured window
  closed or minimized mid-stream, Desktop Duplication output lost, audio-helper
  failure, bind-race give-up, unexpected FFmpeg exit.
- `[ACTION]` what the app did in response: FFmpeg terminated, capture relaunch
  (recovery N of 3), FFmpeg launch retry, settings fallback to defaults,
  capture reset to desktop, updater launched, update install.

Where the lines come from:
- `BroadcastWorker` (`broadcast.d`) now takes the `ActivityLog` and mirrors its
  failure reasons + actions into it. Before, those details only went to
  `aurora-stream-startup.log`, which is reset on every stream start.
- `StreamRoot` (`root.d`) logs startup/encoder/capture/settings/audio/update/
  browser/tray events. The Settings menu gained a "View activity log" entry
  that opens the file with the OS default handler (`openLocalFile` in
  `browser.d`).
- User actions are logged as `[INFO]`: capture source, source/YouTube quality,
  YouTube bitrate, Twitch/YouTube enable toggles, window-content capture, live
  source preview, streaming-server fields, minimize-to-tray / close-to-tray,
  desktop audio / microphone selection (friendly name only), audio refresh,
  browser quick-link opens, browser choice, settings menu opens. **Stream keys
  and server URLs are NEVER logged** — text fields record only the
  populated/cleared transition (`logFieldPopulatedChange` in `root.d`), never
  the content.
- `ActivityLog` (`activitylog.d`) gained `info/warning/error/action` helpers
  (tagged `note` lines); app-authored text is ASCII, file is UTF-8.
- Environment + settings block at startup (`aurorastream/environment.d`):
  `[INFO] OS: <name> <edition> (build NNNNN) (arch).`, `[INFO] CPU: <model>
  (<N> logical processors).`, `[INFO] RAM: <GB>.`, `[INFO] GPU: <adapter>
  (\\.\DISPLAYn). Display <W>x<H> @<Hz>.`, `[INFO] FFmpeg: <version line>.`,
  then `[INFO] Settings: ...` lines covering destinations, encoder, capture,
  qualities/bitrate, audio devices, window-content capture, live preview,
  tray options, browser, config mode, and stream-key PRESENCE only. OS/CPU come
  from the registry (`RegGetValueW` on `HKLM`, requires `advapi32` in
  `dub.json` libs); GPU/display from `EnumDisplayDevicesW`/
  `EnumDisplaySettingsW`; RAM from `GlobalMemoryStatusEx`. Keys and server URLs
  are never written (a unittest asserts the report never contains them).

Verify (no stream keys needed):
1. `dub test` in `aurora-stream` (43 modules pass; new unittest asserts the
   four severity helpers write tagged lines).
2. `dub build` (application) and `dub build --config=notitlebar` both link.
3. Launch `aurora-stream.exe`, wait ~8 s, kill it, then read the tail of
   `aurora-stream-activity.log`: expect `[INFO] Aurora Stream 0.63.0 (build
   dev) starting.`, `[INFO] Encoder: ...`, `[INFO] Capture backend: ...`,
   `[INFO] Settings file: ...`, `[INFO] Loaded settings ...`, `[INFO] Found N
   Windows playback endpoints ...`.
4. To exercise failure/action lines, start a stream with a bad Twitch/YouTube
   key: expect `[INFO] Stream start: ...`, `[INFO] FFmpeg launched ...`,
   FFmpeg `[WARNING]` lines, then on failure `[ERROR] Stream failed: <exact
   reason>` + `[ACTION] Action taken: FFmpeg was terminated.` and a final
   `[ERROR] Stream session ended with failure: ...`. An alt-tab away/back on a
   Desktop-Duplication capture logs `[ERROR] Desktop capture output lost ...`
   + `[ACTION] Action taken: relaunching FFmpeg ... (recovery 1 of 3)`.
5. Settings menu -> "View activity log" opens the file in the default editor.
6. User-action lines: change any dropdown/checkbox in the UI and watch the log
   for `[INFO] <control> ...`; type/paste a stream key and confirm the log only
   says "Twitch stream key entered." / "pasted" — the key itself never appears.
   On first launch with no saved desktop-audio selection, the auto-selected
   default endpoint logs `[INFO] Desktop audio device set to <name>`.
7. Environment block: the first session in a log shows `[INFO] OS: ...`,
   `[INFO] CPU: ...`, `[INFO] RAM: ...`, `[INFO] GPU: ...`, `[INFO] FFmpeg: ...`
   and the `[INFO] Settings: ...` lines, with stream keys reported only as
   "configured (hidden)" / "not configured". Verify the FFmpeg line matches the
   bundled build (version.py / single-exe) or the PATH ffmpeg.

## Aurora Stream: OBS-style game capture via D3D11 render hook — implemented (2026-08-14)

User: "We want to stream a window even if it's minimized or out of focus or not
here. That's the main point." and then "we need just like obs per game render
hooks." The proper fix is OBS Game Capture-style render hooks: inject a DLL into
the game that hooks `IDXGISwapChain::Present` and captures the back buffer at the
render-API level, so it works even when the game is minimized, exclusive-
fullscreen, or covered. Decided to build it **entirely in D** (no C toolchain on
this machine: no MSVC `cl.exe`, no Windows SDK headers, only a stubbed VS 2019
and `dmd`).

### What was built and VERIFIED working
- `aurora-stream/source/aurorastream/d3d11.d` — raw D3D11/DXGI COM bindings as
  explicit vtable-struct layouts (`extern(C)` function-pointer fields). D
  `interface` types are NOT used because they do not dispatch through the native
  COM vtable. The test surface verified: `D3D11CreateDeviceAndSwapChain`,
  `IDXGISwapChain` (GetBuffer/Present/GetDesc), `ID3D11Device`
  (CreateTexture2D/CreateRenderTargetView), `ID3D11DeviceContext`
  (ClearRenderTargetView), and Release. 16,684 frames presented in the test app.
- `aurora-stream/gamecaphook.d` — the injected hook DLL, built as
  `-betterC` with a **custom entry point** (`/ENTRY:gamecaphookEntry`) and
  `/NODEFAULTLIB`, so no CRT startup runs in the foreign process. This is
  mandatory: a normal DMD `-shared` DLL (msvcrt120 or betterC-with-CRT) crashes
  in a foreign process (verified `0xC0000409` STATUS_STACK_BUFFER_OVERRUN even
  for a trivial DLL). The hook reads a config file
  (`%TEMP%\aurora-gamecap-<pid>.cfg`, `hwnd=` + `pipe=`), creates a dummy
  D3D11 device+swapchain to obtain the process-shared `IDXGISwapChain` vtable,
  replaces the `Present` slot (index 8) with `hookPresent`, and publishes
  captured BGRA frames through the shared-memory ring.
- Injection + transport (`tests/gamecap_test.d`, `tests/inject_notepad.d`):
  `CreateRemoteThread(GetProcAddress(kernel32,"LoadLibraryW"))`. CRITICAL:
  `&LoadLibraryW` in D resolves to THIS EXE's import thunk, NOT the kernel32
  function (verified: 0x14000BED0 vs 0x7FFD...) — always use GetProcAddress for
  the injected function pointer. Verified the hook DLL injects into notepad AND
  the D3D11 test app (returns a valid HMODULE), reads config, patches the vtable
  ("setup: vtable patched"), and connects the pipe ("setup: pipe connected").
  `hookPresent` is reached, `isTargetSwapchain` matches, and `captureFrame`
  runs.

### Resolved capture and integration details
- [RESOLVED] `ID3D11Device::GetImmediateContext` — the D3D11 device vtable has
  `GetCreationFlags` (slot 38) and `GetDeviceRemovedReason` (slot 39) BEFORE
  `GetImmediateContext`, so its real slot is **40**, not 38 (my original layout
  was missing those two methods). Verified by fetching the authoritative
  mingw-w64 `d3d11.h` and re-checking. `GetImmediateContext` now returns the
  real context. The probe that found it: create a plain device with
  `D3D11CreateDevice`, read the vtable, call each slot with
  `void(this, void**)` + a sentinel (0x12345678) and find the one that writes
  the known context — but the vtable dump + header comparison is what settled it.
- [RESOLVED] **Frame capture works end-to-end**: the hook copies the back
  buffer through a reusable asynchronous staging ring, performs nonblocking
  readback, and delivers versioned BGRA frames on a dedicated worker. The final
  minimized 1920×1080 matrix covered BGRA8, RGBA8, and RGB10A2 with two restart
  rounds and the production session for each. Two earlier pitfalls fixed:
  (a) moving multi-megabyte frames through a named pipe consumed roughly
  500 MB/s at 1080p60 and was load-sensitive; pixels now use a three-slot
  shared-memory ring and the 64 KiB pipe carries only framed control headers;
  (b) releasing a COM object must go through ITS OWN vtable slot 2 as an
  `extern(C)` call (`comRelease` helper) — releasing through another object's
  vtable, or via a `extern(D)` function pointer, crashes/hangs.
- [RESOLVED] The test target now uses a minimized, never-activated 1920×1080
  swap chain paced by a high-resolution waitable timer at 250 FPS. It stresses
  a 60 FPS capture without monopolizing the GPU or opening a foreground window.
- [RESOLVED] Aurora persists `gameCaptureMode`, injects with the real kernel32
  `LoadLibraryW`, continuously drains the pipe into a bounded latest-frame
  queue, reports structured metrics, aspect-fits non-native frames with a
  reusable HALFTONE DIB, and feeds the existing exact-cadence rawvideo input.
- [RESOLVED] The portable single-exe workflow builds the optimized hook before
  DUB embeds it. Extraction uses a content-derived filename and verifies bytes,
  preventing a same-size stale or locked DLL from being reused.
- Remaining inherent limits: x64/D3D11 only; anti-cheat/elevated processes may
  block injection; D3D12/Vulkan/OpenGL/HDR16 need separate hooks. Authenticated
  YouTube ingest is the next manual release test.

### Build/verify commands
```
dmd -m64 -shared -betterC -O -release -inline -boundscheck=off gamecaphook.d source\aurorastream\d3d11.d -Isource -I..\vendor\aurora-d-0.4.5\source -of=embedded\gamecaphook.dll -L/NODEFAULTLIB -L/ENTRY:gamecaphookEntry -L/OPT:REF -L/OPT:ICF -L"C:\D\dmd2\windows\lib64\mingw\kernel32.lib" -L"C:\D\dmd2\windows\lib64\mingw\user32.lib" -L"C:\D\dmd2\windows\lib64\mingw\gdi32.lib" -L"C:\D\dmd2\windows\lib64\mingw\ucrtbase.lib"
dmd -m64 -O -release -i -Isource -I..\vendor\aurora-d-0.4.5\source tests\gamecap_test.d -of=gamecap_test.exe
```
`hookDebug` is compiled out unless `GameCaptureDebug` is explicitly enabled.
The harness writes `gamecap_test_trace.txt` and owns/terminates its background
test target; it does not need a foreground process-control wrapper.

### Hard-won facts (recorded so they are not rediscovered)
- `dmd -shared` D DLLs default to `msvcrt120` (missing on this system) and do
  NOT export `extern(C)` symbols automatically — use `export` (D-mangled) or
  `-L/EXPORT:name` for clean names.
- An injectable DLL must skip the CRT startup: `-betterC` + custom `/ENTRY` +
  `/NODEFAULTLIB`, linking kernel32/user32/gdi32/ucrtbase import libs explicitly.
  Link `ucrtbase.lib` for `memcpy`/`memcmp`/`strlen` (present on the system);
  `libcmt`/`libucrt` import libs are NOT in this dmd distribution.
- `-betterC` globals must be `__gshared` (no TLS runtime → `_tls_index` is
  undefined otherwise). No D runtime/GC: use HeapAlloc, raw Win32, fixed buffers.
- String/format helpers written by hand are a trap: "aurora-gamecap-" is 15
  chars, not 16 — a hardcoded `+16` offset left the config path truncated
  (null at 52, pid orphaned at 53). Always use `enum prefix; ... prefix.length`.

## Aurora Stream: minimize to tray — implementation + verification method (2026-08-14)

Feature: `Settings → Minimize to tray when streaming starts` (auto-hide on
Start), `Settings → Close button hides to tray instead of exiting`, and a tray
icon whose **single-click** toggles Start/Stop streaming, **double-click**
restores the window, and **right-click** opens a custom dark menu
(Show window / Start-Stop / Status / Exit). Persisted as
`minimizeToTrayOnStart` / `closeToTray` (settings schema 8). **Minimize-to-tray
defaults to OFF** (auto-hiding while streaming is confusing), **close-to-tray
defaults to ON**; an explicitly saved value is respected.

### Implementation notes
- `aurora-stream/source/aurorastream/trayicon.d` (new): `Shell_NotifyIcon`
  backed by a hidden top-level Win32 window (`CreateWindowExW`, class
  `AuroraStreamTrayWindow`). Its messages are pumped by the main Aurora loop on
  the same thread, so no extra message thread is needed. Single-click uses a
  `GetDoubleClickTime()` timer so the first click of a double-click never
  toggles; the trailing UP of a real double-click is suppressed by remembering
  the DBLCLK tick. Menu is a native `TrackPopupMenu(TPM_RETURNCMD)` because
  Aurora's in-app menus are invisible while the window is hidden.
- aurora-d backend: `NativeWindow.setVisible(bool)` (win32 SW_SHOW/SW_HIDE).
  Rendering is gated on `_visible` in `paintNow` so a tray-hidden app stops
  rasterizing (energy), and show re-presents immediately.
- `StreamRoot` gates `onCloseRequested` via `closeRequested()`: close-to-tray
  hides and returns false (window stays alive); `_forceExit` (tray Exit / the
  update-restart path) returns true.
- The tray right-click menu is a **fully custom self-drawn popup**
  (`TrayContextMenu` in trayicon.d), not a native menu: a borderless topmost
  window rendered with GDI in the app's dark gray palette. It opens at the
  cursor, highlights on hover, closes on item click / Escape (registered
  hotkey) / outside click, and delivers the chosen command to the owner tray
  window via `wmMenuAction` (WM_APP+0x40). A previous
  `SetPreferredAppMode(ForceDark)` attempt was removed — it does not darken
  native menus on this machine (verified: the native menu rendered light).
- **Outside-click dismissal lesson:** `SetCapture` alone does NOT deliver a
  click that lands on the desktop/taskbar to the captured window (reproduced in
  the real app via a real-input driver: the menu stayed open and the menu
  window never received `WM_LBUTTONDOWN`; the standalone probe masked this
  because its outside clicks landed on a test form instead of the shell). The
  menu now shows activated (`SW_SHOW` + `SetForegroundWindow`) so an outside
  click deactivates it (`WM_ACTIVATE WA_INACTIVE` → close) AND installs a
  `WH_MOUSE_LL` low-level hook while open that closes it on any press outside
  its rectangle (posted as `wmMenuCloseRequest` to avoid reentrancy). Keep
  those layers if a custom menu is ever revisited.

### How to verify
1. `dub test` in `aurora-stream` → 43 modules pass (trayicon menu-structure
   unittest: idle/live menu labels + disabled status row; settings schema-8
   round-trip unittest).
2. `dub build` + `dub build --config=notitlebar` link.
3. Standalone tray probe (no GUI), from `aurora-stream/`:
   ```
   dmd -i -Isource build\trayicon_probe.d -of=build\trayicon_probe.exe user32.lib shell32.lib gdi32.lib winmm.lib ole32.lib avrt.lib
   build\trayicon_probe.exe
   ```
   Creates a real tray icon, then drives the callback window with synthesized
   messages: a WM_LBUTTONUP → exactly one toggle; UP, DBLCLK, UP → one
   window-show and NO toggle (guards the trailing-UP regression). Tooltip and
   balloon calls are exercised; remove()/shutdown() clean up. Exit 0 = pass.
   NOTE: the probe leaves a tray icon on the screen briefly.
4. Custom tray menu probe (drives the real `TrayContextMenu`):
   ```
   dmd -i -Isource build\tray_darkmenu_probe.d -of=build\tray_darkmenu_probe.exe user32.lib shell32.lib gdi32.lib winmm.lib ole32.lib avrt.lib
   build\tray_darkmenu_probe.exe
   ```
   Right-clicks the icon, verifies the menu window opens, clicks the Exit row
   (row center y=121 at 96 DPI) and asserts exit dispatches exactly once and
   the window is destroyed, then verifies Escape (WM_HOTKEY) and an
   outside-click dismiss without an action. Exit 0 = pass.
   To verify the menu's dark rendering, launch the probe under a solid-red
   fullscreen topmost form and screenshot the region around the cursor: the
   non-red pixels (the menu) should be ~96% dark, avg RGB ≈ (45,52,60)
   (`#252c34`), NOT the OS light menu.
4. Real-app close-to-tray test (PowerShell driver `verify-tray.ps1`, kept
   under `%TEMP%`): back up
   `%APPDATA%\Aurora Stream\aurora-stream-settings.json` first; add
   `closeToTray:true` + `minimizeToTrayOnStart:true` (write WITHOUT a UTF-8 BOM
   — a BOM makes `parseJSON` fail and the app silently overwrites settings with
   defaults on shutdown!); launch `aurora-stream.exe`; find the main window by
   pid; send WM_CLOSE → assert process alive AND `IsWindowVisible` false; find
   the `AuroraStreamTrayWindow` and PostMessage the registered
   `AuroraStreamTrayCallback` message with wParam=1 and
   lParam=WM_LBUTTONUP / WM_LBUTTONDBLCLK / WM_LBUTTONUP (80 ms apart) → assert
   the window is visible again. Kill the process and RESTORE the settings file.
5. `aurora-stream-activity.log` records "Window hidden to the system tray." and
   "Window restored from the system tray.".
6. **Refined behavior — "once the tray icon exists, X and minimize keep it in
   the tray"** (user request): verify A) with no tray feature enabled X still
   exits and minimize still taskbar-minimizes; B) with closeToTray on, X hides
   to tray; C) after a tray exists (restore via double-click), pressing X again
   hides to tray and never exits; D) with a tray present, `ShowWindow(SW_MINIMIZE)`
   (taskbar/Alt+Space minimize) is converted to a tray-hide on the next tick
   (window hidden, process alive). The titlebar/system-menu minimize path is
   covered by unit-tested routing through `requestMinimize()`.

### Gotchas learned while testing
- **A launched app rewrites the settings file** — on save (dirty timer) and on
  shutdown `saveSettingsNow()` always writes schema 8 from its in-memory state.
  Any probe that launches the app therefore leaves `%APPDATA%\Aurora
  Stream\aurora-stream-settings.json` rewritten (e.g. stream keys/browser
  choice can be lost if the app loaded different values). ALWAYS restore the
  exact original bytes afterward — a fresh `ConvertFrom-Json` round-trip is
  fine, but do not rely on a backup that was itself re-written. Keep the keys
  (Twitch `twitchKey`, YouTube `youtubeKey`) and `browserChoice` in the restore.
- `Write-Content`/`Set-Content -Encoding UTF8` in Windows PowerShell adds a
  UTF-8 BOM; the app's `parseJSON` then fails and it silently falls back to
  defaults (which later get saved). Write settings with
  `[System.IO.File]::WriteAllText(path, json, (New-Object System.Text.UTF8Encoding($false)))`.

### Known limits / follow-ups
- Auto-hide on Start was verified through the same `hideToTray()` path as
  close-to-tray, but not with a real stream running (that would push a live
  stream to the user's key during testing).
- The custom tray menu is mouse + Escape driven (no arrow-key navigation yet);
  layout is DPI-scaled from a 100% baseline.
- **Notifications are disabled by default** (user request): `showBalloon` is a
  no-op while `TrayIcon.notificationsEnabled` is false. To verify balloons at
  some point, set that flag true, rebuild, and trigger a tray-hide / tray
  toggle; the balloon appears next to the tray icon. Otherwise nothing is
  posted to the notification center.

## Aurora Stream: capture source red/stuck + window-content capture for covered/minimized windows (2026-08-14)

### Follow-up: VLC partial render / A/V mismatch
- Diagnosis: PrintWindow was using the outer `GetWindowRect` dimensions while
  VLC's DPI-virtualized client content was rendered at a different logical
  size. The result was a correctly rendered left portion plus an oversized
  untouched/white region. The slow PrintWindow cadence also previously
  compressed rawvideo timestamps and made video run ahead of audio.
- Fix: `windowcontent.d` now uses `GetClientRect`, requests
  `PW_CLIENTONLY | PW_RENDERFULLCONTENT`, clears the source DIB before each
  print, and `runWindowContentPump` duplicates held frames into missed cadence
  slots. `dub test` passes 44 modules.
- Required live acceptance: capture a visible VLC window again with
  window-content mode enabled, inspect the full client area for correct
  geometry, and compare audio/video timing. Use the default gdigrab mode for
  hardware-accelerated VLC if its video surface remains incomplete through
  PrintWindow.

User: "capture source feature seems to have trouble with selecting windows and
also keeps entire option highlighted as red all the time", then "We want to
stream a window even if it's minimized or out of focus or not here. That's the
main point."

### Diagnosis (all verified empirically, not guessed)
- The published version's saved settings selected a **minimized** cmd.exe
  window (`windowCaptureHwnd: 3867700`). The dropdown turns red
  ("Window (minimized): …") the moment the window list refreshes, because a
  minimized window cannot be captured — and it stayed red until changed.
- A busy desktop is mostly minimized windows (this machine: 54 of 69), so the
  CAPTURE SOURCE list was ~73 rows with most flagged
  "(minimized — not capturable)", making it effectively impossible to pick a
  usable window.
- Hard technical limits verified with real Win32/FFmpeg tests:
  - `ffmpeg -f gdigrab -i hwnd=<minimized>` → `I/O error`.
  - `PrintWindow(PW_RENDERFULLCONTENT)` on a truly minimized window returns only
    a 159×27 taskbar stub, not the window's content. A minimized window has no
    rendered surface, so **no capture API** (gdigrab, PrintWindow, or Windows
    Graphics Capture) can capture it.
  - `PrintWindow(PW_RENDERFULLCONTENT)` IS occlusion-immune: a deterministic
    probe (red window fully covered by a black window, Z-order forced) returned
    86,480 red pixels — the window's own content, not the cover.
- Headless UI probes (the aurora `UiTestDriver` + a real `GuiWindow`) drove the
  actual `CaptureSourceDropdown`: opening the menu, real clicks on rows,
  verifying captions/danger state. These confirmed selection works and that the
  red came only from the minimized saved selection.

### Fixes
- `windowsources.d`: `capturableWindows()` filters minimized windows out of the
  list; `updateCaption` keeps the red minimized warning for a selection that
  isn't in the (filtered) list; the saved-minimized row is labeled
  "Saved window (minimized — not capturable)"; an all-minimized desktop shows
  "All visible windows are minimized — restore one to capture it".
- `root.d`: startup self-heal — a saved capture window that is closed or
  minimized falls back to "Entire desktop" with a status message, persisted
  (schema 7), so the dropdown can never be stuck red across launches.
- `windowcontent.d` (new): `WindowContentCapturer` uses
  `PrintWindow(PW_RENDERFULLCONTENT)` → BGRA DIB, scaled to target, straight
  through to FFmpeg `-pix_fmt bgra` (DIB bytes are already BGRA little-endian).
  Returns false while the window is minimized/closed so the caller holds the
  last frame.
- `broadcast.d`: content-capture mode switches `captureArguments` from
  `gdigrab hwnd=` to `-f rawvideo -pix_fmt bgra -video_size WxH -framerate N -i
  pipe:0`, launches FFmpeg with stdin redirected, runs `runWindowContentPump`
  (writes raw BGRA via the CRT `_write` on the raw fd — never shares the Phobos
  `File` across threads), re-sends the held frame while minimized, and the
  monitor no longer stops on minimize in content mode (only on window close).
- `settings.d`: schema 7 adds `windowContentCapture` (opt-in; GPU/games can
  render black through PrintWindow). `root.d` adds the "Capture window content"
  checkbox (enabled only when a window is selected and not streaming).

### How to verify
1. `dub test` in `aurora-stream` → 42 modules pass (added windowcontent,
   settings round-trip, and broadcast content-capture-arguments tests).
2. `dub build` + `dub build --config=notitlebar --force` link; the default app
   launches and closes cleanly.
3. Standalone `WindowContentCapturer` probe: visible window → green pixels
   captured; minimized → `capture()` false; restored → true.
4. End-to-end pipe probe (mirrors the broadcaster's pump): create a colored
   window, pipe `PrintWindow` frames into
   `ffmpeg -f rawvideo -pix_fmt bgra -video_size 320x180 -framerate 30 -i
   pipe:0 -c:v libx264 ... out.flv` for 3 s, minimize at 1.3 s, restore at
   2.2 s. Asserts ffmpeg exit 0 and both the t=1.6 s (minimized, held frame)
   and t=2.6 s (restored, live) frames show the window's real content
   (signalstats SATAVG≈62.5, blue-dominant). Rebuild this probe from the
   deleted `tests/pipecontent_probe.d` pattern if needed.
5. The deterministic occlusion probe (red window under a black window →
   PrintWindow returns the red content) is the proof that content capture is
   occlusion-immune.

### Known limits (documented, not silently hidden)
- Truly minimized windows cannot be captured by any API (no rendered surface);
  the content pump keeps streaming the last good frame instead and resumes on
  restore. A minimized selection is still rejected at Start (no first frame).
- GPU/DirectX-rendered windows can render black through PrintWindow; hence the
  opt-in checkbox. A Windows.Graphics.Capture (WinRT) engine would handle
  those when occluded, but druntime has no WinRT types and no Win10 SDK is
  installed here — that is a separate hand-written-WinRT project.
- Method note: `schema_probe.d` and the app save wrote schema 7; a manual probe
  run once overwrote the user's settings with defaults — restore the real
  values (stream keys/browser/cache) before finishing, and verify with
  `Select-String` on `%APPDATA%\Aurora Stream\aurora-stream-settings.json`.

## Aurora Stream: "stops when I alt-tab" + one-time freeze — activity log + alt-tab capture recovery (2026-08-14)

Two user reports: the stream stops when alt-tabbing, and the app froze once.
Plan agreed with the user: "we will start logging to understand freeze and will
look into alt tab problem". Two changes:

### 1. Freeze logging — `aurora-stream-activity.log` + UI-thread stall detector

New `aurora-stream/source/aurorastream/activitylog.d` (class `ActivityLog`):
- Persistent, timestamped, thread-safe log written beside the executable
  (same folder as `aurora-stream-startup.log`): `aurora-stream-activity.log`.
- Records UI heartbeats, window events (focus gained/lost, minimized/restored),
  stream start/stop, and UI stalls. Rotated/truncated after 4 MiB.
- Stall detection runs on a dedicated watchdog thread (not the UI thread), so a
  fully frozen UI can still write the stall record. Threshold: no UI tick for
  > 3 s; checks every 0.5 s; records the stall start (at the LAST heartbeat, so
  the reported duration is the true freeze length), the last published stream
  state (status + metrics), and the resolution once ticks resume.

Wiring in `root.d` (`StreamRoot`):
- `_activityLog` created + `start()` in the constructor; `heartbeat()` at the
  top of every `onTick`; `onHostFocusChanged` logs "Window focus lost (possible
  alt-tab)" / gained; minimize/restore transitions logged; stream
  started/stopped transitions logged; the live snapshot (stream on/off, status,
  FPS/Speed/dup/drop/time) published via `setSnapshot` for stall context;
  `shutdown()` stops the watchdog and writes a final line.

How to verify the stall detector without the GUI:
```
dmd -i -Isource -I..\vendor\aurora-d-0.4.5\source build\activitylog_probe.d -of=build\activitylog-probe.exe user32.lib gdi32.lib shell32.lib winmm.lib ole32.lib avrt.lib -L/SUBSYSTEM:CONSOLE
```
(probe: heartbeat ~1 s, stop, wait ~4.5 s, resume, shutdown) → the log shows
`UI STALL DETECTED ... 3.1 s` then `UI STALL RESOLVED after 4.6 s`, and prints
`ACTIVITYLOG PROBE PASSED`. Note: `Thread.join()` in this DMD has no `Duration`
overload — use a plain `join()` (the watchdog sleeps at most 0.5 s between
checks, so it returns promptly once `_shutdown` is set).

### 2. Alt-tab stream stop — recoverable Desktop Duplication loss

Root cause: alt-tab to/from a fullscreen-exclusive app, a resolution change,
the lock screen, or a UAC prompt makes Desktop Duplication lose its output.
FFmpeg's `ddagrab` prints `AcquireNextFrame failed` and the capture input dies.
Before this change `parseLine` treated that first line as a permanent
`VIDEO CAPTURE FAILURE` and killed FFmpeg instantly.

Change in `aurora-stream/source/aurorastream/broadcast.d`:
- `parseLine`: an `AcquireNextFrame failed` line sets `_captureLossRecoverable`
  (recoverable) instead of `_videoCaptureFailed` (fatal). Kills FFmpeg (the
  input is already dead), status becomes "Desktop capture lost — reconnecting…",
  startup log gets `DESKTOP CAPTURE OUTPUT LOST` + the exact line.
- `monitorProcess`: returns early when `_captureLossRecoverable` is set (same as
  process-gone / user-stop / shutdown), so the launch loop can act promptly.
- `run()` launch loop: after the process exits, if the loss is recoverable AND
  the user still wants the stream (`_requestedRunning`, not `_shutdown`) AND the
  relaunch budget (`maxCaptureRelaunches = 3`, 300 ms apart) remains, it resets
  the per-run flags and relaunches FFmpeg (`RELAUNCH ... recovery N of 3`). The
  bounded FIFO muxer reconnects the Twitch/YouTube destination. Only when the
  budget is exhausted is it reported as a permanent capture failure (status
  "Desktop capture failed (did not recover after 3 relaunches)"). A user Stop
  during the recovery window is respected — no relaunch.

How to verify (automated):
- `dub test` → 41 modules pass. A new broadcast unittest drives `parseLine`
  with `AcquireNextFrame failed` and asserts: recoverable flag set, NOT
  `_videoCaptureFailed` (not fatal yet), status "Desktop capture lost —
  reconnecting…", a second loss line doesn't re-diagnose, clearing the flag
  works, and the monitor exit condition triggers on capture loss AND on user
  stop (`_requestedRunning` false).
- `python tests/verify-audio-transport.py`, `verify-rtp-sdp.py`,
  `verify-network-output-isolation.py` still pass.
- `dub build` (application/titlebar) + `dub build --config=notitlebar` link.
- Manual: launch the app, start a stream, alt-tab to/from a
  fullscreen-exclusive app. Expected: `aurora-stream-startup.log` shows
  `DESKTOP CAPTURE OUTPUT LOST` + `RELAUNCH ... recovery 1 of 3`, the status
  briefly reads "Desktop capture lost — reconnecting…", then live metrics
  resume. If the desktop stays unavailable for > 3 relaunches, the stream stops
  with the "did not recover after 3 relaunches" message. `aurora-stream-activity.log`
  shows the matching focus-loss line and stream-stop transition.

### Known limitation
- The relaunch gap is a few seconds (FFmpeg restart + FIFO reconnect); viewers
  see a brief interruption, not a dead stream. This is the intended trade-off
  for surviving alt-tab.
- `gdigrab` fallback capture has no `AcquireNextFrame` line, so a permanent
  gdigrab failure is still a normal capture failure (no relaunch). Only the
  Desktop Duplication backend is auto-recovered.

## Aurora Stream: settings file location — per-user by default, `--portable-config` opt-in (2026-08-14)

The settings file (`aurora-stream-settings.json`) previously lived in the
current working directory (`getcwd()`), i.e. "beside the folder the app is
launched from". That is wrong for an installed app: settings could land
anywhere (Start-menu shortcuts, other working directories) and the install
directory may not be writable.

New behavior:
- Default (installed): `%APPDATA%\Aurora Stream\aurora-stream-settings.json`
  on Windows; `~/Library/Application Support/Aurora Stream/` on macOS;
  `$XDG_CONFIG_HOME/Aurora Stream/` (else `~/.config/...`) on Linux. The
  directory is created on first save (`mkdirRecurse`).
- `--portable-config` argument: keeps the old behavior (file beside the launch
  folder). Parsed in both entry points (`app.d`, `app_titlebar.d`).
- One-time migration: `loadSettings` moves an existing CWD-relative settings
  file (or its `.bak`) into the per-user location when that file does not yet
  exist, in default mode only. Never overwrites a newer per-user file.

Key code:
- `aurora-stream/source/aurorastream/settings.d`:
  `setPortableConfigMode`, `portableConfigMode`, `userConfigDirectory`,
  `settingsFilePath`, `ensureSettingsDirectory`, `migrateLegacySettings`.
- `aurora-stream/source/app.d` + `app_titlebar.d`: `--portable-config` loop.

How to verify:
- `dub test` in `aurora-stream` → 38 modules pass (a new unittest toggles
  portable mode and asserts per-user != portable path).
- Build both configs: `dub build --config=application` (needs the running
  `aurora-stream.exe` stopped first — the exe locks its own file) and
  `dub build --config=notitlebar`.
- Launch the rebuilt exe: the status row shows the settings path; it must be
  under `%APPDATA%\Aurora Stream\`. Launch with `--portable-config` to confirm
  the path reverts to the launch folder.
- Existing CWD settings file migrates once on first default-mode launch.

## Aurora Stream: game/window capture (CAPTURE SOURCE) — stream only a window (2026-08-14)

User: "would be nice a setting for only game capture so they can't see desktop
xd". Aurora Stream now streams **only the selected window** when a window is
chosen in the new **CAPTURE SOURCE** dropdown (top of the settings panel), so
viewers never see the rest of the desktop.

Key code:
- `aurora-stream/source/aurorastream/windowsources.d` — `WindowSource`
  (`hwnd`/`title`/`processName`), `enumerateWindows()` (Win32 `EnumWindows` +
  `GetWindowTextW` + `QueryFullProcessImageNameW`; filters the shell window,
  tool windows, owned dialogs, title-less windows, and Aurora Stream's own
  process), `windowExists()`, `hwndFromText()`, and the `CaptureSourceDropdown`
  widget (lists "Entire desktop" + windows, re-enumerates on open, has a
  "Refresh window list" item).
- `aurora-stream/source/aurorastream/broadcast.d` — `captureArguments` emits
  `-f gdigrab -framerate 60 -draw_mouse 0 -i hwnd=<handle>` for window capture;
  `usesD3D11ZeroCopyVideo` is false for it (CPU path); `videoPipelineLabel`
  shows `Window capture (GDI) → CPU processing → encoder`;
  `validateBroadcastSettings` rejects a stale/closed window handle with a clear
  message instead of silently streaming the desktop.
- `aurora-stream/source/aurorastream/settings.d` — schema 6 keys
  `windowCaptureHwnd` (decimal handle) + `windowCaptureLabel` (cached
  `process — title`), persisted and round-tripped.
- `aurora-stream/source/aurorastream/root.d` — CAPTURE SOURCE section, live
  video-path label, and the preview window target.
- `aurora-stream/source/aurorastream/desktoppreview.d` — `setWindowTarget` lets
  the LIVE SOURCE CANVAS preview capture the selected window's client area
  instead of the primary monitor.

How to verify (automated):
1. `dub test` in `aurora-stream` → 40 modules pass (includes new
   `windowsources.d` tests and broadcast/settings round-trip + gdigrab-hwnd
   argument tests). The windowsources unittest requires, on an interactive
   desktop, that enumeration finds non-empty-titled windows with unique handles
   and that a freshly enumerated handle passes `windowExists` — this catches the
   callback-convention regression that emptied the list (see below).
2. `dub build` (application/titlebar) and `dub build --config=notitlebar --force`
   link.
3. End-to-end FFmpeg window capture (mirrors `broadcastArguments` for one
   destination, video-only, local FLV):
   ```
   ffmpeg -f gdigrab -framerate 60 -draw_mouse 0 -i hwnd=<HWND> \
     -filter_complex "[0:v]fps=fps=60:start_time=0:round=near,settb=AVTB,setpts=N/(60*TB),scale=1920:1080:force_original_aspect_ratio=decrease:flags=bicubic,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1[vsource];[vsource]format=yuv420p[vtwitch]" \
     -map "[vtwitch]" -r:v 60 -fps_mode:v cfr -c:v libx264 -preset veryfast \
     -b:v 6000k -maxrate 6000k -bufsize 12000k -profile:v high -level:v 4.2 \
     -g 120 -keyint_min 120 -bf 2 -sc_threshold 0 -max_interleave_delta 0 \
     -flush_packets 1 -flvflags no_duration_filesize -f flv -t 5 out.flv
   ```
   Expect ~300 frames at 60/1 and non-black frames (e.g.
   `ffmpeg -ss 3 -i out.flv -frames:v 1 -vf signalstats,metadata=print:file=- -f null -`
   → `YAVG` well above ~16).
   Get an HWND: `powershell "Get-Process | ? { $_.MainWindowTitle } | select Id,MainWindowHandle,MainWindowTitle"`.

Gotcha that WILL bite you (2026-08-14, fixed):
- Win32 callbacks passed to functions like `EnumWindows` must be declared
  `extern (Windows)`. A plain D `BOOL cb(HWND, LPARAM)` function casts fine but
  DMD's default convention reads the arguments from the wrong place, so every
  `HWND` arrives as **null** and every window is filtered out (the dropdown
  showed "No capturable windows"). Use
  `private extern (Windows) BOOL cb(HWND hwnd, LPARAM lParam)`.

Minimized windows cannot be captured (2026-08-14):
- A minimized window's client area is 0×0; `gdigrab` fails to open it (start)
  or stops producing fresh frames while encoder timestamps keep advancing
  (mid-stream) → the stream sits on a frozen last frame forever, and the frame
  counter can keep advancing so no watchdog fires. Handle it explicitly:
  - `windowsources.windowIsMinimized` (IsIconic); the dropdown labels such
    windows `(minimized — not capturable)` and the caption shows
    `Window (minimized): …`.
  - `validateBroadcastSettings` rejects a minimized selection at Start.
  - The broadcast monitor (`monitorProcess`) is passed `windowCaptureHwnd` and
    stops the stream within ~0.1 s the moment the captured window is minimized
    or closed, with a clear status/diagnostic, instead of freezing.
  - `DesktopPreviewCapturer.capture()` returns false for an iconic window so the
    preview keeps its last good frame.
- How to verify (automated): minimize a window
  (`[ShowWindow](hwnd, 6)` from PowerShell), then `windowIsMinimized(hwnd)`
  must be true, `validateBroadcastSettings` with that hwnd must return the
  minimized message, and `captureDesktopPreview`/`DesktopPreviewCapturer.capture`
  must return false for it.

Manual (GUI):
- Launch Aurora Stream → CAPTURE SOURCE dropdown lists visible windows
  (`process.exe — Window Title`) plus Entire desktop; open a game/app after
  startup and the dropdown shows it after **Refresh window list** (or on the
  next open).
- Pick a window, start streaming: status row shows `Capture: Window capture:
  <label> • Window capture (GDI) → CPU processing → encoder`. The LIVE SOURCE
  CANVAS preview shows the window, not the desktop.
- Close the selected window, restart the app, Start → rejected with "The
  selected capture window is no longer open ...".
- Switch back to Entire desktop → desktop capture (ddagrab/NVENC) returns
  (`Desktop Duplication (cursor-safe)` label / `D3D11` path when hardware
  supports it).

## TitleBar: cursor no longer changes to "move" while dragging the window (2026-08-14)

User: dragging the window by the custom titlebar should not change the cursor.

Root cause in `vendor/aurora-d-0.4.5/source/aurora/widgets/titlebar.d`: when a
real drag starts (`onMouseMove`, movement threshold crossed) the bar called
`setCursor(CursorKind.move)`, so the pointer flipped to the move cursor for the
whole drag. Dragging a window is not a resize/move cursor situation — the
pointer should stay an arrow (drag only starts from the title/icon area, which
already uses the arrow cursor, so the arrow is left untouched).

What changed:
- Removed the `setCursor(CursorKind.move)` call at drag start; the drag now
  leaves the existing arrow cursor in place.
- The comment in `onMouseMove`'s `_dragging` branch now says "keep the cursor
  and the hover visuals frozen" (the move-cursor rationale is gone).
- `setDraggable(false)` and `onMouseUp` still reset to `CursorKind.arrow`
  (unchanged — correct and harmless).

How to verify:
- `dub test` in `vendor/aurora-d-0.4.5` → all unit tests pass (the drag
  self-move unittest exercises the exact code path that used to set the move
  cursor).
- `dub build --config=application` in `aurora-stream` links.
- Manual: drag the titlebar; the cursor must stay the arrow and never flip to
  the move cursor. Caption-button hover (hand cursor) is unchanged.

## Single-exe PE icon (Explorer/taskbar) via post-link .rsrc patch (2026-08-13)

DMD's bundled lld-link is 9.0.0 (2019): it rejects `.res` files ("unknown file
type") and CRASHES on hand-built COFF resource objects (two-section
.rsrc$01/.rsrc$02 + @feat.00 + $R symbols + ADDR32NB relocations were emitted
correctly per llvm-cvtres, but LLD 9 still segfaults). So the icon is added
POST-LINK instead:

- `scripts/patch-pe-icon.py icon.ico exe [out]` appends a `.rsrc` section to
  the linked exe and updates the PE headers (NumberOfSections, section table,
  SizeOfImage, resource data directory). Resource data-entry RVAs are computed
  from the new section RVA, so no linker relocation support is needed.
- `scripts/build-portable-windows.py --single-exe` runs it after `dub build`
  for aurora-cut/aurora-stream.
- Resource tree layout is identical to llvm-cvtres (BFS, RT_ICON ids 1..N +
  RT_GROUP_ICON id 1, language 0x0409).

How to verify the icon is truly embedded (not just present in the directory):
`scripts/../temp tool` walk the .rsrc section and confirm every
IMAGE_RESOURCE_DATA_ENTRY.OffsetToData resolves to a real RVA inside .rsrc and
the DataSize matches the .ico image sizes (803/2449/4664/7566/24293/82423 +
90-byte group). DataRVAs left as section-relative offsets (the earlier bug)
means Windows cannot read the icon even though the directory lists RT_ICON.

Explorer icon cache: after re-downloading a fixed exe at the same path, Windows
may keep showing the cached default icon; rename the file or clear the icon
cache to confirm.

## True single portable exe with embedded ffmpeg (2026-08-13)

Goal: ship `aurora-cut.exe` / `aurora-stream.exe` as one self-contained file
that needs no installed ffmpeg.

Mechanism (both apps, mirrored):
- New module `aurorastream/auroracut.ffmpegbundle`: under `version
  (BundledFfmpeg)` it embeds `ffmpeg.exe` + `ffprobe.exe` via D string imports
  (`cast(ubyte[]) import("ffmpeg.exe")`), resolved through
  `stringImportPaths: ["embedded"]` in dub.json.
- At startup (`main()` in app.d / app_titlebar.d) `enableBundledFfmpeg()`
  extracts the two exes into `%TEMP%\Aurora-Stream-ffmpeg` (cut:
  `Aurora-Cut-ffmpeg`) — size-cached so it runs once — and prepends that dir to
  the process `PATH`. Every bare `"ffmpeg"`/`"ffprobe"` call (media.d,
  exporter.d, playback.d, preview.d, ytdlp.d, broadcast.d, ...) then resolves
  to the bundle with zero call-site changes. Dev builds (no BundledFfmpeg)
  fall back to system PATH.

Build:
- `dub build --build=portable-single-exe` (buildType adds
  `versions: [BundledFfmpeg]`, same `-mscrtlib=libcmt` static-CRT flags as
  portable-release).
- CI: `portable-windows.yml` downloads the latest successful
  `ffmpeg-minimal-win64` artifact (`gh run download`), copies ffmpeg.exe +
  ffprobe.exe into `aurora-stream/embedded/` and `aurora-cut/embedded/`, then
  runs `scripts/build-portable-windows.py --single-exe`.
- `embedded/` is gitignored (only `.gitkeep` is committed).

How to verify the mechanism (no GUI):
1. Drop placeholder (or real) `ffmpeg.exe`/`ffprobe.exe` into `embedded/`.
2. `dub build --build=portable-single-exe` in the app dir; confirm the exe
   links (local link needs MSVC's libcmt.lib — present on CI windows-latest;
   locally drop `-mscrtlib=libcmt` temporarily to link with DMD's default CRT).
3. Standalone: compile `ffmpegbundle.d` with `-version=BundledFfmpeg
   -Jembedded`, run a main that calls `enableBundledFfmpeg()`, assert the files
   landed in `%TEMP%\<App>-ffmpeg` with correct sizes and PATH is prepended;
   run twice to prove idempotency.

How to verify the REAL single exe (on a clean machine, no ffmpeg installed):
1. Build via the portable workflow, or locally with the real artifact binaries
   in `embedded/`.
2. Delete any system ffmpeg from PATH; launch the single exe.
3. aurora-stream: RUN-ALL-DIAGNOSTICS / a local .flv output stream; confirm
   `%TEMP%\Aurora-Stream-ffmpeg\ffmpeg.exe` appears on first run.
4. aurora-cut: import + export MP4/MP3; confirm `%TEMP%\Aurora-Cut-ffmpeg`.

## Background playback prewarm on playhead changes (2026-08-13)

User: "after playhead changes we immediately try to start loading in the
background instead of having bad experience on actual playback." Goal: pressing
Play feels immediate because the exact stream was already decoded in the
background while paused.

How it works in `source/auroracut/editor.d`:
- `updatePlaybackPrewarm` (called each onTick): when paused (`_playbackKind ==
  none`, or a paused sequence session) and no busy background job, after the
  playhead settles for `playbackPrewarmDelaySeconds` (0.10 s) it calls
  `startPlaybackPrewarm`.
- `startPlaybackPrewarm` resolves the same context Play would choose
  (direct sequence -> static visual -> live composition, mirroring
  `previewTimeline`), starts `_videoStream` + a PAUSED `_audioPlayer`, and
  stores opaque signatures:
  - `directVideoSignature(path, mediaPosition, duration, w, h, fps, opts,
    mediaOffset)` for direct source playback.
  - `"live\x1f" ~ join(compositeStreamArguments(...), "\x1f")` for the live
    compositor (the args embed position/model/decode/fps).
  - `"static"` for still-image visuals.
- On Play: `startPlayback` first evaluates `prewarmMatchesPlayback(...)` from
  the incoming arguments and skips its `stopPlayback(false)` teardown when the
  prewarm matches (otherwise the teardown kills the warm streams). Then
  `startPlaybackStreams` calls `adoptPlaybackVideoPrewarm()` (signature vs
  `buildCurrentVideoSignature()`, plus the stream must still be running) and,
  in the first-frame handler, `startPlaybackAudio` adopts the matching paused
  audio (calling `PcmAudioPlayer.reanchorClock()` first so the headless
  fallback clock ignores buffering time). No FFmpeg process is spawned on Play.
- Lifecycle: `notePlaybackPrewarmDirty` (from `playheadChanged`) and the
  onTick revision/position checks cancel/restart on any edit or playhead move;
  `cancelPlaybackPrewarm` is called from pause/seek/stop; an idle prewarm is
  released after `playbackPrewarmIdleSeconds` (45 s).

How to verify (headless, deterministic):
- `tests/editor_smoke.d` prewarm block: set the playhead while paused, wait for
  `playbackPrewarmActiveForTesting()` and for the video+audio process counters
  to increase and video frames to buffer, then press Play and assert
  `videoStatsForTesting().processesStarted` and
  `audioStatsForTesting().processesStarted` are UNCHANGED (adoption) and the
  transport reaches the running state.
- The block relies on the prewarm enqueuing the request immediately but
  spawning FFmpeg on the worker thread, so it waits (not asserts) for the
  process counters to move.
- Full gate: `dub test` (33 modules) + the editor/playback/layout/gpu/model/
  export smoke tests. Run `tests/editor_smoke.d` 2-3x on a loaded host to
  confirm the prewarm timing is not flaky.

## "Video decoder ended before the next frame was ready" no longer halts playback (2026-08-13)

User: this message should never appear. It was raised by `editor.d` onTick
whenever `_playbackVideoWaiting` (the transport had paused audio to let a
lagging decoder catch up) was true at the moment the stream reported
`finished()`. But reaching the last frame of the requested range is normal
completion, so a clean EOF while buffering was misreported as a decoder
failure and playback was stopped mid-range.

What changed:
- `playback.d`: `VideoFrameStream.hasReadyFrames()` — distinguishes "finished
  but tail frames still queued" from "nothing left to display".
- `editor.d` `displayedVideoBehindPlaybackClock()`: false once the stream is
  finished with no ready frames (a finished decoder can't catch up, so the
  transport must not re-enter buffering; also breaks a resume→re-pause loop).
- `editor.d` halt block: clean EOF while waiting resumes the transport
  (`resumeAfterVideoBuffer()`) or lets the waiting branch drain the tail;
  genuine FFmpeg errors surface as a status message only. The audio-start
  failure halt is unchanged.

How to verify (deterministic, no decode-speed dependence):
- `tests/editor_smoke.d` direct-playback regression block: after playback is
  active, wait until `videoStreamFinishedForTesting()` (decoder reached the end
  of its range during normal playback — no halt while not waiting), then force
  the exact production buffering state with `simulateVideoBufferWaitForTesting()`
  (which calls the real `waitForVideoBuffer()`), tick, and run to completion.
  Asserts `playbackPositionForTesting() >= playbackEndForTesting() - 0.03` and
  `statusTextForTesting()` never contains "Video decoder ended before the next
  frame was ready". The block fails on the pre-fix code (halt at
  `tests/editor_smoke.d` ~line 1176) and passes with the fix.
- Full gate: `dub test` (33 modules), `tests/editor_smoke.d`,
  `tests/playback_stress.d`, `tests/playback_seek_resilience_smoke.d`,
  `tests/static_sequence_playback_smoke.d`, `tests/playback_proxy_smoke.d`,
  `tests/layout_smoke.d`, `tests/gpu_decode_args_smoke.d`,
  `tests/model_smoke.d`, `tests/export_smoke.d`.
- `tests/synced_playback_preroll_smoke.d` fails at line 112 on the base commit
  too (pre-existing): it asserts `setPlayhead` synchronously increments the
  preview-request counter, but previews are debounced through
  `scheduleTimelineFrame`/`dispatchPendingPreview`. Not part of any verify
  script; repair (assert after a tick / wire frame-step to
  `dispatchPendingPreviewNow`) or remove.

Manual verification in the GUI (this host is 4 logical CPUs, often ~100%
loaded): play a short single-clip timeline to its end, and play a live
multi-clip timeline with audio while the machine is under load; the status must
never show the decoder-end failure and playback must complete at the sequence
end.

## Timeline playback performance / immediacy — analysis (2026-08-13)

End-to-end review of the playback pipeline. Two processes can exist per Play:
video (`VideoFrameStream`) and audio (`PcmAudioPlayer`), both spawning fresh
FFmpeg per play/seek. Live timelines use the compositor graph
(`compositeStreamArguments`) at a fixed 16:9 preset (e.g. 1280x720 in
Responsive) that is then force-scaled to the decode size; paused/scrub frames
use `previewCompositionPreset` at the sequence aspect. This is both a
correctness mismatch (non-16:9 stretched during playback) and a perf waste
(compositor runs at 720p then downscales).

Key measurement method (noisy machine, so use code reasoning + min-of-N):
- Raw decode/filter throughput is measured with ffmpeg writing to `NUL`
  (`-RedirectStandardOutput NUL` in PowerShell) to remove disk I/O; this host
  bounces 1.0-2.3 s for identical 1 s 720p workloads when the box is ~100%
  loaded (4 logical CPUs), so single runs are not trustworthy — take minimums
  and reason from the code.
- First-frame latency is the real "immediacy" metric: ffmpeg spawn + graph
  build + input open/seek + preroll wait (0.055 s direct / 0.090 s live) before
  `_playbackAwaitingFirstFrame` clears (`editor.d` onTick).

How to verify each fix later:
1. Live-vs-pause aspect parity: build a square or portrait sequence
   (e.g. 720x720 composition), press Play and Pause; assert both pause-frame
   and playback-frame use the same aspect (pixel probe / Playwright
   screenshots; compare against the sequence-aspect decode). Current code
   stretches playback for non-16:9.
2. Compositor cost: with the preset changed to the decode size, confirm the
   `[vout]scale=` tail is elided (`outputWidth==preset.width`) and
   `Process Explorer`/ffmpeg CPU for a 3-clip 720p timeline drops vs the
   1280x720-then-downscale baseline at the same decode size.
3. Range-restricted inputs: `collectInputs` should include only clips that
   intersect `[rangeStart, rangeEnd]`; verify a 10-clip timeline playing a
   2 s range starts ~immediately and spawns the same process count.
4. Audio concurrency: video + audio ffmpeg should both spawn at Play
   (`PcmAudioPlayer` paused via `startPaused=true`); verify no A/V desync and
   faster press-Play->sound.
5. Adaptive mode: with frames being dropped (`PlaybackWorkerStats.framesDropped`
   from `_videoStream.stats()`), decode height should step down and later step
   back up; verify `playback_stress.d` still passes.
6. Regression gate: `tests/playback_stress.d` (rapid seeks must coalesce,
   `processesStarted < requests/3`), `tests/synced_playback_preroll_smoke.d`,
   `tests/playback_seek_resilience_smoke.d`, `tests/static_sequence_playback_smoke.d`
   all pass.

## Timeline snapping: playhead, In/Out markers, and cross-track clip edges (2026-08-13)

Timeline items now snap to the playhead (already present), the work-area **In**
(blue) / **Out** (orange) markers, and clip edges on **every** track, plus the
sequence start. Both a clip's start edge and its tail (start + duration) can
snap, and edge-resize previews snap too.

Implementation notes in `source/auroracut/timeline.d`:
- `snappedEdge` / `snappedStart` now take an `out double guide` parameter that
  records the winning marker time (NaN when unsnapped). The `consider` closure
  for start-snaps knows whether the start edge or the tail edge aligned
  (`endEdge`), so the guide points at the marker itself, e.g. a tail snapping
  to the playhead still guides at the playhead.
- `forEachNearbyClipMarker(desired, duration, excludedClipId, visit)` visits
  clip start/end markers from every track using a small window around
  `lowerBoundByStart` (2 binary searches per track, ~7 clips), so 20k-clip
  tracks stay cheap during drags.
- `drawSnapGuide` paints a 1px bright-white rule at `_snapGuideTime` between
  the ruler and the drag overlays. The guide clears on mouse-up, Escape, and
  `clearGhost`. Note: at the playhead's exact X the composited red playhead
  layer is painted above the base guide, so the guide is visually covered there
  (the red line is the cue).

How to verify (headless, no GUI click needed):
- `tests/editor_smoke.d` contains four focused blocks:
  1. In/Out marker snapping: start edge, tail edge, and edge-resize preview.
  2. Cross-track clip-edge snapping: start, tail, and edge-resize preview.
  3. Snap-guide lifecycle: a simulated clip drag snaps to the In marker at
     3.0s, `snapGuideTimeForTesting()` equals 3.0, the rendered pixel at that X
     is bright (>120 per channel), and mouse-up resets it to NaN.
- Compile/run exactly as described in "Run the headless editor smoke test"
  below. Pass = `Aurora Cut multi-track editor smoke test passed.`

## Timeline rows painted over the ruler while scrolling (2026-08-13)

Follow-up to the draggable scrollbar: after making the scrollbar interactive, a
top row scrolled into view painted over the ruler's lower half, so timeline
content appeared on top of the ruler (its time labels/tick marks) while
scrolling up/down.

Root cause in `source/auroracut/timeline.d`: `onPaint` drew the ruler first,
then each track. A row whose top scrolled above `rulerHeight()` but whose
bottom was still below it was not skipped (`rect.bottom() <= rulerHeight()` is
false), so it drew from its unscrolled Y and covered the ruler band.

Fix (a clip, effectively a layer boundary): the track loop now draws into
`canvas.clipped(Rect(0, rulerHeight(), width, height - rulerHeight()))`, so a
partially scrolled row is clipped at the ruler's bottom edge instead of
painting over the ruler.

How to verify (headless):
1. `tests/editor_smoke.d` now renders a 6-track overflow fixture after dragging
   the vertical scrollbar to the bottom and asserts that no track-row color
   (`#1c2027` / `#1a2020` / label `#242930` / selected `#303844`) appears in
   the ruler band (y 0..22 at x=700). It fails on the pre-fix paint order and
   passes with the clip.
2. Pixel probe used during diagnosis: render the editor headlessly
   (`AuroraHeadless`, software renderer), scroll to max, save
   `window.surface().savePpm(...)`, and scan the rows below the timeline for
   row colors. Rows are clipped to the timeline bounds, so the only leak was
   the ruler band.

## Timeline vertical scrollbar: draggable, wider track (2026-08-13)

User complaint: the timeline's vertical scrollbar was a 4px painted thumb only —
you could not grab it, so moving up/down relied on the mouse wheel alone.

What changed in `source/auroracut/timeline.d`:
1. The right-edge scrollbar track is now 12px wide (`VerticalScrollbarWidth`)
   with an opaque track, a left border, and a proportionally sized thumb
   (`verticalScrollbarTrack` / `verticalScrollbarThumb`).
2. It is a real input target: `onMouseDown` grabs the thumb (drag mode),
   `onMouseMove`/`onMouseUp` drag it, hover changes the cursor to `hand`, and
   Escape cancels an active drag. Clicking the track jumps the thumb to the
   pointer (grab offset `thumb.height / 2` when not on the thumb).
3. Testing getters were added: `maxVerticalScrollForTesting`,
   `draggingVerticalScrollbarForTesting`, `verticalScrollbarTrackForTesting`,
   `verticalScrollbarThumbForTesting`.

How to verify (headless, no GUI click needed):
1. `tests/editor_smoke.d` now builds a 4-track fixture that overflows a 120px
   viewport and asserts: track is ≥10px wide and docked right, mouse-down on the
   thumb enters drag mode, dragging to the track bottom scrolls to
   `maxVerticalScrollForTesting`, and mouse-up leaves drag mode.
2. The stale `ListView` scrollbar assertion was rewritten to drive the vendored
   `Scrollbar` widget (drags from the thumb; a track click pages). This was
   pre-existing on the clean base commit — see todo.md.
3. `tests/layout_smoke.d` was stale too: the status-bar loading bar is anchored
   right (inside the 8px inset), not centered; the assertion was renamed
   `assertStatusProgressDocked`. `status-progress` id was missing on
   `_progress` in `source/auroracut/editor.d` and was restored.

Windows build/test commands (see also "Run the headless editor smoke test"):
```
dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source tests\editor_smoke.d -of=build\editor-smoke.exe -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32 -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet
dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source tests\layout_smoke.d -of=build\layout-smoke.exe -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32 -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet
```
Then run with the generated media (or `layout-smoke.exe` with no args). Pass =
`Aurora Cut multi-track editor smoke test passed.` and a silent exit for
layout-smoke. Note `dmd -of=` on Windows emits a file without `.exe` unless the
`.exe` suffix is included; cmd refuses to launch it otherwise.

## Aurora Stream canvas-pump crash: rawWrite on a cross-thread File (2026-08-12)

With the Aurora program canvas enabled, pressing Start streaming crashed the
titlebar app (access violation `0xc0000005`). Two crash dumps
(`aurora-stream-titlebar.exe.*.dmp` in `%LOCALAPPDATA%\CrashDumps`) both faulted
at the same RVA `0x12fe9`.

How it was diagnosed:
1. WER `Report.wer` → ExceptionCode `c0000005`, ExceptionOffset `0x12fe9`.
2. Minidump parse (hand-written Python with the stream directory) →
   exception address `0x140012fe9` (image base + `0x12fe9`), i.e. the fault is
   in the app itself, not a system DLL. The saved thread context pointed into
   ntdll only because the dump captures the exception dispatcher frame.
3. Disassembled the containing function with capstone → it dereferences
   `[rbp+0x10]` (`this`), then `[rax]` (`this._p`), then `[rcx]`
   (`this._p.handle`) and calls; a nearby `lea` references the
   `"Wrote ... instead of ... objects of type ubyte"` string from
   `phobos/std/stdio.d` line 1122 — i.e. **`File.rawWrite!ubyte`**.
4. Grep: the only `rawWrite` in aurora-stream is
   `BroadcastWorker.runCanvasPump` → `stdin.rawWrite(cast(ubyte[]) surface.pixels())`.

Root cause and fix: the phobos `File` (a `@system` struct with a heap-allocated,
manually refcounted `_p` Impl pointer) was captured by reference into the pump
thread's closure and passed by value to `runCanvasPump`. `File.rawWrite` can then
see a null/garbage `_p`. Fixed in `broadcast.d` by passing only the raw fd
(`pipes.stdin.fileno()`, an `int`) into the pump thread; the pump builds its own
`File` via `stdin.fdopen(stdinFd, "wb")` so each thread owns a valid `File`.

How to verify (no GUI click needed):
1. `dub test` in `aurora-stream` → 38 modules pass.
2. `dub build` (default `application` config = the custom titlebar) links.
3. Launch the titlebar app; it opens its window and stays up (no console, no
   crash).
4. Standalone repro: spawn ffmpeg with `Redirect.stderr | Redirect.stdin`,
   `int fd = pipes.stdin.fileno()`, pump thread does
   `File stdin; stdin.fdopen(fd, "wb"); stdin.rawWrite(frames)` — runs clean.

## Aurora Stream no-stray-console-on-stream-start (2026-08-12)

The broadcaster spawns the isolated WASAPI RTP helper as
`aurora-stream.exe --audio-rtp-helper ...` with `Config.suppressConsole`
(CREATE_NO_WINDOW). Previously `app.d` listed `--audio-rtp-helper` in
`isDiagnosticCommand()`, so `main()` called `attachDiagnosticConsole()` →
`AllocConsole()` and popped up a visible command prompt on every Start
streaming. The helper communicates only through status/metrics files and UDP
(no stdout), so `--audio-rtp-helper` was removed from the console-allocating
list.

How to verify (no GUI click needed):
1. Spawn ffmpeg exactly like the broadcast worker and confirm it gets no
   console window:
   ```
   pipeProcess([...], Redirect.stderr, null, Config.suppressConsole)
   ```
   then check the child's `MainWindowHandle` is 0.
2. Spawn the helper the same way the broadcaster does:
   ```
   powershell "$p = Start-Process .\aurora-stream.exe -ArgumentList '--audio-rtp-helper','--port',...,'--synthetic' -PassThru -WindowStyle Hidden; Start-Sleep 4; Get-Process -Id $p.Id | select MainWindowHandle"
   ```
   MainWindowHandle must be 0 (no console).
3. Manual diagnostics that print to stdout (`--version`,
   `--list-audio-endpoints-json`, `--audio-bridge-session-test`,
   `--pacing-test`) still call `AllocConsole` on demand and are expected to
   open a terminal.

## Aurora Stream Aurora-rendered program canvas (2026-08-12)

The roadmap's "Aurora-rendered program canvas" is implemented in
`aurora-stream` as a composited source canvas rendered by Aurora itself. When
**Aurora-rendered program canvas (replaces desktop capture)** is checked in
Settings → Program canvas, `BroadcastWorker` launches FFmpeg with
`-f rawvideo -pix_fmt bgra -s WxH -framerate 60 -i pipe:0` (stdin redirected)
and a dedicated paced frame-pump thread (`runCanvasPump`) composites the canvas
into a `Surface` each frame and writes the BGRA bytes to stdin. The existing
`sourceScaleGraph` (`fps=60:start_time=0:round=near`, `setpts=N/(60*TB)`)
normalizes CFR downstream, so the pump only needs approximate pacing.

Key modules/files:
- `aurora-stream/source/aurorastream/programcanvas.d` — `ProgramSource` model
  (normalized rects, opacity, visibility), `paintProgramCanvas` compositor,
  `ProgramCanvasPreview` widget, `ProgramCanvasEditor` (add color/image/text,
  reorder, opacity, visibility), JSON (de)serialization.
- `broadcast.d` — canvas fields on `BroadcastSettings`, raw-pipe capture args,
  `runCanvasPump`, zero-copy bypass, `videoPipelineLabel`.
- `settings.d` — schema 5 persistence.
- `root.d` — LIVE SOURCE CANVAS preview panel + Program canvas editor section.

How to verify (model level, no GUI needed):
1. `dub test` in `aurora-stream` → 38 modules pass; new programcanvas unittests
   cover color/image/text compositing into a `Surface` and JSON round-trips.
2. Rebuild and run the broadcast-model smoke:
   ```
   dmd -i -g -w -unittest -main -version=AuroraHeadless -Isource -I..\vendor\aurora-d-0.4.5\source tests\broadcast_model_smoke.d -of=build\broadcast-model-smoke.exe user32.lib gdi32.lib shell32.lib ole32.lib avrt.lib -L/SUBSYSTEM:CONSOLE -L/ENTRY:mainCRTStartup -g -L/LIBPATH:"C:\D\dmd2\windows\lib64\mingw" -L/DEFAULTLIB:msvcrt.lib -L/DEFAULTLIB:ucrtbase.lib
   build\broadcast-model-smoke.exe
   ```
   Exit 0. New assertions: canvas mode emits `rawvideo`/`bgra`/`1920x1080`/
   `pipe:0`, never `ddagrab=`/`gdigrab`/`-nostdin`, keeps the CFR cadence
   filters, `usesD3D11ZeroCopyVideo` false, correct `videoPipelineLabel`, and
   the pacing diagnostic forces desktop capture.
3. GUI launch: `dub run` (or RUN-WINDOWS.bat) opens StreamRoot; check the
   LIVE SOURCE CANVAS panel shows the composite and the Program canvas section
   edits sources; controls disable while streaming.

## Aurora Stream custom-titlebar variant + taskbar icon (2026-08-12)

The default `application` build in `aurora-stream` uses the custom `TitleBar`
widget (frameless window, drag/maximize/restore/system menu, real `.ico` in the
titlebar via `TitleBar.setIconImage` and `aurora.image.loadIcoImage`) hosting
the unchanged `StreamRoot`. The `notitlebar` configuration
(`dub run --config=notitlebar`, target `aurora-stream-notitlebar`) keeps the
plain OS-titlebar window.

**Taskbar icon:** the root cause was that aurora-stream was console-subsystem —
double-clicking the exe opened a console window that claimed the taskbar button
with the exe-path title and no icon (verified: the window/class icons were
already set via WM_SETICON/SetClassLongPtr). The default build is now
GUI-subsystem (`/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup`, like
aurora-opencode), so only the GUI window appears in the taskbar with its icon.
CLI diagnostics allocate a console on demand (`AllocConsole` + `freopen`).

Verify: `dub run` (default = custom titlebar, target `aurora-stream`) shows the
aurora-stream icon in the taskbar with no console window; double-clicking the
exe behaves the same. `dub run --config=notitlebar` runs the OS-titlebar build.

## Minimal ffmpeg for redistribution: build + test method (2026-08-12)

Goal: ship ffmpeg with the apps at ~15-30MB instead of 300MB. One static build
serves BOTH aurora-cut and aurora-stream.

How to build (CI only):
1. Push the repo (workflow auto-runs on any change to the build script or
   workflow; also available via Actions -> "Build minimal ffmpeg" -> Run).
2. Download artifact `ffmpeg-minimal-win64` (bin/ffmpeg.exe + bin/ffprobe.exe).

How to reproduce locally (Linux or WSL with mingw-w64 + nasm + meson/ninja +
cmake): `scripts/build-minimal-ffmpeg-win64.sh` — set `WINE=wine` to also run
the smoke test. FFMPEG_TAG env overrides the release (default n8.1).

The build enables ONLY what the two apps use (audited call-site by call-site;
all names cross-checked against ffmpeg's `-encoders/-decoders/-filters/
-formats/-protocols/-devices`):
- aurora-cut surface: mov/mkv/webm/mp3/wav/flac/ogg/image2/gif demuxers,
  mp4/mp3/image2/rawvideo/s16le/null muxers, libx264+nvenc+qsv+amf+aac+
  libmp3lame+ppm+rawvideo+pcm_s16le encoders, ~35 decoders incl. images +
  wrapped_avframe/rawvideo (lavfi + raw pipe), the compositor filter graph,
  d3d11va/dxva2 decode hwaccels, file/pipe protocols.
- aurora-stream surface: ddagrab/gdigrab/dshow + lavfi input devices,
  rawvideo + sdp demuxers (rawvideo pipe:0 canvas, sdp+udp/rtp audio),
  flv + fifo muxers, udp/rtp/rtmp/rtmps protocols (schannel TLS for rtmps),
  settb/asetpts/hwdownload filters, h264_nvenc/libx264/aac encoders.
- Internal codecs with no deps (wrapped_avframe, rawvideo, pcm_s16le, null)
  are NOT listed in configure docs but ARE needed at runtime and were enabled
  explicitly.

CI verification:
- smoke test under wine: the verify-export.sh lavfi commands (color+sine ->
  libx264+aac base-av.mp4, overlay.mp4, libmp3lame extra.mp3) + ffprobe.
- inventory step prints -version/-encoders/-decoders/-filters/-protocols/
  -devices so the run shows ddagrab/dshow/gdigrab/udp/rtmp/rtmps are present.
- configure failures dump ffbuild/config.log.

How to verify on the real machine (definitive — wine has no GPU/capture):
1. Put the minimal ffmpeg.exe + ffprobe.exe on PATH (ahead of any other).
2. aurora-cut: `scripts/verify-export.sh` and `scripts/verify-headless.sh`,
   `scripts/verify-playback-stress.sh`; then launch the GUI and do: import
   MP4/MKV/WebM/GIF/PNG, MP4 export (CPU + GPU), MP3 export, waveform
   preview, yt-dlp normalization. Watch aurora-cut.log for executed commands.
3. aurora-stream: `aurora-stream/RUN-ALL-DIAGNOSTICS.bat` +
   `RUN-QUALITY-DIAGNOSTIC.bat` (exercise ddagrab, fifo->flv, nvenc,
   sdp/udp audio). A local .flv output verifies the fifo/flv path without
   needing a real Twitch/YouTube key.

## Titlebar polish: native cursor + centered search text (2026-08-12)

- The demo disabled Aurora's synchronized (drawn) cursor during titlebar drags
  with `WindowOptions.synchronizedDragPointer = false`; the native pointer stays
  visible while dragging the window (the drawn cursor is meant for retained
  compositor-layer drags).
- `aurora.widgets.texteditor` gained `setContentCentered(bool)`: single-line
  content that fits the viewport is horizontally centered. `contentOriginX()`
  is the single source for paint, caret, selection, and hit-testing, so editing
  stays consistent; content wider than the viewport keeps normal
  `_padding - _scrollX` scrolling. The demo search box is now an empty
  `TextField` with a centered grey placeholder.

Verify: drag the titlebar (native cursor, no shake/black), and the search
placeholder is centered in the middle of the titlebar.

## Titlebar dragging: black window, snap border, shaking (2026-08-12)

Three drag artifacts were reported on the frameless demo and fixed:

1. **Black window while dragging.** The OS caption move loop (`beginSystemMove`)
   arms the resize proxy, whose snapshot ALIASED the software renderer's live
   surface. `_renderer.resize()` then reallocates that same surface in place,
   so the proxy presented garbage/black frames during the modal loop. Fix in
   `aurora.window.refreshResizeProxyFromScene`: the renderer surface's pixels
   are now COPIED into the privately-owned `_resizeSnapshot` surface instead of
   aliased.

2. **White border when dragging to the top and releasing.** The OS caption move
   loop triggers aero-snap maximize, which flashes the native (system-light)
   frame during the transition. The demo now drags owner-side instead of using
   the OS loop: `onDragStarted`/`onDragMoved` call
   `GuiWindow.setWindowPosition` (SetWindowPos), which never snaps.

3. **Entire window shaking while dragging.** Aurora mouse-event positions are
   window-relative (client) coordinates, but the first owner-drag mixed them
   with screen bounds. After each SetWindowPos, Windows synthesizes a
   WM_MOUSEMOVE inside the moved window; the recomputed absolute position then
   moved the window back → hunting/oscillation. Fixed by dragging with the
   pointer DELTA from the drag start:
   `windowOrigin + (pointer − startPointer)` — deltas are identical in
   window-relative and screen space, so the synthesized event yields zero delta
   and the loop is stable.

Verify manually in the demo: drag the titlebar (should be smooth, no black, no
shake), drag to the top edge and release (no white border / no snap), and
restore-on-drag (drag down from maximized) still works.

## TitleBar restore-on-drag: drag down to leave maximize (2026-08-12)

While a TitleBar is maximized, pressing the title and dragging past the 5px
movement threshold now leaves the maximized/fullscreen state and continues the
drag. Implementation: `TitleBar` fires `onRestoreRequested(pointer,
pressPointer)` at threshold crossing, clears its own `_maximized`, re-anchors
the drag (`_dragStartPointer`/`_dragStartPosition`) to the current pointer and
position, and proceeds. Two modes:

- **In-canvas** (self-move or owner `onDragMoved`): after restore the drag
  continues from the re-anchored pointer.
- **Native system move** (`systemMoveOnDrag`): while maximized the OS move loop
  is deferred until real movement (armed on mouse-down instead of calling
  `beginSystemMove()` immediately), so the owner can restore first; then
  `beginSystemMove()` starts the OS loop.

Added `NativeWindow.setWindowPosition(Point)` / `GuiWindow.setWindowPosition`
(Win32 `SetWindowPos`; base/headless return false). The demo's
`restoreFromDrag` exits fullscreen and re-anchors the window so the grabbed
titlebar spot stays under the pointer before the OS loop resumes.

Covered by `tests/titlebar_smoke.d`: in-canvas restore-on-drag asserts the
press pointer, the state clear, and the re-anchored final Y (start + 70 for a
40→120 downward drag); system-move restore-on-drag asserts the restore fires
and the state clears. Verify manually in the demo: maximize (double-click), then
click the titlebar and drag down — the window should restore and follow.

## Titlebar fixes: double-click maximize + white frame border (2026-08-12)

Two user-reported issues with the frameless TitleBar demo:

1. **Double-click did not maximize.** `TitleBar.onMouseDown` checked the
   `systemMoveOnDrag` branch before the double-click branch, so the second
   press of a double-click (clickCount >= 2) started another native move loop
   instead of maximizing. Fix: double-click branch now runs first. Also removed
   the `captureMouse()` before `beginSystemMove()` — the OS caption-drag loop
   owns capture and swallows the mouse-up, so the logical capture leaked.
   Covered by a smoke-test regression: with `setSystemMoveOnDrag(true)`, a
   double-click still maximizes and restores.

2. **Random white border / blink around the frameless window.** Frameless
   resizable windows are `WS_POPUP | WS_THICKFRAME`; DWM draws a 1px frame
   that was left at the system-LIGHT color (white) because `applyDarkTitleBar`
   only ran for `decorated` windows, and DWM repainted it on every activation
   change. Fix in `aurora.platform.win32`: apply the dark DWM frame attributes
   (`DWMWA_USE_IMMERSIVE_DARK_MODE`, `DWMWA_BORDER_COLOR`,
   `DWMWA_CAPTION_COLOR`, `DWMWA_TEXT_COLOR`) whenever `darkTitleBar` is set or
   the window is frameless, and return `TRUE` from `WM_NCACTIVATE` for
   frameless windows so DWM never repaints the frame on focus changes.

Verify: click/focus the demo window repeatedly and watch the border stay dark
and stable; double-click the titlebar to toggle fullscreen both ways. Headless
coverage = `tests/titlebar_smoke.d` double-click-with-system-move regression.

## Aurora OpenCode Pro native tools main; Legacy tools in Settings (2026-08-12)

The toolbar has one "Tools" checkbox (native D tools), on by default. The
legacy bash/cmd/powershell shell tool moved to a "Legacy tools" checkbox in
Settings with a "(?)" hover tooltip. New `Settings.legacyTools` (default off);
old `nativeTools` settings are migrated (native-only users → legacy off).

Verify: Pro smoke test opens Settings and asserts the Legacy tools checkbox
exists, is off by default, and its tooltip mentions the shell tool.

## Aurora Custom TitleBar widget (2026-08-12)

New reusable `aurora.widgets.titlebar.TitleBar` widget — a completely
customizable in-canvas title bar. Everything is configurable:

- `setTitle` / `setIcon` / `setShowIcon` / `setTitleAlign` (left/center/right)
- Caption buttons: `setShowMinimize/Maximize/Close`, `setCaptionButtonWidth`
- Drag: in-canvas self-move (default), owner-driven move (`onDragMoved`), or
  native OS move (`setSystemMoveOnDrag(true)` + new host `beginSystemMove()`)
- `setDoubleClickMaximizes`, `onDoubleClick`, `onSystemMenu(Point)`,
  `onMinimize/onMaximizeToggle/onClose`
- Visuals: `setBarHeight`, `setCornerRadius`, `setBackground`,
  `setInactiveBackground`, `setBorderColor`, `setTextColor`,
  `setMutedTextColor`, `setButtonHover/PressedColor`, `setCloseHover/
  PressedColor`, `setActive`, `setMaximized`
- `setContent(Widget)` puts an arbitrary widget (search box, tabs…) between the
  title and the caption buttons; `setTitleWidth` fixes the title region size.

Two framework hooks were added so the widget can drag a real frameless window:
`WidgetHost.beginSystemMove()` (interface) and `Widget.beginSystemMove()`;
`GuiWindow` already exposed it, now as an `override`.

### Build / run the demo

```
vendor\aurora-d-0.4.5\dub build --config=titlebar      # via dub
RUN-AURORA-D-TITLEBAR.cmd                               # repo-root launcher
```

The demo is a frameless window (`options.decorated=false`) whose whole top
strip is a TitleBar: native drag, custom colors, rounded top corners, a
`TextField` hosted in the bar, and a right-click system menu.

### Headless smoke test (tests\titlebar_smoke.d)

Compile exactly like the other editor smoke tests:

```
dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source tests\titlebar_smoke.d -of=build\headless-smoke\titlebar-smoke.exe -L/DEFAULTLIB:user32 -L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32 -L/DEFAULTLIB:winmm -L/DEFAULTLIB:wininet
set AURORA_RENDERER=software&& set SDL_AUDIODRIVER=dummy&& build\headless-smoke\titlebar-smoke.exe
```

Pass = prints `Aurora TitleBar smoke test passed.` Coverage (through the real
`UiTestDriver` dispatch path): caption-button callbacks, double-click maximize
toggle, right-click system menu, self-move drag by exact pointer delta,
owner-driven drag (`onDragMoved`/`onDragEnded`), hidden buttons, custom content
layout, fixed title width, active/maximized state, and two screenshots
(`titlebar-smoke.ppm` default state, `titlebar-smoke-hover.ppm` with the close
button hot). Pixel-verified with `build/headless-smoke/check_titlebar_pixels.d`
(titlebar background = `panelElevated`, window background = `windowBackground`,
close hover = `danger`).

Module unittests: `dmd -main -unittest -i -version=AuroraHeadless
-Ivendor\aurora-d-0.4.5\source vendor\aurora-d-0.4.5\source\aurora\widgets\titlebar.d
-of=build\headless-smoke\titlebar-module.exe -L/DEFAULTLIB:user32
-L/DEFAULTLIB:gdi32 -L/DEFAULTLIB:shell32 -L/DEFAULTLIB:winmm
-L/DEFAULTLIB:wininet`.

### Gotchas discovered while building it

- A drag must start only after a movement threshold (5 px): the first click of
  a double-click must not arm a drag. The plain-click path releases capture
  without moving.
- `_armDrag` MUST be cleared when the drag actually starts in `onMouseMove`,
  otherwise the next mouse-move over the bar re-arms a fresh drag and the bar
  never stops dragging (regression covered by the smoke test's hover step).
- PPM `savePpm` output is plain RGB; beware off-by-header-byte bugs when
  sampling screenshots (the header is `P6\n<w> <h>\n<max>\n`).

## Aurora OpenCode Pro per-message Copy pill removed (2026-08-12)

The top-right "Copy" pill on every message bubble was redundant with "Copy
message" in the right-click context menu; it was removed. Code-block copy
pills are unchanged (they copy just the code block).

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

### Move-to-track dialog (2026-08-13)
- Timeline clip context menu has ONE `Move to track…` item instead of a
  per-lane `Move to V1/V2/…` list, but keeps the direct
  `Move to new video track` / `Move to new audio track` commands (user
  requested they stay in the context menu).
  `openMoveToTrackDialog` in `source/auroracut/editor.d` opens a centered
  `PopupOverlay` (`move-to-track-popup`, 360x420) with a `ListView`
  (`move-to-track-list`) listing every compatible destination: video tracks +
  `New video track` when the asset has video (or for text clips), audio tracks
  + `New audio track` when it has audio. The clip's current track row is
  disabled and the first enabled row is preselected. `Move`
  (`move-to-track-apply`) or Enter/double-click moves via
  `moveSelectedToTrack` (existing selection+move path; `ensureTrack` appends
  new lanes).
- Text clips (no media asset) get the move section too (`Move to track…` +
  `Move to new video track`, video-track layers only); previously they showed
  none. Verified with a throwaway real-GUI probe (`tests/menu_probe.d`, since
  deleted) that dumps the full context menu: media clip = all three move
  commands, text clip = the two video ones.
- How to test interactively: right-click a timeline clip -> `Move to track…` ->
  pick a row -> Move; the clip relocates and the status shows
  `Moved clip to Vn at …`.
- Covered by `tests/editor_smoke.d`: menu shows `Move to track…` + `Move to
  new video track` (no `Move to V1/V2`, no `Move to new audio track` for the
  video-only overlay), dialog lists `V1/V2/V3(disabled)/New video track` for
  the video-only overlay, move to V2 and back through the same dialog restores
  the clip on V3, a text clip menu shows `Move to track…` + `Move to new video
  track` (no audio move), and the long-menu wheel-scroll assertion still runs
  on a reopened menu. Menu-row clicks use `menuItemPoint(menu, label)` which
  maps a label to its row center accounting for separators (4px) vs rows
  (22px).

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

## Aurora Cut playback rework: readiness gate, prewarm keep-alive, instant warm steps (2026-08-14)

User request: make playback performant and non-blocking, never play unless
ready, always smooth by prewarming/caching after moving the playhead, and make
per-frame playhead movement instant.

### What changed and why (verified against `editor.d` onTick + `playback.d`)

Phase 1/2 - readiness gate and audio decoupling (`editor.d`):
- `playbackReady()` is the single predicate: not awaiting first frame, not
  awaiting the audio clock, not video-buffering, and the monotonic clock valid.
  Exposed as `playbackReadyForTesting()`.
- The audio device clock is no longer a hard gate:
  - If audio cannot start (`startPlaybackAudio` fails), the buffered video
    plays muted on the monotonic clock with a status instead of retrying
    forever in `_playbackAwaitingFirstFrame`.
  - If the audio clock never becomes readable within
    `playbackAudioClockFallbackSeconds` (5 s), the transport falls back to the
    monotonic clock and plays muted instead of hanging on "Waiting for audio
    output...".
- First-frame readiness is bounded: `_playbackFirstFrameWait` accumulates while
  `_playbackAwaitingFirstFrame`; after `playbackFirstFrameTimeoutSeconds`
  (12 s) `failPlaybackStart` stops the streams and reports a failure instead of
  leaving the transport preparing forever.
- `playback.d` headless clock now freezes while paused (`_transportPaused` or
  the new `_prerollPaused`), mirroring `waveOutPause` freezing the device
  sample counter. This fixes the pre-existing `audio_clock_smoke.d` failure
  ("Paused PCM preview audio advanced before resume") and stops preroll
  buffering time leaking into the transport position.

Phase 3 - robust prewarm keep-alive and adoption (`editor.d`):
- A complete, unchanged prewarm stays alive (quiescent; the decoder blocks
  once its 16-slot queue is full). This removes the 45 s cancel/restart churn
  at the same position that the app log showed every ~45 s.
- `notePlaybackPrewarmDirty(position)` only cancels when the playhead leaves
  `_playbackPrewarmForwardWindow` (≈ two slot-queues, `32/fps` seconds) ahead
  of the prewarm start, or when the model revision changes.
- A prewarm that decoded to the end of its range (finished, no ready frames)
  is cancelled instead of being adopted dead; `startPlaybackPrewarm` skips
  positions with < 0.4 s remaining so it cannot churn at the range end.
- Direct-mode video/audio signatures dropped the launch position and duration
  (now stored separately as `_playbackPrewarm*Position/Remaining`); adoption
  matches identity + playhead-inside-forward-window + remaining-not-exceeded,
  so scrubbing or stepping within the window before Play still adopts the warm
  streams instead of respawning FFmpeg.

Phase 4 - instant forward stepping from the warm stream (`editor.d`,
`playback.d`):
- `VideoFrameStream.canTakeReadyAtOrAfter` / `takeReadyAtOrAfter` let a paused
  sequence step consume the buffered stream directly (dropping only obsolete
  frames strictly before the target), so no FFmpeg spawn and no still-renderer
  request happens for in-window forward steps.
- `tryStepSequenceFromPrewarm(value)` in `playheadChanged` serves those steps
  (guarded by `_seekPending` clear, stream running, and target >= displayed
  frame). Backward/out-of-window steps still fall back to the seek/still path.
- The first-frame handler now prefers `takeReadyAtOrAfter(playhead)` when the
  adopted decoder is ahead of the playhead, so playback starts at the playhead
  instead of the prewarm start position.

Phase 5 - non-blocking audit (`playback.d`):
- Removed the caller-thread `waveOutReset` calls from `PcmAudioPlayer`
  enqueue/stop/shutdown. The worker resets and closes the previous
  generation's sink on the worker thread when it observes the generation bump,
  so no device call can stall the event thread.

### How to verify
- `tests/editor_smoke.d`: direct playback EOF-while-buffering regression,
  prewarm adoption (no new video/audio processes on Play) all pass unchanged.
- `tests/audio_clock_smoke.d` (was failing on headless): now passes - the
  paused clock is frozen, and it advances only after resume.
- `tests/synced_playback_preroll_smoke.d` (was failing at line 112 on base):
  repaired the pre-existing wrong assertions (frame steps are debounced, not
  synchronous; a cache hit still dispatches a request but spawns no process).
  Added a warm-step block: pause -> prewarm re-warms -> step forward in-window
  -> asserts no `_seekPending`, no preview-request delta, and the buffered
  stream frame displays.
- Gate on this host: `dub test` (33 modules), editor-smoke, playback-stress,
  audio-clock-smoke, seek-resilience-smoke, static-sequence-smoke,
  synced-preroll-smoke, layout-smoke, export-smoke, gpu-decode-smoke,
  model-smoke, playback-proxy-smoke; `dub build` links the GUI app.
- Build the smoke tests on Windows (dmd, not ldc): dmd uses `-version=X` (not
  `-d-version=X`) and needs the system libs as file args:
  `dmd -i -version=AuroraHeadless -Isource -Ivendor\aurora-d-0.4.5\source
  -Luser32.lib -Lgdi32.lib -Lshell32.lib -Lwinmm.lib -Lwininet.lib tests\<name>.d
  -of=build\<name>.exe` then run with `AURORA_RENDERER=software` and
  `SDL_AUDIODRIVER=dummy`.
