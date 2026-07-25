/+ dub.json:
{
  "name": "aurora-stream-audio-diagnostic",
  "description": "Standalone Aurora Stream audio-device diagnostic",
  "targetType": "executable"
}
+/

/**
 * Standalone Windows diagnostic for Aurora Stream audio enumeration.
 *
 * It compares:
 *   1. FFmpeg's DirectShow microphone/capture-device listing.
 *   2. The names parsed for the microphone dropdown.
 *   3. Windows playback devices used by the desktop WASAPI dropdown.
 *   4. Windows recording devices used for cross-checking microphones.
 *
 * No third-party D package is used.
 */
module audio_device_diagnostic;

import std.file : write;
import std.format : format;
import std.conv : to;
import std.process : Config, Redirect, execute, pipeProcess, wait;
import std.stdio : stderr, writeln;
import std.string : indexOf, lastIndexOf, splitLines, strip;
import std.utf : toUTF8;

version (Windows)
{
    pragma(lib, "winmm");

    private enum uint maxProductNameLength = 32;
    private alias MMRESULT = uint;

    private struct WaveInCapsW
    {
        ushort manufacturerId;
        ushort productId;
        uint driverVersion;
        wchar[maxProductNameLength] productName;
        uint formats;
        ushort channels;
        ushort reserved;
    }

    private struct WaveOutCapsW
    {
        ushort manufacturerId;
        ushort productId;
        uint driverVersion;
        wchar[maxProductNameLength] productName;
        uint formats;
        ushort channels;
        ushort reserved;
        uint support;
    }

    extern (Windows)
    {
        uint waveInGetNumDevs() nothrow @nogc;
        MMRESULT waveInGetDevCapsW(size_t deviceId, WaveInCapsW* caps,
            uint capsSize) nothrow @nogc;
        uint waveOutGetNumDevs() nothrow @nogc;
        MMRESULT waveOutGetDevCapsW(size_t deviceId, WaveOutCapsW* caps,
            uint capsSize) nothrow @nogc;
    }
}

private struct ParsedDirectShowDevice
{
    string displayName;
    string inputName;
}

private struct PendingDirectShowDevice
{
    bool active;
    string displayName;
    string alternativeName;
}

private bool containsInputName(const ParsedDirectShowDevice[] devices,
    string inputName)
{
    foreach (device; devices)
        if (device.inputName == inputName) return true;
    return false;
}

private void finishPending(ref PendingDirectShowDevice pending,
    ref ParsedDirectShowDevice[] devices)
{
    if (!pending.active || pending.displayName.length == 0)
    {
        pending = PendingDirectShowDevice.init;
        return;
    }

    immutable inputName = pending.alternativeName.length > 0 ?
        pending.alternativeName : pending.displayName;
    if (!containsInputName(devices, inputName))
        devices ~= ParsedDirectShowDevice(pending.displayName, inputName);
    pending = PendingDirectShowDevice.init;
}

private ParsedDirectShowDevice[] parseDirectShowAudioDevices(string source)
{
    ParsedDirectShowDevice[] devices;
    PendingDirectShowDevice pending;
    bool inAudioSection;

    foreach (rawLine; source.splitLines())
    {
        const line = rawLine.strip();
        if (line.indexOf("DirectShow audio devices") >= 0)
        {
            finishPending(pending, devices);
            inAudioSection = true;
            continue;
        }
        if (line.indexOf("DirectShow video devices") >= 0)
        {
            finishPending(pending, devices);
            inAudioSection = false;
            continue;
        }

        if (line.indexOf("Alternative name") >= 0)
        {
            if (!pending.active) continue;
            const firstQuote = line.indexOf('"');
            const lastQuote = line.lastIndexOf('"');
            if (firstQuote < 0 || lastQuote <= firstQuote) continue;
            pending.alternativeName = line[cast(size_t) firstQuote + 1 ..
                cast(size_t) lastQuote].strip().idup;
            continue;
        }

        const firstQuote = line.indexOf('"');
        const lastQuote = line.lastIndexOf('"');
        if (firstQuote < 0 || lastQuote <= firstQuote) continue;

        const suffix = line[cast(size_t) lastQuote + 1 .. $].strip();
        const hasTypedSuffix = suffix.length > 0 && suffix[0] == '(';
        const isAudio = hasTypedSuffix ? suffix.indexOf("(audio)") == 0 :
            inAudioSection;

        finishPending(pending, devices);
        if (!isAudio) continue;
        pending.active = true;
        pending.displayName = line[cast(size_t) firstQuote + 1 ..
            cast(size_t) lastQuote].strip().idup;
    }

    finishPending(pending, devices);
    return devices;
}

private string fixedWideName(const(wchar)[] value)
{
    size_t length;
    while (length < value.length && value[length] != 0) ++length;
    if (length == 0) return "";
    return toUTF8(value[0 .. length]).idup;
}

version (Windows)
{
    private string[] windowsRecordingDevices(ref string[] errors)
    {
        string[] devices;
        const count = waveInGetNumDevs();
        foreach (deviceId; 0 .. count)
        {
            WaveInCapsW caps;
            const result = waveInGetDevCapsW(cast(size_t) deviceId, &caps,
                cast(uint) WaveInCapsW.sizeof);
            if (result != 0)
            {
                errors ~= format("waveInGetDevCapsW(%s) failed with MMRESULT %s",
                    deviceId, result);
                continue;
            }

            immutable name = fixedWideName(caps.productName[]);
            devices ~= (name.length == 0 ?
                format("Recording device %s", deviceId) : name);
        }
        return devices;
    }

    private string[] windowsPlaybackDevices(ref string[] errors)
    {
        string[] devices;
        const count = waveOutGetNumDevs();
        foreach (deviceId; 0 .. count)
        {
            WaveOutCapsW caps;
            const result = waveOutGetDevCapsW(cast(size_t) deviceId, &caps,
                cast(uint) WaveOutCapsW.sizeof);
            if (result != 0)
            {
                errors ~= format("waveOutGetDevCapsW(%s) failed with MMRESULT %s",
                    deviceId, result);
                continue;
            }

            immutable name = fixedWideName(caps.productName[]);
            devices ~= (name.length == 0 ?
                format("Playback device %s", deviceId) : name);
        }
        return devices;
    }
}

private void appendLine(ref string report, string line = "")
{
    report ~= line ~ "\r\n";
    writeln(line);
}

private void appendDevices(ref string report, string[] devices)
{
    if (devices.length == 0)
    {
        appendLine(report, "  (none)");
        return;
    }

    foreach (index, device; devices)
        appendLine(report, format("  %s. %s", index + 1, device));
}

private void appendDirectShowDevices(ref string report,
    ParsedDirectShowDevice[] devices)
{
    if (devices.length == 0)
    {
        appendLine(report, "  (none)");
        return;
    }

    foreach (index, device; devices)
    {
        appendLine(report, format("  %s. %s", index + 1,
            device.displayName));
        if (device.inputName != device.displayName)
            appendLine(report, "     FFmpeg input: " ~ device.inputName);
    }
}

private int runDiagnostic()
{
    version (Windows)
    {
        string report;
        appendLine(report, "Aurora Stream audio-device diagnostic");
        appendLine(report, "=====================================");
        appendLine(report);
        appendLine(report, "This report does not contain stream keys or saved settings.");
        appendLine(report);

        string ffmpegVersion;
        string ffmpegDevices;
        string dshowListing;
        int ffmpegVersionStatus = -1;
        int ffmpegDevicesStatus = -1;
        int dshowStatus = -1;

        try
        {
            const result = execute(["ffmpeg", "-version"],
                cast(const string[string]) null, Config.suppressConsole);
            ffmpegVersionStatus = result.status;
            ffmpegVersion = result.output;
        }
        catch (Exception error)
        {
            ffmpegVersion = "Could not start ffmpeg: " ~ error.msg;
        }

        try
        {
            const result = execute(["ffmpeg", "-hide_banner", "-devices"],
                cast(const string[string]) null, Config.suppressConsole);
            ffmpegDevicesStatus = result.status;
            ffmpegDevices = result.output;
        }
        catch (Exception error)
        {
            ffmpegDevices = "Could not query FFmpeg devices: " ~ error.msg;
        }

        try
        {
            auto pipes = pipeProcess([
                "ffmpeg", "-hide_banner", "-list_devices", "true",
                "-f", "dshow", "-i", "dummy"
            ], Redirect.stderr, cast(const string[string]) null,
                Config.suppressConsole);
            foreach (rawLine; pipes.stderr.byLine())
                dshowListing ~= rawLine.to!string;
            dshowStatus = wait(pipes.pid);
        }
        catch (Exception error)
        {
            dshowListing = "Could not run DirectShow enumeration: " ~ error.msg;
        }

        auto parsedDirectShow = parseDirectShowAudioDevices(dshowListing);
        string[] winmmErrors;
        auto playbackDevices = windowsPlaybackDevices(winmmErrors);
        auto recordingDevices = windowsRecordingDevices(winmmErrors);

        appendLine(report, "1. FFmpeg version command");
        appendLine(report, format("Exit status: %s", ffmpegVersionStatus));
        appendLine(report, ffmpegVersion.strip());
        appendLine(report);

        appendLine(report, "2. FFmpeg compiled input/output devices");
        appendLine(report, format("Exit status: %s", ffmpegDevicesStatus));
        appendLine(report, ffmpegDevices.strip());
        appendLine(report);

        appendLine(report, "3. Raw FFmpeg DirectShow enumeration");
        appendLine(report, format("Exit status: %s", dshowStatus));
        appendLine(report,
            "Note: a nonzero status is normal because FFmpeg exits after listing devices.");
        appendLine(report, dshowListing.strip());
        appendLine(report);

        appendLine(report, "4. DirectShow devices accepted for the microphone dropdown");
        appendDirectShowDevices(report, parsedDirectShow);
        appendLine(report);

        appendLine(report,
            "5. Windows playback/render devices (desktop-audio dropdown candidates)");
        appendLine(report,
            "Aurora Stream 0.4.8 enumerates these separately through Windows Core Audio and captures the selected endpoint through WASAPI loopback. WinMM names in this diagnostic may be truncated.");
        appendDevices(report, playbackDevices);
        appendLine(report);

        appendLine(report,
            "6. Windows recording/capture devices (microphone and Stereo Mix candidates)");
        appendDevices(report, recordingDevices);
        appendLine(report);

        if (winmmErrors.length > 0)
        {
            appendLine(report, "7. Windows multimedia API errors");
            appendDevices(report, winmmErrors);
            appendLine(report);
        }

        appendLine(report, "Diagnosis");
        appendLine(report, "---------");

        if (ffmpegDevices.indexOf("dshow") < 0)
        {
            appendLine(report,
                "- FFmpeg did not advertise dshow. The installed FFmpeg build may not include DirectShow input support.");
        }
        else
        {
            appendLine(report, "- FFmpeg advertises DirectShow support.");
        }

        if (parsedDirectShow.length > 0)
        {
            appendLine(report,
                "- The DirectShow parser found microphone/capture devices for the microphone dropdown.");
        }
        else if (dshowListing.indexOf("(audio)") >= 0 ||
            dshowListing.indexOf("DirectShow audio devices") >= 0)
        {
            appendLine(report,
                "- FFmpeg printed audio entries but Aurora Stream parsed none. The raw output identifies a parser-format mismatch.");
        }
        else if (dshowListing.indexOf("Could not enumerate audio") >= 0 ||
            dshowListing.indexOf("none found") >= 0)
        {
            appendLine(report,
                "- FFmpeg reached DirectShow but DirectShow returned no audio capture devices.");
        }
        else
        {
            appendLine(report,
                "- FFmpeg did not print any DirectShow audio entries. Check the raw command output and FFmpeg build.");
        }

        if (recordingDevices.length > 0 && parsedDirectShow.length == 0)
        {
            appendLine(report,
                "- Windows sees recording devices while FFmpeg does not. This points to FFmpeg/DirectShow enumeration rather than missing microphone hardware.");
        }

        if (playbackDevices.length > 0)
        {
            appendLine(report,
                "- Windows sees playback devices. Aurora Stream 0.4.8 should show these in the desktop-audio dropdown and capture the selected render endpoint through WASAPI loopback.");
        }

        appendLine(report);
        appendLine(report,
            "Saved report: audio-device-diagnostic.txt");

        try write("audio-device-diagnostic.txt", report);
        catch (Exception error)
        {
            stderr.writeln("Could not save audio-device-diagnostic.txt: ", error.msg);
            return 2;
        }
        return 0;
    }
    else
    {
        writeln("This diagnostic is only supported on Windows.");
        return 1;
    }
}

int main()
{
    try return runDiagnostic();
    catch (Throwable error)
    {
        stderr.writeln("Audio diagnostic failed: ", error.toString());
        return 1;
    }
}
