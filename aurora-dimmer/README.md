# Aurora Dimmer

A tiny Windows screen tint tool, built with [Aurora-D](../vendor/aurora-d-0.4.5).
It **dims** the desktop for night-time use and **brightens** it for bright-room
use.

Each effect is a full virtual-screen, always-on-top, **click-through layered
Win32 window** blended over everything at a user-chosen alpha:

- the **dimmer** paints black, lowering apparent brightness; and
- the **brightener** paints white, lifting the black level of dark content.

Nothing behind them changes: windows, games and video keep running normally and
clicks still reach them. The two layers are independent and can be combined.

The control panel is an ordinary Aurora window, re-raised above the tint layers
whenever a level changes.

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

## Controls

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
Aurora's test driver, and checks the dim/brighten math and both overlay windows.

## Notes

- The overlays cover the whole virtual desktop, so multi-monitor setups are
  tinted together.
- Each overlay uses `WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW |
  WS_EX_NOACTIVATE` plus `SetLayeredWindowAttributes`, applied directly from
  the app via the Aurora window's native `HWND` - no vendor patch required. The
  solid fill comes from the window class background brush (black or white).
- Level 0 and "enabled off" both blend at alpha 0, i.e. no tint.
- Brightening is a white wash, so it lifts the black level at the cost of
  contrast; the level is capped at 60% to keep it usable.
