module auroramesh.camera;

import auroramesh.mesh : Vec3, add, cross, dot, length, normalize, scale, sub;
import std.math : PI, abs, cos, exp, isFinite, sin, sqrt, tan;

/** Camera depth below which geometry is clipped against the near plane. */
enum double NearPlane = 0.04;

struct Camera
{
    Vec3 target = Vec3(0, 0.95, 0);
    double yaw = 0.32;
    double pitch = 0.12;
    double distance = 4.0;
    double fov = 42.0 * PI / 180.0;

    Vec3 eye() const
    {
        const horizontal = cos(pitch) * distance;
        return add(target, Vec3(sin(yaw) * horizontal, sin(pitch) * distance,
            cos(yaw) * horizontal));
    }

    Vec3 forward() const
    {
        return normalize(sub(target, eye()));
    }

    Vec3 right() const
    {
        auto result = normalize(cross(forward(), Vec3(0, 1, 0)));
        if (length(result) < 0.5)
            result = Vec3(1, 0, 0);
        return result;
    }

    Vec3 up() const
    {
        return normalize(cross(right(), forward()));
    }

    double worldPerPixel(int viewportHeight) const
    {
        if (viewportHeight <= 0)
            return 0.001;
        return 2.0 * tan(fov * 0.5) * distance / viewportHeight;
    }

    void orbit(double dx, double dy)
    {
        yaw += dx * 0.010;
        pitch = clamp(pitch + dy * 0.010, -1.35, 1.35);
    }

    void zoom(double wheel)
    {
        distance = clamp(distance * exp(-wheel * 0.12), 0.55, 30.0);
    }

    void pan(double dx, double dy, int viewportHeight)
    {
        const step = worldPerPixel(viewportHeight);
        target = sub(target, add(scale(right(), dx * step),
            scale(up(), -dy * step)));
    }

    void focus(Vec3 minimum, Vec3 maximum)
    {
        target = scale(add(minimum, maximum), 0.5);
        const size = sub(maximum, minimum);
        const radius = maxAbs(size.x, maxAbs(size.y, size.z)) * 0.5;
        distance = clamp(radius / tan(fov * 0.5) * 1.35, 1.0, 30.0);
    }

    void reset()
    {
        target = Vec3(0, 0.95, 0);
        yaw = 0.32;
        pitch = 0.12;
        distance = 4.0;
        fov = 42.0 * PI / 180.0;
    }
}

struct Projected
{
    double x;
    double y;
    double z;
    /// Camera-space right/up offsets before the perspective divide.
    double viewX;
    double viewY;
    bool visible;
}

Projected project(Vec3 point, const Camera camera, int width, int height)
{
    Projected result;
    const offset = sub(point, camera.eye());
    const depth = dot(offset, camera.forward());
    result.viewX = dot(offset, camera.right());
    result.viewY = dot(offset, camera.up());
    result.z = depth;
    if (depth <= NearPlane)
        return result;
    const focal = (height * 0.5) / tan(camera.fov * 0.5);
    result.x = width * 0.5 + result.viewX / depth * focal;
    result.y = height * 0.5 - result.viewY / depth * focal;
    result.visible = true;
    return result;
}

/// The camera basis, built once so a frame can project many points.
///
/// Each accessor on `Camera` derives the basis from yaw, pitch and distance, so
/// calling `project` per vertex rebuilt it five thousand times per frame.
struct CameraBasis
{
    Vec3 eye;
    Vec3 forward;
    Vec3 right;
    Vec3 up;
    double focal;
}

CameraBasis cameraBasis(const Camera camera, int height)
{
    CameraBasis basis;
    basis.eye = camera.eye();
    basis.forward = camera.forward();
    basis.right = camera.right();
    basis.up = camera.up();
    basis.focal = (height * 0.5) / tan(camera.fov * 0.5);
    return basis;
}

/// Project with a basis built once per frame; the arithmetic matches `project`.
Projected project(Vec3 point, const CameraBasis basis, int width, int height)
{
    Projected result;
    const offset = sub(point, basis.eye);
    const depth = dot(offset, basis.forward);
    result.viewX = dot(offset, basis.right);
    result.viewY = dot(offset, basis.up);
    result.z = depth;
    if (depth <= NearPlane)
        return result;
    result.x = width * 0.5 + result.viewX / depth * basis.focal;
    result.y = height * 0.5 - result.viewY / depth * basis.focal;
    result.visible = true;
    return result;
}

private double clamp(double value, double minimum, double maximum)
{
    if (value < minimum) return minimum;
    if (value > maximum) return maximum;
    return value;
}

private double maxAbs(double a, double b)
{
    return abs(a) > abs(b) ? abs(a) : abs(b);
}

unittest
{
    Camera camera;
    const center = project(camera.target, camera, 800, 600);
    assert(center.visible);
    assert(abs(center.x - 400.0) < 0.001);
    assert(abs(center.y - 300.0) < 0.001);
    assert(abs(dot(camera.forward(), camera.right())) < 1.0e-9);
    assert(abs(dot(camera.forward(), camera.up())) < 1.0e-9);
    const yaw = camera.yaw;
    camera.orbit(12, 0);
    assert(camera.yaw != yaw);
    const before = camera.distance;
    camera.zoom(-1);
    assert(camera.distance < before);
}
