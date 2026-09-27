module tests.timeline_cache_rail_smoke;

import auroracut.model : EditorModel, MediaAsset, TrackAddress, TrackKind;
import auroracut.timeline : TimelineWidget;
import std.stdio : writeln;

private MediaAsset video(string path, double duration)
{
    auto asset = new MediaAsset(path);
    asset.duration = duration;
    asset.hasVideo = true;
    asset.width = 1920;
    asset.height = 1080;
    asset.frameRate = 30.0;
    return asset;
}

int main()
{
    auto model = new EditorModel();
    model.addAsset(video("cached.mp4", 5.0));
    model.addAsset(video("pending.mp4", 5.0));
    const v1 = TrackAddress(TrackKind.video, 0);
    assert(model.addTrack(TrackKind.video) >= 0);
    const v2 = TrackAddress(TrackKind.video, 1);
    assert(model.insertClip(0, v1, 0.0) == 0);
    assert(model.insertClip(1, v2, 2.0) == 0);

    auto timeline = new TimelineWidget(model);
    timeline.setPlaybackCacheReady([true, false]);
    assert(timeline.playbackCacheStateForTesting(1.0) == 1,
        "Cached-only interval is not green");
    assert(timeline.playbackCacheStateForTesting(3.0) == 0,
        "Overlap containing an uncached source is not red");
    assert(timeline.playbackCacheStateForTesting(6.0) == 0,
        "Uncached-only interval is not red");
    assert(timeline.playbackCacheStateForTesting(8.0) == -1,
        "Empty interval should remain neutral");

    timeline.setPlaybackCacheReady([true, true]);
    assert(timeline.playbackCacheStateForTesting(3.0) == 1,
        "Completed overlap did not turn green");
    writeln("Aurora Cut timeline cache rail smoke test passed.");
    return 0;
}
