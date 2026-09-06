// NOTE (2026-09-05): preserved WASAPI/IAudioEndpointVolume implementation.
// Sidelined because THIS machine's MMDevAPI class factory refuses QI for
// IMMDeviceEnumerator (E_NOINTERFACE, proven 4 ways incl. manual QI on a live
// object; registry/DLL/services all healthy). The mixer implementation in
// source/auroradesktop/system.d is what is verified working here. To re-enable
// this file: repair OS COM (restart AudioEndpointBuilder / reboot), verify with
// a manual-QI probe returning S_OK, then swap it back in (same public API).

module wasapi_reference; // NOT BUILT - see NOTE below

import aurora.widgets.desktop : SystemTrayState;

version (Windows)
{
    import core.sys.windows.windows : BOOL, DWORD, BYTE, LPDWORD;
    import core.sys.windows.winbase : SYSTEM_POWER_STATUS, GetSystemPowerStatus;
    import core.sys.windows.winuser : ExitWindowsEx, EWX_SHUTDOWN, EWX_REBOOT,
        EWX_FORCE, EWX_FORCEIFHUNG;
    import core.sys.windows.powrprof : SetSuspendState;
    import core.sys.windows.mmsystem : HWAVEOUT, MMRESULT, MMSYSERR_NOERROR,
        waveOutGetVolume, waveOutGetNumDevs, waveOutSetVolume;
    import core.sys.windows.wininet : InternetGetConnectedState;
    import std.utf : toUTF16z;
}

/**
 * Queries the live Windows system state used to populate the taskbar tray.
 *
 * This is the only module in the desktop app that touches the Win32 system
 * APIs; everything below stays a pure-Aurora widget tree so the shell is still
 * testable headlessly with a hand-supplied `SystemTrayState`.
 */

version (Windows)
{
    private __gshared BYTE acLineStatus;
    private __gshared BYTE batteryFlag;
}

void refreshSystemStatus(ref SystemTrayState tray)
{
    version (Windows)
    {
        SYSTEM_POWER_STATUS status;
        if (GetSystemPowerStatus(&status))
        {
            acLineStatus = status.ACLineStatus;
            batteryFlag = status.BatteryFlag;
            tray.hasBattery = status.BatteryFlag != 128; // 0x80 = no system battery
            tray.batteryPercent = status.BatteryLifePercent == 255 ? -1 :
                cast(int) status.BatteryLifePercent;
            tray.batteryCharging = (status.BatteryFlag & 0x08) != 0 || acLineStatus == 1;
            if (tray.hasBattery && tray.batteryPercent < 0) tray.batteryPercent = 0;
        }
        else
        {
            tray.hasBattery = false;
            tray.batteryPercent = -1;
            tray.batteryCharging = false;
        }

        DWORD flags;
        tray.wifiConnected = InternetGetConnectedState(&flags, 0) != 0;
    }
    else
    {
        tray.wifiConnected = true;
        tray.hasBattery = false;
        tray.batteryPercent = -1;
        tray.batteryCharging = false;
    }
}

version (Windows)
{
    import core.sys.windows.basetyps : GUID;
    import core.sys.windows.objbase : CLSCTX_ALL, COINIT,
        CoCreateInstance, CoInitializeEx, CoTaskMemFree;
    import core.sys.windows.unknwn : IUnknown;
    import core.sys.windows.windef : HKEY;
    import core.sys.windows.winreg : HKEY_CLASSES_ROOT,
        RegCloseKey, RegEnumKeyExW, RegOpenKeyExW, RegQueryValueExW;
    import core.sys.windows.mmsystem : HWAVEOUT,
        waveOutGetNumDevs, waveOutGetVolume, waveOutSetVolume;
    import std.utf : toUTF16z, toUTF8;

    private enum ComInitThreaded = COINIT.COINIT_APARTMENTTHREADED;
    private enum RegRead = 0x020019; // KEY_READ

    // --- Core Audio endpoint volume (Windows Vista+) -----------------------
    // The legacy WinMM mixer destination lines do NOT track the master
    // endpoint volume that Windows itself shows: drivers report stale levels
    // and phantom mute flags through them (the tray showed a muted speaker
    // while Windows was unmuted). Everything below goes through
    // IAudioEndpointVolume instead - the exact API the Windows volume flyout
    // uses - so the tray always agrees with the system. The old WAVE_MAPPER
    // shortcut survives only as a last-resort fallback when COM fails.

    private alias int HResult;

    extern (Windows) interface IMMDeviceEnumerator : IUnknown
    {
        HResult EnumAudioEndpoints(int dataFlow, uint stateMask,
            void** ppDevices);
        HResult GetDefaultAudioEndpoint(int dataFlow, int role,
            void** ppDevice);
        HResult GetDevice(const(wchar)* id, void** ppDevice);
        HResult RegisterEndpointNotificationCallback(void* client);
        HResult UnregisterEndpointNotificationCallback(void* client);
    }

    extern (Windows) interface IMMDeviceCollection : IUnknown
    {
        HResult GetCount(uint* deviceCount);
        HResult Item(uint deviceNumber, void** ppDevice);
    }

    extern (Windows) interface IMMDevice : IUnknown
    {
        HResult Activate(const(GUID)* iid, uint clsctx, void* activationParams,
            void** ppInterface);
        HResult OpenPropertyStore(uint stgmAccess, void** ppProperties);
        HResult GetId(wchar** id);
        HResult GetState(uint* state);
    }

    extern (Windows) interface IAudioEndpointVolume : IUnknown
    {
        HResult RegisterControlChangeNotify(void* notify);
        HResult UnregisterControlChangeNotify(void* notify);
        HResult GetChannelCount(uint* channelCount);
        HResult SetMasterVolumeLevel(float levelDB, const(GUID)* eventContext);
        HResult SetMasterVolumeLevelScalar(float level,
            const(GUID)* eventContext);
        HResult GetMasterVolumeLevel(float* levelDB);
        HResult GetMasterVolumeLevelScalar(float* level);
        HResult SetChannelVolumeLevel(uint channel, float levelDB,
            const(GUID)* eventContext);
        HResult SetChannelVolumeLevelScalar(uint channel, float level,
            const(GUID)* eventContext);
        HResult GetChannelVolumeLevel(uint channel, float* levelDB);
        HResult GetChannelVolumeLevelScalar(uint channel, float* level);
        HResult SetMute(int muted, const(GUID)* eventContext);
        HResult GetMute(int* muted);
        HResult GetVolumeStepInfo(uint* step, uint* stepCount);
        HResult VolumeStepUp(const(GUID)* eventContext);
        HResult VolumeStepDown(const(GUID)* eventContext);
        HResult QueryHardwareSupport(uint* hardwareSupportMask);
    }

    extern (Windows) interface IPropertyStore : IUnknown
    {
        HResult GetCount(uint* props);
        HResult GetAt(uint prop, PropertyKey* key);
        HResult GetValue(const(PropertyKey)* key, PropVariant* value);
        HResult SetValue(const(PropertyKey)* key, const(PropVariant)* value);
        HResult Commit();
    }

    extern (Windows) HResult PropVariantClear(PropVariant* value);

    align(8) struct PropVariant
    {
        ushort vt;
        ubyte[6] reservedPad; // wReserved1..4 + x64 union alignment pad
        union
        {
            wchar* pwszVal;
            ubyte[8] raw;
        }
    }
    static assert(PropVariant.sizeof == 16);

    struct PropertyKey
    {
        GUID fmtid;
        uint pid;
    }
    static assert(PropertyKey.sizeof == 20);

    private enum int EndpointRender = 0; // EDataFlow::eRender
    private enum int EndpointMultimedia = 1; // ERole::eMultimedia
    private enum uint EndpointStateActive = 1; // DEVICE_STATE_ACTIVE
    private enum uint StgmRead = 0; // STGM_READ for OpenPropertyStore
    private enum int HResultOk = 0;
    private enum ushort VariantLpwstr = 31; // VT_LPWSTR

    // Best-effort hardcoded IDs. The registry lookup below is authoritative;
    // these only matter if HKCR itself is unreadable.
    // IID_IUnknown is universal and needs no lookup.
    private immutable GUID iidUnknown = GUID(0x00000000, 0x0000, 0x0000,
        [0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46]);
    private immutable GUID fallbackClsidEnumerator = GUID(0xBCDE0395, 0xE52F,
        0x467C, [0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E]);
    private immutable GUID fallbackIidEnumerator = GUID(0xA95664D2, 0x9614,
        0x4F79, [0xA8, 0xA0, 0x4F, 0x8D, 0xA8, 0xC7, 0x01, 0x00]);
    // {5CDF2C82-841E-4546-9722-0CF74078229A}: proven empirically on this
    // machine (Activate returns S_OK and GetScalar tracks the real level),
    // while the ...78AB9A variant fails with E_NOINTERFACE.
    private immutable GUID fallbackIidEndpointVolume = GUID(0x5CDF2C82,
        0x841E, 0x4546, [0x97, 0x22, 0x0C, 0xF7, 0x40, 0x78, 0x22, 0x9A]);
    private immutable GUID fallbackIidPropertyStore = GUID(0x886D8EEB,
        0x8CF2, 0x4446, [0x8D, 0x02, 0xCD, 0xBA, 0x1D, 0xBD, 0xCF, 0x99]);
    private immutable PropertyKey keyFriendlyName = PropertyKey(
        GUID(0xA45C254E, 0xDF1C, 0x4EFD,
            [0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0]), 14);

    private __gshared bool comAttempted;
    private __gshared bool guidsResolved;
    private __gshared GUID guidClsidEnumerator;
    private __gshared GUID guidIidEnumerator;
    private __gshared GUID guidIidEndpointVolume;
    private __gshared GUID guidIidPropertyStore;

    private void ensureCom()
    {
        if (comAttempted) return;
        comAttempted = true;
        // Best effort: S_OK/S_FALSE initialize this thread; RPC_E_CHANGED_MODE
        // means someone else already did. Any other failure just makes every
        // call below fail into the waveOut fallback.
        CoInitializeEx(null, ComInitThreaded);
        resolveGuids();
    }

    private int hexNibble(wchar c)
    {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    private bool parseGuidText(const(wchar)[] text, out GUID guid)
    {
        // "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}"
        if (text.length < 38 || text[0] != '{' || text[37] != '}' ||
            text[9] != '-' || text[14] != '-' || text[19] != '-' ||
            text[24] != '-')
            return false;
        // NB: the last group is 12 hex digits (48 bits) and MUST NOT go
        // through a 32-bit accumulator (it truncates and yields a corrupt
        // CLSID that fails with REGDB_E_CLASSNOTREG).
        ulong[5] parts;
        int[5] digits = [8, 4, 4, 4, 12];
        size_t cursor = 1;
        foreach (slot; 0 .. 5)
        {
            ulong value;
            foreach (i; 0 .. digits[slot])
            {
                const nibble = hexNibble(text[cursor++]);
                if (nibble < 0) return false;
                value = (value << 4) | cast(ulong) nibble;
            }
            parts[slot] = value;
            if (slot < 4) ++cursor; // skip '-'
        }
        guid.Data1 = cast(uint) parts[0];
        guid.Data2 = cast(ushort) parts[1];
        guid.Data3 = cast(ushort) parts[2];
        guid.Data4[0] = cast(ubyte) (parts[3] >> 8);
        guid.Data4[1] = cast(ubyte) parts[3];
        foreach (i; 0 .. 6)
            guid.Data4[2 + i] = cast(ubyte) (parts[4] >> ((5 - i) * 4));
        return true;
    }

    private bool registryGuid(bool clsid, string name, out GUID guid)
    {
        HKEY list;
        if (RegOpenKeyExW(HKEY_CLASSES_ROOT,
                toUTF16z(clsid ? "CLSID" : "Interface"), 0, RegRead,
                &list) != 0)
            return false;
        scope (exit) RegCloseKey(list);
        const(wchar)* wanted = toUTF16z(name);
        size_t wantedLength;
        while (wanted[wantedLength] != 0) ++wantedLength;
        foreach (index; 0 .. 8192)
        {
            wchar[64] keyName;
            DWORD keyLength = cast(DWORD) keyName.length;
            if (RegEnumKeyExW(list, index, keyName.ptr, &keyLength, null,
                    null, null, null) != 0)
                break;
            if (keyLength >= keyName.length - 1) continue;
            keyName[keyLength] = 0;
            HKEY entry;
            if (RegOpenKeyExW(list, keyName.ptr, 0, RegRead, &entry) != 0)
                continue;
            scope (exit) RegCloseKey(entry);
            wchar[256] value;
            DWORD valueBytes = cast(DWORD) (value.length * 2);
            DWORD type;
            if (RegQueryValueExW(entry, null, null, &type, value.ptr,
                    &valueBytes) != 0)
                continue;
            size_t chars = valueBytes / 2;
            while (chars > 0 && value[chars - 1] == 0) --chars;
            if (chars != wantedLength) continue;
            bool equal = true;
            foreach (i; 0 .. chars)
            {
                if (value[i] != wanted[i])
                {
                    equal = false;
                    break;
                }
            }
            if (!equal) continue;
            return parseGuidText(keyName[0 .. keyLength], guid);
        }
        return false;
    }

    private void resolveGuids()
    {
        if (guidsResolved) return;
        guidsResolved = true;
        guidClsidEnumerator = fallbackClsidEnumerator;
        guidIidEnumerator = fallbackIidEnumerator;
        guidIidEndpointVolume = fallbackIidEndpointVolume;
        guidIidPropertyStore = fallbackIidPropertyStore;
        GUID found;
        if (registryGuid(true, "MMDeviceEnumerator", found))
            guidClsidEnumerator = found;
        if (registryGuid(false, "IMMDeviceEnumerator", found))
            guidIidEnumerator = found;
        if (registryGuid(false, "IAudioEndpointVolume", found))
            guidIidEndpointVolume = found;
        if (registryGuid(false, "IPropertyStore", found))
            guidIidPropertyStore = found;
    }

    private IMMDeviceEnumerator createEnumerator()
    {
        ensureCom();
        // The audio interface IIDs are not registered under HKCR\Interface,
        // so a QueryInterface for IMMDeviceEnumerator cannot succeed. Create
        // through IID_IUnknown (always valid) and drive the first two methods
        // by vtable slot instead; the layout is fixed by mmdeviceapi.h.
        // Proven on this machine: CoCreateInstance + GetDefaultAudioEndpoint
        // both return S_OK through this path.
        void* raw;
        if (CoCreateInstance(&guidClsidEnumerator, null, CLSCTX_ALL,
                &iidUnknown, &raw) != HResultOk || raw is null)
            return null;
        return cast(IMMDeviceEnumerator) raw;
    }

    /** True when the Core Audio MMDevice path is live (no silent fallback). */
    bool coreAudioAvailable()
    {
        auto enumerator = createEnumerator();
        if (enumerator is null) return false;
        scope (exit) enumerator.Release();
        void* rawCollection;
        if (enumerator.EnumAudioEndpoints(EndpointRender, EndpointStateActive,
                &rawCollection) != HResultOk || rawCollection is null)
            return false;
        (cast(IMMDeviceCollection) rawCollection).Release();
        return true;
    }

    private string wcharSpanToString(const(wchar)* text)
    {
        if (text is null) return "";
        try
        {
            size_t length;
            while (text[length] != 0) ++length;
            return toUTF8(text[0 .. length]);
        }
        catch (Exception)
        {
            return "";
        }
    }

    private string endpointFriendlyName(IMMDevice device)
    {
        void* rawStore;
        if (device.OpenPropertyStore(StgmRead, &rawStore) != HResultOk ||
            rawStore is null)
            return "";
        auto store = cast(IPropertyStore) rawStore;
        scope (exit) store.Release();
        PropVariant value;
        // Zero-init: PropVariantClear on garbage would free garbage.
        value.vt = 0;
        foreach (i; 0 .. value.reservedPad.length) value.reservedPad[i] = 0;
        foreach (i; 0 .. value.raw.length) value.raw[i] = 0;
        if (store.GetValue(&keyFriendlyName, &value) != HResultOk)
            return "";
        scope (exit) PropVariantClear(&value);
        if (value.vt != VariantLpwstr || value.pwszVal is null) return "";
        return wcharSpanToString(value.pwszVal);
    }

    private string endpointId(IMMDevice device)
    {
        wchar* id;
        if (device.GetId(&id) != HResultOk || id is null) return "";
        scope (exit) CoTaskMemFree(id);
        return wcharSpanToString(id);
    }

    /** One selectable output endpoint (an MMDevice ordinal + friendly name). */
    struct AudioDevice
    {
        uint index;
        string name;
    }

    private __gshared string _selectedEndpointId;
    private __gshared bool _endpointChosen;

    /** Every active render endpoint, each opened once for id + name. */
    private bool listEndpoints(out AudioDevice[] devices, out string[] ids)
    {
        devices = null;
        ids = null;
        auto enumerator = createEnumerator();
        if (enumerator is null) return false;
        scope (exit) enumerator.Release();
        void* rawCollection;
        if (enumerator.EnumAudioEndpoints(EndpointRender, EndpointStateActive,
                &rawCollection) != HResultOk || rawCollection is null)
            return false;
        auto collection = cast(IMMDeviceCollection) rawCollection;
        scope (exit) collection.Release();
        uint count;
        if (collection.GetCount(&count) != HResultOk) return false;
        foreach (i; 0 .. count)
        {
            void* rawDevice;
            if (collection.Item(i, &rawDevice) != HResultOk ||
                rawDevice is null)
                continue;
            auto device = cast(IMMDevice) rawDevice;
            scope (exit) device.Release();
            const id = endpointId(device);
            if (id.length == 0) continue;
            auto name = endpointFriendlyName(device);
            if (name.length == 0) name = id;
            devices ~= AudioDevice(cast(uint) devices.length, name);
            ids ~= id;
        }
        return true;
    }

    private bool openVolumeForOrdinal(uint ordinal, out IAudioEndpointVolume volume)
    {
        volume = null;
        auto enumerator = createEnumerator();
        if (enumerator is null) return false;
        scope (exit) enumerator.Release();
        void* rawCollection;
        if (enumerator.EnumAudioEndpoints(EndpointRender, EndpointStateActive,
                &rawCollection) != HResultOk || rawCollection is null)
            return false;
        auto collection = cast(IMMDeviceCollection) rawCollection;
        scope (exit) collection.Release();
        uint count;
        if (collection.GetCount(&count) != HResultOk || count == 0)
            return false;
        if (ordinal >= count) ordinal = 0;
        void* rawDevice;
        if (collection.Item(ordinal, &rawDevice) != HResultOk ||
            rawDevice is null)
            return false;
        auto device = cast(IMMDevice) rawDevice;
        scope (exit) device.Release();
        void* rawVolume;
        if (device.Activate(&guidIidEndpointVolume, CLSCTX_ALL, null,
                &rawVolume) != HResultOk || rawVolume is null)
            return false;
        volume = cast(IAudioEndpointVolume) rawVolume;
        return true;
    }

    private uint resolveEndpointOrdinal()
    {
        AudioDevice[] devices;
        string[] ids;
        if (!listEndpoints(devices, ids) || ids.length == 0) return 0;
        if (_endpointChosen)
        {
            foreach (i, id; ids)
            {
                if (id == _selectedEndpointId) return cast(uint) i;
            }
        }
        return 0;
    }

    /** Every active render endpoint on this machine, in MMDevice order. */
    AudioDevice[] audioOutputDevices()
    {
        AudioDevice[] devices;
        string[] ids;
        if (listEndpoints(devices, ids)) return devices;
        return fallbackDeviceList();
    }

    uint selectedAudioDevice()
    {
        AudioDevice[] devices;
        string[] ids;
        if (!listEndpoints(devices, ids) || ids.length == 0) return 0;
        if (_endpointChosen)
        {
            foreach (i, id; ids)
            {
                if (id == _selectedEndpointId) return cast(uint) i;
            }
        }
        return 0;
    }

    void selectAudioDevice(uint index)
    {
        AudioDevice[] devices;
        string[] ids;
        if (!listEndpoints(devices, ids) || ids.length == 0) return;
        if (index >= ids.length) index = 0;
        _selectedEndpointId = ids[index];
        _endpointChosen = true;
    }

    private int clampPercent(int percent)
    {
        return percent < 0 ? 0 : (percent > 100 ? 100 : percent);
    }

    private bool readEndpoint(uint ordinal, out int percent, out bool muted)
    {
        percent = 50;
        muted = false;
        IAudioEndpointVolume volume;
        if (!openVolumeForOrdinal(ordinal, volume)) return false;
        scope (exit) volume.Release();
        float level;
        int muteFlag;
        if (volume.GetMasterVolumeLevelScalar(&level) != HResultOk)
            return false;
        if (volume.GetMute(&muteFlag) != HResultOk) muteFlag = 0;
        if (level < 0.0f) level = 0.0f;
        if (level > 1.0f) level = 1.0f;
        percent = cast(int) (level * 100.0f + 0.5f);
        muted = muteFlag != 0;
        return true;
    }

    /** Master volume percent of one output endpoint (the Windows flyout value). */
    int deviceVolumePercent(uint dev)
    {
        AudioDevice[] devices;
        string[] ids;
        if (!listEndpoints(devices, ids) || ids.length == 0)
            return fallbackVolume();
        if (dev >= ids.length) dev = 0;
        int percent;
        bool muted;
        return readEndpoint(dev, percent, muted) ? percent : fallbackVolume();
    }

    /** Sets the master volume percent of one output endpoint. */
    void setDeviceVolumePercent(uint dev, int percent)
    {
        AudioDevice[] devices;
        string[] ids;
        if (!listEndpoints(devices, ids) || ids.length == 0)
        {
            fallbackSetVolume(percent);
            return;
        }
        if (dev >= ids.length) dev = 0;
        IAudioEndpointVolume volume;
        if (!openVolumeForOrdinal(dev, volume))
        {
            fallbackSetVolume(percent);
            return;
        }
        scope (exit) volume.Release();
        float level = clampPercent(percent) / 100.0f;
        volume.SetMasterVolumeLevelScalar(level, null);
    }

    /** True endpoint mute flag of one output device. */
    bool deviceMuted(uint dev)
    {
        AudioDevice[] devices;
        string[] ids;
        if (!listEndpoints(devices, ids) || ids.length == 0)
            return fallbackVolume() == 0;
        if (dev >= ids.length) dev = 0;
        int percent;
        bool muted;
        return readEndpoint(dev, percent, muted) ? muted :
            fallbackVolume() == 0;
    }

    /** Sets the true endpoint mute flag of one output device. */
    void setDeviceMuted(uint dev, bool muted)
    {
        AudioDevice[] devices;
        string[] ids;
        if (!listEndpoints(devices, ids) || ids.length == 0)
        {
            if (muted) fallbackSetVolume(0);
            return;
        }
        if (dev >= ids.length) dev = 0;
        IAudioEndpointVolume volume;
        if (!openVolumeForOrdinal(dev, volume))
        {
            if (muted) fallbackSetVolume(0);
            return;
        }
        scope (exit) volume.Release();
        volume.SetMute(muted ? 1 : 0, null);
    }

    private AudioDevice[] fallbackDeviceList()
    {
        import core.sys.windows.mmsystem : WAVEOUTCAPSW, waveOutGetDevCapsW;
        AudioDevice[] result;
        const count = waveOutGetNumDevs();
        foreach (dev; 0 .. count)
        {
            WAVEOUTCAPSW caps;
            if (waveOutGetDevCapsW(dev, &caps, WAVEOUTCAPSW.sizeof) !=
                MMSYSERR_NOERROR)
                continue;
            size_t length;
            while (length < caps.szPname.length && caps.szPname[length] != 0)
                ++length;
            result ~= AudioDevice(dev, toUTF8(caps.szPname[0 .. length]));
        }
        return result;
    }

    // Legacy WAVE_MAPPER fallback for machines where COM/Core Audio fails.
    private int fallbackVolume()
    {
        if (waveOutGetNumDevs() == 0) return 50;
        HWAVEOUT handle = cast(HWAVEOUT) null;
        DWORD volume;
        if (waveOutGetVolume(handle, &volume) != MMSYSERR_NOERROR) return 50;
        const left = (volume & 0xFFFF) >> 8;
        return cast(int) ((cast(double) left / 255.0) * 100.0);
    }

    private void fallbackSetVolume(int percent)
    {
        if (waveOutGetNumDevs() == 0) return;
        const scaled = cast(DWORD) (cast(double) clampPercent(percent) / 100.0 * 0xFFFF);
        HWAVEOUT handle = cast(HWAVEOUT) null;
        waveOutSetVolume(handle, (scaled | (scaled << 16)));
    }

    /**
     * Master volume of the currently selected output device. This is what the
     * taskbar tray shows and what the slider drives.
     */
    int systemVolume()
    {
        return deviceVolumePercent(selectedAudioDevice());
    }

    void setSystemVolume(int percent)
    {
        setDeviceVolumePercent(selectedAudioDevice(), percent);
    }

    bool systemMuted()
    {
        return deviceMuted(selectedAudioDevice());
    }

    void setSystemMuted(bool muted)
    {
        setDeviceMuted(selectedAudioDevice(), muted);
    }
}
else
{
    struct AudioDevice
    {
        uint index;
        string name;
    }

    AudioDevice[] audioOutputDevices() { return []; }
    uint selectedAudioDevice() { return 0; }
    void selectAudioDevice(uint index) { }
    int deviceVolumePercent(uint dev) { return 50; }
    void setDeviceVolumePercent(uint dev, int percent) { }
    bool deviceMuted(uint dev) { return false; }
    void setDeviceMuted(uint dev, bool muted) { }
    int systemVolume() { return 50; }
    void setSystemVolume(int percent) { }
    bool systemMuted() { return false; }
    void setSystemMuted(bool muted) { }
}

/** Shut the computer down. Equivalent to `shutdown /s`. */
void systemShutdown()
{
    version (Windows)
        ExitWindowsEx(EWX_SHUTDOWN | EWX_FORCE | EWX_FORCEIFHUNG, 0);
}

/** Restart the computer. Equivalent to `shutdown /r`. */
void systemRestart()
{
    version (Windows)
        ExitWindowsEx(EWX_REBOOT | EWX_FORCE | EWX_FORCEIFHUNG, 0);
}

/** Put the computer to sleep (suspend to RAM). */
void systemSleep()
{
    version (Windows)
        SetSuspendState(false, true, false);
}

/**
 * Opens a Windows Settings page (the settings button in the Start menu, or a
 * tray panel shortcut). Defaults to the Settings home page.
 */
void systemOpenSettings(string page = "ms-settings:")
{
    version (Windows)
    {
        import core.sys.windows.shellapi : ShellExecuteW;
        import core.sys.windows.winuser : SW_SHOWNORMAL;
        import std.utf : toUTF16z;
        ShellExecuteW(null, "open"w.ptr, page.toUTF16z, null, null,
            SW_SHOWNORMAL);
    }
}

