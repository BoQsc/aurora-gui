// SPDX-License-Identifier: 0BSD
// Compatibility names expected by DMD and Aurora; UCRT supplies the behavior.

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#pragma comment(lib, "ucrtbase.lib")
#pragma comment(lib, "kernel32.lib")
#pragma comment(lib, "shell32.lib")

__declspec(dllimport) int __cdecl _open(const char *, int, ...);
__declspec(dllimport) int __cdecl _read(int, void *, unsigned int);
__declspec(dllimport) int __cdecl _write(int, const void *, unsigned int);
__declspec(dllimport) int __cdecl _close(int);
__declspec(dllimport) long __cdecl _time32(long *);
__declspec(dllimport) void *__cdecl _localtime32(const long *);
__declspec(dllimport) void __cdecl _tzset(void);
__declspec(dllimport) void *__cdecl __acrt_iob_func(unsigned int);
__declspec(dllimport) int __cdecl __stdio_common_vsprintf(
    unsigned long long, char *, size_t, const char *, void *, va_list);
__declspec(dllimport) int __cdecl __stdio_common_vfprintf(
    unsigned long long, void *, const char *, void *, va_list);
__declspec(dllimport) int __cdecl __stdio_common_vsscanf(
    unsigned long long, const char *, size_t, const char *, void *, va_list);

int _fltused = 1;

long __cdecl time(long *destination) { return _time32(destination); }
void *__cdecl localtime(const long *source) { return _localtime32(source); }
void __cdecl tzset(void) { _tzset(); }
int __cdecl open(const char *path, int flags, ...)
{
    int mode = 0;
    if (flags & 0x0100) // _O_CREAT requires the caller's third argument.
    {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, int);
        va_end(args);
    }
    return _open(path, flags, mode);
}
int __cdecl read(int fd, void *buffer, unsigned int count) { return _read(fd, buffer, count); }
int __cdecl write(int fd, const void *buffer, unsigned int count) { return _write(fd, buffer, count); }
int __cdecl close(int fd) { return _close(fd); }

int __cdecl vsnprintf(char *output, size_t capacity, const char *format, va_list args)
{
    // Option 2 asks the UCRT for C99 snprintf truncation and return semantics.
    return __stdio_common_vsprintf(2, output, capacity, format, 0, args);
}

int __cdecl snprintf(char *output, size_t capacity, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    int result = vsnprintf(output, capacity, format, args);
    va_end(args);
    return result;
}

int __cdecl fprintf(void *stream, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    int result = __stdio_common_vfprintf(0, stream, format, 0, args);
    va_end(args);
    return result;
}

int __cdecl printf(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    int result = __stdio_common_vfprintf(0, __acrt_iob_func(1), format, 0, args);
    va_end(args);
    return result;
}

int __cdecl sscanf(const char *input, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    int result = __stdio_common_vsscanf(0, input, (size_t)-1, format, 0, args);
    va_end(args);
    return result;
}
