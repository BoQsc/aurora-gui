// SPDX-License-Identifier: 0BSD
/**
 * Minimal compatibility layer for linking the DMD runtime against Windows'
 * built-in msvcrt.dll.
 *
 * DMD's default runtime targets the Visual C++ 2013 CRT.  The host deliberately
 * uses the Windows system CRT instead, which lacks a handful of entry points
 * that druntime and Phobos expect.  This module supplies only those missing
 * pieces; it does not contain Microsoft CRT source.
 *
 * File locking is intentionally delegated to msvcrt's per-stream locking in
 * fputwc/fgetwc.  A process-global lock here would conflict with msvcrt's own
 * FILE lock ordering (and deadlock the control channel).  The host writes its
 * protocol only from the UI thread.
 */
module auroramesh.crt.msvcrt_shim;

version (Windows):

extern(C):

private struct FILE;

private struct FileTime
{
    uint low;
    uint high;
}

private alias InitFunction = void function();
private alias InitFunctionE = int function();

int fputwc(wchar character, FILE* stream);
int fgetwc(FILE* stream);
int fgetpos(FILE* stream, long* position);
int fsetpos(FILE* stream, const long* position);
int _fileno(FILE* stream);
long _filelengthi64(int descriptor);
void* malloc(size_t size);

wchar* GetCommandLineW();
wchar** CommandLineToArgvW(wchar* commandLine, int* argumentCount);
wchar* GetEnvironmentStringsW();
int FreeEnvironmentStringsW(wchar* block);
void* LocalFree(void* memory);
int WideCharToMultiByte(uint codePage, uint flags, wchar* input,
    int inputLength, char* output, int outputLength, char* defaultChar,
    int* usedDefault);
void GetSystemTimeAsFileTime(FileTime* time);

private __gshared int shimArgumentCount;
private __gshared char** shimArguments;
private __gshared char** shimEnvironment;
private __gshared bool shimInitializing;

private void initializeArguments()
{
    if (shimArguments !is null)
        return;
    if (shimInitializing)
        return;

    shimInitializing = true;
    int argumentCount;
    char** arguments;
    char** environment;
    __getmainargs(&argumentCount, &arguments, &environment, 0, null);
    shimArgumentCount = argumentCount;
    shimArguments = arguments;
    shimEnvironment = environment;
    shimInitializing = false;
}

private char* toUtf8(wchar* text)
{
    if (text is null)
        return null;

    const length = WideCharToMultiByte(65001, 0, text, -1, null, 0, null, null);
    if (length <= 0)
        return null;

    auto result = cast(char*) malloc(cast(size_t) length);
    if (result is null)
        return null;

    WideCharToMultiByte(65001, 0, text, -1, result, length, null, null);
    return result;
}

/**
 * msvcrt's startup stub refers to __p___argc and __p___argv, which msvcrt.dll
 * does not export.  Supplying __getmainargs prevents the stub from being pulled
 * in and gives druntime a UTF-8 argv built from the real Unicode command line.
 */
extern(C) int __getmainargs(int* argc, char*** argv, char*** envp,
    int wildcard, void* startupInfo)
{
    if (argc is null || argv is null || envp is null)
        return -1;

    int argumentCount;
    auto wideArguments = CommandLineToArgvW(GetCommandLineW(), &argumentCount);
    if (wideArguments is null)
        return -1;

    auto arguments = cast(char**) malloc(
        cast(size_t) (argumentCount + 1) * size_t.sizeof);
    if (arguments is null)
    {
        LocalFree(cast(void*) wideArguments);
        return -1;
    }

    for (int index = 0; index < argumentCount; ++index)
        arguments[index] = toUtf8(wideArguments[index]);
    arguments[argumentCount] = null;
    LocalFree(cast(void*) wideArguments);

    int environmentCount = 0;
    auto environmentBlock = GetEnvironmentStringsW();
    if (environmentBlock !is null)
    {
        auto cursor = environmentBlock;
        while (*cursor != '\0')
        {
            ++environmentCount;
            while (*cursor != '\0')
                ++cursor;
            ++cursor;
        }
    }

    auto environment = cast(char**) malloc(
        cast(size_t) (environmentCount + 1) * size_t.sizeof);
    if (environment !is null)
    {
        auto cursor = environmentBlock;
        for (int index = 0; index < environmentCount; ++index)
        {
            environment[index] = toUtf8(cursor);
            while (*cursor != '\0')
                ++cursor;
            ++cursor;
        }
        environment[environmentCount] = null;
    }
    if (environmentBlock !is null)
        FreeEnvironmentStringsW(environmentBlock);

    *argc = argumentCount;
    *argv = arguments;
    *envp = environment;
    return 0;
}

private int asciiLower(int value)
{
    return value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value;
}

/**
 * msvcrt's getenv reads the ANSI environment that its startup stub creates.
 * The host needs Unicode paths, so expose the UTF-8 environment returned by
 * __getmainargs instead.  Windows environment names are case-insensitive for
 * ASCII, matching the platform's own lookup rules.
 */
extern(C) char* getenv(const char* name)
{
    if (name is null)
        return null;
    initializeArguments();
    if (shimEnvironment is null)
        return null;

    size_t nameLength;
    while (name[nameLength] != '\0')
        ++nameLength;

    for (size_t index = 0; shimEnvironment[index] !is null; ++index)
    {
        const entry = shimEnvironment[index];
        size_t offset;
        while (offset < nameLength && entry[offset] != '\0'
            && asciiLower(entry[offset]) == asciiLower(name[offset]))
            ++offset;
        if (offset == nameLength && entry[offset] == '=')
            return cast(char*) entry + nameLength + 1;
    }
    return null;
}

extern(C) int* __p___argc()
{
    initializeArguments();
    return &shimArgumentCount;
}

extern(C) char*** __p___argv()
{
    initializeArguments();
    return &shimArguments;
}

extern(C) void _initterm(InitFunction* start, InitFunction* end)
{
    for (auto current = start; current < end; ++current)
    {
        const initializer = *current;
        if (initializer !is null)
            initializer();
    }
}

extern(C) int _initterm_e(InitFunctionE* start, InitFunctionE* end)
{
    for (auto current = start; current < end; ++current)
    {
        const initializer = *current;
        if (initializer !is null)
        {
            const result = initializer();
            if (result != 0)
                return result;
        }
    }
    return 0;
}

extern(C) void _lock_file(FILE* stream)
{
}

extern(C) void _unlock_file(FILE* stream)
{
}

extern(C) int _fputwc_nolock(wchar character, FILE* stream)
{
    return fputwc(character, stream);
}

extern(C) int _fgetwc_nolock(FILE* stream)
{
    return fgetwc(stream);
}

extern(C) long _ftelli64(FILE* stream)
{
    long position;
    if (fgetpos(stream, &position) != 0)
        return -1;
    return position;
}

extern(C) int _fseeki64(FILE* stream, long offset, int origin)
{
    if (origin == 2)
    {
        const descriptor = _fileno(stream);
        const size = _filelengthi64(descriptor);
        if (size < 0)
            return -1;
        offset += size;
    }
    else if (origin == 1)
    {
        const current = _ftelli64(stream);
        if (current < 0)
            return -1;
        offset += current;
    }
    else if (origin != 0)
        return -1;

    return fsetpos(stream, &offset);
}

extern(C) long time(long* result)
{
    FileTime fileTime;
    GetSystemTimeAsFileTime(&fileTime);
    const ticks = (cast(long) fileTime.high << 32) | fileTime.low;
    const seconds = (ticks - 116444736000000000L) / 10000000L;
    if (result !is null)
        *result = seconds;
    return seconds;
}

extern(C) void _invalid_parameter_noinfo()
{
}
