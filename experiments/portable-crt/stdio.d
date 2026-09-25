// SPDX-License-Identifier: BSL-1.0
// Copyright (c) 2026 Aurora OpenCode contributors
module aurora_portable_crt.stdio;

private enum uint streamMagic = 0x4155_4649;
private enum int openReadOnly = 0;
private enum int openWriteOnly = 1;
private enum int openReadWrite = 2;
private enum int openAppend = 0x8;
private enum int openTemporary = 0x40;
private enum int openCreate = 0x100;
private enum int openTruncate = 0x200;
private enum int openBinary = 0x8000;

private struct Stream
{
    size_t lockWord;
    int fd;
    uint magic;
    bool allocated;
    bool atEnd;
    bool failed;
    wchar pendingLowSurrogate;
    wchar pendingHighSurrogate;
}

extern(Windows)
{
    void AcquireSRWLockExclusive(size_t*);
    void ReleaseSRWLockExclusive(size_t*);
    uint GetTempPathW(uint, wchar*);
    uint GetTempFileNameW(const wchar*, const wchar*, uint, wchar*);
    int DeleteFileW(const wchar*);
}

extern(C)
{
    void* malloc(size_t);
    void free(void*);
    int open(const char*, int, ...);
    int _wopen(const wchar*, int, ...);
    int read(int, void*, uint);
    int write(int, const void*, uint);
    int close(int);
    long _lseeki64(int, long, int);
    long _get_osfhandle(int);
    int* _errno();
}

private __gshared Stream[3] standardStreams = [
    Stream(0, 0, streamMagic, false, false, false, 0, 0),
    Stream(0, 1, streamMagic, false, false, false, 0, 0),
    Stream(0, 2, streamMagic, false, false, false, 0, 0)
];

private Stream* checked(void* pointer)
{
    auto stream = cast(Stream*) pointer;
    return stream !is null && stream.magic == streamMagic ? stream : null;
}

private int modeFlags(const char* mode)
{
    if (mode is null || !mode[0]) return -1;
    int flags;
    switch (mode[0])
    {
        case 'r': flags = openReadOnly; break;
        case 'w': flags = openWriteOnly | openCreate | openTruncate; break;
        case 'a': flags = openWriteOnly | openCreate | openAppend; break;
        default: return -1;
    }
    for (const(char)* p = mode + 1; *p; ++p)
    {
        if (*p == '+') flags = (flags & ~3) | openReadWrite;
        else if (*p == 'b') flags |= openBinary;
        else if (*p != 't' && *p != 'x') return -1;
    }
    return flags;
}

private void markFailure(Stream* stream, int code)
{
    if (stream !is null) stream.failed = true;
    auto error = _errno();
    if (error !is null) *error = code;
}

extern(C)
{
    void* __acrt_iob_func(uint index)
    {
        return index < standardStreams.length ? &standardStreams[index] : null;
    }

    void* fopen(const char* path, const char* mode)
    {
        const flags = modeFlags(mode);
        if (flags < 0 || path is null)
        {
            markFailure(null, 22);
            return null;
        }
        const fd = open(path, flags);
        if (fd < 0) return null;
        auto stream = _fdopen(fd, mode);
        if (stream is null) close(fd);
        return stream;
    }

    void* _wfopen(const wchar* path, const wchar* mode)
    {
        if (path is null || mode is null)
        {
            markFailure(null, 22);
            return null;
        }
        char[16] narrowMode;
        size_t index;
        while (mode[index] && index + 1 < narrowMode.length)
        {
            if (mode[index] > 127)
            {
                markFailure(null, 22);
                return null;
            }
            narrowMode[index] = cast(char) mode[index];
            ++index;
        }
        if (mode[index])
        {
            markFailure(null, 22);
            return null;
        }
        narrowMode[index] = 0;
        const flags = modeFlags(narrowMode.ptr);
        if (flags < 0)
        {
            markFailure(null, 22);
            return null;
        }
        const fd = _wopen(path, flags);
        if (fd < 0) return null;
        auto stream = _fdopen(fd, narrowMode.ptr);
        if (stream is null) close(fd);
        return stream;
    }

    void* _fdopen(int fd, const char* mode)
    {
        if (modeFlags(mode) < 0 || _get_osfhandle(fd) == -1)
        {
            markFailure(null, 22);
            return null;
        }
        auto stream = cast(Stream*) malloc(Stream.sizeof);
        if (stream is null) return null;
        *stream = Stream.init;
        stream.fd = fd;
        stream.magic = streamMagic;
        stream.allocated = true;
        return stream;
    }

    void* _wfreopen(const wchar* path, const wchar* mode, void* existing)
    {
        auto stream = checked(existing);
        if (stream is null) return null;
        if (path is null)
        {
            markFailure(stream, 22);
            return null;
        }
        auto fresh = cast(Stream*) _wfopen(path, mode);
        if (fresh is null) return null;
        close(stream.fd);
        stream.fd = fresh.fd;
        stream.atEnd = false;
        stream.failed = false;
        fresh.magic = 0;
        free(fresh);
        return stream;
    }

    int fclose(void* pointer)
    {
        auto stream = checked(pointer);
        if (stream is null)
        {
            markFailure(null, 22);
            return -1;
        }
        const fd = stream.fd;
        const allocated = stream.allocated;
        stream.magic = 0;
        const result = close(fd);
        if (allocated) free(stream);
        return result;
    }

    int fflush(void* pointer)
    {
        if (pointer is null) return 0;
        if (checked(pointer) is null)
        {
            markFailure(null, 22);
            return -1;
        }
        return 0; // Streams are written directly to the Windows handle.
    }

    size_t fread(void* destination, size_t size, size_t count, void* pointer)
    {
        auto stream = checked(pointer);
        if (stream is null || (destination is null && size && count))
        {
            markFailure(stream, 22);
            return 0;
        }
        if (!size || !count) return 0;
        if (count > size_t.max / size)
        {
            markFailure(stream, 34);
            return 0;
        }
        const total = size * count;
        size_t done;
        while (done < total)
        {
            const remaining = total - done;
            const chunk = remaining > int.max ? cast(uint) int.max :
                          cast(uint) remaining;
            const received = read(stream.fd, cast(ubyte*) destination + done,
                                  chunk);
            if (received < 0)
            {
                stream.failed = true;
                break;
            }
            if (received == 0)
            {
                stream.atEnd = true;
                break;
            }
            done += received;
        }
        return done / size;
    }

    size_t fwrite(const void* source, size_t size, size_t count, void* pointer)
    {
        auto stream = checked(pointer);
        if (stream is null || (source is null && size && count))
        {
            markFailure(stream, 22);
            return 0;
        }
        if (!size || !count) return 0;
        if (count > size_t.max / size)
        {
            markFailure(stream, 34);
            return 0;
        }
        const total = size * count;
        size_t done;
        while (done < total)
        {
            const remaining = total - done;
            const chunk = remaining > int.max ? cast(uint) int.max :
                          cast(uint) remaining;
            const sent = write(stream.fd, cast(const(ubyte)*) source + done,
                               chunk);
            if (sent <= 0)
            {
                stream.failed = true;
                break;
            }
            done += sent;
        }
        return done / size;
    }

    int fseek(void* pointer, int offset, int origin)
    {
        return _fseeki64(pointer, offset, origin);
    }

    int _fseeki64(void* pointer, long offset, int origin)
    {
        auto stream = checked(pointer);
        if (stream is null)
        {
            markFailure(null, 22);
            return -1;
        }
        if (_lseeki64(stream.fd, offset, origin) < 0)
        {
            stream.failed = true;
            return -1;
        }
        stream.atEnd = false;
        return 0;
    }

    long _ftelli64(void* pointer)
    {
        auto stream = checked(pointer);
        if (stream is null)
        {
            markFailure(null, 22);
            return -1;
        }
        return _lseeki64(stream.fd, 0, 1);
    }

    int setvbuf(void* pointer, char*, int mode, size_t)
    {
        auto stream = checked(pointer);
        if (stream is null || mode < 0 || mode > 2)
        {
            markFailure(stream, 22);
            return -1;
        }
        return 0;
    }

    void _lock_file(void* pointer)
    {
        auto stream = checked(pointer);
        if (stream !is null) AcquireSRWLockExclusive(&stream.lockWord);
    }

    void _unlock_file(void* pointer)
    {
        auto stream = checked(pointer);
        if (stream !is null) ReleaseSRWLockExclusive(&stream.lockWord);
    }

    int fileno(void* pointer)
    {
        auto stream = checked(pointer);
        return stream is null ? -1 : stream.fd;
    }

    int feof(void* pointer)
    {
        auto stream = checked(pointer);
        return stream !is null && stream.atEnd;
    }

    int ferror(void* pointer)
    {
        auto stream = checked(pointer);
        return stream !is null && stream.failed;
    }

    void clearerr(void* pointer)
    {
        auto stream = checked(pointer);
        if (stream !is null)
        {
            stream.atEnd = false;
            stream.failed = false;
        }
    }

    void* tmpfile()
    {
        wchar[260] directory;
        wchar[260] path;
        const length = GetTempPathW(cast(uint) directory.length, directory.ptr);
        if (!length || length >= directory.length) return null;
        if (!GetTempFileNameW(directory.ptr, "auc"w.ptr, 0, path.ptr))
            return null;
        const fd = _wopen(path.ptr, openReadWrite | openTemporary |
                          openTruncate | openBinary);
        if (fd < 0)
        {
            DeleteFileW(path.ptr);
            return null;
        }
        auto stream = _fdopen(fd, "w+b");
        if (stream is null) close(fd);
        return stream;
    }

    int _fputwc_nolock(wchar value, void* pointer)
    {
        auto stream = checked(pointer);
        if (stream is null) return -1;
        if (value > 127)
        {
            markFailure(stream, 22);
            return -1;
        }
        const byteValue = cast(ubyte) value;
        return write(stream.fd, &byteValue, 1) == 1 ? value : -1;
    }

    int _fgetwc_nolock(void* pointer)
    {
        auto stream = checked(pointer);
        if (stream is null) return -1;
        ubyte value;
        const received = read(stream.fd, &value, 1);
        if (received == 0) stream.atEnd = true;
        else if (received < 0) stream.failed = true;
        return received == 1 ? value : -1;
    }
}
