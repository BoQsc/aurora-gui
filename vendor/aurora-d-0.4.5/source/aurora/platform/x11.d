module aurora.platform.x11;

version (AuroraHeadless)
{
    // Native backend intentionally omitted from headless builds.
}
else version (linux)
{
    import aurora.event : Event, EventType, Key, KeyModifier, MouseButton;
    import aurora.platform.base : NativeSurfaceInfo, NativeSurfaceKind, NativeWindow, NativeWindowSink, WindowOptions;
    import aurora.types : CursorKind, DisplayScale, Point, PointF, Size;
    import core.stdc.config : c_long, c_ulong;
    import core.thread : Thread;
    import core.time : MonoTime, msecs;
    import std.string : toStringz;

    pragma(lib, "X11");

    private struct Display;
    private struct Visual;
    private alias XID = c_ulong;
    private alias XWindow = XID;
    private alias Drawable = XID;
    private alias Atom = XID;
    private alias Time = c_ulong;
    private alias KeySym = XID;
    private alias Cursor = XID;
    private alias GC = void*;

    private enum : int
    {
        KeyPress = 2,
        KeyRelease = 3,
        ButtonPress = 4,
        ButtonRelease = 5,
        MotionNotify = 6,
        EnterNotify = 7,
        LeaveNotify = 8,
        FocusIn = 9,
        FocusOut = 10,
        Expose = 12,
        ConfigureNotify = 22,
        ClientMessage = 33,
        ZPixmap = 2,
        LSBFirst = 0,
        MSBFirst = 1,
        PropModeReplace = 0,
        GrabModeAsync = 1
    }

    private enum : c_long
    {
        KeyPressMask = 1L << 0,
        KeyReleaseMask = 1L << 1,
        ButtonPressMask = 1L << 2,
        ButtonReleaseMask = 1L << 3,
        EnterWindowMask = 1L << 4,
        LeaveWindowMask = 1L << 5,
        PointerMotionMask = 1L << 6,
        ExposureMask = 1L << 15,
        StructureNotifyMask = 1L << 17,
        FocusChangeMask = 1L << 21,
        SubstructureNotifyMask = 1L << 19,
        SubstructureRedirectMask = 1L << 20,
        PPosition = 1L << 2,
        PSize = 1L << 3,
        PMinSize = 1L << 4,
        PMaxSize = 1L << 5
    }

    private enum : uint
    {
        ShiftMask = 1u << 0,
        LockMask = 1u << 1,
        ControlMask = 1u << 2,
        Mod1Mask = 1u << 3,
        Mod2Mask = 1u << 4,
        Mod4Mask = 1u << 6
    }

    private enum : KeySym
    {
        XK_BackSpace = 0xff08,
        XK_Tab = 0xff09,
        XK_Return = 0xff0d,
        XK_Escape = 0xff1b,
        XK_Home = 0xff50,
        XK_Left = 0xff51,
        XK_Up = 0xff52,
        XK_Right = 0xff53,
        XK_Down = 0xff54,
        XK_Page_Up = 0xff55,
        XK_Page_Down = 0xff56,
        XK_End = 0xff57,
        XK_Insert = 0xff63,
        XK_Delete = 0xffff,
        XK_F1 = 0xffbe,
        XK_F2 = 0xffbf,
        XK_F3 = 0xffc0,
        XK_F4 = 0xffc1,
        XK_F5 = 0xffc2,
        XK_F6 = 0xffc3,
        XK_F7 = 0xffc4,
        XK_F8 = 0xffc5,
        XK_F9 = 0xffc6,
        XK_F10 = 0xffc7,
        XK_F11 = 0xffc8,
        XK_F12 = 0xffc9
    }

    private struct XAspect
    {
        int x;
        int y;
    }

    private struct XSizeHints
    {
        c_long flags;
        int x;
        int y;
        int width;
        int height;
        int min_width;
        int min_height;
        int max_width;
        int max_height;
        int width_inc;
        int height_inc;
        XAspect min_aspect;
        XAspect max_aspect;
        int base_width;
        int base_height;
        int win_gravity;
    }

    private struct XAnyEvent
    {
        int type;
        c_ulong serial;
        int send_event;
        Display* display;
        XWindow window;
    }

    private struct XKeyEvent
    {
        int type;
        c_ulong serial;
        int send_event;
        Display* display;
        XWindow window;
        XWindow root;
        XWindow subwindow;
        Time time;
        int x;
        int y;
        int x_root;
        int y_root;
        uint state;
        uint keycode;
        int same_screen;
    }

    private struct XButtonEvent
    {
        int type;
        c_ulong serial;
        int send_event;
        Display* display;
        XWindow window;
        XWindow root;
        XWindow subwindow;
        Time time;
        int x;
        int y;
        int x_root;
        int y_root;
        uint state;
        uint button;
        int same_screen;
    }

    private struct XMotionEvent
    {
        int type;
        c_ulong serial;
        int send_event;
        Display* display;
        XWindow window;
        XWindow root;
        XWindow subwindow;
        Time time;
        int x;
        int y;
        int x_root;
        int y_root;
        uint state;
        char is_hint;
        int same_screen;
    }

    private struct XExposeEvent
    {
        int type;
        c_ulong serial;
        int send_event;
        Display* display;
        XWindow window;
        int x;
        int y;
        int width;
        int height;
        int count;
    }

    private struct XConfigureEvent
    {
        int type;
        c_ulong serial;
        int send_event;
        Display* display;
        XWindow event;
        XWindow window;
        int x;
        int y;
        int width;
        int height;
        int border_width;
        XWindow above;
        int override_redirect;
    }

    private union XClientData
    {
        char[20] b;
        short[10] s;
        c_long[5] l;
    }

    private struct XClientMessageEvent
    {
        int type;
        c_ulong serial;
        int send_event;
        Display* display;
        XWindow window;
        Atom message_type;
        int format;
        XClientData data;
    }

    private union XEvent
    {
        int type;
        XAnyEvent xany;
        XKeyEvent xkey;
        XButtonEvent xbutton;
        XMotionEvent xmotion;
        XExposeEvent xexpose;
        XConfigureEvent xconfigure;
        XClientMessageEvent xclient;
        c_long[24] pad;
    }

    private struct XImage
    {
        int width;
        int height;
        int xoffset;
        int format;
        char* data;
        int byte_order;
        int bitmap_unit;
        int bitmap_bit_order;
        int bitmap_pad;
        int depth;
        int bytes_per_line;
        int bits_per_pixel;
        c_ulong red_mask;
        c_ulong green_mask;
        c_ulong blue_mask;
        char* obdata;
        void*[6] funcs;
    }

    private struct MotifWmHints
    {
        c_ulong flags;
        c_ulong functions;
        c_ulong decorations;
        c_long inputMode;
        c_ulong status;
    }

    extern (C) nothrow @nogc
    {
        Display* XOpenDisplay(const(char)* displayName);
        int XCloseDisplay(Display* display);
        int XDefaultScreen(Display* display);
        XWindow XRootWindow(Display* display, int screenNumber);
        c_ulong XBlackPixel(Display* display, int screenNumber);
        c_ulong XWhitePixel(Display* display, int screenNumber);
        Visual* XDefaultVisual(Display* display, int screenNumber);
        int XDefaultDepth(Display* display, int screenNumber);
        int XDisplayWidth(Display* display, int screenNumber);
        int XDisplayHeight(Display* display, int screenNumber);
        XWindow XCreateSimpleWindow(Display* display, XWindow parent, int x, int y,
            uint width, uint height, uint borderWidth, c_ulong border, c_ulong background);
        int XDestroyWindow(Display* display, XWindow window);
        int XMapWindow(Display* display, XWindow window);
        int XStoreName(Display* display, XWindow window, const(char)* name);
        int XSelectInput(Display* display, XWindow window, c_long eventMask);
        int XGrabPointer(Display* display, XWindow grabWindow, int ownerEvents,
            uint eventMask, int pointerMode, int keyboardMode, XWindow confineTo,
            Cursor cursor, Time time);
        int XUngrabPointer(Display* display, Time time);
        GC XCreateGC(Display* display, Drawable drawable, c_ulong valueMask, void* values);
        int XFreeGC(Display* display, GC gc);
        int XPending(Display* display);
        int XNextEvent(Display* display, XEvent* eventReturn);
        int XFlush(Display* display);
        Atom XInternAtom(Display* display, const(char)* atomName, int onlyIfExists);
        int XSetWMProtocols(Display* display, XWindow window, Atom* protocols, int count);
        void XSetWMNormalHints(Display* display, XWindow window, XSizeHints* hints);
        int XChangeProperty(Display* display, XWindow window, Atom property, Atom type,
            int format, int mode, const(ubyte)* data, int elementCount);
        int XDeleteProperty(Display* display, XWindow window, Atom property);
        int XSendEvent(Display* display, XWindow window, int propagate,
            c_long eventMask, XEvent* eventSend);
        int XLookupString(XKeyEvent* event, char* buffer, int bufferBytes,
            KeySym* keySymReturn, void* composeStatus);
        XImage* XCreateImage(Display* display, Visual* visual, uint depth, int format,
            int offset, char* data, uint width, uint height, int bitmapPad, int bytesPerLine);
        int XDestroyImage(XImage* image);
        int XPutImage(Display* display, Drawable drawable, GC gc, XImage* image,
            int sourceX, int sourceY, int destinationX, int destinationY,
            uint width, uint height);
        Cursor XCreateFontCursor(Display* display, uint shape);
        int XDefineCursor(Display* display, XWindow window, Cursor cursor);
        int XFreeCursor(Display* display, Cursor cursor);
    }

    final class PlatformWindow : NativeWindow
    {
        private Display* _display;
        private void* _x11XcbLibrary;
        private void* _xcbConnection;
        private int _screen;
        private XWindow _window;
        private GC _gc;
        private Atom _wmDelete;
        private XImage* _image;
        private ubyte[] _nativePixels;
        private Size _clientSize;
        private bool _closed;
        private bool _mapped;
        private bool _fullscreen;
        private bool _needsPaint = true;
        private Cursor[CursorKind] _cursors;
        private CursorKind _activeCursor = CursorKind.arrow;

        this(WindowOptions options, NativeWindowSink sink)
        {
            super(options, sink);
            _display = XOpenDisplay(null);
            if (_display is null)
                throw new Exception("Aurora could not connect to the X11 display. Check DISPLAY.");
            loadXcbConnection();

            _screen = XDefaultScreen(_display);
            const screenWidth = XDisplayWidth(_display, _screen);
            const screenHeight = XDisplayHeight(_display, _screen);
            int x = options.x == int.min ? maxIntLocal(0, (screenWidth - options.width) / 2) : options.x;
            int y = options.y == int.min ? maxIntLocal(0, (screenHeight - options.height) / 2) : options.y;
            _clientSize = Size(maxIntLocal(1, options.width), maxIntLocal(1, options.height));
            _fullscreen = options.startFullscreen;
            _window = XCreateSimpleWindow(_display, XRootWindow(_display, _screen), x, y,
                cast(uint) _clientSize.width, cast(uint) _clientSize.height, 0,
                XBlackPixel(_display, _screen), XWhitePixel(_display, _screen));
            if (_window == 0)
                throw new Exception("Aurora could not create an X11 window.");

            const mask = KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask |
                PointerMotionMask | EnterWindowMask | LeaveWindowMask | ExposureMask |
                StructureNotifyMask | FocusChangeMask;
            XSelectInput(_display, _window, mask);
            _gc = XCreateGC(_display, _window, 0, null);
            _wmDelete = XInternAtom(_display, "WM_DELETE_WINDOW".ptr, 0);
            XSetWMProtocols(_display, _window, &_wmDelete, 1);
            applyWindowManagerHints(x, y);
            setTitle(options.title);
            setCursor(CursorKind.arrow);
        }

        override void show()
        {
            XMapWindow(_display, _window);
            _mapped = true;
            XFlush(_display);
            Event event;
            event.type = EventType.resized;
            event.size = _clientSize;
            event.framebufferSize = _clientSize;
            event.displayScale = DisplayScale.init;
            sink.onNativeEvent(event);
        }

        override int run()
        {
            auto previousTick = MonoTime.currTime;
            while (!_closed)
            {
                int dispatchedCount;
                while (dispatchedCount < 64 && XPending(_display) > 0)
                {
                    XEvent nativeEvent;
                    XNextEvent(_display, &nativeEvent);
                    ++dispatchedCount;
                    const pointerMotion = nativeEvent.type == MotionNotify;
                    processEvent(nativeEvent);
                    if (_closed) break;
                    if (options.lowLatency && pointerMotion && _needsPaint)
                        break;
                }

                const now = MonoTime.currTime;
                double delta = (now - previousTick).total!"hnsecs" / 10_000_000.0;
                if (delta > 0.1) delta = 0.1;
                if (delta > 0.0 && !_closed)
                {
                    previousTick = now;
                    sink.onNativeTick(delta);
                }
                if (_needsPaint && !_closed)
                {
                    _needsPaint = !sink.onNativePaint();
                }
                if (!_closed && XPending(_display) == 0)
                    Thread.sleep((_needsPaint ? 1 : (options.lowLatency ? 4 : 16)).msecs);
            }
            sink.onNativeShutdown();
            cleanup();
            return 0;
        }

        override void invalidate()
        {
            _needsPaint = true;
        }

        override void present(const(uint)[] pixels, int width, int height)
        {
            if (_closed || _display is null || _window == 0) return;
            ensureImage(width, height);
            if (_image is null) return;
            convertPixels(pixels, width, height);
            XPutImage(_display, _window, _gc, _image, 0, 0, 0, 0,
                cast(uint) width, cast(uint) height);
            XFlush(_display);
        }

        override void setTitle(string title)
        {
            if (_display is null || _window == 0) return;

            // ICCCM WM_NAME is retained as an ASCII fallback for older window
            // managers. EWMH-aware tools receive the actual UTF-8 title through
            // _NET_WM_NAME instead of interpreting UTF-8 bytes as legacy STRING.
            char[] legacyTitle;
            legacyTitle.reserve(title.length);
            foreach (dchar character; title)
                legacyTitle ~= character >= 0x20 && character <= 0x7e ?
                    cast(char) character : '?';
            XStoreName(_display, _window, toStringz(legacyTitle));
            const property = XInternAtom(_display, "_NET_WM_NAME".ptr, 0);
            const utf8 = XInternAtom(_display, "UTF8_STRING".ptr, 0);
            XChangeProperty(_display, _window, property, utf8, 8,
                PropModeReplace, cast(const(ubyte)*) title.ptr,
                cast(int) title.length);
        }

        override void setCursor(CursorKind cursor)
        {
            if (_display is null || _window == 0) return;
            if (cursor == _activeCursor && (cursor in _cursors) !is null) return;
            Cursor value;
            if (auto cached = cursor in _cursors)
                value = *cached;
            else
            {
                value = XCreateFontCursor(_display, cursorShape(cursor));
                _cursors[cursor] = value;
            }
            if (value != 0)
            {
                XDefineCursor(_display, _window, value);
                XFlush(_display);
                _activeCursor = cursor;
            }
        }

        override void setFullscreen(bool value)
        {
            if (_display is null || _window == 0 || value == _fullscreen) return;
            _fullscreen = value;
            options.startFullscreen = value;
            if (!_mapped)
            {
                applyWindowStateProperty();
            }
            else
            {
                const state = XInternAtom(_display, "_NET_WM_STATE".ptr, 0);
                const fullscreenState = XInternAtom(_display,
                    "_NET_WM_STATE_FULLSCREEN".ptr, 0);
                XEvent event;
                event.xclient.type = ClientMessage;
                event.xclient.display = _display;
                event.xclient.window = _window;
                event.xclient.message_type = state;
                event.xclient.format = 32;
                event.xclient.data.l[0] = value ? 1 : 0; // add/remove
                event.xclient.data.l[1] = cast(c_long) fullscreenState;
                event.xclient.data.l[2] = 0;
                event.xclient.data.l[3] = 1; // normal application source
                XSendEvent(_display, XRootWindow(_display, _screen), 0,
                    SubstructureRedirectMask | SubstructureNotifyMask, &event);
            }
            XFlush(_display);
            invalidate();
        }

        override bool fullscreen() const
        {
            return _fullscreen;
        }

        override void close()
        {
            if (!_closed && sink.onNativeCloseRequested())
                _closed = true;
        }

        override Size clientSize() const
        {
            return _clientSize;
        }

        override NativeSurfaceInfo nativeSurfaceInfo()
        {
            NativeSurfaceInfo info;
            info.kind = NativeSurfaceKind.xlib;
            info.handleA = cast(void*) _display;
            info.handleB = _xcbConnection;
            info.value = cast(ulong) _window;
            return info;
        }

        private void applyWindowManagerHints(int initialX, int initialY)
        {
            XSizeHints sizeHints;
            sizeHints.flags = PPosition | PSize;
            sizeHints.x = initialX;
            sizeHints.y = initialY;
            sizeHints.width = _clientSize.width;
            sizeHints.height = _clientSize.height;
            if (!options.resizable)
            {
                sizeHints.flags |= PMinSize | PMaxSize;
                sizeHints.min_width = _clientSize.width;
                sizeHints.min_height = _clientSize.height;
                sizeHints.max_width = _clientSize.width;
                sizeHints.max_height = _clientSize.height;
            }
            XSetWMNormalHints(_display, _window, &sizeHints);

            if (!options.decorated)
            {
                auto property = XInternAtom(_display, "_MOTIF_WM_HINTS".ptr, 0);
                MotifWmHints hints;
                hints.flags = 1UL << 1;
                hints.decorations = 0;
                XChangeProperty(_display, _window, property, property, 32, PropModeReplace,
                    cast(const(ubyte)*) &hints, 5);
            }

            applyWindowStateProperty();
        }

        private void applyWindowStateProperty()
        {
            const property = XInternAtom(_display, "_NET_WM_STATE".ptr, 0);
            Atom[] states;
            if (_fullscreen)
                states ~= XInternAtom(_display, "_NET_WM_STATE_FULLSCREEN".ptr, 0);
            if (options.alwaysOnTop)
                states ~= XInternAtom(_display, "_NET_WM_STATE_ABOVE".ptr, 0);
            if (options.startMaximized && !_fullscreen)
            {
                states ~= XInternAtom(_display, "_NET_WM_STATE_MAXIMIZED_VERT".ptr, 0);
                states ~= XInternAtom(_display, "_NET_WM_STATE_MAXIMIZED_HORZ".ptr, 0);
            }
            if (states.length == 0)
            {
                XDeleteProperty(_display, _window, property);
                return;
            }
            const atomType = XInternAtom(_display, "ATOM".ptr, 0);
            XChangeProperty(_display, _window, property, atomType, 32, PropModeReplace,
                cast(const(ubyte)*) states.ptr, cast(int) states.length);
        }

        private void processEvent(ref XEvent nativeEvent)
        {
            Event event;
            switch (nativeEvent.type)
            {
                case Expose:
                    _needsPaint = true;
                    break;
                case ConfigureNotify:
                {
                    const width = maxIntLocal(1, nativeEvent.xconfigure.width);
                    const height = maxIntLocal(1, nativeEvent.xconfigure.height);
                    if (width != _clientSize.width || height != _clientSize.height)
                    {
                        _clientSize = Size(width, height);
                        event.type = EventType.resized;
                        event.size = _clientSize;
                        event.framebufferSize = _clientSize;
                        event.displayScale = DisplayScale.init;
                        sink.onNativeEvent(event);
                    }
                    break;
                }
                case MotionNotify:
                    event.type = EventType.mouseMove;
                    event.globalPosition = Point(nativeEvent.xmotion.x, nativeEvent.xmotion.y);
                    event.position = event.globalPosition;
                    event.preciseGlobalPosition = PointF(event.globalPosition);
                    event.precisePosition = event.preciseGlobalPosition;
                    event.hasPrecisePosition = true;
                    event.modifiers = modifiers(nativeEvent.xmotion.state);
                    event.timestampMs = cast(long) nativeEvent.xmotion.time;
                    sink.onNativeEvent(event);
                    break;
                case ButtonPress:
                case ButtonRelease:
                    processButton(nativeEvent.xbutton, nativeEvent.type == ButtonPress);
                    break;
                case KeyPress:
                case KeyRelease:
                    processKey(nativeEvent.xkey, nativeEvent.type == KeyPress);
                    break;
                case FocusIn:
                    event.type = EventType.focusGained;
                    sink.onNativeEvent(event);
                    break;
                case FocusOut:
                    event.type = EventType.focusLost;
                    sink.onNativeEvent(event);
                    break;
                case ClientMessage:
                    if (cast(Atom) nativeEvent.xclient.data.l[0] == _wmDelete &&
                        sink.onNativeCloseRequested())
                        _closed = true;
                    break;
                default:
                    break;
            }
        }

        private void processButton(ref XButtonEvent nativeEvent, bool down)
        {
            Event event;
            event.globalPosition = Point(nativeEvent.x, nativeEvent.y);
            event.position = event.globalPosition;
            event.preciseGlobalPosition = PointF(event.globalPosition);
            event.precisePosition = event.preciseGlobalPosition;
            event.hasPrecisePosition = true;
            event.modifiers = modifiers(nativeEvent.state);
            event.timestampMs = cast(long) nativeEvent.time;

            if (down && nativeEvent.button >= 4 && nativeEvent.button <= 7)
            {
                event.type = EventType.mouseWheel;
                if (nativeEvent.button == 4) event.wheelY = 3;
                else if (nativeEvent.button == 5) event.wheelY = -3;
                else if (nativeEvent.button == 6) event.wheelX = 3;
                else if (nativeEvent.button == 7) event.wheelX = -3;
                sink.onNativeEvent(event);
                return;
            }

            event.type = down ? EventType.mouseDown : EventType.mouseUp;
            event.button = mouseButton(nativeEvent.button);
            if (event.button != MouseButton.none)
            {
                if (down)
                {
                    XGrabPointer(_display, _window, 1,
                        cast(uint) (ButtonPressMask | ButtonReleaseMask | PointerMotionMask),
                        GrabModeAsync, GrabModeAsync, 0, 0, nativeEvent.time);
                }
                sink.onNativeEvent(event);
                if (!down) XUngrabPointer(_display, nativeEvent.time);
            }
        }

        private void processKey(ref XKeyEvent nativeEvent, bool down)
        {
            char[64] textBuffer;
            KeySym symbol;
            const count = XLookupString(&nativeEvent, textBuffer.ptr,
                cast(int) textBuffer.length, &symbol, null);

            Event event;
            event.type = down ? EventType.keyDown : EventType.keyUp;
            event.key = mapKey(symbol);
            event.modifiers = modifiers(nativeEvent.state);
            event.timestampMs = cast(long) nativeEvent.time;
            sink.onNativeEvent(event);

            if (down && count > 0)
            {
                dchar[] text;
                foreach (index; 0 .. count)
                {
                    const value = cast(ubyte) textBuffer[cast(size_t) index];
                    if (value != 0)
                        text ~= cast(dchar) value;
                }
                if (text.length > 0)
                {
                    Event input;
                    input.type = EventType.textInput;
                    input.text = text.idup;
                    input.modifiers = event.modifiers;
                    input.timestampMs = event.timestampMs;
                    sink.onNativeEvent(input);
                }
            }
        }

        private void ensureImage(int width, int height)
        {
            if (_image !is null && _image.width == width && _image.height == height)
                return;
            destroyImage();
            _image = XCreateImage(_display, XDefaultVisual(_display, _screen),
                cast(uint) XDefaultDepth(_display, _screen), ZPixmap, 0, null,
                cast(uint) width, cast(uint) height, 32, 0);
            if (_image is null)
                throw new Exception("Aurora could not create an X11 image.");
            _nativePixels.length = cast(size_t) _image.bytes_per_line * cast(size_t) height;
            _image.data = cast(char*) _nativePixels.ptr;
        }

        private void convertPixels(const(uint)[] pixels, int width, int height)
        {
            const bytesPerPixel = maxIntLocal(1, (_image.bits_per_pixel + 7) / 8);
            foreach (y; 0 .. height)
            {
                foreach (x; 0 .. width)
                {
                    const source = pixels[cast(size_t) y * cast(size_t) width + cast(size_t) x];
                    const red = cast(uint) ((source >> 16) & 0xff);
                    const green = cast(uint) ((source >> 8) & 0xff);
                    const blue = cast(uint) (source & 0xff);
                    const packed = packChannel(red, _image.red_mask) |
                                   packChannel(green, _image.green_mask) |
                                   packChannel(blue, _image.blue_mask);
                    const offset = cast(size_t) y * cast(size_t) _image.bytes_per_line +
                        cast(size_t) x * cast(size_t) bytesPerPixel;
                    if (_image.byte_order == LSBFirst)
                    {
                        foreach (byteIndex; 0 .. bytesPerPixel)
                            _nativePixels[offset + cast(size_t) byteIndex] =
                                cast(ubyte) ((packed >> (byteIndex * 8)) & 0xff);
                    }
                    else
                    {
                        foreach (byteIndex; 0 .. bytesPerPixel)
                            _nativePixels[offset + cast(size_t) byteIndex] =
                                cast(ubyte) ((packed >> ((bytesPerPixel - 1 - byteIndex) * 8)) & 0xff);
                    }
                }
            }
        }

        private static c_ulong packChannel(uint channel, c_ulong mask) @safe pure nothrow @nogc
        {
            if (mask == 0) return 0;
            uint shift;
            c_ulong shifted = mask;
            while ((shifted & 1) == 0)
            {
                shifted >>= 1;
                ++shift;
            }
            const maximum = shifted;
            return cast(c_ulong) ((cast(c_ulong) channel * maximum + 127) / 255) << shift;
        }

        private void destroyImage()
        {
            if (_image !is null)
            {
                _image.data = null;
                XDestroyImage(_image);
                _image = null;
                _nativePixels.length = 0;
            }
        }

        private void loadXcbConnection()
        {
            import core.sys.posix.dlfcn : RTLD_LOCAL, RTLD_NOW, dlopen, dlsym;
            alias GetConnection = extern(C) void* function(Display*);
            _x11XcbLibrary = dlopen("libX11-xcb.so.1".ptr, RTLD_NOW | RTLD_LOCAL);
            if (_x11XcbLibrary is null)
                _x11XcbLibrary = dlopen("libX11-xcb.so".ptr, RTLD_NOW | RTLD_LOCAL);
            if (_x11XcbLibrary !is null)
            {
                auto getConnection = cast(GetConnection) dlsym(_x11XcbLibrary,
                    "XGetXCBConnection".ptr);
                if (getConnection !is null)
                    _xcbConnection = getConnection(_display);
            }
        }

        private void cleanup()
        {
            destroyImage();
            if (_display is null) return;
            foreach (cursor; _cursors.values)
                if (cursor != 0) XFreeCursor(_display, cursor);
            _cursors = null;
            if (_gc !is null)
            {
                XFreeGC(_display, _gc);
                _gc = null;
            }
            if (_window != 0)
            {
                XDestroyWindow(_display, _window);
                _window = 0;
            }
            XCloseDisplay(_display);
            _display = null;
            _xcbConnection = null;
            if (_x11XcbLibrary !is null)
            {
                import core.sys.posix.dlfcn : dlclose;
                dlclose(_x11XcbLibrary);
                _x11XcbLibrary = null;
            }
        }

        private static uint modifiers(uint state) @safe pure nothrow @nogc
        {
            uint result;
            if (state & ShiftMask) result |= cast(uint) KeyModifier.shift;
            if (state & ControlMask) result |= cast(uint) KeyModifier.control;
            if (state & Mod1Mask) result |= cast(uint) KeyModifier.alt;
            if (state & Mod4Mask) result |= cast(uint) KeyModifier.meta;
            if (state & LockMask) result |= cast(uint) KeyModifier.capsLock;
            if (state & Mod2Mask) result |= cast(uint) KeyModifier.numLock;
            return result;
        }

        private static MouseButton mouseButton(uint button) @safe pure nothrow @nogc
        {
            switch (button)
            {
                case 1: return MouseButton.left;
                case 2: return MouseButton.middle;
                case 3: return MouseButton.right;
                case 8: return MouseButton.extra1;
                case 9: return MouseButton.extra2;
                default: return MouseButton.none;
            }
        }

        private static Key mapKey(KeySym symbol) @safe pure nothrow @nogc
        {
            if (symbol >= '0' && symbol <= '9')
                return cast(Key) (cast(int) Key.digit0 + cast(int) (symbol - '0'));
            if (symbol >= 'a' && symbol <= 'z')
                return cast(Key) (cast(int) Key.a + cast(int) (symbol - 'a'));
            if (symbol >= 'A' && symbol <= 'Z')
                return cast(Key) (cast(int) Key.a + cast(int) (symbol - 'A'));
            switch (symbol)
            {
                case XK_BackSpace: return Key.backspace;
                case XK_Tab: return Key.tab;
                case XK_Return: return Key.enter;
                case XK_Escape: return Key.escape;
                case XK_Home: return Key.home;
                case XK_Left: return Key.left;
                case XK_Up: return Key.up;
                case XK_Right: return Key.right;
                case XK_Down: return Key.down;
                case XK_Page_Up: return Key.pageUp;
                case XK_Page_Down: return Key.pageDown;
                case XK_End: return Key.end;
                case XK_Insert: return Key.insert;
                case XK_Delete: return Key.deleteKey;
                case XK_F1: return Key.f1;
                case XK_F2: return Key.f2;
                case XK_F3: return Key.f3;
                case XK_F4: return Key.f4;
                case XK_F5: return Key.f5;
                case XK_F6: return Key.f6;
                case XK_F7: return Key.f7;
                case XK_F8: return Key.f8;
                case XK_F9: return Key.f9;
                case XK_F10: return Key.f10;
                case XK_F11: return Key.f11;
                case XK_F12: return Key.f12;
                case ' ': return Key.space;
                case '-': return Key.minus;
                case '=': return Key.equal;
                case '[': return Key.leftBracket;
                case ']': return Key.rightBracket;
                case '\\': return Key.backslash;
                case ';': return Key.semicolon;
                case '\'': return Key.apostrophe;
                case '`': return Key.grave;
                case ',': return Key.comma;
                case '.': return Key.period;
                case '/': return Key.slash;
                default: return Key.unknown;
            }
        }

        private static uint cursorShape(CursorKind cursor) @safe pure nothrow @nogc
        {
            final switch (cursor)
            {
                case CursorKind.arrow: return 68; // XC_left_ptr
                case CursorKind.hand: return 60; // XC_hand2
                case CursorKind.text: return 152; // XC_xterm
                case CursorKind.resizeHorizontal: return 108;
                case CursorKind.resizeVertical: return 116;
                case CursorKind.resizeDiagonalNWSE: return 14;
                case CursorKind.resizeDiagonalNESW: return 12;
                case CursorKind.move: return 52;
                case CursorKind.forbidden: return 88;
            }
        }

        private static int maxIntLocal(int a, int b) @safe pure nothrow @nogc
        {
            return a > b ? a : b;
        }
    }
}
