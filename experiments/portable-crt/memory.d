// SPDX-License-Identifier: BSL-1.0
// Copyright (c) 2026 Aurora OpenCode contributors
module aurora_portable_crt.memory;

extern(Windows)
{
    void* GetProcessHeap();
    void* HeapAlloc(void* heap, uint flags, size_t bytes);
    void* HeapReAlloc(void* heap, uint flags, void* block, size_t bytes);
    int HeapFree(void* heap, uint flags, void* block);
}

extern(C)
{
    void* malloc(size_t bytes)
    {
        return HeapAlloc(GetProcessHeap(), 0, bytes ? bytes : 1);
    }

    void free(void* block)
    {
        if (block !is null) HeapFree(GetProcessHeap(), 0, block);
    }

    void* calloc(size_t count, size_t bytes)
    {
        if (bytes && count > size_t.max / bytes) return null;
        return HeapAlloc(GetProcessHeap(), 8, count * bytes ? count * bytes : 1);
    }

    void* realloc(void* block, size_t bytes)
    {
        if (block is null) return malloc(bytes);
        if (!bytes)
        {
            free(block);
            return null;
        }
        return HeapReAlloc(GetProcessHeap(), 0, block, bytes);
    }

    void* memcpy(void* destination, const void* source, size_t bytes)
    {
        auto target = cast(ubyte*) destination;
        auto origin = cast(const(ubyte)*) source;
        foreach (index; 0 .. bytes) target[index] = origin[index];
        return destination;
    }

    void* memmove(void* destination, const void* source, size_t bytes)
    {
        auto target = cast(ubyte*) destination;
        auto origin = cast(const(ubyte)*) source;
        if (target > origin && target < origin + bytes)
        {
            for (size_t index = bytes; index; --index)
                target[index - 1] = origin[index - 1];
        }
        else foreach (index; 0 .. bytes) target[index] = origin[index];
        return destination;
    }

    void* memset(void* destination, int value, size_t bytes)
    {
        auto target = cast(ubyte*) destination;
        foreach (index; 0 .. bytes) target[index] = cast(ubyte) value;
        return destination;
    }

    int memcmp(const void* first, const void* second, size_t bytes)
    {
        auto left = cast(const(ubyte)*) first;
        auto right = cast(const(ubyte)*) second;
        foreach (index; 0 .. bytes)
            if (left[index] != right[index])
                return cast(int) left[index] - cast(int) right[index];
        return 0;
    }

    void* memchr(const void* block, int value, size_t bytes)
    {
        auto data = cast(const(ubyte)*) block;
        foreach (index; 0 .. bytes)
            if (data[index] == cast(ubyte) value)
                return cast(void*) (data + index);
        return null;
    }

    size_t strlen(const char* value)
    {
        size_t length;
        while (value[length]) ++length;
        return length;
    }

    size_t strnlen(const char* value, size_t limit)
    {
        size_t length;
        while (length < limit && value[length]) ++length;
        return length;
    }

    size_t wcslen(const wchar* value)
    {
        size_t length;
        while (value[length]) ++length;
        return length;
    }

    size_t wcsnlen(const wchar* value, size_t limit)
    {
        size_t length;
        while (length < limit && value[length]) ++length;
        return length;
    }

    int wcscmp(const wchar* first, const wchar* second)
    {
        size_t index;
        while (first[index] && first[index] == second[index]) ++index;
        return cast(int) first[index] - cast(int) second[index];
    }

    int isdigit(int value)
    {
        return value >= '0' && value <= '9';
    }

    int isspace(int value)
    {
        return value == ' ' || (value >= '\t' && value <= '\r');
    }

    int toupper(int value)
    {
        return value >= 'a' && value <= 'z' ? value - ('a' - 'A') : value;
    }
}
