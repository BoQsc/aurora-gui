module auroramesh.edit;

import auroramesh.camera : Camera, Projected, project;
import auroramesh.mesh : Mesh, Vec3, add, dot, scale;
import std.math : abs;

/** Nearest projected vertex in viewport pixels, or -1. */
int pickNearest(const Mesh mesh, const Camera camera, int width, int height,
    double x, double y, double maxDistance = 14.0)
{
    int best = -1;
    double bestDistance = maxDistance;
    foreach (index, vertex; mesh.vertices)
    {
        const point = project(vertex, camera, width, height);
        if (!point.visible)
            continue;
        const distance = abs(point.x - x) + abs(point.y - y);
        if (distance < bestDistance)
        {
            bestDistance = distance;
            best = cast(int) index;
        }
    }
    return best;
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

unittest
{
    auto mesh = Mesh();
    const a = mesh.addVertex(Vec3(-0.4, -0.3, 0));
    const b = mesh.addVertex(Vec3(0.4, -0.3, 0));
    const c = mesh.addVertex(Vec3(0.0, 0.5, 0));
    mesh.addTriangle(a, b, c, 0);

    auto camera = Camera();
    camera.target = Vec3(0, 0, 0);
    camera.distance = 2.0;
    const projected = project(mesh.vertices[a], camera, 800, 600);
    assert(projected.visible);
    assert(pickNearest(mesh, camera, 800, 600, projected.x, projected.y) == a);
    assert(pickNearest(mesh, camera, 800, 600, -100, -100) == -1);

    const free = screenDelta(camera, 600, 12, 7, 0);
    assert(abs(free.x) + abs(free.y) + abs(free.z) > 0);
    const xOnly = screenDelta(camera, 600, 12, 7, 1);
    assert(xOnly.y == 0 && xOnly.z == 0);
    const yOnly = screenDelta(camera, 600, 12, 7, 2);
    assert(yOnly.x == 0 && yOnly.z == 0);
    const zOnly = screenDelta(camera, 600, 12, 7, 3);
    assert(zOnly.x == 0 && zOnly.y == 0);
}
