module aurora.widget;

import aurora.canvas : Canvas;
import aurora.event : Event, MouseButton;
import aurora.theme : Theme;
import aurora.text.atlas : FontSystem;
import aurora.types : CursorKind, Point, PointF, Rect, Size, maxInt, minInt;
import std.algorithm.searching : countUntil;

struct LayoutHints
{
    int minWidth = 0;
    int minHeight = 0;
    int preferredWidth = -1;
    int preferredHeight = -1;
    double flex = 0.0;
    bool fillCrossAxis = true;
    // Overlays such as context menus keep explicit bounds and are painted in
    // z-order without participating in a parent flex layout.
    bool excludeFromLayout = false;
    // A root-level overlay can request automatic parent-sized bounds. This is
    // used by transient popups so resize handling cannot leave stale hit-test
    // coverage or clipped panels.
    bool overlayFillParent = false;
    // Diagnostics normally require children to remain inside their parent.
    // Scrolling and intentionally overflowing compositor layers opt out.
    bool allowOverflow = false;
}

interface WidgetHost
{
    const(Theme) currentTheme() const;
    FontSystem fontSystem();
    void invalidate();
    void invalidateWidget(Widget widget);
    void invalidateTransform(Widget widget);
    void invalidateComposition();
    void requestFocus(Widget widget);
    void captureMouse(Widget widget);
    void releaseMouse(Widget widget);
    void updateCursor(CursorKind cursor);
    void bringToFront(Widget widget);
    void closeHostWindow();
    /** Forget focus/capture/hover references before a subtree is detached. */
    void detachSubtree(Widget widget);
}

/**
 * A transient Aurora-rendered popup that participates in global dismissal.
 *
 * Popup surfaces are discovered in painter order by GuiWindow before normal
 * pointer dispatch.  An outside press can therefore close the popup and then
 * continue to the widget behind it in the same input event.  This is the
 * behavior expected from start menus, context menus, combo boxes, and other
 * desktop overlays.
 */
interface PopupSurface
{
    /** True when the host-global point belongs to the popup's interactive area. */
    bool popupContains(Point globalPoint) const @safe pure nothrow @nogc;

    /**
     * Dismiss for an outside pointer press.  Return true to consume that press;
     * return false to let GuiWindow re-hit-test and dispatch it underneath.
     */
    bool dismissPopupForPointer(Point globalPoint, MouseButton button);

    /** Dismiss without a pointer event, for example from Escape. */
    void dismissPopup();
}

/** Base class for all retained-mode Aurora controls. */
abstract class Widget
{
    private Widget _parent;
    private Widget[] _children;
    private WidgetHost _host;
    private Rect _bounds;
    private PointF _precisePosition;
    private bool _hasPrecisePosition;
    private LayoutHints _layoutHints;
    private bool _visible = true;
    private bool _enabled = true;
    private bool _focusable;
    private bool _focused;
    private bool _hovered;
    private bool _composited;
    private bool _compositedOpaque;
    private CursorKind _cursor = CursorKind.arrow;
    private string _id;

    Widget parent() @safe pure nothrow @nogc { return _parent; }
    WidgetHost host() @safe pure nothrow @nogc { return _host; }
    Widget[] children() @safe pure nothrow @nogc { return _children; }
    const(Widget)[] children() const @safe pure nothrow @nogc { return _children; }
    Rect bounds() const @safe pure nothrow @nogc { return _bounds; }
    PointF precisePosition() const @safe pure nothrow @nogc
    {
        return _hasPrecisePosition ? _precisePosition : PointF(_bounds.x, _bounds.y);
    }
    Size size() const @safe pure nothrow @nogc { return Size(_bounds.width, _bounds.height); }
    bool visible() const @safe pure nothrow @nogc { return _visible; }
    bool enabled() const @safe pure nothrow @nogc { return _enabled; }
    bool focusable() const @safe pure nothrow @nogc { return _focusable; }
    bool focused() const @safe pure nothrow @nogc { return _focused; }
    bool hovered() const @safe pure nothrow @nogc { return _hovered; }
    bool composited() const @safe pure nothrow @nogc { return _composited; }
    bool compositedOpaque() const @safe pure nothrow @nogc { return _compositedOpaque; }
    CursorKind cursor() const @safe pure nothrow @nogc { return _cursor; }
    string id() const @safe pure nothrow @nogc { return _id; }

    ref LayoutHints layoutHints() @safe pure nothrow @nogc
    {
        return _layoutHints;
    }

    /**
     * Return the widget's preferred logical size constrained by `available`.
     * Layout containers use this instead of guessing from child counts. The
     * default implementation honours LayoutHints; containers override
     * onMeasure() to include their visible descendants.
     */
    Size measure(Size available = Size(int.max, int.max))
    {
        available.width = maxInt(0, available.width);
        available.height = maxInt(0, available.height);
        auto intrinsic = onMeasure(available);
        int width = _layoutHints.preferredWidth >= 0 ?
            _layoutHints.preferredWidth : intrinsic.width;
        int height = _layoutHints.preferredHeight >= 0 ?
            _layoutHints.preferredHeight : intrinsic.height;
        width = maxInt(_layoutHints.minWidth, width);
        height = maxInt(_layoutHints.minHeight, height);
        width = minInt(maxInt(0, width), available.width);
        height = minInt(maxInt(0, height), available.height);
        return Size(width, height);
    }

    void setId(string value)
    {
        _id = value;
    }

    void setBounds(Rect value)
    {
        if (_bounds == value) return;
        const transformOnly = _composited &&
            _bounds.width == value.width && _bounds.height == value.height;
        const positionChanged = _bounds.x != value.x || _bounds.y != value.y;
        _bounds = value;
        if (positionChanged)
        {
            _precisePosition = PointF(value.x, value.y);
            _hasPrecisePosition = false;
        }
        onBoundsChanged();
        if (transformOnly && _host !is null)
            _host.invalidateTransform(this);
        else
            invalidate();
    }

    /** Move a retained compositor layer without invalidating its content. */
    void setPosition(Point value)
    {
        setBounds(Rect(value.x, value.y, _bounds.width, _bounds.height));
    }

    /**
     * Move a retained layer at subpixel logical precision. This preserves every
     * physical pointer pixel at fractional DPI scales instead of quantizing the
     * drag through integer 96-DPI coordinates.
     */
    bool setPrecisePosition(PointF value, bool requestFrame = true)
    {
        if (!_composited)
        {
            const rounded = value.rounded();
            const changed = rounded.x != _bounds.x || rounded.y != _bounds.y;
            if (changed) setPosition(rounded);
            return changed;
        }
        if (_hasPrecisePosition && _precisePosition == value) return false;
        const rounded = value.rounded();
        _precisePosition = value;
        _hasPrecisePosition = true;
        _bounds.x = rounded.x;
        _bounds.y = rounded.y;
        onBoundsChanged();
        if (requestFrame && _host !is null)
            _host.invalidateTransform(this);
        return true;
    }

    /** Promote this widget subtree to an independently retained compositor layer. */
    void setComposited(bool value)
    {
        if (_composited == value) return;
        _composited = value;
        // Moving a subtree into or out of the base draw list changes scene
        // structure, so both base and layer caches must be reconsidered.
        if (_host !is null)
        {
            _host.invalidate();
            _host.invalidateComposition();
        }
    }

    /**
     * Declare that a composited widget paints every pixel of its layer opaque.
     * Software composition can then skip transparent clears and alpha blending.
     */
    void setCompositedOpaque(bool value)
    {
        if (_compositedOpaque == value) return;
        _compositedOpaque = value;
        if (_host !is null)
            _host.invalidateComposition();
    }

    void setVisible(bool value)
    {
        if (_visible == value) return;
        if (!value && _focused && _host !is null)
            _host.requestFocus(null);
        _visible = value;
        if (_composited && _host !is null)
            _host.invalidateComposition();
        else
            invalidate();
    }

    void setEnabled(bool value)
    {
        if (_enabled == value) return;
        if (!value && _focused && _host !is null)
            _host.requestFocus(null);
        _enabled = value;
        invalidate();
    }

    void setFocusable(bool value)
    {
        if (_focusable == value) return;
        if (!value && _focused && _host !is null)
            _host.requestFocus(null);
        _focusable = value;
    }

    void setCursor(CursorKind value)
    {
        _cursor = value;
        if (_hovered && _host !is null)
            _host.updateCursor(value);
    }

    T add(T)(T child) if (is(T : Widget))
    {
        if (child is null) return child;
        Widget baseChild = child;
        if (baseChild._parent !is null)
            baseChild._parent.remove(baseChild);
        baseChild._parent = this;
        _children ~= baseChild;
        baseChild.attachHost(_host);
        if (baseChild._composited && _host !is null)
            _host.invalidateComposition();
        else
            invalidate();
        return child;
    }

    bool remove(Widget child)
    {
        foreach (index, current; _children)
        {
            if (current is child)
            {
                if (current._host !is null)
                    current._host.detachSubtree(current);
                current.attachHost(null);
                current._parent = null;
                _children = _children[0 .. index] ~ _children[index + 1 .. $];
                if (child._composited && _host !is null)
                    _host.invalidateComposition();
                else
                    invalidate();
                return true;
            }
        }
        return false;
    }

    void clearChildren()
    {
        foreach (child; _children)
        {
            if (child._host !is null)
                child._host.detachSubtree(child);
            child.attachHost(null);
            child._parent = null;
        }
        _children.length = 0;
        invalidate();
        if (_host !is null)
            _host.invalidateComposition();
    }

    size_t childIndex(Widget child) const @safe pure nothrow @nogc
    {
        foreach (index, current; _children)
            if (current is child) return index;
        return size_t.max;
    }

    /** Move an existing child to a painter-order index without detaching it. */
    bool moveChildToIndex(Widget child, size_t requestedIndex)
    {
        const found = childIndex(child);
        if (found == size_t.max || _children.length == 0) return false;
        const target = requestedIndex < _children.length ? requestedIndex :
            _children.length - 1;
        if (found == target) return true;

        auto value = _children[found];
        if (found < target)
        {
            for (size_t index = found; index < target; ++index)
                _children[index] = _children[index + 1];
        }
        else
        {
            for (size_t index = found; index > target; --index)
                _children[index] = _children[index - 1];
        }
        _children[target] = value;
        if (child._composited && _host !is null)
            _host.invalidateComposition();
        else
            invalidate();
        return true;
    }

    void bringChildToFront(Widget child)
    {
        if (_children.length != 0)
            moveChildToIndex(child, _children.length - 1);
    }

    void attachHost(WidgetHost value)
    {
        _host = value;
        foreach (child; _children)
            child.attachHost(value);
    }

    const(Theme) theme() const
    {
        return _host is null ? Theme.light() : _host.currentTheme();
    }

    /** Window-local fonts and layout cache, with a detached-widget fallback. */
    protected FontSystem fontSystem()
    {
        return _host is null ? FontSystem.sharedInstance() : _host.fontSystem();
    }

    void invalidate()
    {
        if (_host !is null)
            _host.invalidateWidget(this);
    }

    void requestFocus()
    {
        if (_focusable && _enabled && _visible && _host !is null)
            _host.requestFocus(this);
    }

    void captureMouse()
    {
        if (_host !is null)
            _host.captureMouse(this);
    }

    void releaseMouse()
    {
        if (_host !is null)
            _host.releaseMouse(this);
    }

    void bringToFront()
    {
        if (_host !is null)
            _host.bringToFront(this);
    }

    void closeHostWindow()
    {
        if (_host !is null)
            _host.closeHostWindow();
    }

    PointF preciseGlobalOrigin() const @safe pure nothrow @nogc
    {
        const local = precisePosition();
        if (_parent is null) return local;
        return _parent.preciseGlobalOrigin() + local;
    }

    Point globalOrigin() const @safe pure nothrow @nogc
    {
        return preciseGlobalOrigin().rounded();
    }

    Point globalToLocal(Point point) const @safe pure nothrow @nogc
    {
        const origin = globalOrigin();
        return Point(point.x - origin.x, point.y - origin.y);
    }

    Point localToGlobal(Point point) const @safe pure nothrow @nogc
    {
        const origin = globalOrigin();
        return Point(point.x + origin.x, point.y + origin.y);
    }

    /** True when this widget is the same object as, or an ancestor of, value. */
    bool containsWidget(Widget value) const @safe pure nothrow @nogc
    {
        auto current = value;
        while (current !is null)
        {
            if (current is this) return true;
            current = current._parent;
        }
        return false;
    }


    /** Nearest independently retained layer containing this widget. */
    Widget compositorRoot() @safe pure nothrow @nogc
    {
        Widget current = this;
        while (current !is null)
        {
            if (current._composited) return current;
            current = current._parent;
        }
        return null;
    }

    bool containsLocal(Point point) const @safe pure nothrow @nogc
    {
        return point.x >= 0 && point.y >= 0 &&
               point.x < _bounds.width && point.y < _bounds.height;
    }

    Widget hitTest(Point globalPoint)
    {
        if (!_visible || !_enabled) return null;
        const local = globalToLocal(globalPoint);
        if (!containsLocal(local)) return null;

        for (size_t i = _children.length; i > 0; --i)
        {
            auto child = _children[i - 1];
            auto hit = child.hitTest(globalPoint);
            if (hit !is null) return hit;
        }
        return this;
    }

    /** Topmost visible popup in this subtree, following normal painter order. */
    PopupSurface topmostPopupSurface()
    {
        if (!_visible || !_enabled) return null;
        for (size_t index = _children.length; index > 0; --index)
        {
            auto popup = _children[index - 1].topmostPopupSurface();
            if (popup !is null) return popup;
        }
        return cast(PopupSurface) this;
    }

    void layoutTree()
    {
        if (!_visible) return;
        onLayout();
        foreach (child; _children)
        {
            if (child.visible() && child.layoutHints().overlayFillParent)
                child.setBounds(Rect(0, 0, _bounds.width, _bounds.height));
            child.layoutTree();
        }
    }

    void paintTree(Canvas parentCanvas)
    {
        paintTreeInternal(parentCanvas, false);
    }

    /** Paint the non-composited base tree while leaving retained layers out. */
    void paintTreeSkippingComposited(Canvas parentCanvas)
    {
        paintTreeInternal(parentCanvas, true);
    }

    private void paintTreeInternal(Canvas parentCanvas, bool skipComposited)
    {
        if (!_visible || _bounds.width <= 0 || _bounds.height <= 0) return;
        if (skipComposited && _composited) return;
        auto canvas = parentCanvas.translated(_bounds.x, _bounds.y)
                                  .clipped(Rect(0, 0, _bounds.width, _bounds.height));
        onPaint(canvas);
        foreach (child; _children)
            child.paintTreeInternal(canvas, skipComposited);
    }

    /** Collect visible retained layers in normal painter order. */
    void collectComposited(ref Widget[] output)
    {
        // Retain a hidden compositor root so minimize/restore can reuse its
        // already-built CPU/GPU content. A hidden ordinary ancestor still
        // suppresses its complete subtree.
        if (_composited)
        {
            output ~= this;
            return;
        }
        if (!_visible) return;
        foreach (child; _children)
            child.collectComposited(output);
    }

    void tickTree(double deltaSeconds)
    {
        if (!_visible) return;
        onTick(deltaSeconds);
        foreach (child; _children)
            child.tickTree(deltaSeconds);
    }

    void collectFocusable(ref Widget[] output)
    {
        if (!_visible || !_enabled) return;
        if (_focusable) output ~= this;
        foreach (child; _children)
            child.collectFocusable(output);
    }

    void setFocusedInternal(bool value)
    {
        if (_focused == value) return;
        _focused = value;
        onFocusChanged(value);
        invalidate();
    }

    void setHoveredInternal(bool value)
    {
        if (_hovered == value) return;
        _hovered = value;
        if (value)
            onMouseEnter();
        else
            onMouseLeave();
        invalidate();
    }

    /** Propagate native host activation without assuming the tree is immutable. */
    void notifyHostFocusChanged(bool focused)
    {
        auto snapshot = _children.dup;
        onHostFocusChanged(focused);
        foreach (child; snapshot)
        {
            if (child._parent is this)
                child.notifyHostFocusChanged(focused);
        }
    }

    protected Size onMeasure(Size available)
    {
        return Size(0, 0);
    }
    protected void onBoundsChanged() {}
    protected void onLayout() {}
    protected void onPaint(ref Canvas canvas) {}
    protected void onTick(double deltaSeconds) {}
    protected void onHostFocusChanged(bool focused) {}
    protected void onFocusChanged(bool focused) {}
    protected void onMouseEnter() {}
    protected void onMouseLeave() {}

    /** Last-moment native pointer sample, invoked only for the captured widget. */
    bool onPointerLatch(PointF globalPosition) { return false; }
    /** Request continuously late-latched frames while this widget owns capture. */
    bool wantsContinuousPointerFrames() const @safe pure nothrow @nogc { return false; }

    bool onMouseMove(ref Event event) { return false; }
    bool onMouseDown(ref Event event) { return false; }
    bool onMouseUp(ref Event event) { return false; }
    bool onMouseWheel(ref Event event) { return false; }
    /** Receives native file drops routed to this widget and then bubbled to ancestors. */
    bool onFilesDropped(ref Event event) { return false; }
    bool onKeyDown(ref Event event) { return false; }
    bool onKeyUp(ref Event event) { return false; }
    bool onTextInput(ref Event event) { return false; }
}
