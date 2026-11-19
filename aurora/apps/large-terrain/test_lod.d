import engine.lighting : LightingModel;
import engine.lod : MaxLodLevels, chunkLod, lodHorizontalCells,
    lodVerticalCells;
import engine.world : WorldConfig;
import mcmesh : TerrainLodRefresh, buildTerrainChunk, buildTerrainChunkForCamera,
    buildTerrainChunksForCamera, planLodRefresh;
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
    assert(world.chunksX == 32 && world.chunksZ == 32, "v2 chunk grid");
    assert(world.extentX == 4096 && world.extentZ == 4096, "v2 world size");
    assert(world.lodCount == 3, "v2 has three LOD tiers");
    assert(world.lodFullRadiusChunks == 3, "v2 full-resolution radius");
    assert(world.lodMidRadiusChunks == 7, "v2 mid-resolution radius");

    const cameraX = centerX(world, 16);
    const cameraZ = centerZ(world, 16);
    int[MaxLodLevels] counts;
    foreach (cx; 0 .. world.chunksX)
        foreach (cz; 0 .. world.chunksZ)
        {
            const lod = chunkLod(world, cameraX, cameraZ, centerX(world, cx),
                centerZ(world, cz));
            const dx = cx > 16 ? cx - 16 : 16 - cx;
            const dz = cz > 16 ? cz - 16 : 16 - cz;
            const ring = dx > dz ? dx : dz;
            const expected = ring <= 3 ? 0 : ring <= 7 ? 1 : 2;
            assert(lod == expected, "chunk LOD does not match its ring");
            ++counts[lod];
        }
    assert(counts[0] == 49, "rings 0..3 must render at full resolution");
    assert(counts[1] == 176, "rings 4..7 must render at half resolution");
    assert(counts[2] == 799, "rings 8+ must render at quarter resolution");
    assert(chunkLod(world, cameraX, cameraZ, centerX(world, 19),
        centerZ(world, 16)) == 0, "ring three must stay full resolution");
    assert(chunkLod(world, cameraX, cameraZ, centerX(world, 20),
        centerZ(world, 16)) == 1, "ring four must halve resolution");
    assert(chunkLod(world, cameraX, cameraZ, centerX(world, 23),
        centerZ(world, 16)) == 1, "ring seven must stay half resolution");
    assert(chunkLod(world, cameraX, cameraZ, centerX(world, 24),
        centerZ(world, 16)) == 2, "ring eight must quarter resolution");

    // The tier rule is chunk-based, not world-distance-based.
    auto compact = WorldConfig();
    compact.chunksX = 8;
    compact.chunksZ = 8;
    compact.extentX = 512;
    compact.extentZ = 512;
    compact.lodFullRadiusChunks = 1;
    compact.lodMidRadiusChunks = 2;
    compact.baseCells = 8;
    compact.verticalCells = 16;
    assert(compact.chunkSizeX == 64, "compact chunk size");
    const compactCameraX = centerX(compact, 1);
    const compactCameraZ = centerZ(compact, 1);
    assert(chunkLod(compact, compactCameraX, compactCameraZ,
        centerX(compact, 2), centerZ(compact, 1)) == 0,
        "compact ring one must stay full resolution");
    assert(chunkLod(compact, compactCameraX, compactCameraZ,
        centerX(compact, 3), centerZ(compact, 1)) == 1,
        "compact ring two must halve resolution");
    assert(chunkLod(compact, compactCameraX, compactCameraZ,
        centerX(compact, 4), centerZ(compact, 1)) == 2,
        "compact ring three must quarter resolution");

    assert(lodHorizontalCells(world, 0) == world.baseCells,
        "LOD 0 keeps the full base cells");
    assert(lodHorizontalCells(world, 1) * 2 == lodHorizontalCells(world, 0),
        "LOD 1 halves horizontal mesh resolution");
    assert(lodHorizontalCells(world, 2) * 2 == lodHorizontalCells(world, 1),
        "LOD 2 halves horizontal resolution again");
    assert(lodVerticalCells(world, 0) == world.verticalCells,
        "LOD 0 keeps the full vertical sampling");
    assert(lodVerticalCells(world, 1) * 2 == lodVerticalCells(world, 0),
        "LOD 1 halves vertical mesh resolution");
    assert(lodVerticalCells(world, 2) * 2 == lodVerticalCells(world, 1),
        "LOD 2 halves vertical sampling again");

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
        " half=", chunk.lods[1].vertices.length,
        " quarter=", chunk.lods[2].vertices.length);
    assert(chunk.lods[0].vertices.length > 0, "full LOD produced no vertices");
    assert(chunk.lods[1].vertices.length > 0, "half LOD produced no vertices");
    assert(chunk.lods[2].vertices.length > 0, "quarter LOD produced no vertices");
    assert(chunk.lods[1].vertices.length < chunk.lods[0].vertices.length,
        "half LOD is not a coarser mesh");
    assert(chunk.lods[2].vertices.length < chunk.lods[1].vertices.length,
        "quarter LOD is not a coarser mesh");
    assert(chunk.lodReady[0] && chunk.lodReady[1] && chunk.lodReady[2],
        "full chunk build must mark all three LODs ready");

    // A camera-aware build must produce only the tier that chunk needs.
    auto near = buildTerrainChunkForCamera(world, lights, 16 * 32 + 16,
        cameraX, cameraZ);
    assert(near.lodReady[0] && !near.lodReady[1] && !near.lodReady[2],
        "near chunk must build only the full LOD");
    auto mid = buildTerrainChunkForCamera(world, lights, 16 * 32 + 21,
        cameraX, cameraZ);
    assert(!mid.lodReady[0] && mid.lodReady[1] && !mid.lodReady[2],
        "mid chunk must build only the half LOD");
    auto far = buildTerrainChunkForCamera(world, lights, 16 * 32 + 24,
        cameraX, cameraZ);
    assert(!far.lodReady[0] && !far.lodReady[1] && far.lodReady[2],
        "far chunk must build only the quarter LOD");

    // Streamed refresh: a compact camera move requests exactly the tiers that
    // are missing, nearest first, and the worker fills only those tiers.
    auto chunks = buildTerrainChunksForCamera(compact, lights,
        compactCameraX, compactCameraZ);
    assert(chunks.length == 64, "compact chunk count");
    foreach (chunkIndex, built; chunks)
    {
        const cx = cast(int) chunkIndex % compact.chunksX;
        const cz = cast(int) chunkIndex / compact.chunksX;
        const desired = chunkLod(compact, compactCameraX, compactCameraZ,
            centerX(compact, cx), centerZ(compact, cz));
        assert(built.lodReady[desired], "startup skipped a desired tier");
    }
    auto idle = planLodRefresh(compact, chunks, compactCameraX, compactCameraZ,
        256);
    assert(idle.length == 0, "startup left streaming work behind");

    const movedX = centerX(compact, 0);
    const movedZ = centerZ(compact, 0);
    auto requests = planLodRefresh(compact, chunks, movedX, movedZ, 256);
    assert(requests.length > 0, "camera move produced no LOD work");
    foreach (request; requests)
    {
        const cx = request.index % compact.chunksX;
        const cz = request.index / compact.chunksX;
        assert(request.lod == chunkLod(compact, movedX, movedZ,
            centerX(compact, cx), centerZ(compact, cz)),
            "refresh request does not match the desired tier");
        assert(!chunks[request.index].lodReady[request.lod],
            "refresh requested a tier that is already resident");
    }
    int[] indices;
    int[] lods;
    foreach (request; requests)
    {
        indices ~= request.index;
        lods ~= request.lod;
    }
    auto refresh = new TerrainLodRefresh(compact, lights, indices, lods);
    refresh.start();
    refresh.take();
    assert(refresh.chunks.length == requests.length,
        "refresh result count");
    foreach (slot, built; refresh.chunks)
    {
        int ready;
        foreach (lod; 0 .. built.lods.length)
            if (built.lodReady[lod]) ++ready;
        assert(ready == 1, "refresh must return exactly one resident tier");
        assert(built.lodReady[lods[slot]], "refresh built the wrong tier");
    }
    foreach (slot, chunkIndex; indices)
        chunks[chunkIndex] = refresh.chunks[slot];
    auto after = planLodRefresh(compact, chunks, movedX, movedZ, 256);
    assert(after.length == 0, "refresh did not satisfy the moved camera");

    writeln("PASS v2 chunk LOD: 3 tiers 49/176/799, startup tiers, ",
        "nearest-first streaming and one resident tier per chunk");
}
