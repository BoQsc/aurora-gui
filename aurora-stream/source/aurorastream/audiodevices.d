module aurorastream.audiodevices;

import aurorastream.audioendpoint : AudioEndpoint;
import aurorastream.wasapi : enumerateWasapiRenderEndpoints;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.conv : to;
import std.format : format;
import std.process : Config, Redirect, pipeProcess, wait;
import std.string : indexOf, lastIndexOf, splitLines, startsWith, strip;

/** Result of one background refresh of both independent audio backends. */
struct AudioDeviceScanSnapshot
{
    bool running;
    ulong generation;
    AudioEndpoint[] desktopDevices;
    AudioEndpoint[] microphoneDevices;
    string desktopError;
    string microphoneError;
}

private struct AudioDeviceScanResult
{
    AudioEndpoint[] desktopDevices;
    AudioEndpoint[] microphoneDevices;
    string desktopError;
    string microphoneError;
}

private struct PendingDirectShowDevice
{
    bool active;
    string displayName;
    string alternativeName;
}

private bool containsInputName(const AudioEndpoint[] devices, string inputName)
{
    foreach (device; devices)
        if (device.inputName == inputName) return true;
    return false;
}

private void finishPending(ref PendingDirectShowDevice pending,
    ref AudioEndpoint[] devices)
{
    if (!pending.active || pending.displayName.length == 0)
    {
        pending = PendingDirectShowDevice.init;
        return;
    }

    immutable inputName = pending.alternativeName.length > 0 ?
        pending.alternativeName : pending.displayName;
    if (!containsInputName(devices, inputName))
    {
        AudioEndpoint device;
        device.displayName = pending.displayName;
        device.inputName = inputName;
        device.alternativeName = pending.alternativeName;
        devices ~= device;
    }
    pending = PendingDirectShowDevice.init;
}

private void assignDistinctLabels(ref AudioEndpoint[] devices)
{
    foreach (index; 0 .. devices.length)
    {
        size_t total;
        size_t occurrence;
        foreach (otherIndex; 0 .. devices.length)
        {
            if (devices[otherIndex].displayName != devices[index].displayName)
                continue;
            ++total;
            if (otherIndex <= index) ++occurrence;
        }

        devices[index].label = total > 1 ?
            format("%s — device %s", devices[index].displayName, occurrence) :
            devices[index].displayName;
    }
}

/**
 * Parse microphone/capture endpoints from both FFmpeg DirectShow listing
 * formats. Playback endpoints are intentionally not parsed here; they are
 * enumerated independently through Windows Core Audio for WASAPI loopback.
 */
AudioEndpoint[] parseDirectShowAudioDevices(string source)
{
    AudioEndpoint[] devices;
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
        const hasTypedSuffix = suffix.startsWith("(");
        const isAudio = hasTypedSuffix ? suffix.startsWith("(audio)") :
            inAudioSection;

        finishPending(pending, devices);
        if (!isAudio) continue;

        pending.active = true;
        pending.displayName = line[cast(size_t) firstQuote + 1 ..
            cast(size_t) lastQuote].strip().idup;
    }

    finishPending(pending, devices);
    assignDistinctLabels(devices);
    return devices;
}

private AudioEndpoint[] scanDirectShowMicrophones(out string error)
{
    error = "";
    AudioEndpoint[] devices;
    version (Windows)
    {
        try
        {
            auto pipes = pipeProcess([
                "ffmpeg", "-hide_banner", "-list_devices", "true",
                "-f", "dshow", "-i", "dummy"
            ], Redirect.stderr, cast(const string[string]) null,
                Config.suppressConsole);

            string listing;
            foreach (rawLine; pipes.stderr.byLine())
                listing ~= rawLine.to!string;
            wait(pipes.pid);

            devices = parseDirectShowAudioDevices(listing);
        }
        catch (Exception scanError)
        {
            error = "Could not enumerate DirectShow microphone devices: " ~
                scanError.msg;
        }
    }
    else
    {
        error = "DirectShow microphone enumeration is Windows-only.";
    }
    return devices;
}

private AudioDeviceScanResult scanAudioDevices()
{
    AudioDeviceScanResult result;
    result.desktopDevices = enumerateWasapiRenderEndpoints(result.desktopError);
    result.microphoneDevices = scanDirectShowMicrophones(result.microphoneError);
    return result;
}

/** Runs WASAPI and DirectShow enumeration away from the Aurora UI thread. */
final class AudioDeviceScanner
{
    private Mutex _mutex;
    private Thread _thread;
    private bool _running;
    private bool _shutdown;
    private ulong _generation;
    private AudioEndpoint[] _desktopDevices;
    private AudioEndpoint[] _microphoneDevices;
    private string _desktopError;
    private string _microphoneError;

    this()
    {
        _mutex = new Mutex();
    }

    bool start()
    {
        Thread completed;
        _mutex.lock();
        if (_running || _shutdown)
        {
            _mutex.unlock();
            return false;
        }
        completed = _thread;
        _thread = null;
        _running = true;
        _desktopError = "";
        _microphoneError = "";
        _mutex.unlock();

        if (completed !is null)
        {
            try completed.join();
            catch (Exception) {}
        }

        try
        {
            auto worker = new Thread({ runScan(); });
            worker.isDaemon = true;
            _mutex.lock();
            _thread = worker;
            _mutex.unlock();
            worker.start();
            return true;
        }
        catch (Exception threadError)
        {
            _mutex.lock();
            _thread = null;
            _running = false;
            _desktopError = "Could not start audio-device scan: " ~
                threadError.msg;
            _microphoneError = _desktopError;
            ++_generation;
            _mutex.unlock();
            return false;
        }
    }

    AudioDeviceScanSnapshot snapshot()
    {
        AudioDeviceScanSnapshot result;
        _mutex.lock();
        scope (exit) _mutex.unlock();
        result.running = _running;
        result.generation = _generation;
        result.desktopDevices = _desktopDevices;
        result.microphoneDevices = _microphoneDevices;
        result.desktopError = _desktopError;
        result.microphoneError = _microphoneError;
        return result;
    }

    void shutdown()
    {
        Thread worker;
        _mutex.lock();
        _shutdown = true;
        worker = _thread;
        _mutex.unlock();

        if (worker !is null)
        {
            try worker.join();
            catch (Exception) {}
        }
    }

    private void runScan()
    {
        auto result = scanAudioDevices();
        _mutex.lock();
        if (!_shutdown)
        {
            _desktopDevices = result.desktopDevices;
            _microphoneDevices = result.microphoneDevices;
            _desktopError = result.desktopError;
            _microphoneError = result.microphoneError;
            ++_generation;
        }
        _running = false;
        _mutex.unlock();
    }
}

unittest
{
    const oldFormat = q{
[dshow @ 000001] DirectShow video devices (some may be both video and audio devices)
[dshow @ 000001]  "Integrated Camera"
[dshow @ 000001]     Alternative name "@device_pnp_camera"
[dshow @ 000001] DirectShow audio devices
[dshow @ 000001]  "Stereo Mix (Realtek(R) Audio)"
[dshow @ 000001]     Alternative name "@device_cm_stereo"
[dshow @ 000001]  "Microphone (USB Audio Device)"
[dshow @ 000001]     Alternative name "@device_cm_microphone"
};

    const devices = parseDirectShowAudioDevices(oldFormat);
    assert(devices.length == 2);
    assert(devices[0].displayName == "Stereo Mix (Realtek(R) Audio)");
    assert(devices[0].inputName == "@device_cm_stereo");
    assert(devices[1].label == "Microphone (USB Audio Device)");
}

unittest
{
    const newFormat = q{
[dshow @ 000002] "Camo" (video)
[dshow @ 000002]   Alternative name "@device_pnp_camera"
[dshow @ 000002] "OBS Virtual Camera" (none)
[dshow @ 000002]   Alternative name "@device_sw_camera"
[dshow @ 000002] "Microphone (High Definition Audio Device)" (audio)
[dshow @ 000002]   Alternative name "@device_cm_first"
[dshow @ 000002] "Microphone (High Definition Audio Device)" (audio)
[dshow @ 000002]   Alternative name "@device_cm_second"
[dshow @ 000002] "Microphone (Camo)" (audio)
[dshow @ 000002]   Alternative name "@device_cm_camo"
};

    const devices = parseDirectShowAudioDevices(newFormat);
    assert(devices.length == 3);
    assert(devices[0].label ==
        "Microphone (High Definition Audio Device) — device 1");
    assert(devices[1].label ==
        "Microphone (High Definition Audio Device) — device 2");
    assert(devices[0].inputName == "@device_cm_first");
    assert(devices[1].inputName == "@device_cm_second");
    assert(devices[2].label == "Microphone (Camo)");
}
