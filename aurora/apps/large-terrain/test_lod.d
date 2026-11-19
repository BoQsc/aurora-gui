import engine.lighting : LightingModel;
import engine.lod : chunkLod, lodHorizontalCells, lodVerticalCells;
import engine.world : WorldConfig;
import mcmesh : TerrainChunkCompletion, buildTerrainChunk,
    buildTerrainChunkForCamera, buildTerrainChunksForCamera;
import std.stdio : writeln;

private double centerX(const WorldConfig config, int cx)
{
    return config.minX + (cx + 0.5) * config.chunkSizeX;
}

private double centerZ(const WorldConfig config, int cz)
{
    return config.minZ + (cz + 0.5) * config.chunkSizeZ;
}

void main()
{
    auto world = WorldConfig();
    assert(world.lodFullRadiusChunks == 4, "default full-resolution radius");

    const cameraX = centerX(world, 4);
    const cameraZ = centerZ(world, 4);
    int nearFull;
    int pastFull;
    foreach (cx; 0 .. world.chunksX)
        foreach (cz; 0 .. world.chunksZ)
        {
            const lod = chunkLod(world, cameraX, cameraZ, centerX(world, cx),
                centerZ(world, cz));
            const dx = cx > 4 ? cx - 4 : 4 - cx;
            const dz = cz > 4 ? cz - 4 : 4 - cz;
            const ring = dx > dz ? dx : dz;
            assert(lod == (ring > 4 ? 1 : 0),
                "chunk LOD does not match its ring");
            if (lod == 0) ++nearFull; else ++pastFull;
        }
    assert(nearFull == 81, "rings 0..4 must render at full resolution");
    assert(pastFull > 0, "chunks past four rings must use the half LOD");
    assert(chunkLod(world, cameraX, cameraZ, centerX(world, 8),
        centerZ(world, 4)) == 0, "four chunks away must stay full resolution");
    assert(chunkLod(world, cameraX, cameraZ, centerX(world, 9),
        centerZ(world, 4)) == 1, "five chunks away must halve resolution");
    assert(chunkLod(world, cameraX, cameraZ, centerX(world, 9),
        centerZ(world, 9)) == 1, "diagonal ring past four must halve");
    assert(chunkLod(world, cameraX, cameraZ, centerX(world, 0),
        centerZ(world, 0)) == 0, "diagonal ring four must stay full");

    // The rule is chunk-based, not world-distance-based: with 64-unit chunks,
    // five rings away is 320 world units, well inside any distance threshold.
    auto compact = WorldConfig();
    compact.chunksX = 16;
    compact.chunksZ = 16;
    compact.extentX = 1024;
    compact.extentZ = 1024;
    assert(compact.chunkSizeX == 64, "compact chunk size");
    assert(compact.lodFullRadiusChunks == 4, "compact LOD radius");
    assert(chunkLod(compact, centerX(compact, 4), centerZ(compact, 4),
        centerX(compact, 9), centerZ(compact, 4)) == 1,
        "chunk distance must not fall back to world distance");

    assert(lodHorizontalCells(world, 0) == world.baseCells,
        "LOD 0 keeps the full base cells");
    assert(lodHorizontalCells(world, 1) * 2 == lodHorizontalCells(world, 0),
        "LOD 1 halves horizontal mesh resolution");
    assert(lodVerticalCells(world, 0) == world.verticalCells,
        "LOD 0 keeps the full vertical sampling");
    assert(lodVerticalCells(world, 1) * 2 == lodVerticalCells(world, 0),
        "LOD 1 halves vertical mesh resolution");

    LightingModel lights;
    lights.sunDirection = [0.35f, 0.85f, -0.40f];
    lights.sunColor = [1.0f, 0.94f, 0.80f];
    auto meshWorld = WorldConfig();
    meshWorld.chunksX = 1;
    meshWorld.chunksZ = 1;
    meshWorld.extentX = 128;
    meshWorld.extentZ = 128;
    meshWorld.baseCells = 8;
    meshWorld.verticalCells = 16;
    auto chunk = buildTerrainChunk(meshWorld, lights, 0);
    writeln("chunk LOD vertices full=", chunk.lods[0].vertices.length,
        " half=", chunk.lods[1].vertices.length);
    assert(chunk.lods[0].vertices.length > 0, "full LOD produced no vertices");
    assert(chunk.lods[1].vertices.length > 0, "half LOD produced no vertices");
    assert(chunk.lods[1].vertices.length < chunk.lods[0].vertices.length,
        "half LOD is not a coarser mesh");
    assert(chunk.lodReady[0] && chunk.lodReady[1],
        "full chunk build must mark both LODs ready");

    const nearCameraX = centerX(world, 8);
    const nearCameraZ = centerZ(world, 8);
    auto near = buildTerrainChunkForCamera(world, lights, 136, nearCameraX,
        nearCameraZ);
    assert(near.lodReady[0] && !near.lodReady[1],
        "near chunk must build only the full LOD at startup");
    auto far = buildTerrainChunkForCamera(world, lights, 0, nearCameraX,
        nearCameraZ);
    assert(far.lodReady[1] && !far.lodReady[0],
        "far chunk must build only the half LOD at startup");

    auto initial = buildTerrainChunksForCamera(meshWorld, lights,
        centerX(meshWorld, 0), centerZ(meshWorld, 0));
    assert(initial.length == 1, "initial chunk count");
    assert(initial[0].lodReady[0] && !initial[0].lodReady[1],
        "initial build must defer the complementary LOD");
    auto completion = new TerrainChunkCompletion(initial, meshWorld, lights);
    completion.start();
    auto completed = completion.take();
    assert(completed[0].lodReady[0] && completed[0].lodReady[1],
        "background completion must fill the deferred LOD");
    assert(completed[0].lods[1].vertices.length > 0,
        "completed half LOD has no vertices");

    writeln("PASS chunk LOD: full resolution through 4 rings, half past 4, ",
        "startup builds one LOD and completes the rest");
}
