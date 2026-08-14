module aurorastream.environment;

import aurorastream.browser : browserChoiceLabel;
import aurorastream.broadcast : BroadcastQuality, BroadcastSettings,
    CaptureSelection, EncoderSelection, captureSourceLabel,
    effectiveYoutubeBitrateKbps, qualityShortLabel;
import aurorastream.settings : portableConfigMode;
import std.conv : to;
import std.format : format;
import std.process : Config, execute;
import std.string : indexOf, splitLines, strip;

version (Windows)
{
    import core.sys.windows.windows;
    import std.utf : toUTF16z, toUTF8;
}

/**
 * Builds the startup system-environment report as log lines: OS version/build,
 * architecture, CPU, RAM, GPU(s), current display modes, and the FFmpeg build
 * actually in use. StreamRoot logs each line as a separate `[INFO]` entry so a
 * support session can see the machine at a glance. No personal data.
 */
string[] systemEnvironmentReport()
{
    string[] lines;
    version (Windows)
    {
        lines ~= "OS: " ~ windowsVersionLabel() ~ " (" ~
            architectureLabel() ~ ").";

        const cpu = registryString(
            r"HARDWARE\DESCRIPTION\System\CentralProcessor\0",
            "ProcessorNameString");
        SYSTEM_INFO info;
        GetNativeSystemInfo(&info);
        lines ~= format("CPU: %s (%s logical processors).",
            cpu.length > 0 ? cpu : "unknown", info.dwNumberOfProcessors);

        MEMORYSTATUSEX memory;
        memory.dwLength = MEMORYSTATUSEX.sizeof;
        if (GlobalMemoryStatusEx(&memory) && memory.ullTotalPhys > 0)
            lines ~= format("RAM: %.1f GB.",
                memory.ullTotalPhys / cast(double) (1024 * 1024 * 1024));

        foreach (gpuLine; displayAdapterReport())
            lines ~= gpuLine;
    }
    else
    {
        lines ~= "OS: non-Windows build (limited environment report).";
    }
    lines ~= ffmpegVersionLine();
    return lines;
}

/**
 * Builds the effective-configuration report as log lines. Stream keys and
 * server URLs are NEVER included; key presence is reported only as
 * "configured (hidden)" / "not configured".
 */
string[] settingsReport(const BroadcastSettings settings,
    const EncoderSelection encoder, const CaptureSelection capture)
{
    string[] lines;

    string destinations;
    if (settings.twitchEnabled)
        destinations ~= (destinations.length > 0 ? "+" : "") ~ "Twitch";
    if (settings.youtubeEnabled)
        destinations ~= (destinations.length > 0 ? "+" : "") ~ "YouTube";
    if (destinations.length == 0) destinations = "none";

    lines ~= "Settings: destinations " ~ destinations ~ ".";
    lines ~= "Settings: encoder " ~ encoder.label ~ " (" ~ encoder.name ~
        "); capture " ~ captureSourceLabel(settings, capture) ~ ".";
    lines ~= format("Settings: source canvas %s; YouTube output %s at %d kbps.",
        qualityShortLabel(settings.sourceQuality),
        qualityShortLabel(settings.youtubeQuality),
        effectiveYoutubeBitrateKbps(settings));
    lines ~= "Settings: window-content capture " ~
        (settings.windowContentCapture ? "on" : "off") ~ ".";
    lines ~= "Settings: desktop audio " ~
        deviceName(settings.desktopAudioDevice,
            settings.deviceDisplayNameCache) ~ "; microphone " ~
        deviceName(settings.microphoneDevice,
            settings.deviceDisplayNameCache) ~ ".";
    lines ~= "Settings: live source preview " ~
        (settings.liveSourcePreviewEnabled ? "on" : "off") ~ ".";
    lines ~= "Settings: minimize-to-tray " ~
        (settings.minimizeToTrayOnStart ? "on" : "off") ~
        "; close-to-tray " ~ (settings.closeToTray ? "on" : "off") ~ ".";
    lines ~= "Settings: browser " ~ browserChoiceLabel(settings.browserChoice) ~
        "; config mode " ~ (portableConfigMode() ? "portable" : "per-user") ~ ".";
    lines ~= "Settings: Twitch stream key " ~
        (settings.twitchKey.strip().length > 0 ?
            "configured (hidden)" : "not configured") ~ ".";
    lines ~= "Settings: YouTube stream key " ~
        (settings.youtubeKey.strip().length > 0 ?
            "configured (hidden)" : "not configured") ~ ".";
    return lines;
}

private string ffmpegVersionLine()
{
    try
    {
        const result = execute([
            "ffmpeg", "-hide_banner", "-version"
        ], null, Config.suppressConsole, 2 * 1024 * 1024);
        if (result.status != 0)
            return "FFmpeg: could not run (exit status " ~
                result.status.to!string ~ ").";
        const lines = result.output.splitLines();
        if (lines.length > 0 && lines[0].strip().length > 0)
            return "FFmpeg: " ~ lines[0].strip() ~ ".";
        return "FFmpeg: version output was empty.";
    }
    catch (Exception error)
    {
        return "FFmpeg: not found on PATH (" ~ error.msg ~ ").";
    }
}

version (Windows)
private string windowsVersionLabel()
{
    const key = r"SOFTWARE\Microsoft\Windows NT\CurrentVersion";
    string label = registryString(key, "ProductName");
    const display = registryString(key, "DisplayVersion");
    if (display.length > 0)
        label ~= " " ~ display;
    const build = registryString(key, "CurrentBuildNumber");
    const ubr = registryString(key, "UBR");
    label ~= " (build " ~ build;
    if (ubr.length > 0) label ~= "." ~ ubr;
    label ~= ")";
    return label.length > 0 ? label : "Windows (version unknown)";
}

version (Windows)
private string architectureLabel()
{
    SYSTEM_INFO info;
    GetNativeSystemInfo(&info);
    switch (info.wProcessorArchitecture)
    {
        case PROCESSOR_ARCHITECTURE_AMD64: return "x64";
        case PROCESSOR_ARCHITECTURE_INTEL: return "x86";
        case 12: return "ARM64"; // PROCESSOR_ARCHITECTURE_ARM64 (not in this bindings set)
        default: return "architecture " ~ info.wProcessorArchitecture.to!string;
    }
}

version (Windows)
private string[] displayAdapterReport()
{
    string[] lines;
    DISPLAY_DEVICEW device;
    device.cb = DISPLAY_DEVICEW.sizeof;
    uint adapterIndex;
    while (EnumDisplayDevicesW(null, adapterIndex, &device, 0))
    {
        if ((device.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0)
        {
            string line = format("GPU: %s (%s).",
                wcharToString(device.DeviceString),
                wcharToString(device.DeviceName));
            DEVMODEW mode;
            mode.dmSize = cast(WORD) DEVMODEW.sizeof;
            if (EnumDisplaySettingsW(device.DeviceName.ptr,
                ENUM_CURRENT_SETTINGS, &mode) &&
                mode.dmPelsWidth > 0 && mode.dmPelsHeight > 0)
            {
                line ~= format(" Display %dx%d @%d Hz.",
                    mode.dmPelsWidth, mode.dmPelsHeight,
                    mode.dmDisplayFrequency);
            }
            lines ~= line;
        }
        device = DISPLAY_DEVICEW.init;
        device.cb = DISPLAY_DEVICEW.sizeof;
        ++adapterIndex;
    }
    if (lines.length == 0)
        lines ~= "GPU: none detected.";
    return lines;
}

version (Windows)
private string registryString(string subkey, string valueName)
{
    wchar[512] buffer;
    DWORD size = cast(DWORD)(buffer.length * wchar.sizeof);
    const status = RegGetValueW(HKEY_LOCAL_MACHINE, toUTF16z(subkey),
        toUTF16z(valueName), RRF_RT_REG_SZ, null, buffer.ptr, &size);
    if (status != 0 || size == 0) return "";
    const chars = size / wchar.sizeof;
    return wcharToString(buffer[0 .. (chars > buffer.length ?
        buffer.length : chars)]);
}

version (Windows)
private string wcharToString(const(wchar)[] src)
{
    size_t length;
    while (length < src.length && src[length] != '\0') ++length;
    return toUTF8(src[0 .. length]);
}

private string deviceName(string id, const(string[string]) cache)
{
    if (id.strip().length == 0) return "Disabled";
    const name = id in cache;
    if (name !is null && name.length > 0) return *name;
    return id;
}

unittest
{
    // The settings report must never contain the actual keys or server URLs,
    // only their presence and the safe configuration facts.
    BroadcastSettings settings;
    settings.twitchEnabled = true;
    settings.twitchKey = "super-secret-twitch-key";
    settings.youtubeEnabled = true;
    settings.youtubeKey = "super-secret-youtube-key";
    settings.sourceQuality = BroadcastQuality.fullHD;
    settings.youtubeQuality = BroadcastQuality.twoK;
    settings.youtubeBitrateKbps = 24_000;

    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "libx264";
    encoder.label = "CPU (libx264)";

    CaptureSelection capture;
    capture.label = "GDI fallback (cursor omitted)";

    const lines = settingsReport(settings, encoder, capture);
    foreach (line; lines)
    {
        assert(line.indexOf("super-secret") < 0);
        assert(line.indexOf("twitch-key") < 0);
        assert(line.indexOf("youtube-key") < 0);
    }
    bool foundTwitchPresence;
    bool foundYoutubePresence;
    foreach (line; lines)
    {
        if (line.indexOf("Twitch stream key configured (hidden)") >= 0)
            foundTwitchPresence = true;
        if (line.indexOf("YouTube stream key configured (hidden)") >= 0)
            foundYoutubePresence = true;
    }
    assert(foundTwitchPresence);
    assert(foundYoutubePresence);
}
