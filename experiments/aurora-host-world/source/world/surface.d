module world.surface;

import core.thread : Thread;
import core.time : msecs;
import std.file : mkdirRecurse;
import std.mmfile : MmFile;
import std.path : dirName;
import std.stdio : File;

enum uint SurfaceVersion = 2;
enum uint SurfaceHeaderSize = 80;
enum uint SurfaceEventSize = 24;
enum uint SurfaceCapacity = 64;
enum uint SurfaceBufferCount = 2;

struct InputEvent
{
    uint kind;
    uint button;
    uint key;
    uint modifiers;
    int x;
    int y;
    int wheelX;
    int wheelY;
}

/**
 * Writer half of aurora-host's versioned shared-surface ABI.
 *
 * The host copies the active RGBA buffer on its 60 Hz tick and acknowledges the
 * sequence. Pointer and key records travel back through the same mapping, so
 * the renderer never sends per-frame JSON commands.
 */
struct SharedSurface
{
    int width;
    int height;
    MmFile mapping;
    ubyte[] bytes;
    uint sequence;

    this(string path, int width, int height)
    {
        this.width = width;
        this.height = height;
        const frameBytes = cast(size_t) width * height * 4;
        const size = SurfaceHeaderSize + SurfaceCapacity * SurfaceEventSize +
            SurfaceBufferCount * frameBytes;

        const parent = dirName(path);
        if (parent.length > 0)
            mkdirRecurse(parent);

        auto file = File(path, "wb");
        file.seek(cast(long) size - 1);
        file.write(cast(ubyte) 0);
        file.close();

        mapping = new MmFile(path, MmFile.Mode.readWrite, 0, null);
        bytes = cast(ubyte[]) mapping[];
        bytes[0 .. 8] = cast(ubyte[]) "AURSFACE";
        writeU32(8, SurfaceVersion);
        writeU32(12, SurfaceHeaderSize);
        writeU32(16, cast(uint) width);
        writeU32(20, cast(uint) height);
        writeU32(24, 0);
        writeU32(28, SurfaceCapacity);
        writeU64(32, 0);
        writeU64(40, 0);
        writeU32(48, 0);
        writeU32(52, 0);
        writeU32(56, SurfaceEventSize);
        writeU32(60, SurfaceBufferCount);
        writeU32(64, cast(uint) frameBytes);
        writeU32(68, 0);
        writeU32(72, 0);
        writeU32(76, 0);
    }

    private uint readU32(size_t offset) const
    {
        return cast(uint) bytes[offset] |
            (cast(uint) bytes[offset + 1] << 8) |
            (cast(uint) bytes[offset + 2] << 16) |
            (cast(uint) bytes[offset + 3] << 24);
    }

    private void writeU32(size_t offset, uint value)
    {
        bytes[offset] = cast(ubyte) (value & 0xff);
        bytes[offset + 1] = cast(ubyte) ((value >> 8) & 0xff);
        bytes[offset + 2] = cast(ubyte) ((value >> 16) & 0xff);
        bytes[offset + 3] = cast(ubyte) ((value >> 24) & 0xff);
    }

    private ulong readU64(size_t offset) const
    {
        return cast(ulong) readU32(offset) |
            (cast(ulong) readU32(offset + 4) << 32);
    }

    private void writeU64(size_t offset, ulong value)
    {
        writeU32(offset, cast(uint) value);
        writeU32(offset + 4, cast(uint) (value >> 32));
    }

    private size_t frameOffset(uint index) const
    {
        return SurfaceHeaderSize + SurfaceCapacity * SurfaceEventSize +
            cast(size_t) index * width * height * 4;
    }

    ulong hostRead() const
    {
        return readU64(40);
    }

    /** Publish one RGBA8 frame into the inactive buffer. */
    ulong publish(const(ubyte)[] frame)
    {
        const frameBytes = cast(size_t) width * height * 4;
        if (frame.length != frameBytes)
            throw new Exception("shared surface frame has the wrong size");

        const active = readU32(24);
        const target = 1 - active;
        const offset = frameOffset(target);
        bytes[offset .. offset + frameBytes] = frame;
        writeU32(24, target);
        ++sequence;
        writeU64(32, sequence);
        return sequence;
    }

    /** Wait for the host to copy and acknowledge a published frame. */
    bool waitForHost(ulong wanted, int timeoutMs = 250)
    {
        for (int elapsed = 0; elapsed < timeoutMs; ++elapsed)
        {
            if (hostRead() >= wanted)
                return true;
            Thread.sleep(1.msecs);
        }
        return hostRead() >= wanted;
    }

    /** Drain every pending pointer/key/wheel record from the input ring. */
    InputEvent[] readInputs()
    {
        InputEvent[] events;
        const head = readU32(48);
        const tail = readU32(52);
        if (tail < head)
            return events;

        const count = tail - head;
        if (count > 4096)
            return events;
        events.reserve(count);
        foreach (index; head .. tail)
        {
            const offset = SurfaceHeaderSize +
                cast(size_t) (index % SurfaceCapacity) * SurfaceEventSize;
            InputEvent event;
            event.kind = bytes[offset];
            event.button = bytes[offset + 1];
            event.key = cast(uint) bytes[offset + 2] |
                (cast(uint) bytes[offset + 3] << 8);
            event.modifiers = readU32(offset + 4);
            event.x = cast(int) readU32(offset + 8);
            event.y = cast(int) readU32(offset + 12);
            event.wheelX = cast(int) readU32(offset + 16);
            event.wheelY = cast(int) readU32(offset + 20);
            events ~= event;
        }
        writeU32(48, tail);
        return events;
    }

    void close()
    {
        bytes = null;
        mapping = null;
    }
}
