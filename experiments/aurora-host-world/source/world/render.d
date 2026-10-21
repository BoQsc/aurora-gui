module world.render;

import std.algorithm.comparison : max, min;
import std.format : format;
import std.math : PI, atan2, cos, exp, fabs, floor, pow, sin, sqrt, tan;

import world.world;

private enum float NearPlane = 0.16f;
private enum float FogStart = 38.0f;
private enum float FogEnd = 120.0f;
private enum Vec3 SunDir = Vec3(-0.38f, 0.72f, 0.58f);

private struct ScreenVertex
{
    float x;
    float y;
    float invZ;
}

private struct Camera
{
    Vec3 position;
    Vec3 forward;
    Vec3 right;
    Vec3 up;
    float focal;
    float pitch;
}

struct Renderer
{
    int width;
    int height;
    uint[] pixels;
    float[] depth;

    private Vec3[] viewScratch;
    private float[] screenXScratch;
    private float[] screenYScratch;
    private float[] invZScratch;

    private uint fogColor;
    private int centerX;
    private int centerY;
    private float projectionFocal;

    this(int width, int height)
    {
        resize(width, height);
    }

    void resize(int newWidth, int newHeight)
    {
        width = newWidth;
        height = newHeight;
        pixels.length = cast(size_t) width * height;
        depth.length = pixels.length;
        centerX = width / 2;
        centerY = height / 2;
    }

    void render(const World* world, const Player* player, float time, float fps)
    {
        foreach (ref value; depth)
            value = 0.0f;

        Camera camera;
        camera.position = player.cameraPosition();
        camera.pitch = player.pitch;
        const cp = cos(player.pitch);
        camera.forward = Vec3(sin(player.yaw) * cp, sin(player.pitch),
            cos(player.yaw) * cp);
        camera.right = Vec3(cos(player.yaw), 0.0f, -sin(player.yaw));
        camera.up = camera.forward.cross(camera.right);
        const fovRadians = player.fov * PI / 180.0f;
        camera.focal = (height * 0.5f) / tan(fovRadians * 0.5f);
        projectionFocal = camera.focal;
        fogColor = skyColor(0.03f);

        drawSky(camera);
        drawTerrain(world, camera);
        drawWater(world, camera, time);
        drawProps(world, camera);
        drawHud(world, player, fps);
    }

    private uint skyColor(float elevation) const
    {
        const horizon = Vec3(0.66f, 0.78f, 0.89f);
        const zenith = Vec3(0.12f, 0.30f, 0.62f);
        const below = Vec3(0.25f, 0.35f, 0.40f);
        Vec3 color;
        if (elevation >= 0.0f)
        {
            const t = min(1.0f, elevation / 1.46f);
            color = mix(horizon, zenith, pow(t, 0.62f));
        }
        else
        {
            const t = min(1.0f, -elevation / 1.0f);
            color = mix(horizon, below, pow(t, 0.55f));
        }
        return packColor(color.x, color.y, color.z);
    }

    private void drawSky(const ref Camera camera)
    {
        foreach (y; 0 .. height)
        {
            const elevation = atan2(cast(float) (centerY - y), camera.focal) +
                camera.pitch;
            const color = skyColor(elevation);
            const start = cast(size_t) y * width;
            foreach (x; 0 .. width)
                pixels[start + x] = color;
        }

        const sunView = Vec3(SunDir.dot(camera.right),
            SunDir.dot(camera.up), SunDir.dot(camera.forward));
        if (sunView.z <= 0.05f)
            return;
        const sunX = centerX + sunView.x / sunView.z * camera.focal;
        const sunY = centerY - sunView.y / sunView.z * camera.focal;
        const radius = cast(int) (width * 0.19f);
        const radiusSquared = radius * radius;
        const minX = max(0, cast(int) sunX - radius);
        const maxX = min(width - 1, cast(int) sunX + radius);
        const minY = max(0, cast(int) sunY - radius);
        const maxY = min(height - 1, cast(int) sunY + radius);

        foreach (y; minY .. maxY + 1)
        {
            const dy = y - sunY;
            foreach (x; minX .. maxX + 1)
            {
                const dx = x - sunX;
                const distanceSquared = dx * dx + dy * dy;
                if (distanceSquared > radiusSquared)
                    continue;
                const distance = sqrt(distanceSquared);
                const glow = exp(-(distanceSquared) / (2.0f * 42.0f * 42.0f));
                const disc = distance < 17.0f ? 1.0f : 0.0f;
                const strength = glow * 0.75f + disc * 0.85f;
                if (strength <= 0.004f)
                    continue;
                const index = cast(size_t) y * width + x;
                addPixel(index, 1.0f, 0.93f, 0.70f, strength);
            }
        }
    }

    private void drawTerrain(const World* world, const ref Camera camera)
    {
        prepare(world.vertices, camera);
        foreach (quad; world.terrain)
        {
            const a = world.vertices[quad.a];
            const b = world.vertices[quad.b];
            const c = world.vertices[quad.c];
            const d = world.vertices[quad.d];
            const center = a.plus(b).plus(c).plus(d).scaled(0.25f);
            const offset = center.minus(camera.position);
            if (offset.lengthSquared() > FogEnd * FogEnd)
                continue;
            if (offset.dot(camera.forward) < -3.0f)
                continue;
            if (viewScratch[quad.a].z <= NearPlane &&
                viewScratch[quad.b].z <= NearPlane &&
                viewScratch[quad.c].z <= NearPlane &&
                viewScratch[quad.d].z <= NearPlane)
                continue;
            drawIndexed(quad.a, quad.d, quad.b, quad.color);
            drawIndexed(quad.b, quad.d, quad.c, quad.color);
        }
    }

    private void drawWater(const World* world, const ref Camera camera,
        float time)
    {
        prepare(world.waterVertices, camera);
        foreach (quad; world.water)
        {
            const a = world.waterVertices[quad.a];
            const b = world.waterVertices[quad.b];
            const c = world.waterVertices[quad.c];
            const d = world.waterVertices[quad.d];
            const center = a.plus(b).plus(c).plus(d).scaled(0.25f);
            const offset = center.minus(camera.position);
            if (offset.lengthSquared() > FogEnd * FogEnd)
                continue;
            if (offset.dot(camera.forward) < -3.0f)
                continue;
            if (viewScratch[quad.a].z <= NearPlane &&
                viewScratch[quad.b].z <= NearPlane &&
                viewScratch[quad.c].z <= NearPlane &&
                viewScratch[quad.d].z <= NearPlane)
                continue;
            const color = waterColor(center, quad.depth, camera, time);
            drawIndexed(quad.a, quad.d, quad.b, color);
            drawIndexed(quad.b, quad.d, quad.c, color);
        }
    }

    private void drawProps(const World* world, const ref Camera camera)
    {
        foreach (triangle; world.props)
        {
            const center = triangle.a.plus(triangle.b).plus(triangle.c)
                .scaled(1.0f / 3.0f);
            const offset = center.minus(camera.position);
            if (offset.lengthSquared() > FogEnd * FogEnd)
                continue;
            if (offset.dot(camera.forward) < -3.0f)
                continue;
            const a = viewPoint(triangle.a, camera);
            const b = viewPoint(triangle.b, camera);
            const c = viewPoint(triangle.c, camera);
            drawViewTriangle(a, b, c, triangle.color);
        }
    }

    private void prepare(const Vec3[] vertices, const ref Camera camera)
    {
        if (viewScratch.length != vertices.length)
        {
            viewScratch.length = vertices.length;
            screenXScratch.length = vertices.length;
            screenYScratch.length = vertices.length;
            invZScratch.length = vertices.length;
        }
        foreach (index, vertex; vertices)
        {
            const view = viewPoint(vertex, camera);
            viewScratch[index] = view;
            if (view.z > NearPlane)
            {
                const invZ = 1.0f / view.z;
                screenXScratch[index] = centerX + view.x * camera.focal * invZ;
                screenYScratch[index] = centerY - view.y * camera.focal * invZ;
                invZScratch[index] = invZ;
            }
            else
            {
                screenXScratch[index] = 0.0f;
                screenYScratch[index] = 0.0f;
                invZScratch[index] = 0.0f;
            }
        }
    }

    private Vec3 viewPoint(Vec3 point, const ref Camera camera) const
    {
        const relative = point.minus(camera.position);
        return Vec3(relative.dot(camera.right), relative.dot(camera.up),
            relative.dot(camera.forward));
    }

    private void drawIndexed(ushort a, ushort b, ushort c, uint color)
    {
        if (viewScratch[a].z <= NearPlane || viewScratch[b].z <= NearPlane ||
            viewScratch[c].z <= NearPlane)
        {
            drawViewTriangle(viewScratch[a], viewScratch[b], viewScratch[c],
                color);
            return;
        }
        ScreenVertex sa;
        sa.x = screenXScratch[a];
        sa.y = screenYScratch[a];
        sa.invZ = invZScratch[a];
        ScreenVertex sb;
        sb.x = screenXScratch[b];
        sb.y = screenYScratch[b];
        sb.invZ = invZScratch[b];
        ScreenVertex sc;
        sc.x = screenXScratch[c];
        sc.y = screenYScratch[c];
        sc.invZ = invZScratch[c];
        raster(sa, sb, sc, color);
    }

    private void drawViewTriangle(Vec3 a, Vec3 b, Vec3 c, uint color)
    {
        Vec3[8] polygon;
        int count;
        Vec3[3] triangle = [a, b, c];
        foreach (index; 0 .. 3)
        {
            const p = triangle[index];
            const q = triangle[(index + 1) % 3];
            const pInside = p.z >= NearPlane;
            const qInside = q.z >= NearPlane;
            if (pInside && count < polygon.length)
                polygon[count++] = p;
            if (pInside != qInside && count < polygon.length)
            {
                const t = (NearPlane - p.z) / (q.z - p.z);
                polygon[count++] = p.plus(q.minus(p).scaled(t));
            }
        }
        if (count < 3)
            return;
        foreach (index; 1 .. count - 1)
            projectAndRaster(polygon[0], polygon[index], polygon[index + 1],
                color);
    }

    private void projectAndRaster(Vec3 a, Vec3 b, Vec3 c, uint color)
    {
        ScreenVertex sa;
        sa.invZ = 1.0f / a.z;
        sa.x = centerX + a.x * projectionFocal * sa.invZ;
        sa.y = centerY - a.y * projectionFocal * sa.invZ;
        ScreenVertex sb;
        sb.invZ = 1.0f / b.z;
        sb.x = centerX + b.x * projectionFocal * sb.invZ;
        sb.y = centerY - b.y * projectionFocal * sb.invZ;
        ScreenVertex sc;
        sc.invZ = 1.0f / c.z;
        sc.x = centerX + c.x * projectionFocal * sc.invZ;
        sc.y = centerY - c.y * projectionFocal * sc.invZ;
        raster(sa, sb, sc, color);
    }

    private void raster(ScreenVertex a, ScreenVertex b, ScreenVertex c,
        uint color)
    {
        float denominator = (b.y - c.y) * (a.x - c.x) +
            (c.x - b.x) * (a.y - c.y);
        if (fabs(denominator) < 1e-6f)
            return;
        if (denominator < 0.0f)
        {
            const swap = b;
            b = c;
            c = swap;
            denominator = -denominator;
        }

        const minX = max(0, cast(int) floor(min(a.x, min(b.x, c.x))));
        const maxX = min(width - 1,
            cast(int) floor(max(a.x, max(b.x, c.x)) + 1.0f));
        const minY = max(0, cast(int) floor(min(a.y, min(b.y, c.y))));
        const maxY = min(height - 1,
            cast(int) floor(max(a.y, max(b.y, c.y)) + 1.0f));
        if (minX > maxX || minY > maxY)
            return;

        const inverse = 1.0f / denominator;
        const red = cast(int) (color & 0xff);
        const green = cast(int) ((color >> 8) & 0xff);
        const blue = cast(int) ((color >> 16) & 0xff);
        const fogRed = cast(int) (fogColor & 0xff);
        const fogGreen = cast(int) ((fogColor >> 8) & 0xff);
        const fogBlue = cast(int) ((fogColor >> 16) & 0xff);
        const inverseFogRange = 1.0f / (FogEnd - FogStart);

        foreach (py; minY .. maxY + 1)
        {
            const sampleY = py + 0.5f;
            foreach (px; minX .. maxX + 1)
            {
                const sampleX = px + 0.5f;
                const w0 = ((b.y - c.y) * (sampleX - c.x) +
                    (c.x - b.x) * (sampleY - c.y)) * inverse;
                const w1 = ((c.y - a.y) * (sampleX - c.x) +
                    (a.x - c.x) * (sampleY - c.y)) * inverse;
                const w2 = 1.0f - w0 - w1;
                if (w0 < -1e-5f || w1 < -1e-5f || w2 < -1e-5f)
                    continue;
                const invZ = w0 * a.invZ + w1 * b.invZ + w2 * c.invZ;
                const index = cast(size_t) py * width + px;
                if (invZ <= depth[index])
                    continue;
                depth[index] = invZ;

                const z = 1.0f / invZ;
                float fog = (z - FogStart) * inverseFogRange;
                if (fog <= 0.0f)
                {
                    pixels[index] = 0xff00_0000u | (blue << 16) |
                        (green << 8) | red;
                }
                else
                {
                    fog = min(0.93f, fog);
                    const mixedRed = red + cast(int) ((fogRed - red) * fog);
                    const mixedGreen = green +
                        cast(int) ((fogGreen - green) * fog);
                    const mixedBlue = blue +
                        cast(int) ((fogBlue - blue) * fog);
                    pixels[index] = 0xff00_0000u | (mixedBlue << 16) |
                        (mixedGreen << 8) | mixedRed;
                }
            }
        }
    }

    private uint waterColor(Vec3 center, float depth, const ref Camera camera,
        float time)
    {
        const wave = 0.5f + 0.5f * sin(center.x * 0.35f +
            center.z * 0.23f + time * 1.85f);
        const wave2 = 0.5f + 0.5f * sin(center.x * 0.11f -
            center.z * 0.29f - time * 1.15f);
        const deep = min(1.0f, depth / 6.0f);
        const shallow = Vec3(0.10f + wave * 0.03f, 0.34f + wave2 * 0.05f,
            0.36f + wave * 0.04f);
        const abyss = Vec3(0.025f, 0.16f + wave2 * 0.02f, 0.33f);
        const base = mix(shallow, abyss, deep);
        const toCamera = camera.position.minus(center).normalized();
        const half = SunDir.plus(toCamera).normalized();
        const specular = pow(max(0.0f, half.y), 70.0f) * 0.55f;
        return packColor(base.x + specular, base.y + specular * 0.95f,
            base.z + specular * 0.75f);
    }

    private void drawHud(const World* world, const Player* player, float fps)
    {
        const panel = packColor(0.025f, 0.05f, 0.075f);
        const title = packColor(0.82f, 0.96f, 1.0f);
        const subtitle = packColor(0.56f, 0.72f, 0.81f);
        const body = packColor(0.78f, 0.86f, 0.91f);
        const accent = packColor(0.35f, 0.88f, 1.0f);

        blendRect(0, 0, width, 58, panel, 0.72f);
        drawText(18, 11, 2, "AURORA HOST WORLD", title);
        drawText(19, 37, 1, "SOFTWARE TERRAIN + SHARED SURFACE PLAYER CONTROLLER",
            subtitle);

        const info = format("SEED %d   X %.1f   Z %.1f   ALT %.1f   FPS %.0f",
            world.seed, player.feet.x, player.feet.z, player.feet.y, fps);
        const state = player.inWater ? "WATER" : (!player.grounded ? "AIR" :
            (player.sprint ? "SPRINT" : "GROUND"));
        const mode = format("MODE %s   FOV %.0f   TREES %d   ROCKS %d", state,
            player.fov, world.treeCount, world.rockCount);

        blendRect(0, height - 62, width, 62, panel, 0.70f);
        drawText(18, height - 51, 1,
            "WASD MOVE   DRAG MOUSE LOOK   SPACE JUMP   SHIFT SPRINT", body);
        drawText(18, height - 33, 1,
            "WHEEL ZOOM   R NEW WORLD   ESC EXIT", body);
        drawText(width - 388, height - 51, 1, info, accent);
        drawText(width - 388, height - 33, 1, mode, subtitle);

        const crossColor = packColor(0.9f, 0.98f, 1.0f);
        blendRect(centerX - 12, centerY, 24, 1, crossColor, 0.72f);
        blendRect(centerX, centerY - 12, 1, 24, crossColor, 0.72f);
    }


    private void blendRect(int x, int y, int w, int h, uint color, float alpha)
    {
        const minX = max(0, x);
        const minY = max(0, y);
        const maxX = min(width, x + w);
        const maxY = min(height, y + h);
        const red = cast(float) (color & 0xff);
        const green = cast(float) ((color >> 8) & 0xff);
        const blue = cast(float) ((color >> 16) & 0xff);
        foreach (py; minY .. maxY)
        {
            const start = cast(size_t) py * width;
            foreach (px; minX .. maxX)
            {
                const index = start + px;
                const target = pixels[index];
                const r = cast(int) ((target & 0xff) * (1.0f - alpha) +
                    red * alpha);
                const g = cast(int) (((target >> 8) & 0xff) * (1.0f - alpha) +
                    green * alpha);
                const b = cast(int) (((target >> 16) & 0xff) * (1.0f - alpha) +
                    blue * alpha);
                pixels[index] = 0xff00_0000u | (b << 16) | (g << 8) | r;
            }
        }
    }

    private void addPixel(size_t index, float red, float green, float blue,
        float strength)
    {
        const target = pixels[index];
        const r = min(255, cast(int) ((target & 0xff) + red * 255.0f *
            strength));
        const g = min(255, cast(int) (((target >> 8) & 0xff) + green * 255.0f *
            strength));
        const b = min(255, cast(int) (((target >> 16) & 0xff) + blue * 255.0f *
            strength));
        pixels[index] = 0xff00_0000u | (b << 16) | (g << 8) | r;
    }

    private void drawText(int x, int y, int scale, string text, uint color)
    {
        int cursor = x;
        foreach (character; text)
        {
            char upper = character;
            if (upper >= 'a' && upper <= 'z')
                upper = cast(char) (upper - 'a' + 'A');
            const pattern = glyphPattern(upper);
            if (pattern.length == 35)
            {
                foreach (row; 0 .. 7)
                {
                    foreach (column; 0 .. 5)
                    {
                        if (pattern[row * 5 + column] == '1')
                            blendRect(cursor + column * scale, y + row * scale,
                                scale, scale, color, 1.0f);
                    }
                }
            }
            cursor += 6 * scale;
        }
    }
}

private Vec3 mix(Vec3 a, Vec3 b, float t)
{
    return Vec3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t);
}

private uint packColor(float red, float green, float blue)
{
    const r = cast(uint) (max(0.0f, min(1.0f, red)) * 255.0f + 0.5f);
    const g = cast(uint) (max(0.0f, min(1.0f, green)) * 255.0f + 0.5f);
    const b = cast(uint) (max(0.0f, min(1.0f, blue)) * 255.0f + 0.5f);
    return 0xff00_0000u | (b << 16) | (g << 8) | r;
}

private string glyphPattern(char character)
{
    switch (character)
    {
        case 'A': return "01110" ~ "10001" ~ "10001" ~ "11111" ~ "10001" ~ "10001" ~ "10001";
        case 'B': return "11110" ~ "10001" ~ "10001" ~ "11110" ~ "10001" ~ "10001" ~ "11110";
        case 'C': return "01111" ~ "10000" ~ "10000" ~ "10000" ~ "10000" ~ "10000" ~ "01111";
        case 'D': return "11110" ~ "10001" ~ "10001" ~ "10001" ~ "10001" ~ "10001" ~ "11110";
        case 'E': return "11111" ~ "10000" ~ "10000" ~ "11110" ~ "10000" ~ "10000" ~ "11111";
        case 'F': return "11111" ~ "10000" ~ "10000" ~ "11110" ~ "10000" ~ "10000" ~ "10000";
        case 'G': return "01111" ~ "10000" ~ "10000" ~ "10111" ~ "10001" ~ "10001" ~ "01110";
        case 'H': return "10001" ~ "10001" ~ "10001" ~ "11111" ~ "10001" ~ "10001" ~ "10001";
        case 'I': return "11111" ~ "00100" ~ "00100" ~ "00100" ~ "00100" ~ "00100" ~ "11111";
        case 'J': return "00111" ~ "00010" ~ "00010" ~ "00010" ~ "10010" ~ "10010" ~ "01100";
        case 'K': return "10001" ~ "10010" ~ "10100" ~ "11000" ~ "10100" ~ "10010" ~ "10001";
        case 'L': return "10000" ~ "10000" ~ "10000" ~ "10000" ~ "10000" ~ "10000" ~ "11111";
        case 'M': return "10001" ~ "11011" ~ "10101" ~ "10101" ~ "10001" ~ "10001" ~ "10001";
        case 'N': return "10001" ~ "11001" ~ "10101" ~ "10011" ~ "10001" ~ "10001" ~ "10001";
        case 'O': return "01110" ~ "10001" ~ "10001" ~ "10001" ~ "10001" ~ "10001" ~ "01110";
        case 'P': return "11110" ~ "10001" ~ "10001" ~ "11110" ~ "10000" ~ "10000" ~ "10000";
        case 'Q': return "01110" ~ "10001" ~ "10001" ~ "10001" ~ "10101" ~ "10010" ~ "01101";
        case 'R': return "11110" ~ "10001" ~ "10001" ~ "11110" ~ "10100" ~ "10010" ~ "10001";
        case 'S': return "01111" ~ "10000" ~ "10000" ~ "01110" ~ "00001" ~ "00001" ~ "11110";
        case 'T': return "11111" ~ "00100" ~ "00100" ~ "00100" ~ "00100" ~ "00100" ~ "00100";
        case 'U': return "10001" ~ "10001" ~ "10001" ~ "10001" ~ "10001" ~ "10001" ~ "01110";
        case 'V': return "10001" ~ "10001" ~ "10001" ~ "10001" ~ "10001" ~ "01010" ~ "00100";
        case 'W': return "10001" ~ "10001" ~ "10001" ~ "10101" ~ "10101" ~ "11011" ~ "10001";
        case 'X': return "10001" ~ "10001" ~ "01010" ~ "00100" ~ "01010" ~ "10001" ~ "10001";
        case 'Y': return "10001" ~ "10001" ~ "01010" ~ "00100" ~ "00100" ~ "00100" ~ "00100";
        case 'Z': return "11111" ~ "00001" ~ "00010" ~ "00100" ~ "01000" ~ "10000" ~ "11111";
        case '0': return "01110" ~ "10001" ~ "10011" ~ "10101" ~ "11001" ~ "10001" ~ "01110";
        case '1': return "00100" ~ "01100" ~ "00100" ~ "00100" ~ "00100" ~ "00100" ~ "01110";
        case '2': return "01110" ~ "10001" ~ "00001" ~ "00010" ~ "00100" ~ "01000" ~ "11111";
        case '3': return "11110" ~ "00001" ~ "00001" ~ "01110" ~ "00001" ~ "00001" ~ "11110";
        case '4': return "00010" ~ "00110" ~ "01010" ~ "10010" ~ "11111" ~ "00010" ~ "00010";
        case '5': return "11111" ~ "10000" ~ "11110" ~ "00001" ~ "00001" ~ "10001" ~ "01110";
        case '6': return "00110" ~ "01000" ~ "10000" ~ "11110" ~ "10001" ~ "10001" ~ "01110";
        case '7': return "11111" ~ "00001" ~ "00010" ~ "00100" ~ "01000" ~ "01000" ~ "01000";
        case '8': return "01110" ~ "10001" ~ "10001" ~ "01110" ~ "10001" ~ "10001" ~ "01110";
        case '9': return "01110" ~ "10001" ~ "10001" ~ "01111" ~ "00001" ~ "00010" ~ "01100";
        case '-': return "00000" ~ "00000" ~ "00000" ~ "11111" ~ "00000" ~ "00000" ~ "00000";
        case '.': return "00000" ~ "00000" ~ "00000" ~ "00000" ~ "00000" ~ "00110" ~ "00110";
        case '/': return "00001" ~ "00010" ~ "00010" ~ "00100" ~ "01000" ~ "01000" ~ "10000";
        case ':': return "00000" ~ "00110" ~ "00110" ~ "00000" ~ "00110" ~ "00110" ~ "00000";
        case '+': return "00000" ~ "00100" ~ "00100" ~ "11111" ~ "00100" ~ "00100" ~ "00000";
        default: return "00000" ~ "00000" ~ "00000" ~ "00000" ~ "00000" ~ "00000" ~ "00000";
    }
}
