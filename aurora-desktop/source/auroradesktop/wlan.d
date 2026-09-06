module auroradesktop.wlan;

import core.sys.windows.windows : BOOL, DWORD, HANDLE, PVOID, WCHAR;

/**
 * Minimal hand-written WLAN API (wlanapi.dll) bindings plus a safe query
 * layer for the desktop WiFi panel.
 *
 * druntime ships no wlanapi bindings, so the exact C layouts from the Windows
 * SDK are re-declared here (64-bit). Every entry point is guarded: any API
 * failure degrades to `available == false` and the caller falls back to the
 * plain connected/disconnected indicator. Nothing here may throw out.
 */

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

align(1) struct WlanConnectionParameters
{
    WlanConnectionMode wlanConnectionMode;
    WCHAR[256] strProfileName;
    const(Dot11Ssid)* pDot11Ssid;
    const(void)* pDesiredBssidList;
    Dot11BssType dot11BssType;
    DWORD dwFlags;
}
// Real C size: 4 + 512 + 4 pad + 8 + 8 + 4 + 4 = 544 (pointers 8-aligned).
static assert(WlanConnectionParameters.sizeof == 544);

enum WLAN_INTF_OPCODE_CURRENT_CONNECTION = 7;

version (Windows)
{
    extern (Windows) DWORD WlanOpenHandle(DWORD dwClientVersion,
        PVOID pReserved, DWORD* pdwNegotiatedVersion, HANDLE* phClientHandle);
    extern (Windows) DWORD WlanCloseHandle(HANDLE hClientHandle, PVOID pReserved);
    extern (Windows) DWORD WlanEnumInterfaces(HANDLE hClientHandle,
        PVOID pReserved, WlanInterfaceList** ppInterfaceList);
    extern (Windows) DWORD WlanGetAvailableNetworkList(HANDLE hClientHandle,
        const(WlanGuid)* pInterfaceGuid, DWORD dwFlags, PVOID pReserved,
        WlanAvailableNetworkList** ppAvailableNetworkList);
    extern (Windows) DWORD WlanQueryInterface(HANDLE hClientHandle,
        const(WlanGuid)* pInterfaceGuid, int OpCode, PVOID pReserved,
        DWORD* pdwDataSize, void** ppData, void* pWlanOpcodeValueType);
    extern (Windows) DWORD WlanConnect(HANDLE hClientHandle,
        const(WlanGuid)* pInterfaceGuid,
        const(WlanConnectionParameters)* pConnectionParameters, PVOID pReserved);
    extern (Windows) DWORD WlanDisconnect(HANDLE hClientHandle,
        const(WlanGuid)* pInterfaceGuid, PVOID pReserved);
    extern (Windows) void WlanFreeMemory(PVOID pMemory);
}

/** One visible network with its live signal quality. */
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
    WifiState queryWifi() nothrow
    {
        WifiState state;
        try
        {
            HANDLE client;
            DWORD negotiated;
            if (WlanOpenHandle(2, null, &negotiated, &client) != 0)
                return state;
            scope (exit) WlanCloseHandle(client, null);

            WlanInterfaceList* list;
            if (WlanEnumInterfaces(client, null, &list) != 0 || list is null)
                return state;
            scope (exit) WlanFreeMemory(list);
            if (list.dwNumberOfItems == 0)
                return state;

            // Prefer a connected interface, else the first one.
            WlanInterfaceInfo* iface;
            foreach (i; 0 .. list.dwNumberOfItems)
            {
                auto candidate = cast(WlanInterfaceInfo*) (cast(ubyte*) list +
                    WlanInterfaceList.InterfaceInfo.offsetof +
                    i * WlanInterfaceInfo.sizeof);
                if (iface is null) iface = candidate;
                if (candidate.isState == WlanInterfaceState.connected)
                {
                    iface = candidate;
                    break;
                }
            }
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
                state.profile =
                    wcharToString(attrs.strProfileName[]);
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
                    // Keep the strongest sighting of each SSID.
                    bool merged;
                    foreach (ref existing; state.networks)
                    {
                        if (existing.ssid == entry.ssid)
                        {
                            if (entry.signal > existing.signal)
                                existing = entry;
                            merged = true;
                            break;
                        }
                    }
                    if (!merged)
                        state.networks ~= entry;
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
     * Connects to a visible network. Uses the saved profile when one exists;
     * open networks connect directly by SSID. Secured networks without a
     * saved profile cannot be joined from here (Windows needs credentials).
     */
    bool connectWifiNetwork(string ssid, string profile, bool secured) nothrow
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
            if (list.dwNumberOfItems == 0)
                return false;
            auto iface = cast(WlanInterfaceInfo*) (cast(ubyte*) list +
                WlanInterfaceList.InterfaceInfo.offsetof);

            WlanConnectionParameters params;
            if (profile.length > 0)
            {
                params.wlanConnectionMode = WlanConnectionMode.profile;
                immutable count = profile.length < 255 ? profile.length : 255;
                foreach (i; 0 .. count)
                    params.strProfileName[i] = profile[i];
                params.strProfileName[count] = 0;
            }
            else
            {
                if (secured)
                    return false;
                params.wlanConnectionMode =
                    WlanConnectionMode.temporaryProfile;
                params.dot11BssType = Dot11BssType.infrastructure;
                // SSID bytes are ASCII-printable here (panel-built strings).
                Dot11Ssid dot11;
                immutable count = ssid.length < 32 ? ssid.length : 32;
                dot11.uSSIDLength = cast(uint) count;
                foreach (i; 0 .. count)
                    dot11.ucSSID[i] = cast(ubyte) ssid[i];
                params.pDot11Ssid = &dot11;
                return WlanConnect(client, &iface.InterfaceGuid, &params,
                    null) == 0;
            }
            return WlanConnect(client, &iface.InterfaceGuid, &params,
                null) == 0;
        }
        catch (Exception)
        {
            return false;
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
            if (list.dwNumberOfItems == 0)
                return false;
            auto iface = cast(WlanInterfaceInfo*) (cast(ubyte*) list +
                WlanInterfaceList.InterfaceInfo.offsetof);
            return WlanDisconnect(client, &iface.InterfaceGuid, null) == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
else
{
    WifiState queryWifi() nothrow { return WifiState.init; }
    bool connectWifiNetwork(string ssid, string profile, bool secured) nothrow
    {
        return false;
    }
    bool disconnectWifi() nothrow { return false; }
}
