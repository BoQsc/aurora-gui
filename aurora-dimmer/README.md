# Aurora Dimmer

A tiny Windows screen tint tool, built with [Aurora-D](../vendor/aurora-d-0.4.5).
It **dims** the desktop for night-time use and **brightens** it for bright-room
use.

## Tint engines

Two independent engines tint the screen. Toggle each with a checkbox in the UI,
or with command-line flags; they can run together.

- **Full-screen filter** - the Windows Magnification API
  (`MagSetFullscreenColorEffect`) applies a color matrix to the whole display
  *after* compositing. It therefore also tints context menus, tooltips, the
  taskbar and other shell surfaces that a floating window cannot sit above.
  Limitation: it covers the **primary monitor only**, and it tints this app's
  own control panel too.
- **Overlay windows** - one or two full virtual-screen, always-on-top,
  click-through **layered Win32 windows** are blended over the desktop at a
  user-chosen alpha. It covers **every monitor**, but windows and menus placed
  in a higher z-order band (context menus, the taskbar, secure surfaces) stay at
  full brightness.

When both are enabled, the filter tints the primary monitor and the overlay is
clipped to the remaining monitors, so nothing is tinted twice and every monitor
is covered. When only the overlay is enabled it covers all monitors (the
original behaviour).

Either engine uses an independent **dim** level (black, 0-90%) and **brighten**
level (white, 0-60%); the filter composes them into one per-channel scale.

## Run

```
RUN-WINDOWS.bat
```

or

```
dub run --build=release
```

Options:

- `--dim=NN` - start at NN percent darkening (0-90, clamped).
- `--brighten=NN` - start at NN percent brightening (0-60, clamped).
- `--off` - start with dimming disabled.
- `--brighten-off` - start with brightening disabled.
- `--filter` / `--no-filter` - enable/disable the full-screen filter engine.
- `--overlay` / `--no-overlay` - enable/disable the overlay engine.

## Controls

- **Full-screen filter (covers menus, taskbar)** checkbox.
- **Overlay windows (all monitors)** checkbox.
- **Darken** section: **Dim level** slider, 0-90%.
- **Brighten** section: **Brighten level** slider, 0-60%.
- **Dimming enabled** and **Brightening enabled** checkboxes.
- Preset buttons: 0 / 25 / 45 / 65 / 85% for dim, 0 / 15 / 30 / 45 / 60% for
  brighten.

Closing the window removes both tints.

## Test

```
RUN-HEADLESS-SMOKE.bat
```

Builds `tests/headless_smoke.d` with DMD, paints the control panel through
Aurora's test driver, and checks the dim/brighten math, the filter color-matrix
math, and both overlay windows.

## Notes

- The overlay engine covers the whole virtual desktop; when the filter is also
  on it is clipped with `SetWindowRgn` to everything outside the primary
  monitor.
- Each overlay uses `WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW |
  WS_EX_NOACTIVATE` plus `SetLayeredWindowAttributes`; the solid fill comes from
  the window class background brush (black or white).
- The filter engine loads `Magnification.dll` at runtime (`LoadLibrary` +
  `GetProcAddress`) and calls `MagInitialize`,
  `MagSetFullscreenTransform(1.0)` and `MagSetFullscreenColorEffect`; identity
  (scale 1.0) is used when no tint is active, and `MagUninitialize` plus
  `FreeLibrary` run on exit. If the API is unavailable the filter simply has no
  effect and the overlay engine still works.
- Level 0 and "enabled off" both mean no tint.
- Brightening raises the black level at the cost of contrast; the level is
  capped at 60% to keep it usable.
