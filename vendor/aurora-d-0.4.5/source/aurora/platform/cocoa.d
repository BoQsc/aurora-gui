module aurora.platform.cocoa;

version (AuroraHeadless)
{
    // Native backend intentionally omitted from headless builds.
}
else version (OSX)
{
    import aurora.event : Event, EventType, Key, KeyModifier, MouseButton;
    import aurora.platform.base : NativeSurfaceInfo, NativeSurfaceKind, NativeWindow, NativeWindowSink, WindowOptions;
    import aurora.types : CursorKind, DisplayScale, Point, PointF, Size;
    import core.stdc.config : c_ulong;
    import std.string : fromStringz, toStringz;
    import std.utf : toUTF32;


    private alias id = void*;
    private alias Class = void*;
    private alias SEL = void*;
    private alias IMP = extern(C) void function();
    private alias BOOL = byte;
    private alias NSUInteger = size_t;
    private alias NSInteger = ptrdiff_t;
    private alias CGFloat = double;
    private alias CGColorSpaceRef = void*;
    private alias CGDataProviderRef = void*;
    private alias CGImageRef = void*;
    private alias CGContextRef = void*;
    private alias CGDataProviderReleaseDataCallback =
        extern(C) void function(void*, const(void)*, size_t);

    private struct NSPoint
    {
        CGFloat x;
        CGFloat y;
    }

    private struct NSSize
    {
        CGFloat width;
        CGFloat height;
    }

    private struct NSRect
    {
        NSPoint origin;
        NSSize size;
    }

    private alias CGRect = NSRect;

    extern(C) nothrow @nogc
    {
        Class objc_getClass(const(char)* name);
        SEL sel_registerName(const(char)* name);
        Class objc_allocateClassPair(Class superclass, const(char)* name, size_t extraBytes);
        void objc_registerClassPair(Class cls);
        BOOL class_addMethod(Class cls, SEL name, IMP implementation, const(char)* types);
        void objc_msgSend();
        version (X86_64)
            void objc_msgSend_stret();

        double CFAbsoluteTimeGetCurrent();

        CGColorSpaceRef CGColorSpaceCreateDeviceRGB();
        void CGColorSpaceRelease(CGColorSpaceRef space);
        CGDataProviderRef CGDataProviderCreateWithData(
            void* info, const(void)* data, size_t size,
            CGDataProviderReleaseDataCallback releaseData);
        void CGDataProviderRelease(CGDataProviderRef provider);
        CGImageRef CGImageCreate(
            size_t width,
            size_t height,
            size_t bitsPerComponent,
            size_t bitsPerPixel,
            size_t bytesPerRow,
            CGColorSpaceRef colorSpace,
            uint bitmapInfo,
            CGDataProviderRef provider,
            const(CGFloat)* decode,
            BOOL shouldInterpolate,
            uint renderingIntent);
        void CGImageRelease(CGImageRef image);
        void CGContextSaveGState(CGContextRef context);
        void CGContextRestoreGState(CGContextRef context);
        void CGContextTranslateCTM(CGContextRef context, CGFloat tx, CGFloat ty);
        void CGContextScaleCTM(CGContextRef context, CGFloat sx, CGFloat sy);
        void CGContextDrawImage(CGContextRef context, CGRect rect, CGImageRef image);
    }

    private enum : NSUInteger
    {
        nsWindowStyleTitled = 1UL << 0,
        nsWindowStyleClosable = 1UL << 1,
        nsWindowStyleMiniaturizable = 1UL << 2,
        nsWindowStyleResizable = 1UL << 3,
        nsViewWidthSizable = 1UL << 1,
        nsViewHeightSizable = 1UL << 4,
        nsEventMaskAny = NSUInteger.max
    }

    private enum : NSUInteger
    {
        nsModifierCapsLock = 1UL << 16,
        nsModifierShift = 1UL << 17,
        nsModifierControl = 1UL << 18,
        nsModifierOption = 1UL << 19,
        nsModifierCommand = 1UL << 20,
        nsModifierNumericPad = 1UL << 21
    }

    private enum NSUInteger nsBackingStoreBuffered = 2;
    private enum NSInteger nsApplicationActivationPolicyRegular = 0;
    private enum uint cgImageAlphaNoneSkipFirst = 6;
    private enum uint cgBitmapByteOrder32Little = 2u << 12;
    private enum uint cgRenderingIntentDefault = 0;

    private Class auroraViewClass;
    private PlatformWindow[void*] viewOwners;

    private SEL selector(string name)
    {
        return sel_registerName(toStringz(name));
    }

    private Class cocoaClass(string name)
    {
        return objc_getClass(toStringz(name));
    }

    private alias MsgId0 = extern(C) id function(id, SEL);
    private alias MsgVoid0 = extern(C) void function(id, SEL);
    private alias MsgVoidId = extern(C) void function(id, SEL, id);
    private alias MsgVoidBool = extern(C) void function(id, SEL, BOOL);
    private alias MsgBool0 = extern(C) BOOL function(id, SEL);
    private alias MsgBoolId = extern(C) BOOL function(id, SEL, id);
    private alias MsgUInteger0 = extern(C) NSUInteger function(id, SEL);
    private alias MsgUShort0 = extern(C) ushort function(id, SEL);
    private alias MsgDouble0 = extern(C) double function(id, SEL);
    private alias MsgCString0 = extern(C) const(char)* function(id, SEL);
    private alias MsgPoint0 = extern(C) NSPoint function(id, SEL);
    private alias MsgPointPointId = extern(C) NSPoint function(id, SEL, NSPoint, id);
    private alias MsgVoidPoint = extern(C) void function(id, SEL, NSPoint);
    private alias MsgIdCString = extern(C) id function(id, SEL, const(char)*);
    private alias MsgIdDouble = extern(C) id function(id, SEL, double);
    private alias MsgIdRect = extern(C) id function(id, SEL, NSRect);
    private alias MsgIdRectUlongUlongBool = extern(C) id function(
        id, SEL, NSRect, NSUInteger, NSUInteger, BOOL);
    private alias MsgIdMaskDateModeBool = extern(C) id function(
        id, SEL, NSUInteger, id, id, BOOL);
    private alias MsgVoidUInteger = extern(C) void function(id, SEL, NSUInteger);
    private alias MsgBoolInteger = extern(C) BOOL function(id, SEL, NSInteger);

    private id sendId(id object, string name)
    {
        return (cast(MsgId0) &objc_msgSend)(object, selector(name));
    }

    private void sendVoid(id object, string name)
    {
        (cast(MsgVoid0) &objc_msgSend)(object, selector(name));
    }

    private void sendVoidId(id object, string name, id value)
    {
        (cast(MsgVoidId) &objc_msgSend)(object, selector(name), value);
    }

    private void sendVoidBool(id object, string name, bool value)
    {
        (cast(MsgVoidBool) &objc_msgSend)(object, selector(name), cast(BOOL) value);
    }

    private void sendVoidUInteger(id object, string name, NSUInteger value)
    {
        (cast(MsgVoidUInteger) &objc_msgSend)(object, selector(name), value);
    }

    private BOOL sendBool(id object, string name)
    {
        return (cast(MsgBool0) &objc_msgSend)(object, selector(name));
    }

    private NSUInteger sendUInteger(id object, string name)
    {
        return (cast(MsgUInteger0) &objc_msgSend)(object, selector(name));
    }

    private ushort sendUShort(id object, string name)
    {
        return (cast(MsgUShort0) &objc_msgSend)(object, selector(name));
    }

    private double sendDouble(id object, string name)
    {
        return (cast(MsgDouble0) &objc_msgSend)(object, selector(name));
    }

    private const(char)* sendCString(id object, string name)
    {
        return (cast(MsgCString0) &objc_msgSend)(object, selector(name));
    }

    private NSPoint sendPoint(id object, string name)
    {
        return (cast(MsgPoint0) &objc_msgSend)(object, selector(name));
    }

    private NSPoint sendPointPointId(id object, string name, NSPoint point, id other)
    {
        return (cast(MsgPointPointId) &objc_msgSend)(object, selector(name), point, other);
    }

    private id sendIdCString(id object, string name, string value)
    {
        return (cast(MsgIdCString) &objc_msgSend)(object, selector(name), toStringz(value));
    }

    private id sendIdDouble(id object, string name, double value)
    {
        return (cast(MsgIdDouble) &objc_msgSend)(object, selector(name), value);
    }

    private NSRect sendRect(id object, string name)
    {
        NSRect result;
        version (X86_64)
        {
            alias MsgRectStret = extern(C) void function(NSRect*, id, SEL);
            (cast(MsgRectStret) &objc_msgSend_stret)(&result, object, selector(name));
        }
        else
        {
            alias MsgRect = extern(C) NSRect function(id, SEL);
            result = (cast(MsgRect) &objc_msgSend)(object, selector(name));
        }
        return result;
    }

    private id makeNSString(string value)
    {
        auto object = sendId(cast(id) cocoaClass("NSString"), "alloc");
        return sendIdCString(object, "initWithUTF8String:", value);
    }

    private PlatformWindow ownerFor(id view)
    {
        auto key = cast(void*) view;
        if (auto owner = key in viewOwners)
            return *owner;
        return null;
    }

    private extern(C) void viewDrawRect(id self, SEL command, NSRect dirtyRect)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null) owner.drawNative();
        }
        catch (Throwable) {}
    }

    private extern(C) BOOL viewAcceptsFirstResponder(id self, SEL command)
    {
        return 1;
    }

    private extern(C) BOOL viewIsFlipped(id self, SEL command)
    {
        return 1;
    }

    private extern(C) void viewMouseMoved(id self, SEL command, id event)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null) owner.handleMouse(event, EventType.mouseMove, MouseButton.none);
        }
        catch (Throwable) {}
    }

    private extern(C) void viewMouseDown(id self, SEL command, id event)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null) owner.handleMouse(event, EventType.mouseDown, MouseButton.left);
        }
        catch (Throwable) {}
    }

    private extern(C) void viewMouseUp(id self, SEL command, id event)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null) owner.handleMouse(event, EventType.mouseUp, MouseButton.left);
        }
        catch (Throwable) {}
    }

    private extern(C) void viewRightMouseDown(id self, SEL command, id event)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null) owner.handleMouse(event, EventType.mouseDown, MouseButton.right);
        }
        catch (Throwable) {}
    }

    private extern(C) void viewRightMouseUp(id self, SEL command, id event)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null) owner.handleMouse(event, EventType.mouseUp, MouseButton.right);
        }
        catch (Throwable) {}
    }

    private extern(C) void viewOtherMouseDown(id self, SEL command, id event)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null)
                owner.handleMouse(event, EventType.mouseDown, owner.otherMouseButton(event));
        }
        catch (Throwable) {}
    }

    private extern(C) void viewOtherMouseUp(id self, SEL command, id event)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null)
                owner.handleMouse(event, EventType.mouseUp, owner.otherMouseButton(event));
        }
        catch (Throwable) {}
    }

    private extern(C) void viewScrollWheel(id self, SEL command, id event)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null) owner.handleWheel(event);
        }
        catch (Throwable) {}
    }

    private extern(C) void viewKeyDown(id self, SEL command, id event)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null) owner.handleKey(event, true);
        }
        catch (Throwable) {}
    }

    private extern(C) void viewKeyUp(id self, SEL command, id event)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null) owner.handleKey(event, false);
        }
        catch (Throwable) {}
    }

    private extern(C) BOOL windowShouldClose(id self, SEL command, id sender)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner is null) return 1;
            return cast(BOOL) owner.handleDelegateCloseRequest();
        }
        catch (Throwable)
        {
            return 1;
        }
    }

    private extern(C) void windowWillClose(id self, SEL command, id notification)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null) owner._closed = true;
        }
        catch (Throwable) {}
    }

    private extern(C) void windowDidResize(id self, SEL command, id notification)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null) owner.updateClientSize(true);
        }
        catch (Throwable) {}
    }

    private extern(C) void windowDidEnterFullScreen(id self, SEL command, id notification)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null)
            {
                owner._fullscreen = true;
                owner.updateClientSize(true);
            }
        }
        catch (Throwable) {}
    }

    private extern(C) void windowDidExitFullScreen(id self, SEL command, id notification)
    {
        try
        {
            auto owner = ownerFor(self);
            if (owner !is null)
            {
                owner._fullscreen = false;
                owner.updateClientSize(true);
            }
        }
        catch (Throwable) {}
    }

    private void addViewMethod(Class cls, string name, IMP method, string encoding)
    {
        if (!class_addMethod(cls, selector(name), method, toStringz(encoding)))
            throw new Exception("Aurora could not register an AppKit view method: " ~ name);
    }

    private void ensureAuroraViewClass()
    {
        if (auroraViewClass !is null) return;
        auto existing = cocoaClass("AuroraDSoftwareView");
        if (existing !is null)
        {
            auroraViewClass = existing;
            return;
        }
        auroraViewClass = objc_allocateClassPair(cocoaClass("NSView"),
            "AuroraDSoftwareView".ptr, 0);
        if (auroraViewClass is null)
            throw new Exception("Aurora could not create its AppKit view class.");

        addViewMethod(auroraViewClass, "drawRect:", cast(IMP) &viewDrawRect,
            "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
        addViewMethod(auroraViewClass, "acceptsFirstResponder",
            cast(IMP) &viewAcceptsFirstResponder, "c@:");
        addViewMethod(auroraViewClass, "isFlipped", cast(IMP) &viewIsFlipped, "c@:");
        addViewMethod(auroraViewClass, "mouseMoved:", cast(IMP) &viewMouseMoved, "v@:@");
        addViewMethod(auroraViewClass, "mouseDragged:", cast(IMP) &viewMouseMoved, "v@:@");
        addViewMethod(auroraViewClass, "rightMouseDragged:", cast(IMP) &viewMouseMoved, "v@:@");
        addViewMethod(auroraViewClass, "otherMouseDragged:", cast(IMP) &viewMouseMoved, "v@:@");
        addViewMethod(auroraViewClass, "mouseDown:", cast(IMP) &viewMouseDown, "v@:@");
        addViewMethod(auroraViewClass, "mouseUp:", cast(IMP) &viewMouseUp, "v@:@");
        addViewMethod(auroraViewClass, "rightMouseDown:", cast(IMP) &viewRightMouseDown, "v@:@");
        addViewMethod(auroraViewClass, "rightMouseUp:", cast(IMP) &viewRightMouseUp, "v@:@");
        addViewMethod(auroraViewClass, "otherMouseDown:", cast(IMP) &viewOtherMouseDown, "v@:@");
        addViewMethod(auroraViewClass, "otherMouseUp:", cast(IMP) &viewOtherMouseUp, "v@:@");
        addViewMethod(auroraViewClass, "scrollWheel:", cast(IMP) &viewScrollWheel, "v@:@");
        addViewMethod(auroraViewClass, "keyDown:", cast(IMP) &viewKeyDown, "v@:@");
        addViewMethod(auroraViewClass, "keyUp:", cast(IMP) &viewKeyUp, "v@:@");
        addViewMethod(auroraViewClass, "windowShouldClose:",
            cast(IMP) &windowShouldClose, "c@:@");
        addViewMethod(auroraViewClass, "windowWillClose:",
            cast(IMP) &windowWillClose, "v@:@");
        addViewMethod(auroraViewClass, "windowDidResize:",
            cast(IMP) &windowDidResize, "v@:@");
        addViewMethod(auroraViewClass, "windowDidEnterFullScreen:",
            cast(IMP) &windowDidEnterFullScreen, "v@:@");
        addViewMethod(auroraViewClass, "windowDidExitFullScreen:",
            cast(IMP) &windowDidExitFullScreen, "v@:@");
        objc_registerClassPair(auroraViewClass);
    }

    final class PlatformWindow : NativeWindow
    {
        private id _application;
        private id _window;
        private id _view;
        private id _metalLayer;
        private id _runLoopMode;
        private const(uint)[] _pixels;
        private int _pixelWidth;
        private int _pixelHeight;
        private Size _clientSize;
        private bool _closed;
        private bool _needsPaint = true;
        private bool _programmaticCloseApproved;
        private bool _shown;
        private bool _fullscreen;

        this(WindowOptions options, NativeWindowSink sink)
        {
            super(options, sink);
            ensureAuroraViewClass();
            _application = sendId(cast(id) cocoaClass("NSApplication"), "sharedApplication");
            (cast(MsgBoolInteger) &objc_msgSend)(_application,
                selector("setActivationPolicy:"), nsApplicationActivationPolicyRegular);
            sendVoid(_application, "finishLaunching");

            NSUInteger style;
            if (options.decorated)
            {
                style = nsWindowStyleTitled | nsWindowStyleClosable | nsWindowStyleMiniaturizable;
                if (options.resizable) style |= nsWindowStyleResizable;
            }
            NSRect frame = NSRect(NSPoint(0, 0),
                NSSize(maxIntLocal(1, options.width), maxIntLocal(1, options.height)));

            auto allocatedWindow = sendId(cast(id) cocoaClass("NSWindow"), "alloc");
            _window = (cast(MsgIdRectUlongUlongBool) &objc_msgSend)(
                allocatedWindow,
                selector("initWithContentRect:styleMask:backing:defer:"),
                frame,
                style,
                nsBackingStoreBuffered,
                0);
            if (_window is null)
                throw new Exception("Aurora could not create an AppKit window.");
            sendVoidBool(_window, "setReleasedWhenClosed:", false);

            auto allocatedView = sendId(cast(id) auroraViewClass, "alloc");
            _view = (cast(MsgIdRect) &objc_msgSend)(allocatedView,
                selector("initWithFrame:"), frame);
            if (_view is null)
                throw new Exception("Aurora could not create an AppKit content view.");
            viewOwners[cast(void*) _view] = this;
            sendVoidUInteger(_view, "setAutoresizingMask:",
                nsViewWidthSizable | nsViewHeightSizable);

            // MoltenVK's VK_EXT_metal_surface consumes a CAMetalLayer. Keep the
            // layer attached even when Aurora falls back to Core Graphics so the
            // renderer can be selected without rebuilding the native window.
            auto metalLayerClass = cocoaClass("CAMetalLayer");
            if (metalLayerClass !is null)
            {
                _metalLayer = sendId(cast(id) metalLayerClass, "layer");
                if (_metalLayer !is null)
                {
                    sendVoidBool(_view, "setWantsLayer:", true);
                    sendVoidId(_view, "setLayer:", _metalLayer);
                }
            }

            sendVoidId(_window, "setContentView:", _view);
            sendVoidId(_window, "setDelegate:", _view);
            sendVoidBool(_window, "setAcceptsMouseMovedEvents:", true);
            if (options.alwaysOnTop)
            {
                alias MsgVoidInteger = extern(C) void function(id, SEL, NSInteger);
                (cast(MsgVoidInteger) &objc_msgSend)(_window, selector("setLevel:"), 3);
            }
            setTitle(options.title);
            _runLoopMode = makeNSString("kCFRunLoopDefaultMode");
            _fullscreen = options.startFullscreen;
            updateClientSize(false);
        }

        private bool handleDelegateCloseRequest()
        {
            if (_programmaticCloseApproved)
            {
                _programmaticCloseApproved = false;
                _closed = true;
                return true;
            }
            const approved = sink.onNativeCloseRequested();
            if (approved) _closed = true;
            return approved;
        }

        override void show()
        {
            if (options.x == int.min || options.y == int.min)
                sendVoid(_window, "center");
            else
                (cast(MsgVoidPoint) &objc_msgSend)(_window, selector("setFrameOrigin:"),
                    NSPoint(options.x, options.y));
            sendVoidId(_window, "makeKeyAndOrderFront:", null);
            sendVoidBool(_application, "activateIgnoringOtherApps:", true);
            sendVoidId(_window, "makeFirstResponder:", _view);
            _shown = true;
            if (_fullscreen)
                sendVoidId(_window, "toggleFullScreen:", null);
            else if (options.startMaximized)
                sendVoidId(_window, "zoom:", null);
            updateClientSize(true);
        }

        override int run()
        {
            double previous = CFAbsoluteTimeGetCurrent();
            while (!_closed)
            {
                auto pool = sendId(sendId(cast(id) cocoaClass("NSAutoreleasePool"), "alloc"), "init");
                const waitSeconds = _needsPaint ? 0.001 :
                    (options.lowLatency ? 0.004 : 0.016);
                auto date = sendIdDouble(cast(id) cocoaClass("NSDate"),
                    "dateWithTimeIntervalSinceNow:", waitSeconds);
                auto nativeEvent = (cast(MsgIdMaskDateModeBool) &objc_msgSend)(
                    _application,
                    selector("nextEventMatchingMask:untilDate:inMode:dequeue:"),
                    nsEventMaskAny,
                    date,
                    _runLoopMode,
                    1);
                if (nativeEvent !is null)
                    sendVoidId(_application, "sendEvent:", nativeEvent);
                sendVoid(_application, "updateWindows");

                const now = CFAbsoluteTimeGetCurrent();
                double delta = now - previous;
                if (delta > 0.1) delta = 0.1;
                if (delta > 0.0 && !_closed)
                {
                    previous = now;
                    sink.onNativeTick(delta);
                }
                if (_needsPaint && !_closed)
                {
                    _needsPaint = !sink.onNativePaint();
                }
                sendVoid(pool, "drain");
            }
            sink.onNativeShutdown();
            cleanup();
            return 0;
        }

        override void invalidate()
        {
            _needsPaint = true;
            if (_view !is null)
                sendVoidBool(_view, "setNeedsDisplay:", true);
        }

        override void present(const(uint)[] pixels, int width, int height)
        {
            _pixels = pixels;
            _pixelWidth = width;
            _pixelHeight = height;
            if (_view !is null)
            {
                sendVoidBool(_view, "setNeedsDisplay:", true);
                sendVoid(_view, "displayIfNeeded");
            }
        }

        override void setTitle(string title)
        {
            if (_window is null) return;
            auto value = makeNSString(title);
            sendVoidId(_window, "setTitle:", value);
            sendVoid(value, "release");
        }

        override void setCursor(CursorKind cursor)
        {
            id cursorClass = cast(id) cocoaClass("NSCursor");
            id value;
            final switch (cursor)
            {
                case CursorKind.arrow: value = sendId(cursorClass, "arrowCursor"); break;
                case CursorKind.hand: value = sendId(cursorClass, "pointingHandCursor"); break;
                case CursorKind.text: value = sendId(cursorClass, "IBeamCursor"); break;
                case CursorKind.resizeHorizontal: value = sendId(cursorClass, "resizeLeftRightCursor"); break;
                case CursorKind.resizeVertical: value = sendId(cursorClass, "resizeUpDownCursor"); break;
                case CursorKind.resizeDiagonalNWSE: value = sendId(cursorClass, "closedHandCursor"); break;
                case CursorKind.resizeDiagonalNESW: value = sendId(cursorClass, "closedHandCursor"); break;
                case CursorKind.move: value = sendId(cursorClass, "openHandCursor"); break;
                case CursorKind.forbidden: value = sendId(cursorClass, "operationNotAllowedCursor"); break;
            }
            if (value !is null) sendVoid(value, "set");
        }

        override void setFullscreen(bool value)
        {
            if (_window is null || value == _fullscreen) return;
            _fullscreen = value;
            options.startFullscreen = value;
            if (_shown)
                sendVoidId(_window, "toggleFullScreen:", null);
            invalidate();
        }

        override bool fullscreen() const
        {
            return _fullscreen;
        }

        override void close()
        {
            if (_closed) return;
            if (sink.onNativeCloseRequested())
            {
                _programmaticCloseApproved = true;
                sendVoidId(_window, "performClose:", null);
                if (!_closed) _closed = true;
            }
        }

        override Size clientSize() const
        {
            return _clientSize;
        }

        override NativeSurfaceInfo nativeSurfaceInfo()
        {
            NativeSurfaceInfo info;
            if (_metalLayer !is null)
            {
                info.kind = NativeSurfaceKind.metal;
                info.handleA = _metalLayer;
            }
            return info;
        }

        private void drawNative()
        {
            if (_pixels.length == 0 || _pixelWidth <= 0 || _pixelHeight <= 0) return;
            auto graphicsContext = sendId(cast(id) cocoaClass("NSGraphicsContext"),
                "currentContext");
            if (graphicsContext is null) return;
            alias MsgPointer0 = extern(C) void* function(id, SEL);
            auto context = cast(CGContextRef) (cast(MsgPointer0) &objc_msgSend)(
                graphicsContext, selector("CGContext"));
            if (context is null) return;

            auto colorSpace = CGColorSpaceCreateDeviceRGB();
            auto provider = CGDataProviderCreateWithData(null, _pixels.ptr,
                cast(size_t) _pixelWidth * cast(size_t) _pixelHeight * uint.sizeof, null);
            if (colorSpace is null || provider is null)
            {
                if (provider !is null) CGDataProviderRelease(provider);
                if (colorSpace !is null) CGColorSpaceRelease(colorSpace);
                return;
            }
            auto image = CGImageCreate(
                cast(size_t) _pixelWidth,
                cast(size_t) _pixelHeight,
                8,
                32,
                cast(size_t) _pixelWidth * uint.sizeof,
                colorSpace,
                cgImageAlphaNoneSkipFirst | cgBitmapByteOrder32Little,
                provider,
                null,
                0,
                cgRenderingIntentDefault);
            if (image !is null)
            {
                const target = CGRect(NSPoint(0, 0),
                    NSSize(_clientSize.width, _clientSize.height));
                CGContextSaveGState(context);
                CGContextTranslateCTM(context, 0, _clientSize.height);
                CGContextScaleCTM(context, 1, -1);
                CGContextDrawImage(context, target, image);
                CGContextRestoreGState(context);
                CGImageRelease(image);
            }
            CGDataProviderRelease(provider);
            CGColorSpaceRelease(colorSpace);
        }

        private void updateClientSize(bool notify)
        {
            if (_view is null) return;
            const frame = sendRect(_view, "bounds");
            const next = Size(maxIntLocal(1, cast(int) (frame.size.width + 0.5)),
                maxIntLocal(1, cast(int) (frame.size.height + 0.5)));
            if (next == _clientSize && notify) return;
            _clientSize = next;
            if (notify)
            {
                Event event;
                event.type = EventType.resized;
                event.size = _clientSize;
                event.framebufferSize = _clientSize;
                event.displayScale = DisplayScale.init;
                sink.onNativeEvent(event);
            }
            _needsPaint = true;
        }

        private void handleMouse(id nativeEvent, EventType type, MouseButton button)
        {
            const location = sendPoint(nativeEvent, "locationInWindow");
            const local = sendPointPointId(_view, "convertPoint:fromView:", location, null);
            Event event;
            event.type = type;
            event.position = Point(cast(int) local.x, cast(int) local.y);
            event.globalPosition = event.position;
            event.precisePosition = PointF(local.x, local.y);
            event.preciseGlobalPosition = event.precisePosition;
            event.hasPrecisePosition = true;
            event.button = button;
            event.modifiers = modifiers(sendUInteger(nativeEvent, "modifierFlags"));
            event.timestampMs = cast(long) (sendDouble(nativeEvent, "timestamp") * 1000.0);
            sink.onNativeEvent(event);
        }

        private MouseButton otherMouseButton(id nativeEvent)
        {
            const number = sendUInteger(nativeEvent, "buttonNumber");
            if (number == 2) return MouseButton.middle;
            if (number == 3) return MouseButton.extra1;
            return MouseButton.extra2;
        }

        private void handleWheel(id nativeEvent)
        {
            const location = sendPoint(nativeEvent, "locationInWindow");
            const local = sendPointPointId(_view, "convertPoint:fromView:", location, null);
            Event event;
            event.type = EventType.mouseWheel;
            event.position = Point(cast(int) local.x, cast(int) local.y);
            event.globalPosition = event.position;
            event.precisePosition = PointF(local.x, local.y);
            event.preciseGlobalPosition = event.precisePosition;
            event.hasPrecisePosition = true;
            event.wheelX = wheelAmount(sendDouble(nativeEvent, "scrollingDeltaX"));
            event.wheelY = wheelAmount(sendDouble(nativeEvent, "scrollingDeltaY"));
            event.modifiers = modifiers(sendUInteger(nativeEvent, "modifierFlags"));
            event.timestampMs = cast(long) (sendDouble(nativeEvent, "timestamp") * 1000.0);
            sink.onNativeEvent(event);
        }

        private void handleKey(id nativeEvent, bool down)
        {
            Event event;
            event.type = down ? EventType.keyDown : EventType.keyUp;
            event.key = mapKey(sendUShort(nativeEvent, "keyCode"));
            event.modifiers = modifiers(sendUInteger(nativeEvent, "modifierFlags"));
            event.repeat = down && sendBool(nativeEvent, "isARepeat") != 0;
            event.timestampMs = cast(long) (sendDouble(nativeEvent, "timestamp") * 1000.0);
            sink.onNativeEvent(event);

            if (down && !event.control() && !event.meta())
            {
                auto characters = sendId(nativeEvent, "characters");
                if (characters !is null)
                {
                    auto utf8 = sendCString(characters, "UTF8String");
                    if (utf8 !is null)
                    {
                        const text = toUTF32(fromStringz(utf8));
                        if (text.length > 0)
                        {
                            Event input;
                            input.type = EventType.textInput;
                            input.text = text;
                            input.modifiers = event.modifiers;
                            input.timestampMs = event.timestampMs;
                            sink.onNativeEvent(input);
                        }
                    }
                }
            }
        }

        private void cleanup()
        {
            if (_view !is null)
            {
                viewOwners.remove(cast(void*) _view);
                if (_window !is null) sendVoidId(_window, "setDelegate:", null);
            }
            if (_window !is null)
            {
                sendVoidId(_window, "orderOut:", null);
                sendVoid(_window, "release");
                _window = null;
            }
            if (_view !is null)
            {
                sendVoid(_view, "release");
                _view = null;
            }
            if (_runLoopMode !is null)
            {
                sendVoid(_runLoopMode, "release");
                _runLoopMode = null;
            }
            _metalLayer = null;
            _pixels = null;
        }

        private static uint modifiers(NSUInteger flags) @safe pure nothrow @nogc
        {
            uint result;
            if (flags & nsModifierShift) result |= cast(uint) KeyModifier.shift;
            if (flags & nsModifierControl) result |= cast(uint) KeyModifier.control;
            if (flags & nsModifierOption) result |= cast(uint) KeyModifier.alt;
            if (flags & nsModifierCommand) result |= cast(uint) KeyModifier.meta;
            if (flags & nsModifierCapsLock) result |= cast(uint) KeyModifier.capsLock;
            if (flags & nsModifierNumericPad) result |= cast(uint) KeyModifier.numLock;
            return result;
        }

        private static int wheelAmount(double value) @safe pure nothrow @nogc
        {
            if (value > 0.0)
            {
                const amount = cast(int) (value + 0.5);
                return amount > 0 ? amount : 1;
            }
            if (value < 0.0)
            {
                const amount = cast(int) (value - 0.5);
                return amount < 0 ? amount : -1;
            }
            return 0;
        }

        private static Key mapKey(ushort keyCode) @safe pure nothrow @nogc
        {
            switch (keyCode)
            {
                case 0: return Key.a;
                case 11: return Key.b;
                case 8: return Key.c;
                case 2: return Key.d;
                case 14: return Key.e;
                case 3: return Key.f;
                case 5: return Key.g;
                case 4: return Key.h;
                case 34: return Key.i;
                case 38: return Key.j;
                case 40: return Key.k;
                case 37: return Key.l;
                case 46: return Key.m;
                case 45: return Key.n;
                case 31: return Key.o;
                case 35: return Key.p;
                case 12: return Key.q;
                case 15: return Key.r;
                case 1: return Key.s;
                case 17: return Key.t;
                case 32: return Key.u;
                case 9: return Key.v;
                case 13: return Key.w;
                case 7: return Key.x;
                case 16: return Key.y;
                case 6: return Key.z;
                case 29: return Key.digit0;
                case 18: return Key.digit1;
                case 19: return Key.digit2;
                case 20: return Key.digit3;
                case 21: return Key.digit4;
                case 23: return Key.digit5;
                case 22: return Key.digit6;
                case 26: return Key.digit7;
                case 28: return Key.digit8;
                case 25: return Key.digit9;
                case 51: return Key.backspace;
                case 48: return Key.tab;
                case 36: return Key.enter;
                case 53: return Key.escape;
                case 49: return Key.space;
                case 116: return Key.pageUp;
                case 121: return Key.pageDown;
                case 119: return Key.end;
                case 115: return Key.home;
                case 123: return Key.left;
                case 126: return Key.up;
                case 124: return Key.right;
                case 125: return Key.down;
                case 114: return Key.insert;
                case 117: return Key.deleteKey;
                case 122: return Key.f1;
                case 120: return Key.f2;
                case 99: return Key.f3;
                case 118: return Key.f4;
                case 96: return Key.f5;
                case 97: return Key.f6;
                case 98: return Key.f7;
                case 100: return Key.f8;
                case 101: return Key.f9;
                case 109: return Key.f10;
                case 103: return Key.f11;
                case 111: return Key.f12;
                case 27: return Key.minus;
                case 24: return Key.equal;
                case 33: return Key.leftBracket;
                case 30: return Key.rightBracket;
                case 42: return Key.backslash;
                case 41: return Key.semicolon;
                case 39: return Key.apostrophe;
                case 50: return Key.grave;
                case 43: return Key.comma;
                case 47: return Key.period;
                case 44: return Key.slash;
                default: return Key.unknown;
            }
        }

        private static int maxIntLocal(int a, int b) @safe pure nothrow @nogc
        {
            return a > b ? a : b;
        }
    }
}
