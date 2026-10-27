module auroramesh.human_v3;

import auroramesh.human_v2 : humanBaseMeshV2;
import auroramesh.mesh : Material, Mesh, Vec3, computeSmoothNormals,
    meshMaximum, meshMinimum, parseObj, validMesh, watertight;
import std.math : PI, cos, sin;

/**
 * v3 is a natural T-pose body at a game-like triangle budget. The source
 * body was taken from the user-provided CC0 Human.AK47.r12 reference,
 * separated from clothing/gear, welded, and topology-repaired by our own
 * pipeline. Eyes are the only separate shells.
 */
private enum string V3_BODY_OBJ = import("human_v3.obj");

Mesh humanBaseMeshV3()
{
    auto mesh = parseObj(V3_BODY_OBJ);
    if (mesh.vertices.length == 0 || mesh.faces.length == 0)
        return humanBaseMeshV2();

    foreach (ref face; mesh.faces)
        face.material = Material.skin;

    addEye(mesh, Vec3(0.0305, 1.682, 0.080));
    addEye(mesh, Vec3(-0.0305, 1.682, 0.080));
    computeSmoothNormals(mesh);
    return mesh;
}

private void addEye(ref Mesh mesh, Vec3 center)
{
    const int segments = 8;
    const int rings = 4;
    const double rx = 0.014;
    const double ry = 0.012;
    const double rz = 0.012;
    const int top = mesh.addVertex(Vec3(center.x, center.y + ry, center.z));
    int[][] rows;
    rows.length = rings - 1;
    foreach (ring; 1 .. rings)
    {
        const theta = PI * ring / rings;
        const ringRadius = sin(theta);
        rows[ring - 1].length = segments;
        foreach (segment; 0 .. segments)
        {
            const angle = 2 * PI * segment / segments;
            rows[ring - 1][segment] = mesh.addVertex(Vec3(
                center.x + cos(angle) * ringRadius * rx,
                center.y + cos(theta) * ry,
                center.z + sin(angle) * ringRadius * rz));
        }
    }
    const int bottom = mesh.addVertex(Vec3(center.x, center.y - ry,
        center.z));
    foreach (segment; 0 .. segments)
    {
        const next = (segment + 1) % segments;
        mesh.addTriangle(top, rows[0][segment], rows[0][next],
            Material.eye);
    }
    foreach (ring; 0 .. rows.length - 1)
        foreach (segment; 0 .. segments)
        {
            const next = (segment + 1) % segments;
            mesh.addQuad(rows[ring][segment], rows[ring + 1][segment],
                rows[ring + 1][next], rows[ring][next], Material.eye);
        }
    foreach (segment; 0 .. segments)
    {
        const next = (segment + 1) % segments;
        mesh.addTriangle(bottom, rows[$ - 1][next], rows[$ - 1][segment],
            Material.eye);
    }
}

unittest
{
    auto mesh = humanBaseMeshV3();
    assert(validMesh(mesh));
    assert(mesh.faces.length <= 10000);
    assert(mesh.normals.length == mesh.vertices.length);
    assert(watertight(mesh));
    const minimum = meshMinimum(mesh);
    const maximum = meshMaximum(mesh);
    assert(maximum.y - minimum.y > 1.70);
}
