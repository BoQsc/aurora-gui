module world.world;

import std.algorithm.comparison : max, min;
import std.math : PI, atan2, cos, exp, fabs, floor, sin, sqrt, tan;

import world.surface : InputEvent;

enum int SurfaceWidth = 960;
enum int SurfaceHeight = 540;
enum int TerrainCells = 96;
enum float TerrainStep = 2.0f;
enum float WorldHalf = TerrainCells * TerrainStep * 0.5f;
enum float WorldSize = TerrainCells * TerrainStep;
enum int HeightSamples = TerrainCells + 1;
enum float WaterLevel = 0.0f;
enum float EyeHeight = 1.68f;

enum uint KeyEscape = 4;
enum uint KeySpace = 5;
enum uint KeyLeft = 10;
enum uint KeyUp = 11;
enum uint KeyRight = 12;
enum uint KeyDown = 13;
enum uint KeyA = 26;
enum uint KeyD = 29;
enum uint KeyR = 43;
enum uint KeyS = 44;
enum uint KeyW = 48;

enum uint InputPointerDown = 1;
enum uint InputPointerMove = 2;
enum uint InputPointerUp = 3;
enum uint InputWheel = 4;
enum uint InputKeyDown = 5;
enum uint InputKeyUp = 6;

enum uint MouseLeft = 1;

private enum Vec3 SunDirection = Vec3(-0.38f, 0.72f, 0.58f).normalized();

struct Vec3
{
    float x;
    float y;
    float z;

    static Vec3 of(float x, float y, float z)
    {
        return Vec3(x, y, z);
    }

    Vec3 plus(Vec3 other) const
    {
        return Vec3(x + other.x, y + other.y, z + other.z);
    }

    Vec3 minus(Vec3 other) const
    {
        return Vec3(x - other.x, y - other.y, z - other.z);
    }

    Vec3 scaled(float factor) const
    {
        return Vec3(x * factor, y * factor, z * factor);
    }

    float dot(Vec3 other) const
    {
        return x * other.x + y * other.y + z * other.z;
    }

    Vec3 cross(Vec3 other) const
    {
        return Vec3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x);
    }

    float lengthSquared() const
    {
        return dot(this);
    }

    float length() const
    {
        return sqrt(lengthSquared());
    }

    Vec3 normalized() const
    {
        const length = this.length();
        return length > 1e-6f ? scaled(1.0f / length) : Vec3(0, 0, 0);
    }
}

private struct Rng
{
    uint state;

    uint next()
    {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return state;
    }

    float unit()
    {
        return cast(float) (next() & 0x00ff_ffff) / cast(float) 0x0100_0000;
    }

    float range(float low, float high)
    {
        return low + (high - low) * unit();
    }
}

struct TerrainQuad
{
    ushort a;
    ushort b;
    ushort c;
    ushort d;
    uint color;
}

struct WaterQuad
{
    ushort a;
    ushort b;
    ushort c;
    ushort d;
    float depth;
}

struct PropTriangle
{
    Vec3 a;
    Vec3 b;
    Vec3 c;
    uint color;
}

struct World
{
    uint seed;
    float[] heights;
    Vec3[] vertices;
    TerrainQuad[] terrain;
    Vec3[] waterVertices;
    WaterQuad[] water;
    PropTriangle[] props;
    Vec3 spawn;
    float spawnYaw;
    Vec3 beacon;
    int treeCount;
    int rockCount;
    bool hasBeacon;

    this(uint seed)
    {
        rebuild(seed);
    }

    void rebuild(uint newSeed)
    {
        seed = newSeed;
        buildHeights();
        chooseSpawn();
        buildTerrain();
        buildWater();
        props.length = 0;
        treeCount = 0;
        rockCount = 0;
        addBeacon();
        addForest();
        addRocks();
    }

    private void buildHeights()
    {
        heights.length = HeightSamples * HeightSamples;
        foreach (j; 0 .. HeightSamples)
        {
            const z = -WorldHalf + j * TerrainStep;
            foreach (i; 0 .. HeightSamples)
            {
                const x = -WorldHalf + i * TerrainStep;
                heights[j * HeightSamples + i] = rawHeight(x, z, seed);
            }
        }
    }

    private void chooseSpawn()
    {
        float bestScore = -1e30f;
        float bestX;
        float bestZ;
        bool found;
        for (float z = -78.0f; z <= 78.0f; z += 2.0f)
        {
            for (float x = -78.0f; x <= 78.0f; x += 2.0f)
            {
                const height = heightAt(x, z);
                if (height < 2.2f || height > 15.0f)
                    continue;
                const normal = normalAt(x, z);
                if (normal.y < 0.84f)
                    continue;
                const distance = sqrt(x * x + z * z);
                if (distance < 7.0f || distance > 62.0f)
                    continue;
                const score = height * 1.4f + normal.y * 8.0f - distance * 0.04f;
                if (score > bestScore)
                {
                    bestScore = score;
                    bestX = x;
                    bestZ = z;
                    found = true;
                }
            }
        }
        if (!found)
        {
            bestX = 8.0f;
            bestZ = 8.0f;
        }
        const height = heightAt(bestX, bestZ);
        spawn = Vec3(bestX, height + 0.05f, bestZ);
        spawnYaw = atan2(-bestX, -bestZ);
    }

    private void buildTerrain()
    {
        vertices.length = HeightSamples * HeightSamples;
        foreach (j; 0 .. HeightSamples)
        {
            const z = -WorldHalf + j * TerrainStep;
            foreach (i; 0 .. HeightSamples)
            {
                const x = -WorldHalf + i * TerrainStep;
                vertices[j * HeightSamples + i] =
                    Vec3(x, heights[j * HeightSamples + i], z);
            }
        }

        terrain.length = TerrainCells * TerrainCells;
        size_t target;
        foreach (j; 0 .. TerrainCells)
        {
            foreach (i; 0 .. TerrainCells)
            {
                const a = cast(ushort) (j * HeightSamples + i);
                const b = cast(ushort) (a + 1);
                const d = cast(ushort) (a + HeightSamples);
                const c = cast(ushort) (d + 1);
                const x = -WorldHalf + (i + 0.5f) * TerrainStep;
                const z = -WorldHalf + (j + 0.5f) * TerrainStep;
                const height = heightAt(x, z);
                const normal = normalAt(x, z);
                TerrainQuad quad;
                quad.a = a;
                quad.b = b;
                quad.c = c;
                quad.d = d;
                quad.color = terrainColor(height, normal, x, z);
                terrain[target++] = quad;
            }
        }
    }

    private void buildWater()
    {
        waterVertices.length = HeightSamples * HeightSamples;
        foreach (j; 0 .. HeightSamples)
        {
            const z = -WorldHalf + j * TerrainStep;
            foreach (i; 0 .. HeightSamples)
            {
                const x = -WorldHalf + i * TerrainStep;
                waterVertices[j * HeightSamples + i] = Vec3(x, WaterLevel, z);
            }
        }

        water.length = 0;
        foreach (j; 0 .. TerrainCells)
        {
            foreach (i; 0 .. TerrainCells)
            {
                const h00 = heights[j * HeightSamples + i];
                const h10 = heights[j * HeightSamples + i + 1];
                const h01 = heights[(j + 1) * HeightSamples + i];
                const h11 = heights[(j + 1) * HeightSamples + i + 1];
                const lowest = min(min(h00, h10), min(h01, h11));
                if (lowest >= WaterLevel - 0.08f)
                    continue;
                const a = cast(ushort) (j * HeightSamples + i);
                const b = cast(ushort) (a + 1);
                const d = cast(ushort) (a + HeightSamples);
                const c = cast(ushort) (d + 1);
                WaterQuad quad;
                quad.a = a;
                quad.b = b;
                quad.c = c;
                quad.d = d;
                quad.depth = WaterLevel - lowest;
                water ~= quad;
            }
        }
    }

    private void addBeacon()
    {
        hasBeacon = false;
        float best = -1e30f;
        for (float z = -72.0f; z <= 72.0f; z += 4.0f)
        {
            for (float x = -72.0f; x <= 72.0f; x += 4.0f)
            {
                const dx = x - spawn.x;
                const dz = z - spawn.z;
                const distance = sqrt(dx * dx + dz * dz);
                if (distance < 22.0f || distance > 52.0f)
                    continue;
                const height = heightAt(x, z);
                if (height < 3.0f)
                    continue;
                const normal = normalAt(x, z);
                if (normal.y < 0.78f)
                    continue;
                const score = height + normal.y * 7.0f - distance * 0.02f;
                if (score > best)
                {
                    best = score;
                    beacon = Vec3(x, height, z);
                    hasBeacon = true;
                }
            }
        }
        if (!hasBeacon)
            return;

        const stone = Vec3(0.39f, 0.40f, 0.43f);
        addBox(beacon.x, beacon.y, beacon.z, 1.5f, 0.7f, 1.5f, stone);
        addBox(beacon.x, beacon.y + 0.7f, beacon.z, 1.05f, 1.8f, 1.05f,
            Vec3(0.44f, 0.45f, 0.47f));
        addBox(beacon.x, beacon.y + 2.5f, beacon.z, 0.55f, 0.8f, 0.55f,
            Vec3(0.30f, 0.32f, 0.35f));
        addOctahedron(beacon.x, beacon.y + 4.0f, beacon.z, 0.55f, 0.78f,
            Vec3(0.20f, 0.86f, 1.0f), 0x51f15e);
    }

    private void addForest()
    {
        Rng rng;
        rng.state = seed ^ 0x9e37_79b9;
        int attempts = 0;
        while (attempts < 900 && treeCount < 92)
        {
            ++attempts;
            const x = rng.range(-82.0f, 82.0f);
            const z = rng.range(-82.0f, 82.0f);
            const height = heightAt(x, z);
            if (height < 0.55f)
                continue;
            const normal = normalAt(x, z);
            if (normal.y < 0.48f)
                continue;
            const dx = x - spawn.x;
            const dz = z - spawn.z;
            if (sqrt(dx * dx + dz * dz) < 5.0f)
                continue;
            if (hasBeacon && sqrt((x - beacon.x) * (x - beacon.x) +
                (z - beacon.z) * (z - beacon.z)) < 6.5f)
                continue;

            const scale = rng.range(0.72f, 1.45f);
            const tint = rng.range(-0.06f, 0.07f);
            const trunk = Vec3(0.28f + tint, 0.20f, 0.12f);
            const leaf = Vec3(0.10f + tint * 0.4f, 0.31f + tint, 0.15f);
            addBox(x, height, z, 0.15f * scale, 1.35f * scale, 0.15f * scale,
                trunk);
            addCone(x, z, height + 1.05f * scale, 1.32f * scale,
                1.45f * scale, 5, leaf, rng.next());
            addCone(x, z, height + 1.95f * scale, 1.02f * scale,
                1.35f * scale, 5, Vec3(0.13f + tint, 0.36f + tint, 0.17f),
                rng.next());
            addCone(x, z, height + 2.75f * scale, 0.72f * scale,
                1.15f * scale, 5, Vec3(0.17f + tint, 0.42f + tint, 0.20f),
                rng.next());
            ++treeCount;
        }
    }

    private void addRocks()
    {
        Rng rng;
        rng.state = seed ^ 0x85eb_ca6b;
        int attempts = 0;
        while (attempts < 300 && rockCount < 38)
        {
            ++attempts;
            const x = rng.range(-84.0f, 84.0f);
            const z = rng.range(-84.0f, 84.0f);
            const height = heightAt(x, z);
            if (height < WaterLevel + 0.05f)
                continue;
            const dx = x - spawn.x;
            const dz = z - spawn.z;
            if (sqrt(dx * dx + dz * dz) < 3.5f)
                continue;
            const scale = rng.range(0.45f, 1.5f);
            const tint = rng.range(-0.05f, 0.06f);
            addOctahedron(x, height + 0.15f * scale, z, scale * 0.9f,
                scale * 0.65f, Vec3(0.37f + tint, 0.38f + tint, 0.40f + tint),
                rng.next());
            ++rockCount;
        }
    }

    private void addBox(float cx, float cy, float cz, float halfX, float height,
        float halfZ, Vec3 color)
    {
        const x0 = cx - halfX;
        const x1 = cx + halfX;
        const z0 = cz - halfZ;
        const z1 = cz + halfZ;
        const y0 = cy;
        const y1 = cy + height;
        const b0 = Vec3(x0, y0, z0);
        const b1 = Vec3(x1, y0, z0);
        const b2 = Vec3(x1, y0, z1);
        const b3 = Vec3(x0, y0, z1);
        const t0 = Vec3(x0, y1, z0);
        const t1 = Vec3(x1, y1, z0);
        const t2 = Vec3(x1, y1, z1);
        const t3 = Vec3(x0, y1, z1);
        addShadedQuad(t0, t1, t2, t3, color);
        addShadedQuad(b1, b2, t2, t1, color);
        addShadedQuad(b2, b3, t3, t2, color);
        addShadedQuad(b3, b0, t0, t3, color);
        addShadedQuad(b0, b1, t1, t0, color);
        addShadedQuad(b0, b3, b2, b1, color);
    }

    private void addCone(float cx, float cz, float baseY, float radius,
        float height, int sides, Vec3 color, uint salt)
    {
        const apex = Vec3(cx, baseY + height, cz);
        Vec3[] ring;
        ring.length = sides;
        foreach (index; 0 .. sides)
        {
            const angle = cast(float) (2.0 * PI * index / sides) +
                cast(float) (salt & 0xff) * 0.0001f;
            ring[index] = Vec3(cx + cos(angle) * radius, baseY,
                cz + sin(angle) * radius);
        }
        foreach (index; 0 .. sides)
        {
            const next = (index + 1) % sides;
            addShadedTriangle(ring[index], ring[next], apex, color);
            addShadedTriangle(ring[next], ring[index],
                Vec3(cx, baseY, cz), color.scaled(0.72f));
        }
    }

    private void addOctahedron(float cx, float cy, float cz, float radius,
        float height, Vec3 color, uint salt)
    {
        const top = Vec3(cx, cy + height, cz);
        const bottom = Vec3(cx, cy - height * 0.8f, cz);
        Vec3[] ring;
        ring.length = 4;
        foreach (index; 0 .. 4)
        {
            const angle = cast(float) (0.5 * PI * index) +
                cast(float) (salt & 0xff) * 0.001f;
            ring[index] = Vec3(cx + cos(angle) * radius, cy,
                cz + sin(angle) * radius);
        }
        foreach (index; 0 .. 4)
        {
            const next = (index + 1) % 4;
            addShadedTriangle(top, ring[index], ring[next], color);
            addShadedTriangle(bottom, ring[next], ring[index],
                color.scaled(0.65f));
        }
    }

    private void addShadedQuad(Vec3 a, Vec3 b, Vec3 c, Vec3 d, Vec3 base)
    {
        addShadedTriangle(a, b, c, base);
        addShadedTriangle(a, c, d, base);
    }

    private void addShadedTriangle(Vec3 a, Vec3 b, Vec3 c, Vec3 base)
    {
        const normal = b.minus(a).cross(c.minus(a)).normalized();
        const light = 0.34f + 0.66f * max(0.0f, normal.dot(SunDirection));
        const color = Vec3(base.x * light * 1.04f, base.y * light,
            base.z * light * 0.94f);
        PropTriangle triangle;
        triangle.a = a;
        triangle.b = b;
        triangle.c = c;
        triangle.color = pack(color.x, color.y, color.z);
        props ~= triangle;
    }

    private uint terrainColor(float height, Vec3 normal, float x, float z) const
    {
        const variation = valueNoise(x * 0.24f, z * 0.24f, seed ^ 0xa511_e9b3);
        const fine = valueNoise(x * 0.8f + 19.0f, z * 0.8f - 4.0f,
            seed ^ 0x63d8_3595);
        Vec3 base;
        if (height < 0.9f)
        {
            const t = max(0.0f, min(1.0f, height + 0.4f));
            base = Vec3(0.46f + t * 0.08f, 0.39f + t * 0.05f, 0.26f);
        }
        else
        {
            const t = max(0.0f, min(1.0f, (height - 2.0f) / 15.0f));
            base = Vec3(
                0.18f + 0.07f * variation + 0.06f * t,
                0.36f + 0.11f * variation + 0.03f * t,
                0.15f + 0.05f * variation);
        }
        const slope = 1.0f - normal.y;
        const rock = max(0.0f, min(1.0f, (slope - 0.16f) * 3.4f));
        base = Vec3(
            base.x + (0.40f - base.x) * rock,
            base.y + (0.40f - base.y) * rock,
            base.z + (0.43f - base.z) * rock);
        const snow = max(0.0f, min(1.0f, (height - 11.5f) / 3.5f));
        base = Vec3(
            base.x + (0.91f - base.x) * snow,
            base.y + (0.94f - base.y) * snow,
            base.z + (0.98f - base.z) * snow);
        const tint = 0.94f + fine * 0.12f;
        const light = 0.38f + 0.62f * max(0.0f, normal.dot(SunDirection));
        return pack(base.x * light * tint * 1.04f,
            base.y * light * tint, base.z * light * tint * 0.96f);
    }

    float heightAtSample(int i, int j) const
    {
        const ci = max(0, min(HeightSamples - 1, i));
        const cj = max(0, min(HeightSamples - 1, j));
        return heights[cj * HeightSamples + ci];
    }

    float heightAt(float x, float z) const
    {
        const clampedX = max(-WorldHalf, min(WorldHalf, x));
        const clampedZ = max(-WorldHalf, min(WorldHalf, z));
        const fx = (clampedX + WorldHalf) / TerrainStep;
        const fz = (clampedZ + WorldHalf) / TerrainStep;
        const ix = min(HeightSamples - 2, max(0, cast(int) floor(fx)));
        const iz = min(HeightSamples - 2, max(0, cast(int) floor(fz)));
        const tx = fx - ix;
        const tz = fz - iz;
        const h00 = heights[iz * HeightSamples + ix];
        const h10 = heights[iz * HeightSamples + ix + 1];
        const h01 = heights[(iz + 1) * HeightSamples + ix];
        const h11 = heights[(iz + 1) * HeightSamples + ix + 1];
        const top = h00 + (h10 - h00) * tx;
        const bottom = h01 + (h11 - h01) * tx;
        return top + (bottom - top) * tz;
    }

    Vec3 normalAt(float x, float z) const
    {
        const epsilon = 0.7f;
        const dx = (heightAt(x + epsilon, z) - heightAt(x - epsilon, z)) /
            (2.0f * epsilon);
        const dz = (heightAt(x, z + epsilon) - heightAt(x, z - epsilon)) /
            (2.0f * epsilon);
        return Vec3(-dx, 1.0f, -dz).normalized();
    }

    float slopeAt(float x, float z) const
    {
        return 1.0f - normalAt(x, z).y;
    }
}

private float lerp(float a, float b, float t)
{
    return a + (b - a) * t;
}

private float clamp01(float value)
{
    return max(0.0f, min(1.0f, value));
}

private uint pack(float r, float g, float b)
{
    const red = cast(uint) (clamp01(r) * 255.0f + 0.5f);
    const green = cast(uint) (clamp01(g) * 255.0f + 0.5f);
    const blue = cast(uint) (clamp01(b) * 255.0f + 0.5f);
    return 0xff00_0000u | (blue << 16) | (green << 8) | red;
}

private float hash2(int x, int y, uint seed)
{
    uint value = seed ^ cast(uint) x * 0x1f12_3bb5u ^
        cast(uint) y * 0x6c8e_9cf5u;
    value ^= value >> 15;
    value *= 0x2c1b_3c6du;
    value ^= value >> 12;
    value *= 0x297a_2d39u;
    value ^= value >> 15;
    return cast(float) (value & 0x00ff_ffff) / cast(float) 0x0100_0000;
}

private float valueNoise(float x, float y, uint seed)
{
    const ix = cast(int) floor(x);
    const iy = cast(int) floor(y);
    const fx = x - ix;
    const fy = y - iy;
    const u = fx * fx * (3.0f - 2.0f * fx);
    const v = fy * fy * (3.0f - 2.0f * fy);
    const a = hash2(ix, iy, seed);
    const b = hash2(ix + 1, iy, seed);
    const c = hash2(ix, iy + 1, seed);
    const d = hash2(ix + 1, iy + 1, seed);
    return lerp(lerp(a, b, u), lerp(c, d, u), v);
}

private float fbm(float x, float y, uint seed)
{
    float total = 0.0f;
    float amplitude = 0.5f;
    float frequency = 1.0f;
    foreach (octave; 0 .. 5)
    {
        total += amplitude * valueNoise(
            x * frequency + octave * 17.3f,
            y * frequency - octave * 11.7f,
            seed + octave * 101u);
        frequency *= 2.03f;
        amplitude *= 0.5f;
    }
    return total;
}

private float rawHeight(float x, float z, uint seed)
{
    const broad = fbm(x * 0.020f + 3.1f, z * 0.020f - 5.7f, seed);
    const detail = fbm(x * 0.082f - 9.2f, z * 0.082f + 4.4f,
        seed ^ 0x9e37_79b9);
    float height = (broad - 0.40f) * 26.0f + (detail - 0.5f) * 2.2f;
    height += 2.8f * sin((x + z * 0.33f) * 0.052f) *
        cos(z * 0.036f);

    const edge = max(fabs(x), fabs(z));
    if (edge > 70.0f)
    {
        const rise = edge - 70.0f;
        height += rise * rise * 0.075f;
    }
    return height;
}

struct InputState
{
    bool[64] down;
    bool dragging;
    int lastX;
    int lastY;
    float lookDX = 0.0f;
    float lookDY = 0.0f;
    int wheel;
    bool jump;
    bool reset;
    bool close;
    bool sprint;

    void beginFrame()
    {
        lookDX = 0.0f;
        lookDY = 0.0f;
        wheel = 0;
        jump = false;
        reset = false;
        close = false;
    }

    bool isDown(uint key) const
    {
        return key < down.length && down[key];
    }
}

void handleInput(ref InputState input, const InputEvent event)
{
    input.sprint = (event.modifiers & 1u) != 0;
    switch (event.kind)
    {
        case InputPointerDown:
            if (event.button == MouseLeft)
            {
                input.dragging = true;
                input.lastX = event.x;
                input.lastY = event.y;
            }
            break;
        case InputPointerMove:
            if (input.dragging)
            {
                const dx = event.x - input.lastX;
                const dy = event.y - input.lastY;
                if (fabs(cast(float) dx) < 220.0f &&
                    fabs(cast(float) dy) < 220.0f)
                {
                    input.lookDX += dx;
                    input.lookDY += dy;
                }
                input.lastX = event.x;
                input.lastY = event.y;
            }
            break;
        case InputPointerUp:
            if (event.button == MouseLeft)
                input.dragging = false;
            break;
        case InputWheel:
            input.wheel += event.wheelY;
            break;
        case InputKeyDown:
            if (event.key < input.down.length)
            {
                if (!input.down[event.key])
                {
                    if (event.key == KeySpace)
                        input.jump = true;
                    else if (event.key == KeyR)
                        input.reset = true;
                    else if (event.key == KeyEscape)
                        input.close = true;
                }
                input.down[event.key] = true;
            }
            break;
        case InputKeyUp:
            if (event.key < input.down.length)
                input.down[event.key] = false;
            break;
        default:
            break;
    }
}

struct Player
{
    Vec3 feet;
    Vec3 velocity;
    float yaw;
    float pitch;
    float fov;
    float fovTarget;
    float bobPhase;
    float bob;
    bool grounded;
    bool inWater;
    bool sprint;

    void spawn(const World* world)
    {
        feet = world.spawn;
        velocity = Vec3(0, 0, 0);
        yaw = world.spawnYaw;
        pitch = -0.07f;
        fov = 72.0f;
        fovTarget = 72.0f;
        bobPhase = 0.0f;
        bob = 0.0f;
        grounded = true;
        inWater = false;
        sprint = false;
    }

    Vec3 cameraPosition() const
    {
        return Vec3(feet.x, feet.y + EyeHeight + bob, feet.z);
    }

    void update(ref InputState input, float dt, const World* world)
    {
        sprint = input.sprint;
        const lookSpeed = input.sprint ? 2.35f : 1.85f;
        if (input.isDown(KeyLeft))
            yaw -= lookSpeed * dt;
        if (input.isDown(KeyRight))
            yaw += lookSpeed * dt;
        if (input.isDown(KeyUp))
            pitch += lookSpeed * 0.72f * dt;
        if (input.isDown(KeyDown))
            pitch -= lookSpeed * 0.72f * dt;
        yaw += input.lookDX * 0.0025f;
        pitch -= input.lookDY * 0.0025f;
        pitch = max(-1.42f, min(1.42f, pitch));

        fovTarget = max(50.0f, min(100.0f,
            fovTarget + input.wheel * 0.035f));
        fov += (fovTarget - fov) * min(1.0f, dt * 8.0f);

        const forwardInput = (input.isDown(KeyW) ? 1.0f : 0.0f) -
            (input.isDown(KeyS) ? 1.0f : 0.0f);
        const rightInput = (input.isDown(KeyD) ? 1.0f : 0.0f) -
            (input.isDown(KeyA) ? 1.0f : 0.0f);
        const forward = Vec3(sin(yaw), 0.0f, cos(yaw));
        const right = Vec3(cos(yaw), 0.0f, -sin(yaw));
        Vec3 wish = forward.scaled(forwardInput).plus(right.scaled(rightInput));
        if (wish.lengthSquared() > 1e-6f)
            wish = wish.normalized();

        float speed = input.sprint ? 10.2f : 5.3f;
        if (inWater)
            speed *= 0.58f;
        const desired = wish.scaled(speed);
        Vec3 horizontal = Vec3(velocity.x, 0.0f, velocity.z);
        const acceleration = grounded ? 34.0f : 10.0f;
        horizontal = moveToward(horizontal, desired, acceleration * dt);

        if (input.jump && grounded && !inWater)
        {
            velocity.y = 7.8f;
            grounded = false;
        }
        velocity.y -= 23.0f * dt;
        if (velocity.y < -46.0f)
            velocity.y = -46.0f;

        const limit = WorldHalf - 2.0f;
        float nextX = max(-limit, min(limit, feet.x + horizontal.x * dt));
        float nextZ = max(-limit, min(limit, feet.z + horizontal.z * dt));
        const ahead = max(world.heightAt(nextX, nextZ), WaterLevel);
        if (ahead > feet.y + 0.95f)
        {
            const aheadX = max(-limit, min(limit, feet.x + horizontal.x * dt));
            const aheadZ = max(-limit, min(limit, feet.z + horizontal.z * dt));
            if (max(world.heightAt(aheadX, feet.z), WaterLevel) <= feet.y + 0.95f)
            {
                nextX = aheadX;
                nextZ = feet.z;
                horizontal.z = 0.0f;
            }
            else if (max(world.heightAt(feet.x, aheadZ), WaterLevel) <=
                feet.y + 0.95f)
            {
                nextX = feet.x;
                nextZ = aheadZ;
                horizontal.x = 0.0f;
            }
            else
            {
                nextX = feet.x;
                nextZ = feet.z;
                horizontal.x = 0.0f;
                horizontal.z = 0.0f;
            }
        }
        feet.x = nextX;
        feet.z = nextZ;
        velocity.x = horizontal.x;
        velocity.z = horizontal.z;

        feet.y += velocity.y * dt;
        const terrain = world.heightAt(feet.x, feet.z);
        inWater = terrain < WaterLevel - 0.22f;
        const floorY = max(terrain, WaterLevel);
        if (feet.y <= floorY)
        {
            feet.y = floorY;
            if (velocity.y < 0.0f)
                velocity.y = 0.0f;
            grounded = true;
        }
        else
        {
            grounded = false;
        }
        if (inWater && feet.y < WaterLevel)
        {
            feet.y = WaterLevel;
            velocity.y = 0.0f;
            grounded = true;
        }

        const horizontalSpeed = Vec3(velocity.x, 0.0f, velocity.z).length();
        float targetBob;
        if (grounded && horizontalSpeed > 0.35f)
        {
            bobPhase += dt * (4.8f + horizontalSpeed * 0.62f);
            targetBob = sin(bobPhase) * 0.052f;
        }
        else
        {
            bobPhase += dt * 1.7f;
            targetBob = 0.0f;
        }
        bob += (targetBob - bob) * min(1.0f, dt * 9.0f);
    }
}

private Vec3 moveToward(Vec3 current, Vec3 target, float maxDelta)
{
    const delta = target.minus(current);
    const distance = delta.length();
    if (distance <= maxDelta || distance < 1e-6f)
        return target;
    return current.plus(delta.scaled(maxDelta / distance));
}
