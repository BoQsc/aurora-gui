module engine.collision;

import engine.world : WorldConfig;
import std.math : sqrt;

struct RayHit
{
    bool hit;
    double x;
    double y;
    double z;
    double distance;
}

bool solidAt(const WorldConfig world, double x, double y, double z)
{
    return world.density(x, y, z) <= 0;
}

double surfaceHeight(const WorldConfig world, double x, double z)
{
    return world.terrainHeight(x, z);
}

double groundAt(const WorldConfig world, double x, double z,
    double fromHeight)
{
    double y = fromHeight;
    while (y > world.minY())
    {
        if (solidAt(world, x, y, z))
            return y;
        y -= 0.25;
    }
    return world.minY();
}

bool raycastSolid(const WorldConfig world, double ox, double oy, double oz,
    double dx, double dy, double dz, double maxDistance, ref RayHit hit)
{
    const double length = sqrt(dx * dx + dy * dy + dz * dz);
    if (length < 0.000001) return false;
    dx /= length;
    dy /= length;
    dz /= length;
    const double step = 0.2;
    for (double distance = 0.0; distance <= maxDistance; distance += step)
    {
        const x = ox + dx * distance;
        const y = oy + dy * distance;
        const z = oz + dz * distance;
        if (solidAt(world, x, y, z))
        {
            hit.hit = true;
            hit.x = x;
            hit.y = y;
            hit.z = z;
            hit.distance = distance;
            return true;
        }
    }
    hit.hit = false;
    return false;
}
