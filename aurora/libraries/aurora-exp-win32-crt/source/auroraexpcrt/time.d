// SPDX-License-Identifier: 0BSD
/// Aurora CRT local-time support for Phobos' `std.datetime`.
module auroraexpcrt.time;

import core.sys.windows.windows;

/// Microsoft C `struct tm` layout.
struct CrtTm
{
    int tm_sec;
    int tm_min;
    int tm_hour;
    int tm_mday;
    int tm_mon;
    int tm_year;
    int tm_wday;
    int tm_yday;
    int tm_isdst;
}

private __gshared CrtTm localTm;

/// Seconds since the Unix epoch.
extern(C) long time(long* result)
{
    FILETIME now;
    GetSystemTimeAsFileTime(&now);
    const long ticks = (cast(long) now.dwHighDateTime << 32)
        | now.dwLowDateTime;
    const long seconds = (ticks - 116444736000000000L) / 10000000L;
    if (result !is null)
        *result = seconds;
    return seconds;
}

private bool isLeap(int year)
{
    return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
}

private int dayOfYear(int year, int month, int day)
{
    static immutable int[12] cumulative = [
        0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334
    ];
    return cumulative[month - 1] + day - 1 + (month > 2 && isLeap(year) ? 1 : 0);
}

/// Present for Phobos; Windows supplies timezone conversion through
/// `FileTimeToLocalFileTime`, so no global timezone state is needed here.
extern(C) void tzset()
{
}

extern(C) CrtTm* localtime(const long* seconds)
{
    if (seconds is null)
        return null;

    // Windows FILETIME counts 100 ns intervals since 1601-01-01.
    const long intervals = (*seconds + 11644473600L) * 10000000L;
    FILETIME utc;
    utc.dwLowDateTime = cast(uint) (intervals & 0xFFFFFFFF);
    utc.dwHighDateTime = cast(uint) (intervals >> 32);

    FILETIME local;
    SYSTEMTIME systemTime;
    const converted = FileTimeToLocalFileTime(&utc, &local) != 0
        && FileTimeToSystemTime(&local, &systemTime) != 0;
    if (!converted && FileTimeToSystemTime(&utc, &systemTime) == 0)
        return null;

    localTm.tm_sec = systemTime.wSecond;
    localTm.tm_min = systemTime.wMinute;
    localTm.tm_hour = systemTime.wHour;
    localTm.tm_mday = systemTime.wDay;
    localTm.tm_mon = systemTime.wMonth - 1;
    localTm.tm_year = systemTime.wYear - 1900;
    localTm.tm_wday = systemTime.wDayOfWeek;
    localTm.tm_yday = dayOfYear(systemTime.wYear, systemTime.wMonth,
        systemTime.wDay);
    localTm.tm_isdst = 0;
    return &localTm;
}
