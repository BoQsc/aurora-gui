module tests.model_smoke;

import auroracut.model : EditorModel, EffectProperty, KeyframeInterpolation,
    MediaAsset, TextAlignment, TimelineClip, TimelineTrack, TrackAddress,
    TrackKind;
import auroracut.project : loadProjectFile, saveProjectFile;
import std.file : exists, remove, tempDir;
import std.math : fabs, isFinite;
import std.path : buildPath;
import std.stdio : writeln;

private bool near(double left, double right, double epsilon = 0.000_1)
{
    return fabs(left - right) <= epsilon;
}

private MediaAsset videoAsset(string path, double duration, bool audio = true)
{
    auto asset = new MediaAsset(path);
    asset.duration = duration;
    asset.hasVideo = true;
    asset.hasAudio = audio;
    asset.width = 1920;
    asset.height = 1080;
    asset.frameRate = 30.0;
    asset.audioChannels = audio ? 2 : 0;
    asset.sampleRate = audio ? 48_000 : 0;
    return asset;
}

private MediaAsset audioAsset(string path, double duration)
{
    auto asset = new MediaAsset(path);
    asset.duration = duration;
    asset.hasAudio = true;
    asset.audioChannels = 2;
    asset.sampleRate = 48_000;
    return asset;
}

private bool clipIdsUnique(EditorModel model)
{
    bool[ulong] found;
    foreach (kind; [TrackKind.video, TrackKind.audio])
        foreach (track; model.tracks(kind))
            foreach (clip; track.clips)
            {
                if (clip.id == 0 || clip.id in found) return false;
                found[clip.id] = true;
            }
    return true;
}

int main()
{
    auto model = new EditorModel();
    const v1 = TrackAddress(TrackKind.video, 0);
    const a1 = TrackAddress(TrackKind.audio, 0);
    assert(model.trackCount(TrackKind.video) == 1);
    assert(model.trackCount(TrackKind.audio) == 1);
    assert(model.trackValue(v1).height == 24 && model.trackValue(a1).height == 24,
        "Default tracks are too short for ordinary item text");
    assert(v1.label() == "V1" && a1.label() == "A1");

    const av = model.addAsset(videoAsset("camera-av.mp4", 4.0));
    const videoOnly = model.addAsset(videoAsset("overlay.mp4", 2.0, false));
    const audio = model.addAsset(audioAsset("music.mp3", 3.0));
    assert(av == 0 && videoOnly == 1 && audio == 2);
    assert(model.addAsset(model.assets[0]) == av && model.assets.length == 3,
        "Duplicate media should reuse its Project Media index");

    assert(model.insertClip(av, v1, 0.0) == 0);
    const secondV1 = model.insertClip(videoOnly, v1, 1.0);
    assert(secondV1 == 1);
    assert(near(model.trackValue(v1).clips[1].start, 4.0),
        "An overlapping insert was not moved to the nearest free gap");
    assert(model.insertClip(audio, a1, 0.25) == 0);
    assert(isFinite(model.sequenceDuration()) && near(model.sequenceDuration(), 6.0));
    assert(model.clipAtTime(v1, 0.5) == 0);
    assert(model.clipAtTime(v1, 3.999) == 0);
    assert(model.clipAtTime(v1, 4.5) == 1);
    assert(model.clipAtTime(v1, 7.0) == -1);

    // Dynamic tracks must remain intact when a move creates the destination.
    int movedIndex;
    const v2 = TrackAddress(TrackKind.video, 1);
    assert(model.moveClipToTime(v1, 0, v2, 0.75, movedIndex));
    assert(model.trackCount(TrackKind.video) == 2 && movedIndex == 0);
    assert(model.trackValue(v1).clips.length == 1);
    assert(model.trackValue(v2).clips.length == 1);
    assert(near(model.trackValue(v2).clips[0].start, 0.75));

    // Sideways movement uses absolute sequence time and preserves source trim.
    assert(model.moveClipToTime(v2, 0, v2, 1.25, movedIndex));
    assert(near(model.trackValue(v2).clips[cast(size_t) movedIndex].start, 1.25));
    const movedId = model.trackValue(v2).clips[cast(size_t) movedIndex].id;

    const v3Lane = model.addTrack(TrackKind.video);
    const a2Lane = model.addTrack(TrackKind.audio);
    const a3Lane = model.addTrack(TrackKind.audio);
    assert(v3Lane == 2 && a2Lane == 1 && a3Lane == 2);
    const v3 = TrackAddress(TrackKind.video, 2);
    const a3 = TrackAddress(TrackKind.audio, 2);
    assert(model.insertClip(videoOnly, v3, 0.0) == 0);
    assert(model.insertClip(audio, a3, 1.0) == 0);

    const duplicate = model.duplicateClip(v2, movedIndex);
    assert(duplicate >= 0 && model.trackValue(v2).clips.length == 2);
    assert(model.trackValue(v2).clips[cast(size_t) duplicate].id != movedId);

    const splitTime = model.trackValue(v2).clips[0].start + 1.0;
    const right = model.splitAt(v2, splitTime);
    assert(right >= 0 && model.trackValue(v2).clips.length == 3);
    assert(clipIdsUnique(model), "Split/duplicate operations reused a clip ID");

    assert(model.setTrimIn(v2, 0, 0.25));
    assert(model.setTrimOut(v2, 0, 0.75));
    assert(model.setVolume(v2, 0, 1.35));
    assert(model.setMuted(v2, 0, true));
    assert(model.setScale(v2, 0, 0.5));
    assert(model.setPositionX(v2, 0, 0.25));
    assert(model.setPositionY(v2, 0, -0.20));
    assert(model.setOpacity(v2, 0, 0.65));
    auto transformed = model.trackValue(v2).clips[0];
    assert(near(transformed.scale, 0.5) && near(transformed.positionX, 0.25));
    assert(near(transformed.positionY, -0.20) && near(transformed.opacity, 0.65));
    assert(model.resetAudio(v2, 0));
    assert(model.resetTransform(v2, 0));
    assert(model.resetTrim(v2, 0));

    // Undo snapshots share immutable clip arrays, but every later edit must
    // detach the changed lane. This guards both snapshot correctness and the
    // low-memory behavior required by long editing sessions.
    auto snapshotVideo = model.snapshotTracks(TrackKind.video);
    auto snapshotAudio = model.snapshotTracks(TrackKind.audio);
    const snapshotVolume = snapshotVideo[v2.lane].clips[0].volume;
    const snapshotTrackMuted = snapshotAudio[a3.lane].muted;
    assert(model.setVolume(v2, 0, 0.42));
    assert(near(snapshotVideo[v2.lane].clips[0].volume, snapshotVolume),
        "A clip edit mutated a copy-on-write undo snapshot");
    assert(model.setTrackMuted(a3, !snapshotTrackMuted));
    assert(snapshotAudio[a3.lane].muted == snapshotTrackMuted,
        "A track-flag edit mutated a copy-on-write undo snapshot");
    model.restoreTimelineSnapshot(snapshotVideo, snapshotAudio);
    assert(near(model.trackValue(v2).clips[0].volume, snapshotVolume));
    assert(model.trackValue(a3).muted == snapshotTrackMuted);

    assert(model.setTrackMuted(a3, true));
    assert(model.setTrackDisabled(v3, true));
    assert(model.trackValue(a3).muted && model.trackValue(v3).disabled);
    assert(!model.removeTrack(v3), "A non-empty track was removed without permission");
    assert(model.removeClip(v3, 0));
    assert(model.removeTrack(v3), "An empty V3 track could not be removed");
    assert(model.trackCount(TrackKind.video) == 2);

    auto savedVideo = model.cloneTracks(TrackKind.video);
    auto savedAudio = model.cloneTracks(TrackKind.audio);
    const savedDuration = model.sequenceDuration();
    assert(model.removeClip(v1, 0));
    model.restoreTimeline(savedVideo, savedAudio);
    assert(model.trackCount(TrackKind.video) == savedVideo.length);
    assert(model.trackCount(TrackKind.audio) == savedAudio.length);
    assert(near(model.sequenceDuration(), savedDuration));
    assert(clipIdsUnique(model));

    ulong maximumId;
    foreach (track; model.tracks(TrackKind.video))
        foreach (clip; track.clips) if (clip.id > maximumId) maximumId = clip.id;
    const newDuplicate = model.duplicateClip(v2, 0);
    assert(newDuplicate >= 0 &&
        model.trackValue(v2).clips[cast(size_t) newDuplicate].id > maximumId,
        "Timeline restoration did not advance the next clip ID");

    assert(!model.removeAsset(av, false),
        "An in-use Project Media item was removed without removing its clips");
    assert(model.removeAsset(av, true));
    assert(model.assets.length == 2);
    foreach (kind; [TrackKind.video, TrackKind.audio])
        foreach (track; model.tracks(kind))
            foreach (clip; track.clips)
                assert(clip.assetIndex < model.assets.length,
                    "Clip media indices were not repaired after Project Media removal");

    // Clipboard paste, timeline edge resizing, default reset, and keyframe
    // interpolation are independent model operations and never require a render.
    {
        auto featureModel = new EditorModel();
        const featureV1 = TrackAddress(TrackKind.video, 0);
        const featureAsset = featureModel.addAsset(videoAsset("feature.mp4", 8.0));
        const originalIndex = featureModel.insertClip(featureAsset, featureV1, 0.0);

        // Embedded audio can become an independently editable A-track item
        // without changing source trim or sequence alignment.
        assert(featureModel.setVolume(featureV1, originalIndex, 1.25));
        assert(featureModel.setKeyframe(featureV1, originalIndex,
            EffectProperty.volume, 2.0, 0.75));
        TrackAddress detachedTrack;
        int detachedIndex;
        assert(featureModel.detachAudioFromVideo(featureV1, originalIndex,
            detachedTrack, detachedIndex));
        assert(detachedTrack.kind == TrackKind.audio && detachedIndex >= 0);
        const detached = featureModel.trackValue(detachedTrack)
            .clips[cast(size_t) detachedIndex];
        assert(near(detached.start, 0.0) && near(detached.inPoint, 0.0) &&
            near(detached.outPoint, 8.0));
        assert(near(detached.volume, 1.25) && detached.keyframes.length == 1 &&
            detached.keyframes[0].property == EffectProperty.volume);
        assert(featureModel.trackValue(featureV1).clips[0].muted,
            "Detaching audio left embedded video audio active");

        TimelineClip copied;
        assert(featureModel.copyClip(featureV1, originalIndex, copied));
        const pasted = featureModel.pasteClip(featureV1, copied, 4.0);
        assert(pasted >= 0 && featureModel.trackValue(featureV1).clips.length == 2);

        TrackAddress cutoutTrack;
        int cutoutIndex;
        assert(featureModel.insertCutoutClip(featureV1, originalIndex,
            0.20, 0.10, 0.35, 0.45, 0.12, -0.08, 0.72, 0.0, 0.85,
            cutoutTrack, cutoutIndex));
        TimelineClip cutout;
        assert(featureModel.copyClip(cutoutTrack, cutoutIndex, cutout));
        assert(cutoutTrack.kind == TrackKind.video &&
            cutoutTrack.lane > featureV1.lane && cutout.cropEnabled);
        assert(near(cutout.cropX, 0.20) && near(cutout.cropY, 0.10) &&
            near(cutout.cropWidth, 0.35) && near(cutout.cropHeight, 0.45));
        assert(cutout.muted && !cutout.audioProxyVisible &&
            cutout.keyframes.length == 0);
        assert(near(cutout.positionX, 0.12) && near(cutout.positionY, -0.08) &&
            near(cutout.scale, 0.72) && near(cutout.opacity, 0.85));

        const textTrack = TrackAddress(TrackKind.video,
            featureModel.addTrack(TrackKind.video));
        const textIndex = featureModel.insertTextClip(textTrack, 1.0, 5.0, "Text");
        int resizedIndex;
        assert(featureModel.resizeClipTimeline(textTrack, textIndex,
            1.0, 11.0, resizedIndex));
        assert(near(featureModel.trackValue(textTrack).clips[cast(size_t) resizedIndex].duration(), 10.0));
        assert(featureModel.setTextAlignment(textTrack, resizedIndex,
            TextAlignment.center));

        assert(featureModel.setKeyframe(textTrack, resizedIndex,
            EffectProperty.scale, 0.0, 1.0));
        assert(featureModel.setKeyframe(textTrack, resizedIndex,
            EffectProperty.scale, 8.0, 3.0));
        assert(featureModel.setKeyframeInterpolation(textTrack, resizedIndex,
            EffectProperty.scale, 0.0, KeyframeInterpolation.hold));
        auto animated = featureModel.trackValue(textTrack).clips[cast(size_t) resizedIndex];
        assert(near(animated.evaluatedValue(EffectProperty.scale, 4.0), 1.0));
        assert(featureModel.setKeyframeInterpolation(textTrack, resizedIndex,
            EffectProperty.scale, 0.0, KeyframeInterpolation.bezier));
        const animatedBezier = featureModel.trackValue(textTrack).clips[cast(size_t) resizedIndex];
        assert(animatedBezier.evaluatedValue(EffectProperty.scale, 2.0) > 1.0 &&
            animatedBezier.evaluatedValue(EffectProperty.scale, 2.0) < 1.5);
        assert(featureModel.setOpacity(textTrack, resizedIndex, 0.4));
        assert(featureModel.setFadeIn(textTrack, resizedIndex, 1.0));
        assert(featureModel.resetAllProperties(textTrack, resizedIndex));
        const reset = featureModel.trackValue(textTrack).clips[cast(size_t) resizedIndex];
        assert(near(reset.opacity, 1.0) && near(reset.scale, 1.0));
        assert(reset.fadeIn == 0.0 && reset.textAlignment == TextAlignment.left &&
            reset.keyframes.length == 0);

        // Moving a clip edge must keep animation attached to the same
        // absolute sequence moments and preserve interpolation metadata.
        const retimeIndex = featureModel.insertTextClip(textTrack, 20.0, 8.0, "Animated");
        assert(featureModel.setKeyframe(textTrack, retimeIndex,
            EffectProperty.opacity, 3.0, 0.25));
        assert(featureModel.setKeyframe(textTrack, retimeIndex,
            EffectProperty.opacity, 6.0, 0.90));
        assert(featureModel.setKeyframeInterpolation(textTrack, retimeIndex,
            EffectProperty.opacity, 3.0, KeyframeInterpolation.hold));
        int retimedIndex;
        assert(featureModel.resizeClipTimeline(textTrack, retimeIndex,
            21.0, 28.0, retimedIndex));
        const retimed = featureModel.trackValue(textTrack).clips[cast(size_t) retimedIndex];
        assert(near(retimed.start, 21.0));
        assert(near(retimed.evaluatedValue(EffectProperty.opacity, 2.0), 0.25),
            "Resizing a clip edge moved an animation away from sequence time 23s");
        bool preservedHold;
        foreach (keyframe; retimed.keyframes)
            if (keyframe.property == EffectProperty.opacity &&
                near(keyframe.time, 2.0) &&
                keyframe.interpolation == KeyframeInterpolation.hold)
                preservedHold = true;
        assert(preservedHold, "Clip-edge resize discarded keyframe interpolation");
    }

    // Project files preserve editable text styling, animation, track geometry,
    // playhead/range state, and media metadata without requiring FFprobe again.
    {
        auto projectModel = new EditorModel();
        const assetIndex = projectModel.addAsset(videoAsset("saved-video.mp4", 6.0));
        const savedV1 = TrackAddress(TrackKind.video, 0);
        assert(projectModel.insertClip(assetIndex, savedV1, 0.0) == 0);
        TrackAddress savedCutoutTrack;
        int savedCutoutIndex;
        assert(projectModel.insertCutoutClip(savedV1, 0, 0.25, 0.15,
            0.40, 0.35, 0.10, -0.20, 0.80, 0.0, 0.90,
            savedCutoutTrack, savedCutoutIndex));
        const titleLane = projectModel.addTrack(TrackKind.video);
        const titleTrack = TrackAddress(TrackKind.video, titleLane);
        const titleIndex = projectModel.insertTextClip(titleTrack, 1.5, 3.0,
            "Saved title");
        assert(projectModel.setFontName(titleTrack, titleIndex, "Arial"));
        assert(projectModel.setTextBold(titleTrack, titleIndex, true));
        assert(projectModel.setTextItalic(titleTrack, titleIndex, true));
        assert(projectModel.setTextUnderline(titleTrack, titleIndex, true));
        assert(projectModel.setTextAlignment(titleTrack, titleIndex,
            TextAlignment.right));
        assert(projectModel.setTextColor(titleTrack, titleIndex, 0xffffcc00));
        assert(projectModel.setTrackHeight(titleTrack, 36));
        assert(projectModel.setKeyframe(titleTrack, titleIndex,
            EffectProperty.textSize, 0.5, 64.0));
        assert(projectModel.setKeyframeInterpolation(titleTrack, titleIndex,
            EffectProperty.textSize, 0.5, KeyframeInterpolation.hold));

        const projectPath = buildPath(tempDir(),
            "aurora-cut-project-roundtrip.auroracut");
        scope (exit) if (exists(projectPath)) remove(projectPath);
        saveProjectFile(projectPath, projectModel, 2.25, true, 1.0,
            true, 4.5, 1440);
        const loaded = loadProjectFile(projectPath);
        assert(loaded.assets.length == 1 && loaded.videoTracks.length == 3);
        assert(near(loaded.playhead, 2.25) && loaded.hasWorkIn &&
            loaded.hasWorkOut && near(loaded.workIn, 1.0) &&
            near(loaded.workOut, 4.5) && loaded.previewQualityHeight == 1440);
        const savedCutout = loaded.videoTracks[savedCutoutTrack.lane]
            .clips[cast(size_t) savedCutoutIndex];
        assert(savedCutout.cropEnabled && near(savedCutout.cropX, 0.25) &&
            near(savedCutout.cropY, 0.15) &&
            near(savedCutout.cropWidth, 0.40) &&
            near(savedCutout.cropHeight, 0.35) && savedCutout.muted);
        const savedTitle = loaded.videoTracks[2].clips[0];
        assert(savedTitle.text == "Saved title" && savedTitle.fontName == "Arial");
        assert(savedTitle.textBold && savedTitle.textItalic &&
            savedTitle.textUnderline &&
            savedTitle.textAlignment == TextAlignment.right &&
            savedTitle.textColor == 0xffffcc00);
        assert(loaded.videoTracks[2].height == 36 &&
            savedTitle.keyframes.length == 1 &&
            savedTitle.keyframes[0].interpolation == KeyframeInterpolation.hold);

        // Transient UI math must never make project saving fail. Standard JSON
        // has no NaN/Infinity representation, so the serializer records and
        // replaces non-finite values with field-specific safe defaults.
        projectModel.assets[0].frameRate = double.nan;
        auto invalidVideo = projectModel.cloneTracks(TrackKind.video);
        invalidVideo[0].clips[0].positionX = double.nan;
        invalidVideo[2].clips[0].keyframes[0].value = double.infinity;
        projectModel.restoreTimeline(invalidVideo,
            projectModel.cloneTracks(TrackKind.audio));

        const sanitizedPath = buildPath(tempDir(),
            "aurora-cut-project-nonfinite.auroracut");
        scope (exit) if (exists(sanitizedPath)) remove(sanitizedPath);
        saveProjectFile(sanitizedPath, projectModel, double.nan, true,
            double.infinity, true, -double.infinity, 1080);
        const sanitized = loadProjectFile(sanitizedPath);
        assert(isFinite(sanitized.playhead) && isFinite(sanitized.workIn) &&
            isFinite(sanitized.workOut));
        assert(isFinite(sanitized.assets[0].frameRate));
        assert(isFinite(sanitized.videoTracks[0].clips[0].positionX));
        assert(isFinite(sanitized.videoTracks[2].clips[0].keyframes[0].value));
    }

    // Restore a large sorted track and exercise logarithmic hit-testing. This
    // guards the data shape used by the virtualized TimelineWidget.
    auto largeVideo = model.cloneTracks(TrackKind.video);
    largeVideo[0].clips = new TimelineClip[20_000];
    foreach (index, ref clip; largeVideo[0].clips)
    {
        clip.id = 100_000 + index;
        clip.assetIndex = 0;
        clip.start = cast(double) index * 0.05;
        clip.inPoint = 0.0;
        clip.outPoint = 0.04;
        clip.scale = 1.0;
        clip.opacity = 1.0;
    }
    model.restoreTimeline(largeVideo, model.cloneTracks(TrackKind.audio));
    assert(model.clipAtTime(v1, 500.01) == 10_000);
    assert(model.clipAtTime(v1, 500.049) == -1);
    assert(isFinite(model.sequenceDuration()));

    writeln("Aurora Cut multi-track model smoke test passed.");
    return 0;
}
