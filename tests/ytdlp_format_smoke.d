module tests.ytdlp_format_smoke;

import auroracut.ytdlp : normalizeYtDlpMaxHeight, ytDlpMaxWidthForHeight,
    ytDlpNormalizedVideoArguments, ytDlpVideoFormatForHeight,
    ytDlpVideoNormalizeFilterForHeight, ytDlpVideoSortForHeight;
import std.algorithm.searching : canFind;
import std.array : join;
import std.file : exists, remove, tempDir;
import std.path : buildPath;
import std.process : Config, execute;

int main(string[] arguments)
{
    assert(normalizeYtDlpMaxHeight(1080) == 1080);
    assert(normalizeYtDlpMaxHeight(720) == 720);
    assert(normalizeYtDlpMaxHeight(9999) == 1080);
    assert(ytDlpMaxWidthForHeight(1080) == 1920);
    assert(ytDlpMaxWidthForHeight(720) == 1280);
    assert(ytDlpVideoFormatForHeight(1080) ==
        "bv*[height=1080][width=1920]+ba/b[height=1080][width=1920]/" ~
        "bv*[height<=1080][width<=1920]+ba/b[height<=1080][width<=1920]");
    assert(ytDlpVideoFormatForHeight(480) ==
        "bv*[height=480][width=854]+ba/b[height=480][width=854]/" ~
        "bv*[height<=480][width<=854]+ba/b[height<=480][width<=854]");
    assert(ytDlpVideoSortForHeight(1080) ==
        "res:1080,width:1920,fps,vcodec:h264,acodec:m4a,ext:mp4:m4a");
    assert(ytDlpVideoNormalizeFilterForHeight(1080).canFind(
        "pad=1920:1080"));
    assert(ytDlpVideoNormalizeFilterForHeight(720).canFind(
        "pad=1280:720"));
    const normalizeCommand = ytDlpNormalizedVideoArguments("in.mp4",
        "out.mp4", 1080).join("\n");
    assert(normalizeCommand.canFind("-vf\n"));
    assert(normalizeCommand.canFind("pad=1920:1080"));
    assert(normalizeCommand.canFind("-c:v\nlibx264"));

    if (arguments.length >= 2)
    {
        const outputPath = buildPath(tempDir(),
            "aurora-ytdlp-normalize-smoke.mp4");
        if (exists(outputPath)) remove(outputPath);
        scope (exit) if (exists(outputPath)) remove(outputPath);
        const normalized = execute(ytDlpNormalizedVideoArguments(arguments[1],
            outputPath, 1080), null, Config.suppressConsole, 16 * 1024 * 1024);
        assert(normalized.status == 0, normalized.output);
        const probe = execute([
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height", "-of", "csv=p=0",
            outputPath
        ], null, Config.suppressConsole, 1024 * 1024);
        assert(probe.status == 0, probe.output);
        assert(probe.output.canFind("1920,1080"), probe.output);
    }
    return 0;
}
