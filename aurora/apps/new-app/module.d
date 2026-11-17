module newapp;

import core.stdc.string : memcpy;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.file : write;
import std.json : JSONValue, toJSON;
import std.math : cos, sin, sqrt;
import std.mmfile : MmFile;
import std.stdio : File;

enum Revision = 1;
enum Accent = 0x38bdf8u;
enum int Width = 640;
enum int Height = 480;
enum int EventBytes = 24;
enum int EventCapacity = 64;
enum int HeaderBytes = 80;

private immutable string TriTableHex = "ffffffffffffffffffffffffffffffff000803ffffffffffffffffffffffffff000109ffffffffffffffffffffffffff010803090801ffffffffffffffffffff01020affffffffffffffffffffffffff00080301020affffffffffffffffffff09020a000209ffffffffffffffffffff020803020a080a0908ffffffffffffff030b02ffffffffffffffffffffffffff000b02080b00ffffffffffffffffffff01090002030bffffffffffffffffffff010b0201090b09080bffffffffffffff030a010b0a03ffffffffffffffffffff000a0100080a080b0affffffffffffff030900030b090b0a09ffffffffffffff09080a0a080bffffffffffffffffffff040708ffffffffffffffffffffffffff040300070304ffffffffffffffffffff000109080407ffffffffffffffffffff040109040701070301ffffffffffffff01020a080407ffffffffffffffffffff03040703000401020affffffffffffff09020a090002080407ffffffffffffff020a09020907020703070904ffffffff080407030b02ffffffffffffffffffff0b04070b0204020004ffffffffffffff09000108040702030bffffffffffffff04070b09040b090b02090201ffffffff030a01030b0a070804ffffffffffffff010b0a01040b010004070b04ffffffff04070809000b090b0a0b0003ffffffff04070b040b09090b0affffffffffffff090504ffffffffffffffffffffffffff090504000803ffffffffffffffffffff000504010500ffffffffffffffffffff080504080305030105ffffffffffffff01020a090504ffffffffffffffffffff03000801020a040905ffffffffffffff05020a050402040002ffffffffffffff020a05030205030504030408ffffffff09050402030bffffffffffffffffffff000b0200080b040905ffffffffffffff00050400010502030bffffffffffffff02010502050802080b040805ffffffff0a030b0a0103090504ffffffffffffff040905000801080a01080b0affffffff05040005000b050b0a0b0003ffffffff05040805080a0a080bffffffffffffff090708050709ffffffffffffffffffff090300090503050703ffffffffffffff000708000107010507ffffffffffffff010503030507ffffffffffffffffffff0907080905070a0102ffffffffffffff0a0102090500050300050703ffffffff0800020802050805070a0502ffffffff020a05020503030507ffffffffffffff070905070809030b02ffffffffffffff09050709070209020002070bffffffff02030b000108010708010507ffffffff0b02010b0107070105ffffffffffffff0905080805070a01030a030bffffffff050700050009070b0001000a0b0a00ff0b0a000b00030a0500080007050700ff0b0a05070b05ffffffffffffffffffff0a0605ffffffffffffffffffffffffff000803050a06ffffffffffffffffffff090001050a06ffffffffffffffffffff010803010908050a06ffffffffffffff010605020601ffffffffffffffffffff010605010206030008ffffffffffffff090605090006000206ffffffffffffff050908050802050206030208ffffffff02030b0a0605ffffffffffffffffffff0b00080b02000a0605ffffffffffffff00010902030b050a06ffffffffffffff050a06010902090b0209080bffffffff06030b060503050103ffffffffffffff00080b000b05000501050b06ffffffff030b06000306000605000509ffffffff06050906090b0b0908ffffffffffffff050a06040708ffffffffffffffffffff04030004070306050affffffffffffff010900050a06080407ffffffffffffff0a0605010907010703070904ffffffff060102060501040708ffffffffffffff010205050206030004030407ffffffff080407090005000605000206ffffffff070309070904030209050906020609ff030b020708040a0605ffffffffffffff050a0604070204020002070bffffffff00010904070802030b050a06ffffffff090201090b0209040b070b04050a06ff080407030b05030501050b06ffffffff05010b050b0601000b070b0400040bff0005090006050003060b0603080407ff06050906090b040709070b09ffffffff0a040906040affffffffffffffffffff040a0604090a000803ffffffffffffff0a00010a0600060400ffffffffffffff08030108010608060406010affffffff010409010204020604ffffffffffffff030008010209020409020604ffffffff000204040206ffffffffffffffffffff080302080204040206ffffffffffffff0a04090a06040b0203ffffffffffffff00080202080b04090a040a06ffffffff030b0200010600060406010affffffff06040106010a04080102010b080b01ff0906040903060901030b0603ffffffff080b010801000b0601090104060401ff030b06030600000604ffffffffffffff0604080b0608ffffffffffffffffffff070a0607080a08090affffffffffffff000703000a0700090a06070affffffff0a0607010a07010708010800ffffffff0a06070a0701010703ffffffffffffff010206010608010809080607ffffffff020609020901060709000903070309ff070800070006060002ffffffffffffff070302060702ffffffffffffffffffff02030b0a06080a0809080607ffffffff02000702070b00090706070a090a07ff010800010708010a0706070a02030bff0b02010b01070a0601060701ffffffff0809060806070901060b0603010306ff0009010b0607ffffffffffffffffffff070800070006030b000b0600ffffffff070b06ffffffffffffffffffffffffff07060bffffffffffffffffffffffffff0300080b0706ffffffffffffffffffff0001090b0706ffffffffffffffffffff0801090803010b0706ffffffffffffff0a0102060b07ffffffffffffffffffff01020a030008060b07ffffffffffffff020900020a09060b07ffffffffffffff060b07020a030a08030a0908ffffffff070203060207ffffffffffffffffffff070008070600060200ffffffffffffff020706020307000109ffffffffffffff010602010806010908080706ffffffff0a07060a0107010307ffffffffffffff0a070601070a010807010008ffffffff00030700070a000a09060a07ffffffff07060a070a08080a09ffffffffffffff0608040b0806ffffffffffffffffffff03060b030006000406ffffffffffffff08060b080406090001ffffffffffffff0904060906030903010b0306ffffffff060804060b08020a01ffffffffffffff01020a03000b00060b000406ffffffff040b0804060b000209020a09ffffffff0a09030a03020904030b0306040603ff080203080402040602ffffffffffffff000402040602ffffffffffffffffffff010900020304020406040308ffffffff010904010402020406ffffffffffffff080103080601080406060a01ffffffff0a01000a0006060004ffffffffffffff040603040308060a030003090a0903ff0a0904060a04ffffffffffffffffffff04090507060bffffffffffffffffffff0008030409050b0706ffffffffffffff05000105040007060bffffffffffffff0b0706080304030504030105ffffffff0905040a010207060bffffffffffffff060b0701020a000803040905ffffffff07060b05040a04020a040002ffffffff0304080305040302050a05020b0706ff070203070602050409ffffffffffffff090504000806000602060807ffffffff030602030706010500050400ffffffff060208060807020108040805010508ff0905040a0106010706010307ffffffff01060a010706010007080700090504ff04000a040a0500030a060a0703070aff07060a070a0805040a04080affffffff060905060b090b0809ffffffffffffff03060b000603000506000905ffffffff000b0800050b00010505060bffffffff060b03060305050301ffffffffffffff01020a09050b090b080b0506ffffffff000b0300060b00090605060901020aff0b08050b05060800050a0502000205ff060b03060305020a030a0503ffffffff050809050208050602030802ffffffff090506090600000602ffffffffffffff010508010800050608030802060208ff010506020106ffffffffffffffffffff01030601060a030806050609080906ff0a01000a0006090500050600ffffffff00030805060affffffffffffffffffff0a0506ffffffffffffffffffffffffff0b050a07050bffffffffffffffffffff0b050a0b0705080300ffffffffffffff050b07050a0b010900ffffffffffffff0a07050a0b07090801080301ffffffff0b01020b0701070501ffffffffffffff00080301020701070507020bffffffff090705090207090002020b07ffffffff07050207020b050902030208090802ff02050a020305030705ffffffffffffff0802000805020807050a0205ffffffff090001050a03050307030a02ffffffff0908020902010807020a0205070502ff010305030705ffffffffffffffffffff000807000701010705ffffffffffffff090003090305050307ffffffffffffff090807050907ffffffffffffffffffff050804050a080a0b08ffffffffffffff050004050b00050a0b0b0300ffffffff00010908040a080a0b0a0405ffffffff0a0b040a04050b0304090401030104ff020501020805020b08040508ffffffff00040b000b0304050b020b0105010bff000205000509020b050405080b0805ff090405020b03ffffffffffffffffffff02050a030502030405030804ffffffff050a02050204040200ffffffffffffff030a0203050a030805040508000109ff050a02050204010902090402ffffffff080405080503030501ffffffffffffff000405010005ffffffffffffffffffff080405080503090005000305ffffffff090405ffffffffffffffffffffffffff040b0704090b090a0bffffffffffffff000803040907090b07090a0bffffffff010a0b010b0401040007040bffffffff030104030408010a0407040b0a0b04ff040b07090b0409020b090102ffffffff090704090b0709010b020b01000803ff0b07040b0402020400ffffffffffffff0b07040b0402080304030204ffffffff02090a020709020307070409ffffffff090a070907040a0207080700020007ff03070a030a0207040a010a0004000aff010a02080704ffffffffffffffffffff040901040107070103ffffffffffffff040901040107000801080701ffffffff040003070403ffffffffffffffffffff040807ffffffffffffffffffffffffff090a080a0b08ffffffffffffffffffff03000903090b0b090affffffffffffff00010a000a08080a0bffffffffffffff03010a0b030affffffffffffffffffff01020b010b09090b08ffffffffffffff03000903090b010209020b09ffffffff00020b08000bffffffffffffffffffff03020bffffffffffffffffffffffffff02030802080a0a0809ffffffffffffff090a02000902ffffffffffffffffffff02030802080a000108010a08ffffffff010a02ffffffffffffffffffffffffff010308090108ffffffffffffffffffff000901ffffffffffffffffffffffffff000308ffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

struct Surface
{
    MmFile map;
    ubyte[] data;
    int frameBytes;
    ulong sequence;

    this(string path)
    {
        frameBytes = Width * Height * 4;
        const size = HeaderBytes + EventCapacity * EventBytes +
            2 * frameBytes;
        auto stream = File(path, "wb");
        stream.rawWrite(new ubyte[size]);
        stream.close();
        map = new MmFile(path, MmFile.Mode.readWrite, cast(ulong) size, null);
        data = cast(ubyte[]) map[];

        char[8] magic = "AURSFACE";
        memcpy(data.ptr, magic.ptr, 8);
        put!uint(8, 2);
        put!uint(12, HeaderBytes);
        put!uint(16, Width);
        put!uint(20, Height);
        put!uint(24, 0);
        put!uint(28, EventCapacity);
        put!ulong(32, 0);
        put!ulong(40, 0);
        put!uint(48, 0);
        put!uint(52, 0);
        put!uint(56, EventBytes);
        put!uint(60, 2);
        put!uint(64, frameBytes);
    }

    private void put(T)(size_t offset, T value)
    {
        memcpy(data.ptr + offset, &value, T.sizeof);
    }

    private T get(T)(size_t offset)
    {
        T value;
        memcpy(&value, data.ptr + offset, T.sizeof);
        return value;
    }

    void publish(const(ubyte)[] pixels)
    {
        const active = get!uint(24);
        const target = 1 - active;
        const offset = HeaderBytes + EventCapacity * EventBytes +
            target * frameBytes;
        data[offset .. offset + frameBytes] = pixels[];
        put!uint(24, target);
        sequence++;
        put!ulong(32, sequence);
    }

    bool waitHost(ulong wanted, int timeoutMs = 500)
    {
        while (get!ulong(40) < wanted)
        {
            if (timeoutMs <= 0) return false;
            Thread.sleep(5.msecs);
            timeoutMs -= 5;
        }
        return true;
    }

    void close()
    {
        map = null;
    }
}

private void fill(ubyte[] frame, uint color)
{
    foreach (i; 0 .. Width * Height)
    {
        frame[i * 4] = cast(ubyte) ((color >> 16) & 0xff);
        frame[i * 4 + 1] = cast(ubyte) ((color >> 8) & 0xff);
        frame[i * 4 + 2] = cast(ubyte) (color & 0xff);
        frame[i * 4 + 3] = 255;
    }
}

private void fillRect(ubyte[] frame, int x, int y, int width, int height,
    uint color)
{
    const left = x < 0 ? 0 : x;
    const top = y < 0 ? 0 : y;
    const right = x + width > Width ? Width : x + width;
    const bottom = y + height > Height ? Height : y + height;
    foreach (row; top .. bottom)
        foreach (col; left .. right)
        {
            const offset = (row * Width + col) * 4;
            frame[offset] = cast(ubyte) ((color >> 16) & 0xff);
            frame[offset + 1] = cast(ubyte) ((color >> 8) & 0xff);
            frame[offset + 2] = cast(ubyte) (color & 0xff);
            frame[offset + 3] = 255;
        }
}

private int edge(int ax, int ay, int bx, int by, int x, int y)
{
    return (x - ax) * (by - ay) - (y - ay) * (bx - ax);
}

private void fillTriangle(ubyte[] frame, int ax, int ay, int bx, int by,
    int cx, int cy, uint color)
{
    auto minX = ax < bx ? (ax < cx ? ax : cx) : (bx < cx ? bx : cx);
    auto maxX = ax > bx ? (ax > cx ? ax : cx) : (bx > cx ? bx : cx);
    auto minY = ay < by ? (ay < cy ? ay : cy) : (by < cy ? by : cy);
    auto maxY = ay > by ? (ay > cy ? ay : cy) : (by > cy ? by : cy);
    if (minX < 0) minX = 0;
    if (minY < 0) minY = 0;
    if (maxX >= Width) maxX = Width - 1;
    if (maxY >= Height) maxY = Height - 1;
    if (minX > maxX || minY > maxY) return;
    const area = edge(ax, ay, bx, by, cx, cy);
    if (area == 0) return;
    foreach (row; minY .. maxY + 1)
        foreach (col; minX .. maxX + 1)
        {
            const e0 = edge(ax, ay, bx, by, col, row);
            const e1 = edge(bx, by, cx, cy, col, row);
            const e2 = edge(cx, cy, ax, ay, col, row);
            if ((e0 >= 0 && e1 >= 0 && e2 >= 0) ||
                (e0 <= 0 && e1 <= 0 && e2 <= 0))
            {
                const offset = (row * Width + col) * 4;
                frame[offset] = cast(ubyte) ((color >> 16) & 0xff);
                frame[offset + 1] = cast(ubyte) ((color >> 8) & 0xff);
                frame[offset + 2] = cast(ubyte) (color & 0xff);
                frame[offset + 3] = 255;
            }
        }
}

struct Vec3
{
    double x;
    double y;
    double z;
}

struct ProjectedFace
{
    int[3] x;
    int[3] y;
    double depth;
    uint color;
}

struct MeshTriangle
{
    Vec3 a;
    Vec3 b;
    Vec3 c;
}

private MeshTriangle[] gMesh;

private Vec3 rotate(Vec3 point, double yaw, double pitch)
{
    const cy = cos(yaw);
    const sy = sin(yaw);
    const cp = cos(pitch);
    const sp = sin(pitch);
    const x = point.x * cy + point.z * sy;
    const z = -point.x * sy + point.z * cy;
    return Vec3(x, point.y * cp - z * sp, point.y * sp + z * cp);
}

private int hexNibble(char ch)
{
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

private void ensureTriTable()
{
    if (gTriTable.length != 0) return;
    gTriTable = new ubyte[256 * 16];
    int high = -1;
    size_t outIndex;
    foreach (ch; TriTableHex)
    {
        const value = hexNibble(ch);
        if (value < 0) continue;
        if (high < 0)
            high = value;
        else
        {
            gTriTable[outIndex++] = cast(ubyte) ((high << 4) | value);
            high = -1;
        }
    }
    assert(outIndex == gTriTable.length);
}

private ubyte[] gTriTable;

private Vec3 cross(Vec3 a, Vec3 b)
{
    return Vec3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x);
}

private uint shadedColor(double intensity)
{
    int r = cast(int) (0x38 * intensity);
    int g = cast(int) (0xbd * intensity);
    int b = cast(int) (0xf8 * intensity);
    if (r < 0) r = 0; if (r > 255) r = 255;
    if (g < 0) g = 0; if (g > 255) g = 255;
    if (b < 0) b = 0; if (b > 255) b = 255;
    return (cast(uint) r << 16) | (cast(uint) g << 8) | cast(uint) b;
}

private double surfaceField(Vec3 point)
{
    const q = sqrt(point.x * point.x + point.z * point.z) - 0.85;
    return sqrt(q * q + point.y * point.y) - 0.35;
}

private MeshTriangle[] buildMarchingCubes()
{
    ensureTriTable();
    enum int N = 16;
    const double minimum = -1.6;
    const double step = 3.2 / (N - 1);
    auto values = new double[N * N * N];
    foreach (z; 0 .. N)
        foreach (y; 0 .. N)
            foreach (x; 0 .. N)
            {
                const point = Vec3(minimum + x * step,
                    minimum + y * step, minimum + z * step);
                values[(z * N + y) * N + x] = surfaceField(point);
            }

    static immutable Vec3[8] offsets = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
        Vec3(0, 0, 1), Vec3(1, 0, 1), Vec3(1, 1, 1), Vec3(0, 1, 1),
    ];
    static immutable int[2][12] edgeCorners = [
        [0, 1], [1, 2], [2, 3], [3, 0],
        [4, 5], [5, 6], [6, 7], [7, 4],
        [0, 4], [1, 5], [2, 6], [3, 7],
    ];
    MeshTriangle[] mesh;
    foreach (z; 0 .. N - 1)
        foreach (y; 0 .. N - 1)
            foreach (x; 0 .. N - 1)
            {
                double[8] cornerValues;
                Vec3[8] cornerPoints;
                int cubeIndex;
                foreach (corner; 0 .. 8)
                {
                    const ox = cast(int) offsets[corner].x;
                    const oy = cast(int) offsets[corner].y;
                    const oz = cast(int) offsets[corner].z;
                    const gx = x + ox;
                    const gy = y + oy;
                    const gz = z + oz;
                    cornerValues[corner] = values[(gz * N + gy) * N + gx];
                    cornerPoints[corner] = Vec3(minimum + gx * step,
                        minimum + gy * step, minimum + gz * step);
                    if (cornerValues[corner] < 0)
                        cubeIndex |= 1 << corner;
                }
                const row = cubeIndex * 16;
                if (gTriTable[row] == 0xFF) continue;
                Vec3[12] edgePoints;
                bool[12] edgeReady;
                for (int item = 0; item < 16; item += 3)
                {
                    if (gTriTable[row + item] == 0xFF) break;
                    MeshTriangle triangle;
                    Vec3[3] points;
                    foreach (slot; 0 .. 3)
                    {
                        const edge = gTriTable[row + item + slot];
                        if (!edgeReady[edge])
                        {
                            const ca = edgeCorners[edge][0];
                            const cb = edgeCorners[edge][1];
                            const va = cornerValues[ca];
                            const vb = cornerValues[cb];
                            const denominator = vb - va;
                            const t = denominator != 0
                                ? -va / denominator : 0.5;
                            edgePoints[edge] = Vec3(
                                cornerPoints[ca].x + (cornerPoints[cb].x -
                                    cornerPoints[ca].x) * t,
                                cornerPoints[ca].y + (cornerPoints[cb].y -
                                    cornerPoints[ca].y) * t,
                                cornerPoints[ca].z + (cornerPoints[cb].z -
                                    cornerPoints[ca].z) * t);
                            edgeReady[edge] = true;
                        }
                        points[slot] = edgePoints[edge];
                    }
                    triangle.a = points[0];
                    triangle.b = points[1];
                    triangle.c = points[2];
                    mesh ~= triangle;
                }
            }
    return mesh;
}

private void drawMarchingCubes(ubyte[] frame, int tick)
{
    if (gMesh.length == 0) return;
    const yaw = tick * 0.025;
    const pitch = 0.35;
    ProjectedFace[] projected;
    projected.reserve(gMesh.length);
    foreach (triangle; gMesh)
    {
        const a = rotate(triangle.a, yaw, pitch);
        const b = rotate(triangle.b, yaw, pitch);
        const c = rotate(triangle.c, yaw, pitch);
        const normal = cross(Vec3(b.x - a.x, b.y - a.y, b.z - a.z),
            Vec3(c.x - a.x, c.y - a.y, c.z - a.z));
        const length = sqrt(normal.x * normal.x + normal.y * normal.y +
            normal.z * normal.z);
        if (length < 1e-9) continue;
        const light = (normal.x * 0.4 + normal.y * 0.7 +
            normal.z * 0.5) / length;
        const intensity = 0.35 + 0.65 * (light < 0 ? -light : light);
        ProjectedFace candidate;
        candidate.color = shadedColor(intensity);
        bool visible = true;
        double depth;
        Vec3[3] points = [a, b, c];
        foreach (slot, point; points)
        {
            const cameraZ = 4.8 - point.z;
            if (cameraZ <= 0.1)
            {
                visible = false;
                break;
            }
            const scale = 700.0 / cameraZ;
            candidate.x[slot] = cast(int) (Width / 2 + point.x * scale);
            candidate.y[slot] = cast(int) (Height / 2 - point.y * scale);
            depth += cameraZ;
        }
        if (!visible || length < 0.0001) continue;
        candidate.depth = depth / 3;
        projected ~= candidate;
    }
    projected.sort!((a, b) => a.depth > b.depth);
    foreach (face; projected)
        fillTriangle(frame, face.x[0], face.y[0], face.x[1], face.y[1],
            face.x[2], face.y[2], face.color);
}

private void drawPyramid(ubyte[] frame, int tick)
{
    const yaw = tick * 0.045;
    const pitch = 0.38;
    const Vec3[4] local = [
        Vec3(0.0, 1.25, 0.0),
        Vec3(-1.0, -0.8, 1.0),
        Vec3(1.0, -0.8, 1.0),
        Vec3(0.0, -0.8, -1.0),
    ];
    const int[3][4] faces = [
        [0, 1, 2],
        [0, 2, 3],
        [0, 3, 1],
        [1, 3, 2],
    ];
    const uint[4] colors = [
        0x38bdf8,
        0x0ea5e9,
        0x0284c7,
        0x075985,
    ];
    Vec3[4] world;
    foreach (i, point; local)
        world[i] = rotate(point, yaw, pitch);

    ProjectedFace[] projected;
    foreach (faceIndex, face; faces)
    {
        ProjectedFace candidate;
        candidate.color = colors[faceIndex];
        bool visible = true;
        foreach (slot, vertex; face)
        {
            const cameraZ = 4.4 - world[vertex].z;
            if (cameraZ <= 0.1)
            {
                visible = false;
                break;
            }
            const scale = 560.0 / cameraZ;
            candidate.x[slot] = cast(int) (Width / 2 +
                world[vertex].x * scale);
            candidate.y[slot] = cast(int) (Height / 2 -
                world[vertex].y * scale);
            candidate.depth += cameraZ;
        }
        if (!visible) continue;
        candidate.depth /= 3;
        projected ~= candidate;
    }
    projected.sort!((a, b) => a.depth > b.depth);
    foreach (face; projected)
        fillTriangle(frame, face.x[0], face.y[0], face.x[1], face.y[1],
            face.x[2], face.y[2], face.color);
}

private void draw(ubyte[] frame, int tick)
{
    fill(frame, 0x0b1220);
    foreach (x; 0 .. Width / 32 + 1)
        fillRect(frame, x * 32, 0, 1, Height, 0x152238);
    foreach (y; 0 .. Height / 32 + 1)
        fillRect(frame, 0, y * 32, Width, 1, 0x152238);
    fillRect(frame, 24, 24, Width - 48, Height - 48, 0x0f172a);
    fillRect(frame, 24, 24, Width - 48, 2, Accent);
    fillRect(frame, 24, Height - 26, Width - 48, 2, Accent);

    drawMarchingCubes(frame, tick);
}

void main(string[] args)
{
    string surfacePath;
    string statePath;
    int buildId = 1;
    int seconds = 30;
    for (size_t i = 1; i < args.length; ++i)
    {
        if (args[i] == "--surface" && i + 1 < args.length)
            surfacePath = args[++i];
        else if (args[i] == "--state" && i + 1 < args.length)
            statePath = args[++i];
        else if (args[i] == "--seconds" && i + 1 < args.length)
            seconds = to!int(args[++i]);
        else if (args[i] == "--build" && i + 1 < args.length)
            buildId = to!int(args[++i]);
    }
    if (surfacePath.length == 0 || statePath.length == 0)
        throw new Exception("New App requires --surface and --state");

    auto surface = Surface(surfacePath);
    auto frame = new ubyte[Width * Height * 4];
    auto state = JSONValue(string[string].init);
    state.object["build"] = JSONValue(buildId);
    state.object["revision"] = JSONValue(Revision);
    write(statePath, state.toJSON());
    gMesh = buildMarchingCubes();

    foreach (tick; 0 .. seconds * 60)
    {
        draw(frame, tick);
        surface.publish(frame);
        surface.waitHost(surface.sequence);
        Thread.sleep(16.msecs);
    }
    surface.close();
}
