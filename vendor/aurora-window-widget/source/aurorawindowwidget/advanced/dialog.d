// SPDX-License-Identifier: 0BSD
module aurorawindowwidget.advanced.dialog;

import aurora.layout : HBox, VBox;
import aurora.types : Insets;
import aurora.widget : Widget;
import aurora.widgets.button : Button;
import aurora.widgets.label : Label;

/// Titled dialog body with a content area and an action row.
class Dialog : VBox
{
    private Label _title;
    private VBox _body;
    private HBox _actions;

    this(string title = "")
    {
        super(0, Insets(16));
        _title = add(new Label(title));
        _title.setScale(3);
        _title.layoutHints().preferredHeight = 30;
        _body = add(new VBox(8, Insets(0)));
        _body.layoutHints().flex = 1.0;
        _actions = add(new HBox(8, Insets(0)));
        _actions.layoutHints().preferredHeight = 34;
        layoutHints().minWidth = 280;
        layoutHints().minHeight = 140;
    }

    /// Body container; callers add their content here.
    VBox body() @safe pure nothrow @nogc { return _body; }

    void setTitle(string value)
    {
        _title.setText(value);
    }

    void addContent(Widget widget)
    {
        if (widget is null) return;
        _body.add(widget);
    }

    /// Append a button to the action row and wire its click handler.
    Button addAction(string label, void delegate() action = null)
    {
        auto button = _actions.add(new Button(label));
        button.onClick = action;
        return button;
    }
}