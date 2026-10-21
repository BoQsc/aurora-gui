module app;

import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.algorithm : sort;
import std.algorithm.comparison : max, min;
import std.conv : to;
import std.file : exists, mkdirRecurse, thisExePath;
import std.format : format;
import std.math : fabs, sqrt;
import std.path : buildPath, dirName, isAbsolute;
import std.process : Config, Pid, Pipe, kill, pipe, spawnProcess, tryWait,
    wait;
import std.stdio : File, stderr, writeln;

import world.render : Renderer;
import world.surface : InputEvent, SharedSurface;
import world.world : EyeHeight, InputKeyDown, InputKeyUp, InputPointerDown,
    InputPointerMove, InputState, KeyA, KeyD, KeyEscape, KeyLeft, KeyR,
    KeyRight, KeyS, KeySpace, KeyUp, KeyW, MouseLeft, Player, SurfaceHeight,
    SurfaceWidth, Vec3, WaterLevel, World, handleInput;

private void usage()
{
    writeln("aurora-host-world — software 3D terrain demo for aurora-host");
    writeln("");
    writeln("  aurora-host-world [--seed <n>]");
    writeln("  aurora-host-world --self-test [--seed <n>]");
    writeln("  aurora-host-world --render [path.ppm] [--seed <n>]");
    writeln("  aurora-host-world --publish [--seed <n>]");
    writeln("  aurora-host-world --no-host [--seconds <n>]");
    writeln("  aurora-host-world [options]");
    writeln("");
    writeln("Options:");
    writeln("  --host <path>    aurora-host executable");
    writeln("  --scene <path>   host scene file");
    writeln("  --seed <n>       world seed (default 1337)");
    writeln("");
    writeln("Controls: WASD move, drag mouse or arrow keys to look,");
    writeln("          Space jump, Shift sprint, wheel zoom, R reseed, Esc exit.");
}

private string resolvePath(string path, string base)
{
    return isAbsolute(path) ? path : buildPath(base, path);
}

private void writePpm(string path, const uint[] pixels, int width, int height)
{
    mkdirRecurse(dirName(path));
    auto file = File(path, "wb");
    file.write(format("P6\n%d %d\n255\n", width, height));
    auto row = new ubyte[width * 3];
    foreach (y; 0 .. height)
    {
        foreach (x; 0 .. width)
        {
            const value = pixels[cast(size_t) y * width + x];
            row[x * 3] = cast(ubyte) (value & 0xff);
            row[x * 3 + 1] = cast(ubyte) ((value >> 8) & 0xff);
            row[x * 3 + 2] = cast(ubyte) ((value >> 16) & 0xff);
        }
        file.rawWrite(row);
    }
    file.close();
}

private ulong hashPixels(const uint[] pixels)
{
    ulong hash = 1469598103934665603UL;
    foreach (value; pixels)
    {
        hash ^= value;
        hash *= 1099511628211UL;
    }
    return hash;
}

private size_t uniqueSamples(const uint[] pixels)
{
    uint[] sample;
    sample.reserve(pixels.length / 13 + 1);
    for (size_t index = 0; index < pixels.length; index += 13)
        sample ~= pixels[index];
    if (sample.length == 0)
        return 0;
    sample.sort();
    size_t count = 1;
    foreach (index; 1 .. sample.length)
        if (sample[index] != sample[index - 1])
            ++count;
    return count;
}

private int fail(string message)
{
    stderr.writeln("aurora-host-world self-test failed: " ~ message);
    return 1;
}

private int selfTest(string worldDir, uint seed)
{
    auto world = World(seed);
    auto player = Player();
    player.spawn(&world);
    auto renderer = Renderer(SurfaceWidth, SurfaceHeight);

    writeln("world seed ", seed, ": terrain ", world.terrain.length,
        ", water ", world.water.length, ", trees ", world.treeCount,
        ", rocks ", world.rockCount);
    if (world.terrain.length != 96 * 96)
        return fail("terrain mesh is incomplete");
    if (world.water.length == 0)
        return fail("seed produced no water");
    if (world.treeCount < 20)
        return fail("seed produced too few trees");
    if (world.rockCount < 5)
        return fail("seed produced too few rocks");

    InputState binding;
    InputEvent keyEvent;
    keyEvent.kind = InputKeyDown;
    keyEvent.key = KeyW;
    handleInput(binding, keyEvent);
    if (!binding.isDown(KeyW))
        return fail("surface key code did not map to W");
    keyEvent.kind = InputKeyUp;
    handleInput(binding, keyEvent);
    if (binding.isDown(KeyW))
        return fail("key release did not clear W");

    InputEvent pointerEvent;
    pointerEvent.kind = InputPointerDown;
    pointerEvent.button = MouseLeft;
    pointerEvent.x = 10;
    pointerEvent.y = 20;
    handleInput(binding, pointerEvent);
    pointerEvent.kind = InputPointerMove;
    pointerEvent.x = 14;
    pointerEvent.y = 23;
    handleInput(binding, pointerEvent);
    if (binding.lookDX != 4.0f || binding.lookDY != 3.0f)
        return fail("surface pointer drag did not update the look delta");

    renderer.render(&world, &player, 0.0f, 60.0f);
    const firstHash = hashPixels(renderer.pixels);
    const firstUnique = uniqueSamples(renderer.pixels);
    if (firstUnique < 300)
        return fail("first frame has too little color variation");
    const before = buildPath(worldDir, "build", "selftest-before.ppm");
    const after = buildPath(worldDir, "build", "selftest-after.ppm");
    writePpm(before, renderer.pixels, SurfaceWidth, SurfaceHeight);

    InputState input;
    input.beginFrame();
    input.jump = true;
    player.update(input, 1.0f / 60.0f, &world);
    if (player.grounded || player.velocity.y <= 0.0f)
        return fail("jump did not leave the ground");
    foreach (step; 0 .. 180)
    {
        input.beginFrame();
        player.update(input, 1.0f / 60.0f, &world);
    }
    if (!player.grounded)
        return fail("player did not land after jumping");

    input.down[KeyW] = true;
    const start = player.feet;
    foreach (step; 0 .. 120)
    {
        input.beginFrame();
        player.update(input, 1.0f / 60.0f, &world);
    }
    input.down[KeyW] = false;
    const moved = player.feet.minus(start).length();
    if (moved < 1.0f)
        return fail("W movement did not move the player");
    const ground = max(world.heightAt(player.feet.x, player.feet.z), WaterLevel);
    if (fabs(player.feet.y - ground) > 0.3f)
        return fail("player did not settle on the terrain surface");

    input.beginFrame();
    player.update(input, 1.0f / 60.0f, &world);

    renderer.render(&world, &player, 1.0f, 60.0f);
    const secondHash = hashPixels(renderer.pixels);
    if (firstHash == secondHash)
        return fail("camera movement did not change the rendered frame");

    writePpm(after, renderer.pixels, SurfaceWidth, SurfaceHeight);

    writeln("self-test OK");
    writeln("  seed: ", world.seed);
    writeln("  spawn: ", player.feet.x, ", ", player.feet.y, ", ",
        player.feet.z);
    writeln("  moved: ", moved);
    writeln("  water quads: ", world.water.length, "  trees: ",
        world.treeCount, "  rocks: ", world.rockCount);
    writeln("  color samples: ", firstUnique);
    writeln("  frame hash: ", firstHash, " -> ", secondHash);
    writeln("  images: ", before, " and ", after);
    return 0;
}

private void sendClose(ref Pid host, ref Pipe control)
{
    if (host is null)
        return;
    try
    {
        if (control.writeEnd.isOpen)
        {
            control.writeEnd.writeln(`{"id":1,"command":"close"}`);
            control.writeEnd.flush();
        }
    }
    catch (Exception)
    {
    }
}

private int runWorld(string worldDir, uint seed, string hostPath,
    string scenePath, bool noHost, float maxSeconds)
{
    const surfacePath = buildPath(worldDir, "build", "world.surface");
    const logPath = buildPath(worldDir, "build", "host.log");
    mkdirRecurse(buildPath(worldDir, "build"));

    auto world = World(seed);
    auto player = Player();
    player.spawn(&world);
    auto renderer = Renderer(SurfaceWidth, SurfaceHeight);
    auto surface = SharedSurface(surfacePath, SurfaceWidth, SurfaceHeight);

    renderer.render(&world, &player, 0.0f, 60.0f);
    auto sequence = surface.publish(cast(const(ubyte)[]) renderer.pixels);

    if (!noHost && !exists(hostPath))
    {
        stderr.writeln("missing aurora-host executable: ", hostPath);
        stderr.writeln("Build it first:");
        stderr.writeln("  cd experiments/aurora-host");
        stderr.writeln("  dub build --config=host");
        surface.close();
        return 2;
    }

    if (!noHost && !exists(scenePath))
    {
        stderr.writeln("missing scene: ", scenePath);
        surface.close();
        return 2;
    }

    writeln("aurora-host-world");
    writeln("  seed: ", seed);
    if (noHost)
        writeln("  host: none (surface-only client)");
    else
    {
        writeln("  host: ", hostPath);
        writeln("  scene: ", scenePath);
    }
    writeln("  surface: ", surfacePath);
    writeln("  drag in the window to capture the mouse; Esc exits.");

    Pipe control;
    File log;
    Pid host;
    if (!noHost)
    {
        control = pipe();
        log = File(logPath, "w");
        try
        {
            host = spawnProcess([hostPath, "--run", scenePath, "--control"],
                control.readEnd, log, log, null, Config.none, worldDir);
        }
        catch (Exception error)
        {
            stderr.writeln("failed to launch aurora-host: ", error.msg);
            surface.close();
            log.close();
            return 1;
        }
        control.readEnd.close();
    }

    InputState input;
    auto previous = MonoTime.currTime;
    auto loopStart = previous;
    float worldTime = 0.0f;
    float fps = 60.0f;
    bool finished;
    bool timedOut;


    while (!finished)
    {
        const now = MonoTime.currTime;
        const elapsed = (now - previous).total!"msecs" / 1000.0;
        previous = now;
        const dt = max(0.001f, min(0.05f, cast(float) elapsed));
        worldTime += dt;

        fps = fps * 0.90f + (1.0f / dt) * 0.10f;
        if (maxSeconds > 0.0f &&
            (now - loopStart).total!"seconds" >= maxSeconds)
        {
            timedOut = true;
            finished = true;
            continue;
        }

        input.beginFrame();
        foreach (event; surface.readInputs())
            handleInput(input, event);

        if (input.close)
        {
            sendClose(host, control);
            finished = true;
            continue;
        }
        if (input.reset)
        {
            seed = seed * 1664525u + 1013904223u;
            world.rebuild(seed);
            player.spawn(&world);
            worldTime = 0.0f;
        }

        if (host !is null && tryWait(host).terminated)
            break;

        player.update(input, dt, &world);
        renderer.render(&world, &player, worldTime, fps);
        sequence = surface.publish(cast(const(ubyte)[]) renderer.pixels);
        if (host is null)
            Thread.sleep(1.msecs);
        else if (!surface.waitForHost(sequence, 250))
        {
            if (tryWait(host).terminated)
                break;
            Thread.sleep(1.msecs);
        }
    }


    if (host !is null)
        sendClose(host, control);
    if (!noHost && control.writeEnd.isOpen)
        control.writeEnd.close();
    for (int attempt = 0; attempt < 300; ++attempt)
    {
        if (host is null || tryWait(host).terminated)
            break;
        Thread.sleep(10.msecs);
    }
    if (host !is null && !tryWait(host).terminated)
        kill(host);
    if (host !is null)
        wait(host);
    surface.close();
    if (!noHost)
        log.close();

    if (finished)
        writeln(timedOut ? "finished." : "closed.");
    return 0;
}

/** Write one current frame into build/world.surface without opening a host. */
private int publishFrame(string worldDir, uint seed)
{
    mkdirRecurse(buildPath(worldDir, "build"));
    const surfacePath = buildPath(worldDir, "build", "world.surface");
    auto world = World(seed);
    auto player = Player();
    player.spawn(&world);
    auto renderer = Renderer(SurfaceWidth, SurfaceHeight);
    auto surface = SharedSurface(surfacePath, SurfaceWidth, SurfaceHeight);
    renderer.render(&world, &player, 0.0f, 60.0f);
    surface.publish(cast(const(ubyte)[]) renderer.pixels);
    surface.close();
    writeln("published: ", surfacePath);
    return 0;
}

int main(string[] args)
{
    const worldDir = dirName(thisExePath());
    uint seed = 1337;
    bool selfTestRequested;
    bool renderRequested;
    bool publishRequested;
    bool noHost;
    float maxSeconds;
    string renderPath;
    string hostPath = buildPath(worldDir, "..", "aurora-host",
        "aurora-host-experiment.exe");
    string scenePath = buildPath(worldDir, "world.scene.json");

    for (size_t index = 1; index < args.length; ++index)
    {
        const argument = args[index];
        if (argument == "--help" || argument == "-h")
        {
            usage();
            return 0;
        }
        else if (argument == "--self-test")
        {
            selfTestRequested = true;
        }
        else if (argument == "--render")
        {
            renderRequested = true;
            if (index + 1 < args.length && args[index + 1].length > 0 &&
                args[index + 1][0] != '-')
                renderPath = args[++index];
            else
                renderPath = buildPath(worldDir, "build", "world.ppm");
        }
        else if (argument == "--publish")
        {
            publishRequested = true;
        }
        else if (argument == "--no-host")
        {
            noHost = true;
        }
        else if (argument == "--seconds")
        {
            if (index + 1 >= args.length)
            {
                stderr.writeln("--seconds needs a number");
                return 2;
            }
            maxSeconds = to!float(args[++index]);
        }
        else if (argument == "--seed")
        {
            if (index + 1 >= args.length)
            {
                stderr.writeln("--seed needs a number");
                return 2;
            }
            seed = to!uint(args[++index]);
        }
        else if (argument == "--host")
        {
            if (index + 1 >= args.length)
            {
                stderr.writeln("--host needs a path");
                return 2;
            }
            hostPath = resolvePath(args[++index], worldDir);
        }
        else if (argument == "--scene")
        {
            if (index + 1 >= args.length)
            {
                stderr.writeln("--scene needs a path");
                return 2;
            }
            scenePath = resolvePath(args[++index], worldDir);
        }
        else
        {
            stderr.writeln("unknown option: ", argument);
            usage();
            return 2;
        }
    }

    if (selfTestRequested)
        return selfTest(worldDir, seed);

    if (publishRequested)
        return publishFrame(worldDir, seed);

    if (renderRequested)
    {
        auto world = World(seed);
        auto player = Player();
        player.spawn(&world);
        auto renderer = Renderer(SurfaceWidth, SurfaceHeight);
        renderer.render(&world, &player, 0.0f, 60.0f);
        writePpm(renderPath, renderer.pixels, SurfaceWidth, SurfaceHeight);
        writeln("rendered: ", renderPath);
        return 0;
    }

    return runWorld(worldDir, seed, hostPath, scenePath, noHost, maxSeconds);
}
