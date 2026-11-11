module aurorarecorder.settings;

/**
 * Pure recording settings: capture region, frame rate, quality and the
 * default output name.
 *
 * Everything here is arithmetic on plain values, so
 * `tests/headless_smoke.d` can exercise it without touching a screen or a
 * process. The Win32 capture and the ffmpeg pipe live in other modules.
 */

import std.format : format;
import std.path : buildPath;
import std.string : toLower;

/// Frame-rate selector choices, in frames per second.
immutable int[] frameRatePresets = [15, 24, 30, 60];

/// Quality selector choices, as x264 CRF (lower is larger and sharper; 18 is
/// effectively lossless for screen text, 28 is small and soft).
immutable int[] qualityPresets = [18, 23, 28];

/// What to record.
enum CaptureTarget : ubyte
{
    wholeScreen,  ///< every monitor as one virtual-desktop image
    primaryMonitor
}

/// Upper bound for a cursor-enabled recording. gdigrab captures the desktop
/// itself and cannot be told to stop by the parent, so every such recording
/// gets a generous cap; pressing Stop ends it much earlier.
enum double maxRecordingSeconds = 4.0 * 60.0 * 60.0;

/// Extra seconds allowed past the cap for ffmpeg to finalize the file.
enum double stopMarginSeconds = 2.0;

/// A screen rectangle in physical pixels.
struct CaptureRect
{
    int x;
    int y;
    int width;
    int height;

    bool valid() const { return width > 0 && height > 0; }
}

/// A monitor in physical pixels, as reported by the display system.
struct MonitorInfo
{
    int x;
    int y;
    int width;
    int height;

    bool usable() const { return width > 0 && height > 0; }
}

/// True when `value` is one of `presets`.
bool isPreset(int value, const(int)[] presets)
{
    foreach (preset; presets)
        if (preset == value)
            return true;
    return false;
}

/// The preset closest to `value` (a zero/negative value clamps to the first).
int nearestPreset(int value, const(int)[] presets)
{
    int best = presets[0];
    int bestDistance = int.max;
    foreach (preset; presets)
    {
        const distance = preset > value ? preset - value : value - preset;
        if (distance < bestDistance)
        {
            bestDistance = distance;
            best = preset;
        }
    }
    return best;
}

/// The region to capture. Invalid when the desktop geometry is unknown.
CaptureRect resolveCaptureRect(CaptureTarget target, MonitorInfo[] monitors,
    int virtualX, int virtualY, int virtualWidth, int virtualHeight)
{
    if (target == CaptureTarget.primaryMonitor && monitors.length > 0)
    {
        const primary = monitors[0];
        if (!primary.usable()) return CaptureRect.init;
        return CaptureRect(primary.x, primary.y, primary.width, primary.height);
    }
    if (virtualWidth <= 0 || virtualHeight <= 0) return CaptureRect.init;
    return CaptureRect(virtualX, virtualY, virtualWidth, virtualHeight);
}

/**
 * Even pixel dimensions: H.264 with yuv420p requires even width and height,
 * so at most one pixel is cropped at the right/bottom edge.
 */
CaptureRect evenCaptureRect(CaptureRect rect)
{
    CaptureRect result = rect;
    if (result.width > 0) result.width -= result.width % 2;
    if (result.height > 0) result.height -= result.height % 2;
    return result;
}

/// Recorded length in seconds from a frame count and frame rate.
double recordedSeconds(long frames, int fps)
{
    if (fps <= 0 || frames <= 0) return 0.0;
    return cast(double) frames / cast(double) fps;
}

/// `mm:ss`, or `h:mm:ss` past an hour, for a duration in seconds.
string formatClock(double seconds)
{
    if (!(seconds > 0.0)) seconds = 0.0;
    const total = cast(long) seconds;
    const hours = total / 3600;
    const minutes = (total % 3600) / 60;
    const secs = total % 60;
    if (hours > 0)
        return format("%d:%02d:%02d", hours, minutes, secs);
    return format("%02d:%02d", minutes, secs);
}

/// Local wall-clock time used for the default file name.
struct Timestamp
{
    int year;
    int month;
    int day;
    int hour;
    int minute;
    int second;
}

/// `YYYY-MM-DD_HH-MM-SS`, safe in a Windows file name.
string timestampName(Timestamp stamp)
{
    return format("%04d-%02d-%02d_%02d-%02d-%02d", stamp.year, stamp.month,
        stamp.day, stamp.hour, stamp.minute, stamp.second);
}

/**
 * Absolute `.mp4` path for the default file name,
 * `folder\Recording-YYYY-MM-DD_HH-MM-SS.mp4`. `existing` lets the caller add
 * a ` (2)` suffix instead of overwriting a recording made the same second.
 */
string recordingPath(string folder, Timestamp stamp,
    bool delegate(string) existing = null)
{
    const base = buildPath(folder, "Recording-" ~ timestampName(stamp));
    auto candidate = base ~ ".mp4";
    for (int suffix = 2; existing !is null && existing(candidate); suffix++)
        candidate = format("%s (%d).mp4", base, suffix);
    return candidate;
}

/// `path` with an `.mp4` extension added when it is missing (case matters
/// only for the check).
string ensureMp4Extension(string path)
{
    if (path.length >= 4 && toLower(path[path.length - 4 .. $]) == ".mp4")
        return path;
    return path ~ ".mp4";
}
