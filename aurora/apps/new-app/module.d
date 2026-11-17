module newapp;

import core.stdc.string : memcpy;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.file : write;
import std.json : JSONValue, toJSON;
import std.math : cos, sin;
import std.mmfile : MmFile;
import std.stdio : File;

enum Revision = 1;
enum Accent = 0x38bdf8u;
enum int Width = 640;
enum int Height = 480;
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
        const offset = HeaderBytes + EventCapacity * EventBytes +
            target * frameBytes;
        data[offset .. offset + frameBytes] = pixels[];
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

private void fill(ubyte[] frame, uint color)
{
    foreach (i; 0 .. Width * Height)
    {
        frame[i * 4] = cast(ubyte) ((color >> 16) & 0xff);
        frame[i * 4 + 1] = cast(ubyte) ((color >> 8) & 0xff);
        frame[i * 4 + 2] = cast(ubyte) (color & 0xff);
        frame[i * 4 + 3] = 255;
    }
}

private void fillRect(ubyte[] frame, int x, int y, int width, int height,
    uint color)
{
    const left = x < 0 ? 0 : x;
    const top = y < 0 ? 0 : y;
    const right = x + width > Width ? Width : x + width;
    const bottom = y + height > Height ? Height : y + height;
    foreach (row; top .. bottom)
        foreach (col; left .. right)
        {
            const offset = (row * Width + col) * 4;
            frame[offset] = cast(ubyte) ((color >> 16) & 0xff);
            frame[offset + 1] = cast(ubyte) ((color >> 8) & 0xff);
            frame[offset + 2] = cast(ubyte) (color & 0xff);
            frame[offset + 3] = 255;
        }
}

private int edge(int ax, int ay, int bx, int by, int x, int y)
{
    return (x - ax) * (by - ay) - (y - ay) * (bx - ax);
}

private void fillTriangle(ubyte[] frame, int ax, int ay, int bx, int by,
    int cx, int cy, uint color)
{
    auto minX = ax < bx ? (ax < cx ? ax : cx) : (bx < cx ? bx : cx);
    auto maxX = ax > bx ? (ax > cx ? ax : cx) : (bx > cx ? bx : cx);
    auto minY = ay < by ? (ay < cy ? ay : cy) : (by < cy ? by : cy);
    auto maxY = ay > by ? (ay > cy ? ay : cy) : (by > cy ? by : cy);
    if (minX < 0) minX = 0;
    if (minY < 0) minY = 0;
    if (maxX >= Width) maxX = Width - 1;
    if (maxY >= Height) maxY = Height - 1;
    if (minX > maxX || minY > maxY) return;
    const area = edge(ax, ay, bx, by, cx, cy);
    if (area == 0) return;
    foreach (row; minY .. maxY + 1)
        foreach (col; minX .. maxX + 1)
        {
            const e0 = edge(ax, ay, bx, by, col, row);
            const e1 = edge(bx, by, cx, cy, col, row);
            const e2 = edge(cx, cy, ax, ay, col, row);
            if ((e0 >= 0 && e1 >= 0 && e2 >= 0) ||
                (e0 <= 0 && e1 <= 0 && e2 <= 0))
            {
                const offset = (row * Width + col) * 4;
                frame[offset] = cast(ubyte) ((color >> 16) & 0xff);
                frame[offset + 1] = cast(ubyte) ((color >> 8) & 0xff);
                frame[offset + 2] = cast(ubyte) (color & 0xff);
                frame[offset + 3] = 255;
            }
        }
}

struct Vec3
{
    double x;
    double y;
    double z;
}

struct ProjectedFace
{
    int[3] x;
    int[3] y;
    double depth;
    uint color;
}

private Vec3 rotate(Vec3 point, double yaw, double pitch)
{
    const cy = cos(yaw);
    const sy = sin(yaw);
    const cp = cos(pitch);
    const sp = sin(pitch);
    const x = point.x * cy + point.z * sy;
    const z = -point.x * sy + point.z * cy;
    return Vec3(x, point.y * cp - z * sp, point.y * sp + z * cp);
}

private void drawPyramid(ubyte[] frame, int tick)
{
    const yaw = tick * 0.045;
    const pitch = 0.38;
    const Vec3[4] local = [
        Vec3(0.0, 1.25, 0.0),
        Vec3(-1.0, -0.8, 1.0),
        Vec3(1.0, -0.8, 1.0),
        Vec3(0.0, -0.8, -1.0),
    ];
    const int[3][4] faces = [
        [0, 1, 2],
        [0, 2, 3],
        [0, 3, 1],
        [1, 3, 2],
    ];
    const uint[4] colors = [
        0x38bdf8,
        0x0ea5e9,
        0x0284c7,
        0x075985,
    ];
    Vec3[4] world;
    foreach (i, point; local)
        world[i] = rotate(point, yaw, pitch);

    ProjectedFace[] projected;
    foreach (faceIndex, face; faces)
    {
        ProjectedFace candidate;
        candidate.color = colors[faceIndex];
        bool visible = true;
        foreach (slot, vertex; face)
        {
            const cameraZ = 4.4 - world[vertex].z;
            if (cameraZ <= 0.1)
            {
                visible = false;
                break;
            }
            const scale = 560.0 / cameraZ;
            candidate.x[slot] = cast(int) (Width / 2 +
                world[vertex].x * scale);
            candidate.y[slot] = cast(int) (Height / 2 -
                world[vertex].y * scale);
            candidate.depth += cameraZ;
        }
        if (!visible) continue;
        candidate.depth /= 3;
        projected ~= candidate;
    }
    projected.sort!((a, b) => a.depth > b.depth);
    foreach (face; projected)
        fillTriangle(frame, face.x[0], face.y[0], face.x[1], face.y[1],
            face.x[2], face.y[2], face.color);
}

private void draw(ubyte[] frame, int tick)
{
    fill(frame, 0x0b1220);
    foreach (x; 0 .. Width / 32 + 1)
        fillRect(frame, x * 32, 0, 1, Height, 0x152238);
    foreach (y; 0 .. Height / 32 + 1)
        fillRect(frame, 0, y * 32, Width, 1, 0x152238);
    fillRect(frame, 24, 24, Width - 48, Height - 48, 0x0f172a);
    fillRect(frame, 24, 24, Width - 48, 2, Accent);
    fillRect(frame, 24, Height - 26, Width - 48, 2, Accent);

    drawPyramid(frame, tick);
}

void main(string[] args)
{
    string surfacePath;
    string statePath;
    int buildId = 1;
    int seconds = 30;
    for (size_t i = 1; i < args.length; ++i)
    {
        if (args[i] == "--surface" && i + 1 < args.length)
            surfacePath = args[++i];
        else if (args[i] == "--state" && i + 1 < args.length)
            statePath = args[++i];
        else if (args[i] == "--seconds" && i + 1 < args.length)
            seconds = to!int(args[++i]);
        else if (args[i] == "--build" && i + 1 < args.length)
            buildId = to!int(args[++i]);
    }
    if (surfacePath.length == 0 || statePath.length == 0)
        throw new Exception("New App requires --surface and --state");

    auto surface = Surface(surfacePath);
    auto frame = new ubyte[Width * Height * 4];
    auto state = JSONValue(string[string].init);
    state.object["build"] = JSONValue(buildId);
    state.object["revision"] = JSONValue(Revision);
    write(statePath, state.toJSON());

    foreach (tick; 0 .. seconds * 60)
    {
        draw(frame, tick);
        surface.publish(frame);
        surface.waitHost(surface.sequence);
        Thread.sleep(16.msecs);
    }
    surface.close();
}
