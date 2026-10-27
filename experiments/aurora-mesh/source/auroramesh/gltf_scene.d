module auroramesh.gltf_scene;

import aurora.image : RgbaImage, decodeImage;
import auroramesh.mesh : Material, MaterialSlot, Mesh, Vec2, Vec3,
    computeSmoothNormals, add;
import std.array : join;
import std.base64 : Base64;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs, atan2, cos, floor, sqrt, sin;
import std.string : endsWith, indexOf, startsWith, strip;

struct Mat4
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
    return Vec3(
        matrix.m[0] * normal.x + matrix.m[4] * normal.y +
            matrix.m[8] * normal.z,
        matrix.m[1] * normal.x + matrix.m[5] * normal.y +
            matrix.m[9] * normal.z,
        matrix.m[2] * normal.x + matrix.m[6] * normal.y +
            matrix.m[10] * normal.z);
}

private double[] quatNormalize(double[] q)
{
    const magnitude = sqrt(q[0] * q[0] + q[1] * q[1] +
        q[2] * q[2] + q[3] * q[3]);
    if (magnitude <= 1e-12)
        return [0.0, 0.0, 0.0, 1.0];
    return [q[0] / magnitude, q[1] / magnitude, q[2] / magnitude,
        q[3] / magnitude];
}

private Mat4 trsMatrix(Vec3 translation, double[] rotation, Vec3 scaleValue)
{
    const q = quatNormalize(rotation.length >= 4 ? rotation :
        [0.0, 0.0, 0.0, 1.0]);
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    Mat4 result = Mat4.identity();
    result.m[0] = (1 - 2 * (y * y + z * z)) * scaleValue.x;
    result.m[1] = (2 * (x * y + z * w)) * scaleValue.x;
    result.m[2] = (2 * (x * z - y * w)) * scaleValue.x;
    result.m[4] = (2 * (x * y - z * w)) * scaleValue.y;
    result.m[5] = (1 - 2 * (x * x + z * z)) * scaleValue.y;
    result.m[6] = (2 * (y * z + x * w)) * scaleValue.y;
    result.m[8] = (2 * (x * z + y * w)) * scaleValue.z;
    result.m[9] = (2 * (y * z - x * w)) * scaleValue.z;
    result.m[10] = (1 - 2 * (x * x + y * y)) * scaleValue.z;
    result.m[12] = translation.x;
    result.m[13] = translation.y;
    result.m[14] = translation.z;
    return result;
}

private Vec3 vec3(JSONValue value, Vec3 fallback)
{
    const values = numberArray(value);
    if (values.length < 3)
        return fallback;
    return Vec3(values[0], values[1], values[2]);
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

private uint readU32(const ubyte[] data, size_t offset)
{
    return cast(uint) data[offset] |
        cast(uint) data[offset + 1] << 8 |
        cast(uint) data[offset + 2] << 16 |
        cast(uint) data[offset + 3] << 24;
}

private ushort readU16(const ubyte[] data, size_t offset)
{
    return cast(ushort) (data[offset] | cast(ushort) data[offset + 1] << 8);
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

private struct AccessorData
{
    int components;
    int count;
    double[] values;
}

private int typeComponents(string type)
{
    final switch (type)
    {
        case "SCALAR": return 1;
        case "VEC2": return 2;
        case "VEC3": return 3;
        case "VEC4": return 4;
        case "MAT2": return 4;
        case "MAT3": return 9;
        case "MAT4": return 16;
    }
}

private double componentAt(const ubyte[] data, size_t offset,
    int componentType, bool normalized)
{
    double value;
    switch (componentType)
    {
        case 5120:
            value = cast(byte) data[offset];
            if (normalized)
                value = value < 0 ? value / 127.0 : value / 127.0;
            return value;
        case 5121:
            value = data[offset];
            return normalized ? value / 255.0 : value;
        case 5122:
            value = cast(short) (data[offset] | cast(ushort) data[offset + 1] << 8);
            return normalized ? value / 32767.0 : value;
        case 5123:
            value = readU16(data, offset);
            return normalized ? value / 65535.0 : value;
        case 5125:
            value = readU32(data, offset);
            return value;
        case 5126:
            return readF32(data, offset);
        default:
            return 0;
    }
}

private int componentSize(int componentType)
{
    return componentType == 5120 || componentType == 5121 ? 1 :
        componentType == 5122 || componentType == 5123 ? 2 : 4;
}

private AccessorData readAccessor(JSONValue document, ubyte[][] buffers,
    int accessorIndex)
{
    AccessorData result;
    if (accessorIndex < 0)
        return result;
    const accessors = child(document, "accessors");
    if (accessorIndex >= accessors.array.length)
        return result;
    const accessor = accessors[accessorIndex];
    const componentType = integer(child(accessor, "componentType"), 5126);
    const normalized = integer(child(accessor, "normalized"), 0) != 0;
    const count = integer(child(accessor, "count"), 0);
    const type = has(accessor, "type") ? accessor.object["type"].str : "";
    const components = typeComponents(type);
    result.components = components;
    result.count = count;
    result.values.length = count * components;
    if (has(accessor, "bufferView"))
    {
        const bufferViews = child(document, "bufferViews");
        const viewIndex = integer(child(accessor, "bufferView"), -1);
        if (viewIndex >= 0 && viewIndex < bufferViews.array.length)
        {
            const view = bufferViews[viewIndex];
            const bufferIndex = integer(child(view, "buffer"), 0);
            if (bufferIndex >= 0 && bufferIndex < buffers.length)
            {
                const buffer = buffers[bufferIndex];
                const viewOffset = integer(child(view, "byteOffset"), 0);
                const accessorOffset = integer(child(accessor, "byteOffset"), 0);
                const elementSize = componentSize(componentType) * components;
                const stride = integer(child(view, "byteStride"), elementSize);
                foreach (index; 0 .. count)
                {
                    const base = viewOffset + accessorOffset + index * stride;
                    foreach (component; 0 .. components)
                        result.values[index * components + component] =
                            componentAt(buffer, base +
                                component * componentSize(componentType),
                                componentType, normalized);
                }
            }
        }
    }
    if (has(accessor, "sparse"))
    {
        const sparse = child(accessor, "sparse");
        const sparseCount = integer(child(sparse, "count"), 0);
        const indices = child(sparse, "indices");
        const values = child(sparse, "values");
        const bufferViews = child(document, "bufferViews");
        const indexView = integer(child(indices, "bufferView"), -1);
        const valueView = integer(child(values, "bufferView"), -1);
        if (indexView >= 0 && valueView >= 0 &&
            indexView < bufferViews.array.length &&
            valueView < bufferViews.array.length)
        {
            const indexBuffer = buffers[
                integer(child(bufferViews[indexView], "buffer"), 0)];
            const valueBuffer = buffers[
                integer(child(bufferViews[valueView], "buffer"), 0)];
            const indexOffset = integer(child(bufferViews[indexView],
                "byteOffset"), 0) + integer(child(indices, "byteOffset"), 0);
            const valueOffset = integer(child(bufferViews[valueView],
                "byteOffset"), 0) + integer(child(values, "byteOffset"), 0);
            const indexType = integer(child(indices, "componentType"), 5123);
            foreach (item; 0 .. sparseCount)
            {
                const target = cast(int) componentAt(indexBuffer,
                    indexOffset + item * componentSize(indexType),
                    indexType, false);
                if (target < 0 || target >= count)
                    continue;
                foreach (component; 0 .. components)
                    result.values[target * components + component] =
                        componentAt(valueBuffer, valueOffset +
                            (item * components + component) *
                            componentSize(componentType),
                            componentType, normalized);
            }
        }
    }
    return result;
}

struct GNode
{
    string name;
    Mat4 matrix;
    Vec3 translation;
    double[4] rotation;
    Vec3 scale;
    bool hasMatrix;
    int mesh = -1;
    int skin = -1;
    int[] children;
}

struct GPrimitive
{
    int position = -1;
    int normal = -1;
    int uv = -1;
    int joints = -1;
    int weights = -1;
    int indices = -1;
    int material = -1;
    int mode = 4;
    int[][] targetPositions;
    int[][] targetNormals;
}

struct GMesh
{
    string name;
    GPrimitive[] primitives;
    double[] weights;
}

struct GMaterial
{
    Vec3 baseColor = Vec3(1, 1, 1);
    double alpha = 1;
    double alphaCutoff = 0.5;
    string alphaMode = "OPAQUE";
    int baseTexture = -1;
    bool doubleSided;
}

struct GImage
{
    string name;
    RgbaImage image;
}

struct GTexture
{
    int image = -1;
    int wrapS = 10497;
    int wrapT = 10497;
}

struct GSkin
{
    int[] joints;
    int inverseBind = -1;
}

struct GChannel
{
    int node = -1;
    string path;
    int input = -1;
    int output = -1;
    string interpolation = "LINEAR";
}

struct GAnimation
{
    string name;
    GChannel[] channels;
}

struct GltfScene
{
    string name;
    ubyte[] source;
    JSONValue document;
    ubyte[][] buffers;
    GNode[] nodes;
    GMesh[] meshes;
    GMaterial[] materials;
    GImage[] images;
    GTexture[] textures;
    GSkin[] skins;
    GAnimation[] animations;
    int[] roots;
    double[] meshWeights = [];
}

private ubyte[] dataUri(string uri)
{
    const comma = uri.indexOf(",");
    if (comma < 0 || !uri.startsWith("data:"))
        return null;
    const header = uri[5 .. comma];
    if (!header.endsWith(";base64"))
        return null;
    return Base64.decode(uri[comma + 1 .. $]);
}

/** Parse a complete embedded glTF 2.0 binary scene. */
GltfScene loadGltfScene(ubyte[] bytes)
{
    if (bytes.length < 20 || bytes[0 .. 4] != cast(ubyte[]) "glTF")
        throw new Exception("not a GLB file");
    if (readU32(bytes, 4) != 2)
        throw new Exception("only GLB version 2 is supported");
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

    GltfScene scene;
    scene.source = bytes;
    scene.document = document;
    scene.name = has(child(document, "asset"), "generator") ?
        document["asset"]["generator"].str : "GLB scene";
    const bufferValues = child(document, "buffers");
    if (bufferValues.type == JSONType.array)
    {
        foreach (buffer; bufferValues.array)
        {
            if (has(buffer, "uri"))
                scene.buffers ~= dataUri(buffer.object["uri"].str);
            else
                scene.buffers ~= binary;
        }
    }
    if (scene.buffers.length == 0)
        scene.buffers ~= binary;

    const imageValues = child(document, "images");
    if (imageValues.type == JSONType.array)
        foreach (image; imageValues.array)
        {
            GImage result;
            result.name = has(image, "name") ? image["name"].str : "";
            if (has(image, "bufferView"))
            {
                const viewIndex = integer(child(image, "bufferView"), -1);
                const bufferViews = child(document, "bufferViews");
                if (viewIndex >= 0 && viewIndex < bufferViews.array.length)
                {
                    const view = bufferViews[viewIndex];
                    const bufferIndex = integer(child(view, "buffer"), 0);
                    const start = integer(child(view, "byteOffset"), 0);
                    const length = integer(child(view, "byteLength"), 0);
                    if (bufferIndex < scene.buffers.length &&
                        start + length <= scene.buffers[bufferIndex].length)
                    {
                        try
                            result.image = decodeImage(
                                scene.buffers[bufferIndex][start .. start + length],
                                "GLB image");
                        catch (Exception)
                            result.image = null;
                    }
                }
            }
            scene.images ~= result;
        }
    const textureValues = child(document, "textures");
    const samplerValues = child(document, "samplers");
    if (textureValues.type == JSONType.array)
        foreach (texture; textureValues.array)
        {
            GTexture result;
            result.image = integer(child(texture, "source"), -1);
            const samplerIndex = integer(child(texture, "sampler"), -1);
            if (samplerValues.type == JSONType.array && samplerIndex >= 0 &&
                samplerIndex < samplerValues.array.length)
            {
                const sampler = samplerValues[samplerIndex];
                result.wrapS = integer(child(sampler, "wrapS"), 10497);
                result.wrapT = integer(child(sampler, "wrapT"), 10497);
            }
            scene.textures ~= result;
        }

    const materialValues = child(document, "materials");
    if (materialValues.type == JSONType.array)
        foreach (material; materialValues.array)
        {
            GMaterial result;
            if (has(material, "pbrMetallicRoughness"))
            {
                const pbr = child(material, "pbrMetallicRoughness");
                const color = numberArray(child(pbr, "baseColorFactor"));
                if (color.length >= 3)
                    result.baseColor = Vec3(color[0], color[1], color[2]);
                if (color.length >= 4)
                    result.alpha = color[3];
                if (has(pbr, "baseColorTexture"))
                    result.baseTexture = integer(child(child(pbr,
                        "baseColorTexture"), "index"), -1);
            }
            result.doubleSided = integer(child(material, "doubleSided"), 0) != 0;
            result.alphaMode = has(material, "alphaMode") ?
                material["alphaMode"].str : "OPAQUE";
            result.alphaCutoff = number(child(material, "alphaCutoff"));
            if (!has(material, "alphaCutoff"))
                result.alphaCutoff = 0.5;
            scene.materials ~= result;
        }

    const nodeValues = child(document, "nodes");
    if (nodeValues.type == JSONType.array)
        foreach (node; nodeValues.array)
        {
            GNode result;
            result.name = has(node, "name") ? node["name"].str : "";
            result.mesh = integer(child(node, "mesh"), -1);
            result.skin = integer(child(node, "skin"), -1);
            result.translation = vec3(child(node, "translation"), Vec3(0, 0, 0));
            result.rotation = [0, 0, 0, 1];
            const rotation = numberArray(child(node, "rotation"));
            if (rotation.length >= 4)
                result.rotation = [rotation[0], rotation[1], rotation[2],
                    rotation[3]];
            result.scale = vec3(child(node, "scale"), Vec3(1, 1, 1));
            if (has(node, "matrix"))
            {
                const matrix = numberArray(child(node, "matrix"));
                if (matrix.length == 16)
                {
                    result.hasMatrix = true;
                    foreach (index; 0 .. 16)
                        result.matrix.m[index] = matrix[index];
                }
            }
            const children = child(node, "children");
            if (children.type == JSONType.array)
                foreach (value; children.array)
                    result.children ~= integer(value, -1);
            scene.nodes ~= result;
        }

    const meshValues = child(document, "meshes");
    if (meshValues.type == JSONType.array)
        foreach (mesh; meshValues.array)
        {
            GMesh result;
            result.name = has(mesh, "name") ? mesh["name"].str : "";
            const weights = numberArray(child(mesh, "weights"));
            result.weights = weights.dup;
            const primitiveValues = child(mesh, "primitives");
            if (primitiveValues.type == JSONType.array)
                foreach (primitive; primitiveValues.array)
                {
                    GPrimitive item;
                    const attributes = child(primitive, "attributes");
                    item.position = integer(child(attributes, "POSITION"), -1);
                    item.normal = integer(child(attributes, "NORMAL"), -1);
                    item.uv = integer(child(attributes, "TEXCOORD_0"), -1);
                    item.joints = integer(child(attributes, "JOINTS_0"), -1);
                    item.weights = integer(child(attributes, "WEIGHTS_0"), -1);
                    item.indices = integer(child(primitive, "indices"), -1);
                    item.material = integer(child(primitive, "material"), -1);
                    item.mode = integer(child(primitive, "mode"), 4);
                    const targets = child(primitive, "targets");
                    if (targets.type == JSONType.array)
                        foreach (target; targets.array)
                        {
                            item.targetPositions ~= [integer(child(target,
                                "POSITION"), -1)];
                            item.targetNormals ~= [integer(child(target,
                                "NORMAL"), -1)];
                        }
                    result.primitives ~= item;
                }
            scene.meshes ~= result;
        }

    const skinValues = child(document, "skins");
    if (skinValues.type == JSONType.array)
        foreach (skin; skinValues.array)
        {
            GSkin result;
            result.inverseBind = integer(child(skin,
                "inverseBindMatrices"), -1);
            const joints = child(skin, "joints");
            if (joints.type == JSONType.array)
                foreach (joint; joints.array)
                    result.joints ~= integer(joint, -1);
            scene.skins ~= result;
        }

    const animationValues = child(document, "animations");
    if (animationValues.type == JSONType.array)
        foreach (animation; animationValues.array)
        {
            GAnimation result;
            result.name = has(animation, "name") ? animation["name"].str : "";
            const samplers = child(animation, "samplers");
            const channels = child(animation, "channels");
            if (channels.type != JSONType.array ||
                samplers.type != JSONType.array)
            {
                scene.animations ~= result;
                continue;
            }
            foreach (channel; channels.array)
            {
                const target = child(channel, "target");
                const samplerIndex = integer(child(channel, "sampler"), -1);
                if (samplerIndex < 0 ||
                    samplerIndex >= samplers.array.length)
                    continue;
                const sampler = samplers[samplerIndex];
                GChannel item;
                item.node = integer(child(target, "node"), -1);
                item.path = has(target, "path") ? target["path"].str : "";
                item.input = integer(child(sampler, "input"), -1);
                item.output = integer(child(sampler, "output"), -1);
                item.interpolation = has(sampler, "interpolation") ?
                    sampler["interpolation"].str : "LINEAR";
                result.channels ~= item;
            }
            scene.animations ~= result;
        }

    const scenes = child(document, "scenes");
    const sceneIndex = integer(child(document, "scene"), 0);
    if (scenes.type == JSONType.array && sceneIndex < scenes.array.length)
    {
        const roots = child(scenes[sceneIndex], "nodes");
        if (roots.type == JSONType.array)
            foreach (root; roots.array)
                scene.roots ~= integer(root, -1);
    }
    return scene;
}

private void decomposeMatrix(const Mat4 matrix, out Vec3 translation,
    out double[4] rotation, out Vec3 scaleValue)
{
    translation = Vec3(matrix.m[12], matrix.m[13], matrix.m[14]);
    Vec3 x = Vec3(matrix.m[0], matrix.m[1], matrix.m[2]);
    Vec3 y = Vec3(matrix.m[4], matrix.m[5], matrix.m[6]);
    Vec3 z = Vec3(matrix.m[8], matrix.m[9], matrix.m[10]);
    scaleValue = Vec3(sqrt(x.x * x.x + x.y * x.y + x.z * x.z),
        sqrt(y.x * y.x + y.y * y.y + y.z * y.z),
        sqrt(z.x * z.x + z.y * z.y + z.z * z.z));
    if (scaleValue.x > 1e-12)
        x = Vec3(x.x / scaleValue.x, x.y / scaleValue.x, x.z / scaleValue.x);
    if (scaleValue.y > 1e-12)
        y = Vec3(y.x / scaleValue.y, y.y / scaleValue.y, y.z / scaleValue.y);
    if (scaleValue.z > 1e-12)
        z = Vec3(z.x / scaleValue.z, z.y / scaleValue.z, z.z / scaleValue.z);
    const trace = x.x + y.y + z.z;
    if (trace > 0)
    {
        const s = sqrt(trace + 1) * 2;
        rotation = [(y.z - z.y) / s, (z.x - x.z) / s, (x.y - y.x) / s,
            0.25 * s];
    }
    else if (x.x > y.y && x.x > z.z)
    {
        const s = sqrt(1 + x.x - y.y - z.z) * 2;
        rotation = [0.25 * s, (y.x + x.y) / s, (z.x + x.z) / s,
            (y.z - z.y) / s];
    }
    else if (y.y > z.z)
    {
        const s = sqrt(1 + y.y - x.x - z.z) * 2;
        rotation = [(y.x + x.y) / s, 0.25 * s, (z.y + y.z) / s,
            (z.x - x.z) / s];
    }
    else
    {
        const s = sqrt(1 + z.z - x.x - y.y) * 2;
        rotation = [(z.x + x.z) / s, (z.y + y.z) / s, 0.25 * s,
            (x.y - y.x) / s];
    }
    const normalized = quatNormalize(rotation.dup);
    foreach (index; 0 .. 4)
        rotation[index] = normalized[index];
}

private double[] slerp(double[] a, double[] b, double t)
{
    if (a.length < 4 || b.length < 4)
        return a;
    double dotValue = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
    auto second = b[0 .. 4].dup;
    if (dotValue < 0)
    {
        dotValue = -dotValue;
        foreach (index; 0 .. 4)
            second[index] = -second[index];
    }
    if (dotValue > 0.9995)
        return quatNormalize([a[0] + (second[0] - a[0]) * t,
            a[1] + (second[1] - a[1]) * t,
            a[2] + (second[2] - a[2]) * t,
            a[3] + (second[3] - a[3]) * t]);
    const angle = sqrt(1 - dotValue * dotValue);
    const theta = cast(double) .atan2(angle, dotValue);
    const weightA = sin((1 - t) * theta) / angle;
    const weightB = sin(t * theta) / angle;
    return [a[0] * weightA + second[0] * weightB,
        a[1] * weightA + second[1] * weightB,
        a[2] * weightA + second[2] * weightB,
        a[3] * weightA + second[3] * weightB];
}

private double[] sampleChannel(GltfScene scene, GChannel channel, double time)
{
    const times = readAccessor(scene.document, scene.buffers, channel.input);
    const values = readAccessor(scene.document, scene.buffers, channel.output);
    if (times.count == 0 || values.count == 0 || values.components == 0)
        return [];
    int first = 0;
    int second = 0;
    double fraction = 0;
    if (time <= times.values[0])
    {
        first = 0;
        second = 0;
    }
    else if (time >= times.values[(times.count - 1)])
    {
        first = times.count - 1;
        second = first;
    }
    else
    {
        foreach (index; 1 .. times.count)
        {
            if (time <= times.values[index])
            {
                first = index - 1;
                second = index;
                const span = times.values[second] - times.values[first];
                fraction = span <= 1e-12 ? 0 :
                    (time - times.values[first]) / span;
                break;
            }
        }
    }
    const components = values.components;
    int valuesPerKey = components;
    if (channel.interpolation == "CUBICSPLINE")
        valuesPerKey = components * 3;
    const firstValue = first * valuesPerKey +
        (channel.interpolation == "CUBICSPLINE" ? components : 0);
    const secondValue = second * valuesPerKey +
        (channel.interpolation == "CUBICSPLINE" ? components : 0);
    const firstOut = first * valuesPerKey + components * 2;
    const secondIn = second * valuesPerKey;
    const span = times.values[second] - times.values[first];
    double[] result;
    result.length = components;
    foreach (component; 0 .. components)
    {
        const a = firstValue + component < values.values.length ?
            values.values[firstValue + component] : 0;
        const b = secondValue + component < values.values.length ?
            values.values[secondValue + component] : a;
        if (channel.interpolation == "CUBICSPLINE" &&
            firstOut + component < values.values.length &&
            secondIn + component < values.values.length)
        {
            const p0 = a;
            const p1 = b;
            const m0 = values.values[firstOut + component] * span;
            const m1 = values.values[secondIn + component] * span;
            const t2 = fraction * fraction;
            const t3 = t2 * fraction;
            result[component] =
                (2 * t3 - 3 * t2 + 1) * p0 +
                (t3 - 2 * t2 + fraction) * m0 +
                (-2 * t3 + 3 * t2) * p1 +
                (t3 - t2) * m1;
        }
        else
            result[component] = channel.interpolation == "STEP" ? a :
                a + (b - a) * fraction;
    }
    if (channel.path == "rotation" && result.length >= 4)
    {
        double[] a = firstValue + 3 < values.values.length ?
            cast(double[]) values.values[firstValue .. firstValue + 4] :
            [0.0, 0.0, 0.0, 1.0];
        double[] b = secondValue + 3 < values.values.length ?
            cast(double[]) values.values[secondValue .. secondValue + 4] : a;
        result = slerp(a, b, fraction);
    }
    return result;
}

private double[] sampleWeights(GltfScene scene, GChannel channel, double time)
{
    const times = readAccessor(scene.document, scene.buffers, channel.input);
    const values = readAccessor(scene.document, scene.buffers, channel.output);
    if (times.count == 0 || values.count == 0)
        return [];
    int first;
    int second;
    double fraction;
    if (time <= times.values[0])
    {
        first = 0;
        second = 0;
    }
    else if (time >= times.values[times.count - 1])
    {
        first = times.count - 1;
        second = first;
    }
    else
    {
        foreach (index; 1 .. times.count)
            if (time <= times.values[index])
            {
                first = index - 1;
                second = index;
                const span = times.values[second] - times.values[first];
                fraction = span <= 1e-12 ? 0 :
                    (time - times.values[first]) / span;
                break;
            }
    }
    const cubic = channel.interpolation == "CUBICSPLINE";
    const perKey = values.count / times.count;
    const targetCount = cubic ? perKey / 3 : perKey;
    double[] result;
    result.length = targetCount;
    const firstBase = first * perKey + (cubic ? targetCount : 0);
    const secondBase = second * perKey + (cubic ? targetCount : 0);
    const firstOut = first * perKey + targetCount * 2;
    const secondIn = second * perKey;
    const span = times.values[second] - times.values[first];
    foreach (index; 0 .. targetCount)
    {
        const a = firstBase + index < values.values.length ?
            values.values[firstBase + index] : 0;
        const b = secondBase + index < values.values.length ?
            values.values[secondBase + index] : a;
        if (cubic && firstOut + index < values.values.length &&
            secondIn + index < values.values.length)
        {
            const t2 = fraction * fraction;
            const t3 = t2 * fraction;
            result[index] = (2 * t3 - 3 * t2 + 1) * a +
                (t3 - 2 * t2 + fraction) *
                    values.values[firstOut + index] * span +
                (-2 * t3 + 3 * t2) * b +
                (t3 - t2) * values.values[secondIn + index] * span;
        }
        else
            result[index] = channel.interpolation == "STEP" ? a :
                a + (b - a) * fraction;
    }
    return result;
}

private struct NodePose
{
    Vec3 translation;
    double[4] rotation;
    Vec3 scale;
    Mat4 matrix;
    bool hasMatrix;
}

double gltfAnimationDuration(GltfScene scene, int animationIndex)
{
    if (animationIndex < 0 || animationIndex >= scene.animations.length)
        return 0;
    double result;
    foreach (channel; scene.animations[animationIndex].channels)
    {
        const times = readAccessor(scene.document, scene.buffers, channel.input);
        if (times.count > 0)
            result = times.values[(times.count - 1)] > result ?
                times.values[(times.count - 1)] : result;
    }
    return result;
}

/** Bake the full scene at an animation time into a textured editable mesh. */
Mesh bakeGltfFrame(GltfScene scene, int animationIndex, double time,
    bool applyMorph = true)
{
    Mesh mesh;
    mesh.materials.length = scene.materials.length;
    mesh.textures.length = scene.images.length;
    foreach (index, image; scene.images)
        mesh.textures[index] = image.image;
    foreach (index, material; scene.materials)
    {
        MaterialSlot slot;
        slot.baseColor = material.baseColor;
        slot.alpha = material.alpha;
        slot.alphaMode = material.alphaMode == "MASK" ? 1 :
            material.alphaMode == "BLEND" ? 2 : 0;
        slot.alphaCutoff = material.alphaCutoff;
        slot.doubleSided = material.doubleSided;
        if (material.baseTexture >= 0 &&
            material.baseTexture < scene.textures.length)
        {
            slot.texture = scene.textures[material.baseTexture].image;
            slot.wrapS = scene.textures[material.baseTexture].wrapS;
            slot.wrapT = scene.textures[material.baseTexture].wrapT;
        }
        mesh.materials[index] = slot;
    }

    NodePose[] poses = new NodePose[scene.nodes.length];
    foreach (index, node; scene.nodes)
    {
        poses[index].translation = node.translation;
        poses[index].rotation = node.rotation;
        poses[index].scale = node.scale;
        poses[index].matrix = node.matrix;
        poses[index].hasMatrix = node.hasMatrix;
        if (node.hasMatrix)
        {
            Vec3 translation;
            double[4] rotation;
            Vec3 scaleValue;
            decomposeMatrix(node.matrix, translation, rotation, scaleValue);
            poses[index].translation = translation;
            poses[index].rotation = rotation;
            poses[index].scale = scaleValue;
        }
    }
    double[][] meshWeights = new double[][scene.meshes.length];
    foreach (index, meshValue; scene.meshes)
    {
        meshWeights[index] = meshValue.weights.dup;
        foreach (primitive; meshValue.primitives)
            if (meshWeights[index].length < primitive.targetPositions.length)
                meshWeights[index].length = primitive.targetPositions.length;
    }
    if (animationIndex >= 0 && animationIndex < scene.animations.length)
    {
        foreach (channel; scene.animations[animationIndex].channels)
        {
            if (channel.node < 0 || channel.node >= poses.length)
                continue;
            if (channel.path == "weights")
            {
                const weights = sampleWeights(scene, channel, time);
                const meshIndex = scene.nodes[channel.node].mesh;
                if (meshIndex >= 0 && meshIndex < meshWeights.length)
                    foreach (index, value; weights)
                        if (index < meshWeights[meshIndex].length)
                            meshWeights[meshIndex][index] = value;
                continue;
            }
            const values = sampleChannel(scene, channel, time);
            if (values.length == 0)
                continue;
            if (channel.path == "translation" && values.length >= 3)
                poses[channel.node].translation =
                    Vec3(values[0], values[1], values[2]);
            else if (channel.path == "scale" && values.length >= 3)
                poses[channel.node].scale =
                    Vec3(values[0], values[1], values[2]);
            else if (channel.path == "rotation" && values.length >= 4)
                poses[channel.node].rotation = [values[0], values[1],
                    values[2], values[3]];

        }
    }

    Mat4[] world = new Mat4[scene.nodes.length];
    bool[] visited = new bool[scene.nodes.length];
    void visit(int nodeIndex, Mat4 parent)
    {
        if (nodeIndex < 0 || nodeIndex >= scene.nodes.length ||
            visited[nodeIndex])
            return;
        visited[nodeIndex] = true;
        const node = scene.nodes[nodeIndex];
        Mat4 local = trsMatrix(poses[nodeIndex].translation,
            poses[nodeIndex].rotation[0 .. 4].dup, poses[nodeIndex].scale);
        world[nodeIndex] = multiply(parent, local);
        foreach (childIndex; node.children)
            visit(childIndex, world[nodeIndex]);
    }
    int[] roots = scene.roots;
    if (roots.length == 0)
    {
        bool[] isChild = new bool[scene.nodes.length];
        foreach (node; scene.nodes)
            foreach (childIndex; node.children)
                if (childIndex >= 0 && childIndex < isChild.length)
                    isChild[childIndex] = true;
        foreach (index; 0 .. scene.nodes.length)
            if (!isChild[index])
                roots ~= cast(int) index;
    }
    foreach (root; roots)
        visit(root, Mat4.identity());
    foreach (index; 0 .. scene.nodes.length)
        if (!visited[index])
            visit(cast(int) index, Mat4.identity());

    Mat4[][] skinMatrices = new Mat4[][scene.skins.length];
    foreach (skinIndex, skin; scene.skins)
    {
        Mat4[] inverseBind;
        const inverse = readAccessor(scene.document, scene.buffers,
            skin.inverseBind);
        if (inverse.count == skin.joints.length && inverse.components == 16)
            foreach (index; 0 .. inverse.count)
            {
                Mat4 matrix;
                foreach (component; 0 .. 16)
                    matrix.m[component] =
                        inverse.values[index * 16 + component];
                inverseBind ~= matrix;
            }
        else
            foreach (index; 0 .. skin.joints.length)
                inverseBind ~= Mat4.identity();
        Mat4[] matrices;
        foreach (index, joint; skin.joints)
            matrices ~= multiply(world[joint], inverseBind[index]);
        skinMatrices[skinIndex] = matrices;
    }

    foreach (nodeIndex, node; scene.nodes)
    {
        if (node.mesh < 0 || node.mesh >= scene.meshes.length)
            continue;
        const meshValue = scene.meshes[node.mesh];
        foreach (primitive; meshValue.primitives)
        {
            if (primitive.mode != 4 || primitive.position < 0)
                continue;
            const positions = readAccessor(scene.document, scene.buffers,
                primitive.position);
            const normals = readAccessor(scene.document, scene.buffers,
                primitive.normal);
            const uvs = readAccessor(scene.document, scene.buffers,
                primitive.uv);
            const joints = readAccessor(scene.document, scene.buffers,
                primitive.joints);
            const weights = readAccessor(scene.document, scene.buffers,
                primitive.weights);
            const indices = readAccessor(scene.document, scene.buffers,
                primitive.indices);
            if (positions.count == 0 || positions.components < 3)
                continue;
            AccessorData[] targetPositionData;
            AccessorData[] targetNormalData;
            targetPositionData.length = primitive.targetPositions.length;
            targetNormalData.length = primitive.targetNormals.length;
            // Large corrective sets (the reference body has 228 targets) are
            // not safe to drive until their authored target ranges are mapped;
            // small facial sets remain animated.
            const canMorph = primitive.targetPositions.length <= 64;
            if (applyMorph && canMorph && node.mesh < meshWeights.length)
                foreach (targetIndex, targetWeight; meshWeights[node.mesh])
                {
                    if (targetIndex >= primitive.targetPositions.length ||
                        targetWeight == 0)
                        continue;
                    targetPositionData[targetIndex] = readAccessor(
                        scene.document, scene.buffers,
                        primitive.targetPositions[targetIndex][0]);
                    if (targetIndex < primitive.targetNormals.length)
                        targetNormalData[targetIndex] = readAccessor(
                            scene.document, scene.buffers,
                            primitive.targetNormals[targetIndex][0]);
                }
            int[] vertexMap;
            vertexMap.length = positions.count;
            foreach (ref value; vertexMap)
                value = -1;
            int[] sourceVertices;
            if (indices.count > 0 && indices.components == 1)
            {
                foreach (index; 0 .. indices.count)
                {
                    const source = cast(int) indices.values[index];
                    if (source < 0 || source >= positions.count ||
                        vertexMap[source] >= 0)
                        continue;
                    vertexMap[source] = cast(int) sourceVertices.length;
                    sourceVertices ~= source;
                }
            }
            else
            {
                sourceVertices.length = positions.count;
                foreach (index; 0 .. positions.count)
                {
                    sourceVertices[index] = cast(int) index;
                    vertexMap[index] = cast(int) index;
                }
            }
            const base = cast(int) mesh.vertices.length;
            foreach (usedIndex, vertexIndex; sourceVertices)
            {
                Vec3 position = Vec3(
                    positions.values[vertexIndex * 3],
                    positions.values[vertexIndex * 3 + 1],
                    positions.values[vertexIndex * 3 + 2]);
                Vec3 normal = normals.components >= 3 &&
                    vertexIndex * 3 + 2 < normals.values.length ?
                    Vec3(normals.values[vertexIndex * 3],
                        normals.values[vertexIndex * 3 + 1],
                        normals.values[vertexIndex * 3 + 2]) :
                    Vec3(0, 0, 0);
                if (applyMorph && canMorph && node.mesh < meshWeights.length)
                    foreach (targetIndex, targetWeight;
                        meshWeights[node.mesh])
                    {
                        if (targetIndex >= primitive.targetPositions.length ||
                            targetWeight == 0)
                            continue;
                        const delta = targetPositionData[targetIndex];
                        if (delta.components >= 3 &&
                            vertexIndex * 3 + 2 < delta.values.length)
                            position.x += delta.values[vertexIndex * 3] *
                                targetWeight;
                        if (delta.components >= 3 &&
                            vertexIndex * 3 + 2 < delta.values.length)
                        {
                            position.y += delta.values[vertexIndex * 3 + 1] *
                                targetWeight;
                            position.z += delta.values[vertexIndex * 3 + 2] *
                                targetWeight;
                        }
                        const normalDelta = targetNormalData[targetIndex];
                        if (normalDelta.components >= 3 &&
                            vertexIndex * 3 + 2 < normalDelta.values.length)
                        {
                            normal.x += normalDelta.values[vertexIndex * 3] *
                                targetWeight;
                            normal.y +=
                                normalDelta.values[vertexIndex * 3 + 1] *
                                targetWeight;
                            normal.z +=
                                normalDelta.values[vertexIndex * 3 + 2] *
                                targetWeight;
                        }
                    }
                if (node.skin >= 0 && node.skin < skinMatrices.length &&
                    joints.components >= 4 && weights.components >= 4)
                {
                    Vec3 skinnedPosition = Vec3(0, 0, 0);
                    Vec3 skinnedNormal = Vec3(0, 0, 0);
                    foreach (component; 0 .. 4)
                    {
                        const jointIndex = cast(int) joints.values[
                            vertexIndex * 4 + component];
                        const weight = weights.values[vertexIndex * 4 + component];
                        if (jointIndex < 0 || jointIndex >= skinMatrices[node.skin].length ||
                            weight == 0)
                            continue;
                        const jointMatrix = skinMatrices[node.skin][jointIndex];
                        const p = transformPoint(jointMatrix, position);
                        skinnedPosition.x += p.x * weight;
                        skinnedPosition.y += p.y * weight;
                        skinnedPosition.z += p.z * weight;
                        const n = transformNormal(jointMatrix, normal);
                        skinnedNormal.x += n.x * weight;
                        skinnedNormal.y += n.y * weight;
                        skinnedNormal.z += n.z * weight;
                    }
                    position = skinnedPosition;
                    normal = skinnedNormal;
                }
                else
                {
                    position = transformPoint(world[nodeIndex], position);
                    normal = transformNormal(world[nodeIndex], normal);
                }
                mesh.vertices ~= position;
                mesh.uvs ~= uvs.components >= 2 &&
                    vertexIndex * 2 + 1 < uvs.values.length ?
                    Vec2(uvs.values[vertexIndex * 2],
                        uvs.values[vertexIndex * 2 + 1]) : Vec2(0, 0);
                mesh.normals ~= normal;
            }
            const materialIndex = primitive.material;
            if (indices.count > 0 && indices.components == 1)
            {
                for (size_t index = 0; index + 2 < indices.count; index += 3)
                {
                    const a = cast(int) indices.values[index];
                    const b = cast(int) indices.values[index + 1];
                    const c = cast(int) indices.values[index + 2];
                    if (a < 0 || b < 0 || c < 0 ||
                        a >= positions.count || b >= positions.count ||
                        c >= positions.count)
                        continue;
                    const mappedA = vertexMap[a];
                    const mappedB = vertexMap[b];
                    const mappedC = vertexMap[c];
                    if (mappedA < 0 || mappedB < 0 || mappedC < 0)
                        continue;
                    const count = mesh.faces.length;
                    mesh.addTriangle(base + mappedA, base + mappedB,
                        base + mappedC,
                        Material.cloth);
                    if (mesh.faces.length > count)
                        mesh.faceMaterials ~= materialIndex;
                }
            }
            else
            {
                for (int index = 0; index + 2 < positions.count; index += 3)
                {
                    const count = mesh.faces.length;
                    mesh.addTriangle(base + index, base + index + 1,
                        base + index + 2, Material.cloth);
                    if (mesh.faces.length > count)
                        mesh.faceMaterials ~= materialIndex;
                }
            }
        }
    }
    if (mesh.vertices.length == 0)
        throw new Exception("GLB scene contains no triangles");
    computeSmoothNormals(mesh);
    return mesh;
}