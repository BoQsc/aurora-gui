module aurorastream.devicedropdown;

import aurora;
import aurorastream.audioendpoint : AudioEndpoint, cleanedAudioEndpoint;
import std.string : strip;

/**
 * Small Aurora-native audio-endpoint selector.
 * An empty selected value means that the input is disabled.
 */
final class AudioDeviceDropdown : Button
{
    private string _selectedDevice;
    private AudioEndpoint[] _devices;
    private bool _devicesKnown;
    private string _emptyMessage;

    void delegate(string selectedDevice) onChanged;

    this(string selectedDevice = "",
        string emptyMessage = "No audio devices found")
    {
        super("");
        _selectedDevice = selectedDevice.strip().idup;
        _emptyMessage = emptyMessage.idup;
        onClick = delegate() { openDeviceMenu(); };
        updateCaption();
    }

    string selectedDevice() const
    {
        return _selectedDevice;
    }

    void setSelectedDevice(string value, bool notify = true)
    {
        immutable next = value.strip().idup;
        if (next == _selectedDevice) return;
        _selectedDevice = next;
        updateCaption();
        if (notify && onChanged !is null) onChanged(_selectedDevice);
    }

    void setDevices(AudioEndpoint[] devices)
    {
        _devices.length = 0;
        foreach (device; devices)
        {
            auto cleaned = cleanedAudioEndpoint(device);
            if (cleaned.inputName.length == 0 ||
                containsDeviceValue(cleaned.inputName)) continue;
            _devices ~= cleaned;
        }
        _devicesKnown = true;

        // Older settings sometimes stored a display label instead of the
        // stable backend identifier. Migrate it when an unambiguous match is
        // available.
        if (_selectedDevice.length > 0 && findDeviceIndex(_selectedDevice) < 0)
        {
            ptrdiff_t match = -1;
            foreach (index, device; _devices)
            {
                if (device.displayName != _selectedDevice &&
                    device.label != _selectedDevice) continue;
                if (match >= 0)
                {
                    match = -1;
                    break;
                }
                match = cast(ptrdiff_t) index;
            }
            if (match >= 0)
                _selectedDevice = _devices[cast(size_t) match].inputName;
        }
        updateCaption();
    }

    bool selectDefaultIfEmpty(bool notify = true)
    {
        if (_selectedDevice.length > 0 || _devices.length == 0)
            return false;
        foreach (device; _devices)
        {
            if (device.alternativeName != "default") continue;
            setSelectedDevice(device.inputName, notify);
            return true;
        }
        setSelectedDevice(_devices[0].inputName, notify);
        return true;
    }

    private ptrdiff_t findDeviceIndex(string value) const
    {
        foreach (index, device; _devices)
            if (device.inputName == value) return cast(ptrdiff_t) index;
        return -1;
    }

    private bool containsDeviceValue(string value) const
    {
        return findDeviceIndex(value) >= 0;
    }

    private void updateCaption()
    {
        string caption;
        if (_selectedDevice.length == 0)
        {
            caption = "Disabled";
        }
        else
        {
            const index = findDeviceIndex(_selectedDevice);
            if (index >= 0)
                caption = _devices[cast(size_t) index].label;
            else if (_devicesKnown)
                caption = "Unavailable — " ~ _selectedDevice;
            else
                caption = _selectedDevice;
        }

        setText(caption ~ "  ▼");
        layoutHints().minWidth = 280;
        layoutHints().preferredWidth = 500;
    }

    private ContextMenuItem deviceItem(string value, string label)
    {
        immutable selected = value.idup;
        return ContextMenuItem.check(label, _selectedDevice == selected,
            delegate() { setSelectedDevice(selected); });
    }

    private void openDeviceMenu()
    {
        ContextMenuItem[] items;
        items ~= deviceItem("", "Disabled");

        if (_devicesKnown && _selectedDevice.length > 0 &&
            !containsDeviceValue(_selectedDevice))
        {
            immutable unavailable = _selectedDevice.idup;
            items ~= ContextMenuItem.separatorItem();
            items ~= ContextMenuItem.check(
                "Saved but unavailable: " ~ unavailable,
                true,
                delegate() { setSelectedDevice(unavailable); });
        }

        items ~= ContextMenuItem.separatorItem();
        if (_devices.length == 0)
        {
            items ~= ContextMenuItem.command(
                _devicesKnown ? _emptyMessage : "Audio devices are still loading",
                delegate() {}, "", false);
        }
        else
        {
            foreach (device; _devices)
                items ~= deviceItem(device.inputName, device.label);
        }

        int rowCount;
        int separatorCount;
        foreach (item; items)
        {
            if (item.separator) ++separatorCount;
            else ++rowCount;
        }
        const estimatedHeight = 6 + rowCount * 22 + separatorCount * 4;
        showContextMenu(this,
            localToGlobal(Point(0, bounds().height + estimatedHeight + 2)),
            items);
    }
}
