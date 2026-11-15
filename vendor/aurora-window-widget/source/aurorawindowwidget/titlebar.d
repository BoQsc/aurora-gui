// SPDX-License-Identifier: 0BSD
module aurorawindowwidget.titlebar;

/// Standard captions: configurable bar, frameless shell, and snap preview.
public import aurora.widgets.titlebar : FramelessWindowTitleBar, TitleBar,
    TitleBarSnapPreview;

/// The frameless shell caption every Aurora application should use.
alias StandardTitleBar = FramelessWindowTitleBar;