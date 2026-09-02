# aurora-simple-titlebar

aurora-simple-titlebar is an experimental, reusable titlebar rendered
entirely by Aurora. It intentionally resembles the Windows 10 titlebar while
remaining a normal cross-platform Aurora widget.

This is a new visual take, not a replacement for aurora.widgets.titlebar. The
existing titlebar remains stable in vendor/aurora-d-0.4.5; this component is
opt-in until its design and behavior are accepted.

## What it does

- Draws the background, application icon, title, and caption buttons with
  Aurora's Canvas.
- Handles hit testing, hover, pressed states, right-click system-menu intent,
  and double-click maximize intent.
- Uses the Aurora host's platform-neutral system move hook when available.
- Falls back to owner callbacks for hosts that want to implement movement
  themselves.
- Defaults to measured Windows 10 caption metrics: 23 logical pixels high,
  36 logical pixels per caption button, and a 12-pixel title caption. Use
  `setTitleFontSize(0)` to opt back into the host theme's text tier.
- Keeps window operations as callbacks, so the widget does not call Win32,
  X11, or Cocoa APIs directly.

## Run the reference

    cd vendor/aurora-simple-titlebar
    dub run --compiler=dmd

The reference app is deliberately only a titlebar and a small inspection
surface. It is where we can compare geometry and interaction against the
existing titlebar before adopting the new design in an application.

For a deterministic software-rendered capture, use:

    dub run --compiler=dmd -- --screenshot build/simple-titlebar.ppm

## Use the widget

    import aurorasimpletitlebar.titlebar;

    auto bar = new SimpleTitleBar();
    bar.setTitle("Untitled - Aurora");
    bar.setIcon(IconKind.notepad);
    bar.onMinimize = delegate() { window.minimize(); };
    bar.onMaximizeToggle = delegate() { /* owner updates window bounds */ };
    bar.onClose = delegate() { window.close(); };
    root.add(bar);
