# Aurora Dimmer

A tiny Windows night-time screen dimmer, built with [Aurora-D](../vendor/aurora-d-0.4.5).

The desktop is darkened by a full virtual-screen, always-on-top,
**click-through layered Win32 window** blended over everything at a
user-chosen alpha. Nothing behind it changes: windows, games and video keep
running normally and clicks still reach them.

The control panel is an ordinary Aurora window, re-raised above the dim layer
whenever the level changes.

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
- `--off` - start with dimming disabled.

## Controls

- **Dim level** slider, 0-90%.
- **Dimming enabled** checkbox.
- Preset buttons: 0 / 25 / 45 / 65 / 85%.

Closing the window removes the darkening.

## Test

```
RUN-HEADLESS-SMOKE.bat
```

Builds `tests/headless_smoke.d` with DMD, paints the control panel through
Aurora's test driver, and checks the dim math and the overlay window.

## Notes

- The overlay covers the whole virtual desktop, so multi-monitor setups are
  dimmed together.
- It uses `WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW |
  WS_EX_NOACTIVATE` plus `SetLayeredWindowAttributes`, applied directly from
  the app via the Aurora window's native `HWND` - no vendor patch required.
- Level 0 and "dimming enabled off" both blend at alpha 0, i.e. no darkening.
