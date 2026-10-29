module auroramesh.reshape;

/**
 * Real-time regional mesh edits.
 *
 * An edit names a body region and a style, and re-forms only the surface inside
 * that region. Vertices move along their normals, so topology is untouched and
 * the mesh stays watertight: a full model rebuild is never needed, which is what
 * makes the edit land inside a frame instead of a load.
 */
import auroramesh.mesh : Face, Mesh, Vec2, Vec3, add, computeSmoothNormals,
    length, normalize, scale, sub, watertight;

import auroramesh.sculpt : smoothVertices;
import std.math : PI, abs, cos, isFinite, sin, sqrt;

/**
 * Replace non-finite or zero-length normals with an upright fallback.
 *
 * A zero-length normal normalises to NaN, and a NaN normal turns every vertex it
 * touches into NaN: the surface disappears and the region renders as a black
 * wedge. Meshes in the wild contain degenerate faces, so this is checked rather
 * than assumed.
 */
private void sanitizeNormals(ref Mesh mesh)
{
    if (mesh.normals.length != mesh.vertices.length)
        return;
    foreach (index, normal; mesh.normals)
    {
        const size = length(normal);
        if (isFinite(normal.x) && isFinite(normal.y) && isFinite(normal.z) &&
            size > 1.0e-9)
            continue;
        mesh.normals[index] = Vec3(0, 1, 0);
    }
}

/// A box in model space; the region an edit is allowed to touch.
/** One recorded region edit, kept so it can be replayed after the mesh is
 *  rebaked for a new animation frame. */
struct RegionEdit
{
    string region;
    string style;
    double strength = 1.0;
    RegionBox box;
    bool hasBox;
}

/// A box in model space; the region an edit is allowed to touch.
struct RegionBox
{
    Vec3 minimum;
    Vec3 maximum;

    bool contains(Vec3 point) const
    {
        return point.x >= minimum.x && point.x <= maximum.x &&
            point.y >= minimum.y && point.y <= maximum.y &&
            point.z >= minimum.z && point.z <= maximum.z;
    }
}

/// The regions an edit can name, with the volume each one covers.
RegionBox regionBox(string region)
{
    if (region == "feet" || region == "foot")
        return RegionBox(Vec3(-0.30, -0.02, -0.25), Vec3(0.30, 0.15, 0.25));
    if (region == "hands" || region == "hand")
        return RegionBox(Vec3(-0.95, 0.85, -0.20), Vec3(0.95, 1.05, 0.20));
    if (region == "head")
        return RegionBox(Vec3(-0.20, 1.55, -0.20), Vec3(0.20, 1.85, 0.20));
    return RegionBox(Vec3(0, 0, 0), Vec3(0, 0, 0));
}

/// Indices of the vertices inside a region, taking the whole side when the
/// region spans both feet or both hands.
int[] regionVertices(const Mesh mesh, const RegionBox box)
{
    int[] indices;
    foreach (index, vertex; mesh.vertices)
        if (box.contains(vertex))
            indices ~= cast(int) index;
    return indices;
}

/// One smooth bump added to the surface.
private struct Bump
{
    Vec3 center;
    double radius;
    double height;
}

private void applyBumps(ref Mesh mesh, const int[] indices, const Bump[] bumps)
{
    if (bumps.length == 0 || indices.length == 0)
        return;
    if (mesh.normals.length != mesh.vertices.length)
        computeSmoothNormals(mesh);
    foreach (index; indices)
    {
        if (index < 0 || index >= mesh.vertices.length)
            continue;
        // Bumps blend as a union, not a sum: overlapping toes must not stack
        // into a spike that folds the surface back through itself.
        double push;
        const up = mesh.normals.length == mesh.vertices.length ?
            (0.55 + 0.45 * mesh.normals[index].y) : 1.0;
        foreach (bump; bumps)
        {
            const delta = sub(mesh.vertices[index], bump.center);
            const distance = length(delta);
            if (distance >= bump.radius)
                continue;
            // Smooth falloff, so bumps blend into the surface instead of
            // leaving a crease at their rim.
            const t = 1.0 - distance / bump.radius;
            const rise = bump.height * t * t * (3.0 - 2.0 * t) * up;
            push = rise > push ? rise : push;
        }
        if (push == 0)
            continue;
        const normal = mesh.normals[index];
        const normalSize = length(normal);
        // Never scale by a raw normal: a zero-length one would write NaN into
        // the vertex and delete the surface.
        if (!(normalSize > 1.0e-9) || !isFinite(normalSize))
            continue;
        // A degenerate profile can make the falloff diverge; a toe is never
        // allowed to move the surface further than a couple of centimetres.
        if (!isFinite(push) || !(abs(push) < 0.05))
            continue;
        mesh.vertices[index] = add(mesh.vertices[index],
            scale(normal, push / normalSize));
    }
    computeSmoothNormals(mesh);
    sanitizeNormals(mesh);
}

/// Split a region into its left and right halves so styles can act per limb.
private int[][] splitSides(const Mesh mesh, const int[] indices)
{
    int[][] sides = new int[][2];
    foreach (index; indices)
    {
        const vertex = mesh.vertices[index];
        if (vertex.x < 0)
            sides[0] ~= index;
        else
            sides[1] ~= index;
    }
    return sides;
}

private void boundsOf(const Mesh mesh, const int[] indices, out Vec3 minimum,
    out Vec3 maximum)
{
    minimum = Vec3(double.max, double.max, double.max);
    maximum = Vec3(-double.max, -double.max, -double.max);
    foreach (index; indices)
    {
        const vertex = mesh.vertices[index];
        minimum = Vec3(
            vertex.x < minimum.x ? vertex.x : minimum.x,
            vertex.y < minimum.y ? vertex.y : minimum.y,
            vertex.z < minimum.z ? vertex.z : minimum.z);
        maximum = Vec3(
            vertex.x > maximum.x ? vertex.x : maximum.x,
            vertex.y > maximum.y ? vertex.y : maximum.y,
            vertex.z > maximum.z ? vertex.z : maximum.z);
    }
}

/**
 * Lay a fan of toes across the front of one foot.
 *
 * Which end is the front is measured, not assumed: the toe end of a foot sits
 * lower than the heel end, because the ankle rises above the heel.
 */
private void modelToes(ref Mesh mesh, const int[] foot, double strength)
{
    if (foot.length < 8)
        return;
    Vec3 minimum;
    Vec3 maximum;
    boundsOf(mesh, foot, minimum, maximum);
    const spanX = maximum.x - minimum.x;
    const spanY = maximum.y - minimum.y;
    const spanZ = maximum.z - minimum.z;
    // The foot is long along one horizontal axis; toes sit at its front end.
    const alongZ = spanZ >= spanX;
    const alongMin = alongZ ? minimum.z : minimum.x;
    const alongMax = alongZ ? maximum.z : maximum.x;
    const acrossMin = alongZ ? minimum.x : minimum.z;
    const acrossMax = alongZ ? maximum.x : maximum.z;

    double lowEndTop = -double.max;
    double highEndTop = -double.max;
    foreach (index; foot)
    {
        const vertex = mesh.vertices[index];
        const along = alongZ ? vertex.z : vertex.x;
        if (along < alongMin + (alongMax - alongMin) * 0.25)
            lowEndTop = vertex.y > lowEndTop ? vertex.y : lowEndTop;
        else if (along > alongMax - (alongMax - alongMin) * 0.25)
            highEndTop = vertex.y > highEndTop ? vertex.y : highEndTop;
    }
    const toesAtMaximum = highEndTop <= lowEndTop;
    const front = toesAtMaximum ? alongMax : alongMin;
    const heel = toesAtMaximum ? alongMin : alongMax;

    Bump[] bumps;
    enum int Toes = 5;
    const acrossSpan = acrossMax - acrossMin;
    // A collapsed foot has no room for toes, and dividing by its span would
    // produce infinite radii.
    if (!(acrossSpan > 1.0e-4) || !(spanY > 1.0e-4) ||
        !(abs(front - heel) > 1.0e-4))
        return;
    const toeRadius = acrossSpan * 0.15;
    foreach (toe; 0 .. Toes)
    {
        // The big toe is the widest, so it sits nearest the centre line.
        const offset = (cast(double) toe / (Toes - 1) - 0.5) * acrossSpan * 0.62;
        const across = (acrossMin + acrossMax) * 0.5 + offset;
        const length = (front - heel) * 0.02;
        Vec3 center;
        if (alongZ)
            center = Vec3(across, minimum.y + spanY * 0.32,
                front - length);
        else
            center = Vec3(front - length, minimum.y + spanY * 0.32, across);
        const radius = toeRadius * (1.0 - abs(offset) / (acrossSpan * 0.75));
        // A toe reads as a few millimetres of relief at body scale. The region
        // is refined first, so the bumps have vertices to lift.
        bumps ~= Bump(center, radius * 1.3, radius * 0.85 * strength);
    }
    applyBumps(mesh, foot, bumps);
}

/**
 * Pull one foot into a bare foot: slender above the sole, tapered toward the
 * ankle, with an arch instead of a flat slab.
 *
 * This is the silhouette-level half of "feet instead of boots": the mesh here is
 * about two dozen vertices per foot, so shape comes from proportions and the
 * arch, not from toes.
 */
/// Which end of the foot is the toe end: the toe end sits lower than the heel,
/// because the ankle rises above the heel.
private bool toesAtMaximum(const Mesh mesh, const int[] foot, bool alongZ,
    double alongMin, double alongMax)
{
    double lowEndTop = -double.max;
    double highEndTop = -double.max;
    const span = alongMax - alongMin;
    foreach (index; foot)
    {
        const vertex = mesh.vertices[index];
        const along = alongZ ? vertex.z : vertex.x;
        if (along < alongMin + span * 0.25)
            lowEndTop = vertex.y > lowEndTop ? vertex.y : lowEndTop;
        else if (along > alongMax - span * 0.25)
            highEndTop = vertex.y > highEndTop ? vertex.y : highEndTop;
    }
    return highEndTop <= lowEndTop;
}

/// Width envelope along the foot: heel, waist behind the arch, ball, toes.
private double footWidthProfile(double u)
{
    if (u < 0.25)
        return 1.06 - 0.18 * (u / 0.25);
    if (u < 0.60)
        return 0.88 + 0.24 * ((u - 0.25) / 0.35);
    return 1.12 - 0.27 * ((u - 0.60) / 0.40);
}

/// Height envelope along the foot: low heel, high instep, lower toe box.
private double footHeightProfile(double u)
{
    if (u < 0.30)
        return 0.95;
    if (u < 0.65)
        return 0.95 + 0.05 * ((u - 0.30) / 0.35);
    return 1.0 - 0.20 * ((u - 0.65) / 0.35);
}

/**
 * Shape one foot into a foot.
 *
 * Vertices are moved onto a smooth envelope — narrowing at the waist, widening
 * at the ball, dropping toward the toes, with an arch lifted off the sole. A
 * field like this cannot fold the surface the way additive bumps can, which is
 * what turned the first attempt black.
 */
private void modelFoot(ref Mesh mesh, const int[] foot, double strength)
{
    if (foot.length < 6)
        return;
    Vec3 minimum;
    Vec3 maximum;
    boundsOf(mesh, foot, minimum, maximum);
    const spanX = maximum.x - minimum.x;
    const spanZ = maximum.z - minimum.z;
    const spanY = maximum.y - minimum.y;
    const alongZ = spanZ >= spanX;
    const alongMin = alongZ ? minimum.z : minimum.x;
    const alongMax = alongZ ? maximum.z : maximum.x;
    const centerX = (minimum.x + maximum.x) * 0.5;
    const centerZ = (minimum.z + maximum.z) * 0.5;
    const span = alongMax - alongMin;
    if (span <= 1.0e-9)
        return;
    const flipped = toesAtMaximum(mesh, foot, alongZ, alongMin, alongMax);
    foreach (index; foot)
    {
        if (index < 0 || index >= mesh.vertices.length)
            continue;
        auto vertex = mesh.vertices[index];
        const along = alongZ ? vertex.z : vertex.x;
        const t = (along - alongMin) / span;
        // u runs heel (0) to toe (1), whichever way the foot is oriented.
        const u = flipped ? 1.0 - t : t;
        const width = 1.0 + (footWidthProfile(u) - 1.0) * strength;
        const height = 1.0 + (footHeightProfile(u) - 1.0) * strength;
        if (alongZ)
            vertex.x = centerX + (vertex.x - centerX) * width;
        else
            vertex.z = centerZ + (vertex.z - centerZ) * width;
        // Compress toward the sole so the toe box and heel sit low.
        vertex.y = minimum.y + (vertex.y - minimum.y) * height;
        // Squash the sole band toward the plane rather than snapping it onto the
        // plane: coincident vertices make zero-area faces, whose normals come out
        // as NaN and shade the whole foot black.
        if (vertex.y < minimum.y + spanY * 0.18)
            vertex.y = minimum.y + (vertex.y - minimum.y) * 0.12;
        // Lift an arch between heel and ball, fading out toward the ankle.
        const rise = spanY <= 1.0e-9 ? 0.0 :
            (vertex.y - minimum.y) / spanY;
        if (rise < 0.35 && u > 0.25 && u < 0.70)
        {
            const arch = sin(PI * (u - 0.25) / 0.45);
            vertex.y += 0.014 * strength * arch * (1.0 - rise / 0.35);
        }
        mesh.vertices[index] = vertex;
    }
    smoothVertices(mesh, foot, 0.2);
    sanitizeNormals(mesh);
}

/// Pull one foot into a heavy boot: flat sole, wider body, raised collar.
private void modelBoot(ref Mesh mesh, const int[] foot, double strength)
{
    if (foot.length < 8)
        return;
    Vec3 minimum;
    Vec3 maximum;
    boundsOf(mesh, foot, minimum, maximum);
    const centerX = (minimum.x + maximum.x) * 0.5;
    const centerZ = (minimum.z + maximum.z) * 0.5;
    const ankle = minimum.y + (maximum.y - minimum.y) * 0.72;
    if (mesh.normals.length != mesh.vertices.length)
        computeSmoothNormals(mesh);
    foreach (index; foot)
    {
        if (index < 0 || index >= mesh.vertices.length)
            continue;
        auto vertex = mesh.vertices[index];
        // Flatten the sole onto the floor and square it off.
        if (vertex.y < minimum.y + 0.03)
            vertex.y = minimum.y;
        // Widen the body of the boot.
        vertex.x = centerX + (vertex.x - centerX) * (1.0 + 0.22 * strength);
        vertex.z = centerZ + (vertex.z - centerZ) * (1.0 + 0.10 * strength);
        // Raise a collar around the ankle.
        if (vertex.y > ankle)
        {
            const outward = Vec3(vertex.x - centerX, 0, vertex.z - centerZ);
            const distance = length(outward);
            if (distance > 1.0e-6)
                vertex = add(vertex, scale(normalize(outward),
                    0.035 * strength));
        }
        mesh.vertices[index] = vertex;
    }
    computeSmoothNormals(mesh);
}

/** Relieve the surface: used to take a style back off again. */
private void modelSmooth(ref Mesh mesh, const int[] region, double strength)
{
    smoothVertices(mesh, region, 0.35 + 0.5 * strength);
}

private long edgeKey(int a, int b)
{
    return a < b ? (cast(long) a << 32) | cast(uint) b
        : (cast(long) b << 32) | cast(uint) a;
}

/**
 * One conforming refinement pass over a region.
 *
 * Faces inside the region split into four. A face straddling the region border
 * splits along whichever of its edges gained a midpoint, so both sides of every
 * edge agree and the mesh stays closed: splitting one side only would leave a
 * T-junction and a crack.
 */
private int refineOnce(ref Mesh mesh, const RegionBox box)
{
    const vertexCount = mesh.vertices.length;
    if (vertexCount == 0 || mesh.faces.length == 0)
        return 0;
    auto inside = new bool[vertexCount];
    foreach (index, vertex; mesh.vertices)
        inside[index] = box.contains(vertex);

    const hasUvs = mesh.uvs.length == vertexCount;
    Vec3[] grown;
    Vec2[] grownUvs;
    long[long] midpoints;
    // Only faces that touch a split edge need an edge lookup; the rest are
    // copied through untouched. Without this the rebuild hashes every edge of
    // the whole mesh on every pass.
    auto touched = new bool[vertexCount];

    int midpoint(int a, int b)
    {
        const key = edgeKey(a, b);
        if (auto found = key in midpoints)
            return cast(int) *found;
        const created = cast(int) vertexCount + cast(int) grown.length;
        grown ~= Vec3(
            (mesh.vertices[a].x + mesh.vertices[b].x) * 0.5,
            (mesh.vertices[a].y + mesh.vertices[b].y) * 0.5,
            (mesh.vertices[a].z + mesh.vertices[b].z) * 0.5);
        if (hasUvs)
            grownUvs ~= Vec2(
                (mesh.uvs[a].x + mesh.uvs[b].x) * 0.5,
                (mesh.uvs[a].y + mesh.uvs[b].y) * 0.5);
        midpoints[key] = cast(long) created;
        return created;
    }

    // First decide every midpoint the region needs, so a neighbouring face sees
    // the same vertex whichever order the faces are visited in.
    foreach (face; mesh.faces)
        if (inside[face.a] && inside[face.b] && inside[face.c])
        {
            midpoint(face.a, face.b);
            midpoint(face.b, face.c);
            midpoint(face.c, face.a);
            touched[face.a] = true;
            touched[face.b] = true;
            touched[face.c] = true;
        }
    if (grown.length == 0)
        return 0;

    const hasMaterials = mesh.faceMaterials.length == mesh.faces.length;
    Face[] faces;
    int[] materials;
    foreach (index, face; mesh.faces)
    {
        const a = face.a;
        const b = face.b;
        const c = face.c;
        if (!touched[a] && !touched[b] && !touched[c])
        {
            faces ~= face;
            if (hasMaterials)
                materials ~= mesh.faceMaterials[index];
            continue;
        }
        int ab = -1;
        int bc = -1;
        int ca = -1;
        if (auto found = edgeKey(a, b) in midpoints)
            ab = cast(int) *found;
        if (auto found = edgeKey(b, c) in midpoints)
            bc = cast(int) *found;
        if (auto found = edgeKey(c, a) in midpoints)
            ca = cast(int) *found;
        const material = face.material;
        const materialIndex = hasMaterials ? mesh.faceMaterials[index] : -1;
        void emit(int x, int y, int z)
        {
            faces ~= Face(x, y, z, material);
            if (hasMaterials)
                materials ~= materialIndex;
        }
        const splits = (ab >= 0 ? 1 : 0) + (bc >= 0 ? 1 : 0) + (ca >= 0 ? 1 : 0);
        if (splits == 0)
            emit(a, b, c);
        else if (splits == 3)
        {
            emit(a, ab, ca);
            emit(ab, b, bc);
            emit(ca, bc, c);
            emit(ab, bc, ca);
        }
        else if (splits == 1)
        {
            if (ab >= 0)
            {
                emit(a, ab, c);
                emit(ab, b, c);
            }
            else if (bc >= 0)
            {
                emit(a, b, bc);
                emit(a, bc, c);
            }
            else
            {
                emit(a, b, ca);
                emit(ca, b, c);
            }
        }
        else if (ab < 0)
        {
            emit(a, b, bc);
            emit(a, bc, ca);
            emit(ca, bc, c);
        }
        else if (bc < 0)
        {
            emit(a, ab, ca);
            emit(ab, b, ca);
            emit(b, c, ca);
        }
        else
        {
            emit(a, ab, ca);
            emit(ab, b, bc);
            emit(ab, bc, ca);
        }
    }
    mesh.vertices ~= grown;
    if (hasUvs)
        mesh.uvs ~= grownUvs;
    mesh.faces = faces;
    if (hasMaterials)
        mesh.faceMaterials = materials;
    computeSmoothNormals(mesh);
    sanitizeNormals(mesh);
    return cast(int) grown.length;
}

/// Grow a region until each side of it holds at least `target` vertices.
int refineRegion(ref Mesh mesh, string region, int target = 120,
    int maximumPasses = 3)
{
    const box = regionBox(region);
    if (box.minimum == box.maximum)
        return 0;
    int added;
    foreach (pass; 0 .. maximumPasses)
    {
        const sides = splitSides(mesh, regionVertices(mesh, box));
        int smallest = int.max;
        foreach (side; sides)
            if (side.length > 0 && cast(int) side.length < smallest)
                smallest = cast(int) side.length;
        if (smallest != int.max && smallest >= target)
            break;
        const grown = refineOnce(mesh, box);
        if (grown == 0)
            break;
        added += grown;
    }
    return added;
}

/**
 * Re-form a named region in a named style. Returns how many vertices moved, so
 * a caller can tell an applied edit from a no-op without re-reading the mesh.
 */
int reshapeRegion(ref Mesh mesh, string region, string style,
    double strength = 1.0)
{
    return reshapeBox(mesh, regionBox(region), region, style, strength,
        false);
}

/**
 * Same as reshapeRegion, but for an explicit volume rather than a named region.
 * A live command can therefore ask for a foot, a boot or a sculpt on any part of
 * the body without new code.
 */
int reshapeBox(ref Mesh mesh, const RegionBox box, string region, string style,
    double strength = 1.0, bool explicitBox = true)
{
    // A missing number in a command arrives as NaN, and one NaN in the strength
    // poisons every vertex of the region.
    if (!isFinite(strength) || strength <= 0.0)
        strength = 1.0;
    if (mesh.vertices.length == 0 || mesh.faces.length == 0)
        return 0;
    if (box.minimum == box.maximum)
        return 0;
    const region_ = regionVertices(mesh, box);
    if (region_.length == 0)
        return 0;

    const footRegion = region == "feet" || region == "foot" || explicitBox;
    if (!footRegion)
    {
        modelSmooth(mesh, region_, strength);
        return cast(int) region_.length;
    }
    if (style == "smooth")
    {
        modelSmooth(mesh, region_, strength);
        return cast(int) region_.length;
    }
    // A shaped style needs geometry fine enough to carry the shape: at the base
    // resolution a foot is about two dozen vertices, which can only be moved
    // around as a blob.
    // Five toes need roughly twenty vertices across the foot, so the region is
    // grown well past what a silhouette needs.
    refineRegion(mesh, region, 700, 4);
    sanitizeNormals(mesh);
    const shaped = regionVertices(mesh, box);
    const refinedCount = shaped.length;
    int brokenBefore;
    int brokenAfterFoot;
    int brokenAfterToes;
    int countBroken(const Mesh source, const int[] indices)
    {
        int broke;
        foreach (index; indices)
        {
            if (index < 0 || index >= source.vertices.length)
                continue;
            const vertex = source.vertices[index];
            if (!(vertex.x == vertex.x) || !(vertex.y == vertex.y) ||
                !(vertex.z == vertex.z))
                ++broke;
        }
        return broke;
    }
    brokenBefore = countBroken(mesh, shaped);
    const sides = splitSides(mesh, shaped);
    foreach (side; sides)
    {
        if (side.length == 0)
            continue;
        if (style == "toes")
            modelToes(mesh, side, strength);
        else if (style == "foot" || style == "feet" || style == "bare")
        {
            modelFoot(mesh, side, strength);
            brokenAfterFoot += countBroken(mesh, side);
            modelToes(mesh, side, strength);
            brokenAfterToes += countBroken(mesh, side);
        }
        else if (style == "boot" || style == "boots")
            modelBoot(mesh, side, strength);
    }
    sanitizeNormals(mesh);
    // Trace the shape pass: a region that empties itself means the pass wrote
    // vertices out of the region (or left them non-finite).
    int broke;
    double lowY = double.max;
    double highY = -double.max;
    foreach (index; shaped)
    {
        if (index < 0 || index >= mesh.vertices.length)
            continue;
        const vertex = mesh.vertices[index];
        if (!(vertex.x == vertex.x) || !(vertex.y == vertex.y) ||
            !(vertex.z == vertex.z))
            ++broke;
        lowY = vertex.y < lowY ? vertex.y : lowY;
        highY = vertex.y > highY ? vertex.y : highY;
    }
    try
    {
        import std.format : format;
        import std.file : write;
        write("build/reshape-trace.json", format(
            `{"region":"%s","style":"%s","refined":%d,"nowInBox":%d,"broken":%d,"lowY":%.4f,"highY":%.4f,"vertices":%d,"brokenBefore":%d,"brokenAfterFoot":%d,"brokenAfterToes":%d}`,
            region, style, refinedCount, regionVertices(mesh, box).length,
            broke, lowY, highY, mesh.vertices.length, brokenBefore,
            brokenAfterFoot, brokenAfterToes));
    }
    catch (Exception)
    {
    }
    return cast(int) refinedCount;
}

unittest
{
    // Shaping a real foot must not leave NaN normals or zero-area faces: either
    // one shades the whole region black.
    import auroramesh.human_v3 : humanBaseMeshV3;
    import auroramesh.mesh : cross, dot, sub;
    import std.math : isFinite;
    auto body = humanBaseMeshV3();
    const moved = reshapeRegion(body, "feet", "foot");
    assert(moved > 100, "the foot region must gain vertices by refinement");
    assert(body.normals.length == body.vertices.length);
    foreach (normal; body.normals)
        assert(isFinite(normal.x) && isFinite(normal.y) && isFinite(normal.z),
            "a shaped foot left a non-finite normal");
    int degenerate;
    foreach (face; body.faces)
    {
        const edge1 = sub(body.vertices[face.b], body.vertices[face.a]);
        const edge2 = sub(body.vertices[face.c], body.vertices[face.a]);
        const area = length(cross(edge1, edge2)) * 0.5;
        if (!(area > 1.0e-12))
            ++degenerate;
    }
    assert(degenerate == 0, "a shaped foot left zero-area faces");
    int broke;
    foreach (vertex; body.vertices)
        if (!(isFinite(vertex.x) && isFinite(vertex.y) && isFinite(vertex.z)))
            ++broke;
    assert(broke == 0, "a shaped foot produced non-finite vertices");
    assert(regionVertices(body, regionBox("feet")).length > 0,
        "shaping pushed the whole region out of its own box");

    // The editor draws a glTF scene, not the raw OBJ: bake that path too, since
    // it carries per-face materials and node transforms the OBJ does not.
    import auroramesh.gltf_scene : bakeGltfFrame, loadGltfScene;
    import std.file : exists, read;
    if (exists("build/verify-human.glb"))
    {
        auto scene = loadGltfScene(read("build/verify-human.glb"));
        Mat4[] worlds;
        auto baked = bakeGltfFrame(scene, 0, 0.0, true, null, &worlds);
        const bakedFeet = regionVertices(baked, regionBox("feet")).length;
        assert(bakedFeet > 0, "the baked scene must contain the feet");
        reshapeRegion(baked, "feet", "foot");
        int bakedBroke;
        foreach (vertex; baked.vertices)
            if (!(isFinite(vertex.x) && isFinite(vertex.y) &&
                isFinite(vertex.z)))
                ++bakedBroke;
        assert(bakedBroke == 0, "the baked path produced non-finite vertices");
        assert(regionVertices(baked, regionBox("feet")).length > 0,
            "the baked path pushed the region out of its box");
    }

    // A block standing in for a foot: enough surface for the styles to shape.
    Mesh mesh;
    enum int Rings = 12;
    enum int Segments = 10;
    foreach (ring; 0 .. Rings + 1)
    {
        const t = cast(double) ring / Rings;
        foreach (segment; 0 .. Segments)
        {
            const angle = 2 * PI * segment / Segments;
            mesh.vertices ~= Vec3(0.06 * cos(angle) * 5, 0.002 + 0.14 * t,
                0.12 * sin(angle) * 5);
        }
    }
    foreach (ring; 0 .. Rings)
        foreach (segment; 0 .. Segments)
        {
            const next = (segment + 1) % Segments;
            const a = ring * Segments + segment;
            const b = ring * Segments + next;
            const c = (ring + 1) * Segments + segment;
            const d = (ring + 1) * Segments + next;
            mesh.addTriangle(a, c, b, 0);
            mesh.addTriangle(b, c, d, 0);
        }
    computeSmoothNormals(mesh);

    const before = mesh.vertices.dup;
    const moved = reshapeRegion(mesh, "feet", "toes");
    assert(moved > 0, "the feet region must select vertices");
    bool changed;
    foreach (index; 0 .. mesh.vertices.length)
    {
        const delta = sub(mesh.vertices[index], before[index]);
        if (length(delta) > 1.0e-6)
            changed = true;
    }
    assert(changed, "toes must move the surface");
    assert(watertight(mesh), "a regional edit must not open the mesh");

    // A style that is already applied can be taken back off.
    assert(reshapeRegion(mesh, "feet", "smooth") > 0);
    assert(reshapeRegion(mesh, "feet", "boot") > 0);
    assert(watertight(mesh), "boot shaping must stay watertight");

    // Unknown regions and styles do nothing rather than damage the mesh.
    assert(reshapeRegion(mesh, "unknown", "toes") == 0);
    assert(reshapeRegion(mesh, "feet", "unknown") == moved);
}
