module tests.export_smoke;

import auroracut.exporter : ExportClip, ExportJob, ExportKind, ExportPreset,
    ExportRequest, ExportState, compositeFrameArguments,
    compositeStreamArguments, normalizedExportRequestForTesting,
    renderCompositeFrame;
import auroracut.model : EffectKeyframe, EffectProperty, KeyframeInterpolation,
    TextAlignment;
import std.algorithm.searching : canFind, count;
import std.array : join;
import core.thread : Thread;
import core.time : msecs;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.conv : to;
import std.file : exists, read;
import std.process : Config, Redirect, kill, pipeProcess, wait;
import std.stdio : writeln;

private ExportState waitFor(ExportJob job)
{
    foreach (_; 0 .. 1_800)
    {
        const state = job.state();
        if (state.done && !state.running) return state;
        Thread.sleep(50.msecs);
    }
    assert(false, "Timed out waiting for FFmpeg export");
}

private ExportPreset smokePreset()
{
    ExportPreset preset;
    preset.width = 320;
    preset.height = 180;
    preset.fps = 24;
    preset.crf = 28;
    preset.videoPreset = "ultrafast";
    preset.previewOptimized = true;
    return preset;
}

private bool near(double left, double right, double epsilon = 0.000_1)
{
    return left >= right - epsilon && left <= right + epsilon;
}

private bool whitespace(ubyte value)
{
    return value == ' ' || value == '\t' || value == '\r' || value == '\n';
}

private string nextToken(const(ubyte)[] data, ref size_t cursor)
{
    while (cursor < data.length)
    {
        if (whitespace(data[cursor])) { ++cursor; continue; }
        if (data[cursor] == '#')
        {
            while (cursor < data.length && data[cursor] != '\n') ++cursor;
            continue;
        }
        break;
    }
    const start = cursor;
    while (cursor < data.length && !whitespace(data[cursor]) && data[cursor] != '#')
        ++cursor;
    return cast(string) data[start .. cursor].idup;
}

private struct Ppm
{
    int width;
    int height;
    ubyte[] pixels;
}

private Ppm loadPpm(string path)
{
    auto raw = cast(ubyte[]) read(path);
    size_t cursor;
    assert(nextToken(raw, cursor) == "P6");
    Ppm result;
    result.width = to!int(nextToken(raw, cursor));
    result.height = to!int(nextToken(raw, cursor));
    assert(to!int(nextToken(raw, cursor)) == 255);
    if (cursor < raw.length)
    {
        if (raw[cursor] == '\r' && cursor + 1 < raw.length && raw[cursor + 1] == '\n')
            cursor += 2;
        else if (whitespace(raw[cursor]))
            ++cursor;
    }
    const required = cast(size_t) result.width * cast(size_t) result.height * 3;
    assert(cursor + required <= raw.length);
    result.pixels = raw[cursor .. cursor + required].dup;
    return result;
}

private ubyte[3] pixel(const Ppm image, int x, int y)
{
    assert(x >= 0 && x < image.width && y >= 0 && y < image.height);
    const offset = (cast(size_t) y * cast(size_t) image.width + cast(size_t) x) * 3;
    return [image.pixels[offset], image.pixels[offset + 1], image.pixels[offset + 2]];
}

private ubyte[] firstRawFrame(string[] command, int width, int height)
{
    auto pipes = pipeProcess(command, Redirect.stdout,
        cast(const string[string]) null, Config.suppressConsole);
    const required = cast(size_t) width * cast(size_t) height * 3;
    auto result = new ubyte[required];
    size_t received;
    while (received < required)
    {
        auto chunk = pipes.stdout.rawRead(result[received .. required]);
        if (chunk.length == 0) break;
        received += chunk.length;
    }
    try pipes.stdout.close(); catch (Exception) {}
    try kill(pipes.pid); catch (Exception) {}
    try wait(pipes.pid); catch (Exception) {}
    assert(received == required, "Live compositor did not produce a complete frame");
    return result;
}

private ubyte[3] rawPixel(const ubyte[] image, int width, int x, int y)
{
    const offset = (cast(size_t) y * cast(size_t) width + cast(size_t) x) * 3;
    return [image[offset], image[offset + 1], image[offset + 2]];
}

int main(string[] arguments)
{
    assert(arguments.length == 5,
        "Usage: export-smoke <base-av.mp4> <overlay.mp4> <extra.mp3> <output-directory>");

    ExportClip base;
    base.path = arguments[1];
    base.start = 0.0;
    base.inPoint = 0.0;
    base.outPoint = 1.0;
    base.hasVideo = true;
    base.hasAudio = true;
    base.sourceWidth = 320;
    base.sourceHeight = 180;
    base.trackIndex = 0;

    ExportClip overlay;
    overlay.path = arguments[2];
    overlay.start = 0.20;
    overlay.inPoint = 0.0;
    overlay.outPoint = 0.60;
    overlay.hasVideo = true;
    overlay.sourceWidth = 160;
    overlay.sourceHeight = 90;
    overlay.trackIndex = 1;
    overlay.scale = 0.50;
    overlay.opacity = 1.0;
    overlay.strokeWidth = 3.0;
    overlay.strokeColor = 0xffffffff;
    overlay.shadowOpacity = 0.55;
    overlay.shadowBlur = 4.0;
    overlay.shadowOffsetX = 6.0;
    overlay.shadowOffsetY = 5.0;

    ExportClip title;
    title.generatedText = true;
    title.start = 0.0;
    title.inPoint = 0.0;
    title.outPoint = 1.0;
    title.trackIndex = 2;
    title.text = "Aurora";
    title.fontName = "DejaVu Sans";
    title.textAlignment = TextAlignment.center;
    title.textSize = 30.0;
    title.positionY = -0.68;
    title.strokeWidth = 2.0;
    title.strokeColor = 0xff101010;
    title.shadowOpacity = 0.7;
    title.shadowBlur = 3.0;
    title.shadowOffsetX = 4.0;
    title.shadowOffsetY = 4.0;
    title.keyframes = [
        EffectKeyframe(EffectProperty.scale, 0.0, 0.9,
            KeyframeInterpolation.bezier),
        EffectKeyframe(EffectProperty.scale, 1.0, 1.15,
            KeyframeInterpolation.linear),
        EffectKeyframe(EffectProperty.opacity, 0.0, 0.35,
            KeyframeInterpolation.hold),
        EffectKeyframe(EffectProperty.opacity, 0.25, 1.0,
            KeyframeInterpolation.linear)
    ];

    ExportClip extraAudio;
    extraAudio.path = arguments[3];
    extraAudio.start = 0.10;
    extraAudio.inPoint = 0.0;
    extraAudio.outPoint = 0.50;
    extraAudio.volume = 0.55;
    extraAudio.hasAudio = true;
    extraAudio.trackIndex = 0;

    ExportRequest composed;
    composed.kind = ExportKind.mp4;
    composed.outputPath = arguments[4] ~ "/composed.mp4";
    composed.video = [base, overlay, title];
    composed.audio = [extraAudio];
    composed.preset = smokePreset();
    assert(composed.sequenceDuration() == 1.0);

    auto ranged = composed;
    ranged.rangeStart = 0.20;
    ranged.rangeEnd = 0.55;
    auto normalizedRange = normalizedExportRequestForTesting(ranged);
    assert(normalizedRange.hasRange() &&
        near(normalizedRange.sequenceDuration(), 0.35),
        "Export Out was not preserved while normalizing the work range");
    assert(normalizedRange.video.length == 3);
    assert(near(normalizedRange.video[0].start, 0.0) &&
        near(normalizedRange.video[0].inPoint, 0.20) &&
        near(normalizedRange.video[0].outPoint, 0.55),
        "Work-range trimming did not clamp the base clip to In/Out");
    assert(near(normalizedRange.video[1].start, 0.0) &&
        near(normalizedRange.video[1].outPoint, 0.35),
        "Work-range trimming did not clamp an overlapping overlay to Out");

    // Interactive preview frames are permanently title-free. The live Aurora
    // title layer is painted by PreviewWidget and must never be burned into the
    // RGB background command.
    const previewCommand = compositeFrameArguments(composed, 0.35).join("\n");
    assert(!previewCommand.canFind("drawtext") &&
        !previewCommand.canFind("title-") && !previewCommand.canFind(".pam"),
        "Interactive preview still burns a second title into its background");
    assert(!previewCommand.canFind("-hwaccel"),
        "CPU preview command unexpectedly contains hardware decode options");

    auto acceleratedPreview = composed;
    acceleratedPreview.videoDecodeInputOptions = ["-hwaccel", "d3d11va"];
    const acceleratedPreviewCommand =
        compositeFrameArguments(acceleratedPreview, 0.35).join("\n");
    assert(acceleratedPreviewCommand.count("-hwaccel") == 2 &&
        acceleratedPreviewCommand.canFind("-hwaccel\nd3d11va\n-ss"),
        "Interactive preview did not apply hardware decode before video inputs");

    // Compatibility frame rendering includes Aurora-rasterized title overlays.
    const activeFramePath = arguments[4] ~ "/composed-active.ppm";
    renderCompositeFrame(composed, 0.35, activeFramePath);
    auto active = loadPpm(activeFramePath);
    assert(active.width == 320 && active.height == 180);
    const center = pixel(active, active.width / 2, active.height / 2);
    const corner = pixel(active, 12, 12);
    assert(center[0] > center[2] + 100,
        "The V2 red overlay was not composited over V1 at the frame center");
    assert(corner[2] > corner[0] + 100,
        "The V1 blue base was not retained outside the scaled overlay");

    // Normal playback uses the live timeline compositor, not a pre-rendered
    // proxy. Validate its first RGB frame through the same advanced layer graph.
    auto liveCommand = compositeStreamArguments(composed, 0.35, 0.70,
        320, 180, 24);
    auto acceleratedLive = composed;
    acceleratedLive.videoDecodeInputOptions = ["-hwaccel", "d3d11va"];
    const acceleratedLiveCommand =
        compositeStreamArguments(acceleratedLive, 0.35, 0.70,
            320, 180, 24).join("\n");
    assert(acceleratedLiveCommand.count("-hwaccel") == 2,
        "Live timeline playback did not apply hardware decode to both video inputs");
    auto liveFrame = firstRawFrame(liveCommand, 320, 180);
    const liveCenter = rawPixel(liveFrame, 320, 160, 90);
    const liveCorner = rawPixel(liveFrame, 320, 12, 12);
    assert(liveCenter[0] > liveCenter[2] + 70,
        "Live timeline playback is missing the V2 overlay");
    assert(liveCorner[2] > liveCorner[0] + 70,
        "Live timeline playback is missing the V1 base");

    const baseFramePath = arguments[4] ~ "/composed-base.ppm";
    renderCompositeFrame(composed, 0.05, baseFramePath);
    auto baseOnly = loadPpm(baseFramePath);
    const baseCenter = pixel(baseOnly, baseOnly.width / 2, baseOnly.height / 2);
    assert(baseCenter[2] > baseCenter[0] + 100,
        "A future overlay leaked into an earlier composition frame");

    // A generated-title shadow must be composed below the title, not fed back
    // into itself. Compare otherwise-identical composition frames.
    auto titleWithoutShadow = composed;
    titleWithoutShadow.video = composed.video.dup;
    titleWithoutShadow.video[2].shadowOpacity = 0.0;
    const noTextShadowPath = arguments[4] ~ "/title-no-shadow.ppm";
    renderCompositeFrame(titleWithoutShadow, 0.35, noTextShadowPath);
    auto noTextShadow = loadPpm(noTextShadowPath);

    const textShadowPath = arguments[4] ~ "/title-with-shadow.ppm";
    renderCompositeFrame(composed, 0.35, textShadowPath);
    auto withTextShadow = loadPpm(textShadowPath);
    assert(noTextShadow.pixels != withTextShadow.pixels,
        "Generated text shadow did not alter the rendered composition");

    // Font selection must alter Aurora's own rasterized title layer.
    ExportClip fontTitle = title;
    fontTitle.positionY = 0.0;
    fontTitle.textSize = 64.0;
    fontTitle.strokeWidth = 0.0;
    fontTitle.shadowOpacity = 0.0;
    fontTitle.keyframes = null;
    version (Windows)
    {
        fontTitle.fontName = "Arial";
    }
    else
    {
        fontTitle.fontName = "DejaVu Sans";
    }
    ExportRequest fontRequest;
    fontRequest.kind = ExportKind.mp4;
    fontRequest.video = [fontTitle];
    fontRequest.preset = smokePreset();
    const firstFontPath = arguments[4] ~ "/title-font-a.ppm";
    renderCompositeFrame(fontRequest, 0.35, firstFontPath);
    auto firstFont = loadPpm(firstFontPath);

    version (Windows)
        fontRequest.video[0].fontName = "Consolas";
    else
        fontRequest.video[0].fontName = "DejaVu Serif";
    const secondFontPath = arguments[4] ~ "/title-font-b.ppm";
    renderCompositeFrame(fontRequest, 0.35, secondFontPath);
    auto secondFont = loadPpm(secondFontPath);
    assert(firstFont.pixels != secondFont.pixels,
        "Changing the selected text font did not alter the rendered title");

    // Render one true 1920x1080 compositor frame and validate larger presets.
    auto fullHdRequest = composed;
    fullHdRequest.preset = ExportPreset.fullHd();
    const fullHdPath = arguments[4] ~ "/composed-1080p.ppm";
    renderCompositeFrame(fullHdRequest, 0.35, fullHdPath);
    auto fullHd = loadPpm(fullHdPath);
    assert(fullHd.width == 1920 && fullHd.height == 1080);
    assert(ExportPreset.quadHd().width == 2560 && ExportPreset.quadHd().height == 1440);
    assert(ExportPreset.ultraHd().width == 3840 && ExportPreset.ultraHd().height == 2160);

    auto job = new ExportJob();
    scope (exit) job.shutdown();
    assert(job.start(composed), "Could not start composed MP4 export");
    const mp4State = waitFor(job);
    assert(mp4State.success, "Composed MP4 export failed: " ~ mp4State.error);
    assert(exists(mp4State.outputPath));

    auto mixedAudio = composed;
    mixedAudio.kind = ExportKind.mp3;
    mixedAudio.outputPath = arguments[4] ~ "/composed.mp3";
    assert(job.start(mixedAudio), "Could not start composed MP3 export");
    const mp3State = waitFor(job);
    assert(mp3State.success, "Composed MP3 export failed: " ~ mp3State.error);
    assert(exists(mp3State.outputPath));

    // A source placed only on V1 must retain its embedded audio in both formats.
    ExportRequest v1Only;
    v1Only.kind = ExportKind.mp4;
    v1Only.outputPath = arguments[4] ~ "/v1-only.mp4";
    v1Only.video = [base];
    v1Only.preset = smokePreset();
    assert(job.start(v1Only));
    const v1Mp4 = waitFor(job);
    assert(v1Mp4.success, v1Mp4.error);

    v1Only.kind = ExportKind.mp3;
    v1Only.outputPath = arguments[4] ~ "/v1-only.mp3";
    assert(job.start(v1Only));
    const v1Mp3 = waitFor(job);
    assert(v1Mp3.success, v1Mp3.error);

    // Cancellation is an O(1) UI operation. The worker owns process reaping
    // and removes any partial output after FFmpeg terminates.
    auto longClip = base;
    longClip.outPoint = 30.0;
    ExportRequest cancellable;
    cancellable.kind = ExportKind.mp4;
    cancellable.outputPath = arguments[4] ~ "/cancelled-partial.mp4";
    cancellable.video = [longClip];
    cancellable.preset = ExportPreset.ultraHd();
    cancellable.preset.videoPreset = "slow";
    assert(job.start(cancellable));
    Thread.sleep(120.msecs);
    auto cancelWatch = StopWatch(AutoStart.yes);
    assert(job.cancel(), "Running export did not accept cancellation");
    cancelWatch.stop();
    assert(cancelWatch.peek.total!"msecs" < 250,
        "Cancelling an export blocked the calling thread");
    const cancelledState = waitFor(job);
    assert(cancelledState.cancelled && !cancelledState.success,
        "Cancelled export was not reported as cancelled");
    assert(!exists(cancellable.outputPath),
        "Cancelled export left a partial output file behind");

    writeln("Aurora Cut compositor/export smoke test passed.");
    return 0;
}
