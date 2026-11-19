module engine.runtime;

import engine.atmosphere : SkyPalette, paletteForTime, sunDirectionAt;
import engine.frame_clock : FrameClock;
import engine.lighting : LightingModel;
import engine.world : WorldConfig;

struct TerrainRuntime
{
    WorldConfig world;
    SkyPalette sky;
    LightingModel lights;
    FrameClock clock;
    double timeOfDay = 9.0;
    // A full 24-hour cycle in eight minutes is fast enough to see without
    // turning the world into a strobe.
    double dayLengthSeconds = 480.0;
    bool timePaused;

    void applyTime()
    {
        double hours = timeOfDay % 24.0;
        if (hours < 0) hours += 24.0;
        timeOfDay = hours;
        sky = paletteForTime(hours);
        lights.sunDirection = sunDirectionAt(hours);
        lights.sunIntensity = sky.sunIntensity;
    }

    /// Advances the clock and refreshes the derived sky/sun state.
    void advanceTime(double seconds)
    {
        if (timePaused || seconds <= 0 || dayLengthSeconds <= 0) return;
        timeOfDay += seconds / dayLengthSeconds * 24.0;
        if (timeOfDay >= 24.0) timeOfDay -= 24.0;
        applyTime();
    }
}

TerrainRuntime defaultRuntime()
{
    TerrainRuntime runtime;
    runtime.lights.sunColor = [1.0f, 0.94f, 0.80f];
    runtime.lights.skyColor = [0.32f, 0.46f, 0.68f];
    runtime.lights.groundColor = [0.20f, 0.18f, 0.13f];
    runtime.lights.ambient = 0.65f;
    runtime.lights.sunIntensity = 1.35f;
    runtime.timeOfDay = 9.0;
    runtime.applyTime();
    return runtime;
}
