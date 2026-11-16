module aurora.text.coverage;

import aurora.color : Color;

/** Foreground-aware coverage. This is grayscale alpha correction,
 * not LCD filtering or a claim of native rasterizer parity. Sixteen luminance
 * classes bound color-dependent cache growth; opacity is applied afterwards.
 */
enum TextCoverageClasses = 16;

ubyte textCoverageClass(Color foreground) @safe pure nothrow @nogc
{
    // Integer Rec.709 luma in encoded RGB space, used only to select contrast.
    const luminance = (54u * foreground.r + 183u * foreground.g +
        19u * foreground.b + 128u) >> 8;
    // Round to sixteenths, saturating the near-white class. This preserves the
    // existing dark-theme transfer for #f0f0f0 as well as pure white.
    const level = (luminance + 8u) >> 4;
    return cast(ubyte) (level < TextCoverageClasses ? level : TextCoverageClasses - 1);
}

/** Existing odds-form coverage transfer, also used by the compatibility path. */
ubyte transferTextCoverage(ubyte coverage, float contrast)
    @safe pure nothrow @nogc
{
    const a = cast(float) coverage / 255.0f;
    const denominator = a + (1.0f - a) * (1.0f - contrast);
    const enhanced = denominator > 0.0f ? a / denominator : a;
    return cast(ubyte) (enhanced * 255.0f + 0.5f);
}
