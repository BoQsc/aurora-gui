module auroracut.util;

import std.file : append, exists, isDir, mkdir, mkdirRecurse, remove, rmdirRecurse, tempDir;
import std.format : format;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName, extension;
import std.process : Config, environment, execute;
import std.string : join, strip, toLower;
import std.uuid : randomUUID;
import std.datetime.systime : Clock;


/** Append a timestamped diagnostic line. Logging is intentionally best-effort. */
void appLog(string message)
{
    try
    {
        append("aurora-cut.log", format("[%s] %s\r\n",
            Clock.currTime().toISOExtString(), message));
    }
    catch (Exception) {}
}

/** Returns value constrained to the inclusive range [minimum, maximum]. */
T clampValue(T)(T value, T minimum, T maximum)
{
    if (maximum < minimum)
    {
        const temporary = minimum;
        minimum = maximum;
        maximum = temporary;
    }
    if (value < minimum) return minimum;
    if (value > maximum) return maximum;
    return value;
}

/** Formats a number for FFmpeg command-line arguments using a fixed decimal point. */
string formatSeconds(double value, int decimalPlaces = 3)
{
    decimalPlaces = clampValue(decimalPlaces, 0, 9);
    if (value != value || value > double.max || value < -double.max)
        value = 0.0;

    // Avoid producing "-0.000", which some command-line displays make confusing.
    double threshold = 0.5;
    foreach (_; 0 .. decimalPlaces) threshold /= 10.0;
    if (value < 0.0 && value > -threshold) value = 0.0;
    return format("%.*f", decimalPlaces, value);
}

/** Formats seconds as HH:MM:SS.mmm, or HH:MM:SS when milliseconds is false. */
string formatTimecode(double seconds, bool milliseconds = true)
{
    if (seconds != seconds || seconds < 0.0 || seconds > cast(double) long.max / 1000.0)
        seconds = 0.0;

    if (milliseconds)
    {
        const totalMilliseconds = cast(long) (seconds * 1000.0 + 0.5);
        const hours = totalMilliseconds / 3_600_000;
        const minutes = (totalMilliseconds / 60_000) % 60;
        const wholeSeconds = (totalMilliseconds / 1_000) % 60;
        const fraction = totalMilliseconds % 1_000;
        return format("%02d:%02d:%02d.%03d", hours, minutes, wholeSeconds, fraction);
    }

    const totalSeconds = cast(long) (seconds + 0.5);
    const hours = totalSeconds / 3_600;
    const minutes = (totalSeconds / 60) % 60;
    const wholeSeconds = totalSeconds % 60;
    return format("%02d:%02d:%02d", hours, minutes, wholeSeconds);
}

/** Compact duration text for status and metadata views. */
string humanDuration(double seconds)
{
    if (seconds < 60.0)
        return format("%.1f s", seconds < 0.0 ? 0.0 : seconds);
    return formatTimecode(seconds, false);
}

/** Returns the end of a potentially long process message without splitting UTF-8. */
string outputTail(string text, size_t maximumBytes)
{
    const cleaned = text.strip();
    if (maximumBytes == 0 || cleaned.length == 0) return "";
    if (cleaned.length <= maximumBytes) return cleaned;

    size_t start = cleaned.length - maximumBytes;
    while (start < cleaned.length && (cast(ubyte) cleaned[start] & 0xC0) == 0x80)
        ++start;
    return "…" ~ cleaned[start .. $];
}

/** Ensures a path has the requested extension, replacing a different extension. */
string ensureExtension(string path, string requiredExtension)
{
    if (path.length == 0) return path;
    if (requiredExtension.length == 0) return path;

    string required = requiredExtension;
    if (required[0] != '.') required = "." ~ required;

    const current = extension(path);
    if (current.toLower() == required.toLower()) return path;
    if (current.length > 0) return path[0 .. $ - current.length] ~ required;
    return path ~ required;
}

/** Returns an absolute path with dot and parent segments normalized. */
string absoluteNormalized(string path)
{
    if (path.length == 0) return "";
    return buildNormalizedPath(absolutePath(path));
}

/** Creates the output file's parent directory when it does not already exist. */
void ensureParentDirectory(string path)
{
    const parent = dirName(path);
    if (parent.length == 0 || parent == "." || exists(parent)) return;
    mkdirRecurse(parent);
}

/** Application-owned cache directory used for previews and temporary render files. */
string applicationCacheDirectory()
{
    string root;
    version (Windows)
    {
        const base = environment.get("LOCALAPPDATA", tempDir());
        root = buildPath(base, "Aurora Cut", "Cache");
    }
    else version (OSX)
    {
        const home = environment.get("HOME", tempDir());
        root = buildPath(home, "Library", "Caches", "Aurora Cut");
    }
    else
    {
        const xdg = environment.get("XDG_CACHE_HOME", "");
        if (xdg.length > 0)
            root = buildPath(xdg, "aurora-cut");
        else
        {
            const home = environment.get("HOME", "");
            root = home.length > 0
                ? buildPath(home, ".cache", "aurora-cut")
                : buildPath(tempDir(), "aurora-cut");
        }
    }

    root = absoluteNormalized(root);
    if (!exists(root)) mkdirRecurse(root);
    return root;
}

/** Creates a unique temporary workspace beneath the application cache. */
string createWorkspace(string prefix)
{
    string safePrefix;
    foreach (character; prefix)
    {
        const valid = (character >= 'a' && character <= 'z') ||
            (character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9') || character == '-' || character == '_';
        safePrefix ~= (valid ? character : '_');
    }
    if (safePrefix.length == 0) safePrefix = "work";

    // A UUID avoids collisions between preview/export worker threads and app instances.
    const workspace = buildPath(applicationCacheDirectory(),
        safePrefix ~ "-" ~ randomUUID().toString());
    mkdir(workspace);
    return workspace;
}

/** Removes a file or directory tree and deliberately ignores cleanup failures. */
void removePathQuietly(string path)
{
    if (path.length == 0) return;
    try
    {
        if (!exists(path)) return;
        if (isDir(path))
            rmdirRecurse(path);
        else
            remove(path);
    }
    catch (Exception)
    {
        // Temporary cleanup must not replace the real import/export error.
    }
}

/** Executes an argv-style command and throws a useful exception on failure. */
string runChecked(string[] arguments, string description = "")
{
    if (arguments.length == 0)
        throw new Exception("Cannot execute an empty command.");

    appLog("RUN " ~ arguments.join(" "));
    const result = execute(arguments, null, Config.suppressConsole, 64 * 1024 * 1024);
    if (result.status != 0)
    {
        const label = description.length > 0 ? description : arguments[0];
        const details = outputTail(result.output, 16 * 1024);
        throw new Exception(format("%s failed with exit code %d.%s%s",
            label, result.status, details.length > 0 ? "\n" : "", details));
    }
    return result.output;
}

/** Checks whether a command can be started from the current PATH. */
bool commandAvailable(string command)
{
    if (command.length == 0) return false;
    try
    {
        const result = execute([command, "-version"], null,
            Config.suppressConsole, 1024 * 1024);
        return result.status == 0;
    }
    catch (Exception)
    {
        return false;
    }
}

/** Supported timeline media: common video, audio, still-image and animated-image files. */
bool isSupportedMediaPath(string path)
{
    const suffix = extension(path).toLower();
    return suffix == ".mp4" || suffix == ".mov" || suffix == ".mkv" ||
        suffix == ".webm" || suffix == ".mp3" || suffix == ".wav" ||
        suffix == ".flac" || suffix == ".ogg" || suffix == ".png" ||
        suffix == ".jpg" || suffix == ".jpeg" || suffix == ".webp" ||
        suffix == ".bmp" || suffix == ".gif";
}
