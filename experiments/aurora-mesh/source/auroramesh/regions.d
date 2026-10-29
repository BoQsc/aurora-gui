module auroramesh.regions;

/**
 * Named editing regions.
 *
 * A region is a volume with a soft edge: inside it the mask is 1, outside 0, and
 * across the edge it blends. Edits are weighted by that mask, which is what keeps
 * a local change from leaving a hard seam or a spike where the region ends.
 *
 * Volumes are described as data, so a caller can work on a foot, a forearm or the
 * whole torso with the same code.
 */
import auroramesh.mesh : Mesh, Vec3, add, computeSmoothNormals, dot, length,
    normalize, scale, sub;
import auroramesh.sculpt : smoothVertices;
import std.algorithm : max, min;
import std.math : PI, abs, isFinite, sqrt;

enum RegionKind : ubyte
{
    box,
    sphere,
    capsule,
}

struct RegionVolume
{
    string name;
    RegionKind kind = RegionKind.box;
    Vec3 a;                 /// box minimum, sphere centre, capsule start
    Vec3 b;                 /// box maximum, capsule end
    double radius = 0.1;    /// sphere or capsule radius
    double falloff = 0.3;   /// share of the size used to blend the rim
}

/// Signed distance to the region: negative inside.
double regionDistance(const RegionVolume region, Vec3 point)
{
    final switch (region.kind)
    {
        case RegionKind.box:
            const centre = scale(add(region.a, region.b), 0.5);
            const half = scale(sub(region.b, region.a), 0.5);
            const local = sub(point, centre);
            const qx = abs(local.x) - half.x;
            const qy = abs(local.y) - half.y;
            const qz = abs(local.z) - half.z;
            const outside = Vec3(qx > 0 ? qx : 0, qy > 0 ? qy : 0,
                qz > 0 ? qz : 0);
            const inside = qx > qy ? (qx > qz ? qx : qz) : (qy > qz ? qy : qz);
            return length(outside) + (inside < 0 ? inside : 0);

        case RegionKind.sphere:
            return length(sub(point, region.a)) - region.radius;

        case RegionKind.capsule:
            const segment = sub(region.b, region.a);
            const denominator = dot(segment, segment);
            const t = denominator <= 1.0e-12 ? 0.0 :
                clamp01(dot(sub(point, region.a), segment) / denominator);
            const closest = add(region.a, scale(segment, t));
            return length(sub(point, closest)) - region.radius;
    }
}

/// Characteristic size of the region, used to scale the blend band.
private double regionSize(const RegionVolume region)
{
    final switch (region.kind)
    {
        case RegionKind.box:
            const half = scale(sub(region.b, region.a), 0.5);
            return min(half.x, min(half.y, half.z));

        case RegionKind.sphere:
            return region.radius;

        case RegionKind.capsule:
            return region.radius;
    }
}

private double clamp01(double value)
{
    return value < 0 ? 0 : (value > 1 ? 1 : value);
}

private double smoothStep(double t)
{
    return t * t * (3.0 - 2.0 * t);
}

/**
 * Mask value at a point: 1 inside, 0 outside, blended across a band whose width
 * is `falloff` times the region's size.
 */
double regionMask(const RegionVolume region, Vec3 point)
{
    const size = regionSize(region);
    const band = size * (region.falloff > 0 ? region.falloff : 0.001);
    const distance = regionDistance(region, point);
    if (distance <= -band)
        return 1.0;
    if (distance >= 0)
        return 0.0;
    // Rim of the volume fades from 1 at -band to 0 at the surface.
    return smoothStep(clamp01(1.0 + distance / band));
}

struct RegionSelection
{
    string name;
    int[] vertices;   /// vertices with any mask at all
    int[] faces;      /// faces whose centre is inside the mask
    double[] weights; /// mask per vertex, parallel to `vertices`
    int fullVertices; /// vertices fully inside
    Vec3 minimum;
    Vec3 maximum;

    int count() const
    {
        return cast(int) vertices.length;
    }
}

/// Vertices and faces the region touches, with their mask weights.
RegionSelection selectRegion(const Mesh mesh, const RegionVolume region)
{
    RegionSelection selection;
    selection.name = region.name;
    selection.minimum = Vec3(0, 0, 0);
    selection.maximum = Vec3(0, 0, 0);
    bool any;
    foreach (index, vertex; mesh.vertices)
    {
        const weight = regionMask(region, vertex);
        if (weight <= 0)
            continue;
        selection.vertices ~= cast(int) index;
        selection.weights ~= weight;
        if (weight >= 0.999)
            ++selection.fullVertices;
        if (!any)
        {
            selection.minimum = vertex;
            selection.maximum = vertex;
            any = true;
        }
        else
        {
            selection.minimum = Vec3(
                vertex.x < selection.minimum.x ? vertex.x : selection.minimum.x,
                vertex.y < selection.minimum.y ? vertex.y : selection.minimum.y,
                vertex.z < selection.minimum.z ? vertex.z : selection.minimum.z);
            selection.maximum = Vec3(
                vertex.x > selection.maximum.x ? vertex.x : selection.maximum.x,
                vertex.y > selection.maximum.y ? vertex.y : selection.maximum.y,
                vertex.z > selection.maximum.z ? vertex.z : selection.maximum.z);
        }
    }
    if (selection.vertices.length == 0)
        return selection;
    auto inside = new bool[mesh.vertices.length];
    foreach (index, weight; selection.weights)
        if (weight > 0.05)
            inside[selection.vertices[index]] = true;
    foreach (index, face; mesh.faces)
    {
        const middle = scale(add(add(mesh.vertices[face.a], mesh.vertices[face.b]),
            mesh.vertices[face.c]), 1.0 / 3.0);
        if (regionMask(region, middle) > 0.05)
            selection.faces ~= cast(int) index;
    }
    return selection;
}

/**
 * Move the selected surface.
 *
 * Every op is scaled by the mask, so the change fades out at the rim of the region
 * instead of tearing a seam there. Returns how many vertices moved.
 */
int deformRegion(ref Mesh mesh, const RegionVolume region, string op,
    double amount, Vec3 direction = Vec3(0, 0, 0))
{
    const selection = selectRegion(mesh, region);
    if (selection.vertices.length == 0 || amount == 0)
        return 0;
    if (mesh.normals.length != mesh.vertices.length)
        computeSmoothNormals(mesh);
    auto aim = direction;
    const aimLength = length(aim);
    if (op == "pull" && aimLength < 1.0e-9)
        return 0;
    if (aimLength > 1.0e-9)
        aim = scale(aim, 1.0 / aimLength);
    // Smoothing works from neighbour averages, so it cannot be one vertex at a time.
    if (op == "smooth")
    {
        auto weights = new double[mesh.vertices.length];
        foreach (index, weight; selection.weights)
            weights[selection.vertices[index]] = weight;
        auto sums = new Vec3[mesh.vertices.length];
        auto counts = new int[mesh.vertices.length];
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
        foreach (index; selection.vertices)
        {
            if (counts[index] == 0)
                continue;
            const average = scale(sums[index], 1.0 / counts[index]);
            const t = clamp01(amount) * weights[index];
            const delta = sub(average, mesh.vertices[index]);
            mesh.vertices[index] = add(mesh.vertices[index], scale(delta, t));
        }
        computeSmoothNormals(mesh);
        return selection.count();
    }
    foreach (slot, index; selection.vertices)
    {
        const weight = selection.weights[slot];
        const vertex = mesh.vertices[index];
        if (op == "inflate")
            mesh.vertices[index] = add(vertex,
                scale(mesh.normals[index], amount * weight));
        else if (op == "pull")
            mesh.vertices[index] = add(vertex, scale(aim, amount * weight));
        else if (op == "flatten")
        {
            const centroid = scale(add(region.a, region.b), 0.5);
            const offset = dot(sub(vertex, centroid), aim);
            mesh.vertices[index] = sub(vertex,
                scale(aim, offset * clamp01(amount) * weight));
        }
        else if (op == "pinch")
        {
            const centroid = scale(add(region.a, region.b), 0.5);
            const outward = sub(vertex, centroid);
            const distance = length(outward);
            if (distance > 1.0e-9)
                mesh.vertices[index] = sub(vertex,
                    scale(normalize(outward),
                        distance * clamp01(amount) * weight));
        }
    }
    computeSmoothNormals(mesh);
    return selection.count();
}

unittest
{
    Mesh mesh;
    foreach (x; 0 .. 6)
        foreach (y; 0 .. 6)
            mesh.vertices ~= Vec3(x * 0.1, y * 0.1, 0);
    for (int y = 0; y < 5; ++y)
        for (int x = 0; x < 5; ++x)
        {
            const a = y * 6 + x;
            mesh.addQuad(a, a + 1, a + 7, a + 6, 0);
        }
    computeSmoothNormals(mesh);

    RegionVolume box;
    box.kind = RegionKind.box;
    box.a = Vec3(0.1, 0.1, -0.1);
    box.b = Vec3(0.3, 0.3, 0.1);
    const selection = selectRegion(mesh, box);
    assert(selection.count() > 0, "the box must select vertices");
    assert(selection.fullVertices > 0, "vertices well inside must be fully masked");
    assert(selection.count() > selection.fullVertices,
        "the rim band must add partially masked vertices");

    // A mask fades: a vertex on the rim is weighted less than one at the centre.
    double rim;
    double middle;
    foreach (slot, index; selection.vertices)
    {
        const vertex = mesh.vertices[index];
        if (abs(vertex.x - 0.2) < 0.05 && abs(vertex.y - 0.2) < 0.05)
            middle = selection.weights[slot];
        if (abs(vertex.x - 0.3) < 0.051 && abs(vertex.y - 0.3) < 0.051)
            rim = selection.weights[slot];
    }
    assert(middle >= rim);

    // Deformation only moves the selection, and is weighted by the mask.
    auto moved = mesh.vertices.dup;
    const count = deformRegion(mesh, box, "pull", 0.05, Vec3(0, 0, 1));
    assert(count > 0);
    bool changed;
    foreach (slot, index; selection.vertices)
    {
        const delta = sub(mesh.vertices[index], moved[index]);
        assert(length(delta) <= 0.051, "a pull must not exceed the amount");
        if (length(delta) > 1.0e-9)
            changed = true;
    }
    assert(changed);
    foreach (index, vertex; mesh.vertices)
        if (!selection.vertices.length)
            break;
    // Untouched vertices stay exactly where they were.
    auto outside = new bool[mesh.vertices.length];
    foreach (index; selection.vertices)
        outside[index] = true;
    foreach (index, vertex; mesh.vertices)
        if (!outside[index])
            assert(vertex.x == moved[index].x && vertex.y == moved[index].y &&
                vertex.z == moved[index].z);

    assert(deformRegion(mesh, box, "smooth", 0.5) > 0);
    assert(deformRegion(mesh, box, "inflate", 0.01) > 0);
    assert(deformRegion(mesh, box, "flatten", 0.5, Vec3(0, 1, 0)) > 0);
    assert(deformRegion(mesh, box, "pinch", 0.2) > 0);
    foreach (vertex; mesh.vertices)
        assert(isFinite(vertex.x) && isFinite(vertex.y) && isFinite(vertex.z));
}
