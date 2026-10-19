module experiment.aurorahost.image_widget;

import aurora : Canvas, Color, Rect, RgbaImage, Widget;

/** A retained image leaf that decodes once and draws from its RGBA buffer. */
class ImageWidget : Widget
{
    private RgbaImage _image;
    private bool _hasBackground;
    private Color _background;

    this(RgbaImage image, int width, int height, int flex,
        bool hasBackground, Color background)
    {
        _image = image;
        _hasBackground = hasBackground;
        _background = background;
        const preferredWidth = width > 0 ? width :
            (image is null ? 0 : image.width());
        const preferredHeight = height > 0 ? height :
            (image is null ? 0 : image.height());
        if (preferredWidth > 0)
            layoutHints().preferredWidth = preferredWidth;
        if (preferredHeight > 0)
            layoutHints().preferredHeight = preferredHeight;
        if (flex > 0)
            layoutHints().flex = flex;
    }

    override protected void onPaint(ref Canvas canvas)
    {
        const full = Rect(0, 0, bounds().width, bounds().height);
        if (_hasBackground)
            canvas.fillRect(full, _background);
        if (_image !is null)
            canvas.drawImage(full, _image);
    }
}
