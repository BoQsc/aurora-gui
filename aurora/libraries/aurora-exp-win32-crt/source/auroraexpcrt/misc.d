// SPDX-License-Identifier: 0BSD
/// Symbols the Microsoft CRT normally supplies to the compiler, loader, and
/// Phobos' zlib build, plus the POSIX file shims that build expects.
module auroraexpcrt.misc;

import auroraexpcrt.file : _close, _open, _read, _write;

/// Marks that floating-point code is present (the compiler emits references).
extern(C) __gshared int _fltused = 1;

/// Loader-written TLS index for this module.
extern(C) __gshared int _tls_index = 0;

/// The image's TLS directory. lld-link emits the data-directory entry from this
/// symbol; druntime reads its first two fields as the TLS bracket.
/// Address-linked fields are filled by the linker/post-link phase; D cannot
/// place symbol addresses in a static initializer.
align(1) struct ImageTlsDirectory
{
    ulong startAddressOfRawData;
    ulong endAddressOfRawData;
    ulong addressOfIndex;
    ulong addressOfCallbacks;
    uint sizeOfZeroFill;
    uint characteristics;
}

/// A non-zero field keeps the structure in raw data so the post-link phase can
/// patch it; the patch phase rewrites every field before the image runs.
extern(C) __gshared ImageTlsDirectory _tls_used =
    ImageTlsDirectory(0, 0, 0, 0, 1, 0);

/// zlib in Phobos is built against these names.
extern(C) int open(const char* path, int flags, ...)
{
    return _open(path, flags);
}

extern(C) int read(int descriptor, void* buffer, size_t count)
{
    return _read(descriptor, buffer, cast(uint) count);
}

extern(C) int write(int descriptor, const(void)* buffer, size_t count)
{
    return _write(descriptor, buffer, cast(uint) count);
}

extern(C) int close(int descriptor)
{
    return _close(descriptor);
}
