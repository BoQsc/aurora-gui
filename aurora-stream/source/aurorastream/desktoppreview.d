module aurorastream.desktoppreview;

/**
 * Reusable GDI screen/window capture for the live source preview.
 *
 * The device-context, DIB-section, aspect-fit scaling and BGRX->RGBA plumbing
 * now live in the shared engine module `aurora.platform.gdi`; this class is the
 * stream-specific wrapper that maps the persisted window handle text to a
 * capture source and keeps a persistent capturer so no GDI objects are
 * recreated per frame.
 */

import aurora.image : RgbaImage;
import aurora.platform.gdi : ScreenCapture;

version (Windows)
{
    import core.sys.windows.windows : GetDesktopWindow;
    import aurorastream.windowsources : hwndFromText, hwndToText;

    final class DesktopPreviewCapturer
    {
        private ScreenCapture _capture;
        private int _width;
        private int _height;
        private string _windowTargetText;
        private bool _visibleScreenPixels;

        this(int width, int height)
        {
            _width = width;
            _height = height;
            _capture = new ScreenCapture(width, height);
            _capture.setAspectFit(true);
            _capture.capturePrimaryScreen();
        }

        /// Changes the captured output size. The DIB is recreated on the next
        /// capture so the preview can track its panel size for a sharp 1:1 view.
        void setTargetSize(int width, int height)
        {
            if (width <= 0 || height <= 0) return;
            if (width == _width && height == _height) return;
            _width = width;
            _height = height;
            _capture.setOutputSize(width, height);
        }

        /// Captures a single window (game/window capture) instead of the
        /// desktop. An empty or stale handle reverts to the primary monitor.
        /// `visibleScreenPixels` copies the window's on-screen pixels; when
        /// false the window's own device context is read, so the frame is
        /// correct even while the window is occluded.
        void setWindowTarget(string hwndText, bool visibleScreenPixels = false)
        {
            if (hwndText == _windowTargetText &&
                visibleScreenPixels == _visibleScreenPixels) return;
            _windowTargetText = hwndText.idup;
            _visibleScreenPixels = visibleScreenPixels;
            auto hwnd = hwndFromText(hwndText);
            if (hwnd is null)
                _capture.capturePrimaryScreen();
            else
                _capture.captureWindow(cast(void*) hwnd, true,
                    !visibleScreenPixels);
        }

        /// Copies the current frame (the selected window, or the primary
        /// monitor when no window is selected) scaled to the configured size
        /// into `rgba` as RGBA8 bytes. Returns false when the source cannot be
        /// captured or the buffer is too small.
        bool capture(ubyte[] rgba)
        {
            return _capture.capture(rgba);
        }
    }

    /// One-shot capture convenience used by tests; the live preview keeps a
    /// persistent `DesktopPreviewCapturer` instead so no GDI objects are
    /// recreated per frame.
    RgbaImage captureDesktopPreview(int targetWidth = 480, int targetHeight = 270)
    {
        if (targetWidth <= 0 || targetHeight <= 0) return null;
        auto capturer = new DesktopPreviewCapturer(targetWidth, targetHeight);
        auto rgba = new ubyte[cast(size_t) targetWidth * targetHeight * 4];
        if (!capturer.capture(rgba)) return null;
        return new RgbaImage(targetWidth, targetHeight, rgba);
    }

    unittest
    {
        // On an interactive desktop session a real capture must return the
        // requested image; headless/service sessions may fail and return null.
        auto frame = captureDesktopPreview(480, 270);
        if (frame !is null)
        {
            assert(frame.width() == 480);
            assert(frame.height() == 270);
        }

        // Exercise the visible-screen-region branch without opening or
        // activating any test window. The desktop HWND maps to the composed
        // screen rectangle; this is the same source path used for VLC.
        auto visible = new DesktopPreviewCapturer(64, 36);
        visible.setWindowTarget(hwndToText(cast(ulong) GetDesktopWindow()), true);
        auto rgba = new ubyte[64 * 36 * 4];
        assert(visible.capture(rgba));
    }
}
