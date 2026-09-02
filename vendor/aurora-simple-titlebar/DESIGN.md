# Simple titlebar design notes

The target is a quiet Windows 10-style titlebar, not a general-purpose chrome
system. The first pass uses one visual treatment rather than app presets.

## Baseline

- Frameless Aurora window with a 23 logical-pixel titlebar.
- 36 logical pixels per caption button, stacked close/maximize/minimize from
  right to left. This corresponds to the measured 46-pixel button at 125% DPI.
- 12 logical-pixel Segoe UI caption text, matching the Windows 10 9-point
  caption reference. The title size is explicit instead of inheriting the
  application's body text tier.
- 16 logical-pixel application icon with an 8-pixel title gap.
- Light active and inactive states close to the Windows 10 caption palette.
- Full-width, square hover feedback on caption buttons; close uses the Windows
  red hover treatment.
- Text and icon geometry scale through Aurora's logical/DPI coordinate system.

## Boundary

SimpleTitleBar owns rendering and pointer semantics. Its owner owns window
state and platform policy through callbacks. The widget may request the host's
native system move loop, but it does not know whether that loop is Win32,
X11, Cocoa, or an owner-driven fallback.

The existing aurora.widgets.titlebar remains the behavior reference for
maximize, restore, snap, and frameless-window integration. Those features can
be added to this design deliberately; they are not smuggled in through a
large set of app-specific presets.
