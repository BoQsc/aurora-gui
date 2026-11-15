// SPDX-License-Identifier: 0BSD
module aurorawindowwidget.advanced.image;

import aurora.canvas : Canvas;
import aurora.image : RgbaImage;
import aurora.types : Rect, Size, minInt;
import aurora.widget : Widget;

/// Displays an RGBA image, stretched to its bounds by default.
class ImageView : Widget
{
    private RgbaImage _image;
    private bool _preserveAspect;

    this(RgbaImage image = null, bool preserveAspect = false)
    {
        _image = image;
        _preserveAspect = preserveAspect;
        layoutHints().minWidth = 16;
        layoutHints().minHeight = 16;
    }

    RgbaImage image() @safe pure nothrow @nogc { return _image; }
    bool preserveAspect() const @safe pure nothrow @nogc { return _preserveAspect; }

    void setImage(RgbaImage value)
    {
        if (_image is value) return;
        _image = value;
        invalidate();
    }

    void setPreserveAspect(bool value)
    {
        if (_preserveAspect == value) return;
        _preserveAspect = value;
        invalidate();
    }

    protected override Size onMeasure(Size available)
    {
        if (_image is null) return Size(0, 0);
        return Size(minInt(_image.width, available.width),
            minInt(_image.height, available.height));
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (_image is null) return;
        auto destination = Rect(0, 0, bounds().width, bounds().height);
        if (_preserveAspect && _image.width > 0 && _image.height > 0 &&
            destination.width > 0 && destination.height > 0)
        {
            const scaleX = cast(double) destination.width / _image.width;
            const scaleY = cast(double) destination.height / _image.height;
            const scale = scaleX < scaleY ? scaleX : scaleY;
            const width = cast(int) (_image.width * scale);
            const height = cast(int) (_image.height * scale);
            destination = Rect((destination.width - width) / 2,
                (destination.height - height) / 2, width, height);
        }
        canvas.drawImage(destination, _image);
    }
}