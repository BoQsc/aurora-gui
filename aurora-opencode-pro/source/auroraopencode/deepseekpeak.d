/// DeepSeek 4.1 Flash peak / off-peak billing schedule.
///
/// Peak hours are 01:00-04:00 and 06:00-10:00 UTC, Monday through Friday,
/// excluding Chinese public holidays (a holiday is off-peak for its whole
/// China-time day). Every other hour is off-peak. Off-peak rates are half the
/// peak rates. This module owns the calendar maths only; the composer footer
/// renders it (see `DeepSeekPeakBadge` in appui.d).
module auroraopencode.deepseekpeak;

import core.time : hours, minutes;
import std.datetime : Date, DateTime, DayOfWeek, SysTime, UTC;

/// One slot per 15 minutes across a UTC day; used for the timeline strip.
enum deepSeekSlotsPerDay = 96;
/// Seconds represented by one schedule slot.
enum deepSeekSlotSeconds = 15 * 60;

/// A snapshot of the schedule at one instant, ready to paint.
struct DeepSeekPeakStats
{
    /// The instant falls in a peak window (billed at the peak rate).
    bool peak;
    /// The China-time day containing the instant is a public holiday.
    bool holiday;
    /// Seconds from the instant until the peak state next flips.
    long secondsToChange;
    /// Peak state after that flip (`!peak`).
    bool changeToPeak;
    /// Seconds until the next peak period begins (exclusive of the current one).
    long secondsToNextPeak;
    /// Seconds until the next off-peak period begins (exclusive of the current).
    long secondsToNextOffPeak;
    /// Peak seconds in the instant's UTC day.
    int peakSecondsToday;
    /// Off-peak seconds in the instant's UTC day.
    int offPeakSecondsToday;
    /// Fraction of the UTC day already elapsed (0 .. 1) for the "now" marker.
    double nowFraction;
    /// Per-slot peak flags for the instant's UTC day (true == peak).
    bool[deepSeekSlotsPerDay] schedule;
    /// Per-slot scheduled peaks ignoring holidays (true == a weekday peak
    /// window), so the timeline can show a holiday's waived peaks distinctly.
    bool[deepSeekSlotsPerDay] scheduled;
    /// True when the day contains a scheduled peak that a holiday waived.
    bool waivedPeakToday;
}

/// Chinese public holidays that bill as off-peak, from the annual State
/// Council notices. Dates are China Standard Time civil days. Extend as new
/// notices are published; an unknown year is simply treated as holiday-free.
bool isDeepSeekHoliday(Date date)
{
    bool inRange(Date from, Date to)
    {
        return date >= from && date <= to;
    }

    switch (date.year)
    {
        case 2025:
            return inRange(Date(2025, 1, 1), Date(2025, 1, 1)) ||
                inRange(Date(2025, 1, 28), Date(2025, 2, 4)) ||
                inRange(Date(2025, 4, 4), Date(2025, 4, 6)) ||
                inRange(Date(2025, 5, 1), Date(2025, 5, 5)) ||
                inRange(Date(2025, 5, 31), Date(2025, 6, 2)) ||
                inRange(Date(2025, 10, 1), Date(2025, 10, 8));
        case 2026:
            return inRange(Date(2026, 1, 1), Date(2026, 1, 3)) ||
                inRange(Date(2026, 2, 15), Date(2026, 2, 23)) ||
                inRange(Date(2026, 4, 4), Date(2026, 4, 6)) ||
                inRange(Date(2026, 5, 1), Date(2026, 5, 5)) ||
                inRange(Date(2026, 6, 19), Date(2026, 6, 21)) ||
                inRange(Date(2026, 9, 25), Date(2026, 9, 27)) ||
                inRange(Date(2026, 10, 1), Date(2026, 10, 7));
        default:
            return false;
    }
}

/// True when `instant` falls in a weekday peak window in UTC, ignoring
/// holidays. A Chinese public holiday waives these.
bool isDeepSeekScheduledPeakAt(SysTime instant)
{
    const utc = instant.toUTC();
    const dow = Date(utc.year, utc.month, utc.day).dayOfWeek;
    if (dow == DayOfWeek.sat || dow == DayOfWeek.sun) return false;
    const hour = utc.hour;
    return (hour >= 1 && hour < 4) || (hour >= 6 && hour < 10);
}

/// True when `instant` bills at the peak rate: a scheduled peak that is not
/// waived by a Chinese public holiday.
bool isDeepSeekPeakAt(SysTime instant)
{
    if (!isDeepSeekScheduledPeakAt(instant)) return false;
    const china = instant.toUTC() + hours(8);
    return !isDeepSeekHoliday(Date(china.year, china.month, china.day));
}

/// Seconds from `now` until the peak state next becomes `target`, treating the
/// current period as already spent when it already matches. Always positive.
private long secondsUntilBecomes(SysTime now, bool target)
{
    enum horizonMinutes = 8 * 24 * 60;
    const current = isDeepSeekPeakAt(now);
    long minutesAhead;
    if (current == target)
    {
        while (minutesAhead < horizonMinutes)
        {
            ++minutesAhead;
            if (isDeepSeekPeakAt(now + minutes(minutesAhead)) != target) break;
        }
    }
    while (minutesAhead < horizonMinutes)
    {
        ++minutesAhead;
        if (isDeepSeekPeakAt(now + minutes(minutesAhead)) == target) break;
    }
    return minutesAhead * 60;
}

/// Evaluate the whole schedule at `now`.
DeepSeekPeakStats deepSeekPeakStats(SysTime now)
{
    DeepSeekPeakStats stats;
    const utc = now.toUTC();
    const china = utc + hours(8);
    stats.holiday = isDeepSeekHoliday(Date(china.year, china.month, china.day));
    stats.peak = isDeepSeekPeakAt(now);

    const dayStart = SysTime(DateTime(utc.year, utc.month, utc.day), UTC());
    int peakSeconds, offPeakSeconds;
    foreach (slot; 0 .. deepSeekSlotsPerDay)
    {
        const slotTime = dayStart + minutes(slot * 15);
        const isScheduled = isDeepSeekScheduledPeakAt(slotTime);
        const isPeak = isDeepSeekPeakAt(slotTime);
        stats.scheduled[slot] = isScheduled;
        stats.schedule[slot] = isPeak;
        if (isScheduled && !isPeak) stats.waivedPeakToday = true;
        if (isPeak) peakSeconds += deepSeekSlotSeconds;
        else offPeakSeconds += deepSeekSlotSeconds;
    }
    stats.peakSecondsToday = peakSeconds;
    stats.offPeakSecondsToday = offPeakSeconds;

    const elapsed = cast(long) (now - dayStart).total!"seconds";
    stats.nowFraction = elapsed <= 0 ? 0.0
        : elapsed >= 86_400 ? 1.0 : cast(double) elapsed / 86_400.0;

    stats.secondsToNextPeak = secondsUntilBecomes(now, true);
    stats.secondsToNextOffPeak = secondsUntilBecomes(now, false);
    stats.secondsToChange = stats.peak ? stats.secondsToNextOffPeak
        : stats.secondsToNextPeak;
    stats.changeToPeak = !stats.peak;
    return stats;
}
