// SPDX-License-Identifier: BSL-1.0
// Copyright (c) 2026 Aurora OpenCode contributors
module aurora_portable_crt.thread;

private struct InitOnce
{
    void* state;
}

private alias InitCallback = extern(Windows) int function(InitOnce*, void*, void**);
private alias FlsCallback = extern(Windows) void function(void*);
private alias ThreadCallback = extern(Windows) uint function(void*);

extern(Windows)
{
    int InitOnceExecuteOnce(InitOnce*, InitCallback, void*, void**);
    uint FlsAlloc(FlsCallback);
    void* FlsGetValue(uint);
    int FlsSetValue(uint, void*);
    void* CreateThread(void*, size_t, ThreadCallback, void*, uint, uint*);
    void* GetProcessHeap();
    void* HeapAlloc(void*, uint, size_t);
    int HeapFree(void*, uint, void*);
}

private __gshared InitOnce errnoOnce;
private __gshared uint errnoSlot = uint.max;

private extern(Windows) void releaseErrno(void* value)
{
    if (value !is null) HeapFree(GetProcessHeap(), 0, value);
}

private extern(Windows) int initializeErrno(InitOnce*, void*, void**)
{
    errnoSlot = FlsAlloc(&releaseErrno);
    return errnoSlot != uint.max;
}

extern(C)
{
    int* _errno()
    {
        if (!InitOnceExecuteOnce(&errnoOnce, &initializeErrno, null, null))
            return null;
        auto value = cast(int*) FlsGetValue(errnoSlot);
        if (value is null)
        {
            value = cast(int*) HeapAlloc(GetProcessHeap(), 8, int.sizeof);
            if (value is null) return null;
            if (!FlsSetValue(errnoSlot, value))
            {
                HeapFree(GetProcessHeap(), 0, value);
                return null;
            }
        }
        return value;
    }

    size_t _beginthreadex(void* security, uint stackSize, ThreadCallback start,
                          void* argument, uint flags, uint* threadId)
    {
        auto handle = CreateThread(security, stackSize, start, argument,
                                   flags, threadId);
        if (handle is null)
        {
            auto error = _errno();
            if (error !is null) *error = 11; // EAGAIN
        }
        return cast(size_t) handle;
    }
}
