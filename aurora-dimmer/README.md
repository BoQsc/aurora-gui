# Aurora Dimmer

A tiny Windows screen tint tool, built with [Aurora-D](../vendor/aurora-d-0.4.5).
It **dims** the desktop for night-time use and **brightens** it for bright-room
use.

## Tint engines

The app can tint the screen two ways. Pick with the **Full-screen filter**
checkbox in the UI, or `--filter` / `--overlay` on the command line.

- **Full-screen filter** (default) - the Windows Magnification API
  (`MagSetFullscreenColorEffect`) applies a color matrix to the whole display
  *after* compositing. It therefore also tints context menus, tooltips, the
  taskbar and other shell surfaces that a floating window cannot sit above.
  Limitation: it covers the **primary monitor only**, and it tints this app's
  own control panel too.
- **Overlay** - one or two full virtual-screen, always-on-top, click-through
  **layered Win32 windows** are blended over the desktop at a user-chosen alpha.
  It covers **every monitor**, but windows and menus placed in a higher z-order
  band (context menus, the taskbar, secure surfaces) stay at full brightness.

Either way nothing behind the tint changes: windows, games and video keep
running normally and clicks still reach them.

Both engines use an independent **dim** level (black, 0-90%) and **brighten**
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
- `--filter` - use the full-screen filter engine (default).
- `--overlay` - use the window overlay engine.

## Controls

- **Full-screen filter** checkbox - switch between the two engines.
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

- The overlay engine covers the whole virtual desktop, so multi-monitor setups
  are tinted together.
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
