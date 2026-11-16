module aurora.text.titlepaint;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.text.layout : TextLayout;
import aurora.types : Point, Rect, maxInt;
import std.algorithm.comparison : max;
import std.math : ceil, floor, pow;

/** Visual styling shared by editable preview titles and exported title rasters. */
struct TitlePaintStyle
{
    Color foreground;
    int strokeWidth;
    Color strokeColor;
    int shadowOffsetX;
    int shadowOffsetY;
    int shadowBlur;
    Color shadowColor;
    bool underline;
    bool box;
    Color boxColor;
    // Applied to the completed logical title layer. Component colors keep
    // their authored alpha; repeated stroke/shadow passes are normalized so
    // they cannot accumulate back toward opaque at low layer opacity.
    double layerOpacity = 1.0;
}

private double clampLayerOpacity(double value)
{
    if (value < 0.0) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
}

private Color layerColor(Color color, double opacity)
{
    const amount = clampLayerOpacity(opacity);
    return color.withAlpha(cast(int) (color.a * amount + 0.5));
}

/**
 * Return the alpha for one pass when several overlapping passes should
 * combine to the requested final layer alpha.
 *
 * Straight multiplication is wrong for a stroke made from many offset glyph
 * draws: ten 10%-opaque passes combine to roughly 65% opacity. This inverse
 * source-over calculation keeps the completed effect near the layer opacity.
 */
private Color distributedLayerColor(Color color, double opacity, int passes)
{
    passes = maxInt(1, passes);
    const target = cast(double) color.a / 255.0 * clampLayerOpacity(opacity);
    if (target <= 0.0) return color.withAlpha(0);
    if (target >= 1.0) return color.withAlpha(255);
    const perPass = 1.0 - pow(1.0 - target, 1.0 / passes);
    return color.withAlpha(cast(int) (perPass * 255.0 + 0.5));
}

int titlePaintMargin(const TitlePaintStyle style)
    @safe pure nothrow @nogc
{
    const shadowReachX = style.shadowOffsetX < 0 ?
        -style.shadowOffsetX : style.shadowOffsetX;
    const shadowReachY = style.shadowOffsetY < 0 ?
        -style.shadowOffsetY : style.shadowOffsetY;
    return maxInt(8, style.strokeWidth + style.shadowBlur +
        maxInt(shadowReachX, shadowReachY) + 8);
}

/** Paint title box, shadow, and stroke behind glyph selection/caret overlays. */
void paintTitleBackdrop(ref Canvas canvas, TextLayout layout, Point origin,
    const TitlePaintStyle style)
{
    if (layout is null) return;

    if (style.box && style.boxColor.a > 0)
    {
        const boxWidth = maxInt(1, cast(int) ceil(layout.width)) + 12;
        const boxHeight = maxInt(1, cast(int) ceil(layout.height)) + 8;
        canvas.fillRoundedRect(Rect(origin.x - 6, origin.y - 4,
            boxWidth, boxHeight), 4,
            layerColor(style.boxColor, style.layerOpacity));
    }

    if (style.shadowColor.a > 0 &&
        (style.shadowOffsetX != 0 || style.shadowOffsetY != 0 ||
         style.shadowBlur > 0))
    {
        if (style.shadowBlur <= 0)
            canvas.drawLayout(Point(origin.x + style.shadowOffsetX,
                origin.y + style.shadowOffsetY), layout,
                layerColor(style.shadowColor, style.layerOpacity));
        else
        {
            const radius = style.shadowBlur;
            int samples;
            foreach (dy; -radius .. radius + 1)
                foreach (dx; -radius .. radius + 1)
                    if (dx * dx + dy * dy <= radius * radius) ++samples;
            const blurred = distributedLayerColor(style.shadowColor,
                style.layerOpacity, maxInt(1, samples / 3));
            foreach (dy; -radius .. radius + 1)
                foreach (dx; -radius .. radius + 1)
                    if (dx * dx + dy * dy <= radius * radius)
                        canvas.drawLayout(Point(origin.x +
                            style.shadowOffsetX + dx, origin.y +
                            style.shadowOffsetY + dy), layout, blurred);
        }
    }

    if (style.strokeWidth > 0 && style.strokeColor.a > 0)
    {
        const radius = style.strokeWidth;
        int samples;
        foreach (dy; -radius .. radius + 1)
            foreach (dx; -radius .. radius + 1)
                if ((dx != 0 || dy != 0) &&
                    dx * dx + dy * dy <= radius * radius) ++samples;
        const stroke = distributedLayerColor(style.strokeColor,
            style.layerOpacity, maxInt(1, samples / 3));
        foreach (dy; -radius .. radius + 1)
            foreach (dx; -radius .. radius + 1)
                if ((dx != 0 || dy != 0) &&
                    dx * dx + dy * dy <= radius * radius)
                    canvas.drawLayout(Point(origin.x + dx,
                        origin.y + dy), layout, stroke);
    }

}

/** Paint foreground glyphs and underline over any selection background. */
void paintTitleForeground(ref Canvas canvas, TextLayout layout, Point origin,
    const TitlePaintStyle style)
{
    if (layout is null) return;
    const foreground = layerColor(style.foreground, style.layerOpacity);
    canvas.drawLayout(origin, layout, foreground);
    if (style.underline)
    {
        foreach (line; layout.lines)
        {
            const x = origin.x + cast(int) floor(line.x + 0.5);
            const y = origin.y + cast(int) floor(line.y +
                line.baseline + max(1.0, line.descent * 0.35));
            const width = maxInt(1, cast(int) ceil(line.width));
            canvas.fillRect(Rect(x, y, width,
                maxInt(1, layout.pixelSize / 14)), foreground);
        }
    }
}

/** Paint one complete shaped title layout. */
void paintTitleLayout(ref Canvas canvas, TextLayout layout, Point origin,
    const TitlePaintStyle style)
{
    paintTitleBackdrop(canvas, layout, origin, style);
    paintTitleForeground(canvas, layout, origin, style);
}


unittest
{
    const authored = Color.rgba(255, 255, 255, 255);
    assert(layerColor(authored, 0.5).a == 128);
    const pass = distributedLayerColor(authored, 0.25, 4);
    const passAlpha = cast(double) pass.a / 255.0;
    const combined = 1.0 - pow(1.0 - passAlpha, 4.0);
    assert(combined > 0.23 && combined < 0.27);
}
