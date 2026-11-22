// SPDX-License-Identifier: 0BSD
/**
 * Aurora CRT startup and process entry.
 *
 * DMD injects a C `main` into the program (via `_d_cmain`), which calls
 * `_d_run_main`; that runs druntime initialization and the D `main`. The Aurora
 * startup therefore only needs to build the C arguments, call `main`, and end
 * the process. There is no Microsoft CRT startup object in the link.
 */
module auroraexpcrt.startup;

import core.sys.windows.windows;
import auroraexpcrt.memory : malloc;
import auroraexpcrt.stdio : flushAll;

extern(C) int main(int argc, char** argv);

version (AuroraCrtTrace)
    private int traceTlsProbe = 0x5A5A;

private __gshared int errnoStorage;
private __gshared int shimArgumentCount;
private __gshared char** shimArguments;
private __gshared char** shimEnvironment;
private __gshared bool shimInitializing;

/// The process entry point selected with `/ENTRY:mainCRTStartup`.
extern(C) void mainCRTStartup()
{
    version (AuroraCrtTrace)
        AddVectoredExceptionHandler(1, &logException);
    version (AuroraCrtTrace)
        trace("AuroraCRT: entry\n");
    version (AuroraCrtTrace)
    {
        trace("AuroraCRT: tlsprobe=");
        traceValue(cast(ulong) traceTlsProbe);
    }
    runImageConstructors();
    version (AuroraCrtTrace)
        trace("AuroraCRT: constructors done\n");
    int argc;
    char** argv;
    char** environment;
    const ok = __getmainargs(&argc, &argv, &environment, 0, null) == 0;
    version (AuroraCrtTrace)
        trace("AuroraCRT: args done\n");
    version (AuroraCrtTrace)
        trace("AuroraCRT: entering main\n");
    ExitProcess(main(ok ? argc : 0, ok ? argv : null));
}

version (AuroraCrtTrace)
{
    private extern(Windows) LONG logException(EXCEPTION_POINTERS* information)
    {
        trace("AuroraCRT: exception code=");
        traceValue(information.ExceptionRecord.ExceptionCode);
        trace("AuroraCRT: address=");
        traceValue(cast(ulong) information.ExceptionRecord.ExceptionAddress);
        trace("AuroraCRT: rip=");
        traceValue(information.ContextRecord.Rip);
        trace("AuroraCRT: rsp=");
        traceValue(information.ContextRecord.Rsp);
        trace("AuroraCRT: rax=");
        traceValue(information.ContextRecord.Rax);
        trace("AuroraCRT: rcx=");
        traceValue(information.ContextRecord.Rcx);
        trace("AuroraCRT: rdx=");
        traceValue(information.ContextRecord.Rdx);
        trace("AuroraCRT: r8=");
        traceValue(information.ContextRecord.R8);
        const stack = cast(const(ulong)*) information.ContextRecord.Rsp;
        foreach (index; 0 .. 8)
            traceValue(stack[index]);
        return 0;
    }

    private void trace(const(char)* text)
    {
        DWORD written;
        size_t length;
        while (text[length] != '\0')
            ++length;
        WriteFile(GetStdHandle(STD_ERROR_HANDLE), text, cast(DWORD) length,
            &written, null);
    }

    private void traceValue(ulong value)
    {
        char[17] buffer;
        const digits = "0123456789abcdef";
        for (int index = 15; index >= 0; --index)
        {
            buffer[index] = digits[value & 0xF];
            value >>= 4;
        }
        buffer[16] = '\n';
        DWORD written;
        WriteFile(GetStdHandle(STD_ERROR_HANDLE), buffer.ptr, 17, &written, null);
    }
}

/// Run the image's C runtime constructors (`.CRT` section).
///
/// DMD emits `pragma(crt_constructor)` pointers into `.CRT$XCU`; the linker
/// merges them into the output `.CRT` section. Microsoft's CRT walks that range
/// through `__xc_a`/`__xc_z`; lld does not define those brackets, so the Aurora
/// startup walks the section from the image headers. This is what registers the
/// GCs, initializes the page size, and initializes cpuid before `main`.
private void runImageConstructors()
{
    const base = cast(ubyte*) GetModuleHandleW(null);
    if (base is null)
        return;
    const peOffset = *cast(const(uint)*) (base + 0x3C);
    const coff = base + peOffset + 4;
    const sectionCount = *cast(const(ushort)*) (coff + 2);
    const optionalSize = *cast(const(ushort)*) (coff + 16);
    const sectionTable = coff + 20 + optionalSize;
    foreach (index; 0 .. sectionCount)
    {
        const entry = sectionTable + index * 40;
        const name = cast(const(char)*) entry;
        if (name[0] != '.' || name[1] != 'C' || name[2] != 'R' || name[3] != 'T')
            continue;
        const virtualAddress = *cast(const(uint)*) (entry + 12);
        const rawSize = *cast(const(uint)*) (entry + 16);
        auto functions = cast(void function()*) (base + virtualAddress);
        foreach (offset; 0 .. rawSize / size_t.sizeof)
            if (functions[offset] !is null)
            {
                version (AuroraCrtTrace)
                {
                    trace("AuroraCRT: constructor ");
                    traceValue(cast(ulong) functions[offset]);
                }
                (functions[offset])();
                version (AuroraCrtTrace)
                    trace("AuroraCRT: constructor returned\n");
            }
    }
}

private char* toUtf8(const(wchar)* text)
{
    if (text is null)
        return null;
    const length = WideCharToMultiByte(CP_UTF8, 0, text, -1, null, 0, null, null);
    if (length <= 0)
        return null;
    auto result = cast(char*) malloc(cast(size_t) length);
    if (result is null)
        return null;
    WideCharToMultiByte(CP_UTF8, 0, text, -1, result, length, null, null);
    return result;
}

private void initializeArguments()
{
    if (shimArguments !is null || shimInitializing)
        return;
    shimInitializing = true;

    int argumentCount;
    auto wideArguments = CommandLineToArgvW(GetCommandLineW(), &argumentCount);
    if (wideArguments is null)
    {
        shimArgumentCount = 0;
        shimArguments = null;
        shimEnvironment = null;
        shimInitializing = false;
        return;
    }

    auto arguments = cast(char**) malloc(
        cast(size_t) (argumentCount + 1) * size_t.sizeof);
    if (arguments !is null)
    {
        foreach (index; 0 .. argumentCount)
            arguments[index] = toUtf8(wideArguments[index]);
        arguments[argumentCount] = null;
    }
    LocalFree(cast(void*) wideArguments);

    int environmentCount;
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
        foreach (index; 0 .. environmentCount)
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

    shimArgumentCount = argumentCount;
    shimArguments = arguments;
    shimEnvironment = environment;
    shimInitializing = false;
}

/// Microsoft C runtime entry used by druntime and some libraries.
extern(C) int __getmainargs(int* argc, char*** argv, char*** envp, int wildcard,
    void* startupInfo)
{
    initializeArguments();
    if (argc !is null)
        *argc = shimArgumentCount;
    if (argv !is null)
        *argv = shimArguments;
    if (envp !is null)
        *envp = shimEnvironment;
    return 0;
}

private int asciiLower(int value)
{
    return value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value;
}

/// UTF-8 environment lookup with Windows' ASCII case-insensitive names.
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

/// End the process after flushing Aurora stdio buffers.
extern(C) void exit(int status)
{
    flushAll();
    ExitProcess(cast(uint) status);
}

extern(C) void abort()
{
    ExitProcess(3);
}

extern(C) int* _errno()
{
    return &errnoStorage;
}

extern(C) void __set_app_type(int appType)
{
}

extern(C) uint _set_output_format(uint format)
{
    return 0;
}

extern(C) void _invalid_parameter_noinfo()
{
    abort();
}

extern(C) void _initterm(void function()* start, void function()* end)
{
    for (auto current = start; current < end; ++current)
        if (*current !is null)
            (*current)();
}

extern(C) int _initterm_e(int function()* start, int function()* end)
{
    for (auto current = start; current < end; ++current)
        if (*current !is null)
        {
            const result = (*current)();
            if (result != 0)
                return result;
        }
    return 0;
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

private alias ThreadStart = extern(C) uint function(void*);

/// Create a thread through kernel32; the D runtime uses this for `core.thread`.
extern(C) size_t _beginthreadex(void* security, uint stackSize,
    ThreadStart startAddress, void* argument, uint initFlag, uint* threadId)
{
    if (startAddress is null)
        return 0;
    DWORD id;
    auto handle = CreateThread(cast(SECURITY_ATTRIBUTES*) security, stackSize,
        cast(LPTHREAD_START_ROUTINE) startAddress, argument, initFlag,
        threadId !is null ? threadId : &id);
    return cast(size_t) handle;
}

