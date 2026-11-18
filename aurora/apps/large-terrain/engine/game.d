module engine.game;

import engine.world : WorldConfig;
import std.math : cos, sin, sqrt;

struct Actor
{
    double x;
    double y;
    double z;
    double yaw;
    float health;
    float respawn;
    float attackTimer;
    float wanderPhase;
    bool zombie;
    bool alive;
}

struct Vegetation
{
    double x;
    double z;
    float scale;
    int kind;
}

struct GameState
{
    Actor[] actors;
    Vegetation[] plants;
    double playerHealth = 100;
    int ammo = 30;
    int reserve = 90;
    float fireCooldown = 0;
    float hitFlash = 0;
    float damageFlash = 0;
    int score;
    int zombieKills;
}

private uint nextRandom(ref uint state)
{
    state = state * 1664525u + 1013904223u;
    return state;
}

private double random01(ref uint state)
{
    return cast(double) (nextRandom(state) >> 8) / 16777216.0;
}

void initGame(ref GameState game, WorldConfig world)
{
    game = GameState();
    uint seed = 0x51A7C0DE;
    foreach (i; 0 .. 18)
    {
        const angle = random01(seed) * 6.283185307179586;
        const radius = 25.0 + random01(seed) * 55.0;
        const x = sin(angle) * radius;
        const z = 40.0 + cos(angle) * radius;
        game.actors ~= Actor(x, world.terrainHeight(x, z), z,
            angle, 100, 0, 0, cast(float) random01(seed), true, true);
    }
    foreach (i; 0 .. 8)
    {
        const angle = random01(seed) * 6.283185307179586;
        const radius = 12.0 + random01(seed) * 25.0;
        const x = sin(angle) * radius;
        const z = 40.0 + cos(angle) * radius;
        game.actors ~= Actor(x, world.terrainHeight(x, z), z,
            angle, 100, 0, 0, cast(float) random01(seed), false, true);
    }
    foreach (i; 0 .. 900)
    {
        const angle = random01(seed) * 6.283185307179586;
        const radius = 22.0 + random01(seed) * 180.0;
        const x = sin(angle) * radius;
        const z = 40.0 + cos(angle) * radius;
        game.plants ~= Vegetation(x, z,
            cast(float) (0.7 + random01(seed) * 0.8),
            random01(seed) < 0.18 ? 1 : 0);
    }
}

void updateGame(ref GameState game, WorldConfig world, double px,
    double pz, double py, double yaw, double dt, bool firing, bool captured,
    ref bool didFire)
{
    didFire = false;
    if (game.fireCooldown > 0) game.fireCooldown -= cast(float) dt;
    if (game.hitFlash > 0) game.hitFlash -= cast(float) dt;
    if (game.damageFlash > 0) game.damageFlash -= cast(float) dt;

    const fx = sin(yaw);
    const fz = -cos(yaw);
    if (firing && captured && game.fireCooldown <= 0 && game.ammo > 0)
    {
        game.ammo--;
        game.fireCooldown = 0.12f;
        didFire = true;
        int best = -1;
        double bestDistance = 140.0;
        foreach (index, actor; game.actors)
        {
            if (!actor.alive || !actor.zombie) continue;
            const dx = actor.x - px;
            const dz = actor.z - pz;
            const distance = sqrt(dx * dx + dz * dz);
            if (distance > bestDistance || distance < 0.001) continue;
            if ((dx * fx + dz * fz) / distance < 0.94) continue;
            best = cast(int) index;
            bestDistance = distance;
        }
        if (best >= 0)
        {
            game.actors[best].health -= 34;
            if (game.actors[best].health <= 0)
            {
                game.actors[best].alive = false;
                game.actors[best].respawn = 5;
                game.score += 100;
                ++game.zombieKills;
            }
        }
    }
    if (game.ammo == 0 && game.reserve > 0 && game.fireCooldown <= 0)
    {
        const loaded = game.reserve < 30 ? game.reserve : 30;
        game.ammo = loaded;
        game.reserve -= loaded;
    }

    foreach (ref actor; game.actors)
    {
        if (!actor.alive)
        {
            actor.respawn -= cast(float) dt;
            if (actor.respawn <= 0)
            {
                actor.alive = true;
                actor.health = 100;
                actor.x = px + 20.0;
                actor.z = pz + 20.0;
                actor.y = world.terrainHeight(actor.x, actor.z);
            }
            continue;
        }
        if (actor.zombie)
        {
            double dx = px - actor.x;
            double dz = pz - actor.z;
            const distance = sqrt(dx * dx + dz * dz);
            if (distance > 1.6)
            {
                const speed = 2.2;
                dx /= distance;
                dz /= distance;
                actor.x += dx * speed * dt;
                actor.z += dz * speed * dt;
                actor.yaw = cast(double) (sqrt(dx * dx + dz * dz) > 0 ?
                    (-dx) : 0);
            }
            else
            {
                actor.attackTimer += cast(float) dt;
                if (actor.attackTimer >= 1.0)
                {
                    actor.attackTimer = 0;
                    game.playerHealth -= 5;
                    game.damageFlash = 0.25f;
                }
            }
            actor.y = world.terrainHeight(actor.x, actor.z);
        }
        else
        {
            actor.wanderPhase += cast(float) (dt * 0.7);
            actor.x += sin(actor.wanderPhase) * dt * 0.8;
            actor.z += cos(actor.wanderPhase * 0.7) * dt * 0.8;
            actor.y = world.terrainHeight(actor.x, actor.z);
        }
    }
    if (game.playerHealth <= 0)
    {
        game.playerHealth = 100;
        game.damageFlash = 0.6f;
    }
}
