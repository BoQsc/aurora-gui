module opencodelite.plan_card;

import aurora : Point, Rect, Size, Widget;
import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.layout : VBox;
import aurora.types : Insets;
import aurora.widgets.button : Button;
import aurora.widgets.label : Label;
import aurora.widgets.popup : PopupOverlay, PopupPlacement, showPopup;
import aurorahost.component : ComponentContext, ComponentFactory;
import std.json : JSONValue;

final class PlanPanel : VBox
{
    this()
    {
        super(6, Insets(10));
    }

    protected override void onPaint(ref Canvas canvas)
    {
        canvas.fillRoundedRect(
            Rect(0, 0, bounds().width, bounds().height), 9,
            Color.rgba(20, 25, 34, 255));
        super.onPaint(canvas);
    }
}

final class PlanCardHost : Widget
{
    private ComponentContext _context;
    private bool _shown;

    this(ComponentContext context)
    {
        _context = context;
    }

    override void onTick(double)
    {
        if (_shown || bounds().width <= 0 || bounds().height <= 0)
            return;
        _shown = true;
        auto panel = new PlanPanel();
        panel.layoutHints().preferredWidth = 320;
        panel.layoutHints().preferredHeight = 196;
        auto title = panel.add(new Label("PLAN · Review workspace"));
        title.setScale(1);
        auto line1 = panel.add(new Label(
            "Inspect workspace; plan the next changes."));
        line1.setScale(1);
        auto line2 = panel.add(new Label("In progress · 1/4 steps"));
        line2.setScale(1);
        PopupOverlay popup;
        auto open = panel.add(new Button("Open details"));
        open.onClick = delegate()
        {
            _context.dispatchAction("plan-open");
            if (popup !is null) popup.dismiss();
        };
        auto start = panel.add(new Button("Start"));
        start.onClick = delegate()
        {
            _context.dispatchAction("plan-start");
            if (popup !is null) popup.dismiss();
        };
        popup = showPopup(this, Rect(0, 0, 1, 1), panel,
            PopupPlacement.below, Size(340, 220));
        if (popup !is null)
        {
            const width = _context.window.logicalClientSize().width;
            popup.setPanelPosition(Point(width > 380 ? width - 360 : 20, 72));
        }
    }
}

ComponentFactory planCardFactory()
{
    return delegate(ComponentContext context, JSONValue props)
    {
        return new PlanCardHost(context);
    };
}
