module auroradesktop.tray;

import aurora;
import aurora.widgets.desktop : SystemTrayState, NotificationIcon;
import aurora.widgets.contextmenu : ContextMenuItem, showContextMenu;
import auroradesktop.system : AudioDevice;
import auroradesktop.wlan : WifiState;
import std.format : format;
import std.utf : toUTF8, toUTF32;

/**
 * Small floating panels opened from the taskbar tray icons (volume, WiFi,
 * battery, hidden notifications). They build reusable content trees and the
 * app wires them into a PopupOverlay anchored to the matching taskbar icon.
 */
final class VolumePanel : Widget
{
    private VBox _column;
    private VBox _deviceList;
    private Button[] _deviceButtons;
    private Slider _slider;
    private Label _percentLabel;
    private Button _muteButton;
    private bool _muted;

    void delegate(int percent) onVolumeSet;
    void delegate() onMuteToggle;
    void delegate(uint index) onDeviceSelected;

    this(int percent, bool muted, AudioDevice[] devices, uint selected)
    {
        _muted = muted;
        // Own composited layer: slider drags repaint just this panel instead
        // of the whole full-window popup overlay (measured 12.8 ms/event
        // before, mostly full-layer re-raster).
        setComposited(true);
        auto column = new VBox(10, Insets(14));
        _column = column;
        add(column);

        auto header = column.add(new HBox(8));
        header.layoutHints().preferredHeight = 30;
        auto title = header.add(new Label("Volume"));
        title.setScale(2);
        title.layoutHints().preferredWidth = 110;
        header.add(new Spacer());

        _slider = column.add(new Slider(0, 100, percent));
        _slider.layoutHints().preferredWidth = 270;
        _slider.layoutHints().preferredHeight = 30;
        _slider.onChanged = delegate(double value)
        {
            const rounded = cast(int) (value + 0.5);
            _percentLabel.setText(mutedLabel(rounded));
            if (onVolumeSet !is null) onVolumeSet(rounded);
        };

        auto footer = column.add(new HBox(8));
        footer.layoutHints().preferredHeight = 34;
        _muteButton = footer.add(new Button(muted ? "Unmute" : "Mute",
            muted ? IconKind.volumeMuted : IconKind.volume));
        _muteButton.onClick = delegate()
        {
            if (onMuteToggle !is null) onMuteToggle();
        };
        footer.add(new Spacer(1.0));
        _percentLabel = footer.add(new Label(mutedLabel(percent)));
        _percentLabel.setColor(theme().textMuted);

        // Output-device picker: one row per waveOut device, the active one
        // marked. The slider/mute above always drive the selected device.
        auto deviceTitle = column.add(new Label("Output device"));
        deviceTitle.setColor(theme().textMuted);
        _deviceList = column.add(new VBox(4));
        rebuildDevices(devices, selected);

        // Header + slider + footer + device title + rows + padding/spacing.
        // Wide enough for a full 40-char endpoint name plus icon chrome:
        // 440 px still clipped a ~370 px label, so 460 with real margin.
        layoutHints().preferredWidth = 460;
        layoutHints().preferredHeight = 152 + 10 + 24 +
            _deviceList.layoutHints().preferredHeight;
    }

    private void rebuildDevices(AudioDevice[] devices, uint selected)
    {
        foreach (child; _deviceList.children())
            _deviceList.remove(child);
        _deviceButtons.length = 0;
        foreach (device; devices)
        {
            const captured = device.index;
            const active = device.index == selected;
            auto row = _deviceList.add(new Button(
                (active ? "> " : "    ") ~ device.name, IconKind.volume));
            row.layoutHints().preferredHeight = 30;
            row.setAccent(active);
            row.onClick = delegate()
            {
                if (onDeviceSelected !is null) onDeviceSelected(captured);
            };
            _deviceButtons ~= row;
        }
        // The inner list is itself a VBox row of the outer column: without an
        // explicit height the column gives it 0 and every row clips away.
        const count = cast(int) _deviceButtons.length;
        _deviceList.layoutHints().preferredHeight =
            count == 0 ? 0 : count * 30 + (count - 1) * 4;
        _deviceList.layoutTree();
        invalidate();
    }

    protected override void onLayout()
    {
        if (_column !is null)
            _column.setBounds(Rect(0, 0, bounds().width, bounds().height));
    }

    private string mutedLabel(int percent) const
    {
        return _muted ? "Muted" : format("%d%%", percent);
    }

    void update(int percent, bool muted)
    {
        _muted = muted;
        _slider.setValue(percent, false);
        _percentLabel.setText(mutedLabel(percent));
        _muteButton.setText(muted ? "Unmute" : "Mute");
        _muteButton.setIcon(muted ? IconKind.volumeMuted : IconKind.volume);
    }

    void updateDevices(AudioDevice[] devices, uint selected)
    {
        rebuildDevices(devices, selected);
    }
}

final class WifiPanel : Widget
{
    private VBox _column;
    private VBox _networkList;
    private Label _statusLabel;
    private Label _signalLabel;
    private Button _disconnectButton;
    private WifiState _state;
    private string _feedback;
    private bool _scanning;

    void delegate() onOpenNetworkSettings;
    void delegate(string ssid, string profile, bool secured) onConnect;
    void delegate() onDisconnect;
    void delegate() onRefresh;

    this(WifiState state)
    {
        _state = state;
        auto column = new VBox(10, Insets(14));
        _column = column;
        add(column);
        rebuild();
    }

    void refresh(WifiState state, string feedback = "", bool scanning = false)
    {
        _state = state;
        _feedback = feedback;
        _scanning = scanning;
        rebuild();
    }

    private void rebuild()
    {
        foreach (child; _column.children())
            _column.remove(child);

        auto header = _column.add(new HBox(8));
        header.layoutHints().preferredHeight = 30;
        auto title = header.add(new Label("Wi-Fi"));
        title.setScale(2);
        title.layoutHints().preferredWidth = 110;
        header.add(new Spacer());
        _signalLabel = header.add(new Label(_state.connected ?
            format("%d%%", _state.signal) : "--"));
        _signalLabel.setColor(theme().textMuted);
        _signalLabel.setAlignment(HorizontalAlign.right, VerticalAlign.middle);
        _signalLabel.layoutHints().preferredWidth = 60;

        _statusLabel = _column.add(new Label(statusText()));
        _statusLabel.setColor(theme().textMuted);

        _networkList = _column.add(new VBox(4));
        size_t shown;
        foreach (network; _state.networks)
        {
            if (shown >= 12) break;
            const ssid = network.ssid;
            const profile = network.profile;
            const secured = network.secured;
            const active = _state.connected && ssid == _state.ssid;
            // Uniform rows; the connected one is marked with a leading check
            // instead of a full-width accent block (which made the panel look
            // inconsistent and oversized the icon).
            auto row = _networkList.add(new Button(
                (active ? "OK  " : "    ") ~ ssid ~ "  " ~
                format("%d%%", network.signal) ~
                (secured ? " (secured)" : ""),
                IconKind.wifi));
            row.layoutHints().preferredHeight = 30;
            row.setIconSize(18);
            row.onClick = delegate()
            {
                if (onConnect !is null) onConnect(ssid, profile, secured);
            };
            ++shown;
        }
        bool hasNote;
        if (_state.networks.length > shown)
        {
            auto more = _networkList.add(new Label(format("+ %d more...",
                _state.networks.length - shown)));
            more.setColor(theme().textMuted);
            hasNote = true;
        }
        if (!_state.available)
        {
            auto none = _networkList.add(new Label("No wireless adapter found."));
            none.setColor(theme().textMuted);
            hasNote = true;
        }
        else if (_state.networks.length == 0)
        {
            auto none = _networkList.add(new Label("No networks in range."));
            none.setColor(theme().textMuted);
            hasNote = true;
        }
        // Like the volume device list: the inner VBox needs an explicit
        // height or the outer column collapses it to 0 and rows clip away.
        const shownCount = cast(int) shown;
        _networkList.layoutHints().preferredHeight = shownCount == 0 && !hasNote ?
            0 : shownCount * 30 + (shownCount > 0 ? (shownCount - 1) * 4 : 0) +
            (hasNote ? (shownCount > 0 ? 4 : 0) + 24 : 0);

        auto footer = _column.add(new HBox(8));
        footer.layoutHints().preferredHeight = 34;
        auto refreshButton = footer.add(new Button(
            _scanning ? "Scanning..." : "Refresh", IconKind.refresh));
        refreshButton.layoutHints().preferredWidth = _scanning ? 118 : 96;
        refreshButton.setEnabled(!_scanning);
        refreshButton.onClick = delegate()
        {
            if (onRefresh !is null) onRefresh();
        };
        if (_state.connected)
        {
            _disconnectButton = footer.add(new Button("Disconnect",
                IconKind.close));
            _disconnectButton.onClick = delegate()
            {
                if (onDisconnect !is null) onDisconnect();
            };
        }
        else
            _disconnectButton = null;
        footer.add(new Spacer(1.0));

        auto settings = footer.add(new Button("", IconKind.settings));
        settings.layoutHints().preferredWidth = 38;
        settings.onClick = delegate()
        {
            if (onOpenNetworkSettings !is null) onOpenNetworkSettings();
        };

        // Header + status + rows + footer + padding/spacing. Wide enough
        // for a full "SSID 100% (secured)" row plus the footer gear button;
        // at 300 px both were clipped with ellipsis.
        layoutHints().preferredWidth = 360;
        layoutHints().preferredHeight = 30 + 10 + 24 + 10 +
            _networkList.layoutHints().preferredHeight + 10 + 34 + 28;
        _column.layoutTree();
        invalidate();
    }

    private string statusText() const
    {
        if (_feedback.length > 0) return _feedback;
        if (!_state.available) return "Wi-Fi unavailable";
        if (_state.connected)
            return "Connected to " ~ (_state.ssid.length > 0 ? _state.ssid :
                _state.profile);
        return "Not connected";
    }

    protected override void onLayout()
    {
        if (_column !is null)
            _column.setBounds(Rect(0, 0, bounds().width, bounds().height));
    }
}

final class BatteryPanel : Widget
{
    private VBox _column;

    this(bool hasBattery, bool charging, int percent)
    {
        auto column = new VBox(10, Insets(14));
        _column = column;
        add(column);

        auto title = column.add(new Label(charging ? "Charging" : "Battery"));
        title.setScale(2);
        title.setAlignment(HorizontalAlign.left, VerticalAlign.middle);

        auto detail = column.add(new Label(hasBattery ?
            format("%d%%", percent) : "No battery detected"));
        detail.setColor(theme().textMuted);

        layoutHints().preferredWidth = 240;
        layoutHints().preferredHeight = 80;
    }

    protected override void onLayout()
    {
        if (_column !is null)
            _column.setBounds(Rect(0, 0, bounds().width, bounds().height));
    }
}

final class HiddenIconsPanel : Widget
{
    private NotificationIcon[] _icons;
    private int _cell = 44;
    private int _gap = 8;
    private int _padding = 14;
    private int _maxColumns = 3;
    private int _hover = -1;
    private int _rows;
    // Drag-out-to-restore state: dragging a hidden icon out of the panel
    // unhides it in the visible tray.
    private int _dragCell = -1;
    private bool _dragMoved;
    private bool _dragOutside;
    private Point _pressLocal;

    /// Called when the user clicks a hidden icon (id, label).
    void delegate(size_t id, string label) onIconActivated;
    /// Called to hide/unhide an icon by id.
    void delegate(size_t id, bool hidden) onIconHidden;

    this(NotificationIcon[] icons)
    {
        _icons = icons.dup;
        setComposited(true);
        updateGridMetrics();
        layoutHints().preferredWidth = _maxColumns * (_cell + _gap) + _gap +
            _padding * 2;
        layoutHints().preferredHeight = _rows * (_cell + _gap) + _gap +
            _padding * 2;
    }

    private void updateGridMetrics()
    {
        const count = cast(int) _icons.length;
        _rows = (count + _maxColumns - 1) / _maxColumns;
        if (_rows == 0) _rows = 1;
    }

    private Rect cellRect(int index) const
    {
        const row = index / _maxColumns;
        const col = index % _maxColumns;
        return Rect(_padding + col * (_cell + _gap),
            _padding + row * (_cell + _gap), _cell, _cell);
    }

    private int cellAt(Point point) const
    {
        foreach (index; 0 .. cast(int) _icons.length)
            if (cellRect(index).contains(point)) return index;
        return -1;
    }

    NotificationIcon[] icons() @safe pure nothrow @nogc
    {
        return _icons;
    }

    void refresh(NotificationIcon[] icons)
    {
        _icons = icons.dup;
        updateGridMetrics();
        layoutHints().preferredHeight = _rows * (_cell + _gap) + _gap +
            _padding * 2;
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.drawRoundedRect(full, 9, palette.panelElevated,
            palette.border.withAlpha(230), 1);
        const rows = _rows;
        // Painted rows / day grid.
        foreach (index; 0 .. cast(int) _icons.length)
        {
            const cell = cellRect(index);
            if (index == _hover)
                canvas.fillRoundedRect(cell, 7, palette.buttonHover);
            if (index == _dragCell && _dragMoved)
                canvas.drawRoundedRect(cell.inset(1), 7, Color.rgba(0, 0, 0, 0),
                    palette.accent.withAlpha(210), 2);
            auto iconImage = _icons[cast(size_t) index].iconImage;
            if (iconImage !is null)
            {
                const iconRect = cell.inset(12);
                const side = minInt(iconRect.width, iconRect.height);
                canvas.drawImage(Rect(iconRect.x + (iconRect.width - side) / 2,
                    iconRect.y + (iconRect.height - side) / 2, side, side),
                    iconImage);
            }
            else
                drawIcon(canvas, _icons[cast(size_t) index].icon,
                    cell.inset(12), palette.text, palette.accent);
            canvas.drawTextInRect(Rect(cell.x, cell.bottom() - 16, cell.width, 14),
                toUTF32(shortLabel(_icons[cast(size_t) index].label)),
                palette.textMuted, 1, HorizontalAlign.center, VerticalAlign.bottom,
                true);
        }
        if (_icons.length == 0)
            canvas.drawTextInRect(full, "No hidden icons"d, palette.textMuted,
                1, HorizontalAlign.center, VerticalAlign.middle, true);
    }

    private static string shortLabel(dstring label)
    {
        const s = toUTF8(label);
        return s.length > 4 ? s[0 .. 4] : s;
    }

    override bool onMouseMove(ref Event event)
    {
        const cell = cellAt(event.position);
        if (cell != _hover)
        {
            _hover = cell;
            invalidate();
        }
        if (_dragCell >= 0)
        {
            if (!_dragMoved)
            {
                const dx = event.position.x - _pressLocal.x;
                const dy = event.position.y - _pressLocal.y;
                if (dx * dx + dy * dy >= 36) _dragMoved = true;
            }
            const inside = event.position.x >= 0 && event.position.y >= 0 &&
                event.position.x < bounds().width &&
                event.position.y < bounds().height;
            const outside = !inside;
            if (outside != _dragOutside)
            {
                _dragOutside = outside;
                invalidate();
            }
        }
        return true;
    }

    override bool onMouseDown(ref Event event)
    {
        const cell = cellAt(event.position);
        if (event.button == MouseButton.right)
        {
            if (cell >= 0)
            {
                const id = _icons[cast(size_t) cell].id;
                const label = toUTF8(_icons[cast(size_t) cell].label);
                ContextMenuItem[] items;
                items ~= ContextMenuItem.command("Show in tray",
                    IconKind.chevronUp, delegate()
                    {
                        if (onIconHidden !is null) onIconHidden(id, false);
                    });
                items ~= ContextMenuItem.command(label, IconKind.open,
                    delegate()
                    {
                        if (onIconActivated !is null) onIconActivated(id, label);
                    });
                showContextMenu(this, event.globalPosition, items);
            }
            return true;
        }
        if (event.button != MouseButton.left) return true;
        _dragCell = cell;
        _dragMoved = false;
        _dragOutside = false;
        _pressLocal = event.position;
        if (cell >= 0) captureMouse();
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (_dragCell < 0) return false;
        const cell = _dragCell;
        const moved = _dragMoved;
        const outside = _dragOutside;
        _dragCell = -1;
        _dragMoved = false;
        _dragOutside = false;
        releaseMouse();
        invalidate();
        if (cell < 0 || cell >= cast(int) _icons.length) return true;
        const id = _icons[cast(size_t) cell].id;
        const label = toUTF8(_icons[cast(size_t) cell].label);
        if (moved && outside)
        {
            // Dropped outside the panel: put it back in the visible tray.
            if (onIconHidden !is null) onIconHidden(id, false);
        }
        else if (!moved && onIconActivated !is null)
            onIconActivated(id, label);
        return true;
    }

    protected override void onLayout()
    {
        // Layout is static; the grid is sized by preferred dimensions.
    }
}

