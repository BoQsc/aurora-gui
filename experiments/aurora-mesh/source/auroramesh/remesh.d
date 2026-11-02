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
    add, cross, dot, length, normalize, scale, sub, watertight;
import auroramesh.sculpt : cloneMesh;
import auroramesh.regions : RegionKind, RegionVolume, regionDistance;
import auroramesh.sdf : SdfField, sphere;
import auroramesh.surface_nets : surfaceNets;
import std.array : join;
import std.math : sqrt;
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

private double faceLongestEdge(const Mesh mesh, Face face)
{
    double longest = length(sub(mesh.vertices[face.a], mesh.vertices[face.b]));
    const second = length(sub(mesh.vertices[face.b], mesh.vertices[face.c]));
    const third = length(sub(mesh.vertices[face.c], mesh.vertices[face.a]));
    if (second > longest)
        longest = second;
    if (third > longest)
        longest = third;
    return longest;
}

private double regionReach(const RegionVolume region)
{
    if (region.kind == RegionKind.box)
    {
        double smallest = abs(region.b.x - region.a.x);
        if (abs(region.b.y - region.a.y) < smallest)
            smallest = abs(region.b.y - region.a.y);
        if (abs(region.b.z - region.a.z) < smallest)
            smallest = abs(region.b.z - region.a.z);
        return smallest;
    }
    if (region.kind == RegionKind.capsule)
        return region.radius;
    return region.radius * 2;
}

/// Merge vertices that share a position, dropping faces that collapse.
///
/// Clipping and procedural shells leave coincident vertices; unwelded duplicates show
/// as z-fighting slivers and make a closed surface read as broken.
int weldVertices(ref Mesh mesh, double tolerance = 1.0e-6)
{
    if (mesh.vertices.length == 0 || !(tolerance > 0))
        return 0;
    const hasMaterials = mesh.faceMaterials.length == mesh.faces.length;
    const scale = 1.0 / tolerance;
    int[][long] buckets;
    Vec3[] unique;
    int[] remap;
    remap.length = mesh.vertices.length;
    foreach (index, vertex; mesh.vertices)
    {
        const key = cast(long) (vertex.x * scale) * 73856093L ^
            cast(long) (vertex.y * scale) * 19349663L ^
            cast(long) (vertex.z * scale) * 83492791L;
        int found = -1;
        auto bucket = key in buckets;
        if (bucket !is null)
            foreach (candidate; *bucket)
                if (length(sub(unique[candidate], vertex)) <= tolerance)
                {
                    found = candidate;
                    break;
                }
        if (found < 0)
        {
            found = cast(int) unique.length;
            unique ~= vertex;
            if (bucket is null)
                buckets[key] = [found];
            else
                *bucket ~= found;
        }
        remap[index] = found;
    }
    if (unique.length == mesh.vertices.length)
        return 0;
    Face[] faces;
    int[] materials;
    foreach (position, face; mesh.faces)
    {
        const a = remap[face.a];
        const b = remap[face.b];
        const c = remap[face.c];
        if (a == b || b == c || a == c)
            continue;
        faces ~= Face(a, b, c, face.material);
        if (hasMaterials)
            materials ~= mesh.faceMaterials[position];
    }
    const merged = cast(int) mesh.vertices.length - cast(int) unique.length;
    mesh.vertices = unique;
    mesh.faces = faces;
    mesh.faceMaterials = hasMaterials ? materials : null;
    computeSmoothNormals(mesh);
    return merged;
}

/**
 * Cut the mesh with a plane, keeping the side the normal points away from.
 *
 * Removing whole faces cannot cut a coarse mesh — a leg can be a single long triangle,
 * so nothing is ever fully inside — which leaves the limb sticking out however small
 * the region is. This splits triangles exactly at the plane and closes the opening
 * with a fan on it, so the result stays a closed surface whatever the face size.
 */
int clipToPlane(ref Mesh mesh, Vec3 point, Vec3 normal, out int removed)
{
    removed = 0;
    if (mesh.faces.length == 0)
        return 0;
    const facing = normalize(normal);
    if (!(length(facing) > 0.5))
        return 0;

    double distanceOf(Vec3 vertex)
    {
        return dot(sub(vertex, point), facing);
    }

    int[long] cutIndex;
    int[] cutFrom;
    int[] cutTo;
    int intersection(int low, int high)
    {
        const key = edgeKey(low, high);
        auto found = key in cutIndex;
        if (found !is null)
            return *found;
        const a = mesh.vertices[low];
        const b = mesh.vertices[high];
        const da = distanceOf(a);
        const db = distanceOf(b);
        const span = da - db;
        const t = abs(span) < 1.0e-12 ? 0.5 : da / span;
        const index = cast(int) mesh.vertices.length;
        mesh.vertices ~= Vec3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t,
            a.z + (b.z - a.z) * t);
        if (mesh.normals.length > 0)
            mesh.normals ~= Vec3(0, 0, 0);
        cutIndex[key] = index;
        return index;
    }

    const hasMaterials = mesh.faceMaterials.length == mesh.faces.length;
    Face[] kept;
    // New faces belong to the surface they came from, not to the palette's first
    // slot: that is how a cut ended up wearing the selection colour.
    int dominant;
    if (hasMaterials)
    {
        int[int] tally;
        foreach (slot; mesh.faceMaterials)
            ++tally[slot];
        int best = -1;
        foreach (slot, count; tally)
            if (count > best)
            {
                best = count;
                dominant = slot;
            }
    }
    int[] keptMaterials;
    foreach (position, face; mesh.faces)
    {
        const corners = [face.a, face.b, face.c];
        const material = hasMaterials ? mesh.faceMaterials[position] : 0;
        bool[3] inside;
        int insideCount;
        foreach (slot; 0 .. 3)
        {
            inside[slot] = distanceOf(mesh.vertices[corners[slot]]) <= 1.0e-9;
            if (inside[slot])
                ++insideCount;
        }
        if (insideCount == 3)
        {
            kept ~= face;
            if (hasMaterials)
                keptMaterials ~= material;
            continue;
        }
        if (insideCount == 0)
        {
            ++removed;
            continue;
        }
        int[] polygon;
        int[] cut;
        foreach (slot; 0 .. 3)
        {
            const next = (slot + 1) % 3;
            if (inside[slot])
                polygon ~= corners[slot];
            if (inside[slot] != inside[next])
            {
                const low = corners[slot] < corners[next] ?
                    corners[slot] : corners[next];
                const high = corners[slot] < corners[next] ?
                    corners[next] : corners[slot];
                const index = intersection(low, high);
                polygon ~= index;
                cut ~= index;
            }
        }
        foreach (slot; 1 .. polygon.length - 1)
        {
            kept ~= Face(polygon[0], polygon[slot], polygon[slot + 1],
                Material.skin);
            if (hasMaterials)
                keptMaterials ~= material;
        }
        if (cut.length == 2)
        {
            cutFrom ~= cut[0];
            cutTo ~= cut[1];
        }
    }
    mesh.faces = kept;
    if (hasMaterials)
        mesh.faceMaterials = keptMaterials;

    // Close the opening on the plane. Chains are built by consuming each cut segment
    // exactly once, growing from both ends: a vertex shared by two chains must not be
    // refused, or the cap stops short and leaves a hole into the limb.
    bool[] used;
    used.length = cutFrom.length;
    const segments = cast(int) cutFrom.length;
    int capped;
    foreach (seed; 0 .. segments)
    {
        if (used[seed])
            continue;
        used[seed] = true;
        int[] loop = [cutFrom[seed], cutTo[seed]];
        bool growing = true;
        while (growing)
        {
            growing = false;
            foreach (slot; 0 .. segments)
            {
                if (used[slot])
                    continue;
                if (cutFrom[slot] == loop[$ - 1])
                {
                    loop ~= cutTo[slot];
                    used[slot] = true;
                    growing = true;
                    break;
                }
                if (cutTo[slot] == loop[$ - 1])
                {
                    loop ~= cutFrom[slot];
                    used[slot] = true;
                    growing = true;
                    break;
                }
            }
        }
        growing = true;
        while (growing)
        {
            growing = false;
            foreach (slot; 0 .. segments)
            {
                if (used[slot])
                    continue;
                int[] front;
                if (cutFrom[slot] == loop[0])
                    front = [cutTo[slot]];
                else if (cutTo[slot] == loop[0])
                    front = [cutFrom[slot]];
                else
                    continue;
                front ~= loop;
                loop = front;
                used[slot] = true;
                growing = true;
                break;
            }
        }
        if (loop.length < 3)
            continue;
        auto sum = Vec3(0, 0, 0);
        foreach (index; loop)
            sum = add(sum, mesh.vertices[index]);
        const middle = scale(sum, 1.0 / loop.length);
        Vec3 axis = normalize(Vec3(1, 0, 0));
        if (abs(dot(axis, facing)) > 0.9)
            axis = normalize(Vec3(0, 0, 1));
        const side = normalize(cross(facing, axis));
        const up = normalize(cross(facing, side));
        // Orient the cap outwards. Walk order depends on which side the clip walked, so
        // a cap fanned blindly can face into the limb: it is then culled and the shin
        // shows an open slot instead of a closed end.
        Vec3 newell;
        foreach (slot; 0 .. loop.length)
        {
            const here = mesh.vertices[loop[slot]];
            const next = mesh.vertices[loop[(slot + 1) % loop.length]];
            newell = add(newell, Vec3((here.y - next.y) * (here.z + next.z),
                (here.z - next.z) * (here.x + next.x),
                (here.x - next.x) * (here.y + next.y)));
        }
        if (dot(newell, facing) < 0)
        {
            int[] reversed;
            foreach_reverse (index; loop)
                reversed ~= index;
            loop = reversed;
        }
        // The chain is already in walk order along the cut, so it is fanned as it is:
        // re-sorting it would let a fan span the opening.
        const material = hasMaterials ? dominant : 0;
        // A chain that closed on itself ends with its first vertex; that duplicate
        // makes the last fan triangle degenerate, and welding it away left a hole.
        if (loop.length > 1 && loop[0] == loop[$ - 1])
            loop = loop[0 .. $ - 1];
        foreach (slot; 1 .. loop.length - 1)
        {
            const before = mesh.faces.length;
            mesh.addTriangle(loop[0], loop[slot], loop[slot + 1], Material.skin);
            if (mesh.faces.length > before)
            {
                if (mesh.faceMaterials.length == before)
                    mesh.faceMaterials ~= material;
                ++capped;
            }
        }
    }
    // No welding here: intersection vertices are already deduplicated per edge, and
    // merging on top of that fuses the cut ring into the original ring, which is how
    // the cut produced non-manifold edges.
    computeSmoothNormals(mesh);
    return capped;
}

unittest
{
    // A plane cut must split coarse faces and leave the surface closed. A single
    // quad as two large triangles is the case whole-face removal cannot handle.
    Mesh box;
    box.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
        Vec3(0, 0, 1), Vec3(1, 0, 1), Vec3(1, 1, 1), Vec3(0, 1, 1)
    ];
    foreach (quad; [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
        [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]])
    {
        box.addTriangle(quad[0], quad[1], quad[2], 0);
        box.addTriangle(quad[0], quad[2], quad[3], 0);
    }
    computeSmoothNormals(box);
    const low = Vec3(-1, -1, -1);
    const high = Vec3(2, 2, 2);
    assert(meshHealth(box, low, high).ok);

    auto cut = box;
    int removed;
    const capped = clipToPlane(cut, Vec3(0, 0.5, 0), Vec3(0, 1, 0), removed);
    assert(removed == 0, "no face of the cube is fully above the plane");
    assert(capped == 4, "the cut opening must be closed with four triangles");
    assert(watertight(cut), "a plane cut must leave a closed surface");
    assert(meshHealth(cut, low, high).ok);
    assert(meshHealth(cut, low, high).nonManifoldEdges == 0,
        "a plane cut must not create non-manifold edges");
    int onPlane;
    foreach (vertex; cut.vertices)
    {
        assert(vertex.y <= 0.5 + 1.0e-9, "nothing may stay above the cut");
        if (abs(vertex.y - 0.5) < 1.0e-9)
            ++onPlane;
    }
    assert(onPlane >= 4, "the cap must lie exactly on the plane");
}

unittest
{
    // Welding must merge coincident vertices without dropping real faces. A clip
    // leaves exactly this situation behind, and unwelded duplicates read as slivers.
    Mesh cube;
    cube.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
        Vec3(0, 0, 1), Vec3(1, 0, 1), Vec3(1, 1, 1), Vec3(0, 1, 1)
    ];
    foreach (quad; [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
        [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]])
    {
        cube.addTriangle(quad[0], quad[1], quad[2], 0);
        cube.addTriangle(quad[0], quad[2], quad[3], 0);
    }
    computeSmoothNormals(cube);

    auto doubled = cube;
    const count = cast(int) doubled.vertices.length;
    doubled.vertices ~= doubled.vertices[0 .. count];
    foreach (ref face; doubled.faces)
    {
        face.a += count;
        face.b += count;
        face.c += count;
    }
    doubled.faceMaterials = null;
    assert(doubled.vertices.length == 16);

    const merged = weldVertices(doubled);
    assert(merged == 8, "eight coincident copies must merge");
    assert(doubled.vertices.length == 8);
    assert(doubled.faces.length == 12, "no face may lose its area");
    assert(watertight(doubled), "welding must keep the surface closed");
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

    // A face is removed only when all three corners are inside, so a face larger than
    // the region cannot be cut at all — on a coarse base mesh a whole leg can be one
    // long triangle. Refine until the faces at the cut are small next to the region.
    const reach = regionReach(region);
    if (reach > 0)
        for (int pass = 0; pass < 2; ++pass)
        {
            double largest;
            foreach (face; mesh.faces)
                if (inside[face.a] || inside[face.b] || inside[face.c])
                {
                    const edge = faceLongestEdge(mesh, face);
                    if (edge > largest)
                        largest = edge;
                }
            if (largest <= reach * 0.35)
                break;
            subdivideMesh(mesh, 1);
            inside = new bool[mesh.vertices.length];
            foreach (index, vertex; mesh.vertices)
                inside[index] = regionDistance(region, vertex) <= 0;
        }
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
 * How many disconnected shells the mesh is made of.
 *
 * A replacement is supposed to leave the model with as many shells as it had. When
 * a shape is appended instead of spliced in, this count grows, and the model keeps
 * geometry hidden inside itself; one number makes that visible.
 */
int meshShellCount(const Mesh mesh)
{
    if (mesh.faces.length == 0)
        return 0;
    auto owner = new int[](mesh.vertices.length);
    foreach (index; 0 .. owner.length)
        owner[index] = cast(int) index;
    size_t root(size_t index)
    {
        while (owner[index] != index)
        {
            owner[index] = owner[owner[index]];
            index = owner[index];
        }
        return index;
    }
    void join(size_t a, size_t b)
    {
        const first = root(a);
        const second = root(b);
        if (first != second)
            owner[second] = cast(int) first;
    }
    auto used = new bool[](mesh.vertices.length);
    foreach (face; mesh.faces)
    {
        used[face.a] = true;
        used[face.b] = true;
        used[face.c] = true;
        join(face.a, face.b);
        join(face.b, face.c);
    }
    auto groups = new bool[](mesh.vertices.length);
    int count;
    foreach (index; 0 .. mesh.vertices.length)
    {
        if (!used[index])
            continue;
        const group = root(index);
        if (!groups[group])
        {
            groups[group] = true;
            ++count;
        }
    }
    return count;
}

unittest
{
    // Two triangles that share no vertex are two shells; a folded strip that shares
    // vertices is one.
    auto mesh = Mesh();
    const a = mesh.addVertex(Vec3(0, 0, 0));
    const b = mesh.addVertex(Vec3(1, 0, 0));
    const c = mesh.addVertex(Vec3(0, 1, 0));
    const d = mesh.addVertex(Vec3(5, 0, 0));
    const e = mesh.addVertex(Vec3(6, 0, 0));
    const f = mesh.addVertex(Vec3(5, 1, 0));
    mesh.addTriangle(a, b, c, 0);
    mesh.addTriangle(d, e, f, 0);
    assert(meshShellCount(mesh) == 2, "two detached triangles are two shells");
    mesh.addTriangle(c, b, d, 0);
    assert(meshShellCount(mesh) == 1, "sharing a vertex makes one shell");
    assert(meshShellCount(Mesh()) == 0);
}

/**
 * The ordered boundary loops of the mesh: edges with a single face, walked into rings.
 *
 * A splice leaves exactly this behind — the seam where one surface was cut against
 * another — so closing the model means finding those rings and joining them.
 */
int[][] boundaryLoops(const Mesh mesh)
{
    int[int] edgeCount;
    int[int] nextAt;
    foreach (face; mesh.faces)
    {
        const pairs = [[face.a, face.b], [face.b, face.c], [face.c, face.a]];
        foreach (pair; pairs)
        {
            const key = cast(int) edgeKey(pair[0], pair[1]);
            edgeCount[key] = (key in edgeCount ? edgeCount[key] : 0) + 1;
        }
    }
    // Boundary edges keep the direction their single face walks them in.
    foreach (face; mesh.faces)
    {
        const pairs = [[face.a, face.b], [face.b, face.c], [face.c, face.a]];
        foreach (pair; pairs)
        {
            if (edgeCount[cast(int) edgeKey(pair[0], pair[1])] != 1)
                continue;
            nextAt[pair[0]] = pair[1];
        }
    }
    int[][] loops;
    bool[int] walked;
    foreach (start; nextAt.byKey)
    {
        if (start in walked)
            continue;
        int[] loop;
        auto at = start;
        size_t guard;
        while (!(at in walked) && guard++ < mesh.vertices.length + 1)
        {
            walked[at] = true;
            loop ~= at;
            if (at !in nextAt)
                break;
            at = nextAt[at];
        }
        if (loop.length >= 3)
            loops ~= loop;
    }
    return loops;
}

/**
 * Join two boundary loops with a triangle strip, using only their own vertices.
 *
 * Both rings are walked at once and the shorter step is taken at each stage, which
 * keeps the strip from folding back when the two rings differ in vertex count.
 */
int bridgeLoops(ref Mesh mesh, const int[] first, const int[] second)
{
    if (first.length < 3 || second.length < 3)
        return 0;
    int added;
    size_t a;
    size_t b;
    while (a < first.length || b < second.length)
    {
        const atA = first[a % $];
        const atB = second[b % $];
        const ahead = cast(double) (a + 1) / first.length -
            cast(double) (b + 1) / second.length;
        if (a >= first.length || (ahead > 0 && b < second.length))
        {
            mesh.addTriangle(atA, second[(b + 1) % $], atB, cast(Material) 0);
            ++b;
        }
        else
        {
            mesh.addTriangle(atA, first[(a + 1) % $], atB, cast(Material) 0);
            ++a;
        }
        ++added;
    }
    return added;
}

unittest
{
    // A square tube is open at both ends, so it has two boundary rings. Bridging them
    // must close the surface, which is what a splice has to leave behind.
    auto mesh = Mesh();
    int[] low;
    int[] high;
    foreach (corner; [Vec3(-1, 0, -1), Vec3(1, 0, -1), Vec3(1, 0, 1),
        Vec3(-1, 0, 1)])
        low ~= mesh.addVertex(corner);
    foreach (corner; [Vec3(-1, 1, -1), Vec3(1, 1, -1), Vec3(1, 1, 1),
        Vec3(-1, 1, 1)])
        high ~= mesh.addVertex(corner);
    foreach (index; 0 .. 4)
    {
        const next = (index + 1) % 4;
        mesh.addTriangle(low[index], low[next], high[next], 0);
        mesh.addTriangle(low[index], high[next], high[index], 0);
    }
    const loops = boundaryLoops(mesh);
    assert(loops.length == 2, "a tube has two open ends");
    assert(!watertight(mesh), "the tube is open before bridging");
    assert(bridgeLoops(mesh, low, high) > 0, "bridging must add faces");
}

/// The mesh split into its disconnected shells, each with its own vertices.
Mesh[] splitShells(const Mesh mesh)
{
    auto owner = new int[](mesh.vertices.length);
    foreach (index; 0 .. owner.length)
        owner[index] = cast(int) index;
    int root(int index)
    {
        while (owner[index] != index)
        {
            owner[index] = owner[owner[index]];
            index = owner[index];
        }
        return index;
    }
    void join(int a, int b)
    {
        const first = root(a);
        const second = root(b);
        if (first != second)
            owner[second] = first;
    }
    foreach (face; mesh.faces)
    {
        join(face.a, face.b);
        join(face.b, face.c);
    }
    int[int] slot;
    Mesh[] shells;
    // Per shell: source vertex -> local vertex, or -1 when it has not been copied.
    int[][int] local;
    foreach (face; mesh.faces)
    {
        const group = root(face.a);
        if (group !in slot)
        {
            slot[group] = cast(int) shells.length;
            shells ~= Mesh();
            local[group] = [];
        }
        ref mapping = local[group];
        ref shell = shells[slot[group]];
        int localVertex(int source)
        {
            if (source >= mapping.length)
            {
                const was = mapping.length;
                mapping.length = source + 1;
                foreach (index; was .. mapping.length)
                    mapping[index] = -1;
            }
            if (mapping[source] < 0)
            {
                mapping[source] = cast(int) shell.vertices.length;
                shell.vertices ~= mesh.vertices[source];
            }
            return mapping[source];
        }
        shell.faces ~= Face(localVertex(face.a), localVertex(face.b),
            localVertex(face.c), face.material);
    }
    return shells;
}

unittest
{
    // Two detached triangles are two shells with their own vertices; a strip is one.
    auto mesh = Mesh();
    const a = mesh.addVertex(Vec3(0, 0, 0));
    const b = mesh.addVertex(Vec3(1, 0, 0));
    const c = mesh.addVertex(Vec3(0, 1, 0));
    const d = mesh.addVertex(Vec3(5, 0, 0));
    const e = mesh.addVertex(Vec3(6, 0, 0));
    const f = mesh.addVertex(Vec3(5, 1, 0));
    mesh.addTriangle(a, b, c, cast(Material) 0);
    mesh.addTriangle(d, e, f, cast(Material) 0);
    const parts = splitShells(mesh);
    assert(parts.length == 2, "two detached triangles are two shells");
    assert(parts[0].vertices.length == 3 && parts[0].faces.length == 1);
    assert(parts[1].vertices.length == 3, "each shell owns its vertices");
}

/**
 * Merge two overlapping closed shells into one closed surface.
 *
 * Cull each surface where the other buries it, join what remains, then bridge the two
 * rings the cull leaves behind. This is what lets a replacement take the place of the
 * geometry it replaces instead of sitting inside it.
 */
bool mergeShells(ref Mesh first, const Mesh second, out string reason)
{
    reason = "";
    if (first.faces.length == 0 || second.faces.length == 0)
    {
        reason = "nothing to merge";
        return false;
    }
    auto host = cloneMesh(first);
    auto guest = cloneMesh(second);
    const removedHost = cullInside(host, second);
    const removedGuest = cullInside(guest, first);
    if (removedHost == 0 && removedGuest == 0)
    {
        reason = "the shells do not overlap";
        return false;
    }
    auto joined = host;
    appendMesh(joined, guest);
    const loops = boundaryLoops(joined);
    if (loops.length != 2)
    {
        reason = format("expected 2 seam rings, found %d", loops.length);
        return false;
    }
    bridgeLoops(joined, loops[0], loops[1]);
    weldVertices(joined);
    if (!watertight(joined))
    {
        reason = "the seam did not close";
        return false;
    }
    first = joined;
    return true;
}

unittest
{
    // Two overlapping cubes: a stand-in for a limb and the shape that replaces part of
    // it. The merge must leave one closed shell, not two crossing ones.
    auto host = Mesh();
    cubeAt(host, 0.0, 1.0);
    auto guest = Mesh();
    cubeAt(guest, 0.6, 1.0);
    assert(meshShellCount(host) == 1);
    string reason;
    const merged = mergeShells(host, guest, reason);
    assert(merged, reason);
    assert(meshShellCount(host) == 1, "the merge must leave a single shell");
    assert(watertight(host), "the merged surface must stay closed");

    // Two cubes that do not touch must be refused, not silently joined.
    auto alone = Mesh();
    cubeAt(alone, 0.0, 1.0);
    auto far = Mesh();
    cubeAt(far, 9.0, 1.0);
    assert(!mergeShells(alone, far, reason));
    assert(reason.length > 0);
}

/**
 * Merge every shell that overlaps another, keeping the shells that reach the region.
 *
 * This is the operation a replacement needs: the shape it added is a separate closed
 * surface sitting inside the old geometry, and merging turns the two into one.
 */
int mergeOverlappingShells(ref Mesh mesh, RegionVolume region, out string reason,
    int targetFaces = 28000, double cell = 0, double sliverQuality = 0.05,
    double blendCells = 1.5)
{
    reason = "";
    auto parts = splitShells(mesh);
    if (parts.length < 2)
    {
        reason = "the model has a single shell";
        return 0;
    }
    auto touches = new bool[](parts.length);
    int host;
    size_t mostFaces;
    foreach (index, part; parts)
    {
        foreach (vertex; part.vertices)
            if (regionDistance(region, vertex) <= 0)
            {
                touches[index] = true;
                break;
            }
        if (part.faces.length > mostFaces)
        {
            mostFaces = part.faces.length;
            host = cast(int) index;
        }
    }
    // One field evaluation for everything near the region: unioning pair by pair would
    // resample the whole result again for each shell and multiply the triangle count.
    Mesh[] group;
    int[] members;
    foreach (index, part; parts)
        if (cast(int) index == host || touches[index])
        {
            group ~= part;
            members ~= cast(int) index;
        }
    if (group.length < 2)
    {
        reason = "no shell near the region";
        return 0;
    }
    // Resample at the requested cell (or fine enough for the toes), then reduce to the
    // budget with the quadric cost, which keeps small features.
    auto united = resurfaceUnion(group, targetFaces * 2, targetFaces, cell,
        sliverQuality, blendCells);
    if (united.faces.length == 0)
    {
        reason = "the field union produced no geometry";
        return 0;
    }
    auto absorbed = new bool[](parts.length);
    foreach (index; members)
        absorbed[index] = true;
    Mesh rebuilt = united;
    foreach (index, part; parts)
        if (!absorbed[index])
            appendMesh(rebuilt, part);
    dropSmallShells(rebuilt, 40);
    mesh = rebuilt;
    return cast(int) members.length - 1;
}

unittest
{
    // A host cube and two guests: the overlapping one merges, the distant one stays a
    // shell of its own, which is exactly what a per-foot merge has to do.
    auto mesh = Mesh();
    cubeAt(mesh, 0.0, 1.0);
    auto near = Mesh();
    cubeAt(near, 0.6, 1.0);
    appendMesh(mesh, near);
    auto far = Mesh();
    cubeAt(far, 7.0, 1.0);
    appendMesh(mesh, far);
    assert(meshShellCount(mesh) == 3);
    const box = RegionVolume("all", RegionKind.box, Vec3(-2, -2, -2),
        Vec3(2, 2, 2), 1.0, 0.0);
    string why;
    assert(mergeOverlappingShells(mesh, box, why) > 0, why);
    // The two overlapping cubes became one; the distant cube remains.
    assert(meshShellCount(mesh) == 2, "only the overlapping pair may merge");
}

/**
 * The segment where two triangles meet, or false when they miss.
 *
 * This is the atom of any splice: both surfaces cut along the same segment, so the two
 * sides of the seam end up with exactly the same vertices and weld without tolerance.
 */
bool triangleSegment(Vec3 a0, Vec3 a1, Vec3 a2, Vec3 b0, Vec3 b1, Vec3 b2,
    out Vec3 start, out Vec3 end)
{
    const firstNormal = cross(sub(a1, a0), sub(a2, a0));
    const firstLength = length(firstNormal);
    if (!(firstLength > 1.0e-12))
        return false;
    const firstUnit = scale(firstNormal, 1.0 / firstLength);
    const secondNormal = cross(sub(b1, b0), sub(b2, b0));
    const secondLength = length(secondNormal);
    if (!(secondLength > 1.0e-12))
        return false;
    const secondUnit = scale(secondNormal, 1.0 / secondLength);
    const firstOffset = -dot(firstUnit, a0);
    const secondOffset = -dot(secondUnit, b0);

    // Each triangle must straddle the other's plane, or they cannot meet.
    const aToSecond = [dot(secondUnit, a0) + secondOffset,
        dot(secondUnit, a1) + secondOffset,
        dot(secondUnit, a2) + secondOffset];
    const bToFirst = [dot(firstUnit, b0) + firstOffset,
        dot(firstUnit, b1) + firstOffset,
        dot(firstUnit, b2) + firstOffset];
    if ((aToSecond[0] > 0 && aToSecond[1] > 0 && aToSecond[2] > 0) ||
        (aToSecond[0] < 0 && aToSecond[1] < 0 && aToSecond[2] < 0))
        return false;
    if ((bToFirst[0] > 0 && bToFirst[1] > 0 && bToFirst[2] > 0) ||
        (bToFirst[0] < 0 && bToFirst[1] < 0 && bToFirst[2] < 0))
        return false;

    const direction = cross(firstUnit, secondUnit);
    // Walk the planes' intersection line and clip it against both triangles.
    const along = [a0, a1, a2];
    double[] spans;
    foreach (vertex; along)
        spans ~= dot(direction, vertex);
    auto low = spans[0];
    auto high = spans[0];
    foreach (value; spans)
    {
        if (value < low)
            low = value;
        if (value > high)
            high = value;
    }
    const againstB = [b0, b1, b2];
    double[] otherSpans;
    foreach (vertex; againstB)
        otherSpans ~= dot(direction, vertex);
    auto otherLow = otherSpans[0];
    auto otherHigh = otherSpans[0];
    foreach (value; otherSpans)
    {
        if (value < otherLow)
            otherLow = value;
        if (value > otherHigh)
            otherHigh = value;
    }
    if (low < otherLow)
        low = otherLow;
    if (high > otherHigh)
        high = otherHigh;
    if (!(high > low))
        return false;
    // A point on the line: the closest point to the origin of the line of planes.
    const linePoint = scale(sub(scale(secondUnit, firstOffset),
        scale(firstUnit, secondOffset)), 1.0 / dot(direction, direction));
    start = add(linePoint, scale(direction, low));
    end = add(linePoint, scale(direction, high));
    return true;
}

unittest
{
    // A floor triangle and an upright one crossing at the y axis: the shared segment
    // must lie on the y axis between the triangles' extents.
    const a0 = Vec3(-1, -1, 0);
    const a1 = Vec3(1, -1, 0);
    const a2 = Vec3(0, 1, 0);
    const b0 = Vec3(0, -1, -1);
    const b1 = Vec3(0, -1, 1);
    const b2 = Vec3(0, 1, 1);
    Vec3 start;
    Vec3 end;
    assert(triangleSegment(a0, a1, a2, b0, b1, b2, start, end),
        "a crossing pair must report a segment");
    assert(abs(start.x) < 1.0e-9 && abs(end.x) < 1.0e-9,
        "the segment must lie on the y axis");
    assert(abs(start.z) < 1.0e-9 && abs(end.z) < 1.0e-9);
    assert(abs(start.y - end.y) > 1.0e-6, "the segment must have length");

    // Triangles that do not touch report nothing.
    const far = Vec3(0, -1, 5);
    const far2 = Vec3(0, 1, 5);
    const far3 = Vec3(0, 0, 6);
    assert(!triangleSegment(a0, a1, a2, far, far2, far3, start, end));
}

/**
 * Close the boundary loops with a fan, largest loop first up to `largestLoop`.
 *
 * A cut, a splice or a decimation can leave a hole; a hole is refused by the health
 * gate, so there has to be a general way to seal one. The fan follows the boundary's own
 * winding, which keeps the new faces facing the same way as the surface around them.
 */
/**
 * Remove needle faces: triangles that are a sliver rather than a patch.
 *
 * A distance field cannot resolve two surfaces that graze each other, and it emits the
 * grazing strip as long thin triangles that stand out of the surface as flaps. Shape is
 * the test, not size: a well-formed triangle of any size stays, a needle goes however
 * small. The holes this leaves are then closed by fillHoles.
 */
int removeSliverFaces(ref Mesh mesh, double minQuality = 0.05)
{
    auto kept = new Face[mesh.faces.length];
    int written;
    int removed;
    foreach (face; mesh.faces)
    {
        const first = mesh.vertices[face.a];
        const second = mesh.vertices[face.b];
        const third = mesh.vertices[face.c];
        const firstEdge = sub(second, first);
        const secondEdge = sub(third, second);
        const thirdEdge = sub(first, third);
        const squareSum = dot(firstEdge, firstEdge) +
            dot(secondEdge, secondEdge) + dot(thirdEdge, thirdEdge);
        const area = length(cross(firstEdge, secondEdge)) * 0.5;
        // 4*sqrt(3)*area over the squared edge sum is 1 for an equilateral triangle.
        const quality = squareSum > 0 ?
            4.0 * sqrt(3.0) * area / squareSum : 0.0;
        if (quality < minQuality)
        {
            ++removed;
            continue;
        }
        kept[written++] = face;
    }
    if (removed > 0)
        mesh.faces = kept[0 .. written];
    return removed;
}

unittest
{
    // A needle goes and a healthy triangle of the same edge stays.
    auto mesh = Mesh();
    const a = mesh.addVertex(Vec3(0, 0, 0));
    const b = mesh.addVertex(Vec3(1, 0, 0));
    const c = mesh.addVertex(Vec3(0.5, 1, 0));
    const d = mesh.addVertex(Vec3(0.5, 0.001, 0));
    mesh.addTriangle(a, b, c, cast(Material) 0);
    mesh.addTriangle(a, b, d, cast(Material) 0);
    assert(removeSliverFaces(mesh) == 1, "the needle face is removed");
    assert(mesh.faces.length == 1, "the healthy face is kept");
}

/// Signed volume of a closed mesh. Negative means its faces point inwards.
double signedVolume(const Mesh mesh)
{
    auto total = 0.0;
    foreach (face; mesh.faces)
    {
        const first = mesh.vertices[face.a];
        const second = mesh.vertices[face.b];
        const third = mesh.vertices[face.c];
        total += dot(first, cross(second, third)) / 6.0;
    }
    return total;
}

/**
 * Make an inside-out shell face outward.
 *
 * A resampled shell can come out with every face wound the other way, which is not a hole
 * and not detectable as one: the surface is closed, it simply renders dark wherever the
 * shading trusts the winding. Volume is the tell, so flip when the volume is negative.
 * Returns the number of faces flipped.
 */
int orientOutward(ref Mesh mesh)
{
    if (signedVolume(mesh) >= 0)
        return 0;
    foreach (ref face; mesh.faces)
    {
        const swap = face.b;
        face.b = face.c;
        face.c = swap;
    }
    return cast(int) mesh.faces.length;
}

unittest
{
    // A tetrahedron with outward faces has positive volume; winding it backwards and
    // orienting it back returns the same positive volume.
    auto tetra = Mesh();
    const a = tetra.addVertex(Vec3(0, 0, 0));
    const b = tetra.addVertex(Vec3(1, 0, 0));
    const c = tetra.addVertex(Vec3(0, 1, 0));
    const d = tetra.addVertex(Vec3(0, 0, 1));
    tetra.addTriangle(a, b, d, cast(Material) 0);
    tetra.addTriangle(a, d, c, cast(Material) 0);
    tetra.addTriangle(a, c, b, cast(Material) 0);
    tetra.addTriangle(b, c, d, cast(Material) 0);
    const outward = signedVolume(tetra);
    assert(outward > 0.1, "outward winding has positive volume");
    foreach (ref face; tetra.faces)
    {
        const swap = face.b;
        face.b = face.c;
        face.c = swap;
    }
    assert(signedVolume(tetra) < -0.1, "inverted winding has negative volume");
    orientOutward(tetra);
    assert(signedVolume(tetra) > 0.1, "orientation restores outward winding");
}

int fillHoles(ref Mesh mesh, int largestLoop)
{
    const loops = boundaryLoops(mesh);
    int filled;
    foreach (loop; loops)
    {
        if (loop.length < 3)
            continue;
        if (largestLoop > 0 && cast(int) loop.length > largestLoop)
            continue;
        auto centre = Vec3(0, 0, 0);
        foreach (vertex; loop)
            centre = add(centre, mesh.vertices[vertex]);
        centre = scale(centre, 1.0 / loop.length);
        const hub = mesh.addVertex(centre);
        foreach (index; 0 .. loop.length)
            mesh.addTriangle(loop[index], loop[(index + 1) % $], hub,
                cast(Material) 0);
        ++filled;
    }
    return filled;
}

unittest
{
    // A box with its top face missing is an open shell: one fill must seal it.
    auto mesh = Mesh();
    cubeAt(mesh, 0.0, 1.0);
    // Remove the face whose vertices are all above the centre: the top.
    Face[] kept;
    foreach (face; mesh.faces)
    {
        const high = mesh.vertices[face.a].y > 0.4 &&
            mesh.vertices[face.b].y > 0.4 && mesh.vertices[face.c].y > 0.4;
        if (!high)
            kept ~= face;
    }
    mesh.faces = kept;
    assert(!watertight(mesh), "the box must be open before filling");
    assert(fillHoles(mesh, 0) == 1, "one hole must be filled");
    assert(watertight(mesh), "the fill must close the shell");
}

/**
 * Drop the parts of `mesh` that lie inside `other`, refining only the faces that straddle
 * it so the cut edge follows the crossing closely instead of the face edges.
 *
 * A face wholly outside is kept, one wholly inside is dropped, and one that straddles is
 * split in four and reconsidered — down to `levels`, after which its centroid decides.
 */
int refineInside(ref Mesh mesh, const Mesh other, int levels)
{
    if (mesh.faces.length == 0 || other.vertices.length == 0)
        return 0;
    Vec3 low = other.vertices[0];
    Vec3 high = other.vertices[0];
    foreach (vertex; other.vertices)
    {
        low = Vec3(vertex.x < low.x ? vertex.x : low.x,
            vertex.y < low.y ? vertex.y : low.y,
            vertex.z < low.z ? vertex.z : low.z);
        high = Vec3(vertex.x > high.x ? vertex.x : high.x,
            vertex.y > high.y ? vertex.y : high.y,
            vertex.z > high.z ? vertex.z : high.z);
    }
    Face[] kept;
    kept.reserve(mesh.faces.length);
    int removed;
    void classify(Face face, int depth)
    {
        const first = mesh.vertices[face.a];
        const second = mesh.vertices[face.b];
        const third = mesh.vertices[face.c];
        // Bounding-box rejection first: most faces are nowhere near the other shell.
        if ((first.x < low.x && second.x < low.x && third.x < low.x) ||
            (first.x > high.x && second.x > high.x && third.x > high.x) ||
            (first.y < low.y && second.y < low.y && third.y < low.y) ||
            (first.y > high.y && second.y > high.y && third.y > high.y) ||
            (first.z < low.z && second.z < low.z && third.z < low.z) ||
            (first.z > high.z && second.z > high.z && third.z > high.z))
        {
            kept ~= face;
            return;
        }
        const insideFirst = isInsideMesh(other, first);
        const insideSecond = isInsideMesh(other, second);
        const insideThird = isInsideMesh(other, third);
        const insideCount = (insideFirst ? 1 : 0) + (insideSecond ? 1 : 0) +
            (insideThird ? 1 : 0);
        if (insideCount == 0)
        {
            kept ~= face;
            return;
        }
        if (insideCount == 3)
        {
            ++removed;
            return;
        }
        if (depth <= 0)
        {
            const centre = scale(add(add(first, second), third), 1.0 / 3.0);
            if (isInsideMesh(other, centre))
                ++removed;
            else
                kept ~= face;
            return;
        }
        const ab = mesh.addVertex(scale(add(first, second), 0.5));
        const bc = mesh.addVertex(scale(add(second, third), 0.5));
        const ca = mesh.addVertex(scale(add(third, first), 0.5));
        classify(Face(face.a, ab, ca, face.material), depth - 1);
        classify(Face(ab, face.b, bc, face.material), depth - 1);
        classify(Face(ca, bc, face.c, face.material), depth - 1);
        classify(Face(ab, bc, ca, face.material), depth - 1);
    }
    foreach (face; mesh.faces)
        classify(face, levels);
    mesh.faces = kept;
    return removed;
}

/**
 * Union two overlapping closed shells: refine each against the other, join, weld the
 * seam and seal what is left. Falls back to a refusal rather than a broken surface.
 */
bool unionShells(ref Mesh first, const Mesh second, int levels, out string reason)
{
    reason = "";
    if (first.faces.length == 0 || second.faces.length == 0)
    {
        reason = "nothing to merge";
        return false;
    }
    auto host = cloneMesh(first);
    auto guest = cloneMesh(second);
    const removedHost = refineInside(host, second, levels);
    const removedGuest = refineInside(guest, first, levels);
    if (removedHost == 0 && removedGuest == 0)
    {
        reason = "the shells do not overlap";
        return false;
    }
    auto joined = host;
    appendMesh(joined, guest);
    const loops = boundaryLoops(joined);
    if (loops.length != 2)
    {
        reason = format("expected 2 seam rings, found %d", loops.length);
        return false;
    }
    bridgeLoops(joined, loops[0], loops[1]);
    fillHoles(joined, 0);
    weldVertices(joined);
    if (!watertight(joined))
    {
        reason = "the seam did not close";
        return false;
    }
    first = joined;
    return true;
}

/// Closest point of a triangle to a point.
private Vec3 closestOnTriangle(Vec3 point, Vec3 a, Vec3 b, Vec3 c)
{
    const ab = sub(b, a);
    const ac = sub(c, a);
    const ap = sub(point, a);
    const d1 = dot(ab, ap);
    const d2 = dot(ac, ap);
    if (d1 <= 0 && d2 <= 0)
        return a;
    const bp = sub(point, b);
    const d3 = dot(ab, bp);
    const d4 = dot(ac, bp);
    if (d3 >= 0 && d4 <= d3)
        return b;
    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0 && d1 >= 0 && d3 <= 0)
        return add(a, scale(ab, d1 / (d1 - d3)));
    const cp = sub(point, c);
    const d5 = dot(ab, cp);
    const d6 = dot(ac, cp);
    if (d6 >= 0 && d5 <= d6)
        return c;
    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0 && d2 >= 0 && d6 <= 0)
        return add(a, scale(ac, d2 / (d2 - d6)));
    const va = d3 * d6 - d5 * d4;
    if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0)
        return add(b, scale(sub(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6))));
    const denominator = 1.0 / (va + vb + vc);
    const v = vb * denominator;
    const w = vc * denominator;
    return add(a, add(scale(ab, v), scale(ac, w)));
}

/// Distance from a point to the closest point of a triangle.
private double pointTriangleDistance(Vec3 point, Vec3 a, Vec3 b, Vec3 c)
{
    return length(sub(point, closestOnTriangle(point, a, b, c)));
}

/// Signed distance to the closed surface: negative inside, positive outside.
double signedDistanceToMesh(const Mesh mesh, Vec3 point)
{
    if (mesh.faces.length == 0)
        return double.max;
    auto best = double.max;
    foreach (face; mesh.faces)
    {
        const candidate = pointTriangleDistance(point, mesh.vertices[face.a],
            mesh.vertices[face.b], mesh.vertices[face.c]);
        if (candidate < best)
            best = candidate;
    }
    return isInsideMesh(mesh, point) ? -best : best;
}

unittest
{
    // A unit cube centred on the origin: the centre is half a unit inside, a point one
    // unit away from the centre along x is half a unit outside.
    auto cube = Mesh();
    cubeAt(cube, 0.0, 1.0);
    assert(abs(signedDistanceToMesh(cube, Vec3(0, 0, 0)) + 0.5) < 1.0e-9,
        "the centre must be half a unit inside");
    assert(abs(signedDistanceToMesh(cube, Vec3(1, 0, 0)) - 0.5) < 1.0e-9,
        "a point half a unit outside must read positive");
    assert(signedDistanceToMesh(cube, Vec3(3, 0, 0)) > 2.0);
}

private int magnitude(int value)
{
    return value < 0 ? -value : value;
}

/**
 * Signed distance to a closed mesh, answering from a coarse bucket index.
 *
 * Resampling a model asks the field thousands of times. Asking every face every time is
 * what makes that too slow, so faces are bucketed and searched ring by ring outwards,
 * stopping once no unvisited bucket could hold a closer face.
 */
struct MeshField
{
    Mesh mesh;
    double cell = 0.02;
    double saturation = 0.05;
    Vec3 origin;
    long[][long] buckets;
    Vec3[] normals;

    static long bucketKey(int x, int y, int z)
    {
        return (cast(long) (x + 1024) << 42) ^ (cast(long) (y + 1024) << 21) ^
            (cast(long) (z + 1024));
    }

    int bucketOf(double value, double base) const
    {
        return cast(int) ((value - base) / cell);
    }

    static MeshField build(Mesh source, double cell, double saturation)
    {
        MeshField field;
        field.mesh = source;
        field.cell = cell;
        field.saturation = saturation;
        if (source.vertices.length == 0)
            return field;
        Vec3 low = source.vertices[0];
        Vec3 high = source.vertices[0];
        foreach (vertex; source.vertices)
        {
            low = Vec3(vertex.x < low.x ? vertex.x : low.x,
                vertex.y < low.y ? vertex.y : low.y,
                vertex.z < low.z ? vertex.z : low.z);
            high = Vec3(vertex.x > high.x ? vertex.x : high.x,
                vertex.y > high.y ? vertex.y : high.y,
                vertex.z > high.z ? vertex.z : high.z);
        }
        field.origin = low;
        foreach (index, face; source.faces)
        {
            const a = source.vertices[face.a];
            const b = source.vertices[face.b];
            const c = source.vertices[face.c];
            const normal = cross(sub(b, a), sub(c, a));
            const size = length(normal);
            field.normals ~= size > 1.0e-12 ? scale(normal, 1.0 / size) :
                Vec3(0, 1, 0);
            const lo = field.bucketOf(a.x < b.x ? (a.x < c.x ? a.x : c.x) :
                (b.x < c.x ? b.x : c.x), low.x);
            const hi = field.bucketOf(a.x > b.x ? (a.x > c.x ? a.x : c.x) :
                (b.x > c.x ? b.x : c.x), low.x);
            const ly = field.bucketOf(a.y < b.y ? (a.y < c.y ? a.y : c.y) :
                (b.y < c.y ? b.y : c.y), low.y);
            const hy = field.bucketOf(a.y > b.y ? (a.y > c.y ? a.y : c.y) :
                (b.y > c.y ? b.y : c.y), low.y);
            const lz = field.bucketOf(a.z < b.z ? (a.z < c.z ? a.z : c.z) :
                (b.z < c.z ? b.z : c.z), low.z);
            const hz = field.bucketOf(a.z > b.z ? (a.z > c.z ? a.z : c.z) :
                (b.z > c.z ? b.z : c.z), low.z);
            foreach (x; lo .. hi + 1)
                foreach (y; ly .. hy + 1)
                    foreach (z; lz .. hz + 1)
                        field.buckets[bucketKey(x, y, z)] ~=
                            cast(long) index;
        }
        return field;
    }

    double eval(Vec3 point) const
    {
        if (mesh.faces.length == 0)
            return saturation;
        const base = Vec3(cast(double) bucketOf(point.x, origin.x),
            cast(double) bucketOf(point.y, origin.y),
            cast(double) bucketOf(point.z, origin.z));
        double best = saturation;
        auto closestFace = -1;
        foreach (ring; 0 .. 12)
        {
            if (closestFace >= 0 && ring * cell > best)
                break;
            // Past the saturation distance nothing closer can be found, so a far sample
            // must stop searching instead of walking every ring outwards.
            if (ring * cell > saturation)
                break;
            foreach (dx; -ring .. ring + 1)
                foreach (dy; -ring .. ring + 1)
                    foreach (dz; -ring .. ring + 1)
                    {
                        if (ring > 0)
                        {
                            const widest = magnitude(dx) > magnitude(dy) ?
                                (magnitude(dx) > magnitude(dz) ? magnitude(dx) :
                                magnitude(dz)) : (magnitude(dy) > magnitude(dz) ?
                                magnitude(dy) : magnitude(dz));
                            if (widest != ring)
                                continue;
                        }
                        const key = bucketKey(cast(int) base.x + dx,
                            cast(int) base.y + dy, cast(int) base.z + dz);
                        auto list = key in buckets;
                        if (list is null)
                            continue;
                        foreach (index; *list)
                        {
                            const face = mesh.faces[cast(size_t) index];
                            const distance = pointTriangleDistance(point,
                                mesh.vertices[face.a], mesh.vertices[face.b],
                                mesh.vertices[face.c]);
                            if (distance < best)
                            {
                                best = distance;
                                closestFace = cast(int) index;
                            }
                        }
                    }
        }
        if (closestFace < 0)
            return saturation;
        const face = mesh.faces[cast(size_t) closestFace];
        const closest = closestOnTriangle(point, mesh.vertices[face.a],
            mesh.vertices[face.b], mesh.vertices[face.c]);
        const side = dot(sub(point, closest), normals[cast(size_t) closestFace]);
        return side < 0 ? -best : best;
    }
}

/// Total surface area, used to pick a cell that lands near a target face count.
private double meshArea(const Mesh mesh)
{
    auto total = 0.0;
    foreach (face; mesh.faces)
    {
        const a = mesh.vertices[face.a];
        const b = mesh.vertices[face.b];
        const c = mesh.vertices[face.c];
        total += 0.5 * length(cross(sub(b, a), sub(c, a)));
    }
    return total;
}

/// Keep only the shells with at least `minimum` faces: strays from a resample must go.
int dropSmallShells(ref Mesh mesh, int minimum)
{
    const parts = splitShells(mesh);
    if (parts.length <= 1)
        return 0;
    int dropped;
    Mesh kept;
    foreach (part; parts)
    {
        if (cast(int) part.faces.length < minimum && parts.length > 1)
        {
            ++dropped;
            continue;
        }
        appendMesh(kept, part);
    }
    if (dropped > 0)
        mesh = kept;
    return dropped;
}

/**
 * Union several closed meshes by resurfacing their combined distance field.
 *
 * Overlapping shells have no seam to bridge when the result is extracted from a field:
 * the union is simply the smallest of the distances. The cell is derived from the total
 * area and a target face count, so the density stays under control instead of exploding.
 */
/// Polynomial smooth minimum: surfaces closer than the blend radius round into one.
private double smoothMinimum(double first, double second, double blend)
{
    if (!(blend > 0))
        return first < second ? first : second;
    const h = 0.5 + 0.5 * (second - first) / blend;
    const clamped = h < 0 ? 0.0 : (h > 1 ? 1.0 : h);
    const least = first < second ? first : second;
    return least - blend * clamped * (1 - clamped);
}

Mesh resurfaceUnion(Mesh[] pieces, int targetFaces = 28000, int maxFaces = 0,
    double requestedCell = 0, double sliverQuality = 0.05,
    double blendCells = 1.5)
{
    Mesh[] solid;
    foreach (piece; pieces)
        if (piece.faces.length > 0)
            solid ~= piece;
    if (solid.length == 0)
        return Mesh();
    auto area = 0.0;
    foreach (piece; solid)
        area += meshArea(piece);
    // An explicit cell is predictable; otherwise derive one from the area target.
    // Surface nets emits about two triangles per cell.
    const cell = requestedCell > 0 ? requestedCell :
        (area > 0 ? sqrt(2.0 * area / targetFaces) : 0.01);
    // Keep the search band tight: it bounds how many buckets a sample may visit, so
    // widening it multiplies sampling cost. Pinholes are closed after resampling instead.
    const band = cell * 3;
    MeshField[] fields;
    foreach (piece; solid)
        fields ~= MeshField.build(piece, cell * 4, band);
    struct Union
    {
        MeshField[] fields;
        double blend;
        double eval(Vec3 point) const
        {
            auto best = double.max;
            bool started;
            foreach (field; fields)
            {
                const here = field.eval(point);
                if (!started)
                {
                    best = here;
                    started = true;
                    continue;
                }
                // A hard min leaves a thin sheet where two surfaces graze; blending the
                // union over a fraction of a cell rounds that crease into one surface.
                best = blend > 0 ? smoothMinimum(best, here, blend) :
                    (here < best ? here : best);
            }
            return best;
        }
    }
    auto field = Union(fields, cell * blendCells);
    Vec3 low = solid[0].vertices[0];
    Vec3 high = solid[0].vertices[0];
    foreach (mesh; solid)
        foreach (vertex; mesh.vertices)
        {
            low = Vec3(vertex.x < low.x ? vertex.x : low.x,
                vertex.y < low.y ? vertex.y : low.y,
                vertex.z < low.z ? vertex.z : low.z);
            high = Vec3(vertex.x > high.x ? vertex.x : high.x,
                vertex.y > high.y ? vertex.y : high.y,
                vertex.z > high.z ? vertex.z : high.z);
        }
    const padding = cell * 3;
    auto merged = surfaceNets(field, Vec3(low.x - padding, low.y - padding,
        low.z - padding), Vec3(high.x + padding, high.y + padding,
        high.z + padding), cell);
    // Grazing surfaces leave needle faces that stand out as flaps, and whatever gaps
    // remain are boundary loops: drop the needles, then seal what that opens. Removing
    // faces can open more than the fan can close, so keep the unreduced surface and fall
    // back to it rather than handing the caller a mesh the health gate will refuse. The
    // test is the gate's own, so the two cannot disagree about what "holes" means.
    if (sliverQuality > 0)
    {
        auto unreduced = merged;
        removeSliverFaces(merged, sliverQuality);
        fillHoles(merged, 0);
        if (!meshHealth(merged, low, high).ok)
        {
            merged = unreduced;
            fillHoles(merged, 0);
        }
    }
    else
        fillHoles(merged, 0);
    // Resample finely enough for the smallest feature, then decimate back to budget:
    // decimation keeps toes that a coarse resample would erase.
    if (maxFaces > 0 && cast(int) merged.faces.length > maxFaces)
        merged = decimateMesh(merged, maxFaces);
    dropSmallShells(merged, 40);
    return merged;
}

/// Union two closed meshes by resurfacing their combined distance field.
Mesh unionMeshes(Mesh first, Mesh second, int targetFaces = 28000)
{
    Mesh[] pieces;
    pieces ~= first;
    pieces ~= second;
    return resurfaceUnion(pieces, targetFaces);
}

unittest
{
    // Two overlapping cubes must come back as one closed shell, not two crossing ones:
    // that is the whole point of the field union.
    auto host = Mesh();
    cubeAt(host, 0.0, 1.0);
    auto guest = Mesh();
    cubeAt(guest, 0.6, 1.0);
    const merged = unionMeshes(host, guest, 0.05);
    assert(merged.faces.length > 0, "the union must produce geometry");
    assert(meshShellCount(merged) == 1, "the union must be a single shell");
    assert(watertight(merged), "the union must be closed");
    foreach (vertex; merged.vertices)
        assert(isFinite(vertex.x) && isFinite(vertex.y) && isFinite(vertex.z));
}

/// Möller–Trumbore: does the ray from origin along direction hit the triangle?
private bool rayHitsTriangle(Vec3 origin, Vec3 direction, Vec3 a, Vec3 b, Vec3 c)
{
    const e1 = sub(b, a);
    const e2 = sub(c, a);
    const h = cross(direction, e2);
    const determinant = dot(e1, h);
    if (determinant > -1.0e-12 && determinant < 1.0e-12)
        return false;
    const inverse = 1.0 / determinant;
    const s = sub(origin, a);
    const u = inverse * dot(s, h);
    if (u < 0 || u > 1)
        return false;
    const q = cross(s, e1);
    const v = inverse * dot(direction, q);
    if (v < 0 || u + v > 1)
        return false;
    return inverse * dot(e2, q) > 1.0e-9;
}

/**
 * Is the point inside the closed surface? Odd crossings of a ray mean inside.
 *
 * This is the test every boolean operation needs, so it lives on its own: it is what
 * tells a replacement which old faces are buried under the shape that replaces them.
 */
bool isInsideMesh(const Mesh mesh, Vec3 point)
{
    if (mesh.faces.length == 0)
        return false;
    // A direction that is unlikely to graze an edge, so the crossings stay clean.
    const direction = Vec3(0.5773, 0.5774, 0.5775);
    int crossings;
    foreach (face; mesh.faces)
    {
        if (rayHitsTriangle(point, direction, mesh.vertices[face.a],
            mesh.vertices[face.b], mesh.vertices[face.c]))
            ++crossings;
    }
    return (crossings & 1) == 1;
}

/**
 * Remove the faces of `mesh` that lie inside `other`.
 *
 * Half of a splice: what stays is the part of this surface that is still outside the
 * shape it should merge with. The seam it leaves behind is what a stitch then closes.
 */
int cullInside(ref Mesh mesh, const Mesh other)
{
    if (mesh.faces.length == 0 || other.faces.length == 0)
        return 0;
    Face[] kept;
    kept.reserve(mesh.faces.length);
    int removed;
    foreach (face; mesh.faces)
    {
        const centroid = scale(add(add(mesh.vertices[face.a],
            mesh.vertices[face.b]), mesh.vertices[face.c]), 1.0 / 3.0);
        if (isInsideMesh(other, centroid))
        {
            ++removed;
            continue;
        }
        kept ~= face;
    }
    mesh.faces = kept;
    return removed;
}

unittest
{
    // A cube inside another cube: the inner one is entirely inside, so culling it
    // against the outer removes every face.
    auto outer = Mesh();
    cubeAt(outer, 0.0, 1.0);
    auto inner = Mesh();
    cubeAt(inner, 0.0, 0.4);
    assert(isInsideMesh(outer, Vec3(0, 0, 0)), "the centre must be inside");
    assert(!isInsideMesh(outer, Vec3(5, 0, 0)), "a far point must be outside");
    const before = inner.faces.length;
    assert(cullInside(inner, outer) == before, "a buried shell is fully culled");
    assert(inner.faces.length == 0);

    // Disjoint: nothing may be removed.
    auto apart = Mesh();
    cubeAt(apart, 10.0, 1.0);
    auto keep = Mesh();
    cubeAt(keep, 0.0, 1.0);
    const keptBefore = keep.faces.length;
    assert(cullInside(keep, apart) == 0, "a separate shell removes nothing");
    assert(keep.faces.length == keptBefore);
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
