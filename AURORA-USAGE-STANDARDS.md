# Aurora GUI usage standards

These rules exist because each one maps to a real, repeated bug in this repo.
Follow them when building anything on `vendor/aurora-d-0.4.5` (and Aurora apps
such as `aurora-desktop`). If you find a new class of bug, add a rule here and a
regression test next to it.

Keep it factual and short. Do not guess: measure with a probe first.

---

## 1. Time, timers, and animation (the NaN trap)

**D floating-point fields default to `NaN`, not `0.0`.** Any `accumulator += delta`
that starts uninitialised becomes `NaN` forever, and `NaN >= threshold` is always
false, silently disabling the timer.

- Always initialise timer/accumulator fields explicitly:
  ```d
  private double _refreshAccumulator = 0.0;
  ```
- The platform's **first frame can report `deltaSeconds = NaN`**. A single NaN
  poisons every downstream accumulator. `GuiWindow.onNativeTick` sanitizes it
  (`if (delta != delta || delta < 0) delta = 0.0;`) - do not remove that guard,
  and do not re-introduce raw platform deltas elsewhere.
- Never gate work on `x >= threshold` when `x` can be NaN. Use a monotonic frame
  counter or guard with `x == x`.
- Animation must be driven from `onTick`; call `invalidate()` whenever the frame
  changes.

Regression pattern: tick once with `double.nan`, then normally, and assert the
scheduled work still ran (see `headless_smoke` `notificationRefreshCountForTesting`).

## 2. Raster images and icons

`aurora.image.RgbaImage` is **straight-alpha RGBA8**. The renderer expects that.

- **Do not pre-blend.** `DrawIconEx(DI_NORMAL)` onto a background alpha-blends the
  icon and darkens/softens its anti-aliased edges. Read the source's own pixels
  instead.
- Extract an `HICON` from its own colour bitmap first:
  `GetIconInfo -> hbmColor -> GetDIBits` (32 bpp, top-down). Only fall back to
  `DrawIconEx` + the AND mask (`hbmMask`) when the colour bitmap has no alpha
  (legacy mask-based icons). Do not use `CreateCompatibleBitmap` (a DDB has no
  alpha) as the primary capture surface.
- Always validate the result before using it:
  - reject null and all-transparent images (`iconHasInk` / `bitmapHasContent`),
  - provide a fallback glyph so a slot is never blank.
- **DPI:** the target is physical pixels. Prefer a source at least as large as
  the target (`logical * dpi/96`); display logical = physical / scale so it is
  1:1. Under 125% DPI, a 16-logical slot = 20 px (matches the common 20 px tray
  icon). Never upscale when a same-or-larger source is available.
- `canvas.drawImage(dest, image)` uses linear filtering by default; that is the
  right default for icons, nearest for pixel art.

## 3. Popups and hit-testing

- `TransientPopup` overlays the **whole root** for click-away. By default its
  `hitTest` claims every point, which steals hover from the widgets beneath it
  (this caused the task-preview flicker).
  Override `hitTest` to return `this` only inside the panel and `null` elsewhere,
  and override `popupContains` for press-away detection.
- For hover-opened flyouts use **hover intent**: a short show delay, a hide grace
  window, and a `pointerInside()` check so the pointer can travel from the anchor
  onto the flyout without it flickering closed.
- Dismiss on click-away / Escape via `dismissPopupForPointer`; do not swallow
  presses outside the panel.

## 4. Composited layers and invalidation

- Composited widgets are retained layers; they rebuild only when dirty.
- If a widget paints content whose position changes every pointer sample (a task
  being dragged, a moving list), it **must call `invalidate()` on every sample**,
  not only on discrete state changes, or it appears stuck and then jumps.
- After any model mutation that changes pixels, call `invalidate()`. Prefer
  updating an existing entry in place (`updateNotification`) over clear+rebuild
  so in-progress interactions and stable ids are preserved.
- A hidden floating proxy does **not** move the visible element; the visible
  in-row paint must be repainted by invalidating the owning layer.

## 5. Taskbar / tray model contracts (aurora-desktop)

- External OS windows are keyed by `hwnd`; group them by a stable app key
  (executable path, with UWP `ApplicationFrameHost` resolved to the hosted
  process).
- Notification identity must be stable and must **not** include the volatile
  tooltip: use `exePath + hwnd + id`. Tooltips (CPU %, battery %) change every
  second and would otherwise look like a brand-new icon each poll.
- Keep stable numeric ids per notification so hide/show overrides and reorder
  survive the periodic refresh.
- Never persist live OS windows as pinned tasks.
- Refresh tray icons in place each poll (`updateNotification`) to keep animation;
  do a structural clear+re-add only when the icon set, order, or hidden state
  actually changes.
- A refresh must not disturb an in-progress drag (check `dragging()`), and an
  open flyout (e.g. the overflow panel) must be refreshed from the live model;
  it is a snapshot otherwise.

## 6. Win32 interop

- druntime does not bind everything (e.g. `QueryFullProcessImageNameW`,
  `Shell_NotifyIconGetRect`). Declare missing `extern(Windows)` prototypes
  locally rather than guessing or skipping the feature.
- Validate every cross-process read: `IsWindow`, non-zero handles, `OpenProcess`
  result, `ReadProcessMemory` return, and bounds of any structure read from
  another process. Degrade to fewer results, never crash.
- Free GDI objects you create (`DeleteObject` for bitmaps, bitmaps returned by
  `GetIconInfo`; `DestroyIcon` for icons you created or the shell returned).
  Never delete handles owned by the target process.
- Use `PROCESS_QUERY_LIMITED_INFORMATION` for owner paths.

## 7. Verification discipline

- **Measure, do not guess.** Write a small probe that prints numbers (alpha
  stats, pixel hashes, counters, icon sizes) before and after a change. Keep the
  probe source so it can be re-run.
- Screenshots are unreliable for the Vulkan window (`CopyFromScreen`/`PrintWindow`
  can return a static/blank frame). For GUI-only behaviour, add a **gated
  real-process debug log** (env var) and read it back; remove the gate after.
- Every fixed bug gets a **regression test** (headless where possible).
- Baseline check before/after: `build\headless-smoke.exe` must stay
  `ALL PASSED`.

## 8. Build and run discipline (aurora-desktop / aurora-opencode-pro)

- `dub build` writes the exe to the **package root**, not `build/`. Launch the
  root exe and verify the titlebar build stamp matches the build you just ran.
- **Kill the running instance before rebuilding** (the exe is locked), then
  relaunch exactly **one** instance. Do not report done without relaunching.
- Kill command (cmd.exe): `taskkill /F /PID <pid>`.
- A stale `build\<app>.exe` is a different (test) binary; never use it for the
  smoke/repro of the real app.

## 9. New feature checklist

Before considering a taskbar/tray/icon feature done:

1. Data source measured (probe), not assumed.
2. All timer fields initialised; NaN deltas handled.
3. Raster icons: exact straight-alpha pixels, ink-validated, DPI 1:1 when possible.
4. Popups override `hitTest`/`popupContains`; hover uses delay+grace+inside.
5. Composited layers invalidated on every visual change.
6. Stable identities; in-place refresh; no persistence of transient OS state.
7. Graceful degradation on API/handle failure.
8. Regression test + `headless-smoke` green.
9. Rebuilt, old instance killed, exactly one relaunched, build stamp verified.

## 10. Signed/unsigned index traps (`indexOf` / `lastIndexOf` / ternary)

`std.string.indexOf`/`lastIndexOf` return **`ptrdiff_t`**, and `-1` means "not
found". The trap is the ternary: **D's common type of `size_t` and `ptrdiff_t` is
`ulong`** (verified: `typeof(true ? size_t(0) : ptrdiff_t(-1))` is `ulong`).

```d
// WRONG: `at` is ulong, so `at < 0` is dead and -1 becomes size_t.max.
// The slice/concatenation below then copies size_t.max bytes -> access
// violation inside msvcr120!memcpy with R8 = 0xFFFFFFFFFFFFFFFF.
const at = oldBlock.length == 0
    ? searchPos : content.indexOf(oldBlock, searchPos);
if (at < 0) { ... }                                  // never taken
content = content[0 .. at] ~ block ~ content[at + ... .. $];
```

Rule: never let the signed result meet an unsigned value in one expression. Keep
it signed, test it, **then** widen:

```d
const found = content.indexOf(oldBlock, searchPos);
if (found < 0) { /* not found */ return; }
const at = cast(size_t) found;
```

This bug class has recurred (the markdown inline-link parser and the
`apply_patch` `flushHunk`). Whenever an `indexOf`/`lastIndexOf` result feeds a
slice, add a regression test that passes a needle which is **absent** (or a
stray bracket, or a patch hunk with no matching context). Existing guards:
`markdown.d` `verifyStrayBracketParsing`, `tools_test.d` "apply_patch reports a
missing context instead of crashing".

## 11. Crash triage without a debugger

- The app's own `logs/dumps/*.dmp` may be 0 bytes (the in-process
  `MiniDumpWriteDump` can fail on the dying thread). Do not stop there: Windows
  writes **full-memory dumps** to `%LOCALAPPDATA%\CrashDumps\<exe>.<pid>.dmp`.
- `scripts/analyze-crashdump.py <dump> <exe>` prints the exception code/address,
  the faulting module + offset, the general-purpose registers (for a `memcpy`
  fault read `RCX`/`RDX` as the buffers and `R8` as the length), and a
  RBP-walked stack symbolized through the sibling `.pdb` with `dbghelp`
  `SymFromAddr` (the legacy `SymGetSymFromAddr64` misses non-public symbols).
- The app's `logs/native-crash.log` records the last activity
  (`noteActivity`), e.g. `rebuild slot=… role=assistant toolCalls=1`. Combine it
  with the dump stack to name the exact source line. A fault address inside
  `msvcr120`/`ntdll` is almost always a bad length handed to `memcpy`, not a
  bug in that DLL.
- The `last-activity` line and the fault address repeat across runs when the
  input is deterministic; "it crashed at the same address again" means the fix
  did not touch that path - keep the evidence, do not add another guess.

## 12. Self-modifying apps: never rebuild or kill from inside

Aurora OpenCode is an agent that edits its own source. The agent process and the
app being rebuilt are the same process:

- Running `dub build`, `taskkill`, or the app's **Rebuild** action from inside
  replaces/terminates the process hosting the session. The supervisor then
  relaunches it and the session is lost - this is what produced "you keep
  killing yourself" and hundreds of restarts.
- The safe loop is external: **edit source -> build -> kill the old instance ->
  launch exactly one**. The in-app agent should make source-only edits and let
  an external operator (or the deterministic rebuilder, which waits for the
  file lock) do the build.
- The linker truncates the exe before writing it. `aurora-cli.d` and
  `rebuilder.d` both back the exe up before building and restore it if the link
  fails or leaves a 0-byte file. Do not build directly against a running exe,
  and do not remove those guards.
- A crash loop is diagnosable from the artifacts above; adding speculative
  guards to a crash without the fault stack wastes rebuild cycles (and each
  rebuild kills the session). Get the stack first.

## 13. Restored-session identity and reload safety

- The state directory holds several snapshots of the same conversations
  (`sessions.json`, `sessions.recovery.json`, `sessions.json.bak`). Merge them
  by a **stable identity**, not `title + first content`: every untitled chat is
  `"New chat"`, and a scripted run can be byte-identical. A weak key merges
  independent conversations and drops one, which shifts every later index.
- Message ids are minted once and copied into every snapshot; use the first
  message id (content only as a fallback for legacy files). Repair the message
  graph (`ensureMessageGraph`) **after** merging, never during parsing -
  repairing first mints ids for legacy messages and makes the same file look
  like two conversations.
- After a restore that can change the session count, clamp `_current`
  (`< 0 || >= _sessions.length -> 0`, or `-1` when empty). A stale index faults
  on `_sessions[_current]`.
- Skip quarantined `.bad` / `.preserve-*` files when scanning for snapshots;
  they are known-unreadable and only reproduce the same error every launch.
- Test helpers that append messages must call `markDirty()` exactly like the
  production path, or the immediate recovery snapshot goes stale and the reload
  test is not testing production behaviour.
