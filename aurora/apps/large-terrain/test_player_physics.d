import engine.player : PlayerInput, PlayerState, updatePlayer;
import engine.world : WorldConfig;
import std.math : abs;
import std.stdio : writeln;

void main()
{
    auto world = WorldConfig();
    PlayerState player;
    player.x = 0;
    player.z = 0;
    player.y = world.terrainHeight(player.x, player.z) + 2.26;
    player.yaw = 0;
    player.velocityX = 0;
    player.velocityY = 0;
    player.velocityZ = 0;
    player.grounded = true;

    PlayerInput input;
    input.forward = true;
    updatePlayer(player, world, input, 1.0 / 64.0);
    writeln("after forward x=", player.x, " z=", player.z,
        " vz=", player.velocityZ, " yaw=", player.yaw);
    assert(player.z < -0.01, "forward movement is not camera-relative");

    player.grounded = true;
    player.jumpHeld = false;
    input.forward = false;
    input.jump = true;
    updatePlayer(player, world, input, 1.0 / 64.0);
    assert(player.velocityY > 0, "jump did not apply upward velocity");
    assert(!player.grounded, "jump left the player grounded");

    input.jump = false;
    foreach (step; 0 .. 240)
        updatePlayer(player, world, input, 1.0 / 64.0);
    assert(player.grounded, "player did not land");
    const expectedY = world.terrainHeight(player.x, player.z) + 2.26;
    assert(abs(player.y - expectedY) < 0.05, "player did not settle to ground");

    player.x = 1e9;
    updatePlayer(player, world, input, 1.0 / 64.0);
    assert(player.x <= world.extentX / 2 - 4, "world bounds are not enforced");
    writeln("PASS player movement, jump, gravity, ground and bounds");
}
