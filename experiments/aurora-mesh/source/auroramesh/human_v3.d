module auroramesh.human_v3;

import auroramesh.decimate : decimateMesh;
import auroramesh.human_v2 : humanBaseMeshV2;
import auroramesh.mesh : Material, Mesh, Vec3, computeSmoothNormals,
    fillBoundaryHoles, meshEllipsoid = ellipsoid, meshMaximum, meshMinimum,
    validMesh, watertight;

/**
 * v3 keeps the organic v2 skin but decimates it to a game-like base-mesh
 * budget. The eyes are the only separate shells, as on a normal character
 * base.
 */
Mesh humanBaseMeshV3()
{
    auto mesh = decimateMesh(humanBaseMeshV2(), 12000);
    if (mesh.vertices.length == 0 || mesh.faces.length == 0)
        return humanBaseMeshV2();

    fillBoundaryHoles(mesh, Material.skin);

    meshEllipsoid(mesh, Vec3(0.033, 1.716, 0.094),
        0.015, 0.014, 0.011, 10, 5, Material.eye);
    meshEllipsoid(mesh, Vec3(-0.033, 1.716, 0.094),
        0.015, 0.014, 0.011, 10, 5, Material.eye);
    computeSmoothNormals(mesh);
    return mesh;
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
