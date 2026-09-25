// SPDX-License-Identifier: BSL-1.0
// Copyright (c) 2026 Aurora OpenCode contributors
module aurora_portable_crt.fd;

private enum int readOnly = 0;
private enum int writeOnly = 1;
private enum int readWrite = 2;
private enum int append = 0x0008;
private enum int temporary = 0x0040;
private enum int noInherit = 0x0080;
private enum int create = 0x0100;
private enum int truncate = 0x0200;
private enum int exclusive = 0x0400;
private enum int text = 0x4000;
private enum int binary = 0x8000;

private enum uint genericRead = 0x8000_0000;
private enum uint genericWrite = 0x4000_0000;
private enum uint fileAppendData = 0x0000_0004;
private enum uint shareAll = 0x0000_0001 | 0x0000_0002 | 0x0000_0004;
private enum uint createNew = 1;
private enum uint createAlways = 2;
private enum uint openExisting = 3;
private enum uint openAlways = 4;
private enum uint truncateExisting = 5;
private enum uint normalAttributes = 0x80;
private enum uint deleteOnClose = 0x0400_0000;
private enum uint nonInheritable = 0;
private enum uint inheritable = 1;
private enum void* invalidHandle = cast(void*) size_t.max;
private enum size_t maxDescriptors = 1024;

private struct Descriptor
{
    void* handle;
    int mode;
}

extern(Windows)
{
    void AcquireSRWLockExclusive(size_t*);
    void ReleaseSRWLockExclusive(size_t*);
    void* GetStdHandle(uint);
    void* CreateFileA(const char*, uint, uint, void*, uint, uint, void*);
    void* CreateFileW(const wchar*, uint, uint, void*, uint, uint, void*);
    int CloseHandle(void*);
    int ReadFile(void*, void*, uint, uint*, void*);
    int WriteFile(void*, const void*, uint, uint*, void*);
    int SetFilePointerEx(void*, long, long*, uint);
    uint GetLastError();
}

extern(C) int* _errno();

private __gshared size_t descriptorLock;
private __gshared bool descriptorsInitialized;
private __gshared Descriptor[maxDescriptors] descriptors;

private void lockDescriptors()
{
    AcquireSRWLockExclusive(&descriptorLock);
    if (!descriptorsInitialized)
    {
        descriptors[0] = Descriptor(GetStdHandle(cast(uint) -10), binary);
        descriptors[1] = Descriptor(GetStdHandle(cast(uint) -11), binary);
        descriptors[2] = Descriptor(GetStdHandle(cast(uint) -12), binary);
        descriptorsInitialized = true;
    }
}

private void unlockDescriptors()
{
    ReleaseSRWLockExclusive(&descriptorLock);
}

private bool valid(int fd)
{
    return fd >= 0 && fd < maxDescriptors &&
           descriptors[fd].handle !is null &&
           descriptors[fd].handle !is invalidHandle;
}

private int errnoFromWin32(uint code)
{
    switch (code)
    {
        case 2, 3: return 2; // ENOENT
        case 4: return 24; // EMFILE
        case 5: return 13; // EACCES
        case 6: return 9; // EBADF
        case 8, 14: return 12; // ENOMEM
        case 32, 33: return 13; // EACCES
        case 80, 183: return 17; // EEXIST
        case 87: return 22; // EINVAL
        case 109: return 32; // EPIPE
        case 112: return 28; // ENOSPC
        default: return 5; // EIO
    }
}

private int fail(int code)
{
    auto error = _errno();
    if (error !is null) *error = code;
    return -1;
}

private int failWin32()
{
    return fail(errnoFromWin32(GetLastError()));
}

private int addDescriptor(void* handle, int flags)
{
    if (handle is null || handle is invalidHandle) return failWin32();
    lockDescriptors();
    foreach (index; 3 .. maxDescriptors)
    {
        if (!valid(cast(int) index))
        {
            descriptors[index] = Descriptor(handle, flags & (text | binary | append));
            unlockDescriptors();
            return cast(int) index;
        }
    }
    unlockDescriptors();
    CloseHandle(handle);
    return fail(24);
}

private uint desiredAccess(int flags)
{
    uint access;
    if ((flags & 3) != writeOnly) access |= genericRead;
    if ((flags & 3) != readOnly)
        access |= (flags & append) ? fileAppendData : genericWrite;
    return access;
}

private uint creationDisposition(int flags)
{
    if (flags & create)
        return (flags & exclusive) ? createNew :
               (flags & truncate) ? createAlways : openAlways;
    return (flags & truncate) ? truncateExisting : openExisting;
}

private uint fileAttributes(int flags)
{
    return normalAttributes | ((flags & temporary) ? deleteOnClose : 0);
}

extern(C)
{
    int open(const char* path, int flags, ...)
    {
        if (path is null) return fail(22);
        auto handle = CreateFileA(path, desiredAccess(flags), shareAll, null,
                                  creationDisposition(flags),
                                  fileAttributes(flags), null);
        return addDescriptor(handle, flags);
    }

    int _wopen(const wchar* path, int flags, ...)
    {
        if (path is null) return fail(22);
        auto handle = CreateFileW(path, desiredAccess(flags), shareAll, null,
                                  creationDisposition(flags),
                                  fileAttributes(flags), null);
        return addDescriptor(handle, flags);
    }

    int _open_osfhandle(long osHandle, int flags)
    {
        auto handle = cast(void*) osHandle;
        if (handle is null || handle is invalidHandle) return fail(9);
        return addDescriptor(handle, flags);
    }

    long _get_osfhandle(int fd)
    {
        lockDescriptors();
        if (!valid(fd))
        {
            unlockDescriptors();
            fail(9);
            return -1;
        }
        const result = cast(long) descriptors[fd].handle;
        unlockDescriptors();
        return result;
    }

    int _setmode(int fd, int mode)
    {
        if (mode != text && mode != binary && mode != 0x10000 &&
            mode != 0x20000 && mode != 0x40000) return fail(22);
        lockDescriptors();
        if (!valid(fd))
        {
            unlockDescriptors();
            return fail(9);
        }
        const previous = descriptors[fd].mode & ~append;
        descriptors[fd].mode = (descriptors[fd].mode & append) | mode;
        unlockDescriptors();
        return previous;
    }

    int read(int fd, void* buffer, uint count)
    {
        if (buffer is null && count) return fail(22);
        lockDescriptors();
        if (!valid(fd))
        {
            unlockDescriptors();
            return fail(9);
        }
        uint received;
        const ok = ReadFile(descriptors[fd].handle, buffer,
                            count > int.max ? int.max : count,
                            &received, null);
        const winError = ok ? 0 : GetLastError();
        unlockDescriptors();
        if (!ok)
        {
            if (winError == 109) return 0; // broken pipe is EOF for reading
            return fail(errnoFromWin32(winError));
        }
        return cast(int) received;
    }

    int write(int fd, const void* buffer, uint count)
    {
        if (buffer is null && count) return fail(22);
        lockDescriptors();
        if (!valid(fd))
        {
            unlockDescriptors();
            return fail(9);
        }
        uint written;
        const ok = WriteFile(descriptors[fd].handle, buffer,
                             count > int.max ? int.max : count,
                             &written, null);
        const winError = ok ? 0 : GetLastError();
        unlockDescriptors();
        if (!ok) return fail(errnoFromWin32(winError));
        return cast(int) written;
    }

    long _lseeki64(int fd, long offset, int origin)
    {
        if (origin < 0 || origin > 2)
        {
            fail(22);
            return -1;
        }
        lockDescriptors();
        if (!valid(fd))
        {
            unlockDescriptors();
            fail(9);
            return -1;
        }
        long position;
        const ok = SetFilePointerEx(descriptors[fd].handle, offset,
                                    &position, cast(uint) origin);
        const winError = ok ? 0 : GetLastError();
        unlockDescriptors();
        if (!ok)
        {
            fail(errnoFromWin32(winError));
            return -1;
        }
        return position;
    }

    int close(int fd)
    {
        lockDescriptors();
        if (!valid(fd))
        {
            unlockDescriptors();
            return fail(9);
        }
        auto handle = descriptors[fd].handle;
        descriptors[fd] = Descriptor.init;
        unlockDescriptors();
        if (!CloseHandle(handle)) return failWin32();
        return 0;
    }
}
