module auroradesktop.wlan;

import core.sys.windows.windows : BOOL, DWORD, HANDLE, PVOID, WCHAR, LPWSTR;

/**
 * Minimal hand-written WLAN API (wlanapi.dll) bindings plus a safe query /
 * connect layer for the desktop WiFi panel.
 *
 * druntime ships no wlanapi bindings, so the exact C layouts from the Windows
 * SDK are re-declared here (64-bit). Every entry point is guarded: any API
 * failure degrades to a harmless empty result and the caller falls back to a
 * plain connected/disconnected indicator. Nothing here may throw out.
 */

// ------------------------------------------------------------------ SDK types
align(1) struct WlanGuid
{
    uint Data1;
    ushort Data2;
    ushort Data3;
    ubyte[8] Data4;
}
static assert(WlanGuid.sizeof == 16);

align(1) struct Dot11Ssid
{
    uint uSSIDLength;
    ubyte[32] ucSSID;
}
static assert(Dot11Ssid.sizeof == 36);

enum WlanInterfaceState : uint
{
    notReady = 0,
    connected = 1,
    adhocFormed = 2,
    disconnecting = 3,
    disconnected = 4,
    associating = 5,
    discovering = 6,
    authenticating = 7
}

align(1) struct WlanInterfaceInfo
{
    WlanGuid InterfaceGuid;
    WCHAR[256] strInterfaceDescription;
    WlanInterfaceState isState;
}
static assert(WlanInterfaceInfo.sizeof == 532);

align(1) struct WlanInterfaceList
{
    DWORD dwNumberOfItems;
    DWORD dwIndex;
    WlanInterfaceInfo[1] InterfaceInfo;
}

enum Dot11BssType : uint
{
    infrastructure = 1,
    independent = 2,
    any = 3
}

align(1) struct WlanAvailableNetwork
{
    WCHAR[256] strProfileName;
    Dot11Ssid dot11Ssid;
    Dot11BssType dot11BssType;
    uint uNumberOfBssids;
    BOOL bNetworkConnectable;
    DWORD wlanNotConnectableReason;
    uint uNumberOfPhyTypes;
    uint[8] dot11PhyTypes;
    BOOL bMorePhyTypes;
    DWORD wlanSignalQuality; // 0..100
    BOOL bSecurityEnabled;
    uint dot11DefaultAuthAlgorithm;
    uint dot11DefaultCipherAlgorithm;
    DWORD dwFlags;
    DWORD dwReserved;
}
static assert(WlanAvailableNetwork.sizeof == 628);

align(1) struct WlanAvailableNetworkList
{
    DWORD dwNumberOfItems;
    DWORD dwIndex;
    WlanAvailableNetwork[1] Network;
}

align(1) struct WlanAssociationAttributes
{
    Dot11Ssid dot11Ssid;
    Dot11BssType dot11BssType;
    ubyte[6] dot11Bssid;
    uint dot11PhyType;
    uint uDot11PhyIndex;
    DWORD wlanSignalQuality;
    uint ulRxRate;
    uint ulTxRate;
}

align(1) struct WlanConnectionAttributes
{
    WlanInterfaceState isState;
    uint wlanConnectionMode;
    WCHAR[256] strProfileName;
    WlanAssociationAttributes wlanAssociationAttributes;
    uint bSecurityEnabled;
    uint bOneXEnabled;
    uint dot11AuthAlgorithm;
    uint dot11CipherAlgorithm;
}

enum WlanConnectionMode : uint
{
    profile = 0,
    temporaryProfile = 1,
    discoverySecure = 2,
    discoveryUnsecure = 3,
    auto_ = 4,
    invalid = 5
}

// The real SDK struct: mode (4 bytes), then a 4-byte pad to align the
// following pointers on x64, then three 8-byte pointers, then two 4-byte
// values -> 40 bytes total. strProfile is an LPCWSTR (a pointer), NOT a
// fixed array.
align(1) struct WlanConnectionParameters
{
    WlanConnectionMode wlanConnectionMode;
    const(wchar)* strProfile;
    const(Dot11Ssid)* pDot11Ssid;
    const(void)* pDesiredBssidList;
    Dot11BssType dot11BssType;
    DWORD dwFlags;
}
static assert(WlanConnectionParameters.sizeof == 40);

enum WLAN_INTF_OPCODE_CURRENT_CONNECTION = 7;

version (Windows)
{
    extern (Windows) nothrow DWORD WlanOpenHandle(DWORD dwClientVersion,
        PVOID pReserved, DWORD* pdwNegotiatedVersion, HANDLE* phClientHandle);
    extern (Windows) nothrow DWORD WlanCloseHandle(HANDLE hClientHandle, PVOID pReserved);
    extern (Windows) nothrow DWORD WlanEnumInterfaces(HANDLE hClientHandle,
        PVOID pReserved, WlanInterfaceList** ppInterfaceList);
    extern (Windows) nothrow DWORD WlanGetAvailableNetworkList(HANDLE hClientHandle,
        const(WlanGuid)* pInterfaceGuid, DWORD dwFlags, PVOID pReserved,
        WlanAvailableNetworkList** ppAvailableNetworkList);
    extern (Windows) nothrow DWORD WlanQueryInterface(HANDLE hClientHandle,
        const(WlanGuid)* pInterfaceGuid, int OpCode, PVOID pReserved,
        DWORD* pdwDataSize, void** ppData, void* pWlanOpcodeValueType);
    extern (Windows) nothrow DWORD WlanConnect(HANDLE hClientHandle,
        const(WlanGuid)* pInterfaceGuid,
        const(WlanConnectionParameters)* pConnectionParameters, PVOID pReserved);
    extern (Windows) nothrow DWORD WlanScan(HANDLE hClientHandle,
        const(WlanGuid)* pInterfaceGuid, const(Dot11Ssid)* pDot11Ssid,
        PVOID pReserved);
    extern (Windows) nothrow DWORD WlanDisconnect(HANDLE hClientHandle,
        const(WlanGuid)* pInterfaceGuid, PVOID pReserved);
    extern (Windows) nothrow void WlanFreeMemory(PVOID pMemory);
    extern (Windows) nothrow DWORD WlanReasonCodeToString(DWORD wlanReasonCode,
        LPWSTR buffer, DWORD bufferSize);
}

// -------------------------------------------------------------------- model
/** One visible network with its live signal quality and (optional) profile. */
struct WifiNetwork
{
    string ssid;
    string profile;
    uint signal; // 0..100
    bool secured;
    bool connectable;
}

/** Snapshot shown by the WiFi panel. `available` is false without WLAN. */
struct WifiState
{
    bool available;
    string interfaceDescription;
    bool connected;
    string ssid;
    string profile;
    uint signal;
    WifiNetwork[] networks;
}

/** Outcome of a connect attempt, so the panel can say WHY it failed. */
struct WifiConnectResult
{
    bool ok;
    string message;
}

// ------------------------------------------------------------------ helpers
private string ssidToString(const(ubyte)[] bytes) nothrow
{
    try
    {
        char[] result;
        foreach (b; bytes)
        {
            if (b >= 0x20 && b < 0x7F)
                result ~= cast(char) b;
            else
                result ~= '?';
        }
        return result.idup;
    }
    catch (Exception)
    {
        return "";
    }
}

private string wcharToString(const(WCHAR)[] value) nothrow
{
    try
    {
        size_t length;
        while (length < value.length && value[length] != 0)
            ++length;
        import std.utf : toUTF8;
        return toUTF8(value[0 .. length]);
    }
    catch (Exception)
    {
        return "";
    }
}

version (Windows)
{
    // Return the active (connected, else first) interface, or null.
    private WlanInterfaceInfo* activeInterface(WlanInterfaceList* list)
        @trusted nothrow
    {
        if (list is null || list.dwNumberOfItems == 0) return null;
        WlanInterfaceInfo* fallback;
        foreach (i; 0 .. list.dwNumberOfItems)
        {
            auto candidate = cast(WlanInterfaceInfo*) (cast(ubyte*) list +
                WlanInterfaceList.InterfaceInfo.offsetof +
                i * WlanInterfaceInfo.sizeof);
            if (fallback is null) fallback = candidate;
            if (candidate.isState == WlanInterfaceState.connected)
                return candidate;
        }
        return fallback;
    }

    WifiState queryWifi() nothrow
    {
        // Must be FAST and never block the UI thread. WlanGetAvailableNetworkList
        // returns a cached list (which right after an open shows only the
        // connected network), but the caller does the "wait for the scan to
        // populate" work via a background timer - see DesktopRoot.refreshWifiPanel
        // which re-queries on ticks. A single non-blocking query here keeps the
        // tray button instant to open.
        HANDLE client;
        DWORD negotiated;
        if (WlanOpenHandle(2, null, &negotiated, &client) != 0)
            return WifiState.init;
        scope (exit) WlanCloseHandle(client, null);

        WlanInterfaceList* list;
        if (WlanEnumInterfaces(client, null, &list) != 0 || list is null)
            return WifiState.init;
        scope (exit) WlanFreeMemory(list);
        auto iface = activeInterface(list);
        if (iface is null) return WifiState.init;

        return queryWifiWithClient(client, iface);
    }

    /**
     * Kick an active WLAN scan (non-blocking) so the cached available-network
     * list populates with the surrounding networks. The caller re-queries
     * `queryWifi()` on a background timer; this just triggers Windows to scan.
     * Returns false if the scan could not even be requested.
     */
    bool kickWifiScan() nothrow
    {
        HANDLE client;
        DWORD negotiated;
        if (WlanOpenHandle(2, null, &negotiated, &client) != 0)
            return false;
        scope (exit) WlanCloseHandle(client, null);

        WlanInterfaceList* list;
        if (WlanEnumInterfaces(client, null, &list) != 0 || list is null)
            return false;
        scope (exit) WlanFreeMemory(list);
        auto iface = activeInterface(list);
        if (iface is null) return false;

        // Passing a null SSID scans all channels; the returned code is best
        // effort (some drivers return ERROR_INVALID_PARAMETER yet still scan).
        WlanScan(client, &iface.InterfaceGuid, null, null);
        return true;
    }

    // Query the connected state + available network list on a caller-owned,
    // still-open client handle (the native handle is what lets the cached
    // scan list refresh across calls). The extern WLAN calls may throw, so
    // keep them inside a try/catch and never propagate.
    private WifiState queryWifiWithClient(HANDLE client,
        WlanInterfaceInfo* iface) nothrow
    {
        WifiState state;
        try
        {
            state.available = true;
            state.interfaceDescription =
                wcharToString(iface.strInterfaceDescription[]);

            DWORD dataSize;
            void* data;
            if (WlanQueryInterface(client, &iface.InterfaceGuid,
                    WLAN_INTF_OPCODE_CURRENT_CONNECTION, null, &dataSize,
                    &data, null) == 0 && data !is null)
            {
                scope (exit) WlanFreeMemory(data);
                auto attrs = cast(WlanConnectionAttributes*) data;
                state.connected =
                    attrs.isState == WlanInterfaceState.connected;
                state.profile = wcharToString(attrs.strProfileName[]);
                immutable ssidLen =
                    attrs.wlanAssociationAttributes.dot11Ssid.uSSIDLength;
                if (ssidLen <= 32)
                    state.ssid = ssidToString(
                        attrs.wlanAssociationAttributes.dot11Ssid.ucSSID[0 .. ssidLen]);
                state.signal =
                    attrs.wlanAssociationAttributes.wlanSignalQuality;
            }

            WlanAvailableNetworkList* nets;
            if (WlanGetAvailableNetworkList(client, &iface.InterfaceGuid, 0,
                    null, &nets) == 0 && nets !is null)
            {
                scope (exit) WlanFreeMemory(nets);
                foreach (i; 0 .. nets.dwNumberOfItems)
                {
                    auto net = cast(WlanAvailableNetwork*) (cast(ubyte*) nets +
                        WlanAvailableNetworkList.Network.offsetof +
                        i * WlanAvailableNetwork.sizeof);
                    immutable ssidLen = net.dot11Ssid.uSSIDLength;
                    if (ssidLen == 0 || ssidLen > 32)
                        continue;
                    WifiNetwork entry;
                    entry.ssid =
                        ssidToString(net.dot11Ssid.ucSSID[0 .. ssidLen]);
                    if (entry.ssid.length == 0)
                        continue;
                    entry.profile = wcharToString(net.strProfileName[]);
                    entry.signal = net.wlanSignalQuality > 100 ? 100 :
                        net.wlanSignalQuality;
                    entry.secured = net.bSecurityEnabled != 0;
                    entry.connectable = net.bNetworkConnectable != 0;
                    mergeNetwork(state.networks, entry);
                }
                // Strongest first, like the Windows flyout.
                import std.algorithm : sort;
                state.networks.sort!((a, b) => a.signal > b.signal);
            }
        }
        catch (Exception)
        {
            state.available = false;
        }
        return state;
    }
    /**
     * Merge a scanned network sighting into the list. The same SSID can be
     * reported multiple times (different BSSIDs, some with a saved profile and
     * some without), so we must NOT let a profile-less high-signal duplicate
     * clobber an entry that has a saved profile - otherwise connecting would
     * fail. Keep the stronger signal and the presence of a profile / saved-ness.
     */
    private void mergeNetwork(ref WifiNetwork[] networks, ref WifiNetwork entry)
    {
        foreach (ref existing; networks)
        {
            if (existing.ssid != entry.ssid) continue;
            if (entry.signal > existing.signal)
                existing.signal = entry.signal;
            // A profile (for secured/connectable networks) is what lets us
            // reconnect; prefer it over a blank sighting.
            if (existing.profile.length == 0 && entry.profile.length > 0)
                existing.profile = entry.profile;
            if (entry.connectable)
                existing.connectable = true;
            existing.secured = existing.secured && entry.secured;
            return;
        }
        networks ~= entry;
    }

    /**
     * Connect to a visible network. Prefers a saved profile (works for secured
     * networks that Windows already knows); open networks connect directly by
     * SSID. Returns a human-readable message so the panel can explain a refusal.
     */
    WifiConnectResult connectWifiNetwork(string ssid, string profile, bool secured)
        nothrow
    {
        try
        {
            HANDLE client;
            DWORD negotiated;
            auto hr = WlanOpenHandle(2, null, &negotiated, &client);
            if (hr != 0)
                return WifiConnectResult(false, "WLAN service unavailable");
            scope (exit) WlanCloseHandle(client, null);

            WlanInterfaceList* list;
            if (WlanEnumInterfaces(client, null, &list) != 0 || list is null)
                return WifiConnectResult(false, "No wireless interface");
            scope (exit) WlanFreeMemory(list);

            auto iface = activeInterface(list);
            if (iface is null)
                return WifiConnectResult(false, "No wireless interface");

            WlanConnectionParameters params = WlanConnectionParameters.init;
            wchar[256] profileBuf;   // stable storage for the profile name
            if (profile.length > 0)
            {
                params.wlanConnectionMode = WlanConnectionMode.profile;
                immutable count = profile.length < 255 ? profile.length : 255;
                foreach (i; 0 .. count)
                    profileBuf[i] = cast(wchar) profile[i];
                profileBuf[count] = 0;
                params.strProfile = profileBuf.ptr;
            }
            else
            {
                if (secured)
                    return WifiConnectResult(false,
                        "Cannot join a secured network without a saved profile");
                params.wlanConnectionMode = WlanConnectionMode.temporaryProfile;
                params.dot11BssType = Dot11BssType.infrastructure;
                Dot11Ssid dot11;
                immutable count = ssid.length < 32 ? ssid.length : 32;
                dot11.uSSIDLength = cast(uint) count;
                foreach (i; 0 .. count)
                    dot11.ucSSID[i] = cast(ubyte) ssid[i];
                params.pDot11Ssid = &dot11;
            }

            hr = WlanConnect(client, &iface.InterfaceGuid, &params, null);
            if (hr == 0)
                return WifiConnectResult(true, "Connecting to " ~ ssid);
            return WifiConnectResult(false, wlanErrorText(hr));
        }
        catch (Exception e)
        {
            return WifiConnectResult(false, e.msg);
        }
    }

    bool disconnectWifi() nothrow
    {
        try
        {
            HANDLE client;
            DWORD negotiated;
            if (WlanOpenHandle(2, null, &negotiated, &client) != 0)
                return false;
            scope (exit) WlanCloseHandle(client, null);

            WlanInterfaceList* list;
            if (WlanEnumInterfaces(client, null, &list) != 0 || list is null)
                return false;
            scope (exit) WlanFreeMemory(list);

            auto iface = activeInterface(list);
            if (iface is null) return false;
            return WlanDisconnect(client, &iface.InterfaceGuid, null) == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }

    // Human-readable text for a WLAN error code (ERROR_* / WLAN error).
    private string wlanErrorText(DWORD code) nothrow
    {
        if (code == 0) return "OK";
        try
        {
            wchar[256] buffer;
            if (WlanReasonCodeToString(code, buffer.ptr,
                    cast(DWORD) buffer.length) == 0)
                return wcharToString(buffer[]);
            // Fall back to a generic message with the code.
            import std.conv : to;
            return "WLAN error " ~ code.to!string;
        }
        catch (Exception)
        {
            return "WLAN error";
        }
    }
}
else
{
    WifiState queryWifi() nothrow { return WifiState.init; }
    bool kickWifiScan() nothrow { return false; }
    WifiConnectResult connectWifiNetwork(string ssid, string profile,
        bool secured) nothrow
    {
        return WifiConnectResult(false, "Wi-Fi unsupported on this platform");
    }
    bool disconnectWifi() nothrow { return false; }
}
