// SPDX-License-Identifier: 0BSD
/// Aurora CRT heap: process-heap allocation with standard C signatures.
module auroraexpcrt.memory;

import core.sys.windows.windows;

version (AuroraCrtTrace)
{
    private void memTrace(const(char)* label, const(void)* pointer, size_t size)
    {
        char[128] buffer;
        size_t used;
        for (size_t index = 0; label[index] != '\0' && used + 1 < buffer.length; ++index)
            buffer[used++] = label[index];
        const digits = "0123456789abcdef";
        foreach (value; [cast(ulong) pointer, cast(ulong) size])
        {
            buffer[used++] = ' ';
            buffer[used++] = '0';
            buffer[used++] = 'x';
            for (int shift = 60; shift >= 0; shift -= 4)
                buffer[used++] = digits[(value >> shift) & 0xF];
        }
        buffer[used++] = '\n';
        DWORD written;
        WriteFile(GetStdHandle(STD_ERROR_HANDLE), buffer.ptr, cast(DWORD) used,
            &written, null);
    }
}

extern(C) void* malloc(size_t size)
{
    return HeapAlloc(GetProcessHeap(), 0, size == 0 ? 1 : size);
}

extern(C) void* calloc(size_t count, size_t size)
{
    if (count != 0 && size > size_t.max / count)
        return null;
    return HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY,
        count == 0 || size == 0 ? 1 : count * size);
}

extern(C) void* realloc(void* pointer, size_t size)
{
    version (AuroraCrtTrace)
        memTrace("realloc-in", pointer, size);
    if (pointer is null)
        return malloc(size);
    if (size == 0)
    {
        free(pointer);
        return null;
    }
    auto result = HeapReAlloc(GetProcessHeap(), 0, pointer, size);
    version (AuroraCrtTrace)
        memTrace("realloc-out", result, size);
    return result;
}

extern(C) void free(void* pointer)
{
    if (pointer !is null)
        HeapFree(GetProcessHeap(), 0, pointer);
}
