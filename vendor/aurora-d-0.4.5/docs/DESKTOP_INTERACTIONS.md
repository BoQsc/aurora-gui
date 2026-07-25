# Desktop shell interactions

Aurora-D 0.4.5 keeps desktop shortcuts, floating windows, taskbar buttons, and popup menus inside Aurora's retained scene. The host operating system supplies the top-level window and input stream; it does not create child windows or native popup menus for these shell elements.

## Desktop icons

`DesktopIcon` supports selection, double-click activation, keyboard activation, pointer capture, a drag threshold, synchronized late-latched dragging, drop-target feedback, and context actions.

```d
import aurora;

DesktopSurface desktop = new DesktopSurface();

auto documents = desktop.addIcon("Documents", IconKind.folder, delegate()
{
    openDocuments();
});

auto report = desktop.addIcon("Report.txt", IconKind.notepad, delegate()
{
    openReport();
});

report.onRenameRequested = delegate(DesktopIcon icon)
{
    beginRename(icon);
};
report.onDeleteRequested = delegate(DesktopIcon icon)
{
    desktop.removeIcon(icon);
};
report.onPropertiesRequested = delegate(DesktopIcon icon)
{
    showProperties(icon);
};
```

A normal drag updates only the icon's retained compositor transform. Aurora does not repaint the icon text or glyphs merely because its position changed. Entering or leaving a drop target invalidates only that target's highlight layer.

### Drop contract

`DesktopSurface.onIconDropped` receives both the dragged source and the destination icon:

```d
desktop.onIconDropped = delegate(DesktopIcon source, DesktopIcon target)
{
    if (target.iconKind() == IconKind.trash)
    {
        desktop.removeIcon(source);
        return true;
    }

    if (target.iconKind() == IconKind.folder)
    {
        moveShortcutIntoFolder(source, target);
        return true;
    }

    return false;
};
```

Returning `true` means the drop was consumed. If the callback did not remove the source, Aurora restores it to its pre-drag position. Returning `false` completes an ordinary positional move; when grid alignment is enabled, the icon snaps to the nearest unoccupied cell.

Desktop shortcuts occupy a dedicated wallpaper painter-order stratum. Shortcuts created at runtime remain below floating windows and menus, and a shortcut temporarily raised among its peers during dragging returns to its original icon order after the drop.

Useful desktop APIs include:

```d
desktop.setAlignToGrid(true);
desktop.alignIconsToGrid();
desktop.arrangeIcons();
desktop.clearSelection();
desktop.selectedIcon();
desktop.removeIcon(report);

desktop.onIconMoved = delegate(DesktopIcon icon)
{
    persistDesktopPosition(icon.text(), icon.bounds());
};
```

The wallpaper menu exposes Refresh, Arrange icons, Align icons to grid, New, Display settings, and Personalize. Applications provide the actions through `DesktopSurface` delegates.

Desktop keyboard behavior:

| Input | Result |
|---|---|
| Enter or Space | Activate the focused shortcut |
| F2 | Request rename |
| Delete | Request deletion |
| Shift+F10 | Open the shortcut or wallpaper context menu |
| F5 on the wallpaper | Refresh |

## Taskbar

`Taskbar` contains window entries and command entries. Window entries track visible, active, minimized, maximized, closed, and title-changed state through the corresponding `FloatingWindow` callbacks.

```d
auto taskbar = new Taskbar();
taskbar.addWindow(notepadWindow, "Notepad", IconKind.notepad);
taskbar.addWindow(filesWindow, "Files", IconKind.folder);
taskbar.addCommand("Settings", IconKind.settings, delegate()
{
    openSettings();
});

notepadWindow.onActivated = delegate(FloatingWindow window)
{
    taskbar.setActiveWindow(window);
};
notepadWindow.onTitleChanged = delegate(FloatingWindow window)
{
    taskbar.updateWindowTitle(window);
};
notepadWindow.onClosed = delegate(FloatingWindow window)
{
    taskbar.removeWindow(window);
};
```

Press a task button and move at least five logical pixels to begin reordering. Aurora creates a root-level retained drag proxy containing the task's icon, title, running indicator, and active state. The exact point originally grabbed remains under the latest logical pointer coordinate, including subpixel late-latched samples and vertical movement away from the taskbar.

The stable task model is not mutated during motion. The original task is hidden in the bar, the other entries are painted around an insertion gap, and only the target slot changes when the proxy crosses a midpoint. Mouse-up commits one move from the original index to the final insertion index and emits one persistence notification. Escape, host-focus loss, taskbar resize, entry removal, or a programmatic order mutation cancels the proxy without committing a partial order.

```d
taskbar.onEntryMoved = delegate(int from, int to)
{
    persistTaskOrder(from, to);
};

taskbar.onEntryOrderChanged = delegate(TaskEntryId[] stableOrder)
{
    persistStableTaskIds(stableOrder);
};

taskbar.moveEntry(3, 0);
assert(taskbar.entryTitle(0) == "Settings"d);
```

During an active drag, diagnostics make the pointer-lock contract testable:

```d
assert(taskbar.reordering());
assert(taskbar.dragAnchorGlobalPosition() == latestPointer);
assert(taskbar.dragTargetIndex() >= 0);
```

Because the proxy is independently composited, ordinary pointer samples change only its transform. On low-latency hosts, `GuiWindow` late-samples the pointer before command recording and updates both the proxy and synchronized Aurora cursor in the same scene submission. Crossing an insertion boundary repaints the small taskbar layer to move the gap, but it still does not rewrite the task order until release. Reordering works for both window and command entries.

A task button context menu contains the actions appropriate for that entry:

- Window entries: Restore, Minimize, Maximize or Restore down, Close, Move left, and Move right.
- Command entries: Open, Move left, Move right, and Remove from taskbar.
- Empty taskbar space: Show desktop or Restore windows, Full screen, and Taskbar settings.
- Start and clock regions: Start and date/time commands.

The taskbar also supports left/right keyboard traversal, Enter/Space activation, Shift+F10 context menus, mouse-wheel window switching, and a Show Desktop strip.

## Floating-window system menu

Right-clicking an Aurora floating title bar opens an Aurora-rendered system menu. It provides Restore, Minimize, Maximize or Restore down, and Close. The title bar, menu, caption buttons, and content remain Aurora widgets rather than native child windows.

## Reusable context menus

`ContextMenu` is part of the public widget API:

```d
showContextMenu(owner, event.globalPosition, [
    ContextMenuItem.command("Open", IconKind.open, &openSelection, "Enter"),
    ContextMenuItem.separatorItem(),
    ContextMenuItem.check("Align to grid", desktop.alignToGrid(), delegate()
    {
        desktop.setAlignToGrid(!desktop.alignToGrid());
    }),
    ContextMenuItem.command("Delete", IconKind.trash, &deleteSelection,
        "Del", canDelete)
]);
```

Menus are full-window Aurora overlay layers. They clamp to the client area, draw shadows and icons, support disabled and checked items, dismiss on an outside click or Escape, and provide Up/Down/Home/End/Enter/Space keyboard navigation. `LayoutHints.excludeFromLayout` keeps overlays out of `HBox` and `VBox` sizing while preserving explicit bounds and normal painter order.

## Scope

This release implements drag/drop among Aurora desktop icons and positional taskbar reordering. It does not yet expose native inter-process drag formats, shell file-operation integration, drag images crossing the host-window boundary, or operating-system clipboard data objects. Those are separate platform-integration layers and are not required for the in-Aurora desktop interaction path.
