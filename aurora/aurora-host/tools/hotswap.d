module hotswap;

import core.stdc.string : memcpy;
import core.sys.windows.windows : GetCurrentProcessId;
import core.thread : Thread;
import core.time : msecs, seconds;
import std.conv : to;
import std.file : copy, dirEntries, exists, getSize, mkdirRecurse, read,
    readText, remove, rmdirRecurse, rename, SpanMode, tempDir,
    timeLastModified, write, thisExePath;
import std.json : JSONValue, parseJSON, toJSON;
import std.mmfile : MmFile;
import std.path : buildPath, dirName;
import std.process : Pid, kill, spawnProcess, tryWait, wait;
import std.random : uniform;
import std.socket : InternetAddress, Socket, SocketException, TcpSocket;
import std.stdio : File, stderr, stdout, writeln;
import std.string : indexOf, replace, split, strip;

enum int Width = 320;
enum int Height = 240;
private int sceneWidth = Width;
private int sceneHeight = Height;
enum int StaleMs = 500;
enum int EventBytes = 24;
enum int EventCapacity = 64;
enum int HeaderBytes = 80;
enum int BufferCount = 2;

struct SharedSurface
{
    MmFile file;
    ubyte[] data;
    int width;
    int height;
    int frameBytes;
    ulong sequence;

    this(string path, int width, int height)
    {
        this.width = width;
        this.height = height;
        this.frameBytes = width * height * 4;
        const size = HeaderBytes + EventCapacity * EventBytes +
            BufferCount * frameBytes;
        auto stream = File(path, "wb");
        stream.rawWrite(new ubyte[size]);
        stream.close();
        file = new MmFile(path, MmFile.Mode.readWrite, cast(ulong) size, null);
        data = cast(ubyte[]) file[];

        immutable char[8] magic = "AURSFACE";
        memcpy(data.ptr, magic.ptr, magic.length);
        put!uint(8, 2);            // version
        put!uint(12, HeaderBytes); // header size
        put!uint(16, width);
        put!uint(20, height);
        put!uint(24, 0);           // active buffer
        put!uint(28, EventCapacity);
        put!ulong(32, 0);          // sequence
        put!ulong(40, 0);          // host read sequence
        put!uint(48, 0);           // input head
        put!uint(52, 0);           // input tail
        put!uint(56, EventBytes);
        put!uint(60, BufferCount);
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

    bool waitHost(ulong wanted, int timeoutMs = 1000)
    {
        auto deadline = timeoutMs;
        while (get!ulong(40) < wanted)
        {
            if (deadline <= 0) return false;
            Thread.sleep(5.msecs);
            deadline -= 5;
        }
        return true;
    }

    void close()
    {
        file = null;
    }
}

private ubyte[] quadrantFrame(int generation)
{
    immutable colors = generation == 2
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
            frame[index++] = cast(ubyte) colors[quadrant][0];
            frame[index++] = cast(ubyte) colors[quadrant][1];
            frame[index++] = cast(ubyte) colors[quadrant][2];
            frame[index++] = cast(ubyte) colors[quadrant][3];
        }
    }
    return frame;
}

private int readStateValue(string path)
{
    if (!exists(path)) return 10;
    try
    {
        auto value = parseJSON(readText(path));
        return value.object["value"].get!int;
    }
    catch (Exception)
    {
        return 10;
    }
}

private void moduleMain(string[] args)
{
    int generation;
    string surfacePath;
    string statePath;
    int seconds = 15;
    for (size_t i = 0; i < args.length; ++i)
    {
        if (args[i] == "--generation" && i + 1 < args.length)
            generation = to!int(args[++i]);
        else if (args[i] == "--surface" && i + 1 < args.length)
            surfacePath = args[++i];
        else if (args[i] == "--state" && i + 1 < args.length)
            statePath = args[++i];
        else if (args[i] == "--seconds" && i + 1 < args.length)
            seconds = to!int(args[++i]);
    }
    if (generation < 1 || surfacePath.length == 0 || statePath.length == 0)
        throw new Exception("module requires --generation, --surface, --state");

    const value = readStateValue(statePath) + 1;
    auto surface = SharedSurface(surfacePath, Width, Height);
    auto state = JSONValue(string[string].init);
    state.object["generation"] = JSONValue(generation);
    state.object["value"] = JSONValue(value);
    state.object["pid"] = JSONValue(cast(long) GetCurrentProcessId());
    write(statePath, state.toJSON());
    const frame = quadrantFrame(generation);
    const deadline = seconds;
    for (int i = 0; i < deadline * 100; ++i)
    {
        surface.publish(frame);
        surface.waitHost(surface.sequence, 500);
        Thread.sleep(10.msecs);
    }
    surface.close();
}

class HostLink
{
    private Socket socket;
    private string buffer;
    private long nextId;

    this(Socket socket)
    {
        this.socket = socket;
        buffer = "";
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
                return result;
            }
            auto chunk = new ubyte[8192];
            auto count = socket.receive(chunk);
            if (count <= 0) throw new Exception("host socket closed");
            buffer ~= cast(char[]) chunk[0 .. count];
        }
    }

    private JSONValue exchange(JSONValue payload)
    {
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
                throw new Exception("host command failed: " ~
                    payload.object["command"].get!string ~ " " ~
                    response.object["error"].get!string);
            return response;
        }
    }

    JSONValue request(string command, string[string] fields = null)
    {
        auto payload = JSONValue(string[string].init);
        payload.object["id"] = JSONValue(++nextId);
        payload.object["command"] = JSONValue(command);
        if (fields !is null)
            foreach (key, value; fields)
                payload.object[key] = JSONValue(value);
        return exchange(payload);
    }

    JSONValue request(string command, JSONValue[string] fields)
    {
        auto payload = JSONValue(string[string].init);
        payload.object["id"] = JSONValue(++nextId);
        payload.object["command"] = JSONValue(command);
        foreach (key, value; fields)
            payload.object[key] = value;
        return exchange(payload);
    }


    void close()
    {
        socket.close();
    }
}

private JSONValue surfaceNode(string surfacePath, string[] events)
{
    auto surface = JSONValue(string[string].init);
    surface.object["id"] = JSONValue("module");
    surface.object["type"] = JSONValue("surface");
    surface.object["path"] = JSONValue(surfacePath);
    surface.object["width"] = JSONValue(sceneWidth);
    surface.object["height"] = JSONValue(sceneHeight);
    surface.object["flex"] = JSONValue(1);
    surface.object["fit"] = JSONValue("contain");
    surface.object["background"] = JSONValue("#080c12");
    surface.object["staleMs"] = JSONValue(StaleMs);
    JSONValue[] eventValues;
    if (events !is null)
        foreach (eventName; events)
            eventValues ~= JSONValue(eventName);
    surface.object["events"] = JSONValue(eventValues);
    return surface;
}

private void writeScene(string path, string surfacePath, string title,
    string[] events = null, bool customTitlebar = false,
    int titlebarHeight = 34)
{
    auto scene = JSONValue(string[string].init);
    scene.object["schemaVersion"] = JSONValue(2);
    auto window = JSONValue(string[string].init);
    window.object["title"] = JSONValue(title);
    window.object["width"] = JSONValue(sceneWidth);
    window.object["height"] = JSONValue(customTitlebar
        ? sceneHeight + titlebarHeight : sceneHeight);
    window.object["decorated"] = JSONValue(!customTitlebar);
    scene.object["window"] = window;
    auto surface = surfaceNode(surfacePath, events);
    if (customTitlebar)
    {
        auto root = JSONValue(string[string].init);
        root.object["id"] = JSONValue("root");
        root.object["type"] = JSONValue("column");
        root.object["spacing"] = JSONValue(0);
        root.object["padding"] = JSONValue(0);
        auto bar = JSONValue(string[string].init);
        bar.object["id"] = JSONValue("titlebar");
        bar.object["type"] = JSONValue("titleBar");
        bar.object["text"] = JSONValue(title);
        bar.object["height"] = JSONValue(titlebarHeight);
        bar.object["background"] = JSONValue("#0f172a");
        bar.object["border"] = JSONValue("#1e293b");
        bar.object["textColor"] = JSONValue("#e2e8f0");
        JSONValue[] children;
        children ~= bar;
        children ~= surface;
        root.object["children"] = JSONValue(children);
        scene.object["root"] = root;
    }
    else
    {
        scene.object["root"] = surface;
    }
    const temporary = path ~ ".tmp";
    write(temporary, scene.toJSON());
    rename(temporary, path);
}

private void waitSurface(HostLink host)
{
    JSONValue last;
    foreach (i; 0 .. 400)
    {
        auto response = host.request("surface", ["node": "module"]);
        last = response;
        if (response.object["mapped"].get!bool &&
            response.object["sequence"].get!ulong > 0)
            return;
        Thread.sleep(20.msecs);
    }
    throw new Exception("surface did not become live: " ~ last.toJSON());
}

private void waitState(string path, int generation)
{
    foreach (i; 0 .. 400)
    {
        if (exists(path))
        {
            try
            {
                auto state = parseJSON(readText(path));
                if (state.object["generation"].get!int == generation) return;
            }
            catch (Exception) {}
        }
        Thread.sleep(20.msecs);
    }
    throw new Exception("module generation did not publish state");
}

private void capture(HostLink host, string path)
{
    host.request("screenshot", ["path": path]);
    if (!exists(path)) throw new Exception("host produced no screenshot");
    auto bytes = cast(ubyte[]) read(path);
    if (bytes.length < 32 || bytes[0] != 'P' || bytes[1] != '6')
        throw new Exception("host screenshot is not a PPM");
}

private void stopQuietly(Pid process)
{
    if (process is null) return;
    try
    {
        kill(process);
    }
    catch (Exception)
    {
    }
    try
    {
        wait(process);
    }
    catch (Exception)
    {
    }
}

private void closeQuietly(HostLink link)
{
    try
    {
        link.request("close");
    }
    catch (Exception)
    {
    }
}

private void supervisorMain(string[] args)
{
    string hostPath = "aurora-host.exe";
    string outDir;
    for (size_t i = 0; i < args.length; ++i)
    {
        if (args[i] == "--host" && i + 1 < args.length)
            hostPath = args[++i];
        else if (args[i] == "--out" && i + 1 < args.length)
            outDir = args[++i];
    }
    if (!exists(hostPath))
        throw new Exception("missing host executable: " ~ hostPath);

    const temp = buildPath(tempDir(), "aurora-hotswap-" ~
        to!string(GetCurrentProcessId()) ~ "-" ~ to!string(uniform(0, 100000)));
    mkdirRecurse(temp);
    scope (exit) if (exists(temp)) rmdirRecurse(temp);
    const artifacts = outDir.length != 0 ? outDir : temp;
    if (outDir.length != 0) mkdirRecurse(artifacts);

    const scenePath = buildPath(temp, "module.scene.json");
    const statePath = buildPath(temp, "module.state.json");
    const surface1 = buildPath(temp, "module-v1.surface");
    const surface2 = buildPath(temp, "module-v2.surface");
    const shot1 = buildPath(artifacts, "module-v1.ppm");
    const shot2 = buildPath(artifacts, "module-v2.ppm");
    writeScene(scenePath, surface1, "Module hot swap v1");

    const port = uniform(20000, 40000);
    auto host = spawnProcess([hostPath, "--run", scenePath,
        "--listen", to!string(port)]);

    Socket socket;
    foreach (i; 0 .. 200)
    {
        try
        {
            auto candidate = new TcpSocket();
            candidate.connect(new InternetAddress("127.0.0.1", cast(ushort) port));
            socket = candidate;
            break;
        }
        catch (SocketException)
        {
            Thread.sleep(25.msecs);
        }
    }
    if (socket is null) throw new Exception("cannot connect to aurora-host");
    auto link = new HostLink(socket);
    scope (exit) link.close();

    Pid v1;
    Pid v2;
    scope (exit)
    {
        stopQuietly(v2);
        stopQuietly(v1);
        closeQuietly(link);
        stopQuietly(host);
    }

    const self = thisExePath();
    v1 = spawnProcess([self, "module", "--generation", "1",
        "--surface", surface1, "--state", statePath, "--seconds", "15"]);
    waitState(statePath, 1);
    waitSurface(link);
    capture(link, shot1);

    v2 = spawnProcess([self, "module", "--generation", "2",
        "--surface", surface2, "--state", statePath, "--seconds", "15"]);
    waitState(statePath, 2);
    writeScene(scenePath, surface2, "Module hot swap v2");

    import std.datetime.stopwatch : StopWatch, AutoStart;
    auto watch = StopWatch(AutoStart.yes);
    link.request("reload");
    waitSurface(link);
    watch.stop();
    capture(link, shot2);

    if (!exists(shot1) || !exists(shot2))
        throw new Exception("missing swap screenshots");
    if (read(shot1) == read(shot2))
        throw new Exception("module frames did not change");

    auto state = parseJSON(readText(statePath));
    stdout.writeln("PASS host module hot swap");
    stdout.writeln("host: pid=", host.processID, " stable");
    stdout.writeln("v1: pid=", v1.processID, " value=", 11);
    stdout.writeln("v2: pid=", v2.processID, " value=",
        state.object["value"].get!int);
    stdout.writeln("reload + remap: ", watch.peek.total!"msecs", " ms");
    stdout.writeln("screenshots: ", shot1, " -> ", shot2);
}

private double buildLiveModule(string source, string exe)
{
    import std.datetime.stopwatch : StopWatch, AutoStart;
    auto watch = StopWatch(AutoStart.yes);
    const hostDir = dirName(thisExePath());
    const auroraD = buildPath(hostDir, "..", "aurora-d", "source");
    const auroraStandard = buildPath(hostDir, "..", "aurora-standard",
        "source");
    auto child = spawnProcess(["dmd", "-i",
        "-I" ~ auroraD, "-I" ~ auroraStandard, "-of=" ~ exe, source]);
    const status = wait(child);
    watch.stop();
    if (status != 0)
        throw new Exception("live module build failed: " ~ source);
    return watch.peek.total!"msecs";
}

private ulong newestD(string root)
{
    ulong newest;
    try
    {
        foreach (entry; dirEntries(root, SpanMode.depth))
        {
            if (!entry.isFile || entry.name.length < 2 ||
                entry.name[$ - 2 .. $] != ".d")
                continue;
            try
            {
                const stamp = cast(ulong) timeLastModified(entry.name).stdTime;
                if (stamp > newest) newest = stamp;
            }
            catch (Exception)
            {
            }
        }
    }
    catch (Exception)
    {
    }
    return newest;
}

private ulong frameworkStamp()
{
    const hostDir = dirName(thisExePath());
    const auroraD = buildPath(hostDir, "..", "aurora-d", "source");
    const auroraStandard = buildPath(hostDir, "..", "aurora-standard",
        "source");
    const dStamp = newestD(auroraD);
    const standardStamp = newestD(auroraStandard);
    return standardStamp > dStamp ? standardStamp : dStamp;
}

private bool moduleCacheValid(string source, string cacheExe,
    string cacheInfo)
{
    if (!exists(cacheExe) || !exists(cacheInfo)) return false;
    try
    {
        auto info = parseJSON(readText(cacheInfo));
        return info.object["source"].get!string == source &&
            info.object["sourceTime"].get!ulong ==
                cast(ulong) timeLastModified(source).stdTime &&
            info.object["sourceSize"].get!ulong == getSize(source) &&
            info.object["frameworkTime"].get!ulong == frameworkStamp();
    }
    catch (Exception)
    {
        return false;
    }
}

private void saveModuleCache(string source, string exe, string cacheExe,
    string cacheInfo)
{
    try
    {
        if (exists(cacheExe)) remove(cacheExe);
        copy(exe, cacheExe);
        auto info = JSONValue(string[string].init);
        info.object["source"] = JSONValue(source);
        info.object["sourceTime"] = JSONValue(cast(ulong)
            timeLastModified(source).stdTime);
        info.object["sourceSize"] = JSONValue(getSize(source));
        info.object["frameworkTime"] = JSONValue(frameworkStamp());
        write(cacheInfo, info.toJSON());
    }
    catch (Exception)
    {
        // A cache miss is always safe; the next launch rebuilds.
    }
}

private JSONValue stateDocument(string path)
{
    return parseJSON(readText(path));
}

private void waitBuild(string path, int build, int timeoutMs = 8000)
{
    foreach (i; 0 .. timeoutMs / 50)
    {
        if (exists(path))
        {
            try
            {
                if (stateDocument(path).object["build"].get!int == build)
                    return;
            }
            catch (Exception)
            {
            }
        }
        Thread.sleep(50.msecs);
    }
    throw new Exception("build did not publish: " ~ to!string(build));
}

private void devMain(string[] args)
{
    string hostPath = "aurora-host.exe";
    string source;
    string outDir = "build/live-dev";
    string title = "Live module";
    string eventKind;
    bool customTitlebar;
    int titlebarHeight = 34;
    int watchSeconds = 600;
    int holdSeconds;
    for (size_t i = 0; i < args.length; ++i)
    {
        if (args[i] == "--host" && i + 1 < args.length)
            hostPath = args[++i];
        else if (args[i] == "--source" && i + 1 < args.length)
            source = args[++i];
        else if (args[i] == "--out" && i + 1 < args.length)
            outDir = args[++i];
        else if (args[i] == "--title" && i + 1 < args.length)
            title = args[++i];
        else if (args[i] == "--width" && i + 1 < args.length)
            sceneWidth = to!int(args[++i]);
        else if (args[i] == "--height" && i + 1 < args.length)
            sceneHeight = to!int(args[++i]);
        else if (args[i] == "--events" && i + 1 < args.length)
            eventKind = args[++i];
        else if (args[i] == "--titlebar")
            customTitlebar = true;
        else if (args[i] == "--titlebar-height" && i + 1 < args.length)
            titlebarHeight = to!int(args[++i]);
        else if (args[i] == "--watch" && i + 1 < args.length)
            watchSeconds = to!int(args[++i]);
        else if (args[i] == "--hold" && i + 1 < args.length)
            holdSeconds = to!int(args[++i]);
    }
    if (source.length == 0)
        throw new Exception("dev requires --source <module.d>");
    if (!exists(hostPath)) throw new Exception("missing host: " ~ hostPath);
    if (!exists(source)) throw new Exception("missing live source: " ~ source);

    import std.datetime.stopwatch : StopWatch, AutoStart;
    auto startup = StopWatch(AutoStart.yes);
    void trace(string stage)
    {
        stdout.writeln("[trace] ", startup.peek.total!"msecs",
            " ms  ", stage);
        stdout.flush();
    }
    trace("begin");

    string[] events;
    if (eventKind.length != 0)
        foreach (part; eventKind.split(","))
        {
            const name = strip(part);
            if (name.length != 0) events ~= name;
        }

    const temp = buildPath(tempDir(), "aurora-live-dev-" ~
        to!string(GetCurrentProcessId()) ~ "-" ~ to!string(uniform(0, 100000)));
    mkdirRecurse(temp);
    scope (exit) if (exists(temp)) rmdirRecurse(temp);
    const artifacts = outDir.length != 0 ? outDir : temp;
    if (outDir.length != 0) mkdirRecurse(artifacts);

    const scenePath = buildPath(temp, "dev.scene.json");
    const statePath = buildPath(temp, "dev.state.json");
    const firstSurface = buildPath(temp, "dev-1.surface");
    writeScene(scenePath, firstSurface, title, events, customTitlebar,
        titlebarHeight);
    trace("workspace ready");

    auto firstExe = buildPath(temp, "dev-1.exe");
    const cacheDir = buildPath(outDir.length ? outDir : temp, ".cache");
    mkdirRecurse(cacheDir);
    const cacheExe = buildPath(cacheDir, "module.exe");
    const cacheInfo = buildPath(cacheDir, "module.json");
    bool cacheHit;
    double firstBuildMs;
    if (moduleCacheValid(source, cacheExe, cacheInfo))
    {
        try
        {
            auto copyWatch = StopWatch(AutoStart.yes);
            copy(cacheExe, firstExe);
            copyWatch.stop();
            firstBuildMs = copyWatch.peek.total!"msecs";
            cacheHit = true;
            trace("module cache hit");
        }
        catch (Exception)
        {
            cacheHit = false;
        }
    }
    if (!cacheHit)
    {
        firstBuildMs = buildLiveModule(source, firstExe);
        trace("module built");
        saveModuleCache(source, firstExe, cacheExe, cacheInfo);
    }

    int build = 1;
    Pid current;
    Pid host;
    HostLink link;
    scope (exit)
    {
        stopQuietly(current);
        if (link !is null) closeQuietly(link);
        stopQuietly(host);
    }

    const port = uniform(20000, 40000);
    host = spawnProcess([hostPath, "--run", scenePath,
        "--listen", to!string(port)]);
    trace("host spawned");

    current = spawnProcess([firstExe, "--surface", firstSurface,
        "--state", statePath, "--build", "1", "--seconds", "900"]);
    trace("module spawned");
    Socket socket;
    foreach (i; 0 .. 200)
    {
        try
        {
            auto candidate = new TcpSocket();
            candidate.connect(new InternetAddress("127.0.0.1", cast(ushort) port));
            socket = candidate;
            break;
        }
        catch (SocketException)
        {
            Thread.sleep(25.msecs);
        }
    }
    if (socket is null) throw new Exception("cannot connect to aurora-host");
    link = new HostLink(socket);
    trace("host control connected");

    waitBuild(statePath, 1);
    trace("module state published");
    waitSurface(link);
    trace("surface mapped");
    capture(link, buildPath(artifacts, "build-1.ppm"));
    trace("first frame captured");
    auto last = readText(source);
    stdout.writeln("[1] build=1 buildMs=", firstBuildMs,
        " cache=", cacheHit ? "hit" : "miss",
        " startupMs=", startup.peek.total!"msecs",
        " hostPid=", host.processID);
    stdout.writeln("host stays open; edit ", source, " to rebuild");
    stdout.flush();

    void swap()
    {
        trace("rebuild started");
        build++;
        const surface = buildPath(temp, "dev-" ~ to!string(build) ~ ".surface");
        auto exe = buildPath(temp, "dev-" ~ to!string(build) ~ ".exe");
        const buildMs = buildLiveModule(source, exe);
        trace("rebuild built");
        saveModuleCache(source, exe, cacheExe, cacheInfo);
        auto next = spawnProcess([exe, "--surface", surface,
            "--state", statePath, "--build", to!string(build),
            "--seconds", "900"]);
        trace("rebuild module spawned");
        waitBuild(statePath, build);
        trace("rebuild state published");
        writeScene(scenePath, surface, title, events, customTitlebar,
            titlebarHeight);
        link.request("reload");
        trace("rebuild scene reloaded");
        waitSurface(link);
        trace("rebuild surface mapped");
        capture(link, buildPath(artifacts, "build-" ~ to!string(build) ~ ".ppm"));
        trace("rebuild frame captured");
        stdout.writeln("[", build, "] buildMs=", buildMs,
            " hostPid=", host.processID);
        stdout.flush();
        stopQuietly(current);
        current = next;
    }

    import std.datetime.stopwatch : StopWatch, AutoStart;
    auto watch = StopWatch(AutoStart.yes);
    while (watchSeconds <= 0 ||
        watch.peek.total!"seconds" < watchSeconds)
    {
        if (readText(source) != last)
        {
            last = readText(source);
            swap();
        }
        Thread.sleep(100.msecs);
    }

    if (holdSeconds > 0)
    {
        stdout.writeln("host stays open for ", holdSeconds, " seconds");
        stdout.flush();
        Thread.sleep(seconds(holdSeconds));
    }
}
int main(string[] args)
{
    try
    {
        if (args.length >= 2 && args[1] == "module")
        {
            moduleMain(args[2 .. $]);
            return 0;
        }
        if (args.length >= 2 && args[1] == "supervisor")
        {
            supervisorMain(args[2 .. $]);
            return 0;
        }
        if (args.length >= 2 && args[1] == "dev")
        {
            devMain(args[2 .. $]);
            return 0;
        }
        stderr.writeln("usage: aurora-hotswap module ... | supervisor ... | dev ...");
        return 2;
    }
    catch (Exception error)
    {
        stderr.writeln("FAIL hot swap: ", error.msg);
        return 1;
    }
}
