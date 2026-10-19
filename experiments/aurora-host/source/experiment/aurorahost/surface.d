module experiment.aurorahost.surface;

import experiment.aurorahost.events : HostEvent;
import experiment.aurorahost.protocol : MaxInputEvents, MaxSurfacePixels,
    SurfaceBufferCount, SurfaceHeaderSize, SurfaceInputEventSize, SurfaceMagic,
    SurfaceVersion;
import aurora : Canvas, Color, Event, Key, MouseButton, PointF, Rect,
    RgbaImage, Widget;
import std.algorithm : canFind, equal;
import std.exception : enforce;
import std.file : exists;
import std.mmfile : MmFile;

struct SurfaceSpec
{
    string path;
    int width;
    int height;
    int flex;
    bool hasBackground;
    Color background;
    string[] events;
}

struct SurfaceInfo
{
    bool mapped;
    int width;
    int height;
    ulong sequence;
    uint inputHead;
    uint inputTail;
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
    private bool _hasBackground;
    private Color _background;
    private bool _pointerEvents;
    private bool _keyEvents;
    private bool _pressed;
    private MmFile _mapping;
    private RgbaImage _image;
    private ulong _lastSequence;
    private double _retry;

    void delegate(HostEvent) onInput;

    this(const SurfaceSpec spec)
    {
        _path = spec.path;
        _width = spec.width;
        _height = spec.height;
        _hasBackground = spec.hasBackground;
        _background = spec.background;
        _pointerEvents = spec.events.canFind("pointer");
        _keyEvents = spec.events.canFind("key");
        setFocusable(_keyEvents);
        if (_width > 0)
            layoutHints().preferredWidth = _width;
        if (_height > 0)
            layoutHints().preferredHeight = _height;
        if (spec.flex > 0)
            layoutHints().flex = spec.flex;
    }

    private bool headerValid(const(ubyte)[] data)
    {
        if (data.length < SurfaceHeaderSize)
            return false;
        if (!equal(data[0 .. 8], cast(const(ubyte)[]) SurfaceMagic))
            return false;
        if (readU32(data, 8) != SurfaceVersion)
            return false;
        if (readU32(data, 12) < SurfaceHeaderSize)
            return false;
        if (readU32(data, 16) != _width || readU32(data, 20) != _height)
            return false;
        if (readU32(data, 56) != SurfaceInputEventSize)
            return false;
        if (readU32(data, 60) < SurfaceBufferCount)
            return false;
        if (readU32(data, 64) != cast(uint) (_width * _height * 4))
            return false;
        return cast(ulong) _width * _height <= MaxSurfacePixels;
    }

    private void mapSurface()
    {
        if (!exists(_path))
            return;
        try
        {
            auto mapping = new MmFile(_path, MmFile.Mode.readWrite, 0, null);
            const data = cast(const(ubyte)[]) mapping[];
            if (!headerValid(data))
            {
                mapping = null;
                return;
            }
            _mapping = mapping;
            _lastSequence = 0;
            _retry = 0.5;
        }
        catch (Exception)
        {
            // The writer may be creating or replacing the file.
        }
    }

    /** Copy a newly published frame and acknowledge it to the writer. */
    void refresh(double deltaSeconds)
    {
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
        if (!headerValid(data))
        {
            _mapping = null;
            return;
        }

        const sequence = readU64(data, 32);
        if (sequence == _lastSequence)
            return;

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

        if (_image is null)
            _image = new RgbaImage(_width, _height, data[frameStart .. frameEnd]);
        else
            _image.reset(_width, _height, data[frameStart .. frameEnd]);
        _lastSequence = sequence;
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
        if (tail - head >= capacity)
            return;
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
        pushInput(kind == "wheel" ? 4 : code, button, Key.unknown, modifiers,
            x, y, wheelX, wheelY);
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

    override bool onMouseDown(ref Event event)
    {
        if (!_pointerEvents || event.button != MouseButton.left)
            return false;
        requestFocus();
        captureMouse();
        _pressed = true;
        emitPointer("down", event.position.x, event.position.y, event.button,
            event.modifiers);
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
        refresh(deltaSeconds);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const full = Rect(0, 0, bounds().width, bounds().height);
        if (_hasBackground)
            canvas.fillRect(full, _background);
        if (_image !is null)
            canvas.drawImage(full, _image);
    }
}
