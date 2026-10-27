module auroramesh.glb;

import auroramesh.mesh : Face, Material, Mesh, Vec3, add, computeSmoothNormals,
    cross, dot, length, normalize, scale, sub;
import aurora.image : RgbaImage, encodePng;
import std.array : join;
import std.conv : to;
import std.format : format;
import std.math : isFinite;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs, cos, sin, sqrt;
import std.string : strip;


private struct Mat4
{
    double[16] m;

    static Mat4 identity()
    {
        Mat4 result;
        foreach (ref value; result.m)
            value = 0;
        result.m[0] = 1;
        result.m[5] = 1;
        result.m[10] = 1;
        result.m[15] = 1;
        return result;
    }
}

private Mat4 multiply(const Mat4 a, const Mat4 b)
{
    Mat4 result;
    foreach (column; 0 .. 4)
        foreach (row; 0 .. 4)
        {
            double value = 0;
            foreach (k; 0 .. 4)
                value += a.m[k * 4 + row] * b.m[column * 4 + k];
            result.m[column * 4 + row] = value;
        }
    return result;
}

private Vec3 transformPoint(const Mat4 matrix, Vec3 point)
{
    return Vec3(
        matrix.m[0] * point.x + matrix.m[4] * point.y +
            matrix.m[8] * point.z + matrix.m[12],
        matrix.m[1] * point.x + matrix.m[5] * point.y +
            matrix.m[9] * point.z + matrix.m[13],
        matrix.m[2] * point.x + matrix.m[6] * point.y +
            matrix.m[10] * point.z + matrix.m[14]);
}

private Vec3 transformNormal(const Mat4 matrix, Vec3 normal)
{
    return normalize(Vec3(
        matrix.m[0] * normal.x + matrix.m[4] * normal.y +
            matrix.m[8] * normal.z,
        matrix.m[1] * normal.x + matrix.m[5] * normal.y +
            matrix.m[9] * normal.z,
        matrix.m[2] * normal.x + matrix.m[6] * normal.y +
            matrix.m[10] * normal.z));
}

private Mat4 trsMatrix(Vec3 translation, Vec3 rotation, double rotationW,
    Vec3 scaleValue)
{
    const x = rotation.x;
    const y = rotation.y;
    const z = rotation.z;
    const w = rotationW;
    Mat4 rotationMatrix = Mat4.identity();
    rotationMatrix.m[0] = 1 - 2 * (y * y + z * z);
    rotationMatrix.m[1] = 2 * (x * y + z * w);
    rotationMatrix.m[2] = 2 * (x * z - y * w);
    rotationMatrix.m[4] = 2 * (x * y - z * w);
    rotationMatrix.m[5] = 1 - 2 * (x * x + z * z);
    rotationMatrix.m[6] = 2 * (y * z + x * w);
    rotationMatrix.m[8] = 2 * (x * z + y * w);
    rotationMatrix.m[9] = 2 * (y * z - x * w);
    rotationMatrix.m[10] = 1 - 2 * (x * x + y * y);

    Mat4 scaleMatrix = Mat4.identity();
    scaleMatrix.m[0] = scaleValue.x;
    scaleMatrix.m[5] = scaleValue.y;
    scaleMatrix.m[10] = scaleValue.z;

    Mat4 translationMatrix = Mat4.identity();
    translationMatrix.m[12] = translation.x;
    translationMatrix.m[13] = translation.y;
    translationMatrix.m[14] = translation.z;

    return multiply(translationMatrix, multiply(rotationMatrix, scaleMatrix));
}

private string fixed(double value)
{
    return format("%.6g", value);
}

private ubyte[] buildGlb(string json, ubyte[] binary)
{
    while (json.length % 4 != 0)
        json ~= " ";
    while (binary.length % 4 != 0)
        binary ~= 0;
    const total = 12 + 8 + json.length + 8 + binary.length;
    auto result = new ubyte[total];
    void putU32(size_t offset, uint value)
    {
        result[offset] = cast(ubyte) (value & 0xff);
        result[offset + 1] = cast(ubyte) ((value >> 8) & 0xff);
        result[offset + 2] = cast(ubyte) ((value >> 16) & 0xff);
        result[offset + 3] = cast(ubyte) ((value >> 24) & 0xff);
    }
    putU32(0, 0x46546c67); // "glTF"
    putU32(4, 2);
    putU32(8, cast(uint) total);
    putU32(12, cast(uint) json.length);
    putU32(16, 0x4e4f534a); // "JSON"
    result[20 .. 20 + json.length] = cast(ubyte[]) json;
    const binHeader = 20 + json.length;
    putU32(binHeader, cast(uint) binary.length);
    putU32(binHeader + 4, 0x004e4942); // "BIN\0"
    result[binHeader + 8 .. binHeader + 8 + binary.length] = binary;
    return result;
}

private uint readU32(const ubyte[] data, size_t offset)
{
    return cast(uint) data[offset] |
        cast(uint) data[offset + 1] << 8 |
        cast(uint) data[offset + 2] << 16 |
        cast(uint) data[offset + 3] << 24;
}

private float readF32(const ubyte[] data, size_t offset)
{
    union Bits
    {
        uint u;
        float f;
    }
    Bits bits;
    bits.u = readU32(data, offset);
    return bits.f;
}

private void appendU32(ref ubyte[] data, uint value)
{
    data ~= cast(ubyte) (value & 0xff);
    data ~= cast(ubyte) ((value >> 8) & 0xff);
    data ~= cast(ubyte) ((value >> 16) & 0xff);
    data ~= cast(ubyte) ((value >> 24) & 0xff);
}

private void appendF32(ref ubyte[] data, float value)
{
    union Bits
    {
        uint u;
        float f;
    }
    Bits bits;
    bits.f = value;
    appendU32(data, bits.u);
}

private bool has(JSONValue value, string key)
{
    return value.type == JSONType.object && (key in value.object);
}

private JSONValue child(JSONValue value, string key)
{
    if (!has(value, key))
        return JSONValue();
    return value.object[key];
}

private double number(JSONValue value)
{
    switch (value.type)
    {
        case JSONType.integer:
            return cast(double) value.integer;
        case JSONType.uinteger:
            return cast(double) value.uinteger;
        case JSONType.float_:
            return value.floating;
        default:
            return 0;
    }
}

private int integer(JSONValue value, int fallback = 0)
{
    return value.type == JSONType.integer ? cast(int) value.integer :
        value.type == JSONType.uinteger ? cast(int) value.uinteger : fallback;
}

private double[] numberArray(JSONValue value)
{
    double[] result;
    if (value.type != JSONType.array)
        return result;
    foreach (item; value.array)
        result ~= number(item);
    return result;
}

private Vec3 vec3(JSONValue value, Vec3 fallback = Vec3(0, 0, 0))
{
    const values = numberArray(value);
    if (values.length < 3)
        return fallback;
    return Vec3(values[0], values[1], values[2]);
}

private Vec3 materialColor(Material material)
{
    final switch (material)
    {
        case Material.skin:
            return Vec3(0.64, 0.45, 0.33);
        case Material.cloth:
            return Vec3(0.18, 0.28, 0.34);
        case Material.accent:
            return Vec3(0.72, 0.48, 0.24);
        case Material.neutral:
            return Vec3(0.50, 0.55, 0.62);
        case Material.eye:
            return Vec3(0.05, 0.08, 0.12);
    }
}

private string materialName(Material material)
{
    final switch (material)
    {
        case Material.skin:
            return "skin";
        case Material.cloth:
            return "cloth";
        case Material.accent:
            return "accent";
        case Material.neutral:
            return "neutral";
        case Material.eye:
            return "eye";
    }
}

private Material closestMaterial(Vec3 color)
{
    Material best = Material.cloth;
    double bestDistance = double.infinity;
    foreach (material; [
        Material.skin, Material.cloth, Material.accent, Material.neutral,
        Material.eye])
    {
        const palette = materialColor(material);
        const distance = dot(sub(color, palette), sub(color, palette));
        if (distance < bestDistance)
        {
            bestDistance = distance;
            best = material;
        }
    }
    return best;
}

private string colorJson(Vec3 color)
{
    return format("[%s,%s,%s,1]", fixed(color.x), fixed(color.y),
        fixed(color.z));
}

/** Write a mesh as a glTF 2.0 binary container with embedded buffers. */
ubyte[] toGlb(Mesh source)
{
    Mesh mesh = source;
    if (mesh.normals.length != mesh.vertices.length)
        computeSmoothNormals(mesh);
    foreach (ref vertex; mesh.vertices)
        if (!isFinite(vertex.x) || !isFinite(vertex.y) ||
            !isFinite(vertex.z))
            vertex = Vec3(0, 0, 0);
    foreach (ref normal; mesh.normals)
        if (!isFinite(normal.x) || !isFinite(normal.y) ||
            !isFinite(normal.z))
            normal = Vec3(0, 0, 1);
    if (mesh.faces.length == 0)
        throw new Exception("cannot export an empty mesh to GLB");

    const customMaterials = mesh.materials.length > 0 &&
        mesh.faceMaterials.length == mesh.faces.length;
    const materialCount = customMaterials ? mesh.materials.length : 5;
    int[][] indices;
    indices.length = materialCount;
    foreach (faceIndex, face; mesh.faces)
    {
        const materialIndex = customMaterials ? mesh.faceMaterials[faceIndex] :
            cast(int) face.material;
        const safeMaterial = materialIndex >= 0 &&
            materialIndex < indices.length ? materialIndex : 0;
        indices[safeMaterial] ~= face.a;
        indices[safeMaterial] ~= face.b;
        indices[safeMaterial] ~= face.c;
    }

    ubyte[] binary;
    foreach (vertex; mesh.vertices)
    {
        appendF32(binary, cast(float) vertex.x);
        appendF32(binary, cast(float) vertex.y);
        appendF32(binary, cast(float) vertex.z);
    }
    const positionLength = binary.length;
    foreach (normal; mesh.normals)
    {
        appendF32(binary, cast(float) normal.x);
        appendF32(binary, cast(float) normal.y);
        appendF32(binary, cast(float) normal.z);
    }
    const normalLength = binary.length - positionLength;
    const hasUv = mesh.uvs.length == mesh.vertices.length;
    size_t uvOffset;
    size_t uvLength;
    if (hasUv)
    {
        uvOffset = binary.length;
        foreach (uv; mesh.uvs)
        {
            appendF32(binary, cast(float) uv.x);
            appendF32(binary, cast(float) uv.y);
        }
        uvLength = binary.length - uvOffset;
    }

    string[] bufferViewJson = [
        format(`{"buffer":0,"byteOffset":0,"byteLength":%d,"target":34962}`,
            positionLength),
        format(`{"buffer":0,"byteOffset":%d,"byteLength":%d,"target":34962}`,
            positionLength, normalLength),
    ];
    if (hasUv)
        bufferViewJson ~= format(
            `{"buffer":0,"byteOffset":%d,"byteLength":%d,"target":34962}`,
            uvOffset, uvLength);
    string[] accessorJson = [
        format(`{"bufferView":0,"componentType":5126,"count":%d,"type":"VEC3","min":[%s,%s,%s],"max":[%s,%s,%s]}`,
            mesh.vertices.length, fixed(meshMinimum(mesh).x),
            fixed(meshMinimum(mesh).y), fixed(meshMinimum(mesh).z),
            fixed(meshMaximum(mesh).x), fixed(meshMaximum(mesh).y),
            fixed(meshMaximum(mesh).z)),
        format(`{"bufferView":1,"componentType":5126,"count":%d,"type":"VEC3"}`,
            mesh.normals.length),
    ];
    if (hasUv)
        accessorJson ~= format(
            `{"bufferView":2,"componentType":5126,"count":%d,"type":"VEC2"}`,
            mesh.uvs.length);

    string[] primitiveJson;
    foreach (materialIndex; 0 .. materialCount)
    {
        const list = indices[materialIndex];
        if (list.length == 0)
            continue;
        const byteOffset = binary.length;
        foreach (index; list)
            appendU32(binary, cast(uint) index);
        const byteLength = binary.length - byteOffset;
        const viewIndex = bufferViewJson.length;
        bufferViewJson ~= format(
            `{"buffer":0,"byteOffset":%d,"byteLength":%d,"target":34963}`,
            byteOffset, byteLength);
        const accessorIndex = accessorJson.length;
        accessorJson ~= format(
            `{"bufferView":%d,"componentType":5125,"count":%d,"type":"SCALAR"}`,
            viewIndex, list.length);
        primitiveJson ~= format(
            `{"attributes":{"POSITION":0,"NORMAL":1%s},"indices":%d,"material":%d,"mode":4}`,
            hasUv ? `,"TEXCOORD_0":2` : "", accessorIndex, materialIndex);
    }

    int[] textureIndexBySlot;
    textureIndexBySlot.length = mesh.textures.length;
    foreach (ref value; textureIndexBySlot)
        value = -1;
    string[] imageJson;
    string[] textureJson;
    foreach (textureIndex, texture; mesh.textures)
    {
        if (texture is null)
            continue;
        const png = encodePng(texture);
        while (binary.length % 4 != 0)
            binary ~= 0;
        const byteOffset = binary.length;
        binary ~= png;
        const viewIndex = bufferViewJson.length;
        bufferViewJson ~= format(
            `{"buffer":0,"byteOffset":%d,"byteLength":%d}`, byteOffset,
            png.length);
        const imageIndex = imageJson.length;
        imageJson ~= format(`{"bufferView":%d,"mimeType":"image/png"}`,
            viewIndex);
        textureIndexBySlot[textureIndex] = cast(int) textureJson.length;
        textureJson ~= format(`{"source":%d,"sampler":0}`, imageIndex);
    }

    string[] materialJson;
    if (customMaterials)
    {
        foreach (index, slot; mesh.materials)
        {
            string pbr = format(
                `{"baseColorFactor":[%s,%s,%s,%s],"metallicFactor":0,"roughnessFactor":0.85`,
                fixed(slot.baseColor.x), fixed(slot.baseColor.y),
                fixed(slot.baseColor.z), fixed(slot.alpha));
            if (slot.texture >= 0 &&
                slot.texture < textureIndexBySlot.length &&
                textureIndexBySlot[slot.texture] >= 0)
                pbr ~= format(`,"baseColorTexture":{"index":%d}`,
                    textureIndexBySlot[slot.texture]);
            pbr ~= "}";
            string material = format(
                `{"name":"material%d","doubleSided":%s,"pbrMetallicRoughness":%s`,
                index, slot.doubleSided ? "true" : "false", pbr);
            if (slot.alpha < 1)
                material ~= `,"alphaMode":"BLEND"`;
            material ~= "}";
            materialJson ~= material;
        }
    }
    else
    {
        foreach (materialIndex; 0 .. materialCount)
        {
            const material = cast(Material) materialIndex;
            materialJson ~= format(
                `{"name":"%s","doubleSided":true,"pbrMetallicRoughness":{"baseColorFactor":%s,"metallicFactor":0,"roughnessFactor":0.85}}`,
                materialName(material), colorJson(materialColor(material)));
        }
    }

    string extras;
    if (imageJson.length > 0)
        extras = format(
            `,"images":[%s],"textures":[%s],"samplers":[{"magFilter":9729,"minFilter":9987,"wrapS":10497,"wrapT":10497}]`,
            imageJson.join(","), textureJson.join(","));
    const json = format(
        `{"asset":{"version":"2.0","generator":"aurora-mesh"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0,"name":"Human"}],"meshes":[{"name":"Human","primitives":[%s]}],"materials":[%s],"accessors":[%s],"bufferViews":[%s],"buffers":[{"byteLength":%d}]%s}`,
        primitiveJson.join(","), materialJson.join(","),
        accessorJson.join(","), bufferViewJson.join(","), binary.length,
        extras);
    return buildGlb(json, binary);
}

private Vec3[] readPositions(JSONValue accessors, JSONValue bufferViews,
    const ubyte[] binary, int accessorIndex)
{
    if (accessorIndex < 0 || accessorIndex >= accessors.array.length)
        throw new Exception("GLB accessor out of range");
    const accessor = accessors[accessorIndex];
    if (has(accessor, "sparse"))
        throw new Exception("sparse GLB accessors are not supported");
    const viewIndex = integer(child(accessor, "bufferView"), -1);
    if (viewIndex < 0 || viewIndex >= bufferViews.array.length)
        throw new Exception("GLB bufferView out of range");
    const view = bufferViews[viewIndex];
    if (integer(child(view, "buffer"), 0) != 0)
        throw new Exception("only embedded GLB buffers are supported");
    const componentType = integer(child(accessor, "componentType"), 5126);
    const type = has(accessor, "type") ? accessor.object["type"].str : "";
    if (componentType != 5126 || type != "VEC3")
        throw new Exception("GLB positions must be float VEC3");
    const count = integer(child(accessor, "count"), 0);
    const accessorOffset = integer(child(accessor, "byteOffset"), 0);
    const viewOffset = integer(child(view, "byteOffset"), 0);
    const stride = integer(child(view, "byteStride"), 12);
    const start = viewOffset + accessorOffset;
    Vec3[] result;
    result.length = count;
    foreach (index; 0 .. count)
    {
        const offset = start + index * stride;
        if (offset + 12 > binary.length)
            throw new Exception("GLB position data is truncated");
        result[index] = Vec3(readF32(binary, offset),
            readF32(binary, offset + 4), readF32(binary, offset + 8));
    }
    return result;
}

private int[] readIndices(JSONValue accessors, JSONValue bufferViews,
    const ubyte[] binary, int accessorIndex)
{
    if (accessorIndex < 0 || accessorIndex >= accessors.array.length)
        return [];
    const accessor = accessors[accessorIndex];
    if (has(accessor, "sparse"))
        throw new Exception("sparse GLB accessors are not supported");
    const viewIndex = integer(child(accessor, "bufferView"), -1);
    if (viewIndex < 0 || viewIndex >= bufferViews.array.length)
        return [];
    const view = bufferViews[viewIndex];
    if (integer(child(view, "buffer"), 0) != 0)
        throw new Exception("only embedded GLB buffers are supported");
    const componentType = integer(child(accessor, "componentType"), 5125);
    const count = integer(child(accessor, "count"), 0);
    const accessorOffset = integer(child(accessor, "byteOffset"), 0);
    const viewOffset = integer(child(view, "byteOffset"), 0);
    const stride = integer(child(view, "byteStride"), 0);
    const componentSize = componentType == 5121 ? 1 :
        componentType == 5123 ? 2 : 4;
    const step = stride > 0 ? stride : componentSize;
    const start = viewOffset + accessorOffset;
    int[] result;
    result.length = count;
    foreach (index; 0 .. count)
    {
        const offset = start + index * step;
        if (offset + componentSize > binary.length)
            throw new Exception("GLB index data is truncated");
        if (componentType == 5121)
            result[index] = binary[offset];
        else if (componentType == 5123)
            result[index] = binary[offset] | cast(int) binary[offset + 1] << 8;
        else if (componentType == 5125)
            result[index] = cast(int) readU32(binary, offset);
        else
            throw new Exception("unsupported GLB index component type");
    }
    return result;
}

/** Read a glTF 2.0 binary container into one triangle mesh. */
Mesh fromGlb(ubyte[] bytes)
{
    if (bytes.length < 20 || bytes[0 .. 4] != cast(ubyte[]) "glTF")
        throw new Exception("not a GLB file");
    if (readU32(bytes, 4) != 2)
        throw new Exception("only GLB version 2 is supported");
    if (readU32(bytes, 8) > bytes.length)
        throw new Exception("GLB length exceeds file size");

    string json;
    ubyte[] binary;
    size_t offset = 12;
    while (offset + 8 <= bytes.length)
    {
        const length = readU32(bytes, offset);
        const type = readU32(bytes, offset + 4);
        if (offset + 8 + length > bytes.length)
            throw new Exception("GLB chunk is truncated");
        if (type == 0x4e4f534a)
            json ~= cast(string) bytes[offset + 8 .. offset + 8 + length];
        else if (type == 0x004e4942)
            binary ~= bytes[offset + 8 .. offset + 8 + length];
        offset += 8 + length;
    }
    if (json.length == 0)
        throw new Exception("GLB has no JSON chunk");

    JSONValue document;
    try
        document = parseJSON(strip(json));
    catch (Exception error)
        throw new Exception("invalid GLB JSON: " ~ error.msg);
    const accessors = child(document, "accessors");
    const bufferViews = child(document, "bufferViews");
    const meshes = child(document, "meshes");
    const nodes = child(document, "nodes");
    const materials = child(document, "materials");
    if (meshes.type != JSONType.array || meshes.array.length == 0)
        throw new Exception("GLB has no meshes");


    Mesh mesh;
    bool[] visiting;
    visiting.length = nodes.type == JSONType.array ? nodes.array.length : 0;
    int[string] welded;

    void appendPrimitive(JSONValue primitive, Mat4 transform)
    {
        if (integer(child(primitive, "mode"), 4) != 4)
            return;
        const attributes = child(primitive, "attributes");
        const positionAccessor = integer(child(attributes, "POSITION"), -1);
        if (positionAccessor < 0)
            return;
        const localPositions = readPositions(accessors, bufferViews, binary,
            positionAccessor);
        const indexAccessor = integer(child(primitive, "indices"), -1);
        const localIndices = readIndices(accessors, bufferViews, binary,
            indexAccessor);
        if (indexAccessor >= 0 && localIndices.length == 0)
            return;
        Material material = Material.cloth;
        const materialIndex = integer(child(primitive, "material"), -1);
        if (materialIndex >= 0 && materials.type == JSONType.array &&
            materialIndex < materials.array.length)
        {
            const materialValue = materials[materialIndex];
            if (has(materialValue, "pbrMetallicRoughness"))
            {
                const pbr = child(materialValue, "pbrMetallicRoughness");
                const color = numberArray(child(pbr, "baseColorFactor"));
                if (color.length >= 3)
                    material = closestMaterial(Vec3(color[0], color[1],
                        color[2]));
            }
        }

        int[] globalIndices;
        globalIndices.length = localPositions.length;
        foreach (index, position; localPositions)
        {
            const transformed = transformPoint(transform, position);

            const key = format("%.6f/%.6f/%.6f", transformed.x,
                transformed.y, transformed.z);
            if (key in welded)
                globalIndices[index] = welded[key];
            else
            {
                const vertex = mesh.addVertex(transformed);
                welded[key] = vertex;
                globalIndices[index] = vertex;
            }
        }
        const indices = localIndices.length > 0 ? localIndices :
            cast(int[]) (() {
                int[] sequential;
                sequential.length = localPositions.length;
                foreach (index; 0 .. sequential.length)
                    sequential[index] = cast(int) index;
                return sequential;
            })();

        for (size_t index = 0; index + 2 < indices.length; index += 3)
        {
            if (indices[index] < 0 || indices[index] >= globalIndices.length ||
                indices[index + 1] < 0 ||
                indices[index + 1] >= globalIndices.length ||
                indices[index + 2] < 0 ||
                indices[index + 2] >= globalIndices.length)
                continue;
            mesh.addTriangle(globalIndices[indices[index]],
                globalIndices[indices[index + 1]],
                globalIndices[indices[index + 2]], material);
        }

    }

    void visitNode(int nodeIndex, Mat4 parent)
    {
        if (nodeIndex < 0 || nodeIndex >= nodes.array.length ||
            visiting[nodeIndex])
            return;
        visiting[nodeIndex] = true;
        const node = nodes[nodeIndex];
        Mat4 local = Mat4.identity();
        if (has(node, "matrix"))
        {
            const values = numberArray(child(node, "matrix"));
            if (values.length == 16)
                foreach (index; 0 .. 16)
                    local.m[index] = values[index];
        }
        else
        {
            const translation = vec3(child(node, "translation"));
            const rotationValues = numberArray(child(node, "rotation"));
            const rotation = rotationValues.length >= 4 ?
                Vec3(rotationValues[0], rotationValues[1], rotationValues[2]) :
                Vec3(0, 0, 0);
            const rotationW = rotationValues.length >= 4 ? rotationValues[3] : 1;
            const scaleValue = vec3(child(node, "scale"), Vec3(1, 1, 1));
            local = trsMatrix(translation, rotation, rotationW, scaleValue);
        }
        const world = multiply(parent, local);

        if (has(node, "mesh"))
        {
            const meshIndex = integer(child(node, "mesh"), -1);
            if (meshIndex >= 0 && meshIndex < meshes.array.length)
            {
                const meshValue = meshes[meshIndex];
                const primitives = child(meshValue, "primitives");
                if (primitives.type == JSONType.array)
                    foreach (primitive; primitives.array)
                        appendPrimitive(primitive, world);
            }
        }
        const children = child(node, "children");
        if (children.type == JSONType.array)
            foreach (childNode; children.array)
                visitNode(integer(childNode, -1), world);
        visiting[nodeIndex] = false;
    }

    const scenes = child(document, "scenes");
    if (nodes.type == JSONType.array && scenes.type == JSONType.array &&
        scenes.array.length > 0)
    {
        const sceneIndex = integer(child(document, "scene"), 0);
        const roots = child(scenes[sceneIndex], "nodes");
        if (roots.type == JSONType.array)
            foreach (root; roots.array)
                visitNode(integer(root, -1), Mat4.identity());
    }
    else
    {
        // No scene graph: import mesh 0 directly.
        const primitives = child(meshes[0], "primitives");
        if (primitives.type == JSONType.array)
            foreach (primitive; primitives.array)
                appendPrimitive(primitive, Mat4.identity());
    }
    if (mesh.vertices.length == 0 || mesh.faces.length == 0)
        throw new Exception("GLB produced no triangles");
    computeSmoothNormals(mesh);
    return mesh;
}

private Vec3 meshMinimum(const Mesh mesh)
{
    Vec3 result = Vec3(0, 0, 0);
    if (mesh.vertices.length == 0)
        return result;
    result = mesh.vertices[0];
    foreach (vertex; mesh.vertices)
    {
        if (vertex.x < result.x) result.x = vertex.x;
        if (vertex.y < result.y) result.y = vertex.y;
        if (vertex.z < result.z) result.z = vertex.z;
    }
    return result;
}

private Vec3 meshMaximum(const Mesh mesh)
{
    Vec3 result = Vec3(0, 0, 0);
    if (mesh.vertices.length == 0)
        return result;
    result = mesh.vertices[0];
    foreach (vertex; mesh.vertices)
    {
        if (vertex.x > result.x) result.x = vertex.x;
        if (vertex.y > result.y) result.y = vertex.y;
        if (vertex.z > result.z) result.z = vertex.z;
    }
    return result;
}

unittest
{
    Mesh mesh;
    const a = mesh.addVertex(Vec3(-0.5, -0.5, 0));
    const b = mesh.addVertex(Vec3(0.5, -0.5, 0));
    const c = mesh.addVertex(Vec3(0, 0.5, 0));
    const d = mesh.addVertex(Vec3(0, 0.5, 0.5));
    mesh.addTriangle(a, b, c, Material.cloth);
    mesh.addTriangle(a, c, d, Material.skin);
    computeSmoothNormals(mesh);
    const bytes = toGlb(mesh);
    const parsed = fromGlb(bytes);
    assert(parsed.vertices.length == 4);
    assert(parsed.faces.length == 2);
}