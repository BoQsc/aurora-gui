module engine.player;

import engine.world : WorldConfig;
import engine.collision : surfaceHeight;
import std.math : cos, sin;

struct PlayerInput
{
    bool forward;
    bool back;
    bool left;
    bool right;
    bool sprint;
    bool jump;
}

struct PlayerState
{
    double x;
    double y;
    double z;
    double yaw;
    double velocityX;
    double velocityY;
    double velocityZ;
    bool grounded;
    bool jumpHeld;
}

void updatePlayer(ref PlayerState player, WorldConfig world,
    PlayerInput input, double dt)
{
    if (dt <= 0) return;
    if (dt > 0.1) dt = 0.1;
    const forward = (input.forward ? 1.0 : 0.0) -
        (input.back ? 1.0 : 0.0);
    const strafe = (input.right ? 1.0 : 0.0) -
        (input.left ? 1.0 : 0.0);
    const forwardX = sin(player.yaw);
    const forwardZ = -cos(player.yaw);
    const rightX = cos(player.yaw);
    const rightZ = sin(player.yaw);
    const speed = 11.0 * (input.sprint ? 1.9 : 1.0);
    const targetX = (forwardX * forward + rightX * strafe) * speed;
    const targetZ = (forwardZ * forward + rightZ * strafe) * speed;
    const blend = dt > 0.08 ? 1.0 : dt * 14.0;
    player.velocityX += (targetX - player.velocityX) * blend;
    player.velocityZ += (targetZ - player.velocityZ) * blend;
    player.x += player.velocityX * dt;
    player.z += player.velocityZ * dt;
    const limitX = world.extentX / 2 - 4;
    const limitZ = world.extentZ / 2 - 4;
    if (player.x < -limitX) player.x = -limitX;
    if (player.x > limitX) player.x = limitX;
    if (player.z < -limitZ) player.z = -limitZ;
    if (player.z > limitZ) player.z = limitZ;

    if (input.jump && player.grounded && !player.jumpHeld)
    {
        player.velocityY = 9.0;
        player.grounded = false;
    }
    player.jumpHeld = input.jump;
    player.velocityY -= 24.0 * dt;
    player.y += player.velocityY * dt;
    const ground = surfaceHeight(world, player.x, player.z) + 2.26;
    if (player.y <= ground)
    {
        player.y = ground;
        player.velocityY = 0;
        player.grounded = true;
    }
    else
        player.grounded = false;
}
