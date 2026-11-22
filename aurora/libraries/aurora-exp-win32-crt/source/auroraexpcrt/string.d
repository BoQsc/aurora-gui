// SPDX-License-Identifier: 0BSD
/// Aurora CRT memory and wide-string primitives.
///
/// Loops are deliberate: the CRT is compiled without optimization so the
/// compiler cannot rewrite them into calls to the very symbols being defined.
module auroraexpcrt.string;

extern(C) void* memcpy(void* destination, const(void)* source, size_t count)
{
    auto target = cast(ubyte*) destination;
    auto input = cast(const(ubyte)*) source;
    for (size_t index = 0; index < count; ++index)
        target[index] = input[index];
    return destination;
}

extern(C) void* memmove(void* destination, const(void)* source, size_t count)
{
    auto target = cast(ubyte*) destination;
    auto input = cast(const(ubyte)*) source;
    if (target < input || target >= input + count)
        for (size_t index = 0; index < count; ++index)
            target[index] = input[index];
    else
        for (size_t index = count; index > 0; --index)
            target[index - 1] = input[index - 1];
    return destination;
}

extern(C) void* memset(void* destination, int value, size_t count)
{
    auto target = cast(ubyte*) destination;
    const byteValue = cast(ubyte) value;
    for (size_t index = 0; index < count; ++index)
        target[index] = byteValue;
    return destination;
}

extern(C) int memcmp(const(void)* left, const(void)* right, size_t count)
{
    auto a = cast(const(ubyte)*) left;
    auto b = cast(const(ubyte)*) right;
    for (size_t index = 0; index < count; ++index)
        if (a[index] != b[index])
            return a[index] < b[index] ? -1 : 1;
    return 0;
}

extern(C) void* memchr(const(void)* memory, int value, size_t count)
{
    auto bytes = cast(const(ubyte)*) memory;
    const needle = cast(ubyte) value;
    for (size_t index = 0; index < count; ++index)
        if (bytes[index] == needle)
            return cast(void*) (bytes + index);
    return null;
}

extern(C) size_t strlen(const char* text)
{
    size_t length;
    while (text[length] != '\0')
        ++length;
    return length;
}

extern(C) size_t strnlen(const char* text, size_t limit)
{
    size_t length;
    while (length < limit && text[length] != '\0')
        ++length;
    return length;
}

extern(C) size_t wcslen(const wchar* text)
{
    size_t length;
    while (text[length] != '\0')
        ++length;
    return length;
}

extern(C) size_t wcsnlen(const wchar* text, size_t limit)
{
    size_t length;
    while (length < limit && text[length] != '\0')
        ++length;
    return length;
}

extern(C) int wcscmp(const wchar* left, const wchar* right)
{
    size_t index;
    while (left[index] != '\0' && left[index] == right[index])
        ++index;
    if (left[index] == right[index])
        return 0;
    return left[index] < right[index] ? -1 : 1;
}

private bool isDelimiter(wchar character, const(wchar)* delimiters)
{
    for (size_t index = 0; delimiters[index] != '\0'; ++index)
        if (delimiters[index] == character)
            return true;
    return false;
}

/// Microsoft `wcstok` contract: token state carried through `context`.
extern(C) wchar* wcstok(wchar* text, const(wchar)* delimiters, wchar** context)
{
    auto cursor = text !is null ? text : *context;
    if (cursor is null)
        return null;
    while (*cursor != '\0' && isDelimiter(*cursor, delimiters))
        ++cursor;
    if (*cursor == '\0')
    {
        *context = cursor;
        return null;
    }
    auto token = cursor;
    while (*cursor != '\0' && !isDelimiter(*cursor, delimiters))
        ++cursor;
    if (*cursor != '\0')
    {
        *cursor = '\0';
        ++cursor;
    }
    *context = cursor;
    return token;
}

/// Narrow conversion for ASCII and Latin-1; wider code points become '?'.
extern(C) size_t wcstombs(char* destination, const(wchar)* source, size_t limit)
{
    size_t written;
    while (source[written] != '\0' && written < limit)
    {
        const code = cast(uint) source[written];
        const value = code <= 0xFF ? cast(char) code : '?';
        if (destination !is null)
            destination[written] = value;
        ++written;
    }
    return written;
}
