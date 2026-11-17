module livruntime;

import core.stdc.string : memcpy;
import core.sys.windows.windows : GetCurrentProcessId, GetProcAddress,
    LoadLibraryA;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.file : exists, readText, write;
import std.json : JSONValue, parseJSON, toJSON;
import std.mmfile : MmFile;
import std.stdio : File;
import std.string : toStringz;

enum int Width = 320;
enum int Height = 240;
enum int EventBytes = 24;
enum int EventCapacity = 64;
enum int HeaderBytes = 80;

struct LogicState
{
    int build;
    int pointerX;
    int pointerY;
    int pointerDown;
    int keyCode;
    int value;
}

extern(C) alias FrameFn = void function(ubyte* pixels, int width, int height,
    LogicState* state);

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
        const offset = HeaderBytes + EventCapacity * EventBytes +
            target * frameBytes;
        data[offset .. offset + frameBytes] = pixels[];
        put!uint(24, target);
        sequence++;
        put!ulong(32, sequence);
    }

    void readInput(ref LogicState state)
    {
        const head = get!uint(48);
        const tail = get!uint(52);
        foreach (i; 0 .. tail - head)
        {
            const offset = HeaderBytes +
                ((head + i) % EventCapacity) * EventBytes;
            const kind = data[offset];
            if (kind >= 1 && kind <= 3)
            {
                int x;
                int y;
                memcpy(&x, data.ptr + offset + 8, int.sizeof);
                memcpy(&y, data.ptr + offset + 12, int.sizeof);
                state.pointerX = x;
                state.pointerY = y;
                state.pointerDown = kind == 1;
            }
            else if (kind == 5 || kind == 6)
            {
                ushort key;
                memcpy(&key, data.ptr + offset + 2, ushort.sizeof);
                state.keyCode = key;
            }
        }
        put!uint(48, tail);
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

private FrameFn loadFrame(string path)
{
    if (path.length == 0) return null;
    auto library = LoadLibraryA(toStringz(path));
    if (library is null) return null;
    auto symbol = GetProcAddress(library, toStringz("aurora_logic_frame"));
    if (symbol is null) return null;
    return cast(FrameFn) symbol;
}

private void writeState(string path, ref LogicState state)
{
    auto json = JSONValue(string[string].init);
    json.object["build"] = JSONValue(state.build);
    json.object["pointerX"] = JSONValue(state.pointerX);
    json.object["pointerY"] = JSONValue(state.pointerY);
    json.object["pointerDown"] = JSONValue(state.pointerDown);
    json.object["value"] = JSONValue(state.value);
    json.object["runtimePid"] = JSONValue(cast(long) GetCurrentProcessId());
    try
    {
        write(path, json.toJSON());
    }
    catch (Exception)
    {
    }
}

private void fillDefault(ubyte[] frame)
{
    foreach (i; 0 .. Width * Height)
    {
        frame[i * 4] = 15;
        frame[i * 4 + 1] = 23;
        frame[i * 4 + 2] = 42;
        frame[i * 4 + 3] = 255;
    }
}

void main(string[] args)
{
    string surfacePath;
    string statePath;
    string logicPath;
    string signalPath;
    int seconds = 60;
    for (size_t i = 0; i < args.length; ++i)
    {
        if (args[i] == "--surface" && i + 1 < args.length)
            surfacePath = args[++i];
        else if (args[i] == "--state" && i + 1 < args.length)
            statePath = args[++i];
        else if (args[i] == "--logic" && i + 1 < args.length)
            logicPath = args[++i];
        else if (args[i] == "--signal" && i + 1 < args.length)
            signalPath = args[++i];
        else if (args[i] == "--seconds" && i + 1 < args.length)
            seconds = to!int(args[++i]);
    }
    if (surfacePath.length == 0 || statePath.length == 0)
        throw new Exception("runtime requires --surface and --state");

    auto surface = Surface(surfacePath);
    auto frame = new ubyte[Width * Height * 4];
    fillDefault(frame);
    auto draw = loadFrame(logicPath);
    LogicState state;
    state.build = 1;
    state.pointerX = Width / 2;
    state.pointerY = Height / 2;
    state.value = 0;
    string lastSignal;
    writeState(statePath, state);

    for (int tick = 0; tick < seconds * 60; ++tick)
    {
        if (signalPath.length != 0 && exists(signalPath))
        {
            try
            {
                auto text = readText(signalPath);
                if (text != lastSignal)
                {
                    lastSignal = text;
                    auto signal = parseJSON(text);
                    auto next = loadFrame(signal.object["path"].get!string);
                    if (next !is null)
                    {
                        draw = next;
                        state.build = signal.object["build"].get!int;
                        writeState(statePath, state);
                    }
                }
            }
            catch (Exception)
            {
            }
        }
        surface.readInput(state);
        if (draw !is null) draw(frame.ptr, Width, Height, &state);
        else fillDefault(frame);
        surface.publish(frame);
        surface.waitHost(surface.sequence);
        if (tick % 5 == 0) writeState(statePath, state);
        Thread.sleep(16.msecs);
    }
    surface.close();
}
