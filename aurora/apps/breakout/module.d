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
enum PaddleWidth = 140;
enum BallSpeed = 3;
enum int Width = 320;
enum int Height = 240;
enum int EventBytes = 24;
enum int EventCapacity = 64;
enum int HeaderBytes = 80;
enum int Bricks = 32;

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

    void readPointer(ref int paddleX, ref int autoTicks)
    {
        const head = get!uint(48);
        const tail = get!uint(52);
        const count = tail - head;
        foreach (i; 0 .. count)
        {
            const offset = HeaderBytes +
                ((head + i) % EventCapacity) * EventBytes;
            const kind = data[offset];
            if (kind >= 1 && kind <= 3)
            {
                int x;
                memcpy(&x, data.ptr + offset + 8, int.sizeof);
                paddleX = x;
                autoTicks = 0;
            }
        }
        put!uint(48, tail);
    }

    void close()
    {
        map = null;
    }
}

struct Game
{
    int build;
    int score;
    int lives;
    int paddleX;
    int ballX;
    int ballY;
    int ballDX;
    int ballDY;
    bool[Bricks] bricks;

    void resetBall()
    {
        ballX = Width / 2;
        ballY = Height / 2;
        ballDX = BallSpeed;
        ballDY = -BallSpeed;
    }

    void reset()
    {
        score = 0;
        lives = 3;
        paddleX = Width / 2;
        bricks[] = true;
        resetBall();
    }

    void load(string path)
    {
        reset();
        if (!exists(path)) return;
        try
        {
            auto state = parseJSON(readText(path));
            score = state.object["score"].get!int;
            lives = state.object["lives"].get!int;
            paddleX = state.object["paddleX"].get!int;
            ballX = state.object["ballX"].get!int;
            ballY = state.object["ballY"].get!int;
            ballDX = state.object["ballDX"].get!int;
            ballDY = state.object["ballDY"].get!int;
            auto saved = state.object["bricks"].array;
            foreach (i; 0 .. Bricks)
                if (i < saved.length)
                    bricks[i] = saved[i].get!int != 0;
        }
        catch (Exception)
        {
            reset();
        }
    }

    void save(string path)
    {
        auto state = JSONValue(string[string].init);
        state.object["build"] = JSONValue(build);
        state.object["generation"] = JSONValue(Revision);
        state.object["score"] = JSONValue(score);
        state.object["lives"] = JSONValue(lives);
        state.object["paddleX"] = JSONValue(paddleX);
        state.object["paddleWidth"] = JSONValue(cast(int) PaddleWidth);
        state.object["ballX"] = JSONValue(ballX);
        state.object["ballY"] = JSONValue(ballY);
        state.object["ballDX"] = JSONValue(ballDX);
        state.object["ballDY"] = JSONValue(ballDY);
        JSONValue[] saved;
        foreach (brick; bricks) saved ~= JSONValue(brick ? 1 : 0);
        state.object["bricks"] = JSONValue(saved);
        try
        {
            write(path, state.toJSON());
        }
        catch (Exception)
        {
            // The supervisor may be reading the state file at this instant.
            // The next frame will publish it instead of taking down the game.
        }
    }

    void step(ref int autoTicks)
    {
        if (autoTicks < 1000) autoTicks++;
        if (autoTicks > 95)
        {
            if (paddleX < ballX) paddleX += 4;
            else if (paddleX > ballX) paddleX -= 4;
        }
        const half = PaddleWidth / 2;
        if (paddleX < half) paddleX = half;
        if (paddleX > Width - half) paddleX = Width - half;

        ballX += ballDX;
        ballY += ballDY;
        if (ballX <= 0 || ballX >= Width - 6) ballDX = -ballDX;
        if (ballY <= 0 || ballY >= Height - 6)
        {
            if (ballY <= 0) ballDY = -ballDY;
        }

        const paddleY = Height - 24;
        if (ballDY > 0 && ballY + 6 >= paddleY &&
            ballY < paddleY + 8 &&
            ballX + 6 >= paddleX - half &&
            ballX <= paddleX + half)
        {
            ballDY = -abs(ballDY);
            ballY = paddleY - 6;
        }

        const brickW = Width / 8;
        const brickH = 12;
        foreach (row; 0 .. 4)
        {
            foreach (col; 0 .. 8)
            {
                const index = row * 8 + col;
                if (!bricks[index]) continue;
                const x = col * brickW;
                const y = 30 + row * (brickH + 4);
                if (ballX + 6 >= x && ballX <= x + brickW &&
                    ballY + 6 >= y && ballY <= y + brickH)
                {
                    bricks[index] = false;
                    score += 10;
                    ballDY = -ballDY;
                    break;
                }
            }
        }

        if (ballY > Height)
        {
            lives--;
            if (lives <= 0) reset();
            else resetBall();
        }
    }

    void draw(ubyte[] frame)
    {
        frame[] = 0;
        void rect(int x, int y, int w, int h, ubyte r, ubyte g, ubyte b)
        {
            foreach (yy; y .. y + h)
            {
                if (yy < 0 || yy >= Height) continue;
                foreach (xx; x .. x + w)
                {
                    if (xx < 0 || xx >= Width) continue;
                    const offset = (yy * Width + xx) * 4;
                    frame[offset] = r;
                    frame[offset + 1] = g;
                    frame[offset + 2] = b;
                    frame[offset + 3] = 255;
                }
            }
        }

        rect(0, 0, Width, Height, 8, 12, 22);
        const brickW = Width / 8;
        const brickH = 12;
        immutable colors = [
            [0, 200, 120], [0, 160, 220], [255, 180, 0], [230, 57, 70]
        ];
        foreach (row; 0 .. 4)
        {
            foreach (col; 0 .. 8)
            {
                if (!bricks[row * 8 + col]) continue;
                const c = colors[row];
                rect(col * brickW + 1, 30 + row * (brickH + 4) + 1,
                    brickW - 2, brickH - 2, cast(ubyte) c[0],
                    cast(ubyte) c[1], cast(ubyte) c[2]);
            }
        }
        rect(paddleX - PaddleWidth / 2, Height - 24, PaddleWidth, 8,
            120, 235, 255);
        rect(ballX, ballY, 6, 6, 255, 255, 255);
    }
}

private int abs(int value)
{
    return value < 0 ? -value : value;
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
        throw new Exception("Breakout requires --surface and --state");

    Game game;
    game.load(statePath);
    game.build = buildId;
    auto surface = Surface(surfacePath);
    auto frame = new ubyte[Width * Height * 4];
    int autoTicks = 100;
    game.save(statePath);

    for (int tick = 0; tick < seconds * 60; ++tick)
    {
        surface.readPointer(game.paddleX, autoTicks);
        game.step(autoTicks);
        game.draw(frame);
        surface.publish(frame);
        surface.waitHost(surface.sequence);
        if (tick % 5 == 0) game.save(statePath);
        Thread.sleep(16.msecs);
    }
    game.save(statePath);
    surface.close();
}
