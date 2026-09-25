// SPDX-License-Identifier: BSL-1.0
// Copyright (c) 2026 Aurora OpenCode contributors
module aurora_portable_crt.environment;

private struct InitOnce
{
    void* state;
}

private alias InitCallback = extern(Windows) int function(InitOnce*, void*, void**);
private alias FlsCallback = extern(Windows) void function(void*);

extern(Windows)
{
    int InitOnceExecuteOnce(InitOnce*, InitCallback, void*, void**);
    uint FlsAlloc(FlsCallback);
    void* FlsGetValue(uint);
    int FlsSetValue(uint, void*);
    uint GetEnvironmentVariableA(const char*, char*, uint);
    void* GetProcessHeap();
    void* HeapAlloc(void*, uint, size_t);
    int HeapFree(void*, uint, void*);
}

private __gshared InitOnce environmentOnce;
private __gshared uint environmentSlot = uint.max;

private extern(Windows) void releaseEnvironment(void* value)
{
    if (value !is null) HeapFree(GetProcessHeap(), 0, value);
}

private extern(Windows) int initializeEnvironment(InitOnce*, void*, void**)
{
    environmentSlot = FlsAlloc(&releaseEnvironment);
    return environmentSlot != uint.max;
}

extern(C)
{
    char* getenv(const char* name)
    {
        if (name is null || !name[0] || name[0] == '=') return null;
        if (!InitOnceExecuteOnce(&environmentOnce, &initializeEnvironment,
                                 null, null)) return null;

        uint required = GetEnvironmentVariableA(name, null, 0);
        if (!required) return null;
        while (true)
        {
            auto buffer = cast(char*) HeapAlloc(GetProcessHeap(), 0, required);
            if (buffer is null) return null;
            const copied = GetEnvironmentVariableA(name, buffer, required);
            if (!copied)
            {
                HeapFree(GetProcessHeap(), 0, buffer);
                return null;
            }
            if (copied >= required)
            {
                HeapFree(GetProcessHeap(), 0, buffer);
                required = copied + 1;
                continue;
            }
            auto previous = FlsGetValue(environmentSlot);
            if (!FlsSetValue(environmentSlot, buffer))
            {
                HeapFree(GetProcessHeap(), 0, buffer);
                return null;
            }
            if (previous !is null) HeapFree(GetProcessHeap(), 0, previous);
            return buffer;
        }
    }

    char* strerror(int error)
    {
        switch (error)
        {
            case 0: return cast(char*) "No error";
            case 1: return cast(char*) "Operation not permitted";
            case 2: return cast(char*) "No such file or directory";
            case 4: return cast(char*) "Interrupted function call";
            case 5: return cast(char*) "Input/output error";
            case 9: return cast(char*) "Bad file descriptor";
            case 11: return cast(char*) "Resource temporarily unavailable";
            case 12: return cast(char*) "Not enough memory";
            case 13: return cast(char*) "Permission denied";
            case 17: return cast(char*) "File exists";
            case 22: return cast(char*) "Invalid argument";
            case 24: return cast(char*) "Too many open files";
            case 28: return cast(char*) "No space left on device";
            case 32: return cast(char*) "Broken pipe";
            case 34: return cast(char*) "Result too large";
            default: return cast(char*) "Unknown error";
        }
    }

    wchar* wcstok(wchar* input, const wchar* delimiters, wchar** context)
    {
        if (context is null || delimiters is null) return null;
        auto cursor = input is null ? *context : input;
        if (cursor is null) return null;

        while (*cursor && isDelimiter(*cursor, delimiters)) ++cursor;
        if (!*cursor)
        {
            *context = cursor;
            return null;
        }
        auto token = cursor;
        while (*cursor && !isDelimiter(*cursor, delimiters)) ++cursor;
        if (*cursor)
        {
            *cursor = 0;
            *context = cursor + 1;
        }
        else *context = cursor;
        return token;
    }
}

private bool isDelimiter(wchar value, const wchar* delimiters)
{
    for (const(wchar)* p = delimiters; *p; ++p)
        if (*p == value) return true;
    return false;
}
