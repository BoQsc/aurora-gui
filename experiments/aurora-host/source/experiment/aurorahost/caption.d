module experiment.aurorahost.caption;

import aurora : Canvas, Event, GuiWindow, MouseButton;
import aurora.widgets.titlebar : FramelessWindowTitleBar, TitleBarControl;

/**
 * Mandatory caption behavior shared by every host title bar.
 *
 * A maximized caption only arms a drag; without pointer capture the first
 * downward move leaves the caption strip and the drag is dropped. Capturing
 * here makes double-click maximize and drag-down restore work for both
 * owner-painted and scene-defined title bars.
 */
class CaptionDragEnforcer : FramelessWindowTitleBar
{
    this(GuiWindow window)
    {
        super(window);
        setDoubleClickMaximizes(true);
        setSystemMoveOnDrag(true);
    }

    override bool onMouseDown(ref Event event)
    {
        const handled = super.onMouseDown(event);
        const control = controlAt(event.position);
        if (handled && event.button == MouseButton.left && maximized() &&
            (control == TitleBarControl.title || control == TitleBarControl.icon))
            captureMouse();
        return handled;
    }
}

/**
 * Standard title bar for scene `titleBar` nodes. It paints the normal vendor
 * caption and inherits the mandatory drag behavior.
 */
final class StandardCaptionBar : CaptionDragEnforcer
{
    this(GuiWindow window)
    {
        super(window);
    }
}

/**
 * Standard interaction layer for components that paint their own caption.
 * The component paints the visible title bar while this transparent layer
 * supplies double-click maximize and drag-down restore.
 */
final class CaptionInteractionLayer : CaptionDragEnforcer
{
    void delegate() onVisualChanged;

    this(GuiWindow window, int height = 32)
    {
        super(window);
        setBarHeight(height);
        setShowIcon(false);
    }

    override bool onMouseDown(ref Event event)
    {
        const beforeHot = hotControl();
        const beforePressed = pressedControl();
        const handled = super.onMouseDown(event);
        notify(beforeHot, beforePressed);
        return handled;
    }

    override bool onMouseMove(ref Event event)
    {
        const beforeHot = hotControl();
        const beforePressed = pressedControl();
        const handled = super.onMouseMove(event);
        notify(beforeHot, beforePressed);
        return handled;
    }

    override bool onMouseUp(ref Event event)
    {
        const beforeHot = hotControl();
        const beforePressed = pressedControl();
        const handled = super.onMouseUp(event);
        notify(beforeHot, beforePressed);
        return handled;
    }

    protected override void onMouseLeave()
    {
        const beforeHot = hotControl();
        const beforePressed = pressedControl();
        super.onMouseLeave();
        notify(beforeHot, beforePressed);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        // The owning component paints the visible caption.
    }

    private void notify(TitleBarControl beforeHot,
        TitleBarControl beforePressed)
    {
        if ((beforeHot != hotControl() || beforePressed != pressedControl()) &&
            onVisualChanged !is null)
            onVisualChanged();
    }
}