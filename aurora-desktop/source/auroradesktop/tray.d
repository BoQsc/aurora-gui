module auroradesktop.tray;

import aurora;
import aurora.widgets.desktop : SystemTrayState, NotificationIcon;
import aurora.widgets.contextmenu : ContextMenuItem, showContextMenu;
import auroradesktop.inputlang : InputLanguage;
import auroradesktop.system : AudioDevice;
import auroradesktop.wlan : WifiState;
import std.format : format;
import std.utf : toUTF8, toUTF32;

/**
 * Small floating panels opened from the taskbar tray icons (volume, WiFi,
 * battery, hidden notifications, input language). They build reusable content
 * trees and the app wires them into a PopupOverlay anchored to the matching
 * taskbar icon.
 *
 * The popup overlay paints only the backdrop + drop shadow, so every flyout
 * must fill its own rounded panel surface.
 */
class TrayPanel : Widget
{
    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        canvas.drawRoundedRect(Rect(0, 0, bounds().width, bounds().height), 8,
            palette.panelElevated, palette.border.withAlpha(230), 1);
    }
}

final class VolumePanel : TrayPanel
{
    private VBox _column;
    private Label _deviceLabel;
    private Slider _slider;
    private Label _percentLabel;
    private Button _muteButton;
    private Button _expandButton;
    private VBox _deviceList;
    private Button[] _deviceButtons;
    private AudioDevice[] _devices;
    private uint _selected;
    private int _percent;
    private bool _muted;
    private bool _expanded;

    void delegate(int percent) onVolumeSet;
    void delegate() onMuteToggle;
    void delegate(uint index) onDeviceSelected;

    this(int percent, bool muted, AudioDevice[] devices, uint selected)
    {
        _percent = percent;
        _muted = muted;
        _devices = devices;
        _selected = selected;
        // Own composited layer: slider drags repaint just this panel instead
        // of the whole full-window popup overlay.
        setComposited(true);
        rebuild();
    }

    // See LanguagePanel.bindRow: the device index must arrive as a parameter,
    // not a loop-body local, or every device button selects the last device.
    private void bindDeviceRow(Button row, uint index)
    {
        row.onClick = delegate()
        {
            if (onDeviceSelected !is null) onDeviceSelected(index);
        };
    }

    /// Windows 11 volume flyout: the active output device as the header (with a
    /// chevron to reveal the device picker), then a mute glyph + slider + value.
    private void rebuild()
    {
        if (_column !is null)
        {
            remove(_column);
            _column = null;
        }
        _deviceButtons.length = 0;

        auto column = new VBox(10, Insets(14));
        _column = column;
        add(column);

        auto header = column.add(new HBox(6));
        header.layoutHints().preferredHeight = 28;
        _deviceLabel = header.add(new Label(activeDeviceName()));
        _deviceLabel.setEllipsis(true);
        _deviceLabel.layoutHints().flex = 1.0;
        _expandButton = header.add(new Button("", _expanded ?
            IconKind.chevronUp : IconKind.chevronDown));
        _expandButton.setFlat(true);
        _expandButton.layoutHints().preferredWidth = 30;
        _expandButton.onClick = delegate()
        {
            _expanded = !_expanded;
            rebuild();
        };

        auto row = column.add(new HBox(10));
        row.layoutHints().preferredHeight = 44;
        _muteButton = row.add(new Button("", _muted ?
            IconKind.volumeMuted : IconKind.volume));
        _muteButton.setFlat(true);
        _muteButton.setIconSize(22);
        _muteButton.layoutHints().preferredWidth = 40;
        _muteButton.onClick = delegate()
        {
            if (onMuteToggle !is null) onMuteToggle();
        };
        _slider = row.add(new Slider(0, 100, _percent));
        _slider.layoutHints().flex = 1.0;
        _slider.onChanged = delegate(double value)
        {
            const rounded = cast(int) (value + 0.5);
            _percent = rounded;
            _percentLabel.setText(format("%d", rounded));
            if (onVolumeSet !is null) onVolumeSet(rounded);
        };
        _percentLabel = row.add(new Label(format("%d", _percent)));
        _percentLabel.setAlignment(HorizontalAlign.right, VerticalAlign.middle);
        _percentLabel.layoutHints().preferredWidth = 40;

        if (_expanded)
        {
            _deviceList = column.add(new VBox(2));
            foreach (device; _devices)
            {
                const active = device.index == _selected;
                auto deviceRow = _deviceList.add(new Button(device.name,
                    IconKind.volume));
                deviceRow.setFlat(true);
                deviceRow.setAccent(active);
                deviceRow.layoutHints().preferredHeight = 32;
                bindDeviceRow(deviceRow, device.index);
                _deviceButtons ~= deviceRow;
            }
            const count = cast(int) _deviceButtons.length;
            _deviceList.layoutHints().preferredHeight = count == 0 ? 0 :
                count * 32 + (count - 1) * 2;
        }
        else
            _deviceList = null;

        layoutHints().preferredWidth = 380;
        layoutHints().preferredHeight = 14 * 2 + 28 + 10 + 44 +
            (_expanded && _deviceList !is null ?
                10 + _deviceList.layoutHints().preferredHeight : 0);
        _column.layoutTree();
        invalidate();
    }

    private string activeDeviceName() const
    {
        foreach (device; _devices)
            if (device.index == _selected) return device.name;
        return "Volume";
    }

    protected override void onLayout()
    {
        if (_column !is null)
            _column.setBounds(Rect(0, 0, bounds().width, bounds().height));
    }

    void update(int percent, bool muted)
    {
        _percent = percent;
        _muted = muted;
        _slider.setValue(percent, false);
        _percentLabel.setText(format("%d", percent));
        _muteButton.setIcon(muted ? IconKind.volumeMuted : IconKind.volume);
    }

    void updateDevices(AudioDevice[] devices, uint selected)
    {
        _devices = devices;
        _selected = selected;
        rebuild();
    }

    /// Test hooks: the Windows-style icon-only mute button and its state.
    Button muteButtonForTesting() @safe pure nothrow @nogc { return _muteButton; }
    bool mutedForTesting() const @safe pure nothrow @nogc { return _muted; }
}

final class WifiPanel : TrayPanel
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
    /// Open the Windows Airplane mode / Mobile hotspot settings pages.
    void delegate() onAirplaneMode;
    void delegate() onMobileHotspot;

    this(WifiState state)
    {
        _state = state;
        setComposited(true);
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

    // See LanguagePanel.bindRow: ssid/profile/secured must arrive as parameters,
    // not loop-body locals, or every network row connects to the last network.
    private void bindNetworkRow(WifiNetworkRow row, string ssid, string profile,
        bool secured)
    {
        row.onClick = delegate()
        {
            if (onConnect !is null) onConnect(ssid, profile, secured);
        };
    }

    private void rebuild()
    {
        foreach (child; _column.children())
            _column.remove(child);

        const activeSsid = _state.ssid.length > 0 ? _state.ssid : _state.profile;

        // Windows 11: the connected network is a card at the top with the
        // "Properties" link and the "Disconnect" button.
        if (_state.connected)
        {
            auto card = _column.add(new WifiConnectedCard(activeSsid, true));
            card.onDisconnect = delegate()
            {
                if (onDisconnect !is null) onDisconnect();
            };
            card.onProperties = delegate()
            {
                if (onOpenNetworkSettings !is null) onOpenNetworkSettings();
            };
        }

        const status = _feedback.length > 0 ? _feedback :
            (_scanning ? "Scanning for networks..." : "");
        if (status.length > 0)
        {
            _statusLabel = _column.add(new Label(status));
            _statusLabel.setColor(theme().textMuted);
        }
        else
            _statusLabel = null;

        _signalLabel = null;
        _disconnectButton = null;

        // Available networks: one row each, the connected one marked.
        _networkList = _column.add(new VBox(2));
        size_t shown;
        foreach (network; _state.networks)
        {
            if (shown >= 8) break;
            const ssid = network.ssid;
            const secured = network.secured;
            const signal = network.signal;
            const active = _state.connected && ssid == activeSsid;
            auto row = _networkList.add(new WifiNetworkRow(ssid, secured,
                cast(int) signal, active));
            bindNetworkRow(row, network.ssid, network.profile, secured);
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
        else if (_state.networks.length == 0 && !_scanning)
        {
            auto none = _networkList.add(new Label("No networks in range."));
            none.setColor(theme().textMuted);
            hasNote = true;
        }
        // Like the volume device list: the inner VBox needs an explicit
        // height or the outer column collapses it to 0 and rows clip away.
        const shownCount = cast(int) shown;
        _networkList.layoutHints().preferredHeight = shownCount == 0 && !hasNote ?
            0 : shownCount * 34 + (shownCount > 0 ? (shownCount - 1) * 2 : 0) +
            (hasNote ? (shownCount > 0 ? 2 : 0) + 24 : 0);

        // Settings link + explanation, like Windows.
        auto settings = _column.add(new Button("Network & Internet settings",
            IconKind.settings));
        settings.setFlat(true);
        settings.layoutHints().preferredHeight = 30;
        settings.onClick = delegate()
        {
            if (onOpenNetworkSettings !is null) onOpenNetworkSettings();
        };
        auto note = _column.add(new Label(
            "Change settings, such as making a connection metered."));
        note.setColor(theme().textMuted);
        note.setPixelSize(13);

        // Quick toggles: Wi-Fi / Airplane mode / Mobile hotspot.
        auto tiles = _column.add(new HBox(8));
        tiles.layoutHints().preferredHeight = 74;
        auto wifiTile = tiles.add(new QuickToggleTile("Wi-Fi", QuickGlyph.wifi,
            _state.connected));
        wifiTile.onClick = delegate()
        {
            if (onRefresh !is null) onRefresh();
        };
        auto airplaneTile = tiles.add(new QuickToggleTile("Airplane mode",
            QuickGlyph.airplane, false));
        airplaneTile.onClick = delegate()
        {
            if (onAirplaneMode !is null) onAirplaneMode();
        };
        auto hotspotTile = tiles.add(new QuickToggleTile("Mobile hotspot",
            QuickGlyph.hotspot, false));
        hotspotTile.onClick = delegate()
        {
            if (onMobileHotspot !is null) onMobileHotspot();
        };

        layoutHints().preferredWidth = 400;
        layoutHints().preferredHeight = 14 * 2 +
            (_state.connected ? 96 + 10 : 0) +
            (status.length > 0 ? 22 + 10 : 0) +
            _networkList.layoutHints().preferredHeight + 10 + 30 + 6 + 34 +
            10 + 74;
        _column.layoutTree();
        invalidate();
    }

    protected override void onLayout()
    {
        if (_column !is null)
            _column.setBounds(Rect(0, 0, bounds().width, bounds().height));
    }
}

final class BatteryPanel : TrayPanel
{
    private VBox _column;

    /// Open the Windows battery settings page (link + "Battery saver" tile).
    void delegate() onOpenBatterySettings;

    this(bool hasBattery, bool charging, int percent)
    {
        setComposited(true);
        auto column = new VBox(10, Insets(14));
        _column = column;
        add(column);

        // Windows 11 battery flyout: a large battery glyph, the percentage in
        // display type, a charge-status note, then Battery settings + saver.
        auto top = column.add(new HBox(12));
        top.layoutHints().preferredHeight = 52;
        auto glyph = top.add(new Button("",
            charging ? IconKind.batteryCharging : IconKind.battery));
        glyph.setFlat(true);
        glyph.setIconSize(40);
        glyph.layoutHints().preferredWidth = 56;
        auto percentLabel = top.add(new Label(hasBattery ?
            format("%d%%", percent) : "--"));
        percentLabel.setScale(3);
        percentLabel.setAlignment(HorizontalAlign.left, VerticalAlign.middle);
        percentLabel.layoutHints().preferredWidth = 110;
        auto status = top.add(new Label(hasBattery ?
            (charging ? "Fully charged" : format("%d%% remaining", percent)) :
            "No battery detected"));
        status.setColor(theme().textMuted);
        status.setAlignment(HorizontalAlign.left, VerticalAlign.middle);
        status.layoutHints().flex = 1.0;

        auto settings = column.add(new Button("Battery settings",
            IconKind.settings));
        settings.setFlat(true);
        settings.layoutHints().preferredHeight = 34;
        settings.onClick = delegate()
        {
            if (onOpenBatterySettings !is null) onOpenBatterySettings();
        };

        auto saver = column.add(new Button("Battery saver", IconKind.battery));
        saver.setFlat(true);
        saver.layoutHints().preferredHeight = 48;
        saver.onClick = delegate()
        {
            if (onOpenBatterySettings !is null) onOpenBatterySettings();
        };

        layoutHints().preferredWidth = 340;
        layoutHints().preferredHeight = 14 * 2 + 52 + 10 + 34 + 10 + 48;
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
    /// Open the owning application's own tray menu (returns false if none).
    bool delegate(size_t id) onIconMenu;

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

    /// True while an icon is being dragged out (skip live refreshes then).
    bool dragging() const @safe pure nothrow @nogc { return _dragCell >= 0; }

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
        else if (_dragMoved && _dragOutside)
            canvas.drawTextInRect(
                Rect(0, full.bottom() - 20, full.width, 18),
                "Release to show in tray"d, palette.accent, 1,
                HorizontalAlign.center, VerticalAlign.middle, true);
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
                const system = _icons[cast(size_t) cell].system;
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
                if (!system && onIconMenu !is null)
                    items ~= ContextMenuItem.command("Open app menu",
                        IconKind.chevronRight, delegate()
                        {
                            onIconMenu(id);
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

/// Vector glyphs used by the quick-settings tiles. IconKind has no airplane /
/// hotspot shapes, so they are drawn here (kept next to the tiles).
enum QuickGlyph : ubyte { wifi, airplane, hotspot }

private void drawQuickGlyph(ref Canvas canvas, QuickGlyph glyph, Rect rect,
    Color foreground)
{
    const scale = maxInt(1, rect.width / 18);
    const cx = rect.x + rect.width / 2;
    const cy = rect.y + rect.height / 2;
    final switch (glyph)
    {
        case QuickGlyph.wifi:
            drawIcon(canvas, IconKind.wifi, rect, foreground);
            break;
        case QuickGlyph.airplane:
            // A plane seen from above, nose at the top.
            canvas.drawLine(Point(cx, cy - 9 * scale), Point(cx, cy + 8 * scale),
                foreground, 2 * scale);
            canvas.drawLine(Point(cx - 9 * scale, cy + 2 * scale),
                Point(cx, cy - scale), foreground, 2 * scale);
            canvas.drawLine(Point(cx + 9 * scale, cy + 2 * scale),
                Point(cx, cy - scale), foreground, 2 * scale);
            canvas.drawLine(Point(cx - 4 * scale, cy + 7 * scale),
                Point(cx, cy + 5 * scale), foreground, scale);
            canvas.drawLine(Point(cx + 4 * scale, cy + 7 * scale),
                Point(cx, cy + 5 * scale), foreground, scale);
            break;
        case QuickGlyph.hotspot:
        {
            auto clipped = canvas.clipped(rect);
            const ox = cx - 3 * scale;
            const oy = cy + 6 * scale;
            clipped.fillCircle(Point(ox, oy), 2 * scale, foreground);
            clipped.strokeCircle(Point(ox, oy), 6 * scale, foreground, scale);
            clipped.strokeCircle(Point(ox, oy), 10 * scale,
                foreground.withAlpha(170), scale);
            break;
        }
    }
}

/**
 * One Windows-11 quick-settings tile (icon above a caption). The tile is
 * accent-filled while its feature is on.
 */
final class QuickToggleTile : Widget
{
    private dstring _label;
    private QuickGlyph _glyph;
    private bool _active;
    private bool _hover;

    void delegate() onClick;

    this(string label, QuickGlyph glyph, bool active)
    {
        _label = toUTF32(label);
        _glyph = glyph;
        _active = active;
        setComposited(true);
        layoutHints().flex = 1.0;
        layoutHints().preferredHeight = 74;
    }

    bool active() const { return _active; }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        const background = _active ? palette.accent :
            (_hover ? palette.buttonHover : palette.buttonBackground);
        canvas.fillRoundedRect(full, 6, background);
        const foreground = _active ? Color.rgb(255, 255, 255) : palette.text;
        drawQuickGlyph(canvas, _glyph,
            Rect(full.x + 10, full.y + 12, 20, 20), foreground);
        canvas.drawTextInRect(
            Rect(full.x + 8, full.bottom() - 30, full.width - 14, 24),
            _label, foreground, 1, HorizontalAlign.left, VerticalAlign.middle,
            true);
    }

    override bool onMouseMove(ref Event event)
    {
        const hover = containsLocal(event.position);
        if (hover != _hover)
        {
            _hover = hover;
            invalidate();
        }
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        if (containsLocal(event.position) && onClick !is null) onClick();
        return true;
    }
}

/// The Windows-11 "connected network" card: name, "Connected, secured",
/// a Properties link and a Disconnect button.
final class WifiConnectedCard : Widget
{
    private dstring _ssid;
    private bool _secured;
    private Rect _propertiesRect;
    private Rect _disconnectRect;

    void delegate() onDisconnect;
    void delegate() onProperties;

    this(string ssid, bool secured)
    {
        _ssid = toUTF32(ssid);
        _secured = secured;
        setComposited(true);
        layoutHints().preferredHeight = 96;
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.fillRoundedRect(full, 8, palette.accent);
        const foreground = Color.rgb(255, 255, 255);
        drawIcon(canvas, IconKind.wifi, Rect(full.x + 12, full.y + 12, 22, 22),
            foreground);
        canvas.drawTextInRect(Rect(full.x + 44, full.y + 10, full.width - 56, 24),
            _ssid, foreground, 2, HorizontalAlign.left, VerticalAlign.middle,
            true);
        canvas.drawTextInRect(Rect(full.x + 44, full.y + 34, full.width - 56, 18),
            _secured ? "Connected, secured"d : "Connected"d,
            foreground.withAlpha(215), 1, HorizontalAlign.left,
            VerticalAlign.middle, true);

        _propertiesRect = Rect(full.x + 44, full.y + 56, 90, 20);
        canvas.drawTextInRect(_propertiesRect, "Properties"d, foreground, 1,
            HorizontalAlign.left, VerticalAlign.middle, true);
        canvas.drawLine(Point(_propertiesRect.x, _propertiesRect.bottom() - 2),
            Point(_propertiesRect.x + 62, _propertiesRect.bottom() - 2),
            foreground.withAlpha(190), 1);

        _disconnectRect = Rect(full.right() - 130, full.bottom() - 42, 118, 32);
        canvas.fillRoundedRect(_disconnectRect, 5, foreground.withAlpha(46));
        canvas.drawTextInRect(_disconnectRect, "Disconnect"d, foreground, 1,
            HorizontalAlign.center, VerticalAlign.middle, true);
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        if (_disconnectRect.contains(event.position))
        {
            if (onDisconnect !is null) onDisconnect();
            return true;
        }
        if (_propertiesRect.contains(event.position))
        {
            if (onProperties !is null) onProperties();
            return true;
        }
        return true;
    }
}

/// One available Wi-Fi network row: signal glyph, name and a lock when secured.
final class WifiNetworkRow : Widget
{
    private dstring _ssid;
    private bool _secured;
    private int _signal;
    private bool _active;
    private bool _hover;

    void delegate() onClick;

    this(string ssid, bool secured, int signal, bool active)
    {
        _ssid = toUTF32(ssid);
        _secured = secured;
        _signal = signal;
        _active = active;
        setComposited(true);
        layoutHints().preferredHeight = 34;
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        if (_hover) canvas.fillRoundedRect(full, 5, palette.buttonHover);
        const foreground = _active ? palette.accent : palette.text;
        drawIcon(canvas, IconKind.wifi, Rect(full.x + 8, full.y + 7, 20, 20),
            foreground);
        canvas.drawTextInRect(
            Rect(full.x + 38, full.y, full.width - 76, full.height), _ssid,
            palette.text, 1, HorizontalAlign.left, VerticalAlign.middle, true);
        if (_active)
            canvas.drawTextInRect(
                Rect(full.right() - 104, full.y, 62, full.height), "connected"d,
                palette.accent, 1, HorizontalAlign.right, VerticalAlign.middle,
                true);
        if (_secured)
        {
            // A small padlock (body + shackle).
            const x = full.right() - 24;
            const y = full.y + full.height / 2;
            canvas.strokeCircle(Point(x + 5, y - 2), 4, palette.textMuted, 1);
            canvas.fillRoundedRect(Rect(x, y, 10, 9), 2, palette.textMuted);
        }
    }

    override bool onMouseMove(ref Event event)
    {
        const hover = containsLocal(event.position);
        if (hover != _hover)
        {
            _hover = hover;
            invalidate();
        }
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        if (containsLocal(event.position) && onClick !is null) onClick();
        return true;
    }
}

/// One input-language row: the three-letter indicator, the language name and
/// its keyboard layout, with the active language accented.
final class LanguageRow : Widget
{
    private dstring _abbrev;
    private dstring _name;
    private dstring _keyboard;
    private bool _active;
    private bool _hover;

    void delegate() onClick;

    this(InputLanguage language)
    {
        _abbrev = toUTF32(language.abbrev);
        _name = toUTF32(language.name);
        _keyboard = toUTF32(language.keyboard);
        _active = language.active;
        setComposited(true);
        layoutHints().preferredHeight = 48;
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        if (_active) canvas.fillRoundedRect(full, 5,
            palette.accent.withAlpha(48));
        else if (_hover) canvas.fillRoundedRect(full, 5, palette.buttonHover);
        if (_active)
            canvas.fillRoundedRect(Rect(full.x + 3, full.y + 8, 3,
                full.height - 16), 2, palette.accent);
        const nameColor = _active ? palette.accent : palette.text;
        canvas.drawTextInRect(Rect(full.x + 14, full.y, 54, full.height),
            _abbrev, nameColor, 2, HorizontalAlign.left, VerticalAlign.middle,
            false);
        canvas.drawTextInRect(Rect(full.x + 74, full.y + 5, full.width - 84, 22),
            _name, nameColor, 1, HorizontalAlign.left, VerticalAlign.middle,
            true);
        canvas.drawTextInRect(Rect(full.x + 74, full.y + 22, full.width - 84, 20),
            _keyboard, palette.textMuted, 1, HorizontalAlign.left,
            VerticalAlign.middle, true);
    }

    override bool onMouseMove(ref Event event)
    {
        const hover = containsLocal(event.position);
        if (hover != _hover)
        {
            _hover = hover;
            invalidate();
        }
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        if (containsLocal(event.position) && onClick !is null) onClick();
        return true;
    }
}

/// Windows input-language flyout: one row per installed keyboard layout plus a
/// "Language preferences" link.
final class LanguagePanel : TrayPanel
{
    private VBox _column;
    private InputLanguage[] _languages;

    void delegate() onOpenSettings;
    void delegate(size_t hkl) onSelect;

    this(InputLanguage[] languages)
    {
        setComposited(true);
        auto column = new VBox(2, Insets(10));
        _column = column;
        add(column);
        rebuild(languages);
    }

    void update(InputLanguage[] languages)
    {
        // Rebuilding every 2 s churned all row widgets (and repainted the whole
        // flyout) even when nothing changed, which made the flyout feel laggy.
        // Only rebuild when the set or the active layout actually changed.
        if (languages.length == _languages.length)
        {
            bool same = true;
            foreach (i, language; languages)
            {
                if (language.hkl != _languages[i].hkl ||
                    language.active != _languages[i].active)
                {
                    same = false;
                    break;
                }
            }
            if (same) return;
        }
        rebuild(languages);
    }

    // NB: the hkl MUST arrive as a function parameter. Capturing a loop-body
    // local (`const captured = language.hkl`) makes every row's closure share
    // one reused stack slot, so all rows selected the LAST language (proved:
    // the same pattern prints "2 2 2" for a 0..3 loop). Do not inline this
    // back into the loop.
    private void bindRow(LanguageRow row, size_t hkl)
    {
        row.onClick = delegate()
        {
            if (onSelect !is null) onSelect(hkl);
        };
    }

    private void rebuild(InputLanguage[] languages)
    {
        _languages = languages.dup;
        foreach (child; _column.children())
            _column.remove(child);
        foreach (language; languages)
        {
            auto row = _column.add(new LanguageRow(language));
            bindRow(row, language.hkl);
        }
        _column.add(new Separator());
        auto settings = _column.add(new Button("Language preferences",
            IconKind.settings));
        settings.setFlat(true);
        settings.layoutHints().preferredHeight = 40;
        settings.onClick = delegate()
        {
            if (onOpenSettings !is null) onOpenSettings();
        };

        layoutHints().preferredWidth = 360;
        const count = cast(int) languages.length;
        layoutHints().preferredHeight = 10 * 2 +
            (count == 0 ? 0 : count * 48 + (count - 1) * 2) + 10 + 40;
        _column.layoutTree();
        invalidate();
    }

    protected override void onLayout()
    {
        if (_column !is null)
            _column.setBounds(Rect(0, 0, bounds().width, bounds().height));
    }
}

