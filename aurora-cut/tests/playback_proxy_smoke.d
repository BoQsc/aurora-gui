module tests.playback_proxy_smoke;

import auroracut.media : MediaProxyResult, MediaProxyService,
    assetNeedsPlaybackProxy, playbackProxyDimensions, playbackProxyFrameRate;
import auroracut.model : EditorModel, MediaAsset;
import auroracut.project : loadProjectFile, saveProjectFile;
import core.thread : Thread;
import core.time : msecs;
import std.file : exists, remove, tempDir;
import std.path : buildPath;
import std.stdio : writeln;

private MediaAsset videoAsset(string path, int width, int height,
    double frameRate, string codec)
{
    auto asset = new MediaAsset(path);
    asset.duration = 2.0;
    asset.hasVideo = true;
    asset.hasAudio = true;
    asset.width = width;
    asset.height = height;
    asset.frameRate = frameRate;
    asset.videoCodec = codec;
    asset.audioChannels = 2;
    asset.sampleRate = 48_000;
    return asset;
}

private bool waitForProxy(MediaProxyService service, out MediaProxyResult result)
{
    foreach (_; 0 .. 500)
    {
        if (service.takeReady(result)) return true;
        Thread.sleep(10.msecs);
    }
    return false;
}

int main(string[] arguments)
{
    auto ready = videoAsset("ready.mp4", 1280, 720, 30.0, "h264");
    assert(!assetNeedsPlaybackProxy(ready));

    auto large = videoAsset("large.mp4", 1920, 1080, 60.0, "av1");
    assert(assetNeedsPlaybackProxy(large));
    int width;
    int height;
    playbackProxyDimensions(large, width, height);
    assert(width == 1280 && height == 720);
    assert(playbackProxyFrameRate(large) == 30);

    auto narrow = videoAsset("narrow.mp4", 1600, 1080, 24.0, "vp9");
    playbackProxyDimensions(narrow, width, height);
    assert(width == 1066 && height == 720);
    assert(playbackProxyFrameRate(narrow) == 24);

    auto model = new EditorModel();
    large.playbackProxyPath = buildPath(tempDir(), "aurora-proxy-smoke.mp4");
    large.playbackProxyWidth = 1280;
    large.playbackProxyHeight = 720;
    large.playbackProxyFrameRate = 30.0;
    model.addAsset(large);

    const projectPath = buildPath(tempDir(), "aurora-proxy-smoke.auroracut");
    if (exists(projectPath)) remove(projectPath);
    scope (exit) if (exists(projectPath)) remove(projectPath);

    saveProjectFile(projectPath, model, 0.0, false, 0.0, false, 0.0, 720);
    const loaded = loadProjectFile(projectPath);
    assert(loaded.assets.length == 1);
    assert(loaded.assets[0].playbackProxyPath == large.playbackProxyPath);
    assert(loaded.assets[0].playbackProxyWidth == 1280);
    assert(loaded.assets[0].playbackProxyHeight == 720);
    assert(loaded.assets[0].playbackProxyFrameRate == 30.0);

    if (arguments.length >= 2)
    {
        auto service = new MediaProxyService();
        scope (exit) service.shutdown();
        auto source = videoAsset(arguments[1], 320, 180, 30.0, "vp9");
        assert(service.enqueue(0, source));
        MediaProxyResult proxy;
        assert(waitForProxy(service, proxy));
        if (!proxy.success()) writeln(proxy.error);
        assert(proxy.success(), proxy.error);
        assert(exists(proxy.proxyPath));
        remove(proxy.proxyPath);
    }
    return 0;
}
