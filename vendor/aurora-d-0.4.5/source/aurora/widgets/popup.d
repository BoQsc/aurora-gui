module aurora.widgets.popup;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, Key, MouseButton;
import aurora.types : Point, Rect, Size, clampInt, maxInt;
import aurora.widget : PopupSurface, Widget;

/** Placement of a transient Aurora-rendered popup relative to an anchor. */
enum PopupPlacement : ubyte
{
    automatic,
    above,
    below,
    centered
}

/**
 * Common lifecycle for transient, root-level UI such as context and Start
 * menus. A transient popup owns a full-window input layer, is automatically
 * resized with its root, and restores focus when it closes.
 */
abstract class TransientPopup : Widget, PopupSurface
{
    private bool _dismissed;
    private Widget _focusReturn;

    void delegate() onDismissed;

    protected this(Widget focusReturn = null)
    {
        _focusReturn = focusReturn;
        setComposited(true);
        setFocusable(true);
        layoutHints().excludeFromLayout = true;
        layoutHints().overlayFillParent = true;
        layoutHints().allowOverflow = true;
    }

    bool dismissed() const @safe pure nothrow @nogc
    {
        return _dismissed;
    }

    Widget focusReturn() @safe pure nothrow @nogc
    {
        return _focusReturn;
    }

    void setFocusReturn(Widget value)
    {
        _focusReturn = value;
    }

    /** Reset lifecycle state before reattaching a reusable popup instance. */
    protected void prepareToOpen(Widget focusReturn = null)
    {
        _dismissed = false;
        if (focusReturn !is null) _focusReturn = focusReturn;
    }

    protected override void onHostFocusChanged(bool focused)
    {
        if (!focused) dismiss();
    }

    void dismiss()
    {
        if (_dismissed) return;
        // Snapshot callbacks before detaching: removal may release the final
        // owner-held reference or mutate popup state from focus handlers.
        auto focusReturn = _focusReturn;
        auto dismissedCallback = onDismissed;
        auto owner = parent();
        _dismissed = true;
        if (owner !is null) owner.remove(this);
        if (focusReturn !is null && focusReturn.parent() !is null &&
            focusReturn.visible() && focusReturn.enabled())
            focusReturn.requestFocus();
        if (dismissedCallback !is null) dismissedCallback();
    }

    final override void dismissPopup()
    {
        dismiss();
    }

    override bool dismissPopupForPointer(Point globalPoint, MouseButton button)
    {
        dismiss();
        return false;
    }
}

/**
 * A reusable click-away popup surface containing an arbitrary widget tree.
 * The panel is measured, placed relative to an anchor, and clamped to the
 * current root bounds. It can therefore never silently extend past the client
 * viewport after a resize or on a short display.
 */
class PopupOverlay : TransientPopup
{
    private Widget _content;
    private Rect _anchorGlobal;
    private PopupPlacement _placement = PopupPlacement.automatic;
    private Size _requestedSize;
    private Rect _panelRect;
    private int _margin = 8;
    private int _gap = 6;
    private int _shadowOffset = 4;
    private bool _drawShadow = true;
    private Color _backdrop = Color.rgba(0, 0, 0, 0);
    private bool _consumeAnchorPress;

    this(Widget content, Widget focusReturn = null)
    {
        super(focusReturn);
        setContent(content);
    }

    Widget content() @safe pure nothrow @nogc { return _content; }
    Rect panelRect() const @safe pure nothrow @nogc { return _panelRect; }
    PopupPlacement placement() const @safe pure nothrow @nogc { return _placement; }

    void setContent(Widget value)
    {
        if (_content is value) return;
        if (_content !is null) remove(_content);
        _content = value;
        if (_content !is null)
        {
            _content.layoutHints().excludeFromLayout = true;
            add(_content);
        }
        recalculatePanelRect();
        invalidate();
    }

    void setAnchor(Rect globalAnchor, PopupPlacement placement = PopupPlacement.automatic)
    {
        _anchorGlobal = globalAnchor;
        _placement = placement;
        recalculatePanelRect();
        invalidate();
    }

    void setRequestedSize(Size value)
    {
        _requestedSize = value;
        recalculatePanelRect();
        invalidate();
    }

    void setMargin(int value)
    {
        _margin = maxInt(0, value);
        recalculatePanelRect();
    }

    void setGap(int value)
    {
        _gap = maxInt(0, value);
        recalculatePanelRect();
    }

    void setBackdrop(Color value)
    {
        _backdrop = value;
        invalidate();
    }

    void setDrawShadow(bool value)
    {
        _drawShadow = value;
        invalidate();
    }

    /** Keep an anchor toggle from closing and immediately reopening its popup. */
    void setConsumeAnchorPress(bool value)
    {
        _consumeAnchorPress = value;
    }

    override bool popupContains(Point globalPoint) const @safe pure nothrow @nogc
    {
        const origin = globalOrigin();
        return _panelRect.contains(Point(globalPoint.x - origin.x,
            globalPoint.y - origin.y));
    }

    override bool dismissPopupForPointer(Point globalPoint, MouseButton button)
    {
        const consume = _consumeAnchorPress && _anchorGlobal.contains(globalPoint);
        dismiss();
        return consume;
    }

    /** Focus the first focusable control contained by the panel. */
    void focusFirst()
    {
        if (_content is null)
        {
            requestFocus();
            return;
        }
        Widget[] focusable;
        _content.collectFocusable(focusable);
        if (focusable.length != 0) focusable[0].requestFocus();
        else requestFocus();
    }

    protected override void onBoundsChanged()
    {
        recalculatePanelRect();
    }

    protected override void onLayout()
    {
        recalculatePanelRect();
        if (_content !is null) _content.setBounds(_panelRect);
    }

    private void recalculatePanelRect()
    {
        if (_content is null || bounds().width <= 0 || bounds().height <= 0)
        {
            _panelRect = Rect.init;
            return;
        }

        const availableWidth = maxInt(1, bounds().width - _margin * 2);
        const availableHeight = maxInt(1, bounds().height - _margin * 2);
        auto measured = _content.measure(Size(availableWidth, availableHeight));
        int width = _requestedSize.width > 0 ? _requestedSize.width : measured.width;
        int height = _requestedSize.height > 0 ? _requestedSize.height : measured.height;
        width = clampInt(maxInt(1, width), 1, availableWidth);
        height = clampInt(maxInt(1, height), 1, availableHeight);

        const rootOrigin = globalOrigin();
        const anchor = Rect(_anchorGlobal.x - rootOrigin.x,
            _anchorGlobal.y - rootOrigin.y, _anchorGlobal.width, _anchorGlobal.height);
        int x = anchor.x;
        int y;
        final switch (_placement)
        {
            case PopupPlacement.above:
                y = anchor.y - height - _gap;
                break;
            case PopupPlacement.below:
                y = anchor.bottom() + _gap;
                break;
            case PopupPlacement.centered:
                x = (bounds().width - width) / 2;
                y = (bounds().height - height) / 2;
                break;
            case PopupPlacement.automatic:
                const below = bounds().height - _margin - (anchor.bottom() + _gap);
                const above = anchor.y - _gap - _margin;
                y = below >= height || below >= above ? anchor.bottom() + _gap :
                    anchor.y - height - _gap;
                break;
        }

        x = clampInt(x, _margin, maxInt(_margin, bounds().width - width - _margin));
        y = clampInt(y, _margin, maxInt(_margin, bounds().height - height - _margin));
        _panelRect = Rect(x, y, width, height);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (_backdrop.a != 0)
            canvas.fillRect(Rect(0, 0, bounds().width, bounds().height), _backdrop);
        if (_drawShadow && !_panelRect.empty())
            canvas.fillRoundedRect(_panelRect.translated(_shadowOffset, _shadowOffset), 9,
                theme().shadow.withAlpha(115));
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left && event.button != MouseButton.right)
            return true;
        if (!_panelRect.contains(event.position))
        {
            dismiss();
            return true;
        }
        // The event reached the overlay only because no child consumed it. Keep
        // panel-background clicks inside the popup instead of leaking to the UI
        // underneath.
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key == Key.escape)
        {
            dismiss();
            return true;
        }
        return false;
    }
}

/** Return the top-level root that owns a widget. */
Widget popupRoot(Widget owner)
{
    if (owner is null) return null;
    auto root = owner;
    while (root.parent() !is null) root = root.parent();
    return root;
}

/** Dismiss every root-level transient popup associated with an owner. */
void dismissTransientPopups(Widget owner)
{
    auto root = popupRoot(owner);
    if (root is null) return;
    TransientPopup[] stale;
    foreach (child; root.children())
    {
        auto popup = cast(TransientPopup) child;
        if (popup !is null) stale ~= popup;
    }
    foreach (popup; stale) popup.dismiss();
}

/** Find the current top-level transient popup, if any. */
TransientPopup currentTransientPopup(Widget owner)
{
    auto root = popupRoot(owner);
    if (root is null) return null;
    const children = root.children();
    for (size_t index = children.length; index > 0; --index)
    {
        auto popup = cast(TransientPopup) children[index - 1];
        if (popup !is null) return popup;
    }
    return null;
}

/** Show an arbitrary measured popup panel at a global logical anchor. */
PopupOverlay showPopup(Widget owner, Rect globalAnchor, Widget content,
    PopupPlacement placement = PopupPlacement.automatic,
    Size requestedSize = Size(0, 0))
{
    auto root = popupRoot(owner);
    if (root is null || content is null) return null;
    dismissTransientPopups(root);
    auto popup = new PopupOverlay(content, owner);
    root.add(popup);
    popup.setBounds(Rect(0, 0, root.bounds().width, root.bounds().height));
    root.bringChildToFront(popup);
    popup.setRequestedSize(requestedSize);
    popup.setAnchor(globalAnchor, placement);
    popup.layoutTree();
    popup.focusFirst();
    return popup;
}

unittest
{
    final class PopupTestRoot : Widget {}
    auto root = new PopupTestRoot();
    root.setBounds(Rect(0, 0, 640, 480));
    auto anchor = root.add(new WidgetTestPanel());
    anchor.setFocusable(true);
    anchor.setBounds(Rect(8, 430, 40, 40));
    auto content = new WidgetTestPanel();
    content.layoutHints().preferredWidth = 300;
    content.layoutHints().preferredHeight = 220;
    auto popup = showPopup(anchor, Rect(8, 430, 40, 40), content,
        PopupPlacement.above);
    assert(popup !is null);
    assert(popup.bounds() == Rect(0, 0, 640, 480));
    assert(popup.panelRect().bottom() <= 472);
    Event outside;
    outside.button = MouseButton.left;
    outside.position = Point(620, 20);
    assert(popup.onMouseDown(outside));
    assert(popup.dismissed());
}

private final class WidgetTestPanel : Widget
{
}
