module aurorastream.pacingdiagnostic;

import aurorastream.audioendpoint : AudioEndpoint;
import aurorastream.broadcast : BroadcastQuality, BroadcastSettings,
    CaptureSelection, EncoderSelection, detectCaptureBackend, detectEncoder,
    pacingDiagnosticArguments, qualityShortLabel, videoPipelineLabel;
import aurorastream.audiobridge : AudioBridgeSession;
import aurorastream.settings : loadSettings;
import aurorastream.wasapi : enumerateWasapiRenderEndpoints;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm : sort;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : exists, getSize, mkdirRecurse, remove, write;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs, sqrt;
import std.path : absolutePath, buildPath;
import std.process : Config, Redirect, execute, kill, pipeProcess, wait;
import std.stdio : readln, writeln;
import std.string : indexOf, join, replace, split, splitLines, strip;

private enum diagnosticSeconds = 15;
private enum expectedVideoFps = 60.0;

private enum AudioPhaseMode
{
    ffmpegSynthetic,
    isolatedRtpSilence,
    wasapiLoopback
}

private struct ProgressSample
{
    double outputSeconds = 0.0;
    double fps = 0.0;
    double speed = 0.0;
    long duplicatedFrames;
    long droppedFrames;
}

private struct PhaseResult
{
    string label;
    string outputPath;
    string logPath;
    string[] arguments;
    bool success;
    int exitCode = -1;
    double wallSeconds = 0.0;
    ProgressSample[] progress;
    string bridgeMetrics;
    ulong ffmpegQueueWarnings;
    string error;
}

private struct VideoAnalysis
{
    bool valid;
    size_t frameCount;
    double firstTimestamp = 0.0;
    double lastTimestamp = 0.0;
    double duration = 0.0;
    double averageInterval = 0.0;
    double minimumInterval = 0.0;
    double maximumInterval = 0.0;
    double intervalDeviation = 0.0;
    double p95Interval = 0.0;
    double p99Interval = 0.0;
    size_t nonMonotonicIntervals;
    size_t longIntervals;
    size_t veryLongIntervals;
    size_t shortIntervals;
    size_t exactConsecutiveDuplicates;
    size_t maximumConsecutiveDuplicateRun;
    string averageFrameRate;
    string realFrameRate;
    string error;
}

private struct AudioAnalysis
{
    bool valid;
    size_t packetCount;
    double firstTimestamp = 0.0;
    double lastTimestamp = 0.0;
    double duration = 0.0;
    double maximumPositiveGap = 0.0;
    double maximumOverlap = 0.0;
    size_t gapsOverFiveMilliseconds;
    size_t overlapsOverFiveMilliseconds;
    string error;
}

private struct FileAnalysis
{
    VideoAnalysis video;
    AudioAnalysis audio;
    ulong fileBytes;
    double containerDuration = 0.0;
    string error;
}

private bool tryParseFiniteNumber(string value, out double result)
{
    try result = value.strip().to!double;
    catch (Exception)
    {
        result = 0.0;
        return false;
    }
    return result == result && result <= double.max && result >= -double.max;
}

private double parseNumber(string value, double fallback = 0.0)
{
    double result = 0.0;
    return tryParseFiniteNumber(value, result) ? result : fallback;
}

private long parseInteger(string value, long fallback = 0)
{
    try return value.strip().to!long;
    catch (Exception) return fallback;
}

private double parseSpeed(string value)
{
    auto clean = value.strip();
    if (clean.length > 0 && clean[$ - 1] == 'x') clean = clean[0 .. $ - 1];
    return parseNumber(clean, 0.0);
}

private double parseClock(string value)
{
    auto fields = value.strip().split(":");
    if (fields.length != 3) return 0.0;
    return parseNumber(fields[0]) * 3600.0 +
        parseNumber(fields[1]) * 60.0 + parseNumber(fields[2]);
}

private bool commandAvailable(string program)
{
    try
    {
        const result = execute([program, "-version"], null,
            Config.suppressConsole, 4 * 1024 * 1024);
        return result.status == 0;
    }
    catch (Exception)
    {
        return false;
    }
}

private string commandText(const string[] arguments)
{
    string[] quoted;
    foreach (argument; arguments)
    {
        if (argument.indexOf(' ') >= 0 || argument.indexOf('\t') >= 0 ||
            argument.indexOf('"') >= 0)
            quoted ~= `"` ~ argument.replace(`"`, `\"`) ~ `"`;
        else
            quoted ~= argument;
    }
    return quoted.join(" ");
}

private void waitForTest(string phase)
{
    writeln();
    writeln(phase);
    writeln("Keep the game visible, keep the camera moving continuously, and keep game audio playing.");
    writeln("Press Enter when ready. The capture will run for ",
        diagnosticSeconds, " seconds.");
    readln();
    writeln("Starting in 2 seconds…");
    Thread.sleep(2_000.msecs);
}

private AudioEndpoint selectDesktopEndpoint(ref BroadcastSettings settings,
    out string explanation)
{
    explanation = "";
    string scanError;
    const endpoints = enumerateWasapiRenderEndpoints(scanError);
    AudioEndpoint selected;

    foreach (endpoint; endpoints)
    {
        if (settings.desktopAudioDevice.length > 0 &&
            endpoint.inputName == settings.desktopAudioDevice)
        {
            selected = endpoint;
            explanation = "Using saved desktop endpoint: " ~ endpoint.label;
            return selected;
        }
    }

    if (settings.desktopAudioDevice.length == 0 &&
        settings.microphoneDevice.length > 0)
    {
        explanation = "Desktop audio is disabled; the audio-enabled phase will use the saved microphone only.";
        return selected;
    }

    foreach (endpoint; endpoints)
    {
        if (endpoint.alternativeName == "default")
        {
            selected = endpoint;
            settings.desktopAudioDevice = endpoint.inputName;
            explanation = "No usable saved desktop endpoint was found; the diagnostic selected the Windows default: " ~
                endpoint.label;
            return selected;
        }
    }

    if (endpoints.length > 0)
    {
        selected = endpoints[0];
        settings.desktopAudioDevice = selected.inputName;
        explanation = "No usable saved/default desktop endpoint was found; the diagnostic selected the first active endpoint: " ~
            selected.label;
        return selected;
    }

    explanation = scanError.length > 0 ? scanError :
        "Windows reported no active desktop playback endpoint.";
    return selected;
}

private PhaseResult runPhase(string executablePath, string label,
    BroadcastSettings settings, const EncoderSelection encoder,
    const CaptureSelection capture, string outputPath, string logPath,
    AudioPhaseMode audioMode)
{
    PhaseResult result;
    result.label = label;
    result.outputPath = outputPath;
    result.logPath = logPath;

    AudioBridgeSession bridge;
    string desktopAudioSdpPath;
    string bridgeError;

    // The isolation diagnostic measures desktop-loopback transport only. A
    // separately selected microphone must not contaminate phases B or C.
    settings.microphoneDevice = "";
    final switch (audioMode)
    {
        case AudioPhaseMode.ffmpegSynthetic:
            settings.desktopAudioDevice = "";
            break;
        case AudioPhaseMode.isolatedRtpSilence:
            bridge = new AudioBridgeSession(executablePath);
            if (!bridge.start("", true, bridgeError))
            {
                result.error = bridgeError;
                return result;
            }
            if (!bridge.validateReceiverReservationHandoff(bridgeError))
            {
                result.error = bridgeError;
                bridge.shutdown();
                return result;
            }
            desktopAudioSdpPath = bridge.sdpPath;
            break;
        case AudioPhaseMode.wasapiLoopback:
            if (settings.desktopAudioDevice.strip().length == 0)
            {
                result.error = "No Windows desktop playback endpoint is selected.";
                return result;
            }
            bridge = new AudioBridgeSession(executablePath);
            if (!bridge.start(settings.desktopAudioDevice, false, bridgeError))
            {
                result.error = bridgeError;
                return result;
            }
            if (!bridge.validateReceiverReservationHandoff(bridgeError))
            {
                result.error = bridgeError;
                bridge.shutdown();
                return result;
            }
            desktopAudioSdpPath = bridge.sdpPath;
            break;
    }

    try
    {
        if (exists(outputPath)) remove(outputPath);
        if (exists(logPath)) remove(logPath);
    }
    catch (Exception) {}

    result.arguments = pacingDiagnosticArguments(settings, encoder, capture,
        desktopAudioSdpPath, outputPath, diagnosticSeconds);

    StopWatch stopwatch = StopWatch(AutoStart.yes);
    string rawLog;
    ProgressSample current;
    try
    {
        if (bridge !is null)
            bridge.releaseReceiverReservations();
        auto pipes = pipeProcess(result.arguments, Redirect.stderr,
            cast(const string[string]) null, Config.suppressConsole);
        bool helperFailureReported;
        foreach (rawLine; pipes.stderr.byLine())
        {
            const line = rawLine.to!string;
            rawLog ~= line;
            if (line.indexOf("buffers queued") >= 0)
                ++result.ffmpegQueueWarnings;

            if (bridge !is null && !helperFailureReported)
            {
                const helperFailure = bridge.failure();
                if (helperFailure.length > 0)
                {
                    helperFailureReported = true;
                    result.error = "Audio helper failed: " ~ helperFailure;
                    try kill(pipes.pid);
                    catch (Exception) {}
                }
            }

            const clean = line.strip();
            const separator = clean.indexOf('=');
            if (separator <= 0) continue;
            const key = clean[0 .. cast(size_t) separator];
            const value = clean[cast(size_t) separator + 1 .. $];
            switch (key)
            {
                case "fps": current.fps = parseNumber(value); break;
                case "speed": current.speed = parseSpeed(value); break;
                case "dup_frames":
                    current.duplicatedFrames = parseInteger(value); break;
                case "drop_frames":
                    current.droppedFrames = parseInteger(value); break;
                case "out_time": current.outputSeconds = parseClock(value); break;
                case "out_time_us":
                    current.outputSeconds = parseNumber(value) / 1_000_000.0;
                    break;
                case "progress":
                    result.progress ~= current;
                    break;
                default: break;
            }
        }
        result.exitCode = wait(pipes.pid);
        result.success = result.exitCode == 0 && exists(outputPath) &&
            result.error.length == 0;
        if (!result.success && result.error.length == 0)
            result.error = format("FFmpeg exited with code %s.",
                result.exitCode);
    }
    catch (Exception error)
    {
        result.error = error.msg;
    }
    result.wallSeconds = cast(double) stopwatch.peek.total!"msecs" / 1000.0;

    if (bridge !is null)
    {
        bridge.shutdown();
        result.bridgeMetrics = bridge.metricsText();
        if (bridgeMetric(result, "rtp_packets_sent") == 0)
        {
            result.success = false;
            if (result.error.length == 0)
                result.error = "The isolated audio helper sent zero RTP packets.";
        }
        if (audioMode == AudioPhaseMode.wasapiLoopback &&
            bridgeMetric(result, "packets_captured") == 0)
        {
            result.success = false;
            result.error = "Phase C captured zero WASAPI packets; this is not a valid real-audio result.";
        }
        if (bridgeMetric(result, "send_failures") > 0)
        {
            result.success = false;
            if (result.error.length == 0)
                result.error = "The isolated audio helper reported RTP send failures.";
        }
    }

    try write(logPath, "Command:\r\n" ~ commandText(result.arguments) ~
        "\r\n\r\n" ~ rawLog);
    catch (Exception) {}
    return result;
}

private string jsonString(const JSONValue object, string key)
{
    if (object.type != JSONType.object) return "";
    const value = key in object;
    if (value is null) return "";
    if (value.type == JSONType.string) return value.str;
    if (value.type == JSONType.integer) return value.integer.to!string;
    if (value.type == JSONType.float_) return value.floating.to!string;
    return "";
}

private JSONValue runJson(string[] arguments, out string error)
{
    error = "";
    try
    {
        const result = execute(arguments, null, Config.suppressConsole,
            128 * 1024 * 1024);
        if (result.status != 0)
        {
            error = format("%s exited with code %s: %s",
                arguments[0], result.status, result.output.strip());
            return JSONValue.init;
        }
        return parseJSON(result.output);
    }
    catch (Exception commandError)
    {
        error = commandError.msg;
        return JSONValue.init;
    }
}

private double percentile(double[] sortedValues, double fraction)
{
    if (sortedValues.length == 0) return 0.0;
    if (fraction <= 0.0) return sortedValues[0];
    if (fraction >= 1.0) return sortedValues[$ - 1];
    const index = cast(size_t)((sortedValues.length - 1) * fraction);
    return sortedValues[index];
}

private size_t exactDuplicateFrames(string path, out size_t maximumRun,
    out string error)
{
    error = "";
    maximumRun = 0;
    try
    {
        const result = execute([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
            "-i", path, "-map", "0:v:0",
            "-vf", "scale=320:-2,format=gray",
            "-f", "framemd5", "-"
        ], null, Config.suppressConsole, 128 * 1024 * 1024);
        if (result.status != 0)
        {
            error = format("framemd5 exited with code %s: %s",
                result.status, result.output.strip());
            return 0;
        }

        string previousHash;
        size_t duplicates;
        size_t currentRun;
        foreach (line; result.output.splitLines())
        {
            const clean = line.strip();
            if (clean.length == 0 || clean[0] == '#') continue;
            const fields = clean.split(",");
            if (fields.length < 6) continue;
            const hash = fields[$ - 1].strip();
            if (previousHash.length > 0 && hash == previousHash)
            {
                ++duplicates;
                ++currentRun;
            }
            else
            {
                currentRun = 1;
            }
            if (currentRun > maximumRun) maximumRun = currentRun;
            previousHash = hash;
        }
        return duplicates;
    }
    catch (Exception commandError)
    {
        error = commandError.msg;
        return 0;
    }
}

private VideoAnalysis analyzeVideo(string path)
{
    VideoAnalysis result;
    string error;
    const root = runJson([
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_frames",
        "-show_entries",
            "frame=best_effort_timestamp_time,pkt_duration_time,key_frame,pict_type:" ~
            "stream=avg_frame_rate,r_frame_rate",
        "-show_streams", "-of", "json", path
    ], error);
    if (error.length > 0)
    {
        result.error = error;
        return result;
    }

    double[] timestamps;
    try
    {
        const framesValue = "frames" in root;
        if (framesValue !is null && framesValue.type == JSONType.array)
        {
            foreach (frame; framesValue.array)
            {
                const value = jsonString(frame, "best_effort_timestamp_time");
                double timestamp;
                if (value.length > 0 && tryParseFiniteNumber(value, timestamp))
                    timestamps ~= timestamp;
            }
        }
        const streamsValue = "streams" in root;
        if (streamsValue !is null && streamsValue.type == JSONType.array &&
            streamsValue.array.length > 0)
        {
            result.averageFrameRate = jsonString(streamsValue.array[0],
                "avg_frame_rate");
            result.realFrameRate = jsonString(streamsValue.array[0],
                "r_frame_rate");
        }
    }
    catch (Exception parseError)
    {
        result.error = parseError.msg;
        return result;
    }

    if (timestamps.length < 2)
    {
        result.error = "ffprobe returned fewer than two timestamped video frames.";
        return result;
    }

    double[] intervals;
    double sum = 0.0;
    double sumSquared = 0.0;
    const expected = 1.0 / expectedVideoFps;
    result.minimumInterval = double.max;
    result.maximumInterval = 0.0;
    foreach (index; 1 .. timestamps.length)
    {
        const interval = timestamps[index] - timestamps[index - 1];
        intervals ~= interval;
        sum += interval;
        if (interval < result.minimumInterval) result.minimumInterval = interval;
        if (interval > result.maximumInterval) result.maximumInterval = interval;
        if (interval <= 0.0) ++result.nonMonotonicIntervals;
        if (interval > expected * 1.5) ++result.longIntervals;
        if (interval > expected * 2.5) ++result.veryLongIntervals;
        if (interval > 0.0 && interval < expected * 0.5)
            ++result.shortIntervals;
    }
    result.averageInterval = sum / intervals.length;
    foreach (interval; intervals)
    {
        const difference = interval - result.averageInterval;
        sumSquared += difference * difference;
    }
    result.intervalDeviation = sqrt(sumSquared / intervals.length);
    auto sortedIntervals = intervals.dup;
    sortedIntervals.sort();
    result.p95Interval = percentile(sortedIntervals, 0.95);
    result.p99Interval = percentile(sortedIntervals, 0.99);
    result.frameCount = timestamps.length;
    result.firstTimestamp = timestamps[0];
    result.lastTimestamp = timestamps[$ - 1];
    result.duration = result.lastTimestamp - result.firstTimestamp + expected;

    string hashError;
    result.exactConsecutiveDuplicates = exactDuplicateFrames(path,
        result.maximumConsecutiveDuplicateRun, hashError);
    if (hashError.length > 0) result.error = hashError;
    result.valid = true;
    return result;
}

private AudioAnalysis analyzeAudio(string path)
{
    AudioAnalysis result;
    string error;
    const root = runJson([
        "ffprobe", "-v", "error", "-select_streams", "a:0",
        "-show_packets", "-show_entries",
            "packet=pts_time,duration_time",
        "-of", "json", path
    ], error);
    if (error.length > 0)
    {
        result.error = error;
        return result;
    }

    try
    {
        const packetsValue = "packets" in root;
        if (packetsValue is null || packetsValue.type != JSONType.array ||
            packetsValue.array.length == 0)
        {
            result.error = "ffprobe returned no audio packets.";
            return result;
        }

        bool havePrevious;
        double previousEnd;
        foreach (packet; packetsValue.array)
        {
            const ptsText = jsonString(packet, "pts_time");
            const durationText = jsonString(packet, "duration_time");
            double pts = 0.0;
            double duration = 0.0;
            if (ptsText.length == 0 || !tryParseFiniteNumber(ptsText, pts))
                continue;
            if (!tryParseFiniteNumber(durationText, duration) || duration < 0.0)
                duration = 0.0;
            if (result.packetCount == 0) result.firstTimestamp = pts;
            result.lastTimestamp = pts;
            ++result.packetCount;
            if (havePrevious)
            {
                const gap = pts - previousEnd;
                if (gap > result.maximumPositiveGap)
                    result.maximumPositiveGap = gap;
                if (gap < result.maximumOverlap)
                    result.maximumOverlap = gap;
                if (gap > 0.005) ++result.gapsOverFiveMilliseconds;
                if (gap < -0.005) ++result.overlapsOverFiveMilliseconds;
            }
            previousEnd = pts + duration;
            havePrevious = true;
        }
        result.duration = previousEnd - result.firstTimestamp;
        result.valid = result.packetCount > 0;
    }
    catch (Exception parseError)
    {
        result.error = parseError.msg;
    }
    return result;
}

private FileAnalysis analyzeFile(string path)
{
    FileAnalysis result;
    try if (exists(path)) result.fileBytes = getSize(path);
    catch (Exception) {}

    string error;
    const root = runJson([
        "ffprobe", "-v", "error", "-show_format", "-of", "json", path
    ], error);
    if (error.length == 0)
    {
        try
        {
            const formatValue = "format" in root;
            if (formatValue !is null)
                result.containerDuration = parseNumber(jsonString(
                    *formatValue, "duration"));
        }
        catch (Exception) {}
    }
    else result.error = error;

    result.video = analyzeVideo(path);
    result.audio = analyzeAudio(path);
    return result;
}

private ProgressSample finalProgress(const PhaseResult phase)
{
    if (phase.progress.length == 0) return ProgressSample.init;
    return phase.progress[$ - 1];
}

private double minimumSettledSpeed(const PhaseResult phase)
{
    double result = double.max;
    bool found;
    foreach (sample; phase.progress)
    {
        if (sample.outputSeconds < 2.0 || sample.speed <= 0.0) continue;
        if (sample.speed < result) result = sample.speed;
        found = true;
    }
    return found ? result : 0.0;
}

private double averageSettledSpeed(const PhaseResult phase)
{
    double sum = 0.0;
    size_t count;
    foreach (sample; phase.progress)
    {
        if (sample.outputSeconds < 2.0 || sample.speed <= 0.0) continue;
        sum += sample.speed;
        ++count;
    }
    return count > 0 ? sum / count : 0.0;
}

private string bytesText(ulong bytes)
{
    const mebibytes = cast(double) bytes / (1024.0 * 1024.0);
    return format("%.2f MiB", mebibytes);
}

private string percentText(ulong part, ulong total)
{
    if (total == 0) return "0.00%";
    return format("%.2f%%", cast(double) part * 100.0 /
        cast(double) total);
}

private void appendPhaseReport(ref string report, const PhaseResult phase,
    const FileAnalysis analysis)
{
    const progress = finalProgress(phase);
    report ~= "\r\n" ~ phase.label ~ "\r\n";
    report ~= "----------------------------------------\r\n";
    report ~= format("Success: %s\r\n", phase.success ? "yes" : "no");
    report ~= format("FFmpeg exit code: %s\r\n", phase.exitCode);
    report ~= format("Wall duration: %.3f s\r\n", phase.wallSeconds);
    report ~= format("Output file: %s\r\n", phase.outputPath);
    report ~= format("Output size: %s\r\n", bytesText(analysis.fileBytes));
    report ~= format("Raw FFmpeg log: %s\r\n", phase.logPath);
    if (phase.error.length > 0)
        report ~= "Phase error: " ~ phase.error ~ "\r\n";

    report ~= "\r\nFFmpeg progress\r\n";
    report ~= format("  final FPS: %.3f\r\n", progress.fps);
    report ~= format("  final speed: %.4fx\r\n", progress.speed);
    report ~= format("  minimum settled speed: %.4fx\r\n",
        minimumSettledSpeed(phase));
    report ~= format("  average settled speed: %.4fx\r\n",
        averageSettledSpeed(phase));
    report ~= format("  duplicated frames: %s\r\n",
        progress.duplicatedFrames);
    report ~= format("  dropped frames: %s\r\n",
        progress.droppedFrames);
    report ~= format("  final output time: %.6f s\r\n",
        progress.outputSeconds);
    report ~= format("  FFmpeg queue warnings: %s\r\n",
        phase.ffmpegQueueWarnings);

    report ~= "\r\nVideo frame analysis\r\n";
    if (analysis.video.valid)
    {
        const video = analysis.video;
        report ~= format("  frames: %s\r\n", video.frameCount);
        report ~= format("  duration: %.6f s\r\n", video.duration);
        report ~= format("  avg_frame_rate: %s\r\n",
            video.averageFrameRate);
        report ~= format("  r_frame_rate: %s\r\n", video.realFrameRate);
        report ~= format("  average interval: %.6f ms\r\n",
            video.averageInterval * 1000.0);
        report ~= format("  minimum interval: %.6f ms\r\n",
            video.minimumInterval * 1000.0);
        report ~= format("  maximum interval: %.6f ms\r\n",
            video.maximumInterval * 1000.0);
        report ~= format("  interval standard deviation: %.6f ms\r\n",
            video.intervalDeviation * 1000.0);
        report ~= format("  p95 interval: %.6f ms\r\n",
            video.p95Interval * 1000.0);
        report ~= format("  p99 interval: %.6f ms\r\n",
            video.p99Interval * 1000.0);
        report ~= format("  non-monotonic intervals: %s\r\n",
            video.nonMonotonicIntervals);
        report ~= format("  intervals over 25 ms: %s\r\n",
            video.longIntervals);
        report ~= format("  intervals over 41.7 ms: %s\r\n",
            video.veryLongIntervals);
        report ~= format("  intervals below 8.3 ms: %s\r\n",
            video.shortIntervals);
        report ~= format("  exact consecutive decoded duplicates: %s\r\n",
            video.exactConsecutiveDuplicates);
        const uniqueFrameCount = video.frameCount >
            video.exactConsecutiveDuplicates ?
            video.frameCount - video.exactConsecutiveDuplicates : 0;
        report ~= format("  effective unique-image rate: %.3f FPS\r\n",
            video.duration > 0.0 ?
                cast(double) uniqueFrameCount / video.duration : 0.0);
        report ~= format("  duplicate ratio: %.3f%%\r\n",
            video.frameCount > 1 ?
                cast(double) video.exactConsecutiveDuplicates * 100.0 /
                    cast(double)(video.frameCount - 1) : 0.0);
        report ~= format("  longest identical-frame run: %s frame%s\r\n",
            video.maximumConsecutiveDuplicateRun,
            video.maximumConsecutiveDuplicateRun == 1 ? "" : "s");
    }
    else report ~= "  unavailable: " ~ analysis.video.error ~ "\r\n";

    report ~= "\r\nAudio packet analysis\r\n";
    if (analysis.audio.valid)
    {
        const audio = analysis.audio;
        report ~= format("  packets: %s\r\n", audio.packetCount);
        report ~= format("  duration: %.6f s\r\n", audio.duration);
        report ~= format("  maximum positive packet gap: %.6f ms\r\n",
            audio.maximumPositiveGap * 1000.0);
        report ~= format("  maximum packet overlap: %.6f ms\r\n",
            audio.maximumOverlap * 1000.0);
        report ~= format("  gaps over 5 ms: %s\r\n",
            audio.gapsOverFiveMilliseconds);
        report ~= format("  overlaps over 5 ms: %s\r\n",
            audio.overlapsOverFiveMilliseconds);
    }
    else report ~= "  unavailable: " ~ analysis.audio.error ~ "\r\n";

    if (phase.bridgeMetrics.length > 0)
    {
        report ~= "\r\nIsolated audio helper\r\n";
        foreach (metricLine; phase.bridgeMetrics.splitLines())
        {
            const clean = metricLine.strip();
            if (clean.length > 0) report ~= "  " ~ clean ~ "\r\n";
        }
    }

}

private bool timingLooksHealthy(const PhaseResult phase,
    const FileAnalysis analysis)
{
    const progress = finalProgress(phase);
    if (!phase.success || !analysis.video.valid) return false;
    if (progress.speed > 0.0 && progress.speed < 0.97) return false;
    if (progress.droppedFrames > 0 || progress.duplicatedFrames > 2)
        return false;
    if (analysis.video.nonMonotonicIntervals > 0 ||
        analysis.video.longIntervals > 0 ||
        analysis.video.veryLongIntervals > 0)
        return false;
    return true;
}


private double decodedDuplicateRatio(const VideoAnalysis video)
{
    if (!video.valid || video.frameCount <= 1) return 0.0;
    return cast(double) video.exactConsecutiveDuplicates /
        cast(double)(video.frameCount - 1);
}

private bool repeatedContentRegressed(const FileAnalysis baseline,
    const FileAnalysis withAudio)
{
    if (!baseline.video.valid || !withAudio.video.valid) return false;
    const baselineRatio = decodedDuplicateRatio(baseline.video);
    const audioRatio = decodedDuplicateRatio(withAudio.video);
    const materiallyMoreDuplicates =
        withAudio.video.exactConsecutiveDuplicates >=
            baseline.video.exactConsecutiveDuplicates + 5 &&
        audioRatio >= baselineRatio + 0.03;
    const materiallyLongerRun =
        withAudio.video.maximumConsecutiveDuplicateRun >=
            baseline.video.maximumConsecutiveDuplicateRun + 3;
    return materiallyMoreDuplicates || materiallyLongerRun;
}

private double effectiveUniqueRate(const FileAnalysis analysis)
{
    if (!analysis.video.valid || analysis.video.duration <= 0.0) return 0.0;
    const uniqueFrames = analysis.video.frameCount >
        analysis.video.exactConsecutiveDuplicates ?
        analysis.video.frameCount -
            analysis.video.exactConsecutiveDuplicates : 0;
    return cast(double) uniqueFrames / analysis.video.duration;
}

private ulong bridgeMetric(const PhaseResult phase, string key)
{
    foreach (line; phase.bridgeMetrics.splitLines())
    {
        const clean = line.strip();
        const separator = clean.indexOf('=');
        if (separator <= 0) continue;
        if (clean[0 .. cast(size_t) separator] != key) continue;
        return cast(ulong) parseInteger(clean[cast(size_t) separator + 1 .. $]);
    }
    return 0;
}

private string diagnosis(const PhaseResult phaseA,
    const FileAnalysis analysisA, const PhaseResult phaseB,
    const FileAnalysis analysisB, const PhaseResult phaseC,
    const FileAnalysis analysisC)
{
    string result = "Diagnosis\r\n---------\r\n";
    if (!phaseA.success || !phaseB.success || !phaseC.success)
    {
        result ~= "At least one isolation phase failed. The comparison is incomplete; inspect that phase's raw FFmpeg log before changing timing or resampling again.\r\n";
        return result;
    }

    const transportRegression = repeatedContentRegressed(analysisA, analysisB);
    const wasapiRegression = repeatedContentRegressed(analysisB, analysisC);
    const rateA = effectiveUniqueRate(analysisA);
    const rateB = effectiveUniqueRate(analysisB);
    const rateC = effectiveUniqueRate(analysisC);

    result ~= format("Effective unique-image rates: A %.3f FPS, B %.3f FPS, C %.3f FPS.\r\n",
        rateA, rateB, rateC);

    if (transportRegression || rateB + 2.0 < rateA)
    {
        result ~= "Phase B regressed relative to Phase A. The isolated helper-process RTP path still regressed without WASAPI. Investigate FFmpeg RTP ingestion or system scheduling before the endpoint.\r\n";
    }
    else if (wasapiRegression || rateC + 2.0 < rateB)
    {
        result ~= "Phases A and B are comparable, but Phase C regressed. The remaining fault is isolated to WASAPI capture, endpoint/driver behavior, packet conversion, or capture-thread scheduling rather than the isolated RTP transport.\r\n";
    }
    else
    {
        result ~= "All three local phases are within the intended motion-cadence range. Repeat the full three-phase test at least three times; only after those local results remain stable should actual RTMP/Twitch delivery be tested.\r\n";
    }

    if (phaseA.ffmpegQueueWarnings > 0 || phaseB.ffmpegQueueWarnings > 0 ||
        phaseC.ffmpegQueueWarnings > 0)
        result ~= "At least one phase emitted an FFmpeg queue warning, so the acceptance criterion is not met.\r\n";
    if (bridgeMetric(phaseC, "packets_captured") == 0)
        result ~= "Phase C captured zero WASAPI packets. The phase is invalid and must not be described as real-audio success.\r\n";
    if (bridgeMetric(phaseC, "maximum_capture_duration_us") >= 16_700)
        result ~= "A WASAPI capture operation lasted at least one 60 FPS video-frame interval inside the isolated helper.\r\n";
    if (bridgeMetric(phaseB, "maximum_send_duration_us") >= 16_700 ||
        bridgeMetric(phaseC, "maximum_send_duration_us") >= 16_700)
        result ~= "An isolated RTP send operation lasted at least one 60 FPS video-frame interval.\r\n";
    if (bridgeMetric(phaseC, "send_failures") > 0)
        result ~= "The isolated RTP helper dropped one or more audio datagrams.\r\n";
    if (bridgeMetric(phaseC, "discontinuities") > 0)
        result ~= "Windows marked one or more WASAPI discontinuities.\r\n";
    return result;
}

int runStreamPacingDiagnostic(string executablePath)
{
    version (Windows)
    {
        writeln("Aurora Stream A/V pacing diagnostic");
        writeln("====================================");
        writeln();
        writeln("This test does not stream and does not print or transmit stream keys.");
        writeln("It records three local Twitch-equivalent FLV files: FFmpeg synthetic audio, isolated helper-process RTP silence, and real WASAPI loopback through the isolated RTP helper.");
        writeln();

        if (!commandAvailable("ffmpeg") || !commandAvailable("ffprobe"))
        {
            writeln("ERROR: ffmpeg and ffprobe must both be available on PATH.");
            return 1;
        }

        bool settingsLoaded;
        string settingsMessage;
        auto settings = loadSettings(settingsLoaded, settingsMessage);
        settings.twitchKey = "";
        settings.youtubeKey = "";
        // Keep this diagnostic limited to the desktop-loopback path.
        settings.microphoneDevice = "";
        writeln(settingsMessage);

        const encoder = detectEncoder();
        const capture = detectCaptureBackend();
        auto diagnosticSettings = settings;
        diagnosticSettings.twitchEnabled = true;
        diagnosticSettings.youtubeEnabled = false;
        diagnosticSettings.twitchQuality = BroadcastQuality.fullHD;
        if (!encoder.ffmpegAvailable)
        {
            writeln("ERROR: FFmpeg could not be started.");
            return 1;
        }

        string endpointExplanation;
        const endpoint = selectDesktopEndpoint(settings, endpointExplanation);
        writeln(endpointExplanation);
        if (settings.desktopAudioDevice.length == 0)
        {
            writeln("ERROR: no Windows desktop playback endpoint is available for phase C.");
            return 1;
        }

        writeln("Capture: ", capture.label);
        writeln("Video path: ", videoPipelineLabel(diagnosticSettings,
            encoder, capture));
        writeln("Encoder: ", encoder.label);
        if (capture.nativeWidth > 0 && capture.nativeHeight > 0)
            writeln("Captured monitor size: ", capture.nativeWidth, "×",
                capture.nativeHeight);
        writeln("Source canvas: ", qualityShortLabel(settings.sourceQuality),
            "60");
        writeln("Diagnostic output: Twitch-equivalent 1080p60 at 6000 kbps plus AAC 160 kbps");
        writeln("Desktop endpoint: ", endpoint.label);
        writeln("Microphone input: disabled for isolation");

        const directory = absolutePath("stream-pacing-diagnostic");
        mkdirRecurse(directory);
        const phaseAPath = buildPath(directory,
            "twitch-local-phase-a-ffmpeg-silence.flv");
        const phaseBPath = buildPath(directory,
            "twitch-local-phase-b-isolated-rtp-silence.flv");
        const phaseCPath = buildPath(directory,
            "twitch-local-phase-c-wasapi-rtp.flv");
        const phaseALog = buildPath(directory,
            "ffmpeg-phase-a-ffmpeg-silence.log");
        const phaseBLog = buildPath(directory,
            "ffmpeg-phase-b-isolated-rtp-silence.log");
        const phaseCLog = buildPath(directory,
            "ffmpeg-phase-c-wasapi-rtp.log");
        const reportPath = buildPath(directory,
            "stream-pacing-diagnostic.txt");

        waitForTest("Phase A of 3 — FFmpeg anullsrc synthetic audio");
        const phaseA = runPhase(executablePath, "PHASE A — FFMPEG SYNTHETIC AUDIO",
            settings, encoder, capture, phaseAPath, phaseALog,
            AudioPhaseMode.ffmpegSynthetic);
        writeln(phaseA.success ? "Phase A completed." :
            "Phase A failed: " ~ phaseA.error);

        waitForTest("Phase B of 3 — isolated helper-process RTP silence");
        const phaseB = runPhase(executablePath, "PHASE B — ISOLATED RTP SILENCE HELPER",
            settings, encoder, capture, phaseBPath, phaseBLog,
            AudioPhaseMode.isolatedRtpSilence);
        writeln(phaseB.success ? "Phase B completed." :
            "Phase B failed: " ~ phaseB.error);

        waitForTest("Phase C of 3 — real WASAPI through isolated RTP helper");
        const phaseC = runPhase(executablePath, "PHASE C — WASAPI THROUGH ISOLATED RTP HELPER",
            settings, encoder, capture, phaseCPath, phaseCLog,
            AudioPhaseMode.wasapiLoopback);
        writeln(phaseC.success ? "Phase C completed." :
            "Phase C failed: " ~ phaseC.error);

        writeln();
        writeln("Analyzing timestamps and decoded frames…");
        const analysisA = analyzeFile(phaseAPath);
        const analysisB = analyzeFile(phaseBPath);
        const analysisC = analyzeFile(phaseCPath);

        string report;
        report ~= "Aurora Stream A/V pacing diagnostic\r\n";
        report ~= "====================================\r\n\r\n";
        report ~= "This report contains no stream keys.\r\n";
        report ~= format("Capture backend: %s\r\n", capture.label);
        report ~= format("Video path: %s\r\n",
            videoPipelineLabel(diagnosticSettings, encoder, capture));
        report ~= format("Encoder: %s\r\n", encoder.label);
        if (capture.nativeWidth > 0 && capture.nativeHeight > 0)
            report ~= format("Captured monitor size: %s×%s\r\n",
                capture.nativeWidth, capture.nativeHeight);
        report ~= format("Source canvas: %s60\r\n",
            qualityShortLabel(settings.sourceQuality));
        report ~= "Output profile: Twitch-equivalent 1920x1080, 60 FPS, 6000 kbps H.264, 160 kbps AAC\r\n";
        report ~= format("Test duration per phase: %s seconds\r\n",
            diagnosticSeconds);
        report ~= format("Desktop endpoint: %s\r\n", endpoint.label);
        report ~= "Microphone: disabled for isolation\r\n";
        appendPhaseReport(report, phaseA, analysisA);
        appendPhaseReport(report, phaseB, analysisB);
        appendPhaseReport(report, phaseC, analysisC);
        report ~= "\r\n" ~ diagnosis(phaseA, analysisA, phaseB,
            analysisB, phaseC, analysisC);
        report ~= "\r\nManual visual comparison\r\n";
        report ~= "------------------------\r\n";
        report ~= "Play all three FLV files locally in VLC or ffplay while watching the same continuously moving game view. Run the complete three-phase diagnostic at least three times before accepting the result.\r\n";
        report ~= "A. twitch-local-phase-a-ffmpeg-silence.flv\r\n";
        report ~= "B. twitch-local-phase-b-isolated-rtp-silence.flv\r\n";
        report ~= "C. twitch-local-phase-c-wasapi-rtp.flv\r\n";
        report ~= "A smooth, B uneven isolates helper-process RTP ingestion. A and B smooth, C uneven isolates WASAPI capture or endpoint handling. All smooth locally permits a separate RTMP/Twitch test.\r\n";

        try write(reportPath, report);
        catch (Exception error)
        {
            writeln("ERROR: could not write report: ", error.msg);
            return 1;
        }

        writeln();
        writeln("Diagnostic complete.");
        writeln("Report: ", reportPath);
        writeln("Phase A file: ", phaseAPath);
        writeln("Phase B file: ", phaseBPath);
        writeln("Phase C file: ", phaseCPath);
        return phaseA.success && phaseB.success && phaseC.success ? 0 : 1;
    }
    else
    {
        writeln("The A/V pacing diagnostic currently requires Windows.");
        return 1;
    }
}
