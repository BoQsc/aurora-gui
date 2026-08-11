module aurora.platform.base;

import aurora.color : Color;
import aurora.event : Event;
import aurora.font : FontRenderMode;
public import aurora.render.base : RendererPreference;
import aurora.types : CursorKind, DisplayScale, PointF, Rect, Size;

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
    /** Request a dark native titlebar where the host OS supports it. */
    bool darkTitleBar;
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

    /**
     * Give a native backend an opportunity to submit the complete first frame
     * while its top-level window is still hidden. Backends that cannot safely
     * present while hidden leave the normal show/paint path unchanged.
     */
    bool prepareFirstFrame(Color background)
    {
        return false;
    }
    abstract void show();
    abstract int run();
    abstract void invalidate();
    abstract void present(const(uint)[] pixels, int width, int height);
    /**
     * Present a cached framebuffer scaled to the current native framebuffer.
     * Backends can override this to bypass expensive GPU resize paths during
     * live native resizing. Returning false falls back to the normal renderer.
     */
    bool presentScaledResizeFrame(const(uint)[] pixels, int sourceWidth,
        int sourceHeight, int targetWidth, int targetHeight)
    {
        return false;
    }
    abstract void setTitle(string title);
    abstract void setCursor(CursorKind cursor);
    /** Hide/show the host cursor; false means the backend cannot guarantee it. */
    bool setPointerVisible(bool visible)
    {
        return false;
    }
    /** Start the platform's normal top-level window move loop, if supported. */
    bool beginSystemMove()
    {
        return false;
    }
    /** Enter or leave native monitor fullscreen. */
    abstract void setFullscreen(bool value);
    /** Current or requested native fullscreen state. */
    abstract bool fullscreen() const;
    abstract void close();
    abstract Size clientSize() const;
    /** Outer native window bounds in Aurora logical screen coordinates. */
    bool windowBounds(out Rect bounds)
    {
        bounds = Rect.init;
        return false;
    }

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
