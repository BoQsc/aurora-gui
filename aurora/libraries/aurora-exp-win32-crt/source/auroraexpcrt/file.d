// SPDX-License-Identifier: 0BSD
/// Aurora CRT file descriptors over kernel32 handles.
module auroraexpcrt.file;

import core.sys.windows.windows;

private __gshared void*[64] fileHandles;
private __gshared bool[64] fileUsed;

private enum int openReadOnly = 0;
private enum int openWriteOnly = 1;
private enum int openReadWrite = 2;
private enum int openAppend = 0x0008;
private enum int openCreate = 0x0100;
private enum int openTruncate = 0x0200;
private enum int openExclusive = 0x0400;

private DWORD accessFromFlags(int flags)
{
    switch (flags & 3)
    {
    case openWriteOnly:
        return GENERIC_WRITE;
    case openReadWrite:
        return GENERIC_READ | GENERIC_WRITE;
    default:
        return GENERIC_READ;
    }
}

private DWORD creationFromFlags(int flags)
{
    if ((flags & openCreate) != 0 && (flags & openExclusive) != 0)
        return CREATE_NEW;
    if ((flags & openTruncate) != 0)
        return CREATE_ALWAYS;
    if ((flags & openCreate) != 0)
        return OPEN_ALWAYS;
    return OPEN_EXISTING;
}

private int registerHandle(void* handle)
{
    foreach (descriptor; 3 .. 64)
        if (!fileUsed[descriptor])
        {
            fileUsed[descriptor] = true;
            fileHandles[descriptor] = handle;
            return cast(int) descriptor;
        }
    CloseHandle(handle);
    return -1;
}

private void* handleFor(int descriptor)
{
    if (descriptor >= 0 && descriptor < 3)
        return GetStdHandle(descriptor == 0 ? STD_INPUT_HANDLE
            : descriptor == 1 ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE);
    if (descriptor >= 0 && descriptor < 64 && fileUsed[descriptor])
        return fileHandles[descriptor];
    return INVALID_HANDLE_VALUE;
}

extern(C) int _open(const char* path, int flags, ...)
{
    if (path is null)
        return -1;
    auto handle = CreateFileA(path, accessFromFlags(flags),
        FILE_SHARE_READ | FILE_SHARE_WRITE, null, creationFromFlags(flags),
        FILE_ATTRIBUTE_NORMAL, null);
    if (handle == INVALID_HANDLE_VALUE)
        return -1;
    return registerHandle(handle);
}

extern(C) int _wopen(const wchar* path, int flags, ...)
{
    if (path is null)
        return -1;
    auto handle = CreateFileW(path, accessFromFlags(flags),
        FILE_SHARE_READ | FILE_SHARE_WRITE, null, creationFromFlags(flags),
        FILE_ATTRIBUTE_NORMAL, null);
    if (handle == INVALID_HANDLE_VALUE)
        return -1;
    return registerHandle(handle);
}

extern(C) int _read(int descriptor, void* buffer, uint count)
{
    auto handle = handleFor(descriptor);
    if (handle == INVALID_HANDLE_VALUE)
        return -1;
    DWORD received;
    if (!ReadFile(handle, buffer, count, &received, null))
        return -1;
    return cast(int) received;
}

extern(C) int _write(int descriptor, const(void)* buffer, uint count)
{
    auto handle = handleFor(descriptor);
    if (handle == INVALID_HANDLE_VALUE)
        return -1;
    DWORD written;
    if (!WriteFile(handle, buffer, count, &written, null))
        return -1;
    return cast(int) written;
}

extern(C) long _lseeki64(int descriptor, long offset, int origin)
{
    auto handle = handleFor(descriptor);
    if (handle == INVALID_HANDLE_VALUE)
        return -1;
    LARGE_INTEGER distance;
    LARGE_INTEGER position;
    distance.QuadPart = offset;
    if (!SetFilePointerEx(handle, distance, &position, cast(DWORD) origin))
        return -1;
    return position.QuadPart;
}

extern(C) ptrdiff_t _get_osfhandle(int descriptor)
{
    auto handle = handleFor(descriptor);
    return handle == INVALID_HANDLE_VALUE ? -1 : cast(ptrdiff_t) handle;
}

extern(C) int _close(int descriptor)
{
    if (descriptor < 3 || descriptor >= 64 || !fileUsed[descriptor])
        return -1;
    CloseHandle(fileHandles[descriptor]);
    fileHandles[descriptor] = null;
    fileUsed[descriptor] = false;
    return 0;
}

/// Text/binary mode has no effect on Win32 handles.
extern(C) int _setmode(int descriptor, int mode)
{
    return 0;
}

/// Wrap an existing OS handle in the Aurora file-descriptor table.
extern(C) int _open_osfhandle(ptrdiff_t handle, int flags)
{
    if (handle == -1)
        return -1;
    return registerHandle(cast(void*) handle);
}
