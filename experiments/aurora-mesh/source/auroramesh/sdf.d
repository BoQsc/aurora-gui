module auroramesh.sdf;

import auroramesh.mesh : Vec3, add, dot, length, normalize, scale, sub;
import std.algorithm : max, min;
import std.math : abs, sqrt;

enum SdfKind : ubyte
{
    sphere,
    ellipsoid,
    taper,
}

struct SdfShape
{
    SdfKind kind;
    Vec3 a;
    Vec3 b;
    double radius;
    double endRadius;
    Vec3 radii;
}

SdfShape sphere(Vec3 center, double radius)
{
    return SdfShape(SdfKind.sphere, center, center, radius, radius,
        Vec3(radius, radius, radius));
}

SdfShape ellipsoid(Vec3 center, Vec3 radii)
{
    return SdfShape(SdfKind.ellipsoid, center, center,
        min(radii.x, min(radii.y, radii.z)),
        min(radii.x, min(radii.y, radii.z)), radii);
}

SdfShape taper(Vec3 a, Vec3 b, double startRadius, double endRadius)
{
    return SdfShape(SdfKind.taper, a, b, startRadius, endRadius,
        Vec3(startRadius, startRadius, startRadius));
}

double sdfShape(const SdfShape shape, Vec3 point)
{
    final switch (shape.kind)
    {
        case SdfKind.sphere:
            return length(sub(point, shape.a)) - shape.radius;

        case SdfKind.ellipsoid:
            const qx = (point.x - shape.a.x) / shape.radii.x;
            const qy = (point.y - shape.a.y) / shape.radii.y;
            const qz = (point.z - shape.a.z) / shape.radii.z;
            return (sqrt(qx * qx + qy * qy + qz * qz) - 1.0) *
                shape.radius;

        case SdfKind.taper:
            const segment = sub(shape.b, shape.a);
            const denominator = dot(segment, segment);
            const h = denominator <= 1.0e-12 ? 0.0 :
                clamp01(dot(sub(point, shape.a), segment) / denominator);
            const center = add(shape.a, scale(segment, h));
            const radius = shape.radius +
                (shape.endRadius - shape.radius) * h;
            return length(sub(point, center)) - radius;
    }
}

struct SdfField
{
    SdfShape[] shapes;
    SdfShape[] cuts;
    double blend = 0.018;

    double eval(Vec3 point) const
    {
        if (shapes.length == 0)
            return 1.0;
        auto distance = sdfShape(shapes[0], point);
        foreach (index; 1 .. shapes.length)
            distance = smoothMinimum(distance,
                sdfShape(shapes[index], point), blend);
        foreach (cut; cuts)
            distance = smoothMaximum(distance, -sdfShape(cut, point),
                blend * 0.5);
        return distance;
    }
}

double smoothMinimum(double a, double b, double blend)
{
    if (blend <= 0)
        return min(a, b);
    const h = clamp01(0.5 + 0.5 * (b - a) / blend);
    return b * (1.0 - h) + a * h - blend * h * (1.0 - h);
}

double smoothMaximum(double a, double b, double blend)
{
    return -smoothMinimum(-a, -b, blend);
}

private double clamp01(double value)
{
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
}

unittest
{
    const ball = sphere(Vec3(0, 0, 0), 1.0);
    assert(sdfShape(ball, Vec3(0, 0, 0)) < 0);
    assert(abs(sdfShape(ball, Vec3(1, 0, 0))) < 1.0e-9);
    assert(sdfShape(ball, Vec3(2, 0, 0)) > 0);

    SdfField field;
    field.shapes = [ball, sphere(Vec3(2, 0, 0), 1.0)];
    field.blend = 0.2;
    assert(field.eval(Vec3(1, 0, 0)) < 0);
    assert(field.eval(Vec3(1, 3, 0)) > 0);
}
