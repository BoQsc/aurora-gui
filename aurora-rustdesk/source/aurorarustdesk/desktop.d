module aurorarustdesk.desktop;

import aurora.platform.gdi : ScreenCapture;

/**
 * Whole-desktop frame capture for the viewer.
 *
 * The device-context, DIB-section and BGRX->RGBA plumbing now lives in the
 * shared engine module `aurora.platform.gdi`, so this class is only the
 * rustdesk-specific wrapper: it fixes the output size and asks for the virtual
 * desktop on every frame.
 */
final class DesktopCapturer
{
    private ScreenCapture _capture;

    this(int width, int height)
    {
        _capture = new ScreenCapture(width, height);
        _capture.captureVirtualScreen();
    }

    int width() const { return _capture.width(); }
    int height() const { return _capture.height(); }

    /// The virtual desktop as RGBA8 bytes, or null if it cannot be captured.
    ubyte[] capture() { return _capture.captureFrame(); }
}
