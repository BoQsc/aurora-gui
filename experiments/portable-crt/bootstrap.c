// SPDX-License-Identifier: BSL-1.0
// Copyright (c) 2026 Aurora OpenCode contributors
// Windows PE startup and TLS directory for DMD's Microsoft ABI objects.

#include <windows.h>
#include <shellapi.h>
#include <stdint.h>

#pragma section(".tls$AAA", read, write)
#pragma section(".tls$ZZZ", read, write)
#pragma section(".rdata$T", read)
#pragma section(".CRT$XLA", read)
#pragma section(".CRT$XLZ", read)
#pragma section(".CRT$XIA", read)
#pragma section(".CRT$XIZ", read)
#pragma section(".CRT$XCA", read)
#pragma section(".CRT$XCZ", read)
#pragma section(".CRT$XPA", read)
#pragma section(".CRT$XPZ", read)
#pragma section(".CRT$XTA", read)
#pragma section(".CRT$XTZ", read)

__declspec(allocate(".tls$AAA")) void *_tls_start = 0;
__declspec(allocate(".tls$ZZZ")) void *_tls_end = 0;
unsigned long _tls_index = 0;
__declspec(allocate(".CRT$XLA")) PIMAGE_TLS_CALLBACK aurora_tls_first = 0;
__declspec(allocate(".CRT$XLZ")) PIMAGE_TLS_CALLBACK aurora_tls_last = 0;

__declspec(allocate(".rdata$T")) const IMAGE_TLS_DIRECTORY64 _tls_used = {
    (ULONGLONG)(uintptr_t)&_tls_start,
    (ULONGLONG)(uintptr_t)&_tls_end,
    (ULONGLONG)(uintptr_t)&_tls_index,
    (ULONGLONG)(uintptr_t)(&aurora_tls_first + 1),
    0,
    0
};
#pragma comment(linker, "/INCLUDE:_tls_used")

typedef int (__cdecl *init_callback)(void);
typedef void (__cdecl *void_callback)(void);
__declspec(allocate(".CRT$XIA")) init_callback aurora_init_first = 0;
__declspec(allocate(".CRT$XIZ")) init_callback aurora_init_last = 0;
__declspec(allocate(".CRT$XCA")) void_callback aurora_ctor_first = 0;
__declspec(allocate(".CRT$XCZ")) void_callback aurora_ctor_last = 0;
__declspec(allocate(".CRT$XPA")) void_callback aurora_preterm_first = 0;
__declspec(allocate(".CRT$XPZ")) void_callback aurora_preterm_last = 0;
__declspec(allocate(".CRT$XTA")) void_callback aurora_term_first = 0;
__declspec(allocate(".CRT$XTZ")) void_callback aurora_term_last = 0;

extern int __cdecl main(int, char **);

static void run_callbacks(void_callback *first, void_callback *last)
{
    for (void_callback *p = first + 1; p < last; ++p)
        if (*p) (*p)();
}

static int run_initializers(void)
{
    for (init_callback *p = &aurora_init_first + 1;
         p < &aurora_init_last; ++p)
        if (*p && (*p)()) return 0;
    run_callbacks(&aurora_ctor_first, &aurora_ctor_last);
    return 1;
}

static char **make_arguments(int *count)
{
    wchar_t **wide = CommandLineToArgvW(GetCommandLineW(), count);
    if (!wide) return 0;
    HANDLE heap = GetProcessHeap();
    char **arguments = HeapAlloc(heap, HEAP_ZERO_MEMORY,
                                 ((size_t)*count + 1) * sizeof(char *));
    if (!arguments)
    {
        LocalFree(wide);
        return 0;
    }
    int complete = 1;
    for (int index = 0; index < *count; ++index)
    {
        int needed = WideCharToMultiByte(CP_UTF8, 0, wide[index], -1,
                                         0, 0, 0, 0);
        if (!needed) { complete = 0; break; }
        arguments[index] = HeapAlloc(heap, 0, (size_t)needed);
        if (!arguments[index]) { complete = 0; break; }
        if (!WideCharToMultiByte(CP_UTF8, 0, wide[index], -1,
                                 arguments[index], needed, 0, 0))
        { complete = 0; break; }
    }
    LocalFree(wide);
    if (!complete)
    {
        for (int index = 0; index < *count; ++index)
            if (arguments[index]) HeapFree(heap, 0, arguments[index]);
        HeapFree(heap, 0, arguments);
        return 0;
    }
    return arguments;
}

void __cdecl mainCRTStartup(void)
{
    if (!run_initializers()) ExitProcess(3);
    int count = 0;
    char **arguments = make_arguments(&count);
    if (!arguments) ExitProcess(3);
    int result = main(count, arguments);
    run_callbacks(&aurora_preterm_first, &aurora_preterm_last);
    run_callbacks(&aurora_term_first, &aurora_term_last);
    ExitProcess((UINT)result);
}
