module liveapp;

import core.stdc.string : memcpy;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.file : exists, readText, write;
import std.json : JSONValue, parseJSON, toJSON;
import std.mmfile : MmFile;
import std.stdio : File;

enum Revision = 1;
enum int Width = 320;
enum int Height = 240;
enum int EventBytes = 24;
enum int EventCapacity = 64;
enum int HeaderBytes = 80;

struct Surface
{
    MmFile map;
    ubyte[] data;
    int frameBytes;
    ulong sequence;

    this(string path)
    {
        frameBytes = Width * Height * 4;
        const size = HeaderBytes + EventCapacity * EventBytes +
            2 * frameBytes;
        auto stream = File(path, "wb");
        stream.rawWrite(new ubyte[size]);
        stream.close();
        map = new MmFile(path, MmFile.Mode.readWrite, cast(ulong) size, null);
        data = cast(ubyte[]) map[];
        char[8] magic = "AURSFACE";
        memcpy(data.ptr, magic.ptr, 8);
        put!uint(8, 2);
        put!uint(12, HeaderBytes);
        put!uint(16, Width);
        put!uint(20, Height);
        put!uint(24, 0);
        put!uint(28, EventCapacity);
        put!ulong(32, 0);
        put!ulong(40, 0);
        put!uint(48, 0);
        put!uint(52, 0);
        put!uint(56, EventBytes);
        put!uint(60, 2);
        put!uint(64, frameBytes);

    }

    private void put(T)(size_t offset, T value)
    {
        memcpy(data.ptr + offset, &value, T.sizeof);
    }

    private T get(T)(size_t offset)
    {
        T value;
        memcpy(&value, data.ptr + offset, T.sizeof);
        return value;
    }

    void publish(const(ubyte)[] pixels)
    {
        const active = get!uint(24);
        const target = 1 - active;
        data[HeaderBytes + EventCapacity * EventBytes + target * frameBytes ..
            HeaderBytes + EventCapacity * EventBytes + (target + 1) * frameBytes]
            = pixels[];
        put!uint(24, target);
        sequence++;
        put!ulong(32, sequence);

    }

    bool waitHost(ulong wanted, int timeoutMs = 500)
    {
        while (get!ulong(40) < wanted)
        {
            if (timeoutMs <= 0) return false;
            Thread.sleep(5.msecs);
            timeoutMs -= 5;

        }
        return true;
    }

    void close()
    {
        map = null;
    }
}

private ubyte[] frameBytes()
{
    immutable colors = Revision == 2
        ? [[0, 120, 220, 255], [255, 180, 0, 255],
           [200, 240, 255, 255], [24, 16, 32, 255]]
        : [[0, 200, 120, 255], [230, 57, 70, 255],
           [241, 250, 238, 255], [16, 24, 32, 255]];
    auto frame = new ubyte[Width * Height * 4];
    size_t index;
    foreach (y; 0 .. Height)
    {
        foreach (x; 0 .. Width)
        {
            const quadrant = (x >= Width / 2 ? 1 : 0) +
                (y >= Height / 2 ? 2 : 0);
            foreach (component; colors[quadrant])
                frame[index++] = cast(ubyte) component;
        }
    }
    return frame;
}

void main(string[] args)
{
    string surfacePath;
    string statePath;
    int seconds = 15;
    for (size_t i = 1; i < args.length; ++i)
    {
        if (args[i] == "--surface" && i + 1 < args.length)
            surfacePath = args[++i];
        else if (args[i] == "--state" && i + 1 < args.length)
            statePath = args[++i];
        else if (args[i] == "--seconds" && i + 1 < args.length)
            seconds = to!int(args[++i]);
    }
    if (surfacePath.length == 0 || statePath.length == 0)
        throw new Exception("live module requires --surface and --state");

    int value = 10;
    if (exists(statePath))
    {
        try
        {
            value = parseJSON(readText(statePath)).object["value"].get!int;
        }
        catch (Exception)
        {
        }
    }
    value++;

    auto surface = Surface(surfacePath);
    auto state = JSONValue(string[string].init);
    state.object["generation"] = JSONValue(Revision);
    state.object["value"] = JSONValue(value);
    write(statePath, state.toJSON());

    const frame = frameBytes();
    for (int tick = 0; tick < seconds * 100; ++tick)
    {
        surface.publish(frame);
        surface.waitHost(surface.sequence);
        Thread.sleep(10.msecs);
    }
    surface.close();
}
