// SPDX-License-Identifier: BSL-1.0
// Copyright (c) 2026 Aurora OpenCode contributors
module aurora_portable_crt.process;

private struct FileTime
{
    uint low;
    uint high;
}

extern(Windows)
{
    void ExitProcess(uint code);
    void GetSystemTimeAsFileTime(FileTime* result);
}

extern(C)
{
    // The MSVC object format emits a reference to this marker for floating
    // point code. It does not need any runtime initialization.
    __gshared int _fltused = 1;

    void exit(int code)
    {
        ExitProcess(cast(uint) code);
    }

    void abort()
    {
        ExitProcess(3);
    }

    void _invalid_parameter_noinfo()
    {
        abort();
    }

    // DMD's Windows time_t is a signed 32-bit C long.
    int time(int* result)
    {
        FileTime now;
        GetSystemTimeAsFileTime(&now);
        const ticks = (cast(ulong) now.high << 32) | now.low;
        enum ulong unixEpochTicks = 116_444_736_000_000_000UL;
        const seconds = ticks >= unixEpochTicks
            ? (ticks - unixEpochTicks) / 10_000_000UL
            : ulong.max;
        const value = seconds <= int.max ? cast(int) seconds : -1;
        if (result !is null) *result = value;
        return value;
    }
}
