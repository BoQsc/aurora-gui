// SPDX-License-Identifier: BSL-1.0
// Copyright (c) 2026 Aurora OpenCode contributors
module aurora_portable_crt.time_locale;

private struct FileTime
{
    uint low;
    uint high;
}

private struct SystemTime
{
    ushort year;
    ushort month;
    ushort dayOfWeek;
    ushort day;
    ushort hour;
    ushort minute;
    ushort second;
    ushort milliseconds;
}

private struct TimeZoneInformation
{
    int bias;
    wchar[32] standardName;
    SystemTime standardDate;
    int standardBias;
    wchar[32] daylightName;
    SystemTime daylightDate;
    int daylightBias;
}

private struct CalendarTime
{
    int seconds;
    int minutes;
    int hours;
    int day;
    int month;
    int year;
    int weekDay;
    int yearDay;
    int daylight;
}

private struct InitOnce
{
    void* state;
}

private alias InitCallback = extern(Windows) int function(InitOnce*, void*, void**);
private alias FlsCallback = extern(Windows) void function(void*);

extern(Windows)
{
    int InitOnceExecuteOnce(InitOnce*, InitCallback, void*, void**);
    uint FlsAlloc(FlsCallback);
    void* FlsGetValue(uint);
    int FlsSetValue(uint, void*);
    int FileTimeToSystemTime(const FileTime*, SystemTime*);
    int SystemTimeToFileTime(const SystemTime*, FileTime*);
    int SystemTimeToTzSpecificLocalTime(const TimeZoneInformation*,
                                        const SystemTime*, SystemTime*);
    uint GetTimeZoneInformation(TimeZoneInformation*);
    void* GetProcessHeap();
    void* HeapAlloc(void*, uint, size_t);
    int HeapFree(void*, uint, void*);
    int WideCharToMultiByte(uint, uint, const wchar*, int, char*, int,
                            const char*, int*);
}

private __gshared InitOnce calendarOnce;
private __gshared uint calendarSlot = uint.max;

private extern(Windows) void releaseCalendar(void* value)
{
    if (value !is null) HeapFree(GetProcessHeap(), 0, value);
}

private extern(Windows) int initializeCalendar(InitOnce*, void*, void**)
{
    calendarSlot = FlsAlloc(&releaseCalendar);
    return calendarSlot != uint.max;
}

private bool leapYear(int year)
{
    return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}

private int dayOfYear(int year, int month, int day)
{
    immutable int[12] precedingDays =
        [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
    return precedingDays[month - 1] + day - 1 +
           (month > 2 && leapYear(year) ? 1 : 0);
}

extern(C)
{
    CalendarTime* localtime(const int* seconds)
    {
        if (seconds is null ||
            !InitOnceExecuteOnce(&calendarOnce, &initializeCalendar,
                                 null, null)) return null;
        auto result = cast(CalendarTime*) FlsGetValue(calendarSlot);
        if (result is null)
        {
            result = cast(CalendarTime*) HeapAlloc(GetProcessHeap(), 8,
                                                   CalendarTime.sizeof);
            if (result is null) return null;
            if (!FlsSetValue(calendarSlot, result))
            {
                HeapFree(GetProcessHeap(), 0, result);
                return null;
            }
        }

        enum long epochTicks = 116_444_736_000_000_000L;
        const ticks = epochTicks + cast(long) *seconds * 10_000_000L;
        if (ticks < 0) return null;
        FileTime utcFile = FileTime(cast(uint) ticks, cast(uint) (ticks >> 32));
        SystemTime utc;
        SystemTime local;
        if (!FileTimeToSystemTime(&utcFile, &utc) ||
            !SystemTimeToTzSpecificLocalTime(null, &utc, &local)) return null;

        result.seconds = local.second;
        result.minutes = local.minute;
        result.hours = local.hour;
        result.day = local.day;
        result.month = local.month - 1;
        result.year = local.year - 1900;
        result.weekDay = local.dayOfWeek;
        result.yearDay = dayOfYear(local.year, local.month, local.day);
        result.daylight = -1;

        TimeZoneInformation zone;
        if (GetTimeZoneInformation(&zone) != uint.max)
        {
            FileTime localAsUtc;
            if (SystemTimeToFileTime(&local, &localAsUtc))
            {
                const localTicks = (cast(ulong) localAsUtc.high << 32) |
                                   localAsUtc.low;
                const differenceMinutes = (cast(long) localTicks - ticks) /
                                          600_000_000L;
                const standardOffset = -cast(long) (zone.bias + zone.standardBias);
                const daylightOffset = -cast(long) (zone.bias + zone.daylightBias);
                if (differenceMinutes == daylightOffset &&
                    daylightOffset != standardOffset)
                    result.daylight = 1;
                else if (differenceMinutes == standardOffset)
                    result.daylight = 0;
            }
        }
        return result;
    }

    // Our localtime reads the current Windows time-zone rules on each call.
    void tzset() {}

    size_t wcstombs(char* output, const wchar* input, size_t limit)
    {
        if (input is null) return size_t.max;
        enum uint codePageAcp = 0;
        size_t written;
        const(wchar)* cursor = input;
        while (*cursor)
        {
            int units = 1;
            if (*cursor >= 0xD800 && *cursor <= 0xDBFF &&
                cursor[1] >= 0xDC00 && cursor[1] <= 0xDFFF)
                units = 2;
            char[8] encoded;
            const size = WideCharToMultiByte(codePageAcp, 0, cursor, units,
                                             encoded.ptr,
                                             cast(int) encoded.length,
                                             null, null);
            if (size <= 0) return size_t.max;
            if (output !is null)
            {
                if (written + size > limit) return written;
                foreach (index; 0 .. size)
                    output[written + index] = encoded[index];
            }
            written += size;
            cursor += units;
        }
        if (output !is null && written < limit) output[written] = 0;
        return written;
    }
}
