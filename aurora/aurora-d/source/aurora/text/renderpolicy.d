module aurora.text.renderpolicy;

import std.process : environment;

/// Shared renderer policy. Configure before creating fonts, atlases or windows.
enum TextRenderProfile
{
    refinedD,
    compatibleC,
    originalD
}

TextRenderProfile textRenderProfile(string value) @safe pure nothrow @nogc
{
    if (value == "compatible-c") return TextRenderProfile.compatibleC;
    if (value == "native-next") return TextRenderProfile.originalD;
    // Unset, empty and the explicit native-refined alias select the same default.
    return TextRenderProfile.refinedD;
}

string configuredHintingMode()
{
    return environment.get("AURORA_HINTING", "natural");
}

TextRenderProfile configuredTextRenderProfile()
{
    return textRenderProfile(environment.get("AURORA_TEXT_EXPERIMENT", "native-refined"));
}

bool nativeGlyphSampling()
{
    return configuredHintingMode() == "natural" &&
        configuredTextRenderProfile() != TextRenderProfile.compatibleC;
}

bool refinedTextRendering()
{
    return configuredHintingMode() == "natural" &&
        configuredTextRenderProfile() == TextRenderProfile.refinedD;
}

bool refinedTextCoverage()
{
    return refinedTextRendering() &&
        environment.get("AURORA_TEXT_COVERAGE", "foreground") == "foreground";
}

unittest
{
    assert(textRenderProfile("") == TextRenderProfile.refinedD);
    assert(textRenderProfile("native-refined") == TextRenderProfile.refinedD);
    assert(textRenderProfile("compatible-c") == TextRenderProfile.compatibleC);
    assert(textRenderProfile("native-next") == TextRenderProfile.originalD);
    assert(textRenderProfile("unknown") == TextRenderProfile.refinedD);
}
