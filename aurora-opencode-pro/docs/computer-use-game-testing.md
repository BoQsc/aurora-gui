# Driving a real game with the `computer` tool

Notes from completing Company of Heroes' Basic Training through the tool. They
are here because the same traps will bite again: none of this is model memory,
so it has to live in the repository.

## Input facts that cost hours to rediscover

- **Positioned moves must also emit motion.** `SetCursorPos` repositions the
  Windows cursor but sends no motion packet, so a DirectInput title keeps its
  own cursor: hover highlights, edge pan and wheel zoom stay dead while clicks
  (button messages) work fine. `moveCursor` therefore sweeps the internal cursor
  into its top-left clamp with a large negative relative move and then offsets it
  to the target. A hover test — does a button highlight? — separates "the game
  ignores motion" from "the coordinates are wrong" in one call.
- **The wheel delta belongs in the high word.** `MOUSEEVENTF_WHEEL` reads a
  signed delta from the high word of `mouseData`; writing it low makes every
  scroll arrive as 0. One notch is 120; keep to multiples so engines that filter
  odd deltas still accept the event.
- **Navigation keys need `KEYEVENTF_EXTENDEDKEY`.** Page Up/Down, arrows,
  Home/End, Insert/Delete injected without it arrive as their numpad twins, so a
  game bound to Page Up/Down never sees the press.

## Operating rules for this kind of session

- **Only read coordinates from native-resolution frames.** Captures can come
  back downscaled (e.g. ~1066 px wide for a 1920 px desktop); aiming with
  downscaled readings is off by ~1.8x and looks exactly like "wrong coordinates".
- **A fullscreen game pauses when it loses foreground**, and it keeps a pause
  menu open after focus returns. Act in one batch — `focus`, resume if the menu
  is up, then the input, then a screenshot — so the game is never de-focused
  mid-step. A hover sent while the menu is open silently does nothing.
- **Prefer the game's own affordances.** TAB cycles squads, a minimap click pans
  the camera, Space focuses an event cue, Backspace twice resets the camera
  (which also restores the default zoom, so it is not a zoom lesson).
- **Right-click orders need the marker itself**, not its caption; the marker
  survives until the squad arrives, so a still-visible marker right after the
  order is not proof of failure — wait for the walk.

## Verification that actually means something

Trust the game's own words over the picture: "Good. …", "Point Captured",
"Basic Training Complete". A changed frame alone can be an animation; the
lesson's confirmation text is the assertion. For the product itself, the wheel
path is provable outside games (scroll a browser page and compare frames).
