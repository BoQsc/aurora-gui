module offscreen3d;

import aurora.render.scene3d : Line3D, Scene3D;

import core.stdc.string : memcpy;
import core.sys.windows.windows : GetCurrentProcessId;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.file : exists, getcwd, mkdirRecurse, read, remove, write;
import std.json : JSONValue, parseJSON, toJSON;
import std.mmfile : MmFile;
import std.path : buildPath, isAbsolute;
import std.process : Pid, kill, spawnProcess, wait;
import std.socket : InternetAddress, Socket, SocketException, TcpSocket;
import std.stdio : File, stdout;
import std.string : indexOf;

enum int Width = 360;
enum int Height = 240;
enum int EventBytes = 24;
enum int EventCapacity = 64;
enum int HeaderBytes = 80;

final class HostLink
{
    private Socket socket;
    private char[] buffer;
    private long nextId;

    this(Socket socket)
    {
        this.socket = socket;
    }

    private string line()
    {
        while (true)
        {
            auto newline = buffer.indexOf('\n');
            if (newline >= 0)
            {
                auto result = buffer[0 .. newline];
                buffer = buffer[newline + 1 .. $];
                return result.idup;
            }
            auto chunk = new ubyte[8192];
            auto count = socket.receive(chunk);
            if (count <= 0) throw new Exception("host socket closed");
            buffer ~= cast(char[]) chunk[0 .. count];
        }
    }

    JSONValue request(string command, JSONValue[string] fields = null)
    {
        auto payload = JSONValue(string[string].init);
        payload.object["id"] = JSONValue(++nextId);
        payload.object["command"] = JSONValue(command);
        if (fields !is null)
            foreach (key, value; fields)
                payload.object[key] = value;
        socket.send(payload.toJSON() ~ "\n");
        while (true)
        {
            auto text = line();
            if (text == "READY" ||
                (text.length >= 6 && text[0 .. 6] == "EVENT ")) continue;
            if (text.length < 9 || text[0 .. 9] != "RESPONSE ")
                throw new Exception("unexpected host line: " ~ text);
            auto response = parseJSON(text[9 .. $]);
            if (response.object["id"].get!long !=
                payload.object["id"].get!long)
                throw new Exception("host response id mismatch");
            if (!response.object["ok"].get!bool)
                throw new Exception("host command failed: " ~ command ~ " " ~
                    response.object["error"].get!string);
            return response;
        }
    }

    void close()
    {
        socket.close();
    }
}

struct Surface
{
    MmFile map;
    ubyte[] data;
    int frameBytes;

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
        put!ulong(32, get!ulong(32) + 1);
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

private int iabs(int value)
{
    return value < 0 ? -value : value;
}

private void setPixel(ubyte[] frame, int x, int y, uint color, int thickness)
{
    foreach (dy; -thickness / 2 .. thickness / 2 + 1)
    {
        foreach (dx; -thickness / 2 .. thickness / 2 + 1)
        {
            const px = x + dx;
            const py = y + dy;
            if (px < 0 || px >= Width || py < 0 || py >= Height) continue;
            const offset = (py * Width + px) * 4;
            frame[offset] = cast(ubyte) ((color >> 16) & 0xff);
            frame[offset + 1] = cast(ubyte) ((color >> 8) & 0xff);
            frame[offset + 2] = cast(ubyte) (color & 0xff);
            frame[offset + 3] = 255;
        }
    }
}

private void drawLine(ubyte[] frame, Line3D line)
{
    int x0 = line.x1;
    int y0 = line.y1;
    const x1 = line.x2;
    const y1 = line.y2;
    const dx = iabs(x1 - x0);
    const sx = x0 < x1 ? 1 : -1;
    const dy = -iabs(y1 - y0);
    const sy = y0 < y1 ? 1 : -1;
    int error = dx + dy;
    while (true)
    {
        setPixel(frame, x0, y0, line.color, line.thickness);
        if (x0 == x1 && y0 == y1) break;
        const twice = 2 * error;
        if (twice >= dy)
        {
            error += dy;
            x0 += sx;
        }
        if (twice <= dx)
        {
            error += dx;
            y0 += sy;
        }
    }
}

private string sceneDocument(string surfacePath)
{
    auto scene = JSONValue(string[string].init);
    scene.object["schemaVersion"] = JSONValue(2);
    auto window = JSONValue(string[string].init);
    window.object["title"] = JSONValue("Aurora 3D Offscreen");
    window.object["width"] = JSONValue(Width);
    window.object["height"] = JSONValue(Height + 32);
    window.object["decorated"] = JSONValue(false);
    scene.object["window"] = window;
    auto root = JSONValue(string[string].init);
    root.object["id"] = JSONValue("root");
    root.object["type"] = JSONValue("column");
    root.object["spacing"] = JSONValue(0);
    root.object["padding"] = JSONValue(0);
    auto bar = JSONValue(string[string].init);
    bar.object["id"] = JSONValue("titlebar");
    bar.object["type"] = JSONValue("titleBar");
    bar.object["text"] = JSONValue("Aurora 3D Offscreen");
    bar.object["height"] = JSONValue(32);
    bar.object["background"] = JSONValue("#0b1220");
    bar.object["border"] = JSONValue("#1e293b");
    bar.object["textColor"] = JSONValue("#e2e8f0");
    auto surface = JSONValue(string[string].init);
    surface.object["id"] = JSONValue("view");
    surface.object["type"] = JSONValue("surface");
    surface.object["path"] = JSONValue(surfacePath);
    surface.object["width"] = JSONValue(Width);
    surface.object["height"] = JSONValue(Height);
    surface.object["staleMs"] = JSONValue(1000);
    surface.object["events"] = JSONValue(JSONValue[].init);
    JSONValue[] children;
    children ~= bar;
    children ~= surface;
    root.object["children"] = JSONValue(children);
    scene.object["root"] = root;
    return scene.toJSON();
}

private Socket connectTo(int port)
{
    foreach (i; 0 .. 200)
    {
        try
        {
            auto socket = new TcpSocket();
            socket.connect(new InternetAddress("127.0.0.1", cast(ushort) port));
            return socket;
        }
        catch (SocketException)
        {
            Thread.sleep(25.msecs);
        }
    }
    throw new Exception("cannot connect to aurora-host");
}

private void stopQuietly(Pid process)
{
    try { kill(process); } catch (Exception) {}
    try { wait(process); } catch (Exception) {}
}

private string absolutePathOf(string path)
{
    return isAbsolute(path) ? path : buildPath(getcwd(), path);
}

void main(string[] args)
{
    string hostPath = "aurora-host.exe";
    string outDir = "build/offscreen3d";
    int seconds = 30;
    bool capture;
    for (size_t i = 0; i < args.length; ++i)
    {
        if (args[i] == "--host" && i + 1 < args.length)
            hostPath = args[++i];
        else if (args[i] == "--out" && i + 1 < args.length)
            outDir = args[++i];
        else if (args[i] == "--seconds" && i + 1 < args.length)
            seconds = to!int(args[++i]);
        else if (args[i] == "--capture")
            capture = true;
    }
    if (!exists(hostPath)) throw new Exception("missing host: " ~ hostPath);

    const outRoot = absolutePathOf(outDir);
    mkdirRecurse(outRoot);
    const surfacePath = buildPath(outRoot, "offscreen.surface");
    const scenePath = buildPath(outRoot, "scene.json");
    const firstShot = buildPath(outRoot, "frame-start.ppm");
    const lastShot = buildPath(outRoot, "frame-end.ppm");
    if (exists(surfacePath)) remove(surfacePath);
    auto surface = Surface(surfacePath);
    write(scenePath, sceneDocument(surfacePath));

    const port = 20000 + cast(int) (GetCurrentProcessId() % 20000);
    auto host = spawnProcess([hostPath, "--run", scenePath,
        "--listen", to!string(port)]);
    scope (exit) stopQuietly(host);
    auto socket = connectTo(port);
    auto link = new HostLink(socket);
    scope (exit) link.close();

    auto frame = new ubyte[Width * Height * 4];
    foreach (i; 0 .. Width * Height)
    {
        frame[i * 4] = 11;
        frame[i * 4 + 1] = 18;
        frame[i * 4 + 2] = 32;
        frame[i * 4 + 3] = 255;
    }
    auto scene = Scene3D();
    int frames = seconds * 30;
    foreach (tick; 0 .. frames)
    {
        foreach (i; 0 .. Width * Height)
        {
            frame[i * 4] = 11;
            frame[i * 4 + 1] = 18;
            frame[i * 4 + 2] = 32;
            frame[i * 4 + 3] = 255;
        }
        foreach (line; scene.build(Width, Height, tick / 30.0))
            drawLine(frame, line);
        surface.publish(frame);
        surface.waitHost(tick + 1);
        if (tick == 0)
        {
            Thread.sleep(150.msecs);
            if (capture)
            {
                JSONValue[string] shot;
                shot["path"] = JSONValue(firstShot);
                link.request("screenshot", shot);
            }
        }
        Thread.sleep(30.msecs);
    }
    if (capture)
    {
        Thread.sleep(150.msecs);
        JSONValue[string] shot;
        shot["path"] = JSONValue(lastShot);
        link.request("screenshot", shot);
        if (read(firstShot) == read(lastShot))
            throw new Exception("offscreen presenter frames did not change");
    }
    stdout.writeln("PASS offscreen 3D presenter");
    stdout.writeln("hostPid=", host.processID, " frames=", frames,
        " surface=", Width, "x", Height);
    stdout.flush();
    surface.close();
}
