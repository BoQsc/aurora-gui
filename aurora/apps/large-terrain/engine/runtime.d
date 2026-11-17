module engine.runtime;

import engine.atmosphere : SkyPalette;
import engine.frame_clock : FrameClock;
import engine.lighting : LightingModel;
import engine.world : WorldConfig;

struct TerrainRuntime
{
    WorldConfig world;
    SkyPalette sky;
    LightingModel lights;
    FrameClock clock;
}

TerrainRuntime defaultRuntime()
{
    TerrainRuntime runtime;
    runtime.sky.zenith = [0.018f, 0.045f, 0.12f];
    runtime.sky.horizon = [0.52f, 0.37f, 0.24f];
    runtime.sky.ground = [0.17f, 0.18f, 0.17f];
    runtime.sky.sun = [1.0f, 0.68f, 0.28f];
    runtime.lights.sunDirection = [0.35f, 0.85f, -0.40f];
    runtime.lights.sunColor = [1.0f, 0.94f, 0.80f];
    runtime.lights.ambient = 0.65f;
    runtime.lights.sunIntensity = 1.35f;
    return runtime;
}
