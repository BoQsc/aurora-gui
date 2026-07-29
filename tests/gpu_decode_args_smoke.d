module tests.gpu_decode_args_smoke;

import auroracut.exporter : ExportClip, ExportKind, ExportPreset,
    ExportRequest, compositeFrameArguments, compositeStreamArguments;
import std.algorithm.searching : canFind, count;
import std.array : join;

private ExportPreset previewPreset()
{
    auto preset = ExportPreset.previewForHeight(720);
    preset.width = 1280;
    preset.height = 720;
    preset.fps = 30;
    return preset;
}

int main()
{
    ExportClip base;
    base.path = "base.mp4";
    base.start = 0.0;
    base.inPoint = 0.0;
    base.outPoint = 1.0;
    base.hasVideo = true;
    base.sourceWidth = 1920;
    base.sourceHeight = 1080;

    ExportClip overlay;
    overlay.path = "overlay.mkv";
    overlay.start = 0.15;
    overlay.inPoint = 0.0;
    overlay.outPoint = 0.70;
    overlay.hasVideo = true;
    overlay.sourceWidth = 1280;
    overlay.sourceHeight = 720;
    overlay.scale = 0.5;
    overlay.trackIndex = 1;

    ExportClip still;
    still.path = "still.png";
    still.start = 0.0;
    still.inPoint = 0.0;
    still.outPoint = 1.0;
    still.hasVideo = true;
    still.sourceWidth = 800;
    still.sourceHeight = 600;
    still.trackIndex = 2;

    ExportRequest request;
    request.kind = ExportKind.mp4;
    request.video = [base, overlay, still];
    request.preset = previewPreset();

    const cpuCommand = compositeStreamArguments(request, 0.0, 1.0,
        640, 360, 30).join("\n");
    assert(!cpuCommand.canFind("-hwaccel"),
        "CPU playback command unexpectedly contains hardware decode options");

    request.videoDecodeInputOptions = ["-hwaccel", "d3d11va"];
    request.hardwareVideoDecoding = true;
    request.videoDecodeAcceleration = "D3D11VA";

    const frameCommand = compositeFrameArguments(request, 0.20,
        640, 360).join("\n");
    assert(frameCommand.count("-hwaccel") == 2,
        "Static composition preview did not add hardware decode to both video files");
    assert(frameCommand.canFind("-hwaccel\nd3d11va\n-ss"),
        "Hardware decode options must appear before input seeking");
    assert(!frameCommand.canFind("-hwaccel\nd3d11va\n-loop"),
        "Still image inputs must not receive hardware video decode options");

    const streamCommand = compositeStreamArguments(request, 0.0, 1.0,
        640, 360, 30).join("\n");
    assert(streamCommand.count("-hwaccel") == 2,
        "Live timeline playback did not add hardware decode to both video files");

    return 0;
}
