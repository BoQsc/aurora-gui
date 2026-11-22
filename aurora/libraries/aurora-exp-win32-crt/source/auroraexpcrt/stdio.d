// SPDX-License-Identifier: 0BSD
/// Aurora CRT console, FILE, and formatted-output primitives.
///
/// Windows exposes `FILE` as a single pointer-sized `_iobuf`, so a stream is
/// either a standard descriptor marker (0/1/2) or a pointer to an Aurora
/// `FileRecord`. This keeps `__iob_func()` pointer arithmetic ABI-compatible
/// with druntime and Phobos.
module auroraexpcrt.stdio;

import auroraexpcrt.file : _close, _open, _read, _wopen, _write,
    _lseeki64;
import auroraexpcrt.memory : free, malloc;
import core.stdc.stdarg : va_list, va_arg, va_start, va_end;
import core.sys.windows.windows;

private struct FileRecord
{
    int descriptor;
    long position;
    int eof;
    int error;
}

/// One `FILE` slot: a small descriptor marker or a pointer to a FileRecord.
/// The size must match druntime's VS2013 `_iobuf` stride (48 bytes on x64),
/// because `_msvc_acrt_iob_func` indexes `__iob_func()` with that type.
private struct FileSlot
{
    size_t value;
    ubyte[40] reserved;
}
static assert(FileSlot.sizeof == 48);

private __gshared FileSlot[3] standardFiles = [
    FileSlot(0), FileSlot(1), FileSlot(2)
];

/// Microsoft's `__iob_func` returns the three standard streams.
extern(C) void* __iob_func()
{
    return &standardFiles[0];
}

/// UCRT-style standard-stream accessor used by newer druntime builds.
extern(C) void* __acrt_iob_func(int index)
{
    if (index <= 0)
        return &standardFiles[0];
    if (index >= 2)
        return &standardFiles[2];
    return &standardFiles[1];
}

private FileRecord* fileRecord(void* stream)
{
    if (stream is null)
        return null;
    const value = *cast(const size_t*) stream;
    if (value <= 2)
        return null;
    return cast(FileRecord*) value;
}

private int descriptorOf(void* stream)
{
    if (stream is null)
        return 1;
    const value = *cast(const size_t*) stream;
    if (value <= 2)
        return cast(int) value;
    return (cast(const FileRecord*) value).descriptor;
}

private size_t writeBytes(void* stream, const(char)* data, size_t length)
{
    if (length == 0)
        return 0;
    const descriptor = descriptorOf(stream);
    const written = _write(descriptor, data, cast(uint) length);
    if (written < 0)
    {
        if (auto record = fileRecord(stream))
            record.error = 1;
        return 0;
    }
    if (auto record = fileRecord(stream))
        record.position += written;
    return cast(size_t) written;
}

extern(C) size_t fwrite(const(void)* pointer, size_t size, size_t count, void* stream)
{
    if (size == 0 || count == 0)
        return 0;
    if (size > size_t.max / count)
        return 0;
    const total = size * count;
    const written = writeBytes(stream, cast(const(char)*) pointer, total);
    return written / size;
}

extern(C) int fflush(void* stream)
{
    return 0;
}

/// Called by `exit` before the process ends.
void flushAll()
{
}

// ---- FILE lifecycle ---------------------------------------------------

extern(C) void* _fdopen(int descriptor, const(char)* mode)
{
    auto record = cast(FileRecord*) malloc(FileRecord.sizeof);
    auto slot = cast(FileSlot*) malloc(FileSlot.sizeof);
    if (record is null || slot is null)
    {
        if (record !is null)
            free(record);
        if (slot !is null)
            free(slot);
        return null;
    }
    record.descriptor = descriptor;
    slot.value = cast(size_t) record;
    return slot;
}

private int flagsFromMode(const(char)* mode)
{
    if (mode is null)
        return 0;
    bool plus;
    for (size_t index = 0; mode[index] != '\0'; ++index)
        if (mode[index] == '+')
            plus = true;

    int flags = plus ? 2 : 0;
    for (size_t index = 0; mode[index] != '\0'; ++index)
        switch (mode[index])
        {
        case 'w':
            return flags | 0x0001 | 0x0100 | 0x0200;
        case 'a':
            return flags | 0x0001 | 0x0100 | 0x0008;
        default:
            break;
        }
    return flags;
}

extern(C) void* _wfopen(const(wchar)* path, const(wchar)* mode)
{
    if (path is null)
        return null;
    const descriptor = _wopen(path, flagsFromMode(cast(const(char)*) mode));
    if (descriptor < 0)
        return null;
    return _fdopen(descriptor, cast(const(char)*) mode);
}

extern(C) void* fopen(const(char)* path, const(char)* mode)
{
    if (path is null)
        return null;
    const descriptor = _open(path, flagsFromMode(mode));
    if (descriptor < 0)
        return null;
    return _fdopen(descriptor, mode);
}

extern(C) void* freopen(const(char)* path, const(char)* mode, void* stream)
{
    if (path is null || stream is null)
        return null;
    const isConsole = path[0] == 'C' && path[1] == 'O' && path[2] == 'N';
    const descriptor = _open(path, isConsole ? 2 : flagsFromMode(mode));
    if (descriptor < 0)
        return null;

    auto record = fileRecord(stream);
    if (record is null)
    {
        record = cast(FileRecord*) malloc(FileRecord.sizeof);
        if (record is null)
        {
            _close(descriptor);
            return null;
        }
        record.descriptor = descriptor;
        *cast(size_t*) stream = cast(size_t) record;
        return stream;
    }
    _close(record.descriptor);
    record.descriptor = descriptor;
    record.eof = 0;
    record.error = 0;
    record.position = 0;
    return stream;
}

extern(C) void* _wfreopen(const(wchar)* path, const(wchar)* mode, void* stream)
{
    if (stream !is null)
        fclose(stream);
    return _wfopen(path, mode);
}

extern(C) void* tmpfile()
{
    wchar[260] directory;
    wchar[260] name;
    if (GetTempPathW(260, directory.ptr) == 0)
        return null;
    if (GetTempFileNameW(directory.ptr, "aur"w.ptr, 0, name.ptr) == 0)
        return null;
    const descriptor = _wopen(name.ptr, 0x0002 | 0x0100 | 0x0200);
    if (descriptor < 0)
        return null;
    return _fdopen(descriptor, "w+");
}

extern(C) int fclose(void* stream)
{
    auto record = fileRecord(stream);
    if (record is null)
        return 0;
    if (record.descriptor >= 0)
        _close(record.descriptor);
    if (stream !is null)
        free(stream);
    free(record);
    return 0;
}

// ---- Reading, seeking, state -----------------------------------------

extern(C) size_t fread(void* pointer, size_t size, size_t count, void* stream)
{
    if (size == 0 || count == 0)
        return 0;
    if (size > size_t.max / count)
        return 0;
    const descriptor = descriptorOf(stream);
    const received = _read(descriptor, pointer, cast(uint) (size * count));
    if (received < 0)
    {
        if (auto record = fileRecord(stream))
            record.error = 1;
        return 0;
    }
    if (auto record = fileRecord(stream))
    {
        record.position += received;
        if (received == 0)
            record.eof = 1;
    }
    return cast(size_t) received / size;
}

extern(C) int _fseeki64(void* stream, long offset, int origin)
{
    const descriptor = descriptorOf(stream);
    const position = _lseeki64(descriptor, offset, origin);
    if (position < 0)
        return -1;
    if (auto record = fileRecord(stream))
    {
        record.position = position;
        record.eof = 0;
    }
    return 0;
}

extern(C) int fseek(void* stream, long offset, int origin)
{
    return _fseeki64(stream, offset, origin);
}

extern(C) long _ftelli64(void* stream)
{
    return _lseeki64(descriptorOf(stream), 0, 1);
}

extern(C) long ftell(void* stream)
{
    return _ftelli64(stream);
}

extern(C) int fgetpos(void* stream, long* position)
{
    if (position is null)
        return -1;
    const current = _ftelli64(stream);
    if (current < 0)
        return -1;
    *position = current;
    return 0;
}

extern(C) int fsetpos(void* stream, const(long)* position)
{
    if (position is null)
        return -1;
    return _fseeki64(stream, *position, 0);
}

extern(C) void rewind(void* stream)
{
    _fseeki64(stream, 0, 0);
    clearerr(stream);
}

extern(C) void clearerr(void* stream)
{
    if (auto record = fileRecord(stream))
    {
        record.eof = 0;
        record.error = 0;
    }
}

extern(C) int feof(void* stream)
{
    if (auto record = fileRecord(stream))
        return record.eof;
    return 0;
}

extern(C) int ferror(void* stream)
{
    if (auto record = fileRecord(stream))
        return record.error;
    return 0;
}

extern(C) int setvbuf(void* stream, char* buffer, int mode, size_t size)
{
    return 0;
}

extern(C) int _fileno(void* stream)
{
    return descriptorOf(stream);
}

extern(C) int fileno(void* stream)
{
    return descriptorOf(stream);
}

extern(C) long _filelengthi64(int descriptor)
{
    return _lseeki64(descriptor, 0, 2);
}

extern(C) void _lock_file(void* stream)
{
}

extern(C) void _unlock_file(void* stream)
{
}

// ---- Wide-character streams ------------------------------------------

private size_t encodeUtf8(wchar character, char[4] buffer)
{
    const value = cast(uint) character;
    if (value < 0x80)
    {
        buffer[0] = cast(char) value;
        return 1;
    }
    if (value < 0x800)
    {
        buffer[0] = cast(char) (0xC0 | (value >> 6));
        buffer[1] = cast(char) (0x80 | (value & 0x3F));
        return 2;
    }
    if (value >= 0xD800 && value <= 0xDFFF)
    {
        buffer[0] = '?';
        return 1;
    }
    buffer[0] = cast(char) (0xE0 | (value >> 12));
    buffer[1] = cast(char) (0x80 | ((value >> 6) & 0x3F));
    buffer[2] = cast(char) (0x80 | (value & 0x3F));
    return 3;
}

extern(C) int _fputwc_nolock(wchar character, void* stream)
{
    char[4] buffer;
    const length = encodeUtf8(character, buffer);
    if (writeBytes(stream, buffer.ptr, length) != length)
        return -1;
    return cast(int) character;
}

extern(C) int fputwc(wchar character, void* stream)
{
    return _fputwc_nolock(character, stream);
}

extern(C) int _fputc_nolock(int character, void* stream)
{
    char value = cast(char) character;
    if (writeBytes(stream, &value, 1) != 1)
        return -1;
    return cast(ubyte) value;
}

extern(C) int fputc(int character, void* stream)
{
    return _fputc_nolock(character, stream);
}

extern(C) int putc(int character, void* stream)
{
    return _fputc_nolock(character, stream);
}

extern(C) int _fgetc_nolock(void* stream)
{
    char value;
    if (_read(descriptorOf(stream), &value, 1) != 1)
        return -1;
    return cast(ubyte) value;
}

extern(C) int fgetc(void* stream)
{
    return _fgetc_nolock(stream);
}

extern(C) int getc(void* stream)
{
    return _fgetc_nolock(stream);
}

/// Legacy buffer flush/refill entry points. Writes are unbuffered here, so
/// flushing a character is a direct write and refilling a character is a
/// direct read.
extern(C) int _flsbuf(int character, void* stream)
{
    return _fputc_nolock(character, stream);
}

extern(C) int _filbuf(void* stream)
{
    return _fgetc_nolock(stream);
}

extern(C) int _fgetwc_nolock(void* stream)
{
    return -1;
}

extern(C) int fgetwc(void* stream)
{
    return -1;
}

// ---- Formatting -------------------------------------------------------

private size_t emit(char* buffer, size_t capacity, size_t used, char value)
{
    if (buffer !is null && used + 1 < capacity)
        buffer[used] = value;
    return used + 1;
}

private void terminate(char* buffer, size_t capacity, size_t used)
{
    if (buffer !is null && capacity != 0)
        buffer[used < capacity ? used : capacity - 1] = '\0';
}

private size_t appendUnsigned(char* buffer, size_t capacity, size_t used,
    ulong value, uint base, bool upper)
{
    char[32] digits;
    size_t count;
    const alphabet = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    if (value == 0)
        digits[count++] = '0';
    while (value != 0)
    {
        digits[count++] = alphabet[value % base];
        value /= base;
    }
    while (count > 0)
    {
        --count;
        used = emit(buffer, capacity, used, digits[count]);
    }
    return used;
}

private size_t appendSigned(char* buffer, size_t capacity, size_t used, long value)
{
    if (value < 0)
    {
        used = emit(buffer, capacity, used, '-');
        const magnitude = cast(ulong) (-(value + 1)) + 1;
        return appendUnsigned(buffer, capacity, used, magnitude, 10, false);
    }
    return appendUnsigned(buffer, capacity, used, cast(ulong) value, 10, false);
}

private size_t appendString(char* buffer, size_t capacity, size_t used,
    const(char)* text, int precision)
{
    if (text is null)
        text = "(null)";
    for (size_t index = 0; text[index] != '\0'
        && (precision < 0 || index < cast(size_t) precision); ++index)
        used = emit(buffer, capacity, used, text[index]);
    return used;
}

extern(C) int _vsnprintf(char* buffer, size_t capacity, const(char)* format,
    va_list ap)
{
    if (format is null)
    {
        terminate(buffer, capacity, 0);
        return 0;
    }

    size_t used;
    size_t index;
    while (format[index] != '\0')
    {
        if (format[index] != '%')
        {
            used = emit(buffer, capacity, used, format[index]);
            ++index;
            continue;
        }
        ++index;
        if (format[index] == '%')
        {
            used = emit(buffer, capacity, used, '%');
            ++index;
            continue;
        }

        while (format[index] == '-' || format[index] == '+' || format[index] == ' '
            || format[index] == '#' || format[index] == '0')
            ++index;
        if (format[index] == '*')
        {
            va_arg!int(ap);
            ++index;
        }
        while (format[index] >= '0' && format[index] <= '9')
            ++index;
        int precision = -1;
        if (format[index] == '.')
        {
            ++index;
            if (format[index] == '*')
            {
                precision = va_arg!int(ap);
                ++index;
            }
            else
            {
                precision = 0;
                while (format[index] >= '0' && format[index] <= '9')
                {
                    precision = precision * 10 + (format[index] - '0');
                    ++index;
                }
            }
        }

        bool wide;
        if (format[index] == 'l' && format[index + 1] == 'l')
        {
            wide = true;
            index += 2;
        }
        else if (format[index] == 'l' || format[index] == 'z'
            || format[index] == 'j' || format[index] == 't')
        {
            wide = true;
            ++index;
        }
        else if (format[index] == 'h')
        {
            ++index;
            if (format[index] == 'h')
                ++index;
        }

        const specifier = format[index];
        if (specifier == '\0')
            break;
        ++index;

        switch (cast(char) specifier)
        {
        case 's':
            used = appendString(buffer, capacity, used,
                va_arg!(const(char)*)(ap), precision);
            break;
        case 'c':
            used = emit(buffer, capacity, used, cast(char) va_arg!int(ap));
            break;
        case 'd':
        case 'i':
            if (wide)
                used = appendSigned(buffer, capacity, used, va_arg!long(ap));
            else
                used = appendSigned(buffer, capacity, used, va_arg!int(ap));
            break;
        case 'u':
        case 'x':
        case 'X':
            if (wide)
                used = appendUnsigned(buffer, capacity, used, va_arg!ulong(ap),
                    specifier == 'u' ? 10 : 16, specifier == 'X');
            else
                used = appendUnsigned(buffer, capacity, used, va_arg!uint(ap),
                    specifier == 'u' ? 10 : 16, specifier == 'X');
            break;
        case 'p':
            used = emit(buffer, capacity, used, '0');
            used = emit(buffer, capacity, used, 'x');
            used = appendUnsigned(buffer, capacity, used,
                cast(ulong) va_arg!(void*)(ap), 16, false);
            break;
        default:
            used = emit(buffer, capacity, used, '?');
            break;
        }
    }

    terminate(buffer, capacity, used);
    return cast(int) used;
}

extern(C) int vsnprintf(char* buffer, size_t capacity, const(char)* format,
    va_list ap)
{
    return _vsnprintf(buffer, capacity, format, ap);
}

extern(C) int _snprintf(char* buffer, size_t capacity, const(char)* format, ...)
{
    va_list ap;
    va_start(ap, format);
    const length = _vsnprintf(buffer, capacity, format, ap);
    va_end(ap);
    return length;
}

extern(C) int snprintf(char* buffer, size_t capacity, const(char)* format, ...)
{
    va_list ap;
    va_start(ap, format);
    const length = _vsnprintf(buffer, capacity, format, ap);
    va_end(ap);
    return length;
}

extern(C) int printf(const(char)* format, ...)
{
    char[4096] buffer;
    va_list ap;
    va_start(ap, format);
    const length = _vsnprintf(buffer.ptr, buffer.length, format, ap);
    va_end(ap);
    if (length > 0)
    {
        const count = length < cast(int) buffer.length
            ? cast(size_t) length : buffer.length - 1;
        writeBytes(&standardFiles[1], buffer.ptr, count);
    }
    return length;
}

extern(C) int fprintf(void* stream, const(char)* format, ...)
{
    char[4096] buffer;
    va_list ap;
    va_start(ap, format);
    const length = _vsnprintf(buffer.ptr, buffer.length, format, ap);
    va_end(ap);
    if (length > 0)
    {
        const count = length < cast(int) buffer.length
            ? cast(size_t) length : buffer.length - 1;
        writeBytes(stream, buffer.ptr, count);
    }
    return length;
}

/// Scanned conversions are a later CRT phase; report no assignments.
extern(C) int sscanf(const(char)* input, const(char)* format, ...)
{
    return 0;
}
