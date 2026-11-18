module engine.world;

import std.math : cos, sin, sqrt;

enum TerrainMaterial : ubyte
{
    grass,
    dirt,
    rock,
    sand,
}

struct TerrainEdit
{
    double x;
    double z;
    double radius;
    double delta;
    TerrainMaterial material;
}

struct CaveEdit
{
    double x;
    double y;
    double z;
    double radius;
    TerrainMaterial material;
}

struct WorldConfig
{
    string title = "Large Marching Cubes Terrain";
    int chunksX = 16;
    int chunksZ = 16;
    int baseCells = 48;
    int verticalCells = 128;
    double extentX = 2048;
    double extentY = 512;
    double extentZ = 2048;
    int lodCount = 2;
    double lodNearDistance = 600;
    double farPlane = 5000;
    TerrainEdit[] edits;
    CaveEdit[] caves;

    double minX() const { return -extentX / 2; }
    double minZ() const { return -extentZ / 2; }
    double chunkSizeX() const { return extentX / chunksX; }
    double chunkSizeZ() const { return extentZ / chunksZ; }
    double minY() const { return -extentY / 2; }
    double maxY() const { return extentY / 2; }

    double baseHeight(double x, double z) const
    {
        return 18.0 * sin(x * 0.007) * cos(z * 0.006) +
            6.0 * sin(x * 0.019 + z * 0.013) +
            3.0 * cos(z * 0.031) - 2.0;
    }

    double terrainHeight(double x, double z) const
    {
        double height = baseHeight(x, z);
        foreach (edit; edits)
        {
            const dx = x - edit.x;
            const dz = z - edit.z;
            const distance = dx * dx + dz * dz;
            if (distance >= edit.radius * edit.radius) continue;
            const falloff = 1.0 - distance /
                (edit.radius * edit.radius);
            height += edit.delta * falloff * falloff;
        }
        return height;
    }

    double density(double x, double y, double z) const
    {
        double value = y - terrainHeight(x, z);
        foreach (cave; caves)
        {
            const dx = x - cave.x;
            const dy = y - cave.y;
            const dz = z - cave.z;
            const caveValue = cave.radius -
                sqrt(dx * dx + dy * dy + dz * dz);
            if (caveValue > value) value = caveValue;
        }
        return value;
    }

    TerrainMaterial materialAt(double x, double z, double height) const
    {
        foreach_reverse (edit; edits)
        {
            const dx = x - edit.x;
            const dz = z - edit.z;
            if (dx * dx + dz * dz < edit.radius * edit.radius)
                return edit.material;
        }
        if (height > 14) return TerrainMaterial.rock;
        if (height < -8) return TerrainMaterial.sand;
        return TerrainMaterial.grass;
    }

    void addEdit(double x, double z, double radius, double delta,
        TerrainMaterial material)
    {
        edits ~= TerrainEdit(x, z, radius, delta, material);
    }

    void addCave(double x, double y, double z, double radius,
        TerrainMaterial material)
    {
        caves ~= CaveEdit(x, y, z, radius, material);
    }
}

string materialName(TerrainMaterial material)
{
    final switch (material)
    {
        case TerrainMaterial.grass: return "GRASS";
        case TerrainMaterial.dirt: return "DIRT";
        case TerrainMaterial.rock: return "ROCK";
        case TerrainMaterial.sand: return "SAND";
    }
}
