import engine.lighting : LightingModel;
import engine.world : TerrainMaterial, WorldConfig;
import core.time : MonoTime;
import mcmesh : TerrainChunkRebuild, buildTerrainChunk;
import std.stdio : writeln;

void main()
{
    auto world = WorldConfig();
    world.chunksX = 1;
    world.chunksZ = 1;
    world.extentX = 128;
    world.extentZ = 128;
    world.baseCells = 8;
    world.verticalCells = 16;

    const before = world.terrainHeight(0, 0);
    world.addEdit(0, 0, 12, -8, TerrainMaterial.dirt);
    const dug = world.terrainHeight(0, 0);
    assert(dug < before, "dig did not lower terrain");
    assert(world.materialAt(0, 0, dug) == TerrainMaterial.dirt,
        "dig material was not applied");

    world.addEdit(0, 0, 12, 10, TerrainMaterial.rock);
    const built = world.terrainHeight(0, 0);
    assert(built > dug, "construct did not raise terrain");
    assert(world.materialAt(0, 0, built) == TerrainMaterial.rock,
        "constructed material was not applied");

    LightingModel lights;
    lights.sunDirection = [0.35f, 0.85f, -0.40f];
    lights.sunColor = [1.0f, 0.94f, 0.80f];
    auto chunk = buildTerrainChunk(world, lights, 0);
    assert(chunk.lods[0].indices.length > 0, "edited chunk has no mesh");
    assert(chunk.lods[0].vertices.length > 0, "edited chunk has no vertices");

    auto fullWorld = WorldConfig();
    fullWorld.addEdit(0, 0, 8, -5, TerrainMaterial.dirt);
    auto rebuild = new TerrainChunkRebuild(fullWorld, lights, [136]);
    const rebuildStart = MonoTime.currTime;
    rebuild.start();
    rebuild.take();
    const rebuildMs = (MonoTime.currTime - rebuildStart).total!"msecs";
    writeln("edited chunk rebuild ms=", rebuildMs);
    assert(rebuildMs < 1500.0, "edited chunk rebuild is too slow");

    auto manyWorld = WorldConfig();
    int[] manyIndices;
    foreach (i; 0 .. 16)
    {
        const index = (i * 17) % (manyWorld.chunksX * manyWorld.chunksZ);
        const cx = index % manyWorld.chunksX;
        const cz = index / manyWorld.chunksX;
        const x = manyWorld.minX + (cx + 0.5) * manyWorld.chunkSizeX;
        const z = manyWorld.minZ + (cz + 0.5) * manyWorld.chunkSizeZ;
        manyWorld.addEdit(x, z, 8, -5, TerrainMaterial.dirt);
        manyIndices ~= index;
    }
    auto manyRebuild = new TerrainChunkRebuild(manyWorld, lights, manyIndices);
    const manyStart = MonoTime.currTime;
    manyRebuild.start();
    manyRebuild.take();
    const manyMs = (MonoTime.currTime - manyStart).total!"msecs";
    writeln("multi-edit rebuild ms=", manyMs, " chunks=", manyIndices.length);
    assert(manyMs < 5000.0, "multi-edit batch is too slow");

    writeln("PASS terrain dig/build, materials and rebuilt chunk mesh");
}
