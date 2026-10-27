module auroramesh.human_v2;

import auroramesh.mesh : Material, Mesh, Vec3, humanBaseMeshV1, meshMaximum,
    meshMinimum, validMesh, watertight;

import auroramesh.sdf : SdfField, SdfShape, ellipsoid, sphere, taper;
import auroramesh.surface_nets : surfaceNets;
import std.math : abs;

/** A single blended organic surface rather than intersecting primitives. */
Mesh humanBaseMeshV2()
{
    const field = humanField();
    auto mesh = surfaceNets(field, Vec3(-0.66, -0.035, -0.22),
        Vec3(0.66, 1.91, 0.30), 0.0125);
    if (mesh.vertices.length == 0 || mesh.faces.length == 0)
        return humanBaseMeshV1();

    foreach (ref face; mesh.faces)
    {
        const center = Vec3(
            (mesh.vertices[face.a].x + mesh.vertices[face.b].x +
                mesh.vertices[face.c].x) / 3.0,
            (mesh.vertices[face.a].y + mesh.vertices[face.b].y +
                mesh.vertices[face.c].y) / 3.0,
            (mesh.vertices[face.a].z + mesh.vertices[face.b].z +
                mesh.vertices[face.c].z) / 3.0);
        if (center.y > 1.56)
            face.material = Material.skin;
        else if (center.y < 0.16)
            face.material = Material.accent;
        else if (center.y < 0.90 && abs(center.x) > 0.43)
            face.material = Material.skin;
        else
            face.material = Material.cloth;
    }
    return mesh;
}

SdfField humanField()
{
    SdfField field;
    field.blend = 0.016;
    SdfShape[] shapes;

    // Ribcage, abdomen, pelvis, and glutes.
    shapes ~= ellipsoid(Vec3(0, 1.27, 0), Vec3(0.195, 0.225, 0.110));
    shapes ~= ellipsoid(Vec3(0, 1.07, 0.010), Vec3(0.145, 0.160, 0.095));
    shapes ~= ellipsoid(Vec3(0, 0.94, 0), Vec3(0.170, 0.120, 0.110));
    shapes ~= ellipsoid(Vec3(0, 0.92, -0.055), Vec3(0.150, 0.100, 0.095));

    // Neck and head masses.
    shapes ~= ellipsoid(Vec3(0, 1.49, 0), Vec3(0.100, 0.055, 0.075));
    shapes ~= taper(Vec3(0, 1.50, 0), Vec3(0, 1.63, 0), 0.066, 0.053);
    shapes ~= ellipsoid(Vec3(0, 1.72, 0), Vec3(0.083, 0.108, 0.092));
    shapes ~= ellipsoid(Vec3(0, 1.655, 0.025), Vec3(0.073, 0.078, 0.075));
    shapes ~= ellipsoid(Vec3(0, 1.605, 0.040), Vec3(0.042, 0.034, 0.040));
    shapes ~= ellipsoid(Vec3(0, 1.715, 0.070), Vec3(0.064, 0.020, 0.026));
    shapes ~= taper(Vec3(0, 1.700, 0.075), Vec3(0, 1.665, 0.112),
        0.016, 0.010);

    foreach (side; [-1.0, 1.0])
    {
        // Ears and cheekbones.
        shapes ~= ellipsoid(Vec3(0.086 * side, 1.700, 0.0),
            Vec3(0.016, 0.034, 0.024));
        shapes ~= ellipsoid(Vec3(0.050 * side, 1.675, 0.052),
            Vec3(0.034, 0.026, 0.030));
        shapes ~= ellipsoid(Vec3(0.078 * side, 1.690, 0.015),
            Vec3(0.026, 0.035, 0.030));

        // Pectorals and deltoids.
        shapes ~= ellipsoid(Vec3(0.070 * side, 1.330, 0.070),
            Vec3(0.085, 0.075, 0.045));
        // Fill the armpit crease so surface nets cannot pinch there.
        shapes ~= ellipsoid(Vec3(0.165 * side, 1.365, 0.035),
            Vec3(0.055, 0.045, 0.055));
        shapes ~= ellipsoid(Vec3(0.150 * side, 1.385, -0.045),
            Vec3(0.060, 0.050, 0.060));
        shapes ~= ellipsoid(Vec3(0.205 * side, 1.420, 0.0),
            Vec3(0.085, 0.090, 0.085));

        // Arm: upper arm, elbow, forearm, palm.
        const shoulder = Vec3(0.205 * side, 1.420, 0.0);
        const elbow = Vec3(0.390 * side, 1.170, 0.015);
        const wrist = Vec3(0.520 * side, 0.890, 0.040);
        shapes ~= taper(shoulder, elbow, 0.074, 0.052);
        shapes ~= ellipsoid(Vec3(0.295 * side, 1.295, 0.005),
            Vec3(0.055, 0.075, 0.050));
        shapes ~= ellipsoid(elbow, Vec3(0.052, 0.052, 0.052));
        shapes ~= taper(elbow, wrist, 0.049, 0.034);
        shapes ~= ellipsoid(Vec3(0.455 * side, 1.030, 0.025),
            Vec3(0.045, 0.065, 0.040));
        shapes ~= ellipsoid(Vec3(0.535 * side, 0.815, 0.045),
            Vec3(0.048, 0.062, 0.038));
        shapes ~= ellipsoid(Vec3(0.535 * side, 0.775, 0.045),
            Vec3(0.045, 0.035, 0.035));

        // Four fingers and a thumb; soft enough to remain a hand rather than
        // a set of separate sticks.
        foreach (finger; 0 .. 4)
        {
            const offset = -0.021 + finger * 0.014;
            const base = Vec3(0.535 * side + offset, 0.765, 0.045);
            const tip = Vec3(0.540 * side + offset * 1.1, 0.690, 0.045);
            shapes ~= taper(base, tip, 0.010, 0.007);
        }
        shapes ~= taper(Vec3(0.505 * side, 0.805, 0.065),
            Vec3(0.475 * side, 0.770, 0.075), 0.011, 0.008);
        shapes ~= ellipsoid(Vec3(0.495 * side, 0.785, 0.060),
            Vec3(0.032, 0.035, 0.032));

        // Leg: thigh, knee, calf, ankle, heel, forefoot.
        const hip = Vec3(0.095 * side, 0.910, 0.0);
        const knee = Vec3(0.115 * side, 0.510, 0.010);
        const ankle = Vec3(0.125 * side, 0.110, 0.015);
        const toe = Vec3(0.125 * side, 0.045, 0.140);
        shapes ~= taper(hip, knee, 0.105, 0.068);
        shapes ~= ellipsoid(Vec3(0.105 * side, 0.700, 0.025),
            Vec3(0.075, 0.115, 0.075));
        shapes ~= ellipsoid(knee, Vec3(0.060, 0.055, 0.060));
        shapes ~= taper(knee, ankle, 0.064, 0.038);
        shapes ~= ellipsoid(Vec3(0.120 * side, 0.320, -0.015),
            Vec3(0.052, 0.080, 0.052));
        // Unify the ankle and heel into one foot mass.
        shapes ~= ellipsoid(Vec3(0.125 * side, 0.095, 0.0),
            Vec3(0.065, 0.060, 0.070));
        shapes ~= ellipsoid(Vec3(0.125 * side, 0.060, -0.025),
            Vec3(0.050, 0.050, 0.055));
        shapes ~= taper(ankle, toe, 0.052, 0.038);
        shapes ~= ellipsoid(Vec3(0.125 * side, 0.040, 0.145),
            Vec3(0.065, 0.035, 0.085));
    }

    field.shapes = shapes;
    field.cuts = [
        sphere(Vec3(0.033, 1.716, 0.086), 0.019),
        sphere(Vec3(-0.033, 1.716, 0.086), 0.019),
        taper(Vec3(-0.030, 1.635, 0.086), Vec3(0.030, 1.635, 0.086),
            0.0045, 0.0045),
    ];
    return field;
}

unittest
{
    auto mesh = humanBaseMeshV2();
    assert(validMesh(mesh));
    assert(mesh.faces.length > 2000);
    assert(mesh.normals.length == mesh.vertices.length);
    assert(watertight(mesh));
    const minimum = meshMinimum(mesh);
    const maximum = meshMaximum(mesh);
    assert(maximum.y - minimum.y > 1.70);
}
