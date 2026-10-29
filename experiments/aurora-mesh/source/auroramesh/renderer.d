module auroramesh.renderer;

import auroramesh.camera : Camera, CameraBasis, NearPlane, Projected, cameraBasis,
    project;
import auroramesh.mesh : Face, Material, MaterialSlot, Mesh, Vec2, Vec3, cross,
    dot, humanBaseMesh, length, normalize, sub;
import aurora.image : RgbaImage;
import core.time : MonoTime;
import std.algorithm : max, min;
import std.file : write;
import std.format : format;
import std.math : abs, ceil, floor, tan;

/// Where the last software frame spent its time, reported by `--bench`.
struct SoftwareStats
{
    double backgroundMs;
    double projectMs;
    double rasterMs;
}

__gshared SoftwareStats softwareStats;

struct RenderOptions
{
    bool wireframe = true;
    bool vertices = true;
    bool grid = true;
    bool cullBackfaces = true;
    int selectedVertex = -1;
}

struct RgbFrame
{
    int width;
    int height;
    ubyte[] pixels;
}

/** A clipped triangle corner in screen space with depth-weighted attributes. */
private struct RasterVertex
{
    double x;
    double y;
    double invZ;
    double u;
    double v;
    double light;
}

/**
 * One triangle handed to the GPU rasterizer: three screen-space corners holding
 * x, y, inverse depth and depth-weighted light, then the surface colour.
 */
struct GpuTriangle
{
    float[16] data;
}

 /** A triangle corner in camera space before the perspective divide. */
private struct FaceVertex
{
    double viewX;
    double viewY;
    double depth;
    double u;
    double v;
    double light;
}

private struct Texel
{
    double r;
    double g;
    double b;
    double a;
}

/** Per-face surface state shared by every fragment of the face. */
private struct Surface
{
    Vec3 color = Vec3(1, 1, 1);
    RgbaImage texture;
    int wrapS = 10497;
    int wrapT = 10497;
    double alpha = 1;
    int alphaMode;
    double cutoff = 0.5;
    bool textured;
}

// Scratch buffers reused between frames: the viewport renders at a steady size,
// so rebuilding these arrays on every frame is pure allocation churn.
private __gshared float[] depthScratch;
private __gshared Projected[] projectedScratch;
private __gshared ubyte[] backgroundCache;
private __gshared int backgroundWidth;
private __gshared int backgroundHeight;

/// The cool studio gradient only depends on the frame size, so build it once.
private const(ubyte)[] background(int width, int height)
{
    if (backgroundWidth == width && backgroundHeight == height &&
        backgroundCache.length == width * height * 3)
        return backgroundCache;
    backgroundWidth = width;
    backgroundHeight = height;
    backgroundCache = new ubyte[width * height * 3];
    foreach (y; 0 .. height)
    {
        const t = height <= 1 ? 0.0 : cast(double) y / (height - 1);
        const r = cast(ubyte) (8 + 7 * (1.0 - t));
        const g = cast(ubyte) (14 + 10 * (1.0 - t));
        const b = cast(ubyte) (24 + 18 * (1.0 - t));
        foreach (x; 0 .. width)
        {
            const index = (y * width + x) * 3;
            backgroundCache[index] = r;
            backgroundCache[index + 1] = g;
            backgroundCache[index + 2] = b;
        }
    }
    return backgroundCache;
}

RgbFrame renderMesh(const Mesh mesh, const Camera camera, int width, int height,
    RenderOptions options = RenderOptions(), GpuTriangle[]* triangleSink = null)
{
    width = max(1, width);
    height = max(1, height);
    const startTime = MonoTime.currTime();
    RgbFrame frame;
    frame.width = width;
    frame.height = height;
    frame.pixels = new ubyte[width * height * 3];
    frame.pixels[] = background(width, height);
    // Inverse depth (0 = empty) so nearer fragments compare greater.
    depthScratch.length = width * height;
    depthScratch[] = 0.0f;
    auto depth = depthScratch;

    if (options.grid)
        drawGroundGrid(frame, camera);
    const setupTime = MonoTime.currTime();

    if (mesh.vertices.length == 0 || mesh.faces.length == 0)
        return frame;

    projectedScratch.length = mesh.vertices.length;
    auto projected = projectedScratch[];
    const basis = cameraBasis(camera, height);
    foreach (index, vertex; mesh.vertices)
        projected[index] = project(vertex, basis, width, height);
    const projectTime = MonoTime.currTime();

    const focal = basis.focal;
    const light = normalize(Vec3(0.35, 0.85, 0.55));
    const smooth = mesh.normals.length == mesh.vertices.length;
    const hasFaceMaterials = mesh.faceMaterials.length == mesh.faces.length;
    const hasUvs = mesh.uvs.length == mesh.vertices.length;

    foreach (faceIndex, face; mesh.faces)
    {
        if (face.a < 0 || face.b < 0 || face.c < 0 ||
            face.a >= projected.length || face.b >= projected.length ||
            face.c >= projected.length)
            continue;
        const pa = projected[face.a];
        const pb = projected[face.b];
        const pc = projected[face.c];

        Surface surface;
        bool doubleSided;
        const materialIndex = hasFaceMaterials ?
            mesh.faceMaterials[faceIndex] : -1;
        if (materialIndex >= 0 && materialIndex < mesh.materials.length)
        {
            const slot = mesh.materials[materialIndex];
            surface.color = slot.baseColor;
            surface.alpha = slot.alpha;
            surface.alphaMode = slot.alphaMode;
            surface.cutoff = slot.alphaCutoff;
            surface.wrapS = slot.wrapS;
            surface.wrapT = slot.wrapT;
            doubleSided = slot.doubleSided;
            if (slot.texture >= 0 && slot.texture < mesh.textures.length &&
                hasUvs && mesh.textures[slot.texture] !is null)
            {
                // The renderer only reads texels; decoded images are immutable.
                surface.texture = cast(RgbaImage) mesh.textures[slot.texture];
                surface.textured = true;
            }
        }
        else
        {
            surface.color = materialColor(face.material);
        }

        double lightA;
        double lightB;
        double lightC;
        if (smooth)
        {
            lightA = shade(mesh.normals[face.a], light);
            lightB = shade(mesh.normals[face.b], light);
            lightC = shade(mesh.normals[face.c], light);
        }
        else
        {
            const normal = normalize(cross(
                sub(mesh.vertices[face.b], mesh.vertices[face.a]),
                sub(mesh.vertices[face.c], mesh.vertices[face.a])));
            lightA = lightB = lightC = shade(normal, light);
        }

        // Camera-space triangle, clipped against the near plane so a face that
        // crosses the camera keeps its visible part instead of vanishing.
        FaceVertex[3] corners;
        corners[0] = FaceVertex(pa.viewX, pa.viewY, pa.z,
            hasUvs ? mesh.uvs[face.a].x : 0.0,
            hasUvs ? mesh.uvs[face.a].y : 0.0, lightA);
        corners[1] = FaceVertex(pb.viewX, pb.viewY, pb.z,
            hasUvs ? mesh.uvs[face.b].x : 0.0,
            hasUvs ? mesh.uvs[face.b].y : 0.0, lightB);
        corners[2] = FaceVertex(pc.viewX, pc.viewY, pc.z,
            hasUvs ? mesh.uvs[face.c].x : 0.0,
            hasUvs ? mesh.uvs[face.c].y : 0.0, lightC);

        FaceVertex[4] clipped;
        int count;
        foreach (corner; 0 .. 3)
        {
            const next = (corner + 1) % 3;
            const inside = corners[corner].depth >= NearPlane;
            const insideNext = corners[next].depth >= NearPlane;
            if (inside)
            {
                clipped[count] = corners[corner];
                ++count;
            }
            if (inside != insideNext)
            {
                const t = (NearPlane - corners[corner].depth) /
                    (corners[next].depth - corners[corner].depth);
                clipped[count] = FaceVertex(
                    corners[corner].viewX + (corners[next].viewX -
                        corners[corner].viewX) * t,
                    corners[corner].viewY + (corners[next].viewY -
                        corners[corner].viewY) * t,
                    NearPlane,
                    corners[corner].u + (corners[next].u -
                        corners[corner].u) * t,
                    corners[corner].v + (corners[next].v -
                        corners[corner].v) * t,
                    corners[corner].light + (corners[next].light -
                        corners[corner].light) * t);
                ++count;
            }
        }
        // One clip plane turns a triangle into a triangle or a quad.
        if (count < 3 || count > 4)
            continue;

        RasterVertex[4] polygon;
        foreach (corner; 0 .. count)
        {
            const inverse = 1.0 / clipped[corner].depth;
            polygon[corner].x = width * 0.5 + clipped[corner].viewX * inverse *
                focal;
            polygon[corner].y = height * 0.5 - clipped[corner].viewY * inverse *
                focal;
            polygon[corner].invZ = inverse;
            polygon[corner].u = clipped[corner].u * inverse;
            polygon[corner].v = clipped[corner].v * inverse;
            polygon[corner].light = clipped[corner].light * inverse;
        }

        const cull = options.cullBackfaces && !doubleSided;
        foreach (corner; 1 .. count - 1)
        {
            if (triangleSink is null)
            {
                rasterizeTriangle(frame, depth, polygon[0], polygon[corner],
                    polygon[corner + 1], surface, cull);
                continue;
            }
            // The GPU path wants the same projected fan, culled the same way.
            // Textured surfaces still need the CPU texel fetch, so they stay.
            const fan = [polygon[0], polygon[corner], polygon[corner + 1]];
            const area = edge(fan[0].x, fan[0].y, fan[1].x, fan[1].y,
                fan[2].x, fan[2].y);
            if (abs(area) < 1.0e-9 || (cull && area > 0))
                continue;
            if (surface.textured || surface.alphaMode == 2)
            {
                rasterizeTriangle(frame, depth, fan[0], fan[1], fan[2],
                    surface, cull);
                continue;
            }
            GpuTriangle triangle;
            foreach (slot; 0 .. 3)
            {
                triangle.data[slot * 4] = cast(float) fan[slot].x;
                triangle.data[slot * 4 + 1] = cast(float) fan[slot].y;
                triangle.data[slot * 4 + 2] = cast(float) fan[slot].invZ;
                triangle.data[slot * 4 + 3] = cast(float) fan[slot].light;
            }
            triangle.data[12] = cast(float) surface.color.x;
            triangle.data[13] = cast(float) surface.color.y;
            triangle.data[14] = cast(float) surface.color.z;
            triangle.data[15] = cast(float) surface.alpha;
            *triangleSink ~= triangle;
        }
    }

    if (options.wireframe)
    {
        const wire = [ubyte(118), ubyte(145), ubyte(176)];
        foreach (face; mesh.faces)
        {
            const pa = projected[face.a];
            const pb = projected[face.b];
            const pc = projected[face.c];
            if (!pa.visible || !pb.visible || !pc.visible)
                continue;
            drawLine(frame, pa.x, pa.y, pb.x, pb.y, wire);
            drawLine(frame, pb.x, pb.y, pc.x, pc.y, wire);
            drawLine(frame, pc.x, pc.y, pa.x, pa.y, wire);
        }
    }

    if (options.vertices)
    {
        foreach (index, point; projected)
        {
            if (!point.visible || index == options.selectedVertex)
                continue;
            fillSquare(frame, point.x, point.y, 1,
                [ubyte(218), ubyte(230), ubyte(242)]);
        }
    }
    if (options.selectedVertex >= 0 &&
        options.selectedVertex < projected.length &&
        projected[options.selectedVertex].visible)
    {
        const point = projected[options.selectedVertex];
        fillSquare(frame, point.x, point.y, 3,
            [ubyte(255), ubyte(157), ubyte(66)]);
    }

    const endTime = MonoTime.currTime();
    softwareStats.backgroundMs =
        (setupTime - startTime).total!"usecs" / 1000.0;
    softwareStats.projectMs = (projectTime - setupTime).total!"usecs" / 1000.0;
    softwareStats.rasterMs = (endTime - projectTime).total!"usecs" / 1000.0;
    return frame;
}

/**
 * Shade one already-clipped, projected triangle. Attribute interpolation is
 * perspective correct: 1/z is linear in screen space, so UVs and shading are
 * divided by depth before the weighted sum and multiplied back afterwards.
 */
private void rasterizeTriangle(ref RgbFrame frame, float[] depth,
    const RasterVertex a, const RasterVertex b, const RasterVertex c,
    const Surface surface, bool cull)
{
    const width = frame.width;
    const height = frame.height;
    const area = edge(a.x, a.y, b.x, b.y, c.x, c.y);
    if (abs(area) < 1.0e-9)
        return;
    // Screen y grows downward, so camera-facing (counter-clockwise) triangles
    // have a negative signed area.
    if (cull && area > 0)
        return;

    const minX = max(0, cast(int) floor(min(a.x, min(b.x, c.x))));
    const maxX = min(width - 1, cast(int) ceil(max(a.x, max(b.x, c.x))));
    const minY = max(0, cast(int) floor(min(a.y, min(b.y, c.y))));
    const maxY = min(height - 1, cast(int) ceil(max(a.y, max(b.y, c.y))));
    if (minX > maxX || minY > maxY)
        return;

    const inverseArea = 1.0 / area;
    const mask = surface.alphaMode == 1;
    const blend = surface.alphaMode == 2;
    foreach (y; minY .. maxY + 1)
    {
        foreach (x; minX .. maxX + 1)
        {
            const px = x + 0.5;
            const py = y + 0.5;
            const wa = edge(b.x, b.y, c.x, c.y, px, py) * inverseArea;
            const wb = edge(c.x, c.y, a.x, a.y, px, py) * inverseArea;
            const wc = edge(a.x, a.y, b.x, b.y, px, py) * inverseArea;
            const positive = wa >= 0 && wb >= 0 && wc >= 0;
            const negative = wa <= 0 && wb <= 0 && wc <= 0;
            if (!positive && !negative)
                continue;
            const invZ = wa * a.invZ + wb * b.invZ + wc * c.invZ;
            if (invZ <= 0)
                continue;
            const index = y * width + x;
            if (invZ <= depth[index])
                continue;
            const z = 1.0 / invZ;
            Vec3 sampled = surface.color;
            double alpha = surface.alpha;
            if (surface.textured)
            {
                const u = (wa * a.u + wb * b.u + wc * c.u) * z;
                const v = (wa * a.v + wb * b.v + wc * c.v) * z;
                const texel = sampleTexture(surface.texture, u, v,
                    surface.wrapS, surface.wrapT);
                sampled = Vec3(texel.r, texel.g, texel.b);
                if (surface.alphaMode != 0)
                    alpha *= texel.a;
            }
            if (mask && alpha < surface.cutoff)
                continue;
            depth[index] = cast(float) invZ;
            const intensity = (wa * a.light + wb * b.light + wc * c.light) * z;
            const red = clampByte(sampled.x * intensity * 255);
            const green = clampByte(sampled.y * intensity * 255);
            const blue = clampByte(sampled.z * intensity * 255);
            const pixel = index * 3;
            if (blend && alpha < 0.999)
            {
                const inverse = 1 - alpha;
                frame.pixels[pixel] = clampByte(
                    frame.pixels[pixel] * inverse + red * alpha);
                frame.pixels[pixel + 1] = clampByte(
                    frame.pixels[pixel + 1] * inverse + green * alpha);
                frame.pixels[pixel + 2] = clampByte(
                    frame.pixels[pixel + 2] * inverse + blue * alpha);
            }
            else
            {
                frame.pixels[pixel] = red;
                frame.pixels[pixel + 1] = green;
                frame.pixels[pixel + 2] = blue;
            }
        }
    }
}

private double edge(double ax, double ay, double bx, double by, double px,
    double py)
{
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

private ubyte clampByte(double value)
{
    if (value <= 0)
        return 0;
    if (value >= 255)
        return 255;
    return cast(ubyte) value;
}

private double wrapCoordinate(double value, int mode)
{
    if (mode == 33071)
        return value < 0 ? 0 : value > 1 ? 1 : value;
    if (mode == 33648)
    {
        const wrapped = value - 2 * floor(value / 2);
        return wrapped > 1 ? 2 - wrapped : wrapped;
    }
    return value - floor(value);
}

private Texel sampleTexture(const(RgbaImage) image, double u, double v,
    int wrapS, int wrapT)
{
    Texel result = Texel(1, 1, 1, 1);
    const width = image.width;
    const height = image.height;
    if (width <= 0 || height <= 0)
        return result;
    const tx = cast(int) (wrapCoordinate(u, wrapS) * width) % width;
    const ty = cast(int) (wrapCoordinate(v, wrapT) * height) % height;
    const x = tx < 0 ? tx + width : tx;
    const y = ty < 0 ? ty + height : ty;
    const pixels = image.pixels;
    const offset = (y * width + x) * 4;
    result.r = pixels[offset] / 255.0;
    result.g = pixels[offset + 1] / 255.0;
    result.b = pixels[offset + 2] / 255.0;
    result.a = pixels[offset + 3] / 255.0;
    return result;
}

private double shade(Vec3 normal, Vec3 light)
{
    return 0.28 + 0.72 * abs(dot(normal, light));
}

private Vec3 materialColor(Material material)
{
    final switch (material)
    {
        case Material.skin:
            return Vec3(202.0 / 255.0, 154.0 / 255.0, 123.0 / 255.0);
        case Material.cloth:
            return Vec3(46.0 / 255.0, 111.0 / 255.0, 137.0 / 255.0);
        case Material.accent:
            return Vec3(151.0 / 255.0, 99.0 / 255.0, 60.0 / 255.0);
        case Material.neutral:
            return Vec3(148.0 / 255.0, 160.0 / 255.0, 178.0 / 255.0);
        case Material.eye:
            return Vec3(38.0 / 255.0, 52.0 / 255.0, 68.0 / 255.0);
    }
}

private void drawGroundGrid(RgbFrame frame, const Camera camera)
{
    const gridColor = [ubyte(44), ubyte(58), ubyte(80)];
    const extent = 1.7;
    const step = 0.34;
    for (double value = -extent; value <= extent + 0.001; value += step)
    {
        const a = project(Vec3(value, 0, -extent), camera, frame.width,
            frame.height);
        const b = project(Vec3(value, 0, extent), camera, frame.width,
            frame.height);
        if (a.visible && b.visible)
            drawLine(frame, a.x, a.y, b.x, b.y, gridColor);
        const c = project(Vec3(-extent, 0, value), camera, frame.width,
            frame.height);
        const d = project(Vec3(extent, 0, value), camera, frame.width,
            frame.height);
        if (c.visible && d.visible)
            drawLine(frame, c.x, c.y, d.x, d.y, gridColor);
    }
}

private void drawLine(RgbFrame frame, double ax, double ay, double bx,
    double by, const ubyte[] color)
{
    int x0 = cast(int) floor(ax + 0.5);
    int y0 = cast(int) floor(ay + 0.5);
    const x1 = cast(int) floor(bx + 0.5);
    const y1 = cast(int) floor(by + 0.5);
    const dx = abs(x1 - x0);
    const sx = x0 < x1 ? 1 : -1;
    const dy = -abs(y1 - y0);
    const sy = y0 < y1 ? 1 : -1;
    int error = dx + dy;
    while (true)
    {
        if (x0 >= 0 && x0 < frame.width && y0 >= 0 && y0 < frame.height)
        {
            const index = (y0 * frame.width + x0) * 3;
            frame.pixels[index] = color[0];
            frame.pixels[index + 1] = color[1];
            frame.pixels[index + 2] = color[2];
        }
        if (x0 == x1 && y0 == y1)
            break;
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

private void fillSquare(RgbFrame frame, double centerX, double centerY,
    int radius, const ubyte[] color)
{
    const cx = cast(int) floor(centerX + 0.5);
    const cy = cast(int) floor(centerY + 0.5);
    foreach (dy; -radius .. radius + 1)
    {
        foreach (dx; -radius .. radius + 1)
        {
            const x = cx + dx;
            const y = cy + dy;
            if (x < 0 || x >= frame.width || y < 0 || y >= frame.height)
                continue;
            const index = (y * frame.width + x) * 3;
            frame.pixels[index] = color[0];
            frame.pixels[index + 1] = color[1];
            frame.pixels[index + 2] = color[2];
        }
    }
}

void writePpm(string path, const RgbFrame frame)
{
    const header = format("P6\n%d %d\n255\n", frame.width, frame.height);
    ubyte[] data;
    data ~= cast(const(ubyte)[]) header;
    data ~= frame.pixels;
    write(path, data);
}

private int surfacePixelCount(const RgbFrame frame)
{
    int count;
    foreach (offset; 0 .. frame.pixels.length / 3)
    {
        const index = offset * 3;
        // The studio background is dark blue; surface pixels are brighter.
        if (frame.pixels[index + 1] > 60 || frame.pixels[index] > 60)
            ++count;
    }
    return count;
}

private Camera flatCamera()
{
    auto camera = Camera();
    camera.target = Vec3(0, 0, 0);
    camera.yaw = 0;
    camera.pitch = 0;
    camera.distance = 3.0;
    return camera;
}

private RenderOptions surfaceOptions()
{
    RenderOptions options;
    options.grid = false;
    options.wireframe = false;
    options.vertices = false;
    return options;
}

unittest
{
    auto mesh = Mesh();
    const a = mesh.addVertex(Vec3(-0.5, -0.5, 0));
    const b = mesh.addVertex(Vec3(0.5, -0.5, 0));
    const c = mesh.addVertex(Vec3(0.0, 0.5, 0));
    mesh.addTriangle(a, b, c, Material.cloth);
    auto camera = Camera();
    camera.target = Vec3(0, 0, 0);
    camera.distance = 2.0;
    auto rendered = renderMesh(mesh, camera, 80, 60);
    assert(rendered.pixels.length == 80 * 60 * 3);
    bool changed;
    foreach (index; 0 .. rendered.pixels.length)
        if (rendered.pixels[index] > 30)
        {
            changed = true;
            break;
        }
    assert(changed);
}

unittest
{
    // A quad stretched in depth must sample its texture by 1/z. Affine
    // (perspective-incorrect) interpolation would sample green at the middle.
    Mesh mesh;
    const int a = mesh.addVertex(Vec3(0, -0.5, 2));
    const int b = mesh.addVertex(Vec3(1, -0.5, -1));
    const int c = mesh.addVertex(Vec3(1, 0.5, -1));
    const int d = mesh.addVertex(Vec3(0, 0.5, 2));
    mesh.addQuad(a, b, c, d, Material.neutral);
    mesh.uvs = [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)];
    MaterialSlot slot;
    slot.baseColor = Vec3(1, 1, 1);
    slot.texture = 0;
    mesh.materials = [slot];
    mesh.faceMaterials = [0, 0];
    mesh.textures = [new RgbaImage(2, 1,
        [ubyte(255), 0, 0, 255, 0, 255, 0, 255])];

    const frame = renderMesh(mesh, flatCamera(), 200, 100, surfaceOptions());
    const focal = 50.0 / tan(21.0 * 3.14159265358979323846 / 180.0);
    const left = 104;
    const middle = cast(int) (100 + focal / 8);
    const right = cast(int) (100 + focal * 0.23);
    int red(int x) { return frame.pixels[(50 * frame.width + x) * 3]; }
    int green(int x) { return frame.pixels[(50 * frame.width + x) * 3 + 1]; }
    assert(red(left) > green(left), "near edge must read the first texel");
    assert(red(middle) > green(middle),
        "midpoint must read the near texel under 1/z interpolation");
    assert(green(right) > red(right), "far edge must read the second texel");
}

unittest
{
    // A face that crosses the camera keeps its visible part instead of being
    // dropped, and back faces of single-sided materials are culled.
    Mesh mesh;
    const int a = mesh.addVertex(Vec3(0.6, -0.6, 2.5));
    const int b = mesh.addVertex(Vec3(-0.6, -0.6, 4.0));
    const int c = mesh.addVertex(Vec3(-0.6, 0.6, 4.0));
    const int d = mesh.addVertex(Vec3(0.6, 0.6, 2.5));
    mesh.addQuad(a, d, c, b, Material.cloth);
    auto options = surfaceOptions();
    const clipped = renderMesh(mesh, flatCamera(), 120, 120, options);
    assert(surfacePixelCount(clipped) > 200,
        "crossing face must be clipped, not dropped");

    Mesh facing;
    const int e = facing.addVertex(Vec3(0, -0.4, 0));
    const int f = facing.addVertex(Vec3(0.4, -0.4, 0));
    const int g = facing.addVertex(Vec3(0, 0.4, 0));
    facing.addTriangle(e, f, g, Material.cloth);
    const front = renderMesh(facing, flatCamera(), 60, 60, options);
    assert(surfacePixelCount(front) > 100);

    facing.faces[0] = Face(g, f, e, Material.cloth);
    const back = renderMesh(facing, flatCamera(), 60, 60, options);
    assert(surfacePixelCount(back) == 0, "back faces are culled");

    MaterialSlot slot;
    slot.baseColor = Vec3(1, 1, 1);
    slot.doubleSided = true;
    facing.materials = [slot];
    facing.faceMaterials = [0];
    const doubled = renderMesh(facing, flatCamera(), 60, 60, options);
    assert(surfacePixelCount(doubled) > 100, "double-sided faces draw both ways");
}

unittest
{
    // Culling must not change a closed, outward-wound mesh: if it did, the
    // winding convention or the sign test would be inverted.
    auto mesh = humanBaseMesh();
    auto camera = Camera();
    auto options = surfaceOptions();
    auto culled = renderMesh(mesh, camera, 160, 220, options);
    options.cullBackfaces = false;
    auto both = renderMesh(mesh, camera, 160, 220, options);
    int differences;
    foreach (offset; 0 .. culled.pixels.length / 3)
        foreach (channel; 0 .. 3)
        {
            const index = offset * 3 + channel;
            if (abs(cast(int) culled.pixels[index] -
                cast(int) both.pixels[index]) > 12)
            {
                ++differences;
                break;
            }
        }
    assert(differences < culled.width * culled.height / 120,
        "backface culling changed visible surfaces");
}
