import engine.game : GameState, initGame, updateGame;
import engine.world : WorldConfig;
import std.stdio : writeln;

void main()
{
    auto world = WorldConfig();
    auto game = GameState();
    initGame(game, world);
    assert(game.actors.length == 26, "actor count");
    assert(game.plants.length == 900, "vegetation count");
    int zombies;
    int npcs;
    foreach (actor; game.actors)
        if (actor.zombie) ++zombies; else ++npcs;
    assert(zombies == 18 && npcs == 8, "zombie/npc mix");

    auto shot = GameState();
    shot.actors ~= game.actors[0];
    shot.actors[0].x = 0;
    shot.actors[0].z = -10;
    shot.actors[0].y = world.terrainHeight(0, -10);
    shot.actors[0].health = 34;
    bool fired;
    updateGame(shot, world, 0, 0, 4, 0, 0.1, true, true, fired);
    assert(fired, "weapon did not fire");
    assert(shot.score == 100 && shot.zombieKills == 1,
        "zombie kill was not scored");
    assert(shot.ammo == 29, "ammo was not consumed");

    writeln("PASS FPS actors, vegetation, shooting, health and score");
}
