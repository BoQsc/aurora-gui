module aurorastream.programcanvas;

import aurora;
import std.algorithm.comparison : min;

/// Aspect-preserving letterbox rectangle for the live preview widget.
private Rect aspectTarget(Size logical, Rect outer)
{
    if (logical.width <= 0 || logical.height <= 0) return outer;
    const scale = min(cast(double) outer.width / logical.width,
        cast(double) outer.height / logical.height);
    const width = maxInt(1, cast(int) (logical.width * scale));
    const height = maxInt(1, cast(int) (logical.height * scale));
    return Rect(outer.x + (outer.width - width) / 2,
        outer.y + (outer.height - height) / 2, width, height);
}

/// Live view of the actual recorded source. In the normal desktop-capture mode
/// it shows the newest frame from the background capture thread, letterboxed to
/// the selected source-canvas aspect ratio, so it always matches what the
/// broadcaster will encode.
final class LiveSourceCanvasPreview : Widget
{
    private RgbaImage _frame;
    private Size _logicalSize = Size(1920, 1080);

    void setLogicalSize(Size logicalSize)
    {
        if (logicalSize.width > 0 && logicalSize.height > 0)
            _logicalSize = logicalSize;
        invalidate();
    }

    /// Shows a live capture frame of the actual recorded source (desktop
    /// capture).
    void setLiveFrame(RgbaImage frame)
    {
        _frame = frame;
        invalidate();
    }

    void clearLiveFrame()
    {
        _frame = null;
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.fillRect(full, Color.rgb(4, 5, 7));
        if (_frame is null) return;
        const target = aspectTarget(_logicalSize, full);
        canvas.drawImage(target, _frame, _frame.bounds(),
            Color(255, 255, 255, 255), true);
    }
}
