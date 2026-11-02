module auroramesh.decimate;

import auroramesh.mesh : Face, Material, Mesh, Vec3, add, computeSmoothNormals,
    cross, dot, length, normalize, scale, sub, watertight;
import std.math : isFinite;

/// Symmetric 4x4 quadric, written out: the squared distance to a set of planes.
private struct Quadric
{
    double xx, xy, xz, xw, yy, yz, yw, zz, zw, ww;

    static Quadric plane(Vec3 normal, double offset)
    {
        Quadric quadric;
        quadric.xx = normal.x * normal.x;
        quadric.xy = normal.x * normal.y;
        quadric.xz = normal.x * normal.z;
        quadric.xw = normal.x * offset;
        quadric.yy = normal.y * normal.y;
        quadric.yz = normal.y * normal.z;
        quadric.yw = normal.y * offset;
        quadric.zz = normal.z * normal.z;
        quadric.zw = normal.z * offset;
        quadric.ww = offset * offset;
        return quadric;
    }

    double error(Vec3 point) const
    {
        return xx * point.x * point.x + 2 * xy * point.x * point.y +
            2 * xz * point.x * point.z + 2 * xw * point.x +
            yy * point.y * point.y + 2 * yz * point.y * point.z +
            2 * yw * point.y + zz * point.z * point.z + 2 * zw * point.z +
            ww;
    }
}

private Quadric quadricSum(Quadric first, Quadric second)
{
    Quadric sum;
    sum.xx = first.xx + second.xx;
    sum.xy = first.xy + second.xy;
    sum.xz = first.xz + second.xz;
    sum.xw = first.xw + second.xw;
    sum.yy = first.yy + second.yy;
    sum.yz = first.yz + second.yz;
    sum.yw = first.yw + second.yw;
    sum.zz = first.zz + second.zz;
    sum.zw = first.zw + second.zw;
    sum.ww = first.ww + second.ww;
    return sum;
}

/// Plane quadrics summed per vertex: the geometric error of moving that vertex.
private Quadric[] vertexQuadrics(Mesh mesh)
{
    auto quadrics = new Quadric[mesh.vertices.length];
    foreach (face; mesh.faces)
    {
        const first = mesh.vertices[face.a];
        const second = mesh.vertices[face.b];
        const third = mesh.vertices[face.c];
        const normal = cross(sub(second, first), sub(third, first));
        const size = length(normal);
        if (!(size > 1.0e-12))
            continue;
        const unit = scale(normal, 1.0 / size);
        const planeQuadric = Quadric.plane(unit, -dot(unit, first));
        quadrics[face.a] = quadricSum(quadrics[face.a], planeQuadric);
        quadrics[face.b] = quadricSum(quadrics[face.b], planeQuadric);
        quadrics[face.c] = quadricSum(quadrics[face.c], planeQuadric);
    }
    return quadrics;
}

unittest
{
    // A sharp corner must cost more to flatten than a flat sheet costs to collapse
    // within: that difference is what keeps small features like toes. Costing by edge
    // length alone cannot tell the two apart, which is why the toes went first.
    auto cube = Mesh();
    cubeAt(cube, 0.0, 1.0);
    const cubeQuadrics = vertexQuadrics(cube);
    const cornerCost = quadricSum(cubeQuadrics[0], cubeQuadrics[1]).error(
        scale(add(cube.vertices[0], cube.vertices[1]), 0.5));
    assert(cornerCost > 0.01, "collapsing a cube corner must cost real error");

    auto sheet = Mesh();
    const s0 = sheet.addVertex(Vec3(0, 0, 0));
    const s1 = sheet.addVertex(Vec3(1, 0, 0));
    const s2 = sheet.addVertex(Vec3(0, 1, 0));
    const s3 = sheet.addVertex(Vec3(1, 1, 0));
    sheet.addTriangle(s0, s1, s2, cast(Material) 0);
    sheet.addTriangle(s1, s3, s2, cast(Material) 0);
    const sheetQuadrics = vertexQuadrics(sheet);
    const flatCost = quadricSum(sheetQuadrics[s0], sheetQuadrics[s1]).error(
        scale(add(sheet.vertices[s0], sheet.vertices[s1]), 0.5));
    assert(flatCost <= 1.0e-9, "collapsing inside a flat sheet must cost nothing");
}

private struct Candidate
{
    int a;
    int b;
    double cost;
    int versionA;
    int versionB;
}

/**
 * Quadric-error collapse with a closed-manifold link check and normal guard.
 *
 * The cost of collapsing an edge is the squared distance from the merged point to the
 * planes of the faces around that edge, so removing a sharp small feature (a toe) costs
 * far more than removing a smooth large one (a thigh). Costing by edge length instead —
 * as this did — deletes the smallest features first, which is exactly backwards.
 */
Mesh decimateMesh(Mesh source, int targetFaces)
{
    if (source.faces.length <= targetFaces)
    {
        auto copy = source;
        computeSmoothNormals(copy);
        return copy;
    }

    Mesh mesh = source;
    const int vertexCount = cast(int) mesh.vertices.length;
    auto faceAlive = new bool[mesh.faces.length];
    foreach (ref alive; faceAlive)
        alive = true;
    auto vertexFaces = new int[][vertexCount];
    foreach (index, face; mesh.faces)
    {
        vertexFaces[face.a] ~= cast(int) index;
        vertexFaces[face.b] ~= cast(int) index;
        vertexFaces[face.c] ~= cast(int) index;
    }
    auto versions = new int[vertexCount];
    auto faceStamp = new int[mesh.faces.length];
    int stamp;
    int aliveFaces = cast(int) mesh.faces.length;
    Candidate[] heap;

    // Each vertex accumulates the planes of its faces, which is what makes the cost
    // geometric error rather than edge length.
    auto quadrics = vertexQuadrics(mesh);

    void pushEdge(int a, int b, bool checkEdge)
    {
        if (a == b)
            return;
        if (checkEdge && !shareEdge(a, b, vertexFaces, faceAlive, mesh.faces))
            return;
        // Geometric error at the merged point, with edge length only breaking ties.
        const midpoint = scale(add(mesh.vertices[a], mesh.vertices[b]), 0.5);
        const error = quadricSum(quadrics[a], quadrics[b]).error(midpoint);
        const lengthCost = edgeCost(mesh, a, b);
        const cost = isFinite(error) && error > 0
            ? error + 1.0e-9 * lengthCost : lengthCost;
        heapPush(heap, Candidate(a, b, cost, versions[a], versions[b]));
    }

    bool[ulong] initialEdges;
    foreach (index, face; mesh.faces)
    {
        const indices = [face.a, face.b, face.c];
        foreach (offset; 0 .. 3)
        {
            int first = indices[offset];
            int second = indices[(offset + 1) % 3];
            if (first > second)
            {
                const int swap = first;
                first = second;
                second = swap;
            }
            const key = (cast(ulong) first << 32) | cast(uint) second;
            if (key in initialEdges)
                continue;
            initialEdges[key] = true;
            pushEdge(first, second, false);
        }
    }

    while (aliveFaces > targetFaces && heap.length > 0)
    {
        const candidate = heapPop(heap);
        if (candidate.a < 0 || candidate.b < 0 ||
            candidate.a >= vertexCount || candidate.b >= vertexCount)
            continue;
        if (versions[candidate.a] != candidate.versionA ||
            versions[candidate.b] != candidate.versionB)
            continue;
        if (!shareEdge(candidate.a, candidate.b, vertexFaces, faceAlive,
            mesh.faces))
            continue;
        if (edgeFaceCount(candidate.a, candidate.b, vertexFaces, faceAlive,
            mesh.faces) != 2)
            continue;

        const neighborA = neighborsOf(candidate.a, vertexFaces, faceAlive,
            mesh.faces);
        const neighborB = neighborsOf(candidate.b, vertexFaces, faceAlive,
            mesh.faces);
        int common;
        foreach (neighbor; neighborA)
            foreach (other; neighborB)
                if (other == neighbor)
                {
                    ++common;
                    break;
                }
        // A closed edge has exactly the two opposite vertices in common.
        if (common != 2)
            continue;

        const midpoint = scale(add(mesh.vertices[candidate.a],
            mesh.vertices[candidate.b]), 0.5);
        int[] affected;
        ++stamp;
        foreach (index; vertexFaces[candidate.a])
        {
            if (!faceAlive[index] || faceStamp[index] == stamp)
                continue;
            faceStamp[index] = stamp;
            affected ~= index;
        }
        foreach (index; vertexFaces[candidate.b])
        {
            if (!faceAlive[index] || faceStamp[index] == stamp)
                continue;
            faceStamp[index] = stamp;
            affected ~= index;
        }

        bool rejected;
        foreach (index; affected)
        {
            const face = mesh.faces[index];
            if (faceHas(face, candidate.a) && faceHas(face, candidate.b))
                continue;
            const oldNormal = faceNormal(mesh, face);
            if (length(oldNormal) < 1.0e-12)
                continue;
            Vec3 p0 = vertexPosition(mesh, face.a);
            Vec3 p1 = vertexPosition(mesh, face.b);
            Vec3 p2 = vertexPosition(mesh, face.c);
            if (face.a == candidate.a) p0 = midpoint;
            if (face.b == candidate.a) p1 = midpoint;
            if (face.c == candidate.a) p2 = midpoint;
            if (face.a == candidate.b) p0 = midpoint;
            if (face.b == candidate.b) p1 = midpoint;
            if (face.c == candidate.b) p2 = midpoint;
            const newNormal = cross(sub(p1, p0), sub(p2, p0));
            if (length(newNormal) < 1.0e-12 ||
                dot(normalize(oldNormal), normalize(newNormal)) <= 0.05)
            {
                rejected = true;
                break;
            }
        }
        if (rejected)
            continue;

        const keep = candidate.a;
        const remove = candidate.b;
        mesh.vertices[keep] = midpoint;
        quadrics[keep] = quadricSum(quadrics[keep], quadrics[remove]);
        quadrics[remove] = Quadric.init;
        ++versions[keep];
        ++versions[remove];

        foreach (index; affected)
        {
            if (!faceAlive[index])
                continue;
            auto face = mesh.faces[index];
            bool hadKeep;
            bool hadRemove;
            if (face.a == keep || face.b == keep || face.c == keep)
                hadKeep = true;
            if (face.a == remove || face.b == remove || face.c == remove)
                hadRemove = true;
            if (hadKeep && hadRemove)
            {
                faceAlive[index] = false;
                --aliveFaces;
                continue;
            }
            if (face.a == remove) face.a = keep;
            if (face.b == remove) face.b = keep;
            if (face.c == remove) face.c = keep;
            if (face.a == face.b || face.b == face.c || face.a == face.c)
            {
                faceAlive[index] = false;
                --aliveFaces;
                continue;
            }
            mesh.faces[index] = face;
            vertexFaces[keep] ~= index;
        }
        vertexFaces[remove] = null;

        const neighbors = neighborsOf(keep, vertexFaces, faceAlive,
            mesh.faces);
        foreach (neighbor; neighbors)
            pushEdge(keep, neighbor, true);
    }

    Mesh result;
    int[] remap = new int[vertexCount];
    foreach (ref value; remap)
        value = -1;
    foreach (index, face; mesh.faces)
    {
        if (!faceAlive[index])
            continue;
        const sourceIndices = [face.a, face.b, face.c];
        int[3] mapped;
        foreach (slot; 0 .. 3)
        {
            const oldIndex = sourceIndices[slot];
            if (remap[oldIndex] < 0)
                remap[oldIndex] = result.addVertex(mesh.vertices[oldIndex]);
            mapped[slot] = remap[oldIndex];
        }
        result.addTriangle(mapped[0], mapped[1], mapped[2], face.material);
    }
    computeSmoothNormals(result);
    return result;
}

private void heapPush(ref Candidate[] heap, Candidate value)
{
    heap ~= value;
    size_t index = heap.length - 1;
    while (index > 0)
    {
        const parent = (index - 1) / 2;
        if (heap[parent].cost <= value.cost)
            break;
        heap[index] = heap[parent];
        index = parent;
    }
    heap[index] = value;
}

private Candidate heapPop(ref Candidate[] heap)
{
    const top = heap[0];
    auto last = heap[$ - 1];
    heap = heap[0 .. $ - 1];
    if (heap.length == 0)
        return top;
    size_t index;
    while (true)
    {
        const left = index * 2 + 1;
        if (left >= heap.length)
            break;
        const right = left + 1;
        const child = right < heap.length && heap[right].cost < heap[left].cost ?
            right : left;
        if (heap[child].cost >= last.cost)
            break;
        heap[index] = heap[child];
        index = child;
    }
    heap[index] = last;
    return top;
}

private Vec3 vertexPosition(const Mesh mesh, int index)
{
    return mesh.vertices[index];
}

private Vec3 faceNormal(const Mesh mesh, Face face)
{
    return cross(sub(mesh.vertices[face.b], mesh.vertices[face.a]),
        sub(mesh.vertices[face.c], mesh.vertices[face.a]));
}

private bool faceHas(Face face, int vertex)
{
    return face.a == vertex || face.b == vertex || face.c == vertex;
}

private bool shareEdge(int a, int b, const int[][] vertexFaces,
    const bool[] faceAlive, const Face[] faces)
{
    foreach (index; vertexFaces[a])
    {
        if (!faceAlive[index])
            continue;
        const face = faces[index];
        if (face.a == b || face.b == b || face.c == b)
            return true;
    }
    return false;
}

private int edgeFaceCount(int a, int b, const int[][] vertexFaces,
    const bool[] faceAlive, const Face[] faces)
{
    int count;
    foreach (index; vertexFaces[a])
    {
        if (!faceAlive[index])
            continue;
        const face = faces[index];
        if (face.a == b || face.b == b || face.c == b)
            ++count;
    }
    return count;
}

private int[] neighborsOf(int vertex, const int[][] vertexFaces,
    const bool[] faceAlive, const Face[] faces)
{
    // Degrees are tiny, so a linear scan beats allocating a hash set for every query:
    // this runs twice per candidate collapse and dominated decimation time.
    int[] result;
    result.reserve(12);
    void consider(int candidate)
    {
        if (candidate == vertex)
            return;
        foreach (existing; result)
            if (existing == candidate)
                return;
        result ~= candidate;
    }
    foreach (index; vertexFaces[vertex])
    {
        if (!faceAlive[index])
            continue;
        const face = faces[index];
        consider(face.a);
        consider(face.b);
        consider(face.c);
    }
    return result;
}

private double edgeCost(const Mesh mesh, int a, int b)
{
    const edge = sub(mesh.vertices[a], mesh.vertices[b]);
    double cost = dot(edge, edge);
    if (mesh.normals.length == mesh.vertices.length)
    {
        const variation = 1.0 - dot(normalize(mesh.normals[a]),
            normalize(mesh.normals[b]));
        cost *= 1.0 + 0.5 * variation;
    }
    return cost;
}

unittest
{
    auto mesh = Mesh();
    const a = mesh.addVertex(Vec3(-0.5, -0.5, 0));
    const b = mesh.addVertex(Vec3(0.5, -0.5, 0));
    const c = mesh.addVertex(Vec3(0.0, 0.5, 0));
    mesh.addTriangle(a, b, c, Material.cloth);
    auto result = decimateMesh(mesh, 1);
    assert(result.faces.length == 1);
}
