module auroramesh.sculpt;

import auroramesh.mesh : Face, MaterialSlot, Mesh, Vec2, Vec3, add,
    computeSmoothNormals, lerp, normalize, scale, sub;
import aurora.image : RgbaImage;
import std.math : abs;

/** Deep copy used for undo snapshots; keeps materials, UVs, and textures. */
Mesh cloneMesh(const Mesh source)
{
    Mesh copy;
    copy.vertices = source.vertices.dup;
    copy.faces = source.faces.dup;
    copy.normals = source.normals.dup;
    copy.uvs = source.uvs.dup;
    copy.faceMaterials = source.faceMaterials.dup;
    copy.materials = source.materials.dup;
    // Decoded images are immutable, so undo snapshots share the image objects.
    copy.textures.length = source.textures.length;
    foreach (index, texture; source.textures)
        copy.textures[index] = cast(RgbaImage) texture;
    return copy;
}

/** Laplacian smoothing over a selected set of vertices. */
void smoothVertices(ref Mesh mesh, const int[] indices, double amount = 0.35)
{
    if (mesh.vertices.length == 0 || indices.length == 0)
        return;
    auto sums = new Vec3[mesh.vertices.length];
    auto counts = new int[mesh.vertices.length];
    foreach (ref value; sums)
        value = Vec3(0, 0, 0);
    foreach (face; mesh.faces)
    {
        sums[face.a] = add(sums[face.a], mesh.vertices[face.b]);
        sums[face.a] = add(sums[face.a], mesh.vertices[face.c]);
        counts[face.a] += 2;
        sums[face.b] = add(sums[face.b], mesh.vertices[face.a]);
        sums[face.b] = add(sums[face.b], mesh.vertices[face.c]);
        counts[face.b] += 2;
        sums[face.c] = add(sums[face.c], mesh.vertices[face.a]);
        sums[face.c] = add(sums[face.c], mesh.vertices[face.b]);
        counts[face.c] += 2;
    }
    auto selected = new bool[mesh.vertices.length];
    foreach (index; indices)
        if (index >= 0 && index < selected.length)
            selected[index] = true;
    foreach (index; 0 .. mesh.vertices.length)
    {
        if (!selected[index] || counts[index] == 0)
            continue;
        const average = scale(sums[index], 1.0 / counts[index]);
        mesh.vertices[index] = lerp(mesh.vertices[index], average, amount);
    }
    computeSmoothNormals(mesh);
}

/** Soft inflate along per-vertex normals. */
void inflateVertices(ref Mesh mesh, const int[] indices, double amount)
{
    if (mesh.normals.length != mesh.vertices.length)
        computeSmoothNormals(mesh);
    auto selected = new bool[mesh.vertices.length];
    foreach (index; indices)
        if (index >= 0 && index < selected.length)
            selected[index] = true;
    foreach (index; 0 .. mesh.vertices.length)
    {
        if (!selected[index])
            continue;
        mesh.vertices[index] = add(mesh.vertices[index],
            scale(mesh.normals[index], amount));
    }
    computeSmoothNormals(mesh);
}

int mirrorVertex(const Mesh mesh, int index, double tolerance = 0.004)
{
    if (index < 0 || index >= mesh.vertices.length)
        return -1;
    const target = Vec3(-mesh.vertices[index].x, mesh.vertices[index].y,
        mesh.vertices[index].z);
    int best = -1;
    double bestDistance = tolerance * tolerance;
    foreach (candidate, vertex; mesh.vertices)
    {
        const dx = vertex.x - target.x;
        const dy = vertex.y - target.y;
        const dz = vertex.z - target.z;
        const distance = dx * dx + dy * dy + dz * dz;
        if (distance < bestDistance)
        {
            bestDistance = distance;
            best = cast(int) candidate;
        }
    }
    return best;
}

unittest
{
    auto mesh = Mesh();
    const a = mesh.addVertex(Vec3(-1, 0, 0));
    const b = mesh.addVertex(Vec3(1, 0, 0));
    const c = mesh.addVertex(Vec3(0, 1, 0));
    mesh.addTriangle(a, b, c, 0);
    auto copy = cloneMesh(mesh);
    smoothVertices(mesh, [c]);
    assert(mesh.vertices[c].y < 1.0);
    assert(copy.vertices[c].y == 1.0);
    inflateVertices(mesh, [a], 0.1);
    assert(mesh.vertices[a].x != -1.0);
    assert(mirrorVertex(mesh, 0) >= 0);

    // Undo snapshots must keep everything the rasterizer needs.
    Mesh scene;
    scene.vertices = mesh.vertices.dup;
    scene.faces = mesh.faces.dup;
    scene.uvs = [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1)];
    scene.faceMaterials = [0];
    MaterialSlot slot;
    slot.baseColor = Vec3(1, 0, 0);
    slot.texture = 0;
    scene.materials = [slot];
    scene.textures = [new RgbaImage(1, 1, [ubyte(255), 0, 0, 255])];
    auto snapshot = cloneMesh(scene);
    assert(snapshot.uvs.length == 3);
    assert(snapshot.faceMaterials.length == 1);
    assert(snapshot.materials.length == 1);
    assert(snapshot.materials[0].texture == 0);
    assert(snapshot.textures.length == 1);
    assert(snapshot.textures[0] is scene.textures[0]);
    assert(snapshot.uvs[1].x == 1.0);
}