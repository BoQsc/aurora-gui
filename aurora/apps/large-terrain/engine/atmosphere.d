module engine.atmosphere;

import std.math : cos, exp, sin, sqrt;

struct SkyPalette
{
    float[3] zenith;
    float[3] horizon;
    float[3] ground;
    float[3] sun;
    float[3] fog;
    float[3] tint;
    float sunIntensity = 1.0f;
}

private float clamp01(double value)
{
    return value < 0 ? 0 : value > 1 ? 1 : cast(float) value;
}

private float smooth(float value)
{
    return value * value * (3.0f - 2.0f * value);
}

private float[3] mix(float[3] a, float[3] b, float t)
{
    return [
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    ];
}

/// Solar direction for a 24-hour clock. The sun rises in the east at 06:00,
/// peaks at noon and sets in the west at 18:00. The returned vector points
/// from the world toward the sun.
float[3] sunDirectionAt(double hours)
{
    const azimuth = (hours - 6.0) / 24.0 * 6.283185307179586;
    double x = cos(azimuth);
    double y = sin(azimuth);
    const z = -0.32;
    const length = sqrt(x * x + y * y + z * z);
    return [cast(float) (x / length), cast(float) (y / length),
        cast(float) (z / length)];
}

/// v2 atmosphere: the whole sky/light palette follows the clock, so the world
/// moves from blue daylight through warm dawn/dusk into a dark blue night.
SkyPalette paletteForTime(double hours)
{
    hours = hours % 24.0;
    if (hours < 0) hours += 24.0;
    const elevation = sin((hours - 6.0) / 24.0 * 6.283185307179586);
    // Keep useful ambient through civil twilight; the world should turn blue
    // well after the sun crosses the horizon, not at the instant it touches it.
    const day = smooth(clamp01((elevation + 0.35) / 0.55));
    const night = 1.0f - day;
    // Warm band concentrated around sunrise and sunset.
    const horizonDistance = elevation < 0 ? -elevation : elevation;
    const warm = exp(-horizonDistance * horizonDistance / 0.010) *
        clamp01((elevation + 0.28) / 0.28);

    const float[3] dayZenith = [0.16f, 0.38f, 0.78f];
    const float[3] dayHorizon = [0.62f, 0.77f, 0.93f];
    const float[3] nightZenith = [0.006f, 0.010f, 0.035f];
    const float[3] nightHorizon = [0.025f, 0.038f, 0.085f];
    const float[3] warmHorizon = [0.95f, 0.44f, 0.20f];
    const float[3] warmZenith = [0.25f, 0.20f, 0.34f];
    const float[3] nightGround = [0.008f, 0.010f, 0.018f];
    const float[3] dayGround = [0.13f, 0.15f, 0.16f];
    const float[3] moon = [0.50f, 0.58f, 0.82f];
    const float[3] sunColor = [1.0f, 0.96f, 0.86f];
    const float[3] warmSun = [1.0f, 0.55f, 0.24f];
    const float[3] nightTint = [0.28f, 0.33f, 0.47f];
    const float[3] dayTint = [1.0f, 1.0f, 1.0f];
    const float[3] warmTint = [1.0f, 0.82f, 0.68f];

    SkyPalette sky;
    sky.zenith = mix(mix(nightZenith, dayZenith, day), warmZenith,
        warm * 0.55f);
    sky.horizon = mix(mix(nightHorizon, dayHorizon, day), warmHorizon,
        warm * 0.85f);
    sky.ground = mix(nightGround, dayGround, day);
    sky.sun = mix(mix(moon, sunColor, day), warmSun, warm * 0.90f);
    sky.fog = mix(sky.horizon, sky.zenith, 0.10f);
    sky.tint = mix(mix(nightTint, dayTint, day), warmTint, warm * 0.35f);
    sky.sunIntensity = 0.20f + 0.95f * day;
    return sky;
}

string clockText(double hours)
{
    hours = hours % 24.0;
    if (hours < 0) hours += 24.0;
    int totalMinutes = cast(int) (hours * 60.0 + 0.5);
    if (totalMinutes >= 24 * 60) totalMinutes = 0;
    const hour = totalMinutes / 60;
    const minute = totalMinutes % 60;
    char[5] text;
    text[0] = cast(char) ('0' + hour / 10);
    text[1] = cast(char) ('0' + hour % 10);
    text[2] = ':';
    text[3] = cast(char) ('0' + minute / 10);
    text[4] = cast(char) ('0' + minute % 10);
    // The caller keeps this string, so copy it out of the stack frame.
    return text[].idup;
}

string phaseName(double hours)
{
    hours = hours % 24.0;
    if (hours < 0) hours += 24.0;
    if (hours < 5.0 || hours >= 21.0) return "NIGHT";
    if (hours < 7.5) return "DAWN";
    if (hours < 17.0) return "DAY";
    if (hours < 20.0) return "DUSK";
    return "NIGHT";
}
