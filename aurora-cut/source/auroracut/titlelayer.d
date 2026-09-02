module auroracut.titlelayer;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.font : FontFace, FontRole;
import aurora.surface : Surface;
import aurora.text.atlas : FontSystem;
import aurora.text.layout : TextLayout, TextLayoutOptions;
import aurora.text.titlepaint : TitlePaintStyle, paintTitleLayout,
    titlePaintMargin;
import aurora.types : Point, maxInt, minInt;
import auroracut.model : TextAlignment;
import auroracut.textfonts : canonicalTextFontName, textFontFilePath;
import std.math : ceil;
import std.utf : toUTF32;

/** One live, authored title layer shared by Preview and export rasterization. */
struct TitleVisual
{
    ulong clipId;
    string text = "Title";
    string fontName = "Sans";
    bool bold;
    bool italic;
    bool underline;
    TextAlignment textAlignment = TextAlignment.left;
    // The unanimated authored size used to create the export raster. Preview
    // uses it to scale strokes, shadows, and boxes by the same transform that
    // FFmpeg applies to that raster. A zero value falls back to textSize for
    // callers that provide an already-evaluated, static visual.
    double baseTextSize;
    double textSize = 96.0;
    uint textColor = 0xffffffff;
    bool box;
    uint boxColor = 0x80000000;
    double strokeWidth;
    uint strokeColor = 0xffffffff;
    double shadowOpacity;
    double shadowBlur = 12.0;
    double shadowOffsetX = 12.0;
    double shadowOffsetY = 12.0;
    uint shadowColor = 0xff000000;
    double opacity = 1.0;
    double scale = 1.0;
    double positionX;
    double positionY;
    double rotation;
    size_t trackIndex;
}

/** Scale applied to the authored export raster at this visual's current time. */
double titleRasterScale(const TitleVisual visual)
{
    const baseSize = visual.baseTextSize > 0.000_001 ?
        visual.baseTextSize : visual.textSize;
    const safeBase = baseSize > 0.000_001 ? baseSize : 96.0;
    const factor = visual.scale * visual.textSize / safeBase;
    return factor > 0.01 ? factor : 0.01;
}

struct TitleRaster
{
    string path;
    int width;
    int height;
    double baseTextSize;
}

Color argbColor(uint value)
{
    return Color.fromHex(value & 0x00ff_ffff).withAlpha(
        cast(ubyte) ((value >> 24) & 0xff));
}

Color multiplyAlpha(Color color, double amount)
{
    if (amount < 0.0) amount = 0.0;
    else if (amount > 1.0) amount = 1.0;
    return color.withAlpha(cast(int) (color.a * amount + 0.5));
}

FontFace loadTitleFace(const TitleVisual visual, FontFace fallback = null)
{
    const family = canonicalTextFontName(visual.fontName);
    const path = textFontFilePath(family, visual.bold, visual.italic);
    if (path.length > 0)
    {
        try
        {
            auto face = FontFace.load(path);
            if (face !is null) return face;
        }
        catch (Exception) {}
    }
    return fallback !is null ? fallback :
        FontSystem.sharedInstance().face(FontRole.ui);
}

TitlePaintStyle titlePaintStyle(const TitleVisual visual,
    double pixelFactor = 1.0)
{
    TitlePaintStyle style;
    style.foreground = argbColor(visual.textColor);
    style.layerOpacity = visual.opacity;
    style.strokeWidth = minInt(8, maxInt(0,
        cast(int) (visual.strokeWidth * pixelFactor + 0.5)));
    style.strokeColor = argbColor(visual.strokeColor);
    style.shadowOffsetX = cast(int) (visual.shadowOffsetX * pixelFactor +
        (visual.shadowOffsetX < 0.0 ? -0.5 : 0.5));
    style.shadowOffsetY = cast(int) (visual.shadowOffsetY * pixelFactor +
        (visual.shadowOffsetY < 0.0 ? -0.5 : 0.5));
    style.shadowBlur = minInt(8, maxInt(0,
        cast(int) (visual.shadowBlur * pixelFactor + 0.5)));
    style.shadowColor = multiplyAlpha(argbColor(visual.shadowColor),
        visual.shadowOpacity);
    style.underline = visual.underline;
    style.box = visual.box;
    style.boxColor = argbColor(visual.boxColor);
    return style;
}

void alignTitleLayout(TextLayout layout, TextAlignment alignment)
{
    if (layout is null || alignment == TextAlignment.left) return;
    foreach (lineIndex, ref line; layout.lines)
    {
        double offset;
        final switch (alignment)
        {
            case TextAlignment.left: continue;
            case TextAlignment.center:
                offset = (layout.width - line.width) * 0.5;
                break;
            case TextAlignment.right:
                offset = layout.width - line.width;
                break;
        }
        if (offset <= 0.000_001) continue;
        line.x += offset;
        foreach (ref run; layout.runs)
            if (run.lineIndex == lineIndex) run.x += offset;
        foreach (ref glyph; layout.glyphs)
            if (glyph.lineIndex == lineIndex) glyph.x += offset;
        foreach (ref cluster; layout.visualClusters)
            if (cluster.lineIndex == lineIndex)
            {
                cluster.xMin += offset;
                cluster.xMax += offset;
            }
        foreach (ref caret; layout.carets)
            if (caret.lineIndex == lineIndex) caret.x += offset;
    }
}

/** Rasterize title glyphs and effects through Aurora's own text engine. */
TitleRaster renderTitlePam(const TitleVisual visual, string path)
{
    // Export runs on a worker thread. Keep its layout cache and glyph atlas
    // independent from the UI thread while using the same shaping/paint code.
    auto fonts = new FontSystem();
    auto face = loadTitleFace(visual, fonts.face(FontRole.ui));
    TextLayoutOptions options;
    options.role = FontRole.ui;
    options.overrideFace = face;
    options.pixelSize = maxInt(8, cast(int) (visual.textSize + 0.5));
    auto layout = fonts.textEngine.layout(toUTF32(visual.text), options);
    alignTitleLayout(layout, visual.textAlignment);
    auto style = titlePaintStyle(visual, 1.0);
    // Export applies animated clip opacity/fades once to the completed RGBA
    // title raster. Keep this source layer fully visible while preserving each
    // component's authored alpha.
    style.layerOpacity = 1.0;

    const margin = titlePaintMargin(style);
    const width = maxInt(1, cast(int) ceil(layout.width) + margin * 2);
    const height = maxInt(1, cast(int) ceil(layout.height) + margin * 2);
    auto surface = new Surface(width, height);
    surface.clear(Color.rgba(0, 0, 0, 0));
    auto canvas = Canvas(surface, fonts);
    paintTitleLayout(canvas, layout, Point(margin, margin), style);
    surface.savePam(path);

    TitleRaster result;
    result.path = path;
    result.width = width;
    result.height = height;
    result.baseTextSize = visual.textSize > 0.000_001 ? visual.textSize : 96.0;
    return result;
}
