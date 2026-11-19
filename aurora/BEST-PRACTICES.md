# Aurora v2 best practices

These are the rules worth carrying forward. They compress the framework usage
standards, the quality ratchet, and the host responsibility contract into one
short guide. Detailed explanations remain in `aurora-d/docs/` and
`aurora-host/RESPONSIBILITY.md`.

## 1. Ownership

- **The host is the primary GUI path.** New GUI products start as validated
  scenes run by `aurora-host`. Do not create a new executable around
  `GuiWindow` to deliver an application; direct window construction is limited
  to host internals, framework tests, and an owner-approved specialized
  embedder. Existing direct-window applications are migration sources, not
  examples.
- **The host stays a leaf.** Applications do not import or link `aurora-host`.
  They provide a scene and use the versioned control/shared-surface contract for
  domain behavior.
- **The library owns GUI behavior.** Rendering, text layout, widget layout,
  input routing, the retained compositor, DPI conversion, and window-shell
  behavior belong in `aurora-d`.
- **An application owns its content and policy.** It supplies data, scenes, and
  product decisions; it does not fork framework behavior into a private copy.
- **The host owns the retained UI shell.** `aurora-host` parses and validates
  scenes, owns the window, layout, painting, input routing, frame clock, DPI
  scaling, and the control surface. It does not own application domain policy.
- The host may depend on `aurora-d` and `aurora-standard`. No framework or
  application package may depend on the host.

## 2. One framework source

- **Aurora Canvas and text are the top priority for new app rendering.** All
  2D app UI and content use `aurora.Canvas` plus `aurora.text`/`FontSystem`.
  Do not use GDI, DirectWrite, FreeType, a private glyph atlas, a private text
  layout engine, or a private rounded-rect/icon rasterizer in an application.
  Domain rasterizers remain allowed only for content Aurora cannot express, such
  as a 3D software renderer, and must not become the app's UI stack.
- All applications use the same `aurora-d` source. When an application finds a
  better default, fix the framework; do not keep a private text, theme,
  rendering, window-shell, or hit-testing policy beside it.
- The v2 tree holds one library copy. Do not copy it into an application, and do
  not place a version number in its folder name.
- Shared behavior belongs in the narrowest framework module, with a regression
  test, before the application copy is removed.

## 3. Promotion requires evidence

Changing a framework default is not a local edit:

1. Reproduce and measure the current behavior without changing it.
2. Keep the current default as A and the proposal as B behind a test-only switch
   or isolated branch.
3. Decide whether the change is product policy or general GUI behavior.
4. Run framework regressions and application smoke tests against both A and B.
5. Capture same-size A/B images for affected themes, DPI scales, and renderers;
   include measurements for performance or input changes.
6. Show the evidence to the project owner. Only the owner approves A, B, neither,
   or another candidate. Silence is not approval.
7. After approval, move the mechanism into the framework, add a regression, and
   remove the application copy.

Recency is not evidence of quality. A newer application only supplies a
candidate.

## 4. Timers and floating point

D floating-point fields default to `NaN`, not `0.0`.

- Initialize every timer and accumulator explicitly.
- Treat a platform `deltaSeconds` that is `NaN` or negative as `0.0`; the first
  frame can deliver one.
- Do not gate work on a comparison when the value can be `NaN`. Guard with
  `x == x` or use a frame counter.
- Drive animation from `onTick` and invalidate when the frame changes.

## 5. Layers, invalidation, and retained content

- Composited widgets are retained layers; they rebuild when dirty.
- After any model change that alters pixels, call `invalidate()`.
- Content that moves on every pointer sample must invalidate on every sample, not
  only on discrete state changes.
- Update an existing item in place when identity must survive a refresh (taskbar
  entries, tray notifications, live rows). Use clear-and-rebuild only when the
  set or order really changed.
- A hidden proxy does not move the visible element; repaint the owning layer that
  draws the visible state.

## 6. Popups and hit-testing

- A `TransientPopup` may cover the root for click-away. Override `hitTest` so only
  its panel claims the pointer; otherwise it steals hover from the widgets below.
- Override `popupContains` for press-away detection.
- Hover flyouts use hover intent: a show delay, a hide grace window, and a
  pointer-inside check so the pointer can travel from the anchor to the flyout.
- Dismiss on click-away or Escape without swallowing unrelated presses.

## 7. Images and icons

- `RgbaImage` is straight-alpha RGBA8. Do not pre-blend.
- Read an icon's own colour bitmap (`GetIconInfo` then `GetDIBits`) before falling
  back to `DrawIconEx` plus the AND mask for legacy mask icons.
- Validate an icon or bitmap before use: reject null and fully transparent
  images, and always provide a fallback glyph.
- Target physical pixels. Prefer a source at least as large as the target; do not
  upscale when a same-or-larger source exists.

## 8. Frameless windows

- Use `FramelessWindowTitleBar`; Aurora owns movement, work-area maximize and
  restore, snap preview, and the owner-drawn system menu.
- An application owns its title, icon, palette, sizing, and middle content.
- Product minimize-to-tray and close behavior belongs in the title bar's
  actions, not in a copied window-shell state machine.

## 9. Windows interop

- Declare missing `extern(Windows)` prototypes locally instead of guessing or
  skipping a feature.
- Validate every cross-process read: window handles, process handles, memory
  reads, and structure bounds. Degrade to fewer results; never crash.
- Free GDI objects you create; never delete handles owned by the target process.
- Use `PROCESS_QUERY_LIMITED_INFORMATION` for owner paths.

## 10. Signed/unsigned index traps

`indexOf` and `lastIndexOf` return `ptrdiff_t`, and `-1` means "not found". D's
common type of `size_t` and `ptrdiff_t` is `ulong`, so a ternary can silently turn
`-1` into `size_t.max` and make an `at < 0` guard dead.

Keep the result signed, test it, then widen:

```d
const found = content.indexOf(block, start);
if (found < 0) return;
const at = cast(size_t) found;
```

Any `indexOf` result that feeds a slice needs a regression test with an absent
needle or unmatched context.

## 11. Verification discipline

- **Measure, do not guess.** Write a probe that prints numbers (pixel hashes,
  counters, alpha statistics, icon sizes) before and after a change, and keep it.
- Prefer deterministic headless rendering and real UI-driver events over
  screenshots of a live window. A screenshot proves only what it shows.
- Every fixed bug gets a regression test.
- Never judge behavior from a stale binary. Rebuild the executable you actually
  run, and verify the build stamp or file hash.
- A green compilation is not a behavioral pass; run the relevant check.

## 12. Build and run

- `dub build` writes the executable to the package root, not `build/`.
- Start new GUI work from an `aurora-host` scene. The `GuiWindow` examples in
  `aurora-d/docs/` document library mechanisms; they are not an application
  scaffold.
- Do not rebuild over a running executable on Windows; stop the instance first,
  rebuild, then launch exactly one new instance.
- GUI executables on Windows link with `/SUBSYSTEM:WINDOWS` and
  `/ENTRY:mainCRTStartup` so no console window appears.
- A distributable Windows release uses the `portable-release` build type with
  `-mscrtlib=libcmt`; ordinary local builds may use the bundled DMD runtime.

## 13. Keep the v2 tree clean

- No generated build output or copied binaries in source packages.
- No second copy of the text standard, the library, or a demo application.
- No new standalone `GuiWindow` application package; the host scene is the
  application contract.
- Put a rule here only when it maps to a real, repeated bug; add its regression
  next to the code.
