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
