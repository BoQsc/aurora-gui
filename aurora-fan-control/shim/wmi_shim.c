/* wmi_shim.c -- thin C wrapper over the real WBEM interfaces (wbemcli.h).
 *
 * Built with MinGW-w64 (which ships wbemcli.h and libwbemuuid.a) into
 * wmi_shim.dll, then loaded at runtime by the D front ends. Using the SDK
 * header guarantees the IWbemClassObject vtable layout, unlike a hand-declared
 * interface.
 *
 * Notes learned the hard way:
 *   - IWbemServices::GetObject/ExecMethod take BSTR arguments (length
 *     prefixed); plain wide-string literals make the marshaller mis-read them.
 *   - Out-only methods have no in-signature; WMI still wants a non-NULL
 *     in-params object, so one is spawned from the out-signature.
 *   - Methods are invoked on the class path, then on the instance path
 *     (LENOVO_GAMEZONE_DATA.InstanceName="ACPI\\PNP0C14\\GMZN_0"); the class
 *     path alone returns WBEM_E_INVALID_PARAMETER on this model.
 *   - CoSetProxyBlanket must be called on IWbemServices after ConnectServer, or
 *     every call fails with access denied even when elevated.
 *   - Reaching the instance requires Administrator rights.
 *
 * Exported C API (0 on success, else an HRESULT):
 *   int  fc_open(void** outDev);
 *   void fc_close(void* dev);
 *   int  fc_read(void* dev, const wchar_t* method, unsigned* outValue);
 *   int  fc_write(void* dev, const wchar_t* method, unsigned value);
 */

#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <oleauto.h>
#include <wbemidl.h>

#define EXPORT __declspec(dllexport)

typedef struct {
    IWbemServices* svc;
    int comInit;
} FcDevice;

static const wchar_t* CLASS_NAME = L"LENOVO_GAMEZONE_DATA";
static const wchar_t* DATA_NAME  = L"Data";

static HRESULT get_instance_path(IWbemServices* svc, BSTR* outPath);

EXPORT int fc_open(void** outDev)
{
    if (!outDev) return (int)E_POINTER;
    *outDev = NULL;

    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    int comInit = (hr == S_OK || hr == S_FALSE);

    IWbemLocator* loc = NULL;
    hr = CoCreateInstance(&CLSID_WbemLocator, NULL, CLSCTX_INPROC_SERVER,
                          &IID_IWbemLocator, (void**)&loc);
    if (FAILED(hr)) return (int)hr;

    BSTR ns = SysAllocString(L"ROOT\\WMI");
    IWbemServices* svc = NULL;
    hr = loc->lpVtbl->ConnectServer(loc, ns, NULL, NULL, NULL, 0, NULL, NULL, &svc);
    SysFreeString(ns);
    loc->lpVtbl->Release(loc);
    if (FAILED(hr)) return (int)hr;

    /* Required: set the proxy security blanket, otherwise WMI calls fail with
     * access denied even when elevated. */
    hr = CoSetProxyBlanket((IUnknown*)svc, RPC_C_AUTHN_WINNT, RPC_C_AUTHZ_NONE, NULL,
                           RPC_C_AUTHN_LEVEL_CALL, RPC_C_IMP_LEVEL_IMPERSONATE, NULL, EOAC_NONE);
    if (FAILED(hr)) { svc->lpVtbl->Release(svc); return (int)hr; }

    FcDevice* d = (FcDevice*)CoTaskMemAlloc(sizeof(FcDevice));
    if (!d) { svc->lpVtbl->Release(svc); return (int)E_OUTOFMEMORY; }
    d->svc = svc;
    d->comInit = comInit;
    *outDev = d;
    return 0;
}

EXPORT void fc_close(void* dev)
{
    FcDevice* d = (FcDevice*)dev;
    if (!d) return;
    if (d->svc) d->svc->lpVtbl->Release(d->svc);
    if (d->comInit) CoUninitialize();
    CoTaskMemFree(d);
}

/* Returns the first instance's __RELPATH (caller frees the BSTR). */
static HRESULT get_instance_path(IWbemServices* svc, BSTR* outPath)
{
    *outPath = NULL;
    BSTR lang = SysAllocString(L"WQL");
    BSTR query = SysAllocString(L"SELECT * FROM LENOVO_GAMEZONE_DATA");
    IEnumWbemClassObject* pEnum = NULL;
    HRESULT hr = svc->lpVtbl->ExecQuery(svc, lang, query,
        WBEM_FLAG_FORWARD_ONLY | WBEM_FLAG_RETURN_IMMEDIATELY, NULL, &pEnum);
    SysFreeString(lang);
    SysFreeString(query);
    if (FAILED(hr)) return hr;

    IWbemClassObject* obj = NULL;
    ULONG n = 0;
    hr = pEnum->lpVtbl->Next(pEnum, WBEM_INFINITE, 1, &obj, &n);
    pEnum->lpVtbl->Release(pEnum);
    if (FAILED(hr)) return hr;
    if (n == 0 || !obj) return WBEM_E_NOT_FOUND;

    VARIANT v;
    VariantInit(&v);
    hr = obj->lpVtbl->Get(obj, L"__RELPATH", 0, &v, NULL, NULL);
    obj->lpVtbl->Release(obj);
    if (SUCCEEDED(hr) && V_VT(&v) == VT_BSTR && V_BSTR(&v))
        *outPath = SysAllocString(V_BSTR(&v));
    VariantClear(&v);
    return *outPath ? S_OK : E_FAIL;
}

/* Builds the input-parameter instance for a method (NULL if it has none). */
static HRESULT build_in_params(IWbemClassObject* pClass, const wchar_t* method,
                               IWbemClassObject** ppInParams)
{
    *ppInParams = NULL;
    IWbemClassObject* pInSig = NULL;
    IWbemClassObject* pOutSig = NULL;
    HRESULT hr = pClass->lpVtbl->GetMethod(pClass, method, 0, &pInSig, &pOutSig);
    if (FAILED(hr)) return hr;
    IWbemClassObject* sig = pInSig ? pInSig : pOutSig;
    if (sig) hr = sig->lpVtbl->SpawnInstance(sig, 0, ppInParams);
    if (pInSig) pInSig->lpVtbl->Release(pInSig);
    if (pOutSig) pOutSig->lpVtbl->Release(pOutSig);
    return hr;
}

/* Executes `method` on `path`, first with a NULL in-params, then with one
 * spawned from the method signature. */
static HRESULT exec_on(IWbemServices* svc, IWbemClassObject* pClass, BSTR path,
                       const wchar_t* method, IWbemClassObject** ppOut)
{
    BSTR bMethod = SysAllocString(method);
    *ppOut = NULL;
    HRESULT hr = svc->lpVtbl->ExecMethod(svc, path, bMethod, 0, NULL, NULL, ppOut, NULL);
    if (FAILED(hr)) {
        IWbemClassObject* pIn = NULL;
        if (SUCCEEDED(build_in_params(pClass, method, &pIn)) && pIn)
            hr = svc->lpVtbl->ExecMethod(svc, path, bMethod, 0, NULL, pIn, ppOut, NULL);
        if (pIn) pIn->lpVtbl->Release(pIn);
    }
    SysFreeString(bMethod);
    return hr;
}

EXPORT int fc_read(void* dev, const wchar_t* method, unsigned* outValue)
{
    FcDevice* d = (FcDevice*)dev;
    if (!d || !method || !outValue) return (int)E_POINTER;
    *outValue = 0;

    BSTR bClass = SysAllocString(CLASS_NAME);
    IWbemClassObject* pClass = NULL;
    HRESULT hr = d->svc->lpVtbl->GetObject(d->svc, bClass, 0, NULL, &pClass, NULL);
    if (FAILED(hr)) { SysFreeString(bClass); return (int)hr; }

    IWbemClassObject* pOut = NULL;
    hr = exec_on(d->svc, pClass, bClass, method, &pOut);
    if (FAILED(hr)) {
        BSTR instPath = NULL;
        if (SUCCEEDED(get_instance_path(d->svc, &instPath))) {
            hr = exec_on(d->svc, pClass, instPath, method, &pOut);
            SysFreeString(instPath);
        }
    }

    pClass->lpVtbl->Release(pClass);
    SysFreeString(bClass);
    if (FAILED(hr)) return (int)hr;

    VARIANT v;
    VariantInit(&v);
    hr = pOut->lpVtbl->Get(pOut, DATA_NAME, 0, &v, NULL, NULL);
    pOut->lpVtbl->Release(pOut);
    if (FAILED(hr)) return (int)hr;

    switch (V_VT(&v) & 0x0FFF) {
        case VT_I1:  *outValue = (unsigned)V_I1(&v); break;
        case VT_UI1: *outValue = (unsigned)V_UI1(&v); break;
        case VT_I2:  *outValue = (unsigned)V_I2(&v); break;
        case VT_UI2: *outValue = (unsigned)V_UI2(&v); break;
        case VT_I4:  *outValue = (unsigned)V_I4(&v); break;
        case VT_UI4: *outValue = (unsigned)V_UI4(&v); break;
        default:     *outValue = 0; break;
    }
    VariantClear(&v);
    return 0;
}

EXPORT int fc_write(void* dev, const wchar_t* method, unsigned value)
{
    FcDevice* d = (FcDevice*)dev;
    if (!d || !method) return (int)E_POINTER;

    BSTR bClass = SysAllocString(CLASS_NAME);
    IWbemClassObject* pClass = NULL;
    HRESULT hr = d->svc->lpVtbl->GetObject(d->svc, bClass, 0, NULL, &pClass, NULL);
    if (FAILED(hr)) { SysFreeString(bClass); return (int)hr; }

    BSTR bMethod = SysAllocString(method);
    IWbemClassObject* pIn = NULL;
    build_in_params(pClass, method, &pIn);
    if (!pIn) {
        pClass->lpVtbl->Release(pClass);
        SysFreeString(bClass); SysFreeString(bMethod);
        return (int)E_FAIL;
    }
    VARIANT v;
    VariantInit(&v);
    V_VT(&v) = VT_I4;
    V_I4(&v) = (LONG)value;
    hr = pIn->lpVtbl->Put(pIn, DATA_NAME, 0, &v, 0);

    IWbemClassObject* pOut = NULL;
    if (SUCCEEDED(hr))
        hr = d->svc->lpVtbl->ExecMethod(d->svc, bClass, bMethod, 0, NULL, pIn, &pOut, NULL);
    if (FAILED(hr)) {
        BSTR instPath = NULL;
        if (SUCCEEDED(get_instance_path(d->svc, &instPath))) {
            hr = d->svc->lpVtbl->ExecMethod(d->svc, instPath, bMethod, 0, NULL, pIn, &pOut, NULL);
            SysFreeString(instPath);
        }
    }
    if (pOut) pOut->lpVtbl->Release(pOut);
    pIn->lpVtbl->Release(pIn);
    pClass->lpVtbl->Release(pClass);
    SysFreeString(bClass); SysFreeString(bMethod);
    return (int)hr;
}
