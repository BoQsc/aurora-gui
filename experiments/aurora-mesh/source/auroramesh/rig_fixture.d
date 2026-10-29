module auroramesh.rig_fixture;

import auroramesh.collision : findSelfIntersections;
import auroramesh.glb : buildGlb;
import auroramesh.gltf_scene : bakeGltfFrame, loadGltfScene;
import auroramesh.mesh : Material, Mesh, Vec3, add, computeSmoothNormals,
    cross, dot, length, lerp, normalize, scale, sub, validMesh;
import std.array : join;
import std.format : format;
import std.math : PI, abs, cos, sin, sqrt;

/** One bone of the fixture skeleton, positioned in bind pose. */
struct RigBone
{
    string name;
    int parent = -1;
    Vec3 position;
}

/** A small rigged mannequin plus the joint index of every vertex. */
struct RigFixture
{
    Mesh mesh;
    RigBone[] bones;
    int[] vertexJoint;
}

/**
 * Build the fixture: a ~1.8 m jointed mannequin whose segments are separate,
 * non-overlapping cylinders, boxes, and a sphere. Every vertex is rigidly bound
 * to one bone, so the rest pose has no self-intersections and the collision
 * audit stays meaningful while limbs move.
 */
RigFixture buildRigFixture()
{
    RigFixture fixture;
    fixture.bones = [
        RigBone("Root", -1, Vec3(0, 0, 0)),
        RigBone("Hips", 0, Vec3(0, 0.95, 0)),
        RigBone("Spine", 1, Vec3(0, 1.08, 0)),
        RigBone("Spine2", 2, Vec3(0, 1.30, 0)),
        RigBone("Neck", 3, Vec3(0, 1.50, 0)),
        RigBone("Head", 4, Vec3(0, 1.60, 0)),
        RigBone("LeftShoulder", 3, Vec3(0.20, 1.42, 0)),
        RigBone("LeftArm", 6, Vec3(0.24, 1.40, 0)),
        RigBone("LeftForeArm", 7, Vec3(0.26, 1.14, 0)),
        RigBone("LeftHand", 8, Vec3(0.27, 0.92, 0)),
        RigBone("RightShoulder", 3, Vec3(-0.20, 1.42, 0)),
        RigBone("RightArm", 10, Vec3(-0.24, 1.40, 0)),
        RigBone("RightForeArm", 11, Vec3(-0.26, 1.14, 0)),
        RigBone("RightHand", 12, Vec3(-0.27, 0.92, 0)),
        RigBone("LeftUpLeg", 1, Vec3(0.10, 0.92, 0)),
        RigBone("LeftLeg", 14, Vec3(0.11, 0.50, 0)),
        RigBone("LeftFoot", 15, Vec3(0.11, 0.08, 0)),
        RigBone("RightUpLeg", 1, Vec3(-0.10, 0.92, 0)),
        RigBone("RightLeg", 17, Vec3(-0.11, 0.50, 0)),
        RigBone("RightFoot", 18, Vec3(-0.11, 0.08, 0)),
    ];

    // Pelvis, torso, neck, and head. Every limb ends in a small cap at the
    // joint, so bent joints can approach each other without ever intersecting:
    // a cap radius below the joint inset keeps the disks apart at any angle.
    addBox(fixture, 1, Vec3(0, 1.00, 0), Vec3(0.125, 0.04, 0.085));
    addLimb(fixture, 2, Vec3(0, 1.04, 0), fixture.bones[2].position, 0.020,
        0.115, 0.020);
    addLimb(fixture, 3, fixture.bones[2].position, fixture.bones[3].position,
        0.020, 0.120, 0.020);
    addLimb(fixture, 4, fixture.bones[3].position, fixture.bones[4].position,
        0.015, 0.048, 0.015);
    addSphere(fixture, 5, Vec3(0, 1.70, 0), 0.11);

    // Arms.
    foreach (side; [1.0, -1.0])
    {
        const int shoulder = side > 0 ? 6 : 10;
        addLimb(fixture, shoulder, fixture.bones[shoulder].position,
            fixture.bones[shoulder + 1].position, 0.015, 0.040, 0.025);
        addLimb(fixture, shoulder + 1, fixture.bones[shoulder + 1].position,
            fixture.bones[shoulder + 2].position, 0.018, 0.050, 0.025);
        addLimb(fixture, shoulder + 2, fixture.bones[shoulder + 2].position,
            fixture.bones[shoulder + 3].position, 0.018, 0.042, 0.025);
        addBox(fixture, shoulder + 3,
            Vec3(0.27 * side, 0.87, 0.01), Vec3(0.030, 0.042, 0.026));
    }

    // Legs and feet.
    foreach (side; [1.0, -1.0])
    {
        const int hip = side > 0 ? 14 : 17;
        addLimb(fixture, hip, fixture.bones[hip].position,
            fixture.bones[hip + 1].position, 0.018, 0.070, 0.025);
        addLimb(fixture, hip + 1, fixture.bones[hip + 1].position,
            fixture.bones[hip + 2].position, 0.018, 0.050, 0.025);
        addBox(fixture, hip + 2,
            Vec3(0.11 * side, 0.045, 0.045), Vec3(0.045, 0.040, 0.075));
    }

    computeSmoothNormals(fixture.mesh);
    return fixture;
}

/**
 * A limb segment: a tapered tube from one joint to the next with a pinched,
 * small cap at each end. Cap radius below the inset is what keeps two joint
 * caps apart at every bend angle, which keeps the fixture auditable.
 */
void addLimb(ref RigFixture fixture, int joint, Vec3 from, Vec3 to,
    double jointRadius, double bodyRadius, double inset, int sides = 10)
{
    const direction = normalize(sub(to, from));
    if (length(direction) < 0.5)
        return;
    const reference = abs(direction.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0);
    const side = normalize(cross(direction, reference));
    const up = normalize(cross(direction, side));
    const start = add(from, scale(direction, inset));
    const end = sub(to, scale(direction, inset));
    const double[4] fractions = [0.0, 0.22, 0.78, 1.0];
    const double[4] radii = [jointRadius, bodyRadius, bodyRadius, jointRadius];
    const base = cast(int) fixture.mesh.vertices.length;
    foreach (ring; 0 .. 4)
    {
        const center = lerp(start, end, fractions[ring]);
        foreach (segment; 0 .. sides)
        {
            const angle = 2.0 * PI * segment / sides;
            fixture.mesh.vertices ~= add(center,
                add(scale(side, cos(angle) * radii[ring]),
                    scale(up, sin(angle) * radii[ring])));
            fixture.vertexJoint ~= joint;
        }
    }
    foreach (ring; 0 .. 3)
        foreach (segment; 0 .. sides)
        {
            const next = (segment + 1) % sides;
            const ringA = base + ring * sides + segment;
            const ringB = base + ring * sides + next;
            const ringC = base + (ring + 1) * sides + segment;
            const ringD = base + (ring + 1) * sides + next;
            fixture.mesh.addTriangle(ringA, ringB, ringC, Material.neutral);
            fixture.mesh.addTriangle(ringB, ringD, ringC, Material.neutral);
        }
    const capStart = fixture.mesh.addVertex(start);
    const capEnd = fixture.mesh.addVertex(end);
    fixture.vertexJoint ~= joint;
    fixture.vertexJoint ~= joint;
    foreach (segment; 0 .. sides)
    {
        const next = (segment + 1) % sides;
        fixture.mesh.addTriangle(capStart, base + next, base + segment,
            Material.neutral);
        fixture.mesh.addTriangle(capEnd, base + 3 * sides + segment,
            base + 3 * sides + next, Material.neutral);
    }
}

void addBox(ref RigFixture fixture, int joint, Vec3 center, Vec3 half)
{
    double[2] xs = [center.x - half.x, center.x + half.x];
    double[2] ys = [center.y - half.y, center.y + half.y];
    double[2] zs = [center.z - half.z, center.z + half.z];
    int[8] corner;
    foreach (xi; 0 .. 2)
        foreach (yi; 0 .. 2)
            foreach (zi; 0 .. 2)
            {
                corner[xi * 4 + yi * 2 + zi] =
                    fixture.mesh.addVertex(Vec3(xs[xi], ys[yi], zs[zi]));
                fixture.vertexJoint ~= joint;
            }
    void face(int a, int b, int c, int d)
    {
        fixture.mesh.addTriangle(corner[a], corner[b], corner[c],
            Material.neutral);
        fixture.mesh.addTriangle(corner[a], corner[c], corner[d],
            Material.neutral);
    }
    // +X, -X, +Y, -Y, +Z, -Z with outward winding.
    face(4, 5, 7, 6);
    face(0, 2, 3, 1);
    face(2, 3, 7, 6);
    face(0, 1, 5, 4);
    face(1, 3, 7, 5);
    face(0, 4, 6, 2);
}

void addSphere(ref RigFixture fixture, int joint, Vec3 center, double radius,
    int segments = 16, int rings = 10)
{
    const int top = fixture.mesh.addVertex(
        Vec3(center.x, center.y + radius, center.z));
    fixture.vertexJoint ~= joint;
    int[][] rows;
    rows.length = rings - 1;
    foreach (ring; 1 .. rings)
    {
        const theta = PI * ring / rings;
        const ringRadius = sin(theta);
        rows[ring - 1].length = segments;
        foreach (segment; 0 .. segments)
        {
            const angle = 2.0 * PI * segment / segments;
            rows[ring - 1][segment] = fixture.mesh.addVertex(Vec3(
                center.x + cos(angle) * ringRadius * radius,
                center.y + cos(theta) * radius,
                center.z + sin(angle) * ringRadius * radius));
            fixture.vertexJoint ~= joint;
        }
    }
    const int bottom = fixture.mesh.addVertex(
        Vec3(center.x, center.y - radius, center.z));
    fixture.vertexJoint ~= joint;
    foreach (segment; 0 .. segments)
    {
        const next = (segment + 1) % segments;
        fixture.mesh.addTriangle(top, rows[0][segment], rows[0][next],
            Material.neutral);
    }
    foreach (ring; 0 .. rows.length - 1)
        foreach (segment; 0 .. segments)
        {
            const next = (segment + 1) % segments;
            fixture.mesh.addQuad(rows[ring][segment], rows[ring + 1][segment],
                rows[ring + 1][next], rows[ring][next], Material.neutral);
        }
    foreach (segment; 0 .. segments)
    {
        const next = (segment + 1) % segments;
        fixture.mesh.addTriangle(bottom, rows[$ - 1][next], rows[$ - 1][segment],
            Material.neutral);
    }
}

private string fixed(double value)
{
    return format("%.6g", value);
}

private void appendF32(ref ubyte[] binary, float value)
{
    const bits = *cast(uint*) &value;
    binary ~= cast(ubyte) (bits & 0xff);
    binary ~= cast(ubyte) ((bits >> 8) & 0xff);
    binary ~= cast(ubyte) ((bits >> 16) & 0xff);
    binary ~= cast(ubyte) ((bits >> 24) & 0xff);
}

private void appendU32(ref ubyte[] binary, uint value)
{
    binary ~= cast(ubyte) (value & 0xff);
    binary ~= cast(ubyte) ((value >> 8) & 0xff);
    binary ~= cast(ubyte) ((value >> 16) & 0xff);
    binary ~= cast(ubyte) ((value >> 24) & 0xff);
}

/** Write the fixture as a skinned, single-mesh glTF 2.0 binary. */
ubyte[] rigFixtureGlb(RigFixture fixture)
{
    const mesh = fixture.mesh;
    const jointCount = fixture.bones.length;
    ubyte[] binary;
    string[] viewJson;
    string[] accessorJson;

    int addView(size_t offset, size_t byteLength, int target)
    {
        const int index = cast(int) viewJson.length;
        viewJson ~= target > 0 ?
            format(`{"buffer":0,"byteOffset":%d,"byteLength":%d,"target":%d}`,
                offset, byteLength, target) :
            format(`{"buffer":0,"byteOffset":%d,"byteLength":%d}`, offset,
                byteLength);
        return index;
    }

    // Positions.
    Vec3 minimum = mesh.vertices[0];
    Vec3 maximum = mesh.vertices[0];
    foreach (vertex; mesh.vertices)
    {
        minimum = Vec3(vertex.x < minimum.x ? vertex.x : minimum.x,
            vertex.y < minimum.y ? vertex.y : minimum.y,
            vertex.z < minimum.z ? vertex.z : minimum.z);
        maximum = Vec3(vertex.x > maximum.x ? vertex.x : maximum.x,
            vertex.y > maximum.y ? vertex.y : maximum.y,
            vertex.z > maximum.z ? vertex.z : maximum.z);
        appendF32(binary, cast(float) vertex.x);
        appendF32(binary, cast(float) vertex.y);
        appendF32(binary, cast(float) vertex.z);
    }
    const positionView = addView(0, binary.length, 34962);
    accessorJson ~= format(
        `{"bufferView":%d,"componentType":5126,"count":%d,"type":"VEC3","min":[%s,%s,%s],"max":[%s,%s,%s]}`,
        positionView, mesh.vertices.length, fixed(minimum.x), fixed(minimum.y),
        fixed(minimum.z), fixed(maximum.x), fixed(maximum.y), fixed(maximum.z));

    // Normals.
    const normalOffset = binary.length;
    foreach (normal; mesh.normals)
    {
        appendF32(binary, cast(float) normal.x);
        appendF32(binary, cast(float) normal.y);
        appendF32(binary, cast(float) normal.z);
    }
    const normalView = addView(normalOffset, binary.length - normalOffset,
        34962);
    accessorJson ~= format(
        `{"bufferView":%d,"componentType":5126,"count":%d,"type":"VEC3"}`,
        normalView, mesh.normals.length);

    // Rigid joint indices and weights.
    const jointOffset = binary.length;
    foreach (vertexIndex; 0 .. mesh.vertices.length)
        foreach (component; 0 .. 4)
        {
            const value = component == 0 ? fixture.vertexJoint[vertexIndex] : 0;
            binary ~= cast(ubyte) value;
        }
    const jointView = addView(jointOffset, binary.length - jointOffset, 34962);
    accessorJson ~= format(
        `{"bufferView":%d,"componentType":5121,"count":%d,"type":"VEC4"}`,
        jointView, mesh.vertices.length);
    const weightOffset = binary.length;
    foreach (vertexIndex; 0 .. mesh.vertices.length)
        foreach (component; 0 .. 4)
            appendF32(binary, component == 0 ? 1.0f : 0.0f);
    const weightView = addView(weightOffset, binary.length - weightOffset,
        34962);
    accessorJson ~= format(
        `{"bufferView":%d,"componentType":5126,"count":%d,"type":"VEC4"}`,
        weightView, mesh.vertices.length);

    // Indices.
    const indexOffset = binary.length;
    foreach (face; mesh.faces)
    {
        appendU32(binary, cast(uint) face.a);
        appendU32(binary, cast(uint) face.b);
        appendU32(binary, cast(uint) face.c);
    }
    const indexView = addView(indexOffset, binary.length - indexOffset, 34963);
    accessorJson ~= format(
        `{"bufferView":%d,"componentType":5125,"count":%d,"type":"SCALAR"}`,
        indexView, mesh.faces.length * 3);

    // Inverse bind matrices (bind pose has no rotation, so translation only).
    const bindOffset = binary.length;
    foreach (bone; fixture.bones)
    {
        double[16] matrix;
        // D initializes floating point to NaN, so clear every element.
        foreach (ref value; matrix)
            value = 0;
        matrix[0] = 1;
        matrix[5] = 1;
        matrix[10] = 1;
        matrix[15] = 1;
        matrix[12] = -bone.position.x;
        matrix[13] = -bone.position.y;
        matrix[14] = -bone.position.z;
        foreach (value; matrix)
            appendF32(binary, cast(float) value);
    }
    const bindView = addView(bindOffset, binary.length - bindOffset, 0);
    accessorJson ~= format(
        `{"bufferView":%d,"componentType":5126,"count":%d,"type":"MAT4"}`,
        bindView, fixture.bones.length);

    string[] nodeJson = [`{"name":"Body","mesh":0,"skin":0}`];
    foreach (index, bone; fixture.bones)
    {
        const parentPosition = bone.parent >= 0 ?
            fixture.bones[bone.parent].position : Vec3(0, 0, 0);
        int[] children;
        foreach (candidate, other; fixture.bones)
            if (other.parent == cast(int) index)
                children ~= cast(int) candidate + 1;
        string[] parts = [
            format(`"name":"%s"`, bone.name),
            format(`"translation":[%s,%s,%s]`, fixed(bone.position.x -
                parentPosition.x), fixed(bone.position.y - parentPosition.y),
                fixed(bone.position.z - parentPosition.z)),
        ];
        if (children.length > 0)
        {
            string[] childText;
            foreach (child; children)
                childText ~= format("%d", child);
            parts ~= format(`"children":[%s]`, childText.join(","));
        }
        nodeJson ~= format("{%s}", parts.join(","));
    }

    string[] jointText;
    foreach (index; 0 .. jointCount)
        jointText ~= format("%d", index + 1);

    const document = format(
        `{"asset":{"version":"2.0","generator":"aurora-mesh rig fixture"},` ~
        `"scene":0,"scenes":[{"nodes":[%s]}],"nodes":[%s],` ~
        `"meshes":[{"name":"Body","primitives":[{"attributes":{"POSITION":0,"NORMAL":1,"JOINTS_0":2,"WEIGHTS_0":3},"indices":4,"material":0,"mode":4}]}],` ~
        `"skins":[{"joints":[%s],"inverseBindMatrices":5}],` ~
        `"materials":[{"name":"fixture","doubleSided":false,"pbrMetallicRoughness":{"baseColorFactor":[0.62,0.68,0.76,1],"metallicFactor":0,"roughnessFactor":0.85}}],` ~
        `"accessors":[%s],"bufferViews":[%s],"buffers":[{"byteLength":%d}]}`,
        format("%d", jointCount + 1), nodeJson.join(","), jointText.join(","),
        accessorJson.join(","), viewJson.join(","), binary.length);
    return buildGlb(document, binary);
}

unittest
{
    auto fixture = buildRigFixture();
    assert(validMesh(fixture.mesh));
    assert(fixture.mesh.vertices.length == fixture.vertexJoint.length);
    assert(fixture.bones.length >= 18);
    assert(fixture.mesh.faces.length > 200);

    // Outward winding: the closed, non-overlapping parts must enclose volume.
    double volume;
    foreach (face; fixture.mesh.faces)
    {
        const a = fixture.mesh.vertices[face.a];
        const b = fixture.mesh.vertices[face.b];
        const c = fixture.mesh.vertices[face.c];
        volume += (a.x * (b.y * c.z - b.z * c.y) -
            a.y * (b.x * c.z - b.z * c.x) +
            a.z * (b.x * c.y - b.y * c.x)) / 6.0;
    }
    assert(volume > 0.05, "fixture parts are inside out");

    // The rest pose must be free of self-intersections so the audit is useful.
    const report = findSelfIntersections(fixture.mesh);
    assert(report.pairs == 0, "fixture segments overlap at rest");

    // Every vertex is bound to a real joint that owns geometry.
    auto used = new bool[fixture.bones.length];
    foreach (joint; fixture.vertexJoint)
    {
        assert(joint >= 0 && joint < fixture.bones.length);
        used[joint] = true;
    }
    foreach (index, bone; fixture.bones)
        assert(used[index] || bone.name == "Root",
            "bone has no geometry: " ~ bone.name);

    // The written GLB must reload as a skinned scene whose rest pose matches.
    auto scene = loadGltfScene(rigFixtureGlb(fixture));
    assert(scene.skins.length == 1);
    assert(scene.skins[0].joints.length == fixture.bones.length);
    const baked = bakeGltfFrame(scene, -1, 0, false);
    assert(baked.vertices.length == fixture.mesh.vertices.length);
    foreach (index, vertex; baked.vertices)
    {
        const source = fixture.mesh.vertices[index];
        assert(abs(vertex.x - source.x) < 1e-3 &&
            abs(vertex.y - source.y) < 1e-3 &&
            abs(vertex.z - source.z) < 1e-3,
            "skinned rest pose differs from the bind pose");
    }
}
