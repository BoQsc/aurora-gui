module auroramesh.remesh;

/**
 * Topology-changing edits, done safely.
 *
 * Deformation moves vertices and can never damage the model's structure. Replacing
 * geometry can: a cut leaves holes, a bad stitch leaves creases, a malformed loft
 * leaves NaN. So every replacement here is applied to a copy, checked, and only
 * committed when the result is still a sound mesh. A failed replacement leaves the
 * model exactly as it was.
 */
import auroramesh.decimate : decimateMesh;
import auroramesh.mesh : Face, Material, Mesh, Vec3, computeSmoothNormals,
    add, cross, dot, length, normalize, scale, sub;
import auroramesh.regions : RegionVolume;
import auroramesh.regions : regionDistance;
import auroramesh.sdf : SdfField, sphere;
import auroramesh.surface_nets : surfaceNets;
import std.array : join;
import std.format : format;
import std.math : abs, atan2, cos, isFinite, sin;

struct MeshHealth
{
    bool ok = true;
    string reason;
    string warning;
    int vertices;
    int faces;
    int boundaryEdges;
    int nonManifoldEdges;
    int degenerateFaces;
}

private long edgeKey(int a, int b)
{
    return a < b ? (cast(long) a << 32) | cast(uint) b
        : (cast(long) b << 32) | cast(uint) a;
}

private int lowOf(long key)
{
    return cast(int) (key >> 32);
}

private int highOf(long key)
{
    return cast(int) (key & 0xffffffff);
}

/**
 * Remove the geometry inside a volume and close the openings that leaves.
 *
 * The cap sits inside whatever is placed over the hole, so what remains is still a
 * closed surface and the removal cannot show as a hole. The result still goes
 * through the health gate before it is kept.
 */
int carveRegion(ref Mesh mesh, const RegionVolume region, out int removed)
{
    removed = 0;
    if (mesh.faces.length == 0)
        return 0;
    auto inside = new bool[mesh.vertices.length];
    foreach (index, vertex; mesh.vertices)
        inside[index] = regionDistance(region, vertex) <= 0;
    const hasMaterials = mesh.faceMaterials.length == mesh.faces.length;
    const baseMaterial = hasMaterials && mesh.faceMaterials.length > 0 ?
        mesh.faceMaterials[0] : 0;
    Face[] kept;
    int[] keptMaterials;
    int[long] counts;
    foreach (index, face; mesh.faces)
    {
        if (inside[face.a] && inside[face.b] && inside[face.c])
        {
            ++removed;
            continue;
        }
        kept ~= face;
        if (hasMaterials)
            keptMaterials ~= mesh.faceMaterials[index];
        foreach (key; [edgeKey(face.a, face.b), edgeKey(face.b, face.c),
            edgeKey(face.c, face.a)])
        {
            auto found = key in counts;
            counts[key] = (found ? *found : 0) + 1;
        }
    }
    mesh.faces = kept;
    if (hasMaterials)
        mesh.faceMaterials = keptMaterials;
    if (removed == 0)
        return 0;

    // Walk the edges that lost a face into ordered loops, then cap each one.
    int[][int] neighbours;
    foreach (key, count; counts)
        if (count == 1)
        {
            neighbours[lowOf(key)] ~= highOf(key);
            neighbours[highOf(key)] ~= lowOf(key);
        }
    auto visited = new bool[mesh.vertices.length];
    int capped;
    foreach (start, links; neighbours)
    {
        if (visited[start])
            continue;
        int[] loop;
        loop ~= start;
        visited[start] = true;
        int previous = -1;
        int current = start;
        while (true)
        {
            int next = -1;
            foreach (candidate; neighbours[current])
                if (candidate != previous && !visited[candidate])
                {
                    next = candidate;
                    break;
                }
            if (next < 0)
                break;
            loop ~= next;
            visited[next] = true;
            previous = current;
            current = next;
        }
        if (loop.length < 3)
            continue;
        // Fan around a centroid in angle order. A fan in walk order can span the
        // loop and leave a thin sheet across the opening.
        auto sum = Vec3(0, 0, 0);
        foreach (index; loop)
            sum = add(sum, mesh.vertices[index]);
        const middle = scale(sum, 1.0 / loop.length);
        Vec3 normal;
        foreach (position; 0 .. loop.length)
        {
            const here = mesh.vertices[loop[position]];
            const next = mesh.vertices[loop[(position + 1) % loop.length]];
            normal = add(normal, Vec3((here.y - next.y) * (here.z + next.z),
                (here.z - next.z) * (here.x + next.x),
                (here.x - next.x) * (here.y + next.y)));
        }
        normal = normalize(normal);
        Vec3 axis = normalize(Vec3(1, 0, 0));
        if (abs(dot(axis, normal)) > 0.9)
            axis = normalize(Vec3(0, 0, 1));
        const side = normalize(cross(normal, axis));
        const up = normalize(cross(normal, side));
        double[] angles;
        foreach (index; loop)
        {
            const offset = sub(mesh.vertices[index], middle);
            angles ~= atan2(dot(offset, up), dot(offset, side));
        }
        foreach (a; 0 .. loop.length)
            foreach (b; a + 1 .. loop.length)
                if (angles[b] < angles[a])
                {
                    const swapAngle = angles[a];
                    angles[a] = angles[b];
                    angles[b] = swapAngle;
                    const swapIndex = loop[a];
                    loop[a] = loop[b];
                    loop[b] = swapIndex;
                }
        const centre = cast(int) mesh.vertices.length;
        mesh.vertices ~= middle;
        foreach (position; 0 .. loop.length)
        {
            const next = (position + 1) % loop.length;
            const before = mesh.faces.length;
            mesh.addTriangle(centre, loop[position], loop[next], Material.skin);
            if (mesh.faces.length > before)
            {
                if (mesh.faceMaterials.length == before)
                    mesh.faceMaterials ~= baseMaterial;
                ++capped;
            }
        }
    }
    computeSmoothNormals(mesh);
    return capped;
}

/**
 * Is this still a mesh we are willing to show?
 *
 * Checks what actually goes wrong in practice: NaN coordinates, holes, non-manifold
 * edges, folded faces, and geometry escaping the model's bounds.
 */
MeshHealth meshHealth(const Mesh mesh, Vec3 minimum, Vec3 maximum,
    double tolerance = 0.06)
{
    MeshHealth health;
    health.vertices = cast(int) mesh.vertices.length;
    health.faces = cast(int) mesh.faces.length;
    if (health.vertices == 0 || health.faces == 0)
    {
        health.ok = false;
        health.reason = "empty mesh";
        return health;
    }
    foreach (index, vertex; mesh.vertices)
    {
        if (!(isFinite(vertex.x) && isFinite(vertex.y) && isFinite(vertex.z)))
        {
            health.ok = false;
            health.reason = "non-finite vertex";
            return health;
        }
        if (vertex.x < minimum.x - tolerance || vertex.x > maximum.x + tolerance ||
            vertex.y < minimum.y - tolerance || vertex.y > maximum.y + tolerance ||
            vertex.z < minimum.z - tolerance || vertex.z > maximum.z + tolerance)
        {
            health.ok = false;
            health.reason = "geometry outside the model bounds";
            return health;
        }
    }
    int[long] edges;
    foreach (face; mesh.faces)
    {
        if (face.a < 0 || face.b < 0 || face.c < 0 ||
            face.a >= health.vertices || face.b >= health.vertices ||
            face.c >= health.vertices)
        {
            health.ok = false;
            health.reason = "face references a missing vertex";
            return health;
        }
        const a = mesh.vertices[face.a];
        const b = mesh.vertices[face.b];
        const c = mesh.vertices[face.c];
        if (!(length(cross(sub(b, a), sub(c, a))) > 1.0e-12))
            ++health.degenerateFaces;
        foreach (edge; [edgeKey(face.a, face.b), edgeKey(face.b, face.c),
            edgeKey(face.c, face.a)])
        {
            auto found = edge in edges;
            edges[edge] = (found ? *found : 0) + 1;
        }
    }
    foreach (edge, count; edges)
    {
        if (count == 1)
            ++health.boundaryEdges;
        else if (count > 2)
            ++health.nonManifoldEdges;
    }
    if (health.boundaryEdges > 0)
    {
        health.ok = false;
        health.reason = "the replacement left holes";
        return health;
    }
    // A non-manifold junction or a sliver still renders and still closes the surface,
    // so it is reported rather than refused. Holes, NaN and stray geometry are what
    // actually break the model, and those are refused above.
    string[] notes;
    if (health.nonManifoldEdges > 0)
        notes ~= format("%d non-manifold edges", health.nonManifoldEdges);
    if (health.degenerateFaces > 0)
        notes ~= format("%d degenerate faces", health.degenerateFaces);
    health.warning = join(notes, ", ");
    return health;
}

/**
 * Run a replacement against a copy and keep it only if the result is healthy.
 *
 * This is the gate that makes a destructive edit safe to offer: whatever the
 * replacement does wrong, the model is untouched unless the outcome checks out.
 */
bool replaceChecked(ref Mesh mesh, Mesh candidate, Vec3 minimum, Vec3 maximum,
    out string reason, out string warning)
{
    const health = meshHealth(candidate, minimum, maximum);
    if (!health.ok)
    {
        reason = health.reason;
        warning = "";
        return false;
    }
    mesh = candidate;
    reason = "ok";
    warning = health.warning;
    return true;
}

/// Uniform subdivision: every face becomes four. Keeps the surface closed.
int subdivideMesh(ref Mesh mesh, int passes = 1)
{
    if (mesh.vertices.length == 0 || mesh.faces.length == 0 || passes <= 0)
        return 0;
    int added;
    foreach (pass; 0 .. passes)
    {
        const count = cast(int) mesh.vertices.length;
        Vec3[] grown;
        int[long] midpoints;
        int midpoint(int a, int b)
        {
            const key = edgeKey(a, b);
            if (auto found = key in midpoints)
                return cast(int) *found;
            const created = count + cast(int) grown.length;
            grown ~= Vec3(
                (mesh.vertices[a].x + mesh.vertices[b].x) * 0.5,
                (mesh.vertices[a].y + mesh.vertices[b].y) * 0.5,
                (mesh.vertices[a].z + mesh.vertices[b].z) * 0.5);
            midpoints[key] = cast(long) created;
            return created;
        }
        const hasMaterials = mesh.faceMaterials.length == mesh.faces.length;
        Face[] faces;
        int[] materials;
        foreach (index, face; mesh.faces)
        {
            const ab = midpoint(face.a, face.b);
            const bc = midpoint(face.b, face.c);
            const ca = midpoint(face.c, face.a);
            const material = face.material;
            const materialIndex = hasMaterials ? mesh.faceMaterials[index] : -1;
            void emit(int x, int y, int z)
            {
                faces ~= Face(x, y, z, material);
                if (hasMaterials)
                    materials ~= materialIndex;
            }
            emit(face.a, ab, ca);
            emit(ab, face.b, bc);
            emit(ca, bc, face.c);
            emit(ab, bc, ca);
        }
        mesh.vertices ~= grown;
        mesh.faces = faces;
        if (hasMaterials)
            mesh.faceMaterials = materials;
        computeSmoothNormals(mesh);
        added += cast(int) grown.length;
    }
    return added;
}

/// Collapse the mesh to a face budget, keeping its materials.
int decimateTo(ref Mesh mesh, int targetFaces)
{
    if (targetFaces <= 0 || mesh.faces.length <= targetFaces)
        return 0;
    const before = cast(int) mesh.faces.length;
    auto reduced = decimateMesh(mesh, targetFaces);
    if (reduced.faces.length == 0)
        return 0;
    mesh = reduced;
    computeSmoothNormals(mesh);
    return before - cast(int) mesh.faces.length;
}

/**
 * Add a closed shell meshed from a signed-distance field inside a region.
 *
 * The field is meshed on its own and appended as a separate closed shell — the
 * model's existing surface is not cut. That means the operation cannot open a hole
 * in the body, however wrong the field is; the worst case is an odd-looking lump.
 */
/**
 * Mesh an SDF field into a closed shell, oriented outwards.
 *
 * Meshing is the expensive part, so callers cache the result and splice it onto each
 * rebuild: re-meshing per frame is what made a fine field disappear entirely.
 */
Mesh sdfShell(const SdfField field, double cell,
    out Vec3 shellLo, out Vec3 shellHi, double padding = 0.01)
{
    shellLo = Vec3(0, 0, 0);
    shellHi = Vec3(0, 0, 0);
    if (field.shapes.length == 0 || !(cell > 0))
        return Mesh();
    // Sample where the field is, not where an outside box ends: a field that reaches
    // past the sampling box would be clipped open.
    Vec3 minimum;
    Vec3 maximum;
    field.bounds(minimum, maximum);
    auto shell = surfaceNets(field, Vec3(minimum.x - padding,
        minimum.y - padding, minimum.z - padding),
        Vec3(maximum.x + padding, maximum.y + padding, maximum.z + padding),
        cell);
    if (shell.vertices.length == 0 || shell.faces.length == 0)
        return Mesh();
    shellLo = shell.vertices[0];
    shellHi = shell.vertices[0];
    foreach (vertex; shell.vertices)
    {
        shellLo = Vec3(vertex.x < shellLo.x ? vertex.x : shellLo.x,
            vertex.y < shellLo.y ? vertex.y : shellLo.y,
            vertex.z < shellLo.z ? vertex.z : shellLo.z);
        shellHi = Vec3(vertex.x > shellHi.x ? vertex.x : shellHi.x,
            vertex.y > shellHi.y ? vertex.y : shellHi.y,
            vertex.z > shellHi.z ? vertex.z : shellHi.z);
    }

    // Surface nets has no winding convention, so each face is oriented against the
    // field itself. One global flip is wrong as soon as a field has two lobes, and an
    // inside-out shell renders as a hollow sheet with the far sides poking through.
    const probe = cell * 0.25;
    foreach (ref face; shell.faces)
    {
        const a = shell.vertices[face.a];
        const b = shell.vertices[face.b];
        const c = shell.vertices[face.c];
        const normal = cross(sub(b, a), sub(c, a));
        if (length(normal) < 1.0e-12)
            continue;
        const middle = Vec3((a.x + b.x + c.x) / 3.0, (a.y + b.y + c.y) / 3.0,
            (a.z + b.z + c.z) / 3.0);
        const facing = normalize(normal);
        const outside = field.eval(add(middle, scale(facing, probe)));
        const inside = field.eval(sub(middle, scale(facing, probe)));
        if (outside < inside)
        {
            const swap = face.b;
            face.b = face.c;
            face.c = swap;
        }
    }
    return shell;
}

/// Append a prepared shell, keeping the material table in step.
int appendMesh(ref Mesh mesh, const Mesh shell, int materialIndex = 0)
{
    if (shell.vertices.length == 0 || shell.faces.length == 0)
        return 0;
    const added = cast(int) shell.faces.length;
    const offset = cast(int) mesh.vertices.length;
    mesh.vertices ~= shell.vertices;
    if (mesh.normals.length == offset)
        foreach (normal; shell.normals)
            mesh.normals ~= normal;
    foreach (face; shell.faces)
    {
        const before = mesh.faces.length;
        mesh.addTriangle(offset + face.a, offset + face.b, offset + face.c,
            Material.skin);
        if (mesh.faces.length > before)
            mesh.faceMaterials ~= materialIndex;
    }
    computeSmoothNormals(mesh);
    return added;
}

unittest
{
    // A closed tetrahedron: the smallest mesh that passes every structural check.
    Mesh mesh;
    mesh.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
    mesh.addTriangle(0, 2, 1, 0);
    mesh.addTriangle(0, 1, 3, 0);
    mesh.addTriangle(1, 2, 3, 0);
    mesh.addTriangle(2, 0, 3, 0);
    computeSmoothNormals(mesh);
    const low = Vec3(-1, -1, -1);
    const high = Vec3(2, 2, 2);
    auto health = meshHealth(mesh, low, high);
    assert(health.ok, health.reason);

    // A hole is refused.
    auto holed = mesh;
    holed.faces = holed.faces[0 .. 3];
    assert(!meshHealth(holed, low, high).ok);

    // A NaN vertex is refused.
    auto broken = mesh;
    broken.vertices[0] = Vec3(double.nan, 0, 0);
    assert(!meshHealth(broken, low, high).ok);

    // The gate keeps the old mesh when the new one is bad.
    auto candidate = holed;
    string reason;
    string warning;
    auto kept = mesh;
    assert(!replaceChecked(kept, candidate, low, high, reason, warning));
    assert(kept.faces.length == 4, "a refused replacement must not be committed");

    // A non-manifold junction renders and stays closed, so it is accepted with a
    // warning instead of being refused.
    auto doubleSided = mesh;
    doubleSided.addTriangle(0, 1, 2, 0);
    const reported = meshHealth(doubleSided, low, high);
    assert(reported.ok, reported.reason);
    assert(reported.warning.length > 0, "a non-manifold junction must be reported");

    // Subdivision doubles the resolution and stays closed.
    auto fine = mesh;
    const added = subdivideMesh(fine, 1);
    assert(added > 0);
    assert(fine.faces.length == mesh.faces.length * 4);
    assert(meshHealth(fine, low, high).ok);

    // Decimation reduces without breaking structure.
    auto coarse = fine;
    decimateTo(coarse, fine.faces.length / 2);
    assert(coarse.faces.length < fine.faces.length);
}

unittest
{
    // Carving must leave a closed surface and must be idempotent.
    Mesh mesh;
    mesh.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
    mesh.addTriangle(0, 2, 1, 0);
    mesh.addTriangle(0, 1, 3, 0);
    mesh.addTriangle(1, 2, 3, 0);
    mesh.addTriangle(2, 0, 3, 0);
    computeSmoothNormals(mesh);
    const low = Vec3(-1, -1, -1);
    const high = Vec3(2, 2, 2);
    assert(meshHealth(mesh, low, high).ok);

    // A region holding three of the four corners removes exactly one face, and the
    // opening it leaves must be capped: a carve that left a hole would be refused.
    RegionVolume slab;
    slab.kind = RegionKind.box;
    slab.a = Vec3(-0.1, -0.1, -0.1);
    slab.b = Vec3(1.1, 1.1, 0.1);
    auto carved = mesh;
    int removed;
    const capped = carveRegion(carved, slab, removed);
    assert(removed == 1, "the face inside the volume must be removed");
    assert(capped == 3, "the triangular opening must be capped");
    assert(carved.faces.length == 6);
    assert(watertight(carved), "a carve must leave a closed surface");
    assert(meshHealth(carved, low, high).ok);
    foreach (vertex; carved.vertices)
        assert(isFinite(vertex.x) && isFinite(vertex.y) && isFinite(vertex.z));

    // Carving the same volume again must do nothing.
    auto again = carved;
    int removedAgain;
    carveRegion(again, slab, removedAgain);
    assert(removedAgain == 0, "a repeated carve must be a no-op");
}

unittest
{
    // A shell must face outwards. One global flip is enough for a single lobe but
    // reverses a second one, which renders as a hollow sheet, so both are checked.
    SdfField field;
    field.shapes = [sphere(Vec3(0, 0, 0), 0.4)];
    Vec3 low;
    Vec3 high;
    auto shell = sdfShell(field, 0.02, low, high);
    assert(shell.faces.length > 100);
    foreach (face; shell.faces)
    {
        const a = shell.vertices[face.a];
        const b = shell.vertices[face.b];
        const c = shell.vertices[face.c];
        const normal = cross(sub(b, a), sub(c, a));
        const middle = Vec3((a.x + b.x + c.x) / 3.0, (a.y + b.y + c.y) / 3.0,
            (a.z + b.z + c.z) / 3.0);
        assert(dot(normal, middle) > 0, "a sphere shell must face outwards");
    }

    field.shapes = [sphere(Vec3(0, 0, 0), 0.4), sphere(Vec3(1.2, 0, 0), 0.4)];
    field.blend = 0.05;
    auto pair = sdfShell(field, 0.02, low, high);
    assert(pair.faces.length > 100);
    foreach (face; pair.faces)
    {
        const a = pair.vertices[face.a];
        const b = pair.vertices[face.b];
        const c = pair.vertices[face.c];
        const normal = cross(sub(b, a), sub(c, a));
        const middle = Vec3((a.x + b.x + c.x) / 3.0, (a.y + b.y + c.y) / 3.0,
            (a.z + b.z + c.z) / 3.0);
        const reference = middle.x < 0.6 ? Vec3(0, 0, 0) : Vec3(1.2, 0, 0);
        assert(dot(normal, sub(middle, reference)) > 0,
            "each lobe of a two-lobe shell must face outwards");
    }
}
