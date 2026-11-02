module auroramesh.edit;

import auroramesh.camera : Camera, Projected, project;
import auroramesh.mesh : Material, Mesh, Vec3, add, cross, dot, length, scale,
    sub;
import std.algorithm : max, sort;
import std.math : abs, tan;

/**
 * Nearest projected vertex in viewport pixels, or -1. Vertices hidden behind
 * other geometry are skipped, so clicking the front of a body selects the
 * front vertex instead of one on the far side.
 */
int pickNearest(const Mesh mesh, const Camera camera, int width, int height,
    double x, double y, double maxDistance = 14.0)
{
    struct Candidate
    {
        double distance;
        double depth;
        int index;
    }

    Candidate[] candidates;
    foreach (index, vertex; mesh.vertices)
    {
        const point = project(vertex, camera, width, height);
        if (!point.visible)
            continue;
        const distance = abs(point.x - x) + abs(point.y - y);
        if (distance < maxDistance)
            candidates ~= Candidate(distance, point.z, cast(int) index);
    }
    if (candidates.length == 0)
        return -1;
    candidates.sort!((a, b) => a.distance < b.distance ||
        (a.distance == b.distance && a.index < b.index));

    const eye = camera.eye();
    foreach (candidate; candidates)
        if (!vertexOccluded(mesh, eye, candidate.index))
            return candidate.index;
    // Grazing geometry can hide every candidate; fall back to the shallowest
    // one so a click on a thin or edge-on feature still selects a vertex.
    auto shallowest = candidates[0];
    foreach (candidate; candidates[1 .. $])
        if (candidate.depth < shallowest.depth)
            shallowest = candidate;
    return shallowest.index;
}

/** True when a face other than the vertex's own stands between it and the eye. */
bool vertexOccluded(const Mesh mesh, Vec3 eye, int vertex,
    double epsilon = 0.002)
{
    if (vertex < 0 || vertex >= mesh.vertices.length)
        return false;
    const direction = sub(mesh.vertices[vertex], eye);
    if (length(direction) <= 1.0e-9)
        return false;
    foreach (face; mesh.faces)
    {
        if (face.a == vertex || face.b == vertex || face.c == vertex)
            continue;
        if (segmentHitsTriangle(eye, direction, mesh.vertices[face.a],
            mesh.vertices[face.b], mesh.vertices[face.c], epsilon))
            return true;
    }
    return false;
}

/**
 * Camera depth of the closest surface under a viewport pixel, or -1 when the
 * ray misses the mesh. Used to keep a brush stroke on the visible surface.
 */
double surfaceDepthAt(const Mesh mesh, const Camera camera, int width,
    int height, double x, double y)
{
    const focal = (max(1, height) * 0.5) / tan(camera.fov * 0.5);
    const eye = camera.eye();
    const direction = add(
        add(scale(camera.forward(), focal),
            scale(camera.right(), x - width * 0.5)),
        scale(camera.up(), height * 0.5 - y));
    double nearest = -1;
    foreach (face; mesh.faces)
    {
        const t = rayHitsTriangle(eye, direction, mesh.vertices[face.a],
            mesh.vertices[face.b], mesh.vertices[face.c]);
        if (t < 0)
            continue;
        const depth = t * focal;
        if (nearest < 0 || depth < nearest)
            nearest = depth;
    }
    return nearest;
}

/**
 * Vertices inside the brush disc that belong to the visible surface. Vertices
 * deeper than the surface under the brush center are dropped, so a stroke on
 * the chest no longer deforms the back of the torso.
 */
int[] brushVertices(const Mesh mesh, const Camera camera, int width, int height,
    double x, double y, double radius)
{
    int[] selected;
    if (mesh.vertices.length == 0)
        return selected;
    const surfaceDepth = surfaceDepthAt(mesh, camera, width, height, x, y);
    // Curvature across the brush disc plus a small relative allowance.
    const tolerance = surfaceDepth < 0 ? 0 :
        max(radius * camera.worldPerPixel(height) * 3.0, surfaceDepth * 0.02);
    const limit = surfaceDepth < 0 ? -1 : surfaceDepth + tolerance;

    struct Candidate
    {
        double depth;
        int index;
    }

    Candidate[] candidates;
    foreach (index, vertex; mesh.vertices)
    {
        const point = project(vertex, camera, width, height);
        if (!point.visible)
            continue;
        const dx = point.x - x;
        const dy = point.y - y;
        if (dx * dx + dy * dy > radius * radius)
            continue;
        if (limit >= 0 && point.z > limit)
            continue;
        candidates ~= Candidate(point.z, cast(int) index);
    }
    if (candidates.length == 0)
        return selected;
    candidates.sort!((a, b) => a.depth < b.depth ||
        (a.depth == b.depth && a.index < b.index));
    selected.length = candidates.length;
    foreach (offset, candidate; candidates)
        selected[offset] = candidate.index;
    return selected;
}

/**
 * Convert a screen-space drag into a camera-plane world movement.
 * axis: 0 = free, 1 = X, 2 = Y, 3 = Z.
 */
Vec3 screenDelta(const Camera camera, int viewportHeight, double dx, double dy,
    int axis)
{
    const step = camera.worldPerPixel(viewportHeight);
    auto offset = add(scale(camera.right(), dx * step),
        scale(camera.up(), -dy * step));
    final switch (axis)
    {
        case 0:
            break;
        case 1:
            offset = scale(Vec3(1, 0, 0), dot(offset, Vec3(1, 0, 0)));
            break;
        case 2:
            offset = scale(Vec3(0, 1, 0), dot(offset, Vec3(0, 1, 0)));
            break;
        case 3:
            offset = scale(Vec3(0, 0, 1), dot(offset, Vec3(0, 0, 1)));
            break;
    }
    return offset;
}

/** Moller-Trumbore segment/triangle test. Returns true for 0 < t < 1 - eps. */
private bool segmentHitsTriangle(Vec3 origin, Vec3 direction, Vec3 a, Vec3 b,
    Vec3 c, double epsilon)
{
    const t = rayHitsTriangle(origin, direction, a, b, c);
    return t > epsilon && t < 1 - epsilon;
}

/** Ray parameter of the first triangle hit, or -1. */
private double rayHitsTriangle(Vec3 origin, Vec3 direction, Vec3 a, Vec3 b,
    Vec3 c)
{
    const edge1 = sub(b, a);
    const edge2 = sub(c, a);
    const h = cross(direction, edge2);
    const determinant = dot(edge1, h);
    if (abs(determinant) < 1.0e-12)
        return -1;
    const inverse = 1.0 / determinant;
    const s = sub(origin, a);
    const u = dot(s, h) * inverse;
    if (u < 0 || u > 1)
        return -1;
    const q = cross(s, edge1);
    const v = dot(direction, q) * inverse;
    if (v < 0 || u + v > 1)
        return -1;
    const t = dot(edge2, q) * inverse;
    return t > 1.0e-9 ? t : -1;
}

/** Camera at +Z looking down -Z, so screen depth grows away from the viewer. */
private Camera flatCamera()
{
    auto camera = Camera();
    camera.target = Vec3(0, 0, 0);
    camera.yaw = 0;
    camera.pitch = 0;
    camera.distance = 3.0;
    return camera;
}

private int quad(ref Mesh mesh, double z, double half)
{
    const base = cast(int) mesh.vertices.length;
    mesh.vertices ~= Vec3(-half, -half, z);
    mesh.vertices ~= Vec3(half, -half, z);
    mesh.vertices ~= Vec3(half, half, z);
    mesh.vertices ~= Vec3(-half, half, z);
    mesh.addQuad(base, base + 1, base + 2, base + 3, Material.neutral);
    return base;
}

unittest
{
    auto mesh = Mesh();
    const a = mesh.addVertex(Vec3(-0.4, -0.3, 0));
    const b = mesh.addVertex(Vec3(0.4, -0.3, 0));
    const c = mesh.addVertex(Vec3(0.0, 0.5, 0));
    mesh.addTriangle(a, b, c, 0);

    auto camera = flatCamera();
    const projected = project(mesh.vertices[a], camera, 800, 600);
    assert(projected.visible);
    assert(pickNearest(mesh, camera, 800, 600, projected.x, projected.y) == a);
    assert(pickNearest(mesh, camera, 800, 600, -100, -100) == -1);

    // A near quad hides a far one that projects closer to the cursor center.
    auto layered = Mesh();
    const nearBase = quad(layered, 1.0, 0.2);
    const farBase = quad(layered, -1.0, 0.2);
    const centerX = 200.0;
    const centerY = 150.0;
    const near = pickNearest(layered, camera, 400, 300, centerX, centerY);
    assert(near >= nearBase && near < nearBase + 4,
        "picked a hidden back vertex");
    assert(!vertexOccluded(layered, camera.eye(), nearBase));
    assert(vertexOccluded(layered, camera.eye(), farBase));

    const depth = surfaceDepthAt(layered, camera, 400, 300, centerX, centerY);
    assert(abs(depth - 2.0) < 0.05, "surface depth should be the near quad");
    assert(surfaceDepthAt(layered, camera, 400, 300, -20, -20) < 0);

    const brushed = brushVertices(layered, camera, 400, 300, centerX, centerY,
        40);
    assert(brushed.length == 4, "brush must stay on the visible surface");
    foreach (index; brushed)
        assert(index >= nearBase && index < nearBase + 4);

    // When every candidate is hidden, the shallowest one still wins so thin or
    // edge-on features stay selectable.
    auto shielded = Mesh();
    const backBase = quad(shielded, 0.0, 0.05);
    quad(shielded, 2.5, 0.5);
    const fallback = pickNearest(shielded, camera, 400, 300, centerX, centerY);
    assert(fallback >= backBase && fallback < backBase + 4,
        "fallback must pick the shallowest hidden vertex");

    const free = screenDelta(camera, 600, 12, 7, 0);
    assert(abs(free.x) + abs(free.y) + abs(free.z) > 0);
    const xOnly = screenDelta(camera, 600, 12, 7, 1);
    assert(xOnly.y == 0 && xOnly.z == 0);
    const yOnly = screenDelta(camera, 600, 12, 7, 2);
    assert(yOnly.x == 0 && yOnly.z == 0);
    const zOnly = screenDelta(camera, 600, 12, 7, 3);
    assert(zOnly.x == 0 && zOnly.y == 0);
}

/**
 * Move the vertices near a world point along a direction with a smooth falloff.
 *
 * This is the document-side brush: the mouse selects with `brushVertices`, but a
 * stroke that has to survive a rebuild needs a world address and no camera, so the
 * same falloff is applied around a point instead of a pixel.
 */
int brushWorld(ref Mesh mesh, Vec3 center, double radius, Vec3 direction,
    double amount)
{
    if (!(radius > 0) || amount == 0 || mesh.vertices.length == 0)
        return 0;
    const aim = length(direction);
    if (!(aim > 0))
        return 0;
    const step = scale(direction, amount / aim);
    int moved;
    foreach (ref vertex; mesh.vertices)
    {
        const offset = sub(vertex, center);
        const distance = length(offset);
        if (distance >= radius)
            continue;
        const falloff = 1.0 - distance / radius;
        vertex = add(vertex, scale(step, falloff * falloff));
        ++moved;
    }
    return moved;
}

unittest
{
    // The brush must move what is under it, leave the rest alone, and fade towards
    // the rim: a hard edge at the rim would show as a crease on the surface.
    auto mesh = Mesh();
    foreach (x; 0 .. 5)
        mesh.addVertex(Vec3(x * 0.01, 0, 0));
    const base = mesh.vertices[0];
    const moved = brushWorld(mesh, Vec3(0, 0, 0), 0.03, Vec3(0, 1, 0), 0.01);
    assert(moved == 3, "only the vertices under the brush may move");
    assert(mesh.vertices[0].y > 0.009, "the centre takes the full amount");
    assert(mesh.vertices[1].y > 0 && mesh.vertices[1].y < mesh.vertices[0].y,
        "the falloff must fade towards the rim");
    assert(mesh.vertices[2].y > 0 && mesh.vertices[2].y < mesh.vertices[1].y);
    assert(mesh.vertices[3] == base + Vec3(0.03, 0, 0),
        "a vertex outside the brush must not move");
    assert(brushWorld(mesh, Vec3(0, 0, 0), 0.0, Vec3(0, 1, 0), 0.01) == 0);
}

/**
 * Relax the vertices near a point towards their neighbours, with the same falloff.
 *
 * Pushing a surface with a brush leaves a crease where the stroke stops; relaxing it
 * is what removes that, so the two modes belong together.
 */
int smoothWorld(ref Mesh mesh, Vec3 center, double radius, double amount,
    int passes = 1)
{
    if (!(radius > 0) || !(amount > 0) || mesh.vertices.length == 0 || passes <= 0)
        return 0;
    // Neighbour positions per vertex, from the faces.
    Vec3[][] rings;
    rings.length = mesh.vertices.length;
    foreach (face; mesh.faces)
    {
        rings[face.a] ~= mesh.vertices[face.b];
        rings[face.a] ~= mesh.vertices[face.c];
        rings[face.b] ~= mesh.vertices[face.a];
        rings[face.b] ~= mesh.vertices[face.c];
        rings[face.c] ~= mesh.vertices[face.a];
        rings[face.c] ~= mesh.vertices[face.b];
    }
    int moved;
    foreach (pass; 0 .. passes)
    {
        Vec3[] relaxed;
        relaxed.length = mesh.vertices.length;
        foreach (index, vertex; mesh.vertices)
        {
            relaxed[index] = vertex;
            const offset = sub(vertex, center);
            const distance = length(offset);
            if (distance >= radius || rings[index].length == 0)
                continue;
            auto average = Vec3(0, 0, 0);
            foreach (neighbour; rings[index])
                average = add(average, neighbour);
            average = scale(average, 1.0 / rings[index].length);
            const falloff = 1.0 - distance / radius;
            const weight = amount * falloff * falloff;
            relaxed[index] = add(vertex, scale(sub(average, vertex), weight));
        }
        mesh.vertices = relaxed;
        moved += cast(int) mesh.vertices.length;
    }
    return moved;
}

unittest
{
    // A spike must be pulled towards its neighbours, and a vertex outside the brush
    // must stay exactly where it is.
    auto mesh = Mesh();
    const left = mesh.addVertex(Vec3(-0.02, 0, 0));
    const right = mesh.addVertex(Vec3(0.02, 0, 0));
    const spike = mesh.addVertex(Vec3(0.0, 0.05, 0));
    const far = mesh.addVertex(Vec3(1.0, 0, 0));
    mesh.addTriangle(left, spike, right, 0);
    const before = mesh.vertices[spike];
    const farBefore = mesh.vertices[far];
    assert(smoothWorld(mesh, before, 0.05, 0.5) == 4);
    assert(mesh.vertices[spike].y < before.y, "the spike must be relaxed");
    assert(mesh.vertices[far] == farBefore, "outside the brush nothing moves");
}
