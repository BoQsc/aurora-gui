module present3d;

import aurora.render.scene3d : Line3D, Scene3D, Triangle3D;

import core.sys.windows.windows : GetCurrentProcessId;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.file : exists, getcwd, mkdirRecurse, read, write;
import std.format : format;
import std.json : JSONValue, parseJSON, toJSON;
import std.path : buildPath;
import std.process : Pid, kill, spawnProcess, wait;
import std.socket : InternetAddress, Socket, SocketException, TcpSocket;
import std.stdio : stderr, stdout;
import std.string : indexOf;

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

private string sceneDocument()
{
    auto scene = JSONValue(string[string].init);
    scene.object["schemaVersion"] = JSONValue(2);
    auto window = JSONValue(string[string].init);
    window.object["title"] = JSONValue("Aurora 3D First");
    window.object["width"] = JSONValue(360);
    window.object["height"] = JSONValue(272);
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
    bar.object["text"] = JSONValue("Aurora 3D First");
    bar.object["height"] = JSONValue(32);
    bar.object["background"] = JSONValue("#0b1220");
    bar.object["border"] = JSONValue("#1e293b");
    bar.object["textColor"] = JSONValue("#e2e8f0");
    auto canvas = JSONValue(string[string].init);
    canvas.object["id"] = JSONValue("view");
    canvas.object["type"] = JSONValue("canvas");
    canvas.object["width"] = JSONValue(360);
    canvas.object["height"] = JSONValue(240);
    canvas.object["background"] = JSONValue("#0b1220");
    canvas.object["commands"] = JSONValue(JSONValue[].init);
    JSONValue[] children;
    children ~= bar;
    children ~= canvas;
    root.object["children"] = JSONValue(children);
    scene.object["root"] = root;
    return scene.toJSON();
}

private JSONValue[string] canvasPayload(Line3D[] lines, Triangle3D[] triangles)
{
    JSONValue[] commands;
    foreach (triangle; triangles)
    {
        auto command = JSONValue(string[string].init);
        command.object["op"] = JSONValue("triangle");
        command.object["x"] = JSONValue(triangle.x1);
        command.object["y"] = JSONValue(triangle.y1);
        command.object["x2"] = JSONValue(triangle.x2);
        command.object["y2"] = JSONValue(triangle.y2);
        command.object["x3"] = JSONValue(triangle.x3);
        command.object["y3"] = JSONValue(triangle.y3);
        const r = (triangle.color >> 16) & 0xff;
        const g = (triangle.color >> 8) & 0xff;
        const b = triangle.color & 0xff;
        command.object["color"] = JSONValue(format("#%02X%02X%02X", r, g, b));
        commands ~= command;
    }
    foreach (line; lines)
    {
        auto command = JSONValue(string[string].init);
        command.object["op"] = JSONValue("line");
        command.object["x"] = JSONValue(line.x1);
        command.object["y"] = JSONValue(line.y1);
        command.object["x2"] = JSONValue(line.x2);
        command.object["y2"] = JSONValue(line.y2);
        const r = (line.color >> 16) & 0xff;
        const g = (line.color >> 8) & 0xff;
        const b = line.color & 0xff;
        command.object["color"] = JSONValue(format("#%02X%02X%02X", r, g, b));
        command.object["thickness"] = JSONValue(line.thickness);
        commands ~= command;
    }
    JSONValue[string] fields;
    fields["node"] = JSONValue("view");
    fields["commands"] = JSONValue(commands);
    return fields;
}

private void stopQuietly(Pid process)
{
    try { kill(process); } catch (Exception) {}
    try { wait(process); } catch (Exception) {}
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

void main(string[] args)
{
    string hostPath = "aurora-host.exe";
    string outDir = "build/present3d";
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

    const root = outDir.length != 0 ? outDir : "build/present3d";
    mkdirRecurse(root);
    const scenePath = buildPath(root, "scene.json");
    write(scenePath, sceneDocument());

    const port = 20000 + cast(int) (GetCurrentProcessId() % 20000);
    auto host = spawnProcess([hostPath, "--run", scenePath,
        "--listen", to!string(port)]);
    scope (exit) stopQuietly(host);

    auto socket = connectTo(port);
    auto link = new HostLink(socket);
    scope (exit) link.close();

    Scene3D scene;
    const firstShot = buildPath(root, "frame-start.ppm");
    const lastShot = buildPath(root, "frame-end.ppm");
    int frames = seconds * 30;
    foreach (frame; 0 .. frames)
    {
        auto lines = scene.build(360, 240, frame / 30.0);
        auto triangles = scene.buildTriangles(360, 240, frame / 30.0);
        auto fields = canvasPayload(lines, triangles);
        link.request("setCanvas", fields);
        if (frame == 0)
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
            throw new Exception("3D presenter frames did not change");
    }

    stdout.writeln("PASS in-host 3D presenter");
    stdout.writeln("hostPid=", host.processID, " frames=", frames,
        " lines=", scene.build(360, 240, 0).length);
    stdout.flush();
}
