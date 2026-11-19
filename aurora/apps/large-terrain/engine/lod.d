module engine.lod;

import engine.world : WorldConfig;
import std.math : floor;

/// Returns the LOD for one chunk. Rings 0..lodFullRadiusChunks use LOD 0;
/// every chunk past that radius uses the half-resolution LOD 1.
/// Rings are measured in chunks, not world units, so the rule does not change
/// with the configured chunk size.
int chunkLod(const WorldConfig config, double cameraX, double cameraZ,
    double centerX, double centerZ)
{
    const cameraChunkX = cast(int) floor((cameraX - config.minX) /
        config.chunkSizeX);
    const cameraChunkZ = cast(int) floor((cameraZ - config.minZ) /
        config.chunkSizeZ);
    const chunkX = cast(int) floor((centerX - config.minX) /
        config.chunkSizeX);
    const chunkZ = cast(int) floor((centerZ - config.minZ) /
        config.chunkSizeZ);
    const dx = cameraChunkX > chunkX
        ? cameraChunkX - chunkX : chunkX - cameraChunkX;
    const dz = cameraChunkZ > chunkZ
        ? cameraChunkZ - chunkZ : chunkZ - cameraChunkZ;
    const ring = dx > dz ? dx : dz;
    return ring > config.lodFullRadiusChunks ? 1 : 0;
}

/// Horizontal marching-cubes cell count for a LOD; each LOD halves it.
int lodHorizontalCells(const WorldConfig config, int lod)
{
    int divisor = 1;
    foreach (i; 0 .. lod)
        divisor *= 2;
    const cells = config.baseCells / divisor;
    return cells < 2 ? 2 : cells;
}

/// Vertical sampling count for a LOD; the mesh resolution halves in every
/// axis, so the column count halves with the cell count.
int lodVerticalCells(const WorldConfig config, int lod)
{
    int divisor = 1;
    foreach (i; 0 .. lod)
        divisor *= 2;
    const cells = config.verticalCells / divisor;
    return cells < 2 ? 2 : cells;
}