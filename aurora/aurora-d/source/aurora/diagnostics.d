module aurora.diagnostics;

import aurora.types : Rect, maxInt;
import aurora.widget : Widget;
import std.format : format;

/** Structural layout problem detected in a retained widget tree. */
enum LayoutIssueKind : ubyte
{
    negativeSize,
    belowDeclaredMinimum,
    childOverflow,
    overlayCoverage,
    interactiveTargetTooSmall
}

struct LayoutIssue
{
    LayoutIssueKind kind;
    string widgetType;
    string widgetId;
    Rect bounds;
    Rect parentBounds;
    string message;
}

struct LayoutAuditOptions
{
    bool checkOverflow = true;
    bool checkMinimums = true;
    bool checkOverlayCoverage = true;
    bool checkInteractiveTargets = true;
    int minimumInteractiveWidth = 32;
    int minimumInteractiveHeight = 32;
}

/**
 * Inspect a laid-out tree for clipping and sizing errors. This is intended for
 * deterministic shell/UI tests and is deliberately independent of a renderer.
 */
LayoutIssue[] auditLayout(Widget root, LayoutAuditOptions options = LayoutAuditOptions.init)
{
    LayoutIssue[] issues;
    if (root is null) return issues;
    auditWidget(root, null, options, issues);
    return issues;
}

private void auditWidget(Widget widget, Widget parent,
    const ref LayoutAuditOptions options, ref LayoutIssue[] issues)
{
    if (widget is null || !widget.visible()) return;
    const rect = widget.bounds();
    const parentRect = parent is null ? Rect.init :
        Rect(0, 0, parent.bounds().width, parent.bounds().height);

    if (rect.width < 0 || rect.height < 0)
        appendIssue(issues, LayoutIssueKind.negativeSize, widget, parentRect,
            "negative widget dimensions");

    const hints = widget.layoutHints();
    if (options.checkMinimums &&
        (rect.width < hints.minWidth || rect.height < hints.minHeight))
        appendIssue(issues, LayoutIssueKind.belowDeclaredMinimum, widget, parentRect,
            format("%sx%s is below declared minimum %sx%s", rect.width, rect.height,
                hints.minWidth, hints.minHeight));

    if (parent !is null && options.checkOverflow && !hints.allowOverflow)
    {
        if (rect.x < 0 || rect.y < 0 || rect.right() > parentRect.width ||
            rect.bottom() > parentRect.height)
            appendIssue(issues, LayoutIssueKind.childOverflow, widget, parentRect,
                "visible child extends outside its parent viewport");
    }

    if (parent !is null && options.checkOverlayCoverage && hints.overlayFillParent &&
        rect != parentRect)
        appendIssue(issues, LayoutIssueKind.overlayCoverage, widget, parentRect,
            "parent-filling overlay does not cover the complete parent");

    if (options.checkInteractiveTargets && widget.focusable() && widget.enabled() &&
        (rect.width < options.minimumInteractiveWidth ||
            rect.height < options.minimumInteractiveHeight))
        appendIssue(issues, LayoutIssueKind.interactiveTargetTooSmall, widget, parentRect,
            format("interactive target %sx%s is below %sx%s", rect.width, rect.height,
                options.minimumInteractiveWidth, options.minimumInteractiveHeight));

    foreach (child; widget.children())
        auditWidget(child, widget, options, issues);
}

private void appendIssue(ref LayoutIssue[] issues, LayoutIssueKind kind,
    Widget widget, Rect parentBounds, string message)
{
    LayoutIssue issue;
    issue.kind = kind;
    issue.widgetType = typeid(widget).name;
    issue.widgetId = widget.id();
    issue.bounds = widget.bounds();
    issue.parentBounds = parentBounds;
    issue.message = message;
    issues ~= issue;
}

/** Throw an assertion with all layout failures formatted for CI logs. */
void assertLayoutClean(Widget root, LayoutAuditOptions options = LayoutAuditOptions.init)
{
    const issues = auditLayout(root, options);
    if (issues.length == 0) return;
    string message = format("layout audit found %s issue(s):", issues.length);
    foreach (issue; issues)
        message ~= format("\n- %s%s: %s; bounds=%s parent=%s",
            issue.widgetType, issue.widgetId.length == 0 ? "" : "#" ~ issue.widgetId,
            issue.message, issue.bounds, issue.parentBounds);
    assert(false, message);
}

unittest
{
    final class AuditRoot : Widget {}
    auto root = new AuditRoot();
    root.setBounds(Rect(0, 0, 100, 100));
    auto child = root.add(new AuditRoot());
    child.setBounds(Rect(90, 90, 20, 20));
    auto issues = auditLayout(root);
    assert(issues.length == 1);
    assert(issues[0].kind == LayoutIssueKind.childOverflow);
    child.layoutHints().allowOverflow = true;
    assert(auditLayout(root).length == 0);
}
