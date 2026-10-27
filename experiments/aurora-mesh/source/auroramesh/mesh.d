module auroramesh.mesh;

import std.conv : to;
import std.format : format;
import std.math : PI, abs, cos, isFinite, sin, sqrt;
import std.string : indexOf, split, splitLines, startsWith, strip;

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

/** A low-poly, symmetric humanoid in a relaxed A-pose. */
Mesh humanBaseMesh()
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
    return true;
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
