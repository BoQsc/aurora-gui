module auroramesh.collision;

import auroramesh.mesh : Mesh, Vec3, cross, dot, sub;
import std.math : abs, floor;

struct CollisionReport
{
    int pairs;
    Vec3 sample;
    int faceA = -1;
    int faceB = -1;
}

private struct Aabb
{
    Vec3 minimum;
    Vec3 maximum;
}

private Aabb triangleBounds(Vec3 a, Vec3 b, Vec3 c)
{
    return Aabb(
        Vec3(a.x < b.x ? a.x : b.x, a.y < b.y ? a.y : b.y,
            a.z < b.z ? a.z : b.z),
        Vec3(a.x > b.x ? a.x : b.x, a.y > b.y ? a.y : b.y,
            a.z > b.z ? a.z : b.z));
}

private Aabb mergeBounds(const Aabb a, const Aabb b)
{
    return Aabb(
        Vec3(a.minimum.x < b.minimum.x ? a.minimum.x : b.minimum.x,
            a.minimum.y < b.minimum.y ? a.minimum.y : b.minimum.y,
            a.minimum.z < b.minimum.z ? a.minimum.z : b.minimum.z),
        Vec3(a.maximum.x > b.maximum.x ? a.maximum.x : b.maximum.x,
            a.maximum.y > b.maximum.y ? a.maximum.y : b.maximum.y,
            a.maximum.z > b.maximum.z ? a.maximum.z : b.maximum.z));
}

private bool overlaps(const Aabb a, const Aabb b)
{
    return a.minimum.x <= b.maximum.x && a.maximum.x >= b.minimum.x &&
        a.minimum.y <= b.maximum.y && a.maximum.y >= b.minimum.y &&
        a.minimum.z <= b.maximum.z && a.maximum.z >= b.minimum.z;
}

private long cellKey(int x, int y, int z)
{
    return (cast(long) (x + 512) << 40) |
        (cast(long) (y + 512) << 20) | cast(long) (z + 512);
}

private bool edgeHitsTriangle(Vec3 start, Vec3 end, Vec3 a, Vec3 b, Vec3 c)
{
    const edge1 = sub(b, a);
    const edge2 = sub(c, a);
    const direction = sub(end, start);
    const h = cross(direction, edge2);
    const determinant = dot(edge1, h);
    if (abs(determinant) < 1e-9)
        return false;
    const inverse = 1.0 / determinant;
    const s = sub(start, a);
    const u = dot(s, h) * inverse;
    if (u < 0 || u > 1)
        return false;
    const q = cross(s, edge1);
    const v = dot(direction, q) * inverse;
    if (v < 0 || u + v > 1)
        return false;
    const t = dot(edge2, q) * inverse;
    return t > 1e-6 && t < 1 - 1e-6;
}

private bool trianglesIntersect(Vec3 a, Vec3 b, Vec3 c, Vec3 d, Vec3 e,
    Vec3 f)
{
    return edgeHitsTriangle(a, b, d, e, f) ||
        edgeHitsTriangle(b, c, d, e, f) ||
        edgeHitsTriangle(c, a, d, e, f) ||
        edgeHitsTriangle(d, e, a, b, c) ||
        edgeHitsTriangle(e, f, a, b, c) ||
        edgeHitsTriangle(f, d, a, b, c);
}

/** Spatial-grid self-intersection audit. Adjacent faces and shared edges are ignored. */
CollisionReport findSelfIntersections(const Mesh mesh, int maximumPairs = 4096)
{
    CollisionReport report;
    report.sample = Vec3(0, 0, 0);
    if (mesh.faces.length < 2)
        return report;
    enum double CellSize = 0.08;
    Aabb[] bounds;
    bounds.length = mesh.faces.length;
    int[][long] cells;
    foreach (faceIndex, face; mesh.faces)
    {
        if (face.a < 0 || face.b < 0 || face.c < 0 ||
            face.a >= mesh.vertices.length ||
            face.b >= mesh.vertices.length ||
            face.c >= mesh.vertices.length)
            continue;
        const a = mesh.vertices[face.a];
        const b = mesh.vertices[face.b];
        const c = mesh.vertices[face.c];
        bounds[faceIndex] = triangleBounds(a, b, c);
        const minimumX = cast(int) floor(bounds[faceIndex].minimum.x /
            CellSize);
        const maximumX = cast(int) floor(bounds[faceIndex].maximum.x /
            CellSize);
        const minimumY = cast(int) floor(bounds[faceIndex].minimum.y /
            CellSize);
        const maximumY = cast(int) floor(bounds[faceIndex].maximum.y /
            CellSize);
        const minimumZ = cast(int) floor(bounds[faceIndex].minimum.z /
            CellSize);
        const maximumZ = cast(int) floor(bounds[faceIndex].maximum.z /
            CellSize);
        foreach (x; minimumX .. maximumX + 1)
            foreach (y; minimumY .. maximumY + 1)
                foreach (z; minimumZ .. maximumZ + 1)
                    cells[cellKey(x, y, z)] ~= cast(int) faceIndex;
    }
    bool[ulong] seen;
    foreach (ids; cells)
    {
        foreach (left; 0 .. ids.length)
            foreach (right; left + 1 .. ids.length)
            {
                const first = ids[left];
                const second = ids[right];
                if (first == second)
                    continue;
                const low = first < second ? first : second;
                const high = first < second ? second : first;
                const key = cast(ulong) low *
                    cast(ulong) mesh.faces.length + cast(ulong) high;
                if (key in seen)
                    continue;
                seen[key] = true;
                const firstFace = mesh.faces[low];
                const secondFace = mesh.faces[high];
                if (firstFace.a == secondFace.a ||
                    firstFace.a == secondFace.b ||
                    firstFace.a == secondFace.c ||
                    firstFace.b == secondFace.a ||
                    firstFace.b == secondFace.b ||
                    firstFace.b == secondFace.c ||
                    firstFace.c == secondFace.a ||
                    firstFace.c == secondFace.b ||
                    firstFace.c == secondFace.c)
                    continue;
                if (!overlaps(bounds[low], bounds[high]))
                    continue;
                const a = mesh.vertices[firstFace.a];
                const b = mesh.vertices[firstFace.b];
                const c = mesh.vertices[firstFace.c];
                const d = mesh.vertices[secondFace.a];
                const e = mesh.vertices[secondFace.b];
                const f = mesh.vertices[secondFace.c];
                if (!trianglesIntersect(a, b, c, d, e, f))
                    continue;
                report.pairs++;
                if (report.faceA < 0)
                {
                    report.faceA = low;
                    report.faceB = high;
                    report.sample = Vec3((a.x + b.x + c.x + d.x + e.x +
                        f.x) / 6, (a.y + b.y + c.y + d.y + e.y + f.y) / 6,
                        (a.z + b.z + c.z + d.z + e.z + f.z) / 6);
                }
                if (report.pairs >= maximumPairs)
                    return report;
            }
    }
    return report;
}