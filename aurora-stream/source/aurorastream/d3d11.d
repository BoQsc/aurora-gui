module aurorastream.d3d11;

/// Minimal raw D3D11/DXGI COM bindings used by the game-capture render hook
/// and the D3D11 test surface. druntime has no D3D11 declarations, and D
/// `interface` types are not guaranteed to dispatch through the native COM
/// vtable, so every interface here is the classic COM layout: an object struct
/// whose first member is a pointer to a vtable struct of `extern(C)` function
/// pointers. Calling a method resolves the slot position explicitly, exactly
/// how d3d11.dll/dxgi.dll lay their objects out.
///
/// Each vtable struct declares every slot up to the highest one we use; slots
/// we never call are `_slot*` placeholder function pointers so the positions of
/// the real methods stay exact.

import core.sys.windows.windows : BOOL, DWORD, HANDLE, HMODULE, HRESULT,
    HWND, ULONG;
import core.sys.windows.basetyps : GUID;

version (Windows)
{
    // ---- IUnknown ----
    struct IUnknownVtbl
    {
        extern(C) HRESULT function(void*, const GUID*, void**) QueryInterface; // 0
        extern(C) uint function(void*) AddRef; // 1
        extern(C) uint function(void*) Release; // 2
    }

    // ---- IDXGIDeviceSubObject (IUnknown + IDXGIObject + GetDevice) ----
    struct IDXGIDeviceSubObjectVtbl
    {
        extern(C) HRESULT function(void*, const GUID*, void**) QueryInterface; // 0
        extern(C) uint function(void*) AddRef; // 1
        extern(C) uint function(void*) Release; // 2
        extern(C) HRESULT function(void*, const GUID*, uint, const void*) _s3; // 3
        extern(C) HRESULT function(void*, const GUID*, void*) _s4; // 4
        extern(C) HRESULT function(void*, const GUID*, uint*, void*) _s5; // 5
        extern(C) HRESULT function(void*, const GUID*, void**) _s6; // 6
        extern(C) HRESULT function(void*, const GUID*, void**) GetDevice; // 7
    }

    // ---- IDXGISwapChain ----
    struct IDXGISwapChainVtbl
    {
        extern(C) HRESULT function(void*, const GUID*, void**) QueryInterface; // 0
        extern(C) uint function(void*) AddRef; // 1
        extern(C) uint function(void*) Release; // 2
        extern(C) HRESULT function(void*, const GUID*, uint, const void*) _s3; // 3
        extern(C) HRESULT function(void*, const GUID*, void*) _s4; // 4
        extern(C) HRESULT function(void*, const GUID*, uint*, void*) _s5; // 5
        extern(C) HRESULT function(void*, const GUID*, void**) _s6; // 6
        extern(C) HRESULT function(void*, const GUID*, void**) GetDevice; // 7
        extern(C) HRESULT function(void*, uint, uint) Present; // 8
        extern(C) HRESULT function(void*, uint, const GUID*, void**) GetBuffer; // 9
        extern(C) HRESULT function(void*, BOOL, void*) _s10; // 10
        extern(C) HRESULT function(void*, BOOL*, void**) _s11; // 11
        extern(C) HRESULT function(void*, void*) GetDesc; // 12
        extern(C) HRESULT function(void*, uint, uint, uint, int, uint) _s13; // 13
        extern(C) HRESULT function(void*, void*) _s14; // 14
        extern(C) HRESULT function(void*, void**) _s15; // 15
        extern(C) HRESULT function(void*, void*) _s16; // 16
        extern(C) HRESULT function(void*, uint*) _s17; // 17
    }
    struct IDXGISwapChainObj { IDXGISwapChainVtbl* lpVtbl; }

    // ---- IDXGIFactory ----
    struct IDXGIFactoryVtbl
    {
        extern(C) HRESULT function(void*, const GUID*, void**) QueryInterface; // 0
        extern(C) uint function(void*) AddRef; // 1
        extern(C) uint function(void*) Release; // 2
        extern(C) HRESULT function(void*, const GUID*, uint, const void*) _s3; // 3
        extern(C) HRESULT function(void*, const GUID*, void*) _s4; // 4
        extern(C) HRESULT function(void*, const GUID*, uint*, void*) _s5; // 5
        extern(C) HRESULT function(void*, const GUID*, void**) _s6; // 6
        extern(C) HRESULT function(void*, HMODULE, void**) _s7; // 7
        extern(C) HRESULT function(void*, void*, uint, void**) _s8; // 8
        extern(C) HRESULT function(void*, uint, void**) EnumAdapters; // 9
        extern(C) HRESULT function(void*, void*, uint, void**) _s10; // 10
        extern(C) HRESULT function(void*, void*, uint, void*) _s11; // 11
        extern(C) HRESULT function(void*, void*, void*) _s12; // 12
        extern(C) HRESULT function(void*) _s13; // 13
        extern(C) HRESULT function(void*, BOOL*) _s14; // 14
        extern(C) HRESULT function(void*, HWND, uint) _s15; // 15
        extern(C) HRESULT function(void*, void*, const void*, void**) CreateSwapChain; // 16
    }
    struct IDXGIFactoryObj { IDXGIFactoryVtbl* lpVtbl; }

    // ---- D3D11 structs ----
    struct DXGI_RATIONAL { uint Numerator; uint Denominator; }
    struct DXGI_SAMPLE_DESC { uint Count; uint Quality; }

    struct DXGI_MODE_DESC
    {
        uint Width;
        uint Height;
        DXGI_RATIONAL RefreshRate;
        uint Format;
        uint ScanlineOrdering;
        uint Scaling;
    }

    struct DXGI_SWAP_CHAIN_DESC
    {
        DXGI_MODE_DESC BufferDesc;
        DXGI_SAMPLE_DESC SampleDesc;
        uint BufferUsage;
        uint BufferCount;
        HWND OutputWindow;
        BOOL Windowed;
        uint SwapEffect;
        uint Flags;
    }

    struct D3D11_TEXTURE2D_DESC
    {
        uint Width;
        uint Height;
        uint MipLevels;
        uint ArraySize;
        uint Format;
        DXGI_SAMPLE_DESC SampleDesc;
        uint Usage;
        uint BindFlags;
        uint CPUAccessFlags;
        uint MiscFlags;
    }

    struct D3D11_RENDER_TARGET_VIEW_DESC
    {
        uint Format;
        uint ViewDimension;
        uint Texture2D_MipSlice;
    }

    struct D3D11_MAPPED_SUBRESOURCE
    {
        void* pData;
        uint RowPitch;
        uint DepthPitch;
    }

    struct D3D11_VIEWPORT
    {
        float TopLeftX;
        float TopLeftY;
        float Width;
        float Height;
        float MinDepth;
        float MaxDepth;
    }

    // ---- ID3D11DeviceChild ----
    struct ID3D11DeviceChildVtbl
    {
        extern(C) HRESULT function(void*, const GUID*, void**) QueryInterface; // 0
        extern(C) uint function(void*) AddRef; // 1
        extern(C) uint function(void*) Release; // 2
        extern(C) void function(void*, void**) GetDevice; // 3
    }

    // ---- ID3D11Device ----
    struct ID3D11DeviceVtbl
    {
        extern(C) HRESULT function(void*, const GUID*, void**) QueryInterface; // 0
        extern(C) uint function(void*) AddRef; // 1
        extern(C) uint function(void*) Release; // 2
        extern(C) HRESULT function(void*, const void*, const void*, void**) _s3; // 3
        extern(C) HRESULT function(void*, const void*, const void*, void**) _s4; // 4
        extern(C) HRESULT function(void*, const D3D11_TEXTURE2D_DESC*, const void*, void**) CreateTexture2D; // 5
        extern(C) HRESULT function(void*, const void*, const void*, void**) _s6; // 6
        extern(C) HRESULT function(void*, void*, const void*, void**) _s7; // 7
        extern(C) HRESULT function(void*, void*, const void*, void**) _s8; // 8
        extern(C) HRESULT function(void*, void*, const D3D11_RENDER_TARGET_VIEW_DESC*, void**) CreateRenderTargetView; // 9
        extern(C) HRESULT function(void*, void*, const void*, void**) _s10; // 10
        extern(C) HRESULT function(void*, const void*, uint, const void*, size_t, void**) _s11; // 11
        extern(C) HRESULT function(void*, const void*, size_t, void*, void**) _s12; // 12
        extern(C) HRESULT function(void*, const void*, size_t, void*, void**) _s13; // 13
        extern(C) HRESULT function(void*, const void*, size_t, void*, const void*, uint, const uint*, uint, uint, void**) _s14; // 14
        extern(C) HRESULT function(void*, const void*, size_t, void*, void**) _s15; // 15
        extern(C) HRESULT function(void*, const void*, size_t, void*, void**) _s16; // 16
        extern(C) HRESULT function(void*, const void*, size_t, void*, void**) _s17; // 17
        extern(C) HRESULT function(void*, const void*, size_t, void*, void**) _s18; // 18
        extern(C) HRESULT function(void*, void**) _s19; // 19
        extern(C) HRESULT function(void*, const void*, void**) _s20; // 20
        extern(C) HRESULT function(void*, const void*, void**) _s21; // 21
        extern(C) HRESULT function(void*, const void*, void**) _s22; // 22
        extern(C) HRESULT function(void*, const void*, void**) _s23; // 23
        extern(C) HRESULT function(void*, const void*, void**) _s24; // 24
        extern(C) HRESULT function(void*, const void*, void**) _s25; // 25
        extern(C) HRESULT function(void*, const void*, void**) _s26; // 26
        extern(C) HRESULT function(void*, uint, void**) _s27; // 27
        extern(C) HRESULT function(void*, HANDLE, const GUID*, void**) _s28; // 28
        extern(C) HRESULT function(void*, uint, uint*) _s29; // 29
        extern(C) HRESULT function(void*, uint, uint, uint*) _s30; // 30
        extern(C) HRESULT function(void*, void*) _s31; // 31
        extern(C) HRESULT function(void*, const void*, void*, void*, uint*, void*, uint*, void*, uint*) _s32; // 32
        extern(C) HRESULT function(void*, uint, void*, uint) _s33; // 33
        extern(C) HRESULT function(void*, const GUID*, uint*, void*) _s34; // 34
        extern(C) HRESULT function(void*, const GUID*, uint, const void*) _s35; // 35
        extern(C) HRESULT function(void*, const GUID*, void*) _s36; // 36
        extern(C) uint function(void*) _s37; // 37
        extern(C) void function(void*, void**) GetImmediateContext; // 38
        extern(C) uint function(void*, uint) _s39; // 39
        extern(C) uint function(void*) _s40; // 40
    }
    struct ID3D11DeviceObj { ID3D11DeviceVtbl* lpVtbl; }

    // ---- ID3D11DeviceContext ----
    struct ID3D11DeviceContextVtbl
    {
        extern(C) HRESULT function(void*, const GUID*, void**) QueryInterface; // 0
        extern(C) uint function(void*) AddRef; // 1
        extern(C) uint function(void*) Release; // 2
        extern(C) void function(void*, void**) GetDevice; // 3
        extern(C) HRESULT function(void*, const GUID*, uint*, void*) _s4; // 4
        extern(C) HRESULT function(void*, const GUID*, uint, const void*) _s5; // 5
        extern(C) HRESULT function(void*, const GUID*, void*) _s6; // 6
        extern(C) void function(void*, uint, uint, void**) _s7; // 7
        extern(C) void function(void*, uint, uint, void**) _s8; // 8
        extern(C) void function(void*, void*, void**, uint) _s9; // 9
        extern(C) void function(void*, uint, uint, void**) _s10; // 10
        extern(C) void function(void*, void*, void**, uint) _s11; // 11
        extern(C) void function(void*, uint, uint, int) _s12; // 12
        extern(C) void function(void*, uint, uint) _s13; // 13
        extern(C) HRESULT function(void*, void*, uint, uint, uint, void*) Map; // 14
        extern(C) void function(void*, void*, uint) Unmap; // 15
        extern(C) void function(void*, uint, uint, void**) _s16; // 16
        extern(C) void function(void*, void*) _s17; // 17
        extern(C) void function(void*, uint, uint, void**, const uint*, const uint*) _s18; // 18
        extern(C) void function(void*, void*, uint, uint) _s19; // 19
        extern(C) void function(void*, uint, uint, uint, int, uint) _s20; // 20
        extern(C) void function(void*, uint, uint, uint, uint) _s21; // 21
        extern(C) void function(void*, uint, uint, void**) _s22; // 22
        extern(C) void function(void*, void*, void**, uint) _s23; // 23
        extern(C) void function(void*, uint) _s24; // 24
        extern(C) void function(void*, uint, uint, void**) _s25; // 25
        extern(C) void function(void*, uint, uint, void**) _s26; // 26
        extern(C) void function(void*, void*) _s27; // 27
        extern(C) void function(void*, void*) _s28; // 28
        extern(C) HRESULT function(void*, void*, void*, uint, uint) _s29; // 29
        extern(C) void function(void*, void*, BOOL) _s30; // 30
        extern(C) void function(void*, uint, uint, void**) _s31; // 31
        extern(C) void function(void*, uint, uint, void**) _s32; // 32
        extern(C) void function(void*, uint, void**, void*) OMSetRenderTargets; // 33
        extern(C) void function(void*, uint, void**, void*, uint, uint, void**, const uint*) _s34; // 34
        extern(C) void function(void*, void*, const float*, uint) _s35; // 35
        extern(C) void function(void*, void*, uint) _s36; // 36
        extern(C) void function(void*, uint, void**, const uint*) _s37; // 37
        extern(C) void function(void*) _s38; // 38
        extern(C) void function(void*, void*, uint) _s39; // 39
        extern(C) void function(void*, void*, uint) _s40; // 40
        extern(C) void function(void*, uint, uint, uint) _s41; // 41
        extern(C) void function(void*, void*, uint) _s42; // 42
        extern(C) void function(void*, void*) _s43; // 43
        extern(C) void function(void*, uint, const D3D11_VIEWPORT*) RSSetViewports; // 44
        extern(C) void function(void*, uint, const void*) _s45; // 45
        extern(C) void function(void*, void*, uint, uint, uint, uint, void*, uint, const void*) _s46; // 46
        extern(C) void function(void*, void*, void*) CopyResource; // 47
        extern(C) void function(void*, void*, uint, const void*, const void*, uint, uint) _s48; // 48
        extern(C) void function(void*, void*, uint, void*) _s49; // 49
        extern(C) void function(void*, void*, const float*) ClearRenderTargetView; // 50
        extern(C) void function(void*, void*, const uint*) _s51; // 51
        extern(C) void function(void*, void*, const float*) _s52; // 52
        extern(C) void function(void*, void*, uint, float, ubyte) _s53; // 53
        extern(C) void function(void*, void*) _s54; // 54
        extern(C) void function(void*, void*, float) _s55; // 55
        extern(C) void function(void*, void*, uint, void*, uint, uint) _s56; // 56
        extern(C) void function(void*, void*, BOOL) _s57; // 57
    }
    struct ID3D11DeviceContextObj { ID3D11DeviceContextVtbl* lpVtbl; }

    // ---- D3D11CreateDevice / D3D11CreateDeviceAndSwapChain (loaded at runtime
    // via GetProcAddress; only the type is declared here) ----
    alias D3D11CreateDeviceFn = extern(C) HRESULT function(void* pAdapter,
        uint DriverType, HMODULE Software, uint Flags,
        const uint* pFeatureLevels, uint FeatureLevels, uint SDKVersion,
        void** ppDevice, uint* pFeatureLevel, void** ppImmediateContext);
    alias D3D11CreateDeviceAndSwapChainFn = extern(C) HRESULT function(
        void* pAdapter, uint DriverType, HMODULE Software, uint Flags,
        const uint* pFeatureLevels, uint FeatureLevels, uint SDKVersion,
        const void* pSwapChainDesc, void** ppSwapChain, void** ppDevice,
        uint* pFeatureLevel, void** ppImmediateContext);
}

version (Windows)
{
    enum D3D11_SDK_VERSION = 7;
    enum D3D_DRIVER_TYPE_HARDWARE = 1;
    enum D3D_DRIVER_TYPE_WARP = 5;
    enum D3D11_CREATE_DEVICE_BGRA_SUPPORT = 0x20;
    enum D3D_FEATURE_LEVEL_11_0 = 0xb000;
    enum D3D11_BIND_RENDER_TARGET = 0x2;
    enum D3D11_CPU_ACCESS_READ = 0x20000;
    enum D3D11_MAP_READ = 1;
    enum D3D11_RTV_DIMENSION_TEXTURE2D = 4;
    enum D3D11_USAGE_DEFAULT = 0;
    enum D3D11_USAGE_STAGING = 3;
    enum DXGI_USAGE_RENDER_TARGET_OUTPUT = 0x20;
    enum DXGI_FORMAT_R8G8B8A8_UNORM = 28;
    enum DXGI_FORMAT_B8G8R8A8_UNORM = 87;
    enum DXGI_SWAP_EFFECT_DISCARD = 0;
    enum DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH = 2;

    immutable GUID IID_IDXGIFactory = GUID(0x7b7166ec, 0x21c7, 0x44ae,
        [0xb2, 0x1a, 0xc9, 0xae, 0x32, 0x1a, 0xe3, 0x69]);
    immutable GUID IID_ID3D11Texture2D = GUID(0x6f15aaf2, 0xd208, 0x4e89,
        [0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c]);
    immutable GUID IID_IDXGISwapChain = GUID(0x310d36a0, 0xd2e7, 0x4c0a,
        [0xaa, 0x04, 0x6a, 0x9d, 0x23, 0xb8, 0x88, 0x6a]);
    immutable GUID IID_ID3D11Device = GUID(0xdb6f6ddb, 0xac77, 0x4e88,
        [0x82, 0x53, 0x81, 0x9d, 0xf9, 0xbb, 0xf1, 0x40]);
}
