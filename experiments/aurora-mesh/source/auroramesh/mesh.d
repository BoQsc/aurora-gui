module auroramesh.mesh;

import std.conv : to;
import std.format : format;
import std.math : PI, abs, cos, isFinite, sin, sqrt;
import std.string : indexOf, split, splitLines, startsWith, strip;
import aurora.image : RgbaImage;

struct Vec3
{
    double x;
    double y;
    double z;

    this(double x, double y, double z)
    {
        this.x = x;
        this.y = y;
        this.z = z;
    }
}

struct Vec2
{
    double x;
    double y;

    this(double x, double y)
    {
        this.x = x;
        this.y = y;
    }
}

Vec3 add(Vec3 a, Vec3 b)
{
    return Vec3(a.x + b.x, a.y + b.y, a.z + b.z);
}

Vec3 sub(Vec3 a, Vec3 b)
{
    return Vec3(a.x - b.x, a.y - b.y, a.z - b.z);
}

Vec3 scale(Vec3 a, double factor)
{
    return Vec3(a.x * factor, a.y * factor, a.z * factor);
}

double dot(Vec3 a, Vec3 b)
{
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

Vec3 cross(Vec3 a, Vec3 b)
{
    return Vec3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x);
}

double length(Vec3 a)
{
    return sqrt(dot(a, a));
}

Vec3 normalize(Vec3 a)
{
    const magnitude = length(a);
    if (magnitude <= 1.0e-12)
        return Vec3(0, 0, 0);
    return scale(a, 1.0 / magnitude);
}

Vec3 lerp(Vec3 a, Vec3 b, double t)
{
    return add(a, scale(sub(b, a), t));
}

enum Material : ubyte
{
    skin,
    cloth,
    accent,
    neutral,
    eye,
}

struct MaterialSlot
{
    Vec3 baseColor = Vec3(1, 1, 1);
    double alpha = 1;
    int texture = -1;
    bool doubleSided;
}

struct Face
{
    int a;
    int b;
    int c;
    Material material;

    this(int a, int b, int c, Material material)
    {
        this.a = a;
        this.b = b;
        this.c = c;
        this.material = material;
    }
}

struct Mesh
{
    Vec3[] vertices;
    Face[] faces;
    Vec3[] normals;
    Vec2[] uvs;
    int[] faceMaterials;
    MaterialSlot[] materials;
    RgbaImage[] textures;

    int addVertex(Vec3 point)
    {
        vertices ~= point;
        return cast(int) vertices.length - 1;
    }

    void addTriangle(int a, int b, int c, Material material)
    {
        if (a == b || b == c || a == c)
            return;
        faces ~= Face(a, b, c, material);
    }

    void addQuad(int a, int b, int c, int d, Material material)
    {
        addTriangle(a, b, c, material);
        addTriangle(a, c, d, material);
    }
}

/** A low-poly, symmetric humanoid in a relaxed A-pose (v1). */
Mesh humanBaseMeshV1()
{
    Mesh mesh;
    const int segments = 14;

    // Torso and pelvis.
    bodyTube(mesh, Vec3(0, 0, 0), 0.82, 1.02, 0.17, 0.11, 0.19, 0.12,
        segments, 3, Material.cloth);
    bodyTube(mesh, Vec3(0, 0, 0), 1.00, 1.48, 0.19, 0.12, 0.22, 0.13,
        segments, 4, Material.cloth);

    // Neck and head.
    bodyTube(mesh, Vec3(0, 0, 0), 1.46, 1.61, 0.060, 0.052, 0.055, 0.048,
        segments, 2, Material.skin);
    ellipsoid(mesh, Vec3(0, 1.70, 0.005), 0.105, 0.145, 0.120, 16, 9,
        Material.skin);
    ellipsoid(mesh, Vec3(-0.115, 1.70, 0.00), 0.025, 0.055, 0.030, 8, 4,
        Material.skin);
    ellipsoid(mesh, Vec3(0.115, 1.70, 0.00), 0.025, 0.055, 0.030, 8, 4,
        Material.skin);

    // Nose wedge, facing +Z.
    const int noseLeft = mesh.addVertex(Vec3(-0.032, 1.705, 0.112));
    const int noseRight = mesh.addVertex(Vec3(0.032, 1.705, 0.112));
    const int noseTop = mesh.addVertex(Vec3(0.0, 1.745, 0.118));
    const int noseTip = mesh.addVertex(Vec3(0.0, 1.685, 0.185));
    mesh.addTriangle(noseLeft, noseTop, noseTip, Material.skin);
    mesh.addTriangle(noseTop, noseRight, noseTip, Material.skin);
    mesh.addTriangle(noseRight, noseLeft, noseTip, Material.skin);
    mesh.addTriangle(noseLeft, noseRight, noseTop, Material.skin);

    // Arms: shoulder, upper arm, forearm, hand.
    foreach (side; [-1.0, 1.0])
    {
        const shoulder = Vec3(0.205 * side, 1.43, 0.0);
        const elbow = Vec3(0.405 * side, 1.17, 0.025);
        const wrist = Vec3(0.535 * side, 0.90, 0.045);
        tubeSegment(mesh, shoulder, elbow, 0.082, 0.062, 10, 2,
            Material.cloth);
        tubeSegment(mesh, elbow, wrist, 0.060, 0.043, 10, 2,
            Material.skin);
        ellipsoid(mesh, Vec3(0.570 * side, 0.800, 0.050), 0.052, 0.090, 0.042,
            10, 5, Material.skin);
    }

    // Legs: thigh, calf, foot.
    foreach (side; [-1.0, 1.0])
    {
        const hip = Vec3(0.095 * side, 0.91, 0.0);
        const knee = Vec3(0.115 * side, 0.50, 0.012);
        const ankle = Vec3(0.125 * side, 0.10, 0.015);
        const toe = Vec3(0.125 * side, 0.045, 0.160);
        tubeSegment(mesh, hip, knee, 0.105, 0.073, 12, 3,
            Material.cloth);
        tubeSegment(mesh, knee, ankle, 0.072, 0.044, 12, 3,
            Material.cloth);
        tubeSegment(mesh, ankle, toe, 0.060, 0.052, 10, 2,
            Material.accent);
        ellipsoid(mesh, Vec3(0.125 * side, 0.045, 0.185), 0.070, 0.040, 0.085,
            10, 4, Material.accent);
    }

    return mesh;
}

/** Stable v1 entry point used by existing callers and tests. */
Mesh humanBaseMesh()
{
    return humanBaseMeshV1();
}

void bodyTube(ref Mesh mesh, Vec3 center, double y0, double y1, double rx0,
    double rz0, double rx1, double rz1, int segments, int rings,
    Material material)
{
    const int base = cast(int) mesh.vertices.length;
    foreach (ring; 0 .. rings + 1)
    {
        const t = cast(double) ring / rings;
        const y = y0 + (y1 - y0) * t;
        const rx = rx0 + (rx1 - rx0) * t;
        const rz = rz0 + (rz1 - rz0) * t;
        foreach (segment; 0 .. segments)
        {
            const angle = 2.0 * PI * segment / segments;
            mesh.vertices ~= Vec3(center.x + cos(angle) * rx, y,
                center.z + sin(angle) * rz);
        }
    }
    for (int ring = 0; ring < rings; ring++)
    {
        foreach (segment; 0 .. segments)
        {
            const next = (segment + 1) % segments;
            const i0 = base + ring * segments + segment;
            const i1 = base + ring * segments + next;
            const i2 = base + (ring + 1) * segments + segment;
            const i3 = base + (ring + 1) * segments + next;
            mesh.addQuad(i0, i2, i3, i1, material);
        }
    }

    const int bottom = mesh.addVertex(Vec3(center.x, y0, center.z));
    const int top = mesh.addVertex(Vec3(center.x, y1, center.z));
    foreach (segment; 0 .. segments)
    {
        const next = (segment + 1) % segments;
        mesh.addTriangle(bottom, base + next, base + segment, material);
        const last = base + rings * segments;
        mesh.addTriangle(top, last + segment, last + next, material);
    }
}

void tubeSegment(ref Mesh mesh, Vec3 a, Vec3 b, double radiusA, double radiusB,
    int segments, int rings, Material material)
{
    const direction = normalize(sub(b, a));
    const reference = abs(direction.y) < 0.9 ?
        Vec3(0, 1, 0) : Vec3(1, 0, 0);
    const side = normalize(cross(direction, reference));
    const up = normalize(cross(side, direction));
    const int base = cast(int) mesh.vertices.length;
    foreach (ring; 0 .. rings + 1)
    {
        const t = cast(double) ring / rings;
        const center = lerp(a, b, t);
        const radius = radiusA + (radiusB - radiusA) * t;
        foreach (segment; 0 .. segments)
        {
            const angle = 2.0 * PI * segment / segments;
            mesh.vertices ~= add(center,
                add(scale(side, cos(angle) * radius),
                    scale(up, sin(angle) * radius)));
        }
    }
    for (int ring = 0; ring < rings; ring++)
    {
        foreach (segment; 0 .. segments)
        {
            const next = (segment + 1) % segments;
            const i0 = base + ring * segments + segment;
            const i1 = base + ring * segments + next;
            const i2 = base + (ring + 1) * segments + segment;
            const i3 = base + (ring + 1) * segments + next;
            mesh.addQuad(i0, i2, i3, i1, material);
        }
    }

    const int capA = mesh.addVertex(a);
    const int capB = mesh.addVertex(b);
    foreach (segment; 0 .. segments)
    {
        const next = (segment + 1) % segments;
        mesh.addTriangle(capA, base + segment, base + next, material);
        const last = base + rings * segments;
        mesh.addTriangle(capB, last + next, last + segment, material);
    }
}

void ellipsoid(ref Mesh mesh, Vec3 center, double rx, double ry, double rz,
    int segments, int rings, Material material)
{
    const int base = cast(int) mesh.vertices.length;
    foreach (ring; 0 .. rings + 1)
    {
        const theta = PI * ring / rings;
        const ringRadius = sin(theta);
        const y = cos(theta) * ry;
        foreach (segment; 0 .. segments)
        {
            const angle = 2.0 * PI * segment / segments;
            mesh.vertices ~= Vec3(center.x + cos(angle) * ringRadius * rx,
                center.y + y, center.z + sin(angle) * ringRadius * rz);
        }
    }
    for (int ring = 0; ring < rings; ring++)
    {
        foreach (segment; 0 .. segments)
        {
            const next = (segment + 1) % segments;
            const i0 = base + ring * segments + segment;
            const i1 = base + ring * segments + next;
            const i2 = base + (ring + 1) * segments + segment;
            const i3 = base + (ring + 1) * segments + next;
            mesh.addQuad(i0, i2, i3, i1, material);
        }
    }
}

bool validMesh(const Mesh mesh)
{
    foreach (vertex; mesh.vertices)
        if (!isFinite(vertex.x) || !isFinite(vertex.y) || !isFinite(vertex.z))
            return false;
    foreach (face; mesh.faces)
    {
        if (face.a < 0 || face.b < 0 || face.c < 0 ||
            face.a >= mesh.vertices.length ||
            face.b >= mesh.vertices.length ||
            face.c >= mesh.vertices.length)
            return false;
    }
    if (mesh.normals.length != 0 &&
        mesh.normals.length != mesh.vertices.length)
        return false;
    return true;
}

void computeSmoothNormals(ref Mesh mesh)
{
    Vec3[] sums = new Vec3[mesh.vertices.length];
    foreach (ref value; sums)
        value = Vec3(0, 0, 0);
    foreach (face; mesh.faces)
    {
        const normal = cross(
            sub(mesh.vertices[face.b], mesh.vertices[face.a]),
            sub(mesh.vertices[face.c], mesh.vertices[face.a]));
        if (length(normal) < 1.0e-12)
            continue;
        sums[face.a] = add(sums[face.a], normal);
        sums[face.b] = add(sums[face.b], normal);
        sums[face.c] = add(sums[face.c], normal);
    }
    mesh.normals = new Vec3[mesh.vertices.length];
    foreach (index, normal; sums)
    {
        auto normalized = normalize(normal);
        if (length(normalized) < 0.5)
            normalized = Vec3(0, 0, 1);
        mesh.normals[index] = normalized;
    }
}

bool watertight(const Mesh mesh)
{
    int[ulong] edges;
    foreach (face; mesh.faces)
    {
        const indices = [face.a, face.b, face.c];
        foreach (offset; 0 .. 3)
        {
            int first = indices[offset];
            int second = indices[(offset + 1) % 3];
            if (first > second)
            {
                const int swap = first;
                first = second;
                second = swap;
            }
            const key = (cast(ulong) first << 32) | cast(uint) second;
            edges[key] = (key in edges) ? edges[key] + 1 : 1;
        }
    }
    foreach (count; edges)
        if (count != 2)
            return false;
    return edges.length > 0;
}

struct EdgeStats
{
    size_t boundary;
    size_t nonManifold;
}

EdgeStats meshEdgeStats(const Mesh mesh)
{
    int[ulong] edges;
    foreach (face; mesh.faces)
    {
        const indices = [face.a, face.b, face.c];
        foreach (offset; 0 .. 3)
        {
            int first = indices[offset];
            int second = indices[(offset + 1) % 3];
            if (first > second)
            {
                const int swap = first;
                first = second;
                second = swap;
            }
            const key = (cast(ulong) first << 32) | cast(uint) second;
            edges[key] = (key in edges) ? edges[key] + 1 : 1;
        }
    }
    EdgeStats stats;
    foreach (count; edges)
    {
        if (count == 1)
            stats.boundary++;
        else if (count > 2)
            stats.nonManifold++;
    }
    return stats;
}

private ulong edgeKey(int first, int second)
{
    if (first > second)
    {
        const int swap = first;
        first = second;
        second = swap;
    }
    return (cast(ulong) first << 32) | cast(uint) second;
}

/**
 * Close small boundary loops left by a low-resolution isosurface extraction.
 * Each loop gets a center vertex and a triangle fan.
 */
bool fillBoundaryHoles(ref Mesh mesh, Material material = Material.neutral)
{
    int[ulong] counts;
    foreach (face; mesh.faces)
    {
        const indices = [face.a, face.b, face.c];
        foreach (offset; 0 .. 3)
        {
            const key = edgeKey(indices[offset], indices[(offset + 1) % 3]);
            if (auto existing = key in counts)
                ++*existing;
            else
                counts[key] = 1;
        }
    }

    int[][int] adjacency;
    foreach (key, count; counts)
    {
        if (count != 1)
            continue;
        const first = cast(int) (key >> 32);
        const second = cast(int) (key & 0xffffffff);
        adjacency[first] ~= second;
        adjacency[second] ~= first;
    }
    if (adjacency.length == 0)
        return false;

    bool[ulong] used;
    bool filled;
    foreach (key, count; counts)
    {
        if (count != 1 || (key in used))
            continue;
        const start = cast(int) (key >> 32);
        int[] loop;
        int current = start;
        loop ~= current;
        while (true)
        {
            int next = -1;
            if (current in adjacency)
                foreach (neighbor; adjacency[current])
                {
                    const candidate = edgeKey(current, neighbor);
                    if (candidate in used)
                        continue;
                    next = neighbor;
                    break;
                }
            if (next < 0)
                break;
            used[edgeKey(current, next)] = true;
            if (next == start)
                break;
            loop ~= next;
            current = next;
            if (loop.length > mesh.vertices.length)
                break;
        }
        if (loop.length < 3 || loop[$ - 1] == start)
            continue;

        Vec3 center = Vec3(0, 0, 0);
        foreach (index; loop)
            center = add(center, mesh.vertices[index]);
        center = scale(center, 1.0 / loop.length);
        const centerIndex = mesh.addVertex(center);
        foreach (index; 0 .. loop.length)
        {
            const a = loop[index];
            const b = loop[(index + 1) % loop.length];
            const pa = mesh.vertices[a];
            const pb = mesh.vertices[b];
            const normal = cross(sub(pb, pa), sub(center, pa));
            Vec3 average = Vec3(0, 0, 0);
            if (a < mesh.normals.length)
                average = add(average, mesh.normals[a]);
            if (b < mesh.normals.length)
                average = add(average, mesh.normals[b]);
            if (dot(normal, average) < 0)
                mesh.addTriangle(centerIndex, b, a, material);
            else
                mesh.addTriangle(centerIndex, a, b, material);
        }
        filled = true;
    }
    if (filled)
        computeSmoothNormals(mesh);
    return filled;
}

string toObj(const Mesh mesh)
{
    string output = "# aurora-mesh human base mesh\n";
    foreach (vertex; mesh.vertices)
        output ~= format("v %.6f %.6f %.6f\n", vertex.x, vertex.y, vertex.z);
    foreach (face; mesh.faces)
        output ~= format("f %d %d %d\n", face.a + 1, face.b + 1, face.c + 1);
    return output;
}

Mesh parseObj(string text)
{
    Mesh mesh;
    foreach (rawLine; text.splitLines())
    {
        const line = rawLine.strip;
        if (line.startsWith("v "))
        {
            auto parts = line[2 .. $].split;
            if (parts.length < 3)
                continue;
            try
                mesh.vertices ~= Vec3(to!double(parts[0]),
                    to!double(parts[1]), to!double(parts[2]));
            catch (Exception) {}
        }
        else if (line.startsWith("f "))
        {
            int[] indices;
            foreach (token; line[2 .. $].split)
            {
                const slash = token.indexOf('/');
                const number = slash >= 0 ? token[0 .. slash] : token;
                if (number.length == 0)
                    continue;
                try
                {
                    auto index = to!int(number);
                    if (index < 0)
                        index = cast(int) mesh.vertices.length + index + 1;
                    indices ~= index - 1;
                }
                catch (Exception) {}
            }
            if (indices.length < 3)
                continue;
            foreach (index; 1 .. indices.length - 1)
            {
                const a = indices[0];
                const b = indices[index];
                const c = indices[index + 1];
                if (a >= 0 && b >= 0 && c >= 0 &&
                    a < mesh.vertices.length &&
                    b < mesh.vertices.length &&
                    c < mesh.vertices.length)
                    mesh.addTriangle(a, b, c, Material.neutral);
            }
        }
    }
    computeSmoothNormals(mesh);
    return mesh;
}

Vec3 meshMinimum(const Mesh mesh)
{
    if (mesh.vertices.length == 0)
        return Vec3(0, 0, 0);
    Vec3 result = mesh.vertices[0];
    foreach (vertex; mesh.vertices[1 .. $])
    {
        if (vertex.x < result.x) result.x = vertex.x;
        if (vertex.y < result.y) result.y = vertex.y;
        if (vertex.z < result.z) result.z = vertex.z;
    }
    return result;
}

Vec3 meshMaximum(const Mesh mesh)
{
    if (mesh.vertices.length == 0)
        return Vec3(0, 0, 0);
    Vec3 result = mesh.vertices[0];
    foreach (vertex; mesh.vertices[1 .. $])
    {
        if (vertex.x > result.x) result.x = vertex.x;
        if (vertex.y > result.y) result.y = vertex.y;
        if (vertex.z > result.z) result.z = vertex.z;
    }
    return result;
}

unittest
{
    auto mesh = humanBaseMesh();
    assert(validMesh(mesh));
    assert(mesh.vertices.length > 500);
    assert(mesh.faces.length > 800);
    const minimum = meshMinimum(mesh);
    const maximum = meshMaximum(mesh);
    assert(maximum.y - minimum.y > 1.7);
    const obj = toObj(mesh);
    auto parsed = parseObj(obj);
    assert(parsed.vertices.length == mesh.vertices.length);
    assert(parsed.faces.length == mesh.faces.length);
}
