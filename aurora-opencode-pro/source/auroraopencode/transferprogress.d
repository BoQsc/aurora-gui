module auroraopencode.transferprogress;

import std.conv : to;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.math : isFinite;
import std.string : startsWith, endsWith;

public struct TransferProgress
{
    string phase, path;
    ulong bytesDone, totalBytes, filesDone, totalFiles;
    double bytesPerSecond = 0;
    double remainingSeconds = -1;
    bool totalsKnown;
    bool metadataOnly;

    double fraction() const
    {
        if (phase.endsWith("complete")) return 1;
        const value = totalBytes ? cast(double) bytesDone / totalBytes :
            totalFiles ? cast(double) filesDone / totalFiles : 0;
        return value < 0 ? 0 : value > 1 ? 1 : value;
    }
}

private enum prefix = "\x1eaurora-transfer ";

public string encodeTransferProgress(const ref TransferProgress progress)
{
    JSONValue value;
    value["phase"] = progress.phase;
    value["path"] = progress.path;
    value["bytesDone"] = cast(long) progress.bytesDone;
    value["totalBytes"] = cast(long) progress.totalBytes;
    value["filesDone"] = cast(long) progress.filesDone;
    value["totalFiles"] = cast(long) progress.totalFiles;
    value["bytesPerSecond"] = progress.bytesPerSecond;
    value["remainingSeconds"] = progress.remainingSeconds;
    value["totalsKnown"] = progress.totalsKnown;
    value["metadataOnly"] = progress.metadataOnly;
    return prefix ~ value.toString();
}

public bool decodeTransferProgress(string text, out TransferProgress progress)
{
    if (!text.startsWith(prefix) || text.length > 32768) return false;
    try
    {
        const value = parseJSON(text[prefix.length .. $]);
        progress.phase = value["phase"].str;
        progress.path = value["path"].str;
        progress.bytesDone = cast(ulong) value["bytesDone"].integer;
        progress.totalBytes = cast(ulong) value["totalBytes"].integer;
        progress.filesDone = cast(ulong) value["filesDone"].integer;
        progress.totalFiles = cast(ulong) value["totalFiles"].integer;
        progress.bytesPerSecond = value["bytesPerSecond"].get!double;
        progress.remainingSeconds = value["remainingSeconds"].get!double;
        progress.totalsKnown = value["totalsKnown"].boolean;
        progress.metadataOnly = value["metadataOnly"].boolean;
        return isFinite(progress.bytesPerSecond) && isFinite(progress.remainingSeconds);
    }
    catch (Exception) return false;
}

public string transferBytes(ulong bytes)
{
    if (bytes < 1024) return to!string(bytes) ~ " B";
    double amount = bytes;
    string unit = "B";
    foreach (candidate; ["KiB", "MiB", "GiB", "TiB", "PiB"])
    {
        amount /= 1024;
        unit = candidate;
        if (amount < 1024) break;
    }
    return format("%.1f %s", amount, unit);
}

public string transferProgressText(const ref TransferProgress progress)
{
    string text = progress.phase;
    if (progress.totalsKnown)
        text ~= format(" · %.0f%% · ", progress.fraction() * 100) ~
            transferBytes(progress.bytesDone) ~ " / " ~ transferBytes(progress.totalBytes) ~
            " · " ~ to!string(progress.filesDone) ~ " / " ~ to!string(progress.totalFiles) ~ " files";
    else if (progress.bytesDone)
        text ~= " · " ~ transferBytes(progress.bytesDone);
    if (progress.metadataOnly)
        text ~= "\nSame volume: moving names; no file data needs copying.";
    else if (progress.bytesPerSecond > 0)
    {
        text ~= "\n" ~ transferBytes(cast(ulong) progress.bytesPerSecond) ~ "/s";
        if (progress.remainingSeconds >= 0)
        {
            const seconds = cast(ulong) progress.remainingSeconds;
            text ~= " · about " ~ (seconds >= 60 ? to!string(seconds / 60) ~ "m " : "") ~
                to!string(seconds % 60) ~ "s remaining";
        }
    }
    if (progress.path.length) text ~= "\n" ~ progress.path;
    return text;
}
