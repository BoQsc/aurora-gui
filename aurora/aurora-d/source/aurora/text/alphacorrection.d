module aurora.text.alphacorrection;

// Grayscale alpha model and gamma coefficients adapted from Microsoft Terminal:
// https://github.com/microsoft/terminal/blob/1283c0f5b99a2961673249fa77c6b986efb5086c/src/renderer/atlas/dwrite.hlsl
// https://github.com/microsoft/terminal/blob/main/src/renderer/atlas/dwrite_helpers.cpp
// Copyright (c) Microsoft Corporation. Licensed under the MIT license;
// see licenses/Microsoft-Terminal-MIT.txt. No native API is used here.

import aurora.color : Color;
import std.math : isFinite;

enum NativeIntensityLevels = 17;
enum NativeContrastLevels = 8;
enum NativeCoverageClasses = NativeIntensityLevels * NativeContrastLevels;

struct GammaRatios
{
    float x, y, z, w;
}

GammaRatios gammaRatios(float gamma) @safe pure nothrow @nogc
{
    static immutable float[4][13] coefficients = [
        [0.0000f, 0.0000f, 0.0000f, 0.0000f],
        [0.0166f, -0.0807f, 0.2227f, -0.0751f],
        [0.0350f, -0.1760f, 0.4325f, -0.1370f],
        [0.0543f, -0.2821f, 0.6302f, -0.1876f],
        [0.0739f, -0.3963f, 0.8167f, -0.2287f],
        [0.0933f, -0.5161f, 0.9926f, -0.2616f],
        [0.1121f, -0.6395f, 1.1588f, -0.2877f],
        [0.1300f, -0.7649f, 1.3159f, -0.3080f],
        [0.1469f, -0.8911f, 1.4644f, -0.3234f],
        [0.1627f, -1.0170f, 1.6051f, -0.3347f],
        [0.1773f, -1.1420f, 1.7385f, -0.3426f],
        [0.1908f, -1.2652f, 1.8650f, -0.3476f],
        [0.2031f, -1.3864f, 1.9851f, -0.3501f],
    ];
    if (!isFinite(gamma)) gamma = 1.8f;
    const index = cast(int) (clamp(gamma, 1.0f, 2.2f) * 10.0f + 0.5f) - 10;
    const row = coefficients[index];
    return GammaRatios(row[0] * (65536.0f / 65025.0f), row[1] * (256.0f / 255.0f),
        row[2] * (65536.0f / 65025.0f), row[3] * (256.0f / 255.0f));
}

private float clamp(float value, float low, float high) @safe pure nothrow @nogc
{
    return value < low ? low : value > high ? high : value;
}

/// Separate intensity and contrast quantization preserves colored foregrounds.
/// Seventeen intensity levels include both #f0 and pure white exactly. Opacity
/// is excluded: correction applies to the straight foreground before blending.
ubyte nativeCoverageClass(Color foreground) @safe pure nothrow @nogc
{
    const intensity = (cast(uint) foreground.r + 2u * foreground.g + foreground.b + 2u) / 4u;
    const intensityClass = intensity >= 248u ? 16u : (intensity + 8u) / 16u;
    const brightness = (30.0f * foreground.r + 59.0f * foreground.g + 11.0f * foreground.b) / 25500.0f;
    const contrast = clamp(3.0f - 4.0f * brightness, 0.0f, 1.0f);
    const contrastClass = cast(uint) (contrast * (NativeContrastLevels - 1) + 0.5f);
    return cast(ubyte) (contrastClass * NativeIntensityLevels + intensityClass);
}

ubyte nativeTextCoverage(ubyte coverage, ubyte colorClass, float contrast,
    GammaRatios ratios, bool thinFont = false) @safe pure nothrow @nogc
{
    assert(colorClass < NativeCoverageClasses);
    if (!isFinite(contrast)) contrast = 0.5f;
    contrast = clamp(contrast, 0.0f, 0.95f);
    if (coverage == 0 || coverage == 255 || contrast <= 0) return coverage;
    const intensityClass = colorClass % NativeIntensityLevels;
    const intensity = (intensityClass == 16 ? 255.0f : intensityClass * 16.0f) / 255.0f;
    const multiplier = cast(float) (colorClass / NativeIntensityLevels) / (NativeContrastLevels - 1);
    // Preserve the existing contrast knob: 0 is linear, 0.5 corresponds to the
    // native grayscale enhanced-contrast value 1.0, and opacity remains separate.
    const k = contrast / (1.0f - contrast) * multiplier + (thinFont ? 0.5f : 0.0f);
    float a = coverage / 255.0f;
    a = a * (1.0f + k) / (1.0f + a * k);
    a += a * (1.0f - a) * ((ratios.x * intensity + ratios.y) * a +
        ratios.z * intensity + ratios.w);
    return cast(ubyte) (clamp(a, 0.0f, 1.0f) * 255.0f + 0.5f);
}

unittest
{
    const black = nativeCoverageClass(Color.rgb(0, 0, 0));
    const white = nativeCoverageClass(Color.rgb(255, 255, 255));
    const nearWhite = nativeCoverageClass(Color.rgb(240, 240, 240));
    assert(black == 119 && white == 16 && nearWhite == 15);
    assert(nativeCoverageClass(Color.rgba(30, 80, 200, 20)) ==
        nativeCoverageClass(Color.rgba(30, 80, 200, 255)));
    const gamma = gammaRatios(1.8f);
    assert(nativeTextCoverage(64, black, 0.5f, gamma) == 60);
    assert(nativeTextCoverage(64, nearWhite, 0.5f, gamma) == 106);
    assert(nativeTextCoverage(64, black, float.nan, gamma) == 60);
    assert(gammaRatios(float.nan) == gamma && gammaRatios(-1) == gammaRatios(1));
    foreach (level; 0 .. NativeCoverageClasses)
    foreach (thin; [false, true])
    foreach (g; [1.0f, 1.8f, 2.2f])
    foreach (contrast; [0.0f, 0.5f, 0.95f])
    {
        uint previous;
        foreach (value; 0 .. 256)
        {
            const alpha = nativeTextCoverage(cast(ubyte) value, cast(ubyte) level, contrast, gammaRatios(g), thin);
            assert(alpha >= previous, "Native alpha correction must remain monotone");
            if (contrast == 0) assert(alpha == value, "Explicit linear coverage remains linear");
            previous = alpha;
        }
        assert(previous == 255);
    }
}
