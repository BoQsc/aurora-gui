module aurora.platform.base;

import aurora.event : Event;
import aurora.font : FontRenderMode;
public import aurora.render.base : RendererPreference;
import aurora.types : CursorKind, DisplayScale, PointF, Size;

enum NativeSurfaceKind : ubyte
{
    none,
    xlib,
    win32,
    metal
}

/** Opaque platform handles required by a presentation renderer. */
struct NativeSurfaceInfo
{
    NativeSurfaceKind kind;
    void* handleA;
    void* handleB;
    ulong value;
}

struct WindowOptions
{
    string title = "Aurora";
    string iconPath;
    int width = 960;
    int height = 640;
    int x = int.min;
    int y = int.min;
    bool resizable = true;
    bool decorated = true;
    bool alwaysOnTop;
    bool startMaximized;
    /** Start in native monitor fullscreen. Takes precedence over maximized. */
    bool startFullscreen;
    /** Let GuiWindow consume F11, Alt+Enter, and fullscreen Escape. */
    bool enableFullscreenShortcut = true;
    /** Favor newest pointer-driven frames over queued throughput. */
    bool lowLatency = true;
    /** Render a frame-synchronized Aurora cursor during transform drags. */
    bool synchronizedDragPointer = true;
    RendererPreference renderer = RendererPreference.automatic;
    bool vulkanValidation;
    bool vsync = true;
    string uiFontPath;
    string monospaceFontPath;
    FontRenderMode fontRenderMode = FontRenderMode.sharp;
}

interface NativeWindowSink
{
    void onNativeEvent(ref Event event);
    bool onNativePaint();
    void onNativeTick(double deltaSeconds);
    bool onNativeCloseRequested();
    void onNativeShutdown();
}

abstract class NativeWindow
{
    protected NativeWindowSink sink;
    protected WindowOptions options;

    this(WindowOptions options, NativeWindowSink sink)
    {
        this.options = options;
        this.sink = sink;
    }

    abstract void show();
    abstract int run();
    abstract void invalidate();
    abstract void present(const(uint)[] pixels, int width, int height);
    abstract void setTitle(string title);
    abstract void setCursor(CursorKind cursor);
    /** Hide/show the host cursor; false means the backend cannot guarantee it. */
    bool setPointerVisible(bool visible)
    {
        return false;
    }
    /** Enter or leave native monitor fullscreen. */
    abstract void setFullscreen(bool value);
    /** Current or requested native fullscreen state. */
    abstract bool fullscreen() const;
    abstract void close();
    abstract Size clientSize() const;

    final void toggleFullscreen()
    {
        setFullscreen(!fullscreen());
    }

    /** Physical pixel extent consumed by Vulkan or the software presenter. */
    Size framebufferSize() const
    {
        return clientSize();
    }

    /** Logical-to-physical scale for the monitor currently containing the window. */
    DisplayScale displayScale() const
    {
        return DisplayScale.init;
    }

    /**
     * Sample the newest native pointer position in subpixel Aurora logical units.
     * Backends may return false when the host cannot query pointer state directly.
     */
    bool queryPointerPosition(out PointF position)
    {
        position = PointF.init;
        return false;
    }

    NativeSurfaceInfo nativeSurfaceInfo()
    {
        return NativeSurfaceInfo.init;
    }
}
