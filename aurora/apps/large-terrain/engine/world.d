module engine.world;

import std.math : cos, sin;

struct WorldConfig
{
    string title = "Large Marching Cubes Terrain";
    int chunksX = 8;
    int chunksZ = 8;
    int baseCells = 64;
    int verticalCells = 96;
    double extentX = 2048;
    double extentY = 512;
    double extentZ = 2048;
    int lodCount = 2;
    double lodNearDistance = 600;
    double farPlane = 5000;

    double minX() const { return -extentX / 2; }
    double minZ() const { return -extentZ / 2; }
    double chunkSizeX() const { return extentX / chunksX; }
    double chunkSizeZ() const { return extentZ / chunksZ; }
    double minY() const { return -extentY / 2; }
    double maxY() const { return extentY / 2; }

    double terrainHeight(double x, double z) const
    {
        return 18.0 * sin(x * 0.007) * cos(z * 0.006) +
            6.0 * sin(x * 0.019 + z * 0.013) +
            3.0 * cos(z * 0.031) - 2.0;
    }
}
