// SPDX-License-Identifier: 0BSD
module aurorawindowwidget.advanced.panel;

import aurora.layout : VBox;
import aurora.types : Insets;

public import aurorawindowwidget.advanced.panel.combobox;
public import aurorawindowwidget.advanced.panel.dropdownlist;
public import aurorawindowwidget.advanced.panel.listbox;
public import aurorawindowwidget.advanced.panel.progressbar;
public import aurorawindowwidget.advanced.panel.scrollbar;
public import aurorawindowwidget.advanced.panel.scrollview;
public import aurorawindowwidget.advanced.panel.slider;

/// Themed vertical card: spacing, padding, background and border come from
/// the active theme.
class Panel : VBox
{
    this(int spacing = 8, Insets padding = Insets(12))
    {
        super(spacing, padding);
        const palette = theme();
        setBackground(palette.panelBackground);
        setBorder(palette.border, palette.cornerRadius);
        layoutHints().minWidth = 80;
        layoutHints().minHeight = 40;
    }
}