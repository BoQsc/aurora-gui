module auroramesh.sdf;

import auroramesh.mesh : Vec3, add, dot, length, normalize, scale, sub;
import std.algorithm : max, min;
import std.math : abs, sqrt;

enum SdfKind : ubyte
{
    sphere,
    ellipsoid,
    taper,
    plane,
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

/**
 * Half space below a plane through `point` facing `normal`.
 *
 * As a cut this trims a solid flat, which is what a sole is; a sphere or ellipsoid
 * cut grazes the surface at a shallow angle and leaves a flap behind.
 */
SdfShape plane(Vec3 point, Vec3 normal)
{
    const unit = normalize(normal);
    return SdfShape(SdfKind.plane, unit, point, 0, 0, Vec3(0, 0, 0));
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

        case SdfKind.plane:
            // shape.a holds the normal, shape.b a point on the plane.
            return dot(sub(point, shape.b), shape.a);
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

    /**
     * Axis-aligned extent of the field's solid, grown by the blend radius.
     *
     * Meshing uses this rather than an outside box: a field that reaches past the
     * box it is sampled in gets clipped open, which reads as a hole.
     */
    void bounds(out Vec3 low, out Vec3 high) const
    {
        low = Vec3(0, 0, 0);
        high = Vec3(0, 0, 0);
        bool any;
        foreach (shape; shapes)
        {
            Vec3 localLow = Vec3(0, 0, 0);
            Vec3 localHigh = Vec3(0, 0, 0);
            final switch (shape.kind)
            {
                case SdfKind.sphere:
                    localLow = Vec3(shape.a.x - shape.radius,
                        shape.a.y - shape.radius, shape.a.z - shape.radius);
                    localHigh = Vec3(shape.a.x + shape.radius,
                        shape.a.y + shape.radius, shape.a.z + shape.radius);
                    break;

                case SdfKind.ellipsoid:
                    localLow = Vec3(shape.a.x - abs(shape.radii.x),
                        shape.a.y - abs(shape.radii.y),
                        shape.a.z - abs(shape.radii.z));
                    localHigh = Vec3(shape.a.x + abs(shape.radii.x),
                        shape.a.y + abs(shape.radii.y),
                        shape.a.z + abs(shape.radii.z));
                    break;

                case SdfKind.taper:
                    const reach = max(shape.radius, shape.endRadius);
                    localLow = Vec3(min(shape.a.x, shape.b.x) - reach,
                        min(shape.a.y, shape.b.y) - reach,
                        min(shape.a.z, shape.b.z) - reach);
                    localHigh = Vec3(max(shape.a.x, shape.b.x) + reach,
                        max(shape.a.y, shape.b.y) + reach,
                        max(shape.a.z, shape.b.z) + reach);
                    break;

                case SdfKind.plane:
                    // A half space has no finite extent, so it cannot widen a box.
                    continue;
            }
            if (!any)
            {
                low = localLow;
                high = localHigh;
                any = true;
            }
            else
            {
                low = Vec3(min(low.x, localLow.x), min(low.y, localLow.y),
                    min(low.z, localLow.z));
                high = Vec3(max(high.x, localHigh.x), max(high.y, localHigh.y),
                    max(high.z, localHigh.z));
            }
        }
        const pad = blend > 0 ? blend : 0.0;
        low = Vec3(low.x - pad, low.y - pad, low.z - pad);
        high = Vec3(high.x + pad, high.y + pad, high.z + pad);
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

    // The meshing box must cover the field, including the blend.
    Vec3 low;
    Vec3 high;
    field.bounds(low, high);
    assert(low.x <= -1.0 && high.x >= 3.0, "bounds must span every shape");
    assert(low.y <= -1.0 && high.y >= 1.0);
    assert(high.x - low.x >= 4.0);
}
