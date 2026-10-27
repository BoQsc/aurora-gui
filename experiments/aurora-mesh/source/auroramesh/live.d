module auroramesh.live;

import auroramesh.mesh : Face, Material, Mesh, Vec3, add,
    computeSmoothNormals;
import std.math : cos, PI, sin;

private Mesh makeBox(Vec3 center, Vec3 size)
{
    Mesh mesh;
    const hx = size.x * 0.5;
    const hy = size.y * 0.5;
    const hz = size.z * 0.5;
    mesh.vertices = [
        Vec3(center.x - hx, center.y - hy, center.z - hz),
        Vec3(center.x + hx, center.y - hy, center.z - hz),
        Vec3(center.x + hx, center.y + hy, center.z - hz),
        Vec3(center.x - hx, center.y + hy, center.z - hz),
        Vec3(center.x - hx, center.y - hy, center.z + hz),
        Vec3(center.x + hx, center.y - hy, center.z + hz),
        Vec3(center.x + hx, center.y + hy, center.z + hz),
        Vec3(center.x - hx, center.y + hy, center.z + hz),
    ];
    mesh.faces = [
        Face(0, 2, 1, Material.neutral), Face(0, 3, 2, Material.neutral),
        Face(4, 5, 6, Material.neutral), Face(4, 6, 7, Material.neutral),
        Face(0, 1, 5, Material.neutral), Face(0, 5, 4, Material.neutral),
        Face(1, 2, 6, Material.neutral), Face(1, 6, 5, Material.neutral),
        Face(2, 3, 7, Material.neutral), Face(2, 7, 6, Material.neutral),
        Face(3, 0, 4, Material.neutral), Face(3, 4, 7, Material.neutral),
    ];
    computeSmoothNormals(mesh);
    return mesh;
}

private void appendBox(ref Mesh target, Vec3 center, Vec3 size)
{
    const box = makeBox(center, size);
    const offset = cast(int) target.vertices.length;
    target.vertices ~= box.vertices;
    target.normals ~= box.normals;
    foreach (face; box.faces)
        target.addTriangle(offset + face.a, offset + face.b, offset + face.c,
            Material.neutral);
}

private Mesh makeSphere(Vec3 center, double radius)
{
    Mesh mesh;
    enum int Rings = 10;
    enum int Segments = 16;
    foreach (ring; 0 .. Rings + 1)
    {
        const v = cast(double) ring / Rings;
        const latitude = PI * v;
        foreach (segment; 0 .. Segments)
        {
            const longitude = 2 * PI * segment / Segments;
            mesh.vertices ~= Vec3(
                center.x + radius * sin(latitude) * cos(longitude),
                center.y + radius * cos(latitude),
                center.z + radius * sin(latitude) * sin(longitude));
        }
    }
    foreach (ring; 0 .. Rings)
        foreach (segment; 0 .. Segments)
        {
            const next = (segment + 1) % Segments;
            const a = ring * Segments + segment;
            const b = ring * Segments + next;
            const c = (ring + 1) * Segments + segment;
            const d = (ring + 1) * Segments + next;
            mesh.addTriangle(a, c, b, Material.accent);
            mesh.addTriangle(b, c, d, Material.accent);
        }
    computeSmoothNormals(mesh);
    return mesh;
}

/** A small owned rifle assembled from boxes, centered at the origin. */
private Mesh makeRifle()
{
    Mesh mesh;
    appendBox(mesh, Vec3(0.0, 0.0, 0.0), Vec3(0.55, 0.12, 0.12));
    appendBox(mesh, Vec3(-0.40, -0.02, 0.0), Vec3(0.32, 0.14, 0.07));
    appendBox(mesh, Vec3(0.48, 0.02, 0.0), Vec3(0.55, 0.035, 0.035));
    appendBox(mesh, Vec3(0.05, -0.18, 0.0), Vec3(0.10, 0.22, 0.06));
    appendBox(mesh, Vec3(-0.16, -0.17, 0.0), Vec3(0.08, 0.18, 0.07));
    appendBox(mesh, Vec3(0.10, 0.10, 0.0), Vec3(0.08, 0.05, 0.05));
    return mesh;
}

/** Build a procedural object in world space. */
Mesh liveObject(string shape, Vec3 position, double scale)
{
    Mesh mesh;
    if (shape == "sphere")
        mesh = makeSphere(position, scale);
    else if (shape == "rifle" || shape == "weapon")
        mesh = makeRifle();
    else
        mesh = makeBox(Vec3(0, 0, 0), Vec3(0.4, 0.4, 0.4));
    if (shape != "sphere")
        foreach (ref vertex; mesh.vertices)
            vertex = add(Vec3(vertex.x * scale, vertex.y * scale,
                vertex.z * scale), position);
    return mesh;
}