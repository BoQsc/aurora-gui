module tests.gpu_decode_detection_smoke;

import auroracut.media : inspectToolStatus;
import std.stdio : writeln;

int main()
{
    const tools = inspectToolStatus();
    assert(tools.ffmpeg, "FFmpeg is required for decode acceleration detection");
    assert(tools.videoDecodeAcceleration.length > 0,
        "Playback decode acceleration label must always be populated");
    if (tools.hardwareVideoDecoding)
    {
        assert(tools.videoDecodeInputOptions.length == 2,
            "Hardware decode must provide a complete FFmpeg input option pair");
        assert(tools.videoDecodeInputOptions[0] == "-hwaccel",
            "Hardware decode input options must start with -hwaccel");
        assert(tools.videoDecodeInputOptions[1].length > 0,
            "Hardware decode accelerator name must not be empty");
    }

    writeln("Playback decode: ", tools.videoDecodeAcceleration);
    return 0;
}
