module mcmesh;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import engine.lighting : LightingModel;
import engine.world : TerrainMaterial, WorldConfig;
import std.math : cos, sin, sqrt;

struct MeshVertex
{
    float x;
    float y;
    float z;
    float r;
    float g;
    float b;
    float material;

    this(float x, float y, float z, float r, float g, float b,
        float material = 0)
    {
        this.x = x;
        this.y = y;
        this.z = z;
        this.r = r;
        this.g = g;
        this.b = b;
        this.material = material;
    }
}

struct MeshData
{
    MeshVertex[] vertices;
    uint[] indices;
}

struct TerrainChunk
{
    MeshData[2] lods;
    double centerX;
    double centerZ;
}

private float[3] materialColor(TerrainMaterial material)
{
    final switch (material)
    {
        case TerrainMaterial.grass: return [0.22f, 0.46f, 0.16f];
        case TerrainMaterial.dirt: return [0.38f, 0.24f, 0.13f];
        case TerrainMaterial.rock: return [0.36f, 0.37f, 0.39f];
        case TerrainMaterial.sand: return [0.68f, 0.58f, 0.34f];
    }
}

private float[3] shadeVertex(WorldConfig config, LightingModel lights,
    double x, double y, double z)
{
    const double sample = 1.0;
    const double left = config.terrainHeight(x - sample, z);
    const double right = config.terrainHeight(x + sample, z);
    const double back = config.terrainHeight(x, z - sample);
    const double front = config.terrainHeight(x, z + sample);
    const double nx = -(right - left) * 0.5;
    const double ny = 1.0;
    const double nz = -(front - back) * 0.5;
    const double length = sqrt(nx * nx + ny * ny + nz * nz);
    const double up = ny / length;
    const double slope = 1.0 - up;
    const double sunDot = (nx * lights.sunDirection[0] +
        ny * lights.sunDirection[1] + nz * lights.sunDirection[2]) / length;
    const double ndotl = sunDot < 0 ? -sunDot : sunDot;
    const double diffuse = ndotl * lights.sunIntensity;
    const double hemisphere = 0.5 + 0.5 * up;
    const double globalR = lights.groundColor[0] +
        (lights.skyColor[0] - lights.groundColor[0]) * hemisphere;
    const double globalG = lights.groundColor[1] +
        (lights.skyColor[1] - lights.groundColor[1]) * hemisphere;
    const double globalB = lights.groundColor[2] +
        (lights.skyColor[2] - lights.groundColor[2]) * hemisphere;
    return [
        cast(float) (globalR * lights.ambient +
            diffuse * lights.sunColor[0]),
        cast(float) (globalG * lights.ambient +
            diffuse * lights.sunColor[1]),
        cast(float) (globalB * lights.ambient +
            diffuse * lights.sunColor[2]),
    ];
}

final class TerrainChunkStream
{
    private TerrainChunk[] built;
    private Thread worker;
    private Throwable failure;
    private WorldConfig config;
    private LightingModel lights;

    this(WorldConfig config, LightingModel lights)
    {
        this.config = config;
        this.lights = lights;
    }

    void start()
    {
        if (worker !is null) return;
        worker = new Thread(&run);
        worker.start();
    }

    private void run()
    {
        try
            built = buildTerrainChunks(config, lights);
        catch (Throwable error)
            failure = error;
    }

    TerrainChunk[] wait()
    {
        if (worker !is null) worker.join();
        if (failure !is null) throw failure;
        return built;
    }
}

private final class ChunkBuildJob
{
    TerrainChunk[] chunks;
    WorldConfig config;
    LightingModel lights;
    int first;
    int stride;

    this(TerrainChunk[] chunks, WorldConfig config, LightingModel lights,
        int first, int stride)
    {
        this.chunks = chunks;
        this.config = config;
        this.lights = lights;
        this.first = first;
        this.stride = stride;
    }



    void run()
    {
        foreach (index; first .. chunks.length)
            if ((index % stride) == first)
                chunks[index] = buildTerrainChunk(config, lights,
                    cast(int) index);
    }
}

final class TerrainChunkRebuild
{
    private WorldConfig config;
    private LightingModel lights;
    int[] indices;
    TerrainChunk[] chunks;
    private Thread worker;
    private Mutex mutex;
    private bool done;
    private Throwable failure;

    this(WorldConfig config, LightingModel lights, int[] indices)
    {
        this.config = config;
        this.config.edits = config.edits.dup;
        this.lights = lights;
        this.indices = indices;
        mutex = new Mutex();
    }

    void start()
    {
        if (worker !is null) return;
        worker = new Thread(&run);
        worker.start();
    }

    bool finished()
    {
        synchronized (mutex)
            return done;
    }

    void run()
    {
        try
        {
            chunks.length = indices.length;
            enum int maxWorkers = 8;
            const workerCount = indices.length < maxWorkers
                ? cast(int) indices.length : maxWorkers;
            if (workerCount > 1)
            {
                RebuildWorker[] jobs;
                Thread[] workers;
                foreach (job; 0 .. workerCount)
                {
                    jobs ~= new RebuildWorker(chunks, config, lights, indices,
                        job, workerCount);
                    workers ~= new Thread(&jobs[$ - 1].run);
                    workers[$ - 1].start();
                }
                foreach (worker; workers)
                    worker.join();
                foreach (job; jobs)
                    if (job.failure !is null)
                        throw job.failure;
            }
            else
            {
                foreach (slot, index; indices)
                    chunks[slot] = buildTerrainChunk(config, lights, index);
            }
        }
        catch (Throwable error)
            failure = error;
        synchronized (mutex)
            done = true;
    }

    void take()
    {
        if (worker !is null) worker.join();
        if (failure !is null) throw failure;
    }
}

private final class RebuildWorker
{
    private TerrainChunk[] chunks;
    private WorldConfig config;
    private LightingModel lights;
    private int[] indices;
    private int first;
    private int stride;
    Throwable failure;

    this(TerrainChunk[] chunks, WorldConfig config, LightingModel lights,
        int[] indices, int first, int stride)
    {
        this.chunks = chunks;
        this.config = config;
        this.lights = lights;
        this.indices = indices;
        this.first = first;
        this.stride = stride;
    }

    void run()
    {
        try
        {
            foreach (slot; first .. indices.length)
                if ((slot % stride) == first)
                    chunks[slot] = buildTerrainChunk(config, lights,
                        indices[slot]);
        }
        catch (Throwable error)
            failure = error;
    }
}

private immutable string TriTableHex = "ffffffffffffffffffffffffffffffff000803ffffffffffffffffffffffffff000109ffffffffffffffffffffffffff010803090801ffffffffffffffffffff01020affffffffffffffffffffffffff00080301020affffffffffffffffffff09020a000209ffffffffffffffffffff020803020a080a0908ffffffffffffff030b02ffffffffffffffffffffffffff000b02080b00ffffffffffffffffffff01090002030bffffffffffffffffffff010b0201090b09080bffffffffffffff030a010b0a03ffffffffffffffffffff000a0100080a080b0affffffffffffff030900030b090b0a09ffffffffffffff09080a0a080bffffffffffffffffffff040708ffffffffffffffffffffffffff040300070304ffffffffffffffffffff000109080407ffffffffffffffffffff040109040701070301ffffffffffffff01020a080407ffffffffffffffffffff03040703000401020affffffffffffff09020a090002080407ffffffffffffff020a09020907020703070904ffffffff080407030b02ffffffffffffffffffff0b04070b0204020004ffffffffffffff09000108040702030bffffffffffffff04070b09040b090b02090201ffffffff030a01030b0a070804ffffffffffffff010b0a01040b010004070b04ffffffff04070809000b090b0a0b0003ffffffff04070b040b09090b0affffffffffffff090504ffffffffffffffffffffffffff090504000803ffffffffffffffffffff000504010500ffffffffffffffffffff080504080305030105ffffffffffffff01020a090504ffffffffffffffffffff03000801020a040905ffffffffffffff05020a050402040002ffffffffffffff020a05030205030504030408ffffffff09050402030bffffffffffffffffffff000b0200080b040905ffffffffffffff00050400010502030bffffffffffffff02010502050802080b040805ffffffff0a030b0a0103090504ffffffffffffff040905000801080a01080b0affffffff05040005000b050b0a0b0003ffffffff05040805080a0a080bffffffffffffff090708050709ffffffffffffffffffff090300090503050703ffffffffffffff000708000107010507ffffffffffffff010503030507ffffffffffffffffffff0907080905070a0102ffffffffffffff0a0102090500050300050703ffffffff0800020802050805070a0502ffffffff020a05020503030507ffffffffffffff070905070809030b02ffffffffffffff09050709070209020002070bffffffff02030b000108010708010507ffffffff0b02010b0107070105ffffffffffffff0905080805070a01030a030bffffffff050700050009070b0001000a0b0a00ff0b0a000b00030a0500080007050700ff0b0a05070b05ffffffffffffffffffff0a0605ffffffffffffffffffffffffff000803050a06ffffffffffffffffffff090001050a06ffffffffffffffffffff010803010908050a06ffffffffffffff010605020601ffffffffffffffffffff010605010206030008ffffffffffffff090605090006000206ffffffffffffff050908050802050206030208ffffffff02030b0a0605ffffffffffffffffffff0b00080b02000a0605ffffffffffffff00010902030b050a06ffffffffffffff050a06010902090b0209080bffffffff06030b060503050103ffffffffffffff00080b000b05000501050b06ffffffff030b06000306000605000509ffffffff06050906090b0b0908ffffffffffffff050a06040708ffffffffffffffffffff04030004070306050affffffffffffff010900050a06080407ffffffffffffff0a0605010907010703070904ffffffff060102060501040708ffffffffffffff010205050206030004030407ffffffff080407090005000605000206ffffffff070309070904030209050906020609ff030b020708040a0605ffffffffffffff050a0604070204020002070bffffffff00010904070802030b050a06ffffffff090201090b0209040b070b04050a06ff080407030b05030501050b06ffffffff05010b050b0601000b070b0400040bff0005090006050003060b0603080407ff06050906090b040709070b09ffffffff0a040906040affffffffffffffffffff040a0604090a000803ffffffffffffff0a00010a0600060400ffffffffffffff08030108010608060406010affffffff010409010204020604ffffffffffffff030008010209020409020604ffffffff000204040206ffffffffffffffffffff080302080204040206ffffffffffffff0a04090a06040b0203ffffffffffffff00080202080b04090a040a06ffffffff030b0200010600060406010affffffff06040106010a04080102010b080b01ff0906040903060901030b0603ffffffff080b010801000b0601090104060401ff030b06030600000604ffffffffffffff0604080b0608ffffffffffffffffffff070a0607080a08090affffffffffffff000703000a0700090a06070affffffff0a0607010a07010708010800ffffffff0a06070a0701010703ffffffffffffff010206010608010809080607ffffffff020609020901060709000903070309ff070800070006060002ffffffffffffff070302060702ffffffffffffffffffff02030b0a06080a0809080607ffffffff02000702070b00090706070a090a07ff010800010708010a0706070a02030bff0b02010b01070a0601060701ffffffff0809060806070901060b0603010306ff0009010b0607ffffffffffffffffffff070800070006030b000b0600ffffffff070b06ffffffffffffffffffffffffff07060bffffffffffffffffffffffffff0300080b0706ffffffffffffffffffff0001090b0706ffffffffffffffffffff0801090803010b0706ffffffffffffff0a0102060b07ffffffffffffffffffff01020a030008060b07ffffffffffffff020900020a09060b07ffffffffffffff060b07020a030a08030a0908ffffffff070203060207ffffffffffffffffffff070008070600060200ffffffffffffff020706020307000109ffffffffffffff010602010806010908080706ffffffff0a07060a0107010307ffffffffffffff0a070601070a010807010008ffffffff00030700070a000a09060a07ffffffff07060a070a08080a09ffffffffffffff0608040b0806ffffffffffffffffffff03060b030006000406ffffffffffffff08060b080406090001ffffffffffffff0904060906030903010b0306ffffffff060804060b08020a01ffffffffffffff01020a03000b00060b000406ffffffff040b0804060b000209020a09ffffffff0a09030a03020904030b0306040603ff080203080402040602ffffffffffffff000402040602ffffffffffffffffffff010900020304020406040308ffffffff010904010402020406ffffffffffffff080103080601080406060a01ffffffff0a01000a0006060004ffffffffffffff040603040308060a030003090a0903ff0a0904060a04ffffffffffffffffffff04090507060bffffffffffffffffffff0008030409050b0706ffffffffffffff05000105040007060bffffffffffffff0b0706080304030504030105ffffffff0905040a010207060bffffffffffffff060b0701020a000803040905ffffffff07060b05040a04020a040002ffffffff0304080305040302050a05020b0706ff070203070602050409ffffffffffffff090504000806000602060807ffffffff030602030706010500050400ffffffff060208060807020108040805010508ff0905040a0106010706010307ffffffff01060a010706010007080700090504ff04000a040a0500030a060a0703070aff07060a070a0805040a04080affffffff060905060b090b0809ffffffffffffff03060b000603000506000905ffffffff000b0800050b00010505060bffffffff060b03060305050301ffffffffffffff01020a09050b090b080b0506ffffffff000b0300060b00090605060901020aff0b08050b05060800050a0502000205ff060b03060305020a030a0503ffffffff050809050208050602030802ffffffff090506090600000602ffffffffffffff010508010800050608030802060208ff010506020106ffffffffffffffffffff01030601060a030806050609080906ff0a01000a0006090500050600ffffffff00030805060affffffffffffffffffff0a0506ffffffffffffffffffffffffff0b050a07050bffffffffffffffffffff0b050a0b0705080300ffffffffffffff050b07050a0b010900ffffffffffffff0a07050a0b07090801080301ffffffff0b01020b0701070501ffffffffffffff00080301020701070507020bffffffff090705090207090002020b07ffffffff07050207020b050902030208090802ff02050a020305030705ffffffffffffff0802000805020807050a0205ffffffff090001050a03050307030a02ffffffff0908020902010807020a0205070502ff010305030705ffffffffffffffffffff000807000701010705ffffffffffffff090003090305050307ffffffffffffff090807050907ffffffffffffffffffff050804050a080a0b08ffffffffffffff050004050b00050a0b0b0300ffffffff00010908040a080a0b0a0405ffffffff0a0b040a04050b0304090401030104ff020501020805020b08040508ffffffff00040b000b0304050b020b0105010bff000205000509020b050405080b0805ff090405020b03ffffffffffffffffffff02050a030502030405030804ffffffff050a02050204040200ffffffffffffff030a0203050a030805040508000109ff050a02050204010902090402ffffffff080405080503030501ffffffffffffff000405010005ffffffffffffffffffff080405080503090005000305ffffffff090405ffffffffffffffffffffffffff040b0704090b090a0bffffffffffffff000803040907090b07090a0bffffffff010a0b010b0401040007040bffffffff030104030408010a0407040b0a0b04ff040b07090b0409020b090102ffffffff090704090b0709010b020b01000803ff0b07040b0402020400ffffffffffffff0b07040b0402080304030204ffffffff02090a020709020307070409ffffffff090a070907040a0207080700020007ff03070a030a0207040a010a0004000aff010a02080704ffffffffffffffffffff040901040107070103ffffffffffffff040901040107000801080701ffffffff040003070403ffffffffffffffffffff040807ffffffffffffffffffffffffff090a080a0b08ffffffffffffffffffff03000903090b0b090affffffffffffff00010a000a08080a0bffffffffffffff03010a0b030affffffffffffffffffff01020b010b09090b08ffffffffffffff03000903090b010209020b09ffffffff00020b08000bffffffffffffffffffff03020bffffffffffffffffffffffffff02030802080a0a0809ffffffffffffff090a02000902ffffffffffffffffffff02030802080a000108010a08ffffffff010a02ffffffffffffffffffffffffff010308090108ffffffffffffffffffff000901ffffffffffffffffffffffffff000308ffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
private ubyte[] gTriTable;

private int nibble(char ch)
{
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

private void ensureTable()
{
    if (gTriTable.length != 0) return;
    gTriTable = new ubyte[256 * 16];
    int high = -1;
    size_t outIndex;
    foreach (ch; TriTableHex)
    {
        const value = nibble(ch);
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

private double field(double x, double y, double z)
{
    const q = sqrt(x * x + z * z) - 0.85;
    return sqrt(q * q + y * y) - 0.35;
}

double terrainHeight(double x, double z)
{
    return 18.0 * sin(x * 0.007) * cos(z * 0.006) +
        6.0 * sin(x * 0.019 + z * 0.013) +
        3.0 * cos(z * 0.031) - 2.0;
}

MeshData buildTerrainMesh()
{
    ensureTable();
    enum int NX = 96;
    enum int NY = 30;
    enum int NZ = 96;
    const double x0 = -80, x1 = 80;
    const double y0 = -10, y1 = 10;
    const double z0 = -80, z1 = 80;
    const double dx = (x1 - x0) / (NX - 1);
    const double dy = (y1 - y0) / (NY - 1);
    const double dz = (z1 - z0) / (NZ - 1);
    auto values = new double[NX * NY * NZ];
    foreach (z; 0 .. NZ)
        foreach (y; 0 .. NY)
            foreach (x; 0 .. NX)
                values[(z * NY + y) * NX + x] =
                    (y0 + y * dy) - terrainHeight(x0 + x * dx, z0 + z * dz);

    static immutable double[3][8] offsets = [
        [0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0],
        [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1],
    ];
    static immutable int[2][12] edgeCorners = [
        [0, 1], [1, 2], [2, 3], [3, 0],
        [4, 5], [5, 6], [6, 7], [7, 4],
        [0, 4], [1, 5], [2, 6], [3, 7],
    ];
    MeshData data;
    foreach (z; 0 .. NZ - 1)
        foreach (y; 0 .. NY - 1)
            foreach (x; 0 .. NX - 1)
            {
                double[8] cornerValues;
                double[3][8] cornerPoints;
                int cubeIndex;
                foreach (corner; 0 .. 8)
                {
                    const ox = cast(int) offsets[corner][0];
                    const oy = cast(int) offsets[corner][1];
                    const oz = cast(int) offsets[corner][2];
                    const gx = x + ox;
                    const gy = y + oy;
                    const gz = z + oz;
                    cornerValues[corner] = values[(gz * NY + gy) * NX + gx];
                    cornerPoints[corner] = [
                        x0 + gx * dx, y0 + gy * dy, z0 + gz * dz,
                    ];
                    if (cornerValues[corner] < 0)
                        cubeIndex |= 1 << corner;
                }
                const row = cubeIndex * 16;
                if (gTriTable[row] == 0xFF) continue;
                double[3][12] edgePoints;
                bool[12] edgeReady;
                for (int item = 0; item < 16; item += 3)
                {
                    if (gTriTable[row + item] == 0xFF) break;
                    double[3][3] triangle;
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
                            foreach (axis; 0 .. 3)
                                edgePoints[edge][axis] =
                                    cornerPoints[ca][axis] +
                                    (cornerPoints[cb][axis] -
                                        cornerPoints[ca][axis]) * t;
                            edgeReady[edge] = true;
                        }
                        triangle[slot] = edgePoints[edge];
                    }
                    const ax = triangle[1][0] - triangle[0][0];
                    const ay = triangle[1][1] - triangle[0][1];
                    const az = triangle[1][2] - triangle[0][2];
                    const bx = triangle[2][0] - triangle[0][0];
                    const by = triangle[2][1] - triangle[0][1];
                    const bz = triangle[2][2] - triangle[0][2];
                    const nx = ay * bz - az * by;
                    const ny = az * bx - ax * bz;
                    const nz = ax * by - ay * bx;
                    const length = sqrt(nx * nx + ny * ny + nz * nz);
                    const light = length > 1e-9
                        ? (nx * 0.35 + ny * 0.85 + nz * 0.4) / length : 0;
                    const intensity = 0.35 + 0.65 *
                        (light < 0 ? -light : light);
                    const averageY = (triangle[0][1] + triangle[1][1] +
                        triangle[2][1]) / 3;
                    const slope = length > 1e-9 ? 1.0 - ny / length : 0;
                    const heightFactor = (averageY + 32.0) / 96.0;
                    const r = 0.16 + 0.20 * heightFactor +
                        0.10 * (slope < 0.65 ? slope : 0.65);
                    const g = 0.34 + 0.30 * heightFactor;
                    const b = 0.13 + 0.08 * heightFactor;
                    const base = cast(uint) data.vertices.length;
                    foreach (slot; 0 .. 3)
                        data.vertices ~= MeshVertex(
                            cast(float) triangle[slot][0],
                            cast(float) triangle[slot][1],
                            cast(float) triangle[slot][2],
                            cast(float) (r * intensity),
                            cast(float) (g * intensity),
                            cast(float) (b * intensity));
                    data.indices ~= base;
                    data.indices ~= base + 1;
                    data.indices ~= base + 2;
                }
            }
    return data;
}

private MeshData buildChunkMesh(WorldConfig config, LightingModel lights,
    double x0, double z0, double size, int cells)
{
    const int NX = cells + 1;
    const int NY = config.verticalCells;
    const int NZ = cells + 1;
    const double y0 = config.minY, y1 = config.maxY;
    const double dx = size / cells;
    const double dy = (y1 - y0) / (NY - 1);
    const double dz = size / cells;
    auto values = new double[NX * NY * NZ];
    foreach (z; 0 .. NZ)
        foreach (y; 0 .. NY)
            foreach (x; 0 .. NX)
                values[(z * NY + y) * NX + x] = config.density(
                    x0 + x * dx, y0 + y * dy, z0 + z * dz);

    static immutable double[3][8] offsets = [
        [0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0],
        [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1],
    ];
    static immutable int[2][12] edgeCorners = [
        [0, 1], [1, 2], [2, 3], [3, 0],
        [4, 5], [5, 6], [6, 7], [7, 4],
        [0, 4], [1, 5], [2, 6], [3, 7],
    ];
    MeshData data;
    foreach (z; 0 .. NZ - 1)
        foreach (y; 0 .. NY - 1)
            foreach (x; 0 .. NX - 1)
            {
                double[8] cornerValues;
                double[3][8] cornerPoints;
                int cubeIndex;
                foreach (corner; 0 .. 8)
                {
                    const ox = cast(int) offsets[corner][0];
                    const oy = cast(int) offsets[corner][1];
                    const oz = cast(int) offsets[corner][2];
                    const gx = x + ox;
                    const gy = y + oy;
                    const gz = z + oz;
                    cornerValues[corner] = values[(gz * NY + gy) * NX + gx];
                    cornerPoints[corner] = [
                        x0 + gx * dx, y0 + gy * dy, z0 + gz * dz,
                    ];
                    if (cornerValues[corner] < 0)
                        cubeIndex |= 1 << corner;
                }
                const row = cubeIndex * 16;
                if (gTriTable[row] == 0xFF) continue;
                double[3][12] edgePoints;
                bool[12] edgeReady;
                for (int item = 0; item < 16; item += 3)
                {
                    if (gTriTable[row + item] == 0xFF) break;
                    double[3][3] triangle;
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
                            foreach (axis; 0 .. 3)
                                edgePoints[edge][axis] =
                                    cornerPoints[ca][axis] +
                                    (cornerPoints[cb][axis] -
                                        cornerPoints[ca][axis]) * t;
                            edgeReady[edge] = true;
                        }
                        triangle[slot] = edgePoints[edge];
                    }
                    const ax = triangle[1][0] - triangle[0][0];
                    const ay = triangle[1][1] - triangle[0][1];
                    const az = triangle[1][2] - triangle[0][2];
                    const bx = triangle[2][0] - triangle[0][0];
                    const by = triangle[2][1] - triangle[0][1];
                    const bz = triangle[2][2] - triangle[0][2];
                    const nx = ay * bz - az * by;
                    const ny = az * bx - ax * bz;
                    const nz = ax * by - ay * bx;
                    const length = sqrt(nx * nx + ny * ny + nz * nz);
                    const sunDot = length > 1e-9
                        ? (nx * lights.sunDirection[0] +
                            ny * lights.sunDirection[1] +
                            nz * lights.sunDirection[2]) / length : 0;
                    const ndotl = sunDot < 0 ? -sunDot : sunDot;
                    const diffuse = ndotl * lights.sunIntensity;
                    const base = cast(uint) data.vertices.length;
                    foreach (slot; 0 .. 3)
                    {
                        const auto color = shadeVertex(config, lights,
                            triangle[slot][0], triangle[slot][1],
                            triangle[slot][2]);
                        const auto material = config.materialAt(
                            triangle[slot][0], triangle[slot][2],
                            triangle[slot][1]);
                        const int variant = (cast(int)
                            (triangle[slot][0] * 0.071 +
                             triangle[slot][2] * 0.053)) & 3;
                        data.vertices ~= MeshVertex(
                            cast(float) triangle[slot][0],
                            cast(float) triangle[slot][1],
                            cast(float) triangle[slot][2],
                            color[0], color[1], color[2],
                            cast(float) (cast(int) material * 4 + variant));
                    }
                    data.indices ~= base;
                    data.indices ~= base + 1;
                    data.indices ~= base + 2;
                }
            }
    return data;
}

TerrainChunk[] buildTerrainChunks(WorldConfig config, LightingModel lights)
{
    ensureTable();
    auto chunks = new TerrainChunk[config.chunksX * config.chunksZ];
    enum int workerCount = 8;
    Thread[] workers;
    ChunkBuildJob[] jobs;
    foreach (job; 0 .. workerCount)
    {
        jobs ~= new ChunkBuildJob(chunks, config, lights, job, workerCount);
        workers ~= new Thread(&jobs[$ - 1].run);
        workers[$ - 1].start();
    }
    foreach (worker; workers)
        worker.join();
    return chunks;
}

TerrainChunk buildTerrainChunk(WorldConfig config, LightingModel lights,
    int index)
{
    ensureTable();
    TerrainChunk chunk;
    const cx = index % config.chunksX;
    const cz = index / config.chunksX;
    const x0 = config.minX + cx * config.chunkSizeX;
    const z0 = config.minZ + cz * config.chunkSizeZ;
    chunk.centerX = x0 + config.chunkSizeX / 2;
    chunk.centerZ = z0 + config.chunkSizeZ / 2;
    chunk.lods[0] = buildChunkMesh(config, lights, x0, z0,
        config.chunkSizeX, config.baseCells);
    chunk.lods[1] = buildChunkMesh(config, lights, x0, z0,
        config.chunkSizeX, config.baseCells / 2);
    return chunk;
}

MeshData buildTorusMesh()
{
    ensureTable();
    enum int N = 20;
    const double minimum = -1.6;
    const double step = 3.2 / (N - 1);
    auto values = new double[N * N * N];
    foreach (z; 0 .. N)
        foreach (y; 0 .. N)
            foreach (x; 0 .. N)
                values[(z * N + y) * N + x] = field(
                    minimum + x * step, minimum + y * step,
                    minimum + z * step);

    static immutable double[3][8] offsets = [
        [0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0],
        [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1],
    ];
    static immutable int[2][12] edgeCorners = [
        [0, 1], [1, 2], [2, 3], [3, 0],
        [4, 5], [5, 6], [6, 7], [7, 4],
        [0, 4], [1, 5], [2, 6], [3, 7],
    ];
    MeshData data;
    foreach (z; 0 .. N - 1)
        foreach (y; 0 .. N - 1)
            foreach (x; 0 .. N - 1)
            {
                double[8] cornerValues;
                double[3][8] cornerPoints;
                int cubeIndex;
                foreach (corner; 0 .. 8)
                {
                    const ox = cast(int) offsets[corner][0];
                    const oy = cast(int) offsets[corner][1];
                    const oz = cast(int) offsets[corner][2];
                    const gx = x + ox;
                    const gy = y + oy;
                    const gz = z + oz;
                    cornerValues[corner] = values[(gz * N + gy) * N + gx];
                    cornerPoints[corner] = [
                        minimum + gx * step,
                        minimum + gy * step,
                        minimum + gz * step,
                    ];
                    if (cornerValues[corner] < 0)
                        cubeIndex |= 1 << corner;
                }
                const row = cubeIndex * 16;
                if (gTriTable[row] == 0xFF) continue;
                double[3][12] edgePoints;
                bool[12] edgeReady;
                for (int item = 0; item < 16; item += 3)
                {
                    if (gTriTable[row + item] == 0xFF) break;
                    double[3][3] triangle;
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
                            foreach (axis; 0 .. 3)
                                edgePoints[edge][axis] =
                                    cornerPoints[ca][axis] +
                                    (cornerPoints[cb][axis] -
                                        cornerPoints[ca][axis]) * t;
                            edgeReady[edge] = true;
                        }
                        triangle[slot] = edgePoints[edge];
                    }
                    const ax = triangle[1][0] - triangle[0][0];
                    const ay = triangle[1][1] - triangle[0][1];
                    const az = triangle[1][2] - triangle[0][2];
                    const bx = triangle[2][0] - triangle[0][0];
                    const by = triangle[2][1] - triangle[0][1];
                    const bz = triangle[2][2] - triangle[0][2];
                    const nx = ay * bz - az * by;
                    const ny = az * bx - ax * bz;
                    const nz = ax * by - ay * bx;
                    const length = sqrt(nx * nx + ny * ny + nz * nz);
                    const light = length > 1e-9
                        ? (nx * 0.4 + ny * 0.7 + nz * 0.5) / length : 0;
                    const intensity = 0.35 + 0.65 *
                        (light < 0 ? -light : light);
                    const base = cast(uint) data.vertices.length;
                    foreach (slot; 0 .. 3)
                        data.vertices ~= MeshVertex(
                            cast(float) triangle[slot][0],
                            cast(float) triangle[slot][1],
                            cast(float) triangle[slot][2],
                            cast(float) (0.22 * intensity),
                            cast(float) (0.74 * intensity),
                            cast(float) (0.97 * intensity));
                    data.indices ~= base;
                    data.indices ~= base + 1;
                    data.indices ~= base + 2;
                }
            }
    return data;
}
