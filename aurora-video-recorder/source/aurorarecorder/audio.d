module aurorarecorder.audio;

/**
 * Microphone discovery.
 *
 * ffmpeg's `dshow` input lists DirectShow capture devices and prints them to
 * stderr. Rather than link a COM enumerator, the list is parsed from
 * `ffmpeg -list_devices true -f dshow -i dummy`, which is the same list the
 * recording command will accept. Parsing is a pure function so it can be
 * checked without a microphone.
 */

import std.array : appender;
import std.string : lastIndexOf, splitLines, strip;

/// One capture device, by the friendly name `dshow` expects.
struct AudioDevice
{
    string name;

    bool valid() const pure nothrow @safe { return name.length > 0; }
}

/**
 * Extract the `(audio)` entries from ffmpeg's device listing.
 *
 * Example line:
 *   [dshow @ ...] "Microphone Array (Realtek High Definition Audio)" (audio)
 * `Alternative name` lines are ignored: the friendly name is what the
 * recording command uses.
 */
AudioDevice[] parseAudioDevices(string listing)
{
    auto devices = appender!(AudioDevice[]);
    foreach (line; splitLines(listing))
    {
        const trimmed = strip(line);
        const marker = trimmed.lastIndexOf("\" (audio)");
        if (marker < 0) continue;
        // The name starts after the first quote following the "[dshow ...]"
        // prefix, so search from the end of the bracketed part.
        size_t nameStart;
        bool started;
        for (size_t i = 0; i < marker; ++i)
        {
            if (trimmed[i] != '"') continue;
            nameStart = i + 1;
            started = true;
            break;
        }
        if (!started) continue;
        const name = trimmed[nameStart .. marker];
        if (name.length == 0) continue;
        bool duplicate;
        foreach (existing; devices.data)
            if (existing.name == name) duplicate = true;
        if (!duplicate) devices ~= AudioDevice(name);
    }
    return devices.data;
}

version (Windows)
{
    import std.array : join;
    import std.process : Redirect, pipeProcess, wait;

    /**
     * Run ffmpeg's device listing and return its microphones. Returns an empty
     * array when ffmpeg is missing or lists nothing; the UI then offers
     * "No microphone", which still records video.
     */
    AudioDevice[] listAudioDevices(string ffmpegPath)
    {
        if (ffmpegPath.length == 0) return [];
        try
        {
            auto process = pipeProcess([
                ffmpegPath, "-hide_banner", "-list_devices", "true",
                "-f", "dshow", "-i", "dummy",
            ], Redirect.stderr);
            // ffmpeg always exits non-zero for this listing.
            import std.stdio : stderr;
            const output = process.stderr.byLine.join("\n");
            wait(process.pid);
            return parseAudioDevices(cast(string) output);
        }
        catch (Exception)
        {
            return [];
        }
    }
}
