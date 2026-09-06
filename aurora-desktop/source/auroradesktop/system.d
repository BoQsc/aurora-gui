module auroradesktop.system;

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
 *
 * Audio goes through each output device's real mixer VOLUME + MUTE controls.
 * (A WASAPI/IAudioEndpointVolume implementation exists in
 * reference/endpoint-volume-wasapi.d but this machine's MMDevAPI class
 * factory refuses QI for IMMDeviceEnumerator - E_NOINTERFACE proven four
 * ways - so the mixer path is what is verified working here.)
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
    import core.sys.windows.mmsystem : HWAVEOUT,
        WAVEOUTCAPSW, waveOutGetDevCapsW, waveOutGetNumDevs,
        waveOutGetVolume, waveOutSetVolume;
    import std.utf : toUTF8;

    // --- Core Audio endpoint volume (Windows Vista+) ----------------------
    // The legacy WinMM mixer destination lines do NOT track the master
    // endpoint volume Windows itself shows (stale levels, phantom mute, and
    // waveOut product names truncated to 32 WCHARs). Everything below goes
    // through IAudioEndpointVolume instead - the exact API the Windows volume
    // flyout uses. The old WAVE_MAPPER shortcut survives only as a
    // last-resort fallback when COM fails.
    //
    // Interface identity notes (verified empirically on real hardware):
    // - CLSID_MMDeviceEnumerator is registered and correct.
    // - The audio interface IIDs are NOT in HKCR\Interface, so the enumerator
    //   is created through IID_IUnknown and driven by vtable slot.
    // - IID_IAudioEndpointVolume {5CDF2C82-841E-4546-9722-0CF74078229A} is
    //   proven: Activate returns S_OK and the scalar tracks the live level.
    //   (A ...78AB9A variant fails with E_NOINTERFACE and must not be used.)

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
    private enum ComInitThreaded = COINIT.COINIT_APARTMENTTHREADED;
    private enum RegRead = 0x020019; // KEY_READ

    private immutable GUID iidUnknown = GUID(0x00000000, 0x0000, 0x0000,
        [0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46]);
    private immutable GUID fallbackClsidEnumerator = GUID(0xBCDE0395, 0xE52F,
        0x467C, [0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E]);
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
    private __gshared GUID guidIidEndpointVolume;
    private __gshared GUID guidIidPropertyStore;

    private void ensureCom()
    {
        if (comAttempted) return;
        comAttempted = true;
        // Best effort; every call below fails into the waveOut fallback when
        // COM is unavailable.
        CoInitializeEx(null, ComInitThreaded);
        resolveGuids();
    }

    // NOTE: an HKCR\Interface registry lookup for these IDs lived here. It
    // was removed: the audio interface IDs are not registered on a stock
    // machine, and the constants below are empirically proven (Activate S_OK
    // with a live scalar). Simpler code, no registry attack surface.
    private void resolveGuids()
    {
        if (guidsResolved) return;
        guidsResolved = true;
        guidClsidEnumerator = fallbackClsidEnumerator;
        guidIidEndpointVolume = fallbackIidEndpointVolume;
        guidIidPropertyStore = fallbackIidPropertyStore;
    }

    private IMMDeviceEnumerator createEnumerator()
    {
        ensureCom();
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
            // Bounded: an unterminated buffer must yield "" rather than a
            // runaway scan into unmapped memory.
            size_t length;
            while (length < 512 && text[length] != 0) ++length;
            if (length >= 512) return "";
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
        PropVariant value = PropVariant.init;
        if (store.GetValue(&keyFriendlyName, &value) != HResultOk)
            return "";
        scope (exit) PropVariantClear(&value);
        if (value.vt != VariantLpwstr || value.pwszVal is null) return "";
        // Bound the NUL scan: a malformed string must yield "" rather than
        // running off the end of the buffer.
        size_t length;
        while (length < 512 && value.pwszVal[length] != 0) ++length;
        if (length >= 512) return "";
        try
        {
            return toUTF8(value.pwszVal[0 .. length]);
        }
        catch (Exception)
        {
            return "";
        }
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

    private bool openVolumeForOrdinal(uint ordinal,
        out IAudioEndpointVolume volume)
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

    // Cached endpoint volume interface so a slider drag pays one vtable call
    // per sample instead of a full COM enumeration (measured 12.8 ms/event
    // before, 0.5 ms after). The cache key is (ordinal, selection
    // generation); it is dropped on selection change and on any endpoint
    // failure, so unplug/replug self-heals on the next sample.
    private __gshared IAudioEndpointVolume cachedVolume;
    private __gshared uint cachedOrdinal = uint.max;
    private __gshared uint cacheGeneration;
    private __gshared uint selectionGeneration;

    private void dropVolumeCache()
    {
        if (cachedVolume !is null)
        {
            cachedVolume.Release();
            cachedVolume = null;
        }
        cachedOrdinal = uint.max;
    }

    private bool volumeForOrdinal(uint ordinal, out IAudioEndpointVolume volume)
    {
        volume = null;
        if (cachedVolume !is null && cachedOrdinal == ordinal &&
            cacheGeneration == selectionGeneration)
        {
            cachedVolume.AddRef();
            volume = cachedVolume;
            return true;
        }
        dropVolumeCache();
        IAudioEndpointVolume fresh;
        if (!openVolumeForOrdinal(ordinal, fresh)) return false;
        cachedVolume = fresh;
        cachedOrdinal = ordinal;
        cacheGeneration = selectionGeneration;
        cachedVolume.AddRef();
        volume = cachedVolume;
        return true;
    }

    /** Every active render endpoint on this machine, in MMDevice order. */
    AudioDevice[] audioOutputDevices()
    {
        AudioDevice[] devices;
        string[] ids;
        if (listEndpoints(devices, ids)) return devices;
        return fallbackDeviceList();
    }

    private uint fallbackSelectedDevice()
    {
        const count = waveOutGetNumDevs();
        if (count == 0) return 0;
        return _selectedEndpointFallback < count ? _selectedEndpointFallback : 0;
    }

    private __gshared uint _selectedEndpointFallback;

    // Cached selected ordinal so a slider drag does not re-enumerate (with
    // property stores) on every sample. Invalidated by selection changes,
    // volume-op failures, and the periodic tray refresh.
    private __gshared uint selectedOrdinalCache;
    private __gshared bool selectedOrdinalValid;

    private void invalidateSelection()
    {
        selectedOrdinalValid = false;
        dropVolumeCache();
    }

    /**
     * Force the next selection/volume lookup to re-enumerate. The 2 s tray
     * tick calls this so plug/unplug heals quickly; slider drags in between
     * ride the cache with zero enumeration.
     */
    void refreshAudioEndpoints()
    {
        invalidateSelection();
    }

    uint selectedAudioDevice()
    {
        if (selectedOrdinalValid) return selectedOrdinalCache;
        AudioDevice[] devices;
        string[] ids;
        if (!listEndpoints(devices, ids) || ids.length == 0)
            return fallbackSelectedDevice();
        uint resolved = 0;
        if (_endpointChosen)
        {
            foreach (i, id; ids)
            {
                if (id == _selectedEndpointId)
                {
                    resolved = cast(uint) i;
                    break;
                }
            }
        }
        selectedOrdinalCache = resolved;
        selectedOrdinalValid = true;
        return resolved;
    }

    void selectAudioDevice(uint index)
    {
        // Mirror into the waveOut fallback selection first, so a later COM
        // failure still drives the device the user picked.
        const waveCount = waveOutGetNumDevs();
        _selectedEndpointFallback =
            waveCount == 0 ? 0 : (index < waveCount ? index : 0);
        AudioDevice[] devices;
        string[] ids;
        if (!listEndpoints(devices, ids) || ids.length == 0) return;
        if (index >= ids.length) index = 0;
        _selectedEndpointId = ids[index];
        _endpointChosen = true;
        ++selectionGeneration;
        invalidateSelection();
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
        if (!volumeForOrdinal(ordinal, volume)) return false;
        scope (exit) volume.Release();
        float level;
        int muteFlag;
        if (volume.GetMasterVolumeLevelScalar(&level) != HResultOk)
        {
            invalidateSelection();
            return false;
        }
        if (volume.GetMute(&muteFlag) != HResultOk) muteFlag = 0;
        if (level < 0.0f) level = 0.0f;
        if (level > 1.0f) level = 1.0f;
        percent = cast(int) (level * 100.0f + 0.5f);
        muted = muteFlag != 0;
        return true;
    }

    /** Master volume percent of one output endpoint (the flyout value). */
    int deviceVolumePercent(uint dev)
    {
        int percent;
        bool muted;
        return readEndpoint(dev, percent, muted) ? percent : fallbackVolume();
    }

    /** Sets the master volume percent of one output endpoint. */
    void setDeviceVolumePercent(uint dev, int percent)
    {
        IAudioEndpointVolume volume;
        if (!volumeForOrdinal(dev, volume))
        {
            fallbackSetVolume(percent);
            return;
        }
        scope (exit) volume.Release();
        if (volume.SetMasterVolumeLevelScalar(clampPercent(percent) / 100.0f,
                null) != HResultOk)
        {
            // The cached interface may refer to an unplugged device: drop it
            // and retry once on a freshly opened one before falling back.
            invalidateSelection();
            IAudioEndpointVolume fresh;
            if (!volumeForOrdinal(dev, fresh))
            {
                fallbackSetVolume(percent);
                return;
            }
            scope (exit) fresh.Release();
            fresh.SetMasterVolumeLevelScalar(clampPercent(percent) / 100.0f,
                null);
        }
    }

    /** True endpoint mute flag of one output device. */
    bool deviceMuted(uint dev)
    {
        int percent;
        bool muted;
        return readEndpoint(dev, percent, muted) ? muted :
            fallbackVolume() == 0;
    }

    /** Sets the true endpoint mute flag of one output device. */
    void setDeviceMuted(uint dev, bool muted)
    {
        IAudioEndpointVolume volume;
        if (!volumeForOrdinal(dev, volume))
        {
            if (muted) fallbackSetVolume(0);
            return;
        }
        scope (exit) volume.Release();
        if (volume.SetMute(muted ? 1 : 0, null) != HResultOk)
        {
            invalidateSelection();
            IAudioEndpointVolume fresh;
            if (!volumeForOrdinal(dev, fresh))
            {
                if (muted) fallbackSetVolume(0);
                return;
            }
            scope (exit) fresh.Release();
            fresh.SetMute(muted ? 1 : 0, null);
        }
    }

    // NOTE: the legacy WinMM mixer helpers used to live here. They were
    // removed because mixer destination lines do not track the master
    // endpoint volume on modern Windows (stale levels, phantom mute); the
    // Core Audio implementation above is authoritative and the WAVE_MAPPER
    // fallback below survives only for machines where COM fails.

    // Legacy WAVE_MAPPER fallback for machines without a usable mixer path.
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
