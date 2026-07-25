module tests.public_api;

/** Compile and runtime smoke test for the supported aggregate import. */

import aurora;
import std.stdio : writefln;

int main()
{
    static assert(AuroraVersion == "0.4.5");
    static assert(UnicodeDataVersion == "17.0.0");

    static assert(fontPixelSize(cast(int) TextScale.caption) == 13);
    static assert(fontPixelSize(cast(int) TextScale.body) == 17);
    static assert(fontPixelSize(cast(int) TextScale.heading) == 22);
    static assert(fontPixelSize(cast(int) TextScale.display) == 30);
    assert(fontScaleForPixelSize(17) == cast(int) TextScale.body);

    auto defaultTheme = Theme.light();
    assert(defaultTheme.fontScale == cast(int) TextScale.body);
    assert(defaultTheme.controlHeight >= 38);

    auto measuredButton = new Button("New", IconKind.newDocument);
    assert(measuredButton.layoutHints().preferredHeight >= 38);
    assert(measuredButton.layoutHints().preferredWidth >= 70);

    auto standardList = new ListView();
    assert(standardList.rowHeight() >= 44);

    auto surface = new Surface(8, 8);
    surface.clear(Color.rgb(12, 34, 56));
    surface.fillRect(Rect(2, 2, 4, 4), Color.rgba(200, 100, 50, 128),
        Rect(0, 0, 8, 8));

    assert(surface.size == Size(8, 8));
    assert(surface.pixel(0, 0) == Color.rgb(12, 34, 56).argb());
    assert(surface.pixel(3, 3) != surface.pixel(0, 0));

    auto drawList = new DrawList();
    drawList.reset(Size(8, 8), Color.rgb(0, 0, 0));
    drawList.addSolidRect(Rect(1, 1, 6, 6), Color.rgb(255, 255, 255),
        Rect(0, 0, 8, 8));
    assert(!drawList.empty);

    WindowOptions options;
    options.width = 64;
    options.height = 48;
    options.renderer = RendererPreference.software;
    options.startFullscreen = true;
    assert(options.lowLatency);
    auto window = new GuiWindow(options);
    assert(window.fullscreen());

    window.setFullscreen(false);
    assert(!window.fullscreen());
    window.toggleFullscreen();
    assert(window.fullscreen());

    Event shortcut;
    shortcut.type = EventType.keyDown;
    shortcut.key = Key.f11;
    window.onNativeEvent(shortcut);
    assert(!window.fullscreen());

    shortcut.repeat = true;
    window.onNativeEvent(shortcut);
    assert(!window.fullscreen());

    shortcut = Event.init;
    shortcut.type = EventType.keyDown;
    shortcut.key = Key.enter;
    shortcut.modifiers = cast(uint) KeyModifier.alt;
    window.onNativeEvent(shortcut);
    assert(window.fullscreen());

    shortcut = Event.init;
    shortcut.type = EventType.keyUp;
    shortcut.key = Key.escape;
    window.onNativeEvent(shortcut);
    assert(window.fullscreen());
    shortcut.type = EventType.keyDown;
    window.onNativeEvent(shortcut);
    assert(!window.fullscreen());
    window.close();

    WindowOptions disabledOptions;
    disabledOptions.width = 32;
    disabledOptions.height = 24;
    disabledOptions.renderer = RendererPreference.software;
    disabledOptions.enableFullscreenShortcut = false;
    auto disabledWindow = new GuiWindow(disabledOptions);
    shortcut = Event.init;
    shortcut.type = EventType.keyDown;
    shortcut.key = Key.f11;
    disabledWindow.onNativeEvent(shortcut);
    assert(!disabledWindow.fullscreen());
    disabledWindow.close();

    // Pointer capture must apply the newest global pointer position directly
    // to an in-canvas desktop window and stop moving after button release.
    WindowOptions dragOptions;
    dragOptions.width = 400;
    dragOptions.height = 300;
    dragOptions.renderer = RendererPreference.software;
    auto dragHost = new GuiWindow(dragOptions, Theme.dark());
    auto desktop = new DesktopSurface();
    auto floating = desktop.addWindow(new FloatingWindow(
        "Drag regression", IconKind.notepad, new Label("Content")));
    floating.setBounds(Rect(40, 50, 200, 140));
    dragHost.setRoot(desktop);

    Event pointer;
    pointer.type = EventType.mouseDown;
    pointer.button = MouseButton.left;
    pointer.globalPosition = Point(60, 60);
    pointer.timestampMs = 100;
    dragHost.onNativeEvent(pointer);

    pointer = Event.init;
    pointer.type = EventType.mouseMove;
    pointer.globalPosition = Point(130, 100);
    pointer.timestampMs = 108;
    dragHost.onNativeEvent(pointer);
    assert(floating.bounds() == Rect(110, 90, 200, 140));

    pointer = Event.init;
    pointer.type = EventType.mouseUp;
    pointer.button = MouseButton.left;
    pointer.globalPosition = Point(130, 100);
    pointer.timestampMs = 116;
    dragHost.onNativeEvent(pointer);

    pointer = Event.init;
    pointer.type = EventType.mouseMove;
    pointer.globalPosition = Point(200, 160);
    pointer.timestampMs = 124;
    dragHost.onNativeEvent(pointer);
    assert(floating.bounds() == Rect(110, 90, 200, 140));
    dragHost.close();

    writefln("Aurora-D public API %s; Unicode %s", AuroraVersion,
        UnicodeDataVersion);
    return 0;
}
