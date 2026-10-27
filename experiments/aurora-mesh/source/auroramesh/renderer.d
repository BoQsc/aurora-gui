module auroramesh.renderer;

import auroramesh.camera : Camera, Projected, project;
import auroramesh.mesh : Face, Material, Mesh, Vec3, cross, dot, length, normalize,
    sub;
import std.algorithm : max, min;
import std.file : write;
import std.format : format;
import std.math : abs, ceil, cos, floor, sin, sqrt;

struct RenderOptions
{
    bool wireframe = true;
    bool vertices = true;
    bool grid = true;
    int selectedVertex = -1;
}

struct RgbFrame
{
    int width;
    int height;
    ubyte[] pixels;
}

RgbFrame renderMesh(const Mesh mesh, const Camera camera, int width, int height,
    RenderOptions options = RenderOptions())
{
    width = max(1, width);
    height = max(1, height);
    RgbFrame frame;
    frame.width = width;
    frame.height = height;
    frame.pixels = new ubyte[width * height * 3];
    auto depth = new float[width * height];
    foreach (ref value; depth)
        value = float.max;

    // Cool vertical studio gradient.
    foreach (y; 0 .. height)
    {
        const t = height <= 1 ? 0.0 : cast(double) y / (height - 1);
        const r = cast(ubyte) (8 + 7 * (1.0 - t));
        const g = cast(ubyte) (14 + 10 * (1.0 - t));
        const b = cast(ubyte) (24 + 18 * (1.0 - t));
        foreach (x; 0 .. width)
        {
            const index = (y * width + x) * 3;
            frame.pixels[index] = r;
            frame.pixels[index + 1] = g;
            frame.pixels[index + 2] = b;
        }
    }

    if (options.grid)
        drawGroundGrid(frame, camera);

    if (mesh.vertices.length == 0 || mesh.faces.length == 0)
        return frame;

    auto projected = new Projected[mesh.vertices.length];
    foreach (index, vertex; mesh.vertices)
        projected[index] = project(vertex, camera, width, height);

    const light = normalize(Vec3(0.35, 0.85, 0.55));
    const smooth = mesh.normals.length == mesh.vertices.length;
    foreach (face; mesh.faces)
    {
        const pa = projected[face.a];
        const pb = projected[face.b];
        const pc = projected[face.c];
        if (!pa.visible || !pb.visible || !pc.visible)
            continue;

        const area = edge(pa.x, pa.y, pb.x, pb.y, pc.x, pc.y);
        if (abs(area) < 1.0e-8)
            continue;

        double intensityA;
        double intensityB;
        double intensityC;
        double flatIntensity;
        if (smooth)
        {
            intensityA = shade(mesh.normals[face.a], light);
            intensityB = shade(mesh.normals[face.b], light);
            intensityC = shade(mesh.normals[face.c], light);
        }
        else
        {
            const normal = normalize(cross(
                sub(mesh.vertices[face.b], mesh.vertices[face.a]),
                sub(mesh.vertices[face.c], mesh.vertices[face.a])));
            flatIntensity = shade(normal, light);
        }
        const base = materialColor(face.material);

        const minX = max(0, cast(int) floor(min(pa.x, min(pb.x, pc.x))));
        const maxX = min(width - 1, cast(int) ceil(max(pa.x, max(pb.x, pc.x))));
        const minY = max(0, cast(int) floor(min(pa.y, min(pb.y, pc.y))));
        const maxY = min(height - 1, cast(int) ceil(max(pa.y, max(pb.y, pc.y))));
        if (minX > maxX || minY > maxY)
            continue;

        const inverseArea = 1.0 / area;
        foreach (y; minY .. maxY + 1)
        {
            foreach (x; minX .. maxX + 1)
            {
                const px = x + 0.5;
                const py = y + 0.5;
                const wa = edge(pb.x, pb.y, pc.x, pc.y, px, py) * inverseArea;
                const wb = edge(pc.x, pc.y, pa.x, pa.y, px, py) * inverseArea;
                const wc = edge(pa.x, pa.y, pb.x, pb.y, px, py) * inverseArea;
                const positive = wa >= 0 && wb >= 0 && wc >= 0;
                const negative = wa <= 0 && wb <= 0 && wc <= 0;
                if (!positive && !negative)
                    continue;
                const z = wa * pa.z + wb * pb.z + wc * pc.z;
                const index = y * width + x;
                if (z >= depth[index])
                    continue;
                depth[index] = cast(float) z;
                const intensity = smooth ?
                    wa * intensityA + wb * intensityB + wc * intensityC :
                    flatIntensity;
                const red = cast(ubyte) min(255.0, base[0] * intensity);
                const green = cast(ubyte) min(255.0, base[1] * intensity);
                const blue = cast(ubyte) min(255.0, base[2] * intensity);
                const pixel = index * 3;
                frame.pixels[pixel] = red;
                frame.pixels[pixel + 1] = green;
                frame.pixels[pixel + 2] = blue;
            }
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

    return frame;
}

private double edge(double ax, double ay, double bx, double by, double px,
    double py)
{
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

private double shade(Vec3 normal, Vec3 light)
{
    return 0.28 + 0.72 * abs(dot(normal, light));
}

private double[] materialColor(Material material)
{
    final switch (material)
    {
        case Material.skin:
            return [202.0, 154.0, 123.0];
        case Material.cloth:
            return [46.0, 111.0, 137.0];
        case Material.accent:
            return [151.0, 99.0, 60.0];
        case Material.neutral:
            return [148.0, 160.0, 178.0];
        case Material.eye:
            return [38.0, 52.0, 68.0];
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
