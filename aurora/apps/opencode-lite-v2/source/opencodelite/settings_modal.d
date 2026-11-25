module opencodelite.settings_modal;

import aurora : Point, Rect, Size, Widget;
import aurora.layout : VBox;
import aurora.types : Insets;
import aurora.widgets.button : Button;
import aurora.widgets.label : Label;
import aurora.widgets.popup : PopupOverlay, PopupPlacement, showPopup;
import aurorahost.component : ComponentContext, ComponentFactory;
import std.json : JSONValue;

ComponentFactory settingsButtonFactory()
{
    return delegate(ComponentContext context, JSONValue props)
    {
        auto button = new Button("Settings");
        button.onClick = delegate()
        {
            auto panel = new VBox(8, Insets(14));
            panel.layoutHints().preferredWidth = 360;
            panel.layoutHints().preferredHeight = 420;
            auto title = panel.add(new Label("Settings"));
            title.setScale(2);
            auto hint = panel.add(new Label(
                "Connection profiles and diagnostics"));
            hint.setScale(1);

            PopupOverlay popup;
            void addAction(string label, string action)
            {
                auto item = panel.add(new Button(label));
                item.onClick = delegate()
                {
                    context.dispatchAction(action);
                    if (popup !is null)
                        popup.dismiss();
                };
            }
            addAction("Use OpenCode profile", "preset-opencode");
            addAction("Use OpenAI profile", "preset-openai");
            addAction("Text fit audit", "audit-text");
            addAction("Credential audit", "audit-credentials");
            addAction("Reset connection", "reset-connection");
            auto close = panel.add(new Button("Close"));
            close.onClick = delegate()
            {
                if (popup !is null)
                    popup.dismiss();
            };

            const windowWidth = context.window.logicalClientSize().width;
            const anchorX = windowWidth > 380 ? windowWidth - 360 : 20;
            const anchor = Rect(anchorX, 160, 1, 1);
            popup = showPopup(button, anchor, panel,
                PopupPlacement.below, Size(380, 440));
            if (popup !is null)
                popup.setPanelPosition(Point(120, 160));
        };
        return button;
    };
}
