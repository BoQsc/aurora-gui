module auroramesh.surface_nets;

import auroramesh.mesh : Mesh, Material, Vec3, add, computeSmoothNormals, cross,
    dot, length, lerp, normalize, scale, sub, watertight;
import auroramesh.sdf : SdfField;
import std.algorithm : max, min;
import std.math : ceil;

private immutable int[] CornerX = [0, 1, 1, 0, 0, 1, 1, 0];
private immutable int[] CornerY = [0, 0, 1, 1, 0, 0, 1, 1];
private immutable int[] CornerZ = [0, 0, 0, 0, 1, 1, 1, 1];
private immutable int[] EdgeA = [0, 1, 3, 2, 4, 5, 7, 6, 0, 1, 2, 3];
private immutable int[] EdgeB = [1, 3, 2, 0, 5, 7, 6, 4, 4, 5, 6, 7];

/**
 * Extract a closed quad/triangle surface from a signed-distance field with
 * naive surface nets. This produces one connected organic skin instead of a
 * collection of intersecting primitives.
 */
Mesh surfaceNets(const SdfField field, Vec3 minimum, Vec3 maximum, double cell)
{
    const nx = cast(int) ceil((maximum.x - minimum.x) / cell) + 1;
    const ny = cast(int) ceil((maximum.y - minimum.y) / cell) + 1;
    const nz = cast(int) ceil((maximum.z - minimum.z) / cell) + 1;
    if (nx < 3 || ny < 3 || nz < 3)
        return Mesh();

    auto values = new double[nx * ny * nz];
    foreach (k; 0 .. nz)
    {
        const z = minimum.z + k * cell;
        foreach (j; 0 .. ny)
        {
            const y = minimum.y + j * cell;
            foreach (i; 0 .. nx)
            {
                const x = minimum.x + i * cell;
                values[(k * ny + j) * nx + i] = field.eval(Vec3(x, y, z));
            }
        }
    }

    const cellsX = nx - 1;
    const cellsY = ny - 1;
    const cellsZ = nz - 1;
    auto cellVertex = new int[cellsX * cellsY * cellsZ];
    foreach (ref value; cellVertex)
        value = -1;

    Mesh mesh;
    double[8] corner;
    foreach (k; 0 .. cellsZ)
    {
        foreach (j; 0 .. cellsY)
        {
            foreach (i; 0 .. cellsX)
            {
                bool hasInside;
                bool hasOutside;
                foreach (cornerIndex; 0 .. 8)
                {
                    const gx = i + CornerX[cornerIndex];
                    const gy = j + CornerY[cornerIndex];
                    const gz = k + CornerZ[cornerIndex];
                    const value = values[(gz * ny + gy) * nx + gx];
                    corner[cornerIndex] = value;
                    if (value < 0)
                        hasInside = true;
                    else
                        hasOutside = true;
                }
                if (!hasInside || !hasOutside)
                    continue;

                Vec3 sum = Vec3(0, 0, 0);
                int crossingCount;
                foreach (edge; 0 .. 12)
                {
                    const first = EdgeA[edge];
                    const second = EdgeB[edge];
                    const a = corner[first];
                    const b = corner[second];
                    if ((a < 0) == (b < 0))
                        continue;
                    const t = a / (a - b);
                    const p0 = Vec3(
                        minimum.x + (i + CornerX[first]) * cell,
                        minimum.y + (j + CornerY[first]) * cell,
                        minimum.z + (k + CornerZ[first]) * cell);
                    const p1 = Vec3(
                        minimum.x + (i + CornerX[second]) * cell,
                        minimum.y + (j + CornerY[second]) * cell,
                        minimum.z + (k + CornerZ[second]) * cell);
                    sum = add(sum, lerp(p0, p1, t));
                    ++crossingCount;
                }
                if (crossingCount == 0)
                    continue;

                const point = scale(sum, 1.0 / crossingCount);
                const normal = gradient(field, point, cell * 0.5);
                const vertex = mesh.addVertex(point);
                mesh.normals ~= normal;
                cellVertex[(k * cellsY + j) * cellsX + i] = vertex;
            }
        }
    }

    // Connect the four cells around every sign-changing grid edge.
    foreach (k; 1 .. cellsZ)
    {
        foreach (j; 1 .. cellsY)
        {
            foreach (i; 0 .. cellsX)
            {
                if ((values[(k * ny + j) * nx + i] < 0) ==
                    (values[(k * ny + j) * nx + i + 1] < 0))
                    continue;
                const a = cellVertex[((k - 1) * cellsY + (j - 1)) * cellsX + i];
                const b = cellVertex[((k - 1) * cellsY + j) * cellsX + i];
                const c = cellVertex[(k * cellsY + j) * cellsX + i];
                const d = cellVertex[(k * cellsY + (j - 1)) * cellsX + i];
                addQuad(mesh, a, b, c, d);
            }
        }
    }
    foreach (k; 1 .. cellsZ)
    {
        foreach (i; 1 .. cellsX)
        {
            foreach (j; 0 .. cellsY)
            {
                if ((values[(k * ny + j) * nx + i] < 0) ==
                    (values[(k * ny + j + 1) * nx + i] < 0))
                    continue;
                const a = cellVertex[((k - 1) * cellsY + j) * cellsX + (i - 1)];
                const b = cellVertex[((k - 1) * cellsY + j) * cellsX + i];
                const c = cellVertex[(k * cellsY + j) * cellsX + i];
                const d = cellVertex[(k * cellsY + j) * cellsX + (i - 1)];
                addQuad(mesh, a, b, c, d);
            }
        }
    }
    foreach (j; 1 .. cellsY)
    {
        foreach (i; 1 .. cellsX)
        {
            foreach (k; 0 .. cellsZ)
            {
                if ((values[(k * ny + j) * nx + i] < 0) ==
                    (values[((k + 1) * ny + j) * nx + i] < 0))
                    continue;
                const a = cellVertex[((k) * cellsY + (j - 1)) * cellsX + (i - 1)];
                const b = cellVertex[((k) * cellsY + (j - 1)) * cellsX + i];
                const c = cellVertex[((k) * cellsY + j) * cellsX + i];
                const d = cellVertex[((k) * cellsY + j) * cellsX + (i - 1)];
                addQuad(mesh, a, b, c, d);
            }
        }
    }

    smooth(mesh, 2, 0.22);
    return mesh;
}

private void addQuad(ref Mesh mesh, int a, int b, int c, int d)
{
    if (a < 0 || b < 0 || c < 0 || d < 0)
        return;
    const p0 = mesh.vertices[a];
    const p1 = mesh.vertices[b];
    const p2 = mesh.vertices[c];
    const faceNormal = cross(sub(p1, p0), sub(p2, p0));
    const averageNormal = add(add(mesh.normals[a], mesh.normals[b]),
        add(mesh.normals[c], mesh.normals[d]));
    if (dot(faceNormal, averageNormal) >= 0)
    {
        mesh.addTriangle(a, b, c, Material.neutral);
        mesh.addTriangle(a, c, d, Material.neutral);
    }
    else
    {
        mesh.addTriangle(a, d, c, Material.neutral);
        mesh.addTriangle(a, c, b, Material.neutral);
    }
}

private Vec3 gradient(const SdfField field, Vec3 point, double epsilon)
{
    const dx = field.eval(add(point, Vec3(epsilon, 0, 0))) -
        field.eval(sub(point, Vec3(epsilon, 0, 0)));
    const dy = field.eval(add(point, Vec3(0, epsilon, 0))) -
        field.eval(sub(point, Vec3(0, epsilon, 0)));
    const dz = field.eval(add(point, Vec3(0, 0, epsilon))) -
        field.eval(sub(point, Vec3(0, 0, epsilon)));
    auto normal = normalize(Vec3(dx, dy, dz));
    if (length(normal) < 0.5)
        normal = Vec3(0, 1, 0);
    return normal;
}

private void smooth(ref Mesh mesh, int iterations, double amount)
{
    if (mesh.vertices.length == 0)
        return;
    foreach (iteration; 0 .. iterations)
    {
        auto sums = new Vec3[mesh.vertices.length];
        foreach (ref value; sums)
            value = Vec3(0, 0, 0);
        auto counts = new int[mesh.vertices.length];
        void link(int a, int b)
        {
            sums[a] = add(sums[a], mesh.vertices[b]);
            counts[a]++;
        }
        foreach (face; mesh.faces)
        {
            link(face.a, face.b);
            link(face.b, face.c);
            link(face.c, face.a);
        }
        foreach (index; 0 .. mesh.vertices.length)
        {
            if (counts[index] == 0)
                continue;
            const average = scale(sums[index], 1.0 / counts[index]);
            mesh.vertices[index] = add(
                scale(mesh.vertices[index], 1.0 - amount),
                scale(average, amount));
        }
    }
    computeSmoothNormals(mesh);
}

unittest
{
    import auroramesh.sdf : sphere;
    SdfField field;
    field.shapes = [sphere(Vec3(0, 0, 0), 0.5)];
    auto mesh = surfaceNets(field, Vec3(-1, -1, -1), Vec3(1, 1, 1), 0.1);
    assert(mesh.vertices.length > 0);
    assert(mesh.faces.length > 0);
    assert(mesh.normals.length == mesh.vertices.length);
    assert(watertight(mesh));
}
