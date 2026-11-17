module aurora.render.scene3d;

import std.algorithm.sorting : sort;
import std.math : cos, sin;

struct Vec3
{
    double x;
    double y;
    double z;

    Vec3 opBinary(string op)(Vec3 rhs) const
        if (op == "+" || op == "-")
    {
        return Vec3(mixin("x " ~ op ~ " rhs.x"),
            mixin("y " ~ op ~ " rhs.y"),
            mixin("z " ~ op ~ " rhs.z"));
    }
}

struct Line3D
{
    int x1;
    int y1;
    int x2;
    int y2;
    uint color;
    int thickness = 1;
}

struct Triangle3D
{
    int x1;
    int y1;
    int x2;
    int y2;
    int x3;
    int y3;
    uint color;
    double depth;
}

private Vec3 rotateY(Vec3 p, double angle)
{
    const c = cos(angle);
    const s = sin(angle);
    return Vec3(p.x * c - p.z * s, p.y, p.x * s + p.z * c);
}

private Vec3 rotateX(Vec3 p, double angle)
{
    const c = cos(angle);
    const s = sin(angle);
    return Vec3(p.x, p.y * c - p.z * s, p.y * s + p.z * c);
}

private bool project(Vec3 point, int width, int height, out int x, out int y)
{
    const vx = point.x;
    const vy = point.y;
    const vz = point.z - 5.0;
    if (vz > -0.25) return false;
    const scale = 400.0 / -vz;
    x = cast(int) (width / 2 + vx * scale);
    y = cast(int) (height / 2 - vy * scale);
    return true;
}

private void addLine(ref Line3D[] lines, Vec3 a, Vec3 b, int width,
    int height, uint color, int thickness = 1)
{
    int ax;
    int ay;
    int bx;
    int by;
    if (!project(a, width, height, ax, ay)) return;
    if (!project(b, width, height, bx, by)) return;
    lines ~= Line3D(ax, ay, bx, by, color, thickness);
}

/**
 * The shared 3D scene. It is intentionally independent of the host and the
 * presenter: a camera, a ground grid, and a rotating cube in world space.
 */
struct Scene3D
{
    Line3D[] build(int width, int height, double time)
    {
        Line3D[] lines;

        // Ground grid.
        foreach (i; -6 .. 7)
        {
            if (i == 0) continue;
            addLine(lines, Vec3(i, -1.5, -6), Vec3(i, -1.5, 6),
                width, height, 0x1e293b);
            addLine(lines, Vec3(-6, -1.5, i), Vec3(6, -1.5, i),
                width, height, 0x1e293b);
        }
        addLine(lines, Vec3(-6, -1.5, 0), Vec3(6, -1.5, 0),
            width, height, 0x475569, 2);
        addLine(lines, Vec3(0, -1.5, -6), Vec3(0, -1.5, 6),
            width, height, 0x475569, 2);

        // Rotating cube.
        const yaw = time * 0.7;
        const pitch = 0.35;
        Vec3[8] corners;
        size_t index;
        foreach (x; [-1.0, 1.0])
        {
            foreach (y; [-1.0, 1.0])
            {
                foreach (z; [-1.0, 1.0])
                {
                    corners[index++] = rotateX(rotateY(Vec3(x, y, z), yaw),
                        pitch);
                }
            }
        }
        immutable edges = [
            [0, 1], [0, 2], [0, 4], [1, 3], [1, 5], [2, 3],
            [2, 6], [3, 7], [4, 5], [4, 6], [5, 7], [6, 7]
        ];
        foreach (edge; edges)
        {
            addLine(lines, corners[edge[0]], corners[edge[1]],
                width, height, 0x38bdf8, 2);
        }

        return lines;
    }

    Triangle3D[] buildTriangles(int width, int height, double time)
    {
        const yaw = time * 0.7;
        const pitch = 0.35;
        Vec3[8] corners;
        size_t index;
        foreach (x; [-1.0, 1.0])
        {
            foreach (y; [-1.0, 1.0])
            {
                foreach (z; [-1.0, 1.0])
                {
                    corners[index++] = rotateX(rotateY(Vec3(x, y, z), yaw),
                        pitch);
                }
            }
        }
        immutable faces = [
            [0, 1, 3, 2],
            [4, 6, 7, 5],
            [0, 4, 5, 1],
            [2, 3, 7, 6],
            [0, 2, 6, 4],
            [1, 5, 7, 3]
        ];
        immutable colors = [
            0x0c4a6e, 0x075985, 0x0369a1,
            0x0284c7, 0x0ea5e9, 0x38bdf8
        ];
        Triangle3D[] triangles;
        foreach (faceIndex, face; faces)
        {
            Vec3 center;
            foreach (vertex; face)
                center = center + corners[vertex];
            center = Vec3(center.x / 4, center.y / 4, center.z / 4);
            int[4] px;
            int[4] py;
            bool visible = true;
            foreach (slot, vertex; face)
            {
                if (!project(corners[vertex], width, height,
                    px[slot], py[slot]))
                {
                    visible = false;
                    break;
                }
            }
            if (!visible) continue;
            const color = colors[faceIndex];
            triangles ~= Triangle3D(px[0], py[0], px[1], py[1],
                px[2], py[2], color, center.z);
            triangles ~= Triangle3D(px[0], py[0], px[2], py[2],
                px[3], py[3], color, center.z);
        }
        triangles.sort!((a, b) => a.depth < b.depth);
        return triangles;
    }
}
