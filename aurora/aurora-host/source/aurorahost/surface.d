module aurorahost.surface;

import aurorahost.events : HostEvent;
import aurorahost.protocol : MaxInputEvents, MaxSurfacePixels,
    SurfaceBufferCount, SurfaceHeaderSize, SurfaceInputEventSize,
    SurfaceInputReserve, SurfaceMagic, SurfaceVersion;
import aurora : Canvas, Color, Event, GuiWindow, Key, MouseButton, Point,
    PointF, Rect, RgbaImage, Widget;
import std.algorithm : canFind, equal;
import std.conv : to;
import std.exception : enforce;
import std.file : exists;
import std.mmfile : MmFile;
import std.process : environment;
import std.stdio : stdout;
import core.time : MonoTime;

version (Windows)
    import core.sys.windows.windows : LoadCursorA, SetCursor, ShowCursor;

struct SurfaceSpec
{
    string path;
    int width;
    int height;
    int flex;
    string fit;
    bool hasBackground;
    Color background;
    string[] events;
    uint staleMs;
}

struct SurfaceInfo
{
    bool mapped;
    int width;
    int height;
    ulong sequence;
    uint inputHead;
    uint inputTail;
    uint inputDropped;
    uint inputCoalesced;
    uint inputDroppedMoves;
    uint inputDroppedDiscrete;
    double frameAge;
    bool stale;
    uint staleMs;
    string error;
    uint retryMs;
    uint pixelWidth;
    uint pixelHeight;
    uint preferredWidth;
    uint preferredHeight;
    double displayScale;
}

private uint readU32(const(ubyte)[] data, size_t offset)
{
    return cast(uint) data[offset] |
        (cast(uint) data[offset + 1] << 8) |
        (cast(uint) data[offset + 2] << 16) |
        (cast(uint) data[offset + 3] << 24);
}

private ulong readU64(const(ubyte)[] data, size_t offset)
{
    return cast(ulong) readU32(data, offset) |
        (cast(ulong) readU32(data, offset + 4) << 32);
}

private void writeU16(ubyte[] data, size_t offset, ushort value)
{
    data[offset] = cast(ubyte) (value & 0xff);
    data[offset + 1] = cast(ubyte) (value >> 8);
}

private void writeU32(ubyte[] data, size_t offset, uint value)
{
    data[offset] = cast(ubyte) (value & 0xff);
    data[offset + 1] = cast(ubyte) ((value >> 8) & 0xff);
    data[offset + 2] = cast(ubyte) ((value >> 16) & 0xff);
    data[offset + 3] = cast(ubyte) ((value >> 24) & 0xff);
}

private void writeU64(ubyte[] data, size_t offset, ulong value)
{
    writeU32(data, offset, cast(uint) value);
    writeU32(data, offset + 4, cast(uint) (value >> 32));
}

private int readI32(const(ubyte)[] data, size_t offset)
{
    return cast(int) readU32(data, offset);
}

private void writeI32(ubyte[] data, size_t offset, int value)
{
    writeU32(data, offset, cast(uint) value);
}

/**
 * A retained leaf backed by a versioned memory-mapped RGBA surface.
 *
 * The writer publishes a frame and sequence number; the host copies the active
 * buffer on tick, acknowledges the sequence, and draws it as one retained image.
 * Pointer and keyboard events are written back through a lock-free ring so
 * external engines do not need per-frame JSON traffic.
 */
class SurfaceWidget : Widget
{
    private string _path;
    private int _width;
    private int _height;
    private bool _fitContain;
    private bool _hasBackground;
    private Color _background;
    private bool _pointerEvents;
    private bool _keyEvents;
    private bool _pressed;
    private MmFile _mapping;
    private RgbaImage _image;
    private ulong _lastSequence;
    private double _retry;
    private uint _inputDropped;
    private uint _inputCoalesced;
    private uint _inputDroppedMoves;
    private uint _inputDroppedDiscrete;
    private double _frameAge;
    private bool _hasFrame;
    private uint _staleMs = 500;
    private string _lastError;
    private uint _pixelWidth;
    private uint _pixelHeight;
    private bool _cursorHidden;
    private MonoTime _lastPaint;
    private double _paintSumMs = 0;
    private double _paintMaxMs = 0;
    private int _paintSamples;
    private double _insideSumMs = 0;
    private double _insideMaxMs = 0;
    private double _fillSumMs = 0;
    private double _fillMaxMs = 0;
    private double _imageSumMs = 0;
    private double _imageMaxMs = 0;
    private double _outsideSumMs = 0;
    private double _outsideMaxMs = 0;
    private double _lastInsideMs = 0;
    private double _steadyMaxGapMs = 0;
    private int _steadyWarmupSamples;
    private int _steadyGapSamples;
    private int _paintOver16;
    private int _paintOver20;
    private double _paintMaxIntervalMs = 0.0;
    private MonoTime _tickStart;
    private MonoTime _refreshDone;
    private MonoTime _paintStart;
    private MonoTime _paintEnd;
    private bool _traceFrame;
    private bool _trace;

    void delegate(HostEvent) onInput;

    this(const SurfaceSpec spec)
    {
        _trace = environment.get("AURORA_HOST_TRACE") == "1";
        _path = spec.path;
        _width = spec.width;
        _height = spec.height;
        _fitContain = spec.fit == "contain";
        _hasBackground = spec.hasBackground;
        _background = spec.background;
        _pointerEvents = spec.events.canFind("pointer");
        _keyEvents = spec.events.canFind("key");
        _staleMs = spec.staleMs > 0 ? spec.staleMs : 500;
        _retry = 0.0;
        setFocusable(_keyEvents);
        if (_width > 0)
            layoutHints().preferredWidth = _width;
        if (_height > 0)
            layoutHints().preferredHeight = _height;
        if (spec.flex > 0)
            layoutHints().flex = spec.flex;
    }

    private string headerError(const(ubyte)[] data)
    {
        if (data.length < SurfaceHeaderSize)
            return "surface header is shorter than 80 bytes";
        if (!equal(data[0 .. 8], cast(const(ubyte)[]) SurfaceMagic))
            return "surface magic mismatch";
        if (readU32(data, 8) != SurfaceVersion)
            return "unsupported surface version " ~ to!string(readU32(data, 8));
        const headerSize = readU32(data, 12);
        if (headerSize < SurfaceHeaderSize)
            return "surface header size is too small";
        const pixelWidth = readU32(data, 16);
        const pixelHeight = readU32(data, 20);
        if (pixelWidth == 0 || pixelHeight == 0)
            return "surface dimensions are zero";
        if (cast(ulong) pixelWidth * pixelHeight > MaxSurfacePixels)
            return "surface exceeds max pixel count";
        const capacity = readU32(data, 28);
        if (capacity == 0 || capacity > MaxInputEvents)
            return "surface input capacity is invalid";
        if (readU32(data, 56) != SurfaceInputEventSize)
            return "surface input event size mismatch";
        const bufferCount = readU32(data, 60);
        if (bufferCount < SurfaceBufferCount)
            return "surface buffer count is too small";
        const active = readU32(data, 24);
        if (active >= bufferCount)
            return "surface active frame buffer is invalid";
        const frameBytes = readU32(data, 64);
        if (cast(ulong) frameBytes != cast(ulong) pixelWidth * pixelHeight * 4)
            return "surface frame byte count mismatch";
        const expected = cast(ulong) headerSize +
            cast(ulong) capacity * SurfaceInputEventSize +
            cast(ulong) bufferCount * frameBytes;
        if (expected > data.length)
            return "surface mapping is smaller than its declared layout";
        return null;
    }

    private double currentDisplayScale()
    {
        auto window = cast(GuiWindow) host();
        return window is null ? 1.0 : window.displayScale().x();
    }

    private uint preferredExtent(int logical, double scale)
    {
        const value = cast(double) logical * scale;
        return value <= 0 ? 1 : cast(uint) (value + 0.5);
    }

    private Rect contentRect()
    {
        const full = Rect(0, 0, bounds().width, bounds().height);
        if (!_fitContain || _image is null || full.empty)
            return full;
        const imageWidth = _image.width();
        const imageHeight = _image.height();
        if (imageWidth <= 0 || imageHeight <= 0)
            return full;
        const imageAspect = cast(double) imageWidth / imageHeight;
        const boundsAspect = cast(double) full.width / full.height;
        if (boundsAspect > imageAspect)
        {
            const width = cast(int) (full.height * imageAspect + 0.5);
            return Rect((full.width - width) / 2, 0, width, full.height);
        }
        const height = cast(int) (full.width / imageAspect + 0.5);
        return Rect(0, (full.height - height) / 2, full.width, height);
    }

    private Point mappedPointer(int x, int y)
    {
        if (!_fitContain || _image is null || _pixelWidth == 0 ||
            _pixelHeight == 0)
            return Point(x, y);
        const destination = contentRect();
        if (destination.width <= 0 || destination.height <= 0)
            return Point(x, y);
        int mappedX = (x - destination.x) * cast(int) _pixelWidth /
            destination.width;
        int mappedY = (y - destination.y) * cast(int) _pixelHeight /
            destination.height;
        if (mappedX < 0) mappedX = 0;
        if (mappedY < 0) mappedY = 0;
        if (mappedX >= cast(int) _pixelWidth)
            mappedX = cast(int) _pixelWidth - 1;
        if (mappedY >= cast(int) _pixelHeight)
            mappedY = cast(int) _pixelHeight - 1;
        return Point(mappedX, mappedY);
    }

    private void clearMapping(string error)
    {
        _mapping = null;
        _image = null;
        _pixelWidth = 0;
        _pixelHeight = 0;
        _hasFrame = false;
        _frameAge = 0.0;
        _lastError = error;
        invalidate();
    }

    private void mapSurface()
    {
        if (!exists(_path))
        {
            clearMapping("surface file is missing");
            return;
        }
        try
        {
            auto mapping = new MmFile(_path, MmFile.Mode.readWrite, 0, null);
            const data = cast(const(ubyte)[]) mapping[];
            const error = headerError(data);
            if (error !is null)
            {
                clearMapping(error);
                mapping = null;
                return;
            }
            _mapping = mapping;
            _pixelWidth = readU32(data, 16);
            _pixelHeight = readU32(data, 20);
            _image = null;
            _lastSequence = 0;
            _hasFrame = false;
            _frameAge = 0.0;
            _inputDropped = 0;
            _inputCoalesced = 0;
            _inputDroppedMoves = 0;
            _inputDroppedDiscrete = 0;
            _lastError = "";
            _retry = 0.5;
        }
        catch (Exception error)
        {
            clearMapping("surface open failed: " ~ error.msg);
        }
    }

    /** Copy a newly published frame and acknowledge it to the writer. */
    void refresh(double deltaSeconds)
    {
        _frameAge += deltaSeconds;
        if (_mapping is null)
        {
            _retry -= deltaSeconds;
            if (_retry > 0.0)
                return;
            _retry = 0.5;
            mapSurface();
            if (_mapping is null)
                return;
        }

        auto data = cast(ubyte[]) _mapping[];
        const error = headerError(data);
        if (error !is null)
        {
            clearMapping(error);
            return;
        }

        // The producer owns mouse capture. Mirror it so cursor hiding is not
        // lost when the surface widget is rebuilt or the host misses the down.
        setCursorHidden((readU32(data, 68) & 1) != 0);

        const sequence = readU64(data, 32);
        if (sequence == _lastSequence)
            return;

        const pixelWidth = readU32(data, 16);
        const pixelHeight = readU32(data, 20);
        const active = readU32(data, 24);
        const inputCapacity = readU32(data, 28);
        const bufferCount = readU32(data, 60);
        const frameBytes = readU32(data, 64);
        const headerSize = readU32(data, 12);
        if (active >= bufferCount || inputCapacity > MaxInputEvents)
            return;

        const frameOffset = cast(size_t) headerSize +
            cast(size_t) inputCapacity * SurfaceInputEventSize;
        const frameStart = frameOffset + cast(size_t) active * frameBytes;
        const frameEnd = frameStart + frameBytes;
        if (frameEnd > data.length)
            return;

        _pixelWidth = pixelWidth;
        _pixelHeight = pixelHeight;
        if (_image is null)
            _image = new RgbaImage(pixelWidth, pixelHeight,
                data[frameStart .. frameEnd]);
        else
            _image.reset(pixelWidth, pixelHeight, data[frameStart .. frameEnd]);
        _lastSequence = sequence;
        _hasFrame = true;
        _frameAge = 0.0;
        writeU64(data, 40, sequence);
        invalidate();
    }

    SurfaceInfo info()
    {
        SurfaceInfo result;
        result.mapped = _mapping !is null;
        result.width = _width;
        result.height = _height;
        result.sequence = _lastSequence;
        result.inputDropped = _inputDropped;
        result.inputCoalesced = _inputCoalesced;
        result.inputDroppedMoves = _inputDroppedMoves;
        result.inputDroppedDiscrete = _inputDroppedDiscrete;
        result.staleMs = _staleMs;
        result.frameAge = _hasFrame ? _frameAge : 0.0;
        result.stale = _mapping !is null &&
            (!_hasFrame || _frameAge * 1000.0 > _staleMs);
        result.error = _lastError.length > 0 ? _lastError :
            (_mapping is null ? "surface not mapped" : "");
        result.retryMs = _mapping is null ? cast(uint) (_retry * 1000.0) : 0;
        result.pixelWidth = _pixelWidth;
        result.pixelHeight = _pixelHeight;
        result.displayScale = currentDisplayScale();
        result.preferredWidth = preferredExtent(_width, result.displayScale);
        result.preferredHeight = preferredExtent(_height, result.displayScale);
        if (_mapping !is null)
        {
            const data = cast(const(ubyte)[]) _mapping[];
            if (data.length >= SurfaceHeaderSize)
            {
                result.inputHead = readU32(data, 48);
                result.inputTail = readU32(data, 52);
            }
        }
        return result;
    }

    private void pushInput(uint kind, MouseButton button, Key key,
        uint modifiers, int x, int y, int wheelX = 0, int wheelY = 0)
    {
        if (_mapping is null)
            return;
        auto data = cast(ubyte[]) _mapping[];
        if (data.length < SurfaceHeaderSize)
            return;
        const headerSize = readU32(data, 12);
        const capacity = readU32(data, 28);
        const eventSize = readU32(data, 56);
        if (eventSize != SurfaceInputEventSize || capacity == 0 ||
            capacity > MaxInputEvents)
            return;
        const inputEnd = cast(size_t) headerSize +
            cast(size_t) capacity * eventSize;
        if (inputEnd > data.length)
            return;
        const head = readU32(data, 48);
        const tail = readU32(data, 52);

        // Pointer motion is state, not an ordered command. Collapse adjacent
        // identical moves so a jittery window cannot fill the ring with
        // duplicate samples before the consumer polls.
        if (kind == 2 && tail > head)
        {
            const previous = cast(size_t) headerSize +
                cast(size_t) ((tail - 1) % capacity) * eventSize;
            if (data[previous] == 2 && data[previous + 1] == button &&
                data[previous + 2] == (key & 0xff) &&
                data[previous + 3] == ((key >> 8) & 0xff) &&
                readU32(data, previous + 4) == modifiers &&
                readI32(data, previous + 8) == x &&
                readI32(data, previous + 12) == y &&
                readI32(data, previous + 16) == wheelX &&
                readI32(data, previous + 20) == wheelY)
            {
                ++_inputCoalesced;
                return;
            }
        }
        // Reserve room for discrete events. Pointer moves must not consume the
        // whole ring and cause a later key-up or button-up to be dropped.
        uint reserve;
        if (capacity > 1)
        {
            reserve = capacity / 4;
            if (reserve == 0)
                reserve = 1;
            if (reserve > SurfaceInputReserve)
                reserve = SurfaceInputReserve;
        }
        const moveLimit = capacity - reserve;
        if (kind == 2 && tail - head >= moveLimit)
        {
            ++_inputDroppedMoves;
            ++_inputDropped;
            return;
        }
        if (kind != 2 && tail - head >= capacity)
        {
            ++_inputDroppedDiscrete;
            ++_inputDropped;
            return;
        }
        const offset = cast(size_t) headerSize +
            cast(size_t) (tail % capacity) * eventSize;
        data[offset] = cast(ubyte) kind;
        data[offset + 1] = cast(ubyte) button;
        writeU16(data, offset + 2, cast(ushort) key);
        writeU32(data, offset + 4, modifiers);
        writeI32(data, offset + 8, x);
        writeI32(data, offset + 12, y);
        writeI32(data, offset + 16, wheelX);
        writeI32(data, offset + 20, wheelY);
        writeU32(data, 52, tail + 1);
    }

    private void emitPointer(string kind, int x, int y, MouseButton button,
        uint modifiers, int wheelX = 0, int wheelY = 0)
    {
        uint code;
        switch (kind)
        {
            case "down": code = 1; break;
            case "move": code = 2; break;
            case "up": code = 3; break;
            case "wheel": code = 4; break;
            default: return;
        }
        const mapped = mappedPointer(x, y);
        pushInput(kind == "wheel" ? 4 : code, button, Key.unknown, modifiers,
            mapped.x, mapped.y, wheelX, wheelY);
        if (onInput is null)
            return;
        HostEvent event;
        event.name = "pointer";
        event.kind = kind;
        event.x = x;
        event.y = y;
        event.wheelX = wheelX;
        event.wheelY = wheelY;
        event.button = button;
        event.modifiers = modifiers;
        onInput(event);
    }

    private void emitKey(string kind, Key key, uint modifiers)
    {
        pushInput(kind == "down" ? 5 : 6, MouseButton.none, key, modifiers,
            0, 0);
        if (onInput is null)
            return;
        HostEvent event;
        event.name = "key";
        event.kind = kind;
        event.key = key;
        event.modifiers = modifiers;
        onInput(event);
    }

    void injectPointer(string kind, int x, int y, MouseButton button,
        uint modifiers, int wheelX = 0, int wheelY = 0)
    {
        if (_pointerEvents)
            emitPointer(kind, x, y, button, modifiers, wheelX, wheelY);
    }

    void injectKey(string kind, Key key, uint modifiers)
    {
        if (_keyEvents)
            emitKey(kind, key, modifiers);
    }

    private void setCursorHidden(bool hidden)
    {
        version (Windows)
        {
            if (_cursorHidden == hidden)
                return;
            ShowCursor(hidden ? 0 : 1);
            SetCursor(hidden ? null :
                LoadCursorA(null, cast(char*) 32512));
            _cursorHidden = hidden;
        }
    }

    override bool onMouseDown(ref Event event)
    {
        if (!_pointerEvents || event.button != MouseButton.left)
            return false;
        requestFocus();
        captureMouse();
        _pressed = true;
        emitPointer("down", event.position.x, event.position.y, event.button,
            event.modifiers);
        setCursorHidden(true);
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (!_pointerEvents)
            return false;
        emitPointer("move", event.position.x, event.position.y, event.button,
            event.modifiers);
        return _pressed;
    }

    override bool onMouseUp(ref Event event)
    {
        if (!_pointerEvents || event.button != MouseButton.left)
            return false;
        if (_pressed)
            releaseMouse();
        _pressed = false;
        emitPointer("up", event.position.x, event.position.y, event.button,
            event.modifiers);
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        if (!_pointerEvents)
            return false;
        emitPointer("wheel", event.position.x, event.position.y, event.button,
            event.modifiers, event.wheelX, event.wheelY);
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (!_keyEvents)
            return false;
        if (event.key == Key.escape)
            setCursorHidden(false);
        emitKey("down", event.key, event.modifiers);
        return true;
    }

    override bool onKeyUp(ref Event event)
    {
        if (!_keyEvents)
            return false;
        emitKey("up", event.key, event.modifiers);
        return true;
    }

    override void onFocusChanged(bool focused)
    {
        if (!focused)
            setCursorHidden(false);
        super.onFocusChanged(focused);
    }

    override bool onPointerLatch(PointF globalPosition)
    {
        if (!_pressed || !_pointerEvents)
            return false;
        const local = globalToLocal(globalPosition.rounded());
        emitPointer("move", local.x, local.y, MouseButton.none, 0);
        return true;
    }

    override bool wantsContinuousPointerFrames() const @safe pure nothrow @nogc
    {
        return _pressed && _pointerEvents;
    }

    protected override void onTick(double deltaSeconds)
    {
        auto tick = MonoTime.currTime;
        if (_traceFrame && _paintEnd != MonoTime.init &&
            _refreshDone != MonoTime.init && _paintStart != MonoTime.init)
        {
            const intervalMs = (tick - _tickStart).total!"usecs" / 1000.0;
            if (intervalMs > 20.0)
            {
                if (_trace)
                {
                    stdout.writeln("host frame over20 intervalMs=", intervalMs,
                        " refreshMs=", (_refreshDone - _tickStart)
                            .total!"usecs" / 1000.0,
                        " prePaintMs=", (_paintStart - _refreshDone)
                            .total!"usecs" / 1000.0,
                        " paintMs=", (_paintEnd - _paintStart)
                            .total!"usecs" / 1000.0,
                        " postPaintMs=", (tick - _paintEnd)
                            .total!"usecs" / 1000.0,
                        " postPaintStampUs=", tick.ticks);
                    stdout.flush();
                }
            }
        }
        _tickStart = tick;
        version (Windows)
            if (_cursorHidden)
                SetCursor(null);
        refresh(deltaSeconds);
        invalidate();
        _refreshDone = MonoTime.currTime;
        _traceFrame = true;
    }

    protected override void onPaint(ref Canvas canvas)
    {
        auto entry = MonoTime.currTime;
        _paintStart = entry;
        if (_lastPaint != MonoTime.init)
        {
            const deltaMs = (entry - _lastPaint).total!"usecs" / 1000.0;
            _paintSumMs += deltaMs;
            if (deltaMs > _paintMaxMs) _paintMaxMs = deltaMs;
            if (deltaMs > 16.667)
            {
                ++_paintOver16;
                stdout.writeln("host outlier ms=", deltaMs);
                stdout.flush();
            }
            if (_steadyWarmupSamples < 60)
                ++_steadyWarmupSamples;
            else
            {
                ++_steadyGapSamples;
                if (deltaMs > _steadyMaxGapMs)
                    _steadyMaxGapMs = deltaMs;
            }
            if (deltaMs > 20.0) ++_paintOver20;
            if (deltaMs > _paintMaxIntervalMs)
                _paintMaxIntervalMs = deltaMs;
            const outsideMs = deltaMs > _lastInsideMs ?
                deltaMs - _lastInsideMs : 0.0;
            _outsideSumMs += outsideMs;
            if (outsideMs > _outsideMaxMs) _outsideMaxMs = outsideMs;
        }
        _lastPaint = entry;
        const full = Rect(0, 0, bounds().width, bounds().height);
        if (_hasBackground)
        {
            auto fillStart = MonoTime.currTime;
            canvas.fillRect(full, _background);
            const fillMs = (MonoTime.currTime - fillStart)
                .total!"usecs" / 1000.0;
            _fillSumMs += fillMs;
            if (fillMs > _fillMaxMs) _fillMaxMs = fillMs;
        }
        if (_image !is null)
        {
            auto imageStart = MonoTime.currTime;
            canvas.drawImage(contentRect(), _image);
            const imageMs = (MonoTime.currTime - imageStart)
                .total!"usecs" / 1000.0;
            _imageSumMs += imageMs;
            if (imageMs > _imageMaxMs) _imageMaxMs = imageMs;
        }
        const insideMs = (MonoTime.currTime - entry).total!"usecs" / 1000.0;
        _paintEnd = MonoTime.currTime;
        _insideSumMs += insideMs;
        if (insideMs > _insideMaxMs) _insideMaxMs = insideMs;
        _lastInsideMs = insideMs;
        if (++_paintSamples >= 600)
        {
            if (_trace)
            {
                stdout.writeln("host paint intervalAvg=",
                    _paintSumMs / _paintSamples, " max=", _paintMaxMs,
                    " insideAvg=", _insideSumMs / _paintSamples,
                    " insideMax=", _insideMaxMs, " outsideAvg=",
                    _outsideSumMs / _paintSamples, " outsideMax=", _outsideMaxMs,
                    " fillAvg=", _fillSumMs / _paintSamples, " fillMax=",
                    _fillMaxMs, " imageAvg=", _imageSumMs / _paintSamples,
                    " imageMax=", _imageMaxMs);
                stdout.writeln("host steady max paint gap ms=",
                    _steadyMaxGapMs, " samples=", _steadyGapSamples);
                stdout.flush();
            }
            _paintSumMs = 0;
            _paintMaxMs = 0;
            _insideSumMs = 0;
            _insideMaxMs = 0;
            _fillSumMs = 0;
            _fillMaxMs = 0;
            _imageSumMs = 0;
            _imageMaxMs = 0;
            _outsideSumMs = 0;
            _outsideMaxMs = 0;
            _paintOver16 = 0;
            _paintOver20 = 0;
            _paintMaxIntervalMs = 0;
            _paintSamples = 0;
            _steadyMaxGapMs = 0;
            _steadyGapSamples = 0;
        }
    }
}
