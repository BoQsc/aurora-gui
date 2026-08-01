module auroracut.model;

import auroracut.util : clampValue;
import std.algorithm.sorting : sort;
import std.math : fabs;
import std.path : baseName, extension, filenameCmp;
import std.string : toLower;

/** Video and audio track families. Each family may contain V1..Vn / A1..An. */
enum TrackKind : ubyte
{
    video,
    audio
}

struct TrackAddress
{
    TrackKind kind = TrackKind.video;
    size_t lane;

    string label() const
    {
        import std.format : format;
        return format("%s%d", kind == TrackKind.video ? "V" : "A", lane + 1);
    }
}

final class MediaAsset
{
    string path;
    string name;
    double duration = 0.0;
    bool hasVideo;
    bool hasAudio;
    // Codec name is persisted so playback can avoid applying a hardware
    // accelerator that was only validated against a different codec.
    string videoCodec;
    int width;
    int height;
    double frameRate = 0.0;
    int audioChannels;
    int sampleRate;
    string playbackProxyPath;
    int playbackProxyWidth;
    int playbackProxyHeight;
    double playbackProxyFrameRate = 0.0;

    this(string path)
    {
        this.path = path;
        this.name = baseName(path);
    }

    bool isStillImage() const
    {
        const suffix = extension(path).toLower();
        return hasVideo && !hasAudio &&
            (suffix == ".png" || suffix == ".jpg" || suffix == ".jpeg" ||
             suffix == ".webp" || suffix == ".bmp");
    }
}

/** Sequence item kind. Text clips are generated composition layers and do not
 * reference Project Media. */
enum ClipKind : ubyte
{
    media,
    text
}

/** Paragraph alignment inside generated text layers. */
enum TextAlignment : ubyte
{
    left,
    center,
    right
}

string textAlignmentName(TextAlignment value) @safe pure nothrow @nogc
{
    final switch (value)
    {
        case TextAlignment.left: return "left";
        case TextAlignment.center: return "center";
        case TextAlignment.right: return "right";
    }
}

string textAlignmentLabel(TextAlignment value) @safe pure nothrow @nogc
{
    final switch (value)
    {
        case TextAlignment.left: return "Left";
        case TextAlignment.center: return "Center";
        case TextAlignment.right: return "Right";
    }
}

TextAlignment textAlignmentFromName(string value) @safe pure nothrow
{
    switch (value)
    {
        case "center": return TextAlignment.center;
        case "right": return TextAlignment.right;
        case "left": return TextAlignment.left;
        default: return TextAlignment.left;
    }
}

/** Properties that can carry linear keyframes. Times are relative to clip start. */
enum EffectProperty : ubyte
{
    volume,
    scale,
    positionX,
    positionY,
    opacity,
    rotation,
    textSize
}

/** Interpolation used from this keyframe to the next keyframe. */
enum KeyframeInterpolation : ubyte
{
    linear,
    bezier,
    hold
}

struct EffectKeyframe
{
    EffectProperty property;
    double time;
    double value;
    KeyframeInterpolation interpolation = KeyframeInterpolation.linear;
}

/** A clip has an absolute sequence start, source trim, effects, and optional text. */
struct TimelineClip
{
    ulong id;
    ClipKind kind = ClipKind.media;
    size_t assetIndex;
    double start = 0.0;
    double inPoint = 0.0;
    double outPoint = 0.0;

    // Audio effects.
    double volume = 1.0;
    bool muted;
    // Optional display-only shadow of embedded video audio on A1.
    bool audioProxyVisible;
    // Source-time controls. 1.0 is normal speed; reverse reads source frames
    // from outPoint back toward inPoint.
    double playbackRate = 1.0;
    bool reversed;

    // Source crop/cutout, normalized to the referenced media frame.
    // (0,0,1,1) means the full source image.
    bool cropEnabled;
    double cropX = 0.0;
    double cropY = 0.0;
    double cropWidth = 1.0;
    double cropHeight = 1.0;

    // Composition transform/effects.
    double scale = 1.0;
    double positionX = 0.0; // normalized canvas offset, -2..2
    double positionY = 0.0; // normalized canvas offset, -2..2
    double opacity = 1.0;
    double rotation = 0.0; // degrees
    double fadeIn = 0.0;
    double fadeOut = 0.0;

    // Layer effects. Blur, shadow and stroke are static style controls;
    // transform, opacity, audio gain and text size use linear keyframes.
    double blur = 0.0; // gaussian sigma, 0..40
    double shadowOpacity = 0.0;
    double shadowBlur = 12.0;
    double shadowOffsetX = 12.0; // composition pixels
    double shadowOffsetY = 12.0;
    uint shadowColor = 0xff000000;
    double strokeWidth = 0.0; // composition pixels
    uint strokeColor = 0xffffffff;

    // Generated title layer settings.
    string text = "Title";
    string fontName = "Sans";
    bool textBold;
    bool textItalic;
    bool textUnderline;
    TextAlignment textAlignment = TextAlignment.left;
    double textSize = 96.0;
    uint textColor = 0xffffffff; // AARRGGBB
    bool textBox;
    uint textBoxColor = 0x80000000;

    EffectKeyframe[] keyframes;

    bool isText() const @safe pure nothrow @nogc
    {
        return kind == ClipKind.text;
    }

    bool usesMedia() const @safe pure nothrow @nogc
    {
        return kind == ClipKind.media;
    }

    double duration() const @safe pure nothrow @nogc
    {
        const sourceDuration = outPoint > inPoint ? outPoint - inPoint : 0.0;
        const rate = playbackRate > 0.000_001 ? playbackRate : 1.0;
        return sourceDuration / rate;
    }

    double end() const @safe pure nothrow @nogc
    {
        return start + duration();
    }

    double baseValue(EffectProperty property) const @safe pure nothrow @nogc
    {
        final switch (property)
        {
            case EffectProperty.volume: return volume;
            case EffectProperty.scale: return scale;
            case EffectProperty.positionX: return positionX;
            case EffectProperty.positionY: return positionY;
            case EffectProperty.opacity: return opacity;
            case EffectProperty.rotation: return rotation;
            case EffectProperty.textSize: return textSize;
        }
    }

    /** Evaluate a property with linear, smooth Bezier, or hold interpolation. */
    double evaluatedValue(EffectProperty property, double localTime) const
    {
        double previousTime;
        double previousValue = baseValue(property);
        KeyframeInterpolation previousInterpolation = KeyframeInterpolation.linear;
        bool havePrevious;
        foreach (keyframe; keyframes)
        {
            if (keyframe.property != property) continue;
            if (keyframe.time <= localTime + 0.000_000_5)
            {
                previousTime = keyframe.time;
                previousValue = keyframe.value;
                previousInterpolation = keyframe.interpolation;
                havePrevious = true;
                continue;
            }
            if (!havePrevious) return keyframe.value;
            const span = keyframe.time - previousTime;
            if (span <= 0.000_000_5) return keyframe.value;
            if (previousInterpolation == KeyframeInterpolation.hold)
                return previousValue;
            double amount = clampValue((localTime - previousTime) / span, 0.0, 1.0);
            if (previousInterpolation == KeyframeInterpolation.bezier)
                amount = amount * amount * (3.0 - 2.0 * amount);
            return previousValue + (keyframe.value - previousValue) * amount;
        }
        return previousValue;
    }

    bool hasKeyframe(EffectProperty property, double localTime,
        double tolerance = 0.000_5) const
    {
        foreach (keyframe; keyframes)
            if (keyframe.property == property &&
                fabs(keyframe.time - localTime) <= tolerance) return true;
        return false;
    }
}

struct TimelineTrack
{
    ulong id;
    TrackKind kind = TrackKind.video;
    TimelineClip[] clips;
    bool muted;
    bool disabled;
    int height = 24;

    bool empty() const @safe pure nothrow @nogc
    {
        return clips.length == 0;
    }
}

final class EditorModel
{
    MediaAsset[] assets;
    TimelineTrack[] videoTracks;
    TimelineTrack[] audioTracks;

    private ulong _nextClipId = 1;
    private ulong _nextTrackId = 1;

    // Inspector and on-canvas drag gestures detach one track once, then update
    // its private clip storage in place. This prevents O(track-size) copying on
    // every slider or pointer event in long sequences.
    private bool _continuousEdit;
    private TrackAddress _continuousTrack;

    this()
    {
        addTrack(TrackKind.video);
        addTrack(TrackKind.audio);
    }

    int assetIndexForPath(string path) const
    {
        foreach (index, asset; assets)
            if (filenameCmp(asset.path, path) == 0) return cast(int) index;
        return -1;
    }

    size_t addAsset(MediaAsset asset)
    {
        const existing = assetIndexForPath(asset.path);
        if (existing >= 0) return cast(size_t) existing;
        assets ~= asset;
        return assets.length - 1;
    }

    ref TimelineTrack[] tracks(TrackKind kind)
    {
        if (kind == TrackKind.video) return videoTracks;
        return audioTracks;
    }

    const(TimelineTrack)[] tracks(TrackKind kind) const
    {
        return kind == TrackKind.video ? videoTracks : audioTracks;
    }

    size_t trackCount(TrackKind kind) const
    {
        return tracks(kind).length;
    }

    bool validTrack(TrackAddress address) const
    {
        return address.lane < trackCount(address.kind);
    }

    ref TimelineTrack track(TrackAddress address)
    {
        return tracks(address.kind)[address.lane];
    }

    const(TimelineTrack) trackValue(TrackAddress address) const
    {
        return tracks(address.kind)[address.lane];
    }

    bool copyClip(TrackAddress address, int index, out TimelineClip clip) const
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        clip = cloneClip(clips[cast(size_t) index]);
        return true;
    }

    size_t addTrack(TrackKind kind)
    {
        TimelineTrack value;
        value.id = _nextTrackId++;
        value.kind = kind;
        tracks(kind) ~= value;
        return tracks(kind).length - 1;
    }

    size_t ensureTrack(TrackKind kind, size_t lane)
    {
        while (trackCount(kind) <= lane) addTrack(kind);
        return lane;
    }

    bool removeTrack(TrackAddress address, bool removeClips = false)
    {
        auto collection = tracks(address.kind);
        if (address.lane >= collection.length || collection.length <= 1) return false;
        const lane = address.lane;
        if (!removeClips && collection[lane].clips.length > 0) return false;
        tracks(address.kind) = collection[0 .. lane] ~ collection[lane + 1 .. $];
        return true;
    }

    bool setTrackMuted(TrackAddress address, bool value)
    {
        if (!validTrack(address) || trackValue(address).muted == value) return false;
        detachTrackFamily(address.kind);
        track(address).muted = value;
        return true;
    }

    bool setTrackDisabled(TrackAddress address, bool value)
    {
        if (!validTrack(address) || trackValue(address).disabled == value) return false;
        detachTrackFamily(address.kind);
        track(address).disabled = value;
        return true;
    }

    bool setTrackHeight(TrackAddress address, int pixels)
    {
        if (!validTrack(address)) return false;
        pixels = clampValue(pixels, 22, 144);
        if (trackValue(address).height == pixels) return false;
        detachTrackFamily(address.kind);
        track(address).height = pixels;
        return true;
    }

    /** Count all project-media uses in one linear sequence pass. */
    size_t[] assetUseCounts() const
    {
        auto result = new size_t[assets.length];
        foreach (kind; [TrackKind.video, TrackKind.audio])
            foreach (timelineTrack; tracks(kind))
                foreach (clip; timelineTrack.clips)
                    if (clip.usesMedia() && clip.assetIndex < result.length)
                        ++result[clip.assetIndex];
        return result;
    }

    size_t assetUseCount(size_t assetIndex) const
    {
        if (assetIndex >= assets.length) return 0;
        size_t result;
        foreach (kind; [TrackKind.video, TrackKind.audio])
            foreach (timelineTrack; tracks(kind))
                foreach (clip; timelineTrack.clips)
                    if (clip.usesMedia() && clip.assetIndex == assetIndex) ++result;
        return result;
    }

    bool assetIsUsed(size_t assetIndex) const
    {
        return assetUseCount(assetIndex) != 0;
    }

    /** Remove a project asset, optionally removing every timeline clip that uses it. */
    bool removeAsset(size_t assetIndex, bool removeClips)
    {
        if (assetIndex >= assets.length) return false;
        if (!removeClips && assetIsUsed(assetIndex)) return false;

        adjustTracksForRemovedAsset(videoTracks, assetIndex, removeClips);
        adjustTracksForRemovedAsset(audioTracks, assetIndex, removeClips);
        assets = assets[0 .. assetIndex] ~ assets[assetIndex + 1 .. $];
        return true;
    }

    private static void adjustTracksForRemovedAsset(ref TimelineTrack[] timelineTracks,
        size_t assetIndex, bool removeClips)
    {
        foreach (ref timelineTrack; timelineTracks)
        {
            TimelineClip[] result;
            result.reserve(timelineTrack.clips.length);
            foreach (clip; timelineTrack.clips)
            {
                if (clip.usesMedia() && clip.assetIndex == assetIndex && removeClips) continue;
                auto adjusted = clip;
                if (adjusted.usesMedia() && adjusted.assetIndex > assetIndex)
                    --adjusted.assetIndex;
                result ~= adjusted;
            }
            timelineTrack.clips = result;
        }
    }

    MediaAsset assetForClip(const TimelineClip clip)
    {
        return clip.usesMedia() && clip.assetIndex < assets.length ?
            assets[clip.assetIndex] : null;
    }

    const(MediaAsset) assetForClip(const TimelineClip clip) const
    {
        return clip.usesMedia() && clip.assetIndex < assets.length ?
            assets[clip.assetIndex] : null;
    }

    bool canPlace(size_t assetIndex, TrackKind kind) const
    {
        if (assetIndex >= assets.length) return false;
        const asset = assets[assetIndex];
        return kind == TrackKind.video ? asset.hasVideo : asset.hasAudio;
    }

    int appendClip(size_t assetIndex, TrackAddress address)
    {
        ensureTrack(address.kind, address.lane);
        return insertClip(assetIndex, address, trackDuration(address));
    }

    int insertClip(size_t assetIndex, TrackAddress address, double requestedStart)
    {
        endContinuousEdit();
        if (!canPlace(assetIndex, address.kind)) return -1;
        const asset = assets[assetIndex];
        if (asset.duration <= 0.0) return -1;
        ensureTrack(address.kind, address.lane);

        TimelineClip clip;
        clip.id = _nextClipId++;
        clip.kind = ClipKind.media;
        clip.assetIndex = assetIndex;
        clip.inPoint = 0.0;
        clip.outPoint = asset.duration;
        clip.volume = 1.0;
        clip.scale = 1.0;
        clip.opacity = 1.0;
        clip.start = nearestAvailableStart(address, requestedStart, clip.duration());

        detachTrackClips(address);
        return insertSorted(track(address).clips, clip);
    }

    /** Insert a generated text layer on a video track. */
    int insertTextClip(TrackAddress address, double requestedStart,
        double duration = 5.0, string text = "Title")
    {
        endContinuousEdit();
        if (address.kind != TrackKind.video) return -1;
        ensureTrack(address.kind, address.lane);
        duration = clampValue(duration, 0.25, 86_400.0);

        TimelineClip clip;
        clip.id = _nextClipId++;
        clip.kind = ClipKind.text;
        clip.inPoint = 0.0;
        clip.outPoint = duration;
        clip.text = text.length > 0 ? text : "Title";
        clip.textSize = 96.0;
        clip.scale = 1.0;
        clip.opacity = 1.0;
        clip.start = nearestAvailableStart(address, requestedStart, clip.duration());

        detachTrackClips(address);
        return insertSorted(track(address).clips, clip);
    }

    double nearestAvailableStart(TrackAddress address, double desiredStart,
        double duration, ulong excludedClipId = 0) const
    {
        desiredStart = desiredStart < 0.0 ? 0.0 : desiredStart;
        if (!validTrack(address) || duration <= 0.0) return desiredStart;
        const clips = trackValue(address).clips;
        if (clips.length == 0) return desiredStart;

        // The normal insert/move path removes a moved clip before asking for a
        // destination, so it can use a binary-searched neighbourhood. Keep a
        // conservative linear fallback only for callers that explicitly exclude
        // an item still present in the lane.
        if (excludedClipId != 0)
        {
            double best = double.max;
            double bestDistance = double.max;
            double gapStart = 0.0;
            foreach (clip; clips)
            {
                if (clip.id == excludedClipId) continue;
                const gapEnd = clip.start;
                if (gapEnd - gapStart >= duration - 0.000_001)
                {
                    const candidate = clampValue(desiredStart, gapStart,
                        gapEnd - duration);
                    const distance = fabs(candidate - desiredStart);
                    if (distance < bestDistance)
                    {
                        best = candidate;
                        bestDistance = distance;
                    }
                }
                if (clip.end() > gapStart) gapStart = clip.end();
            }
            const tail = desiredStart > gapStart ? desiredStart : gapStart;
            if (fabs(tail - desiredStart) < bestDistance) best = tail;
            return best == double.max ? desiredStart : best;
        }

        size_t low;
        size_t high = clips.length;
        while (low < high)
        {
            const middle = low + (high - low) / 2;
            if (clips[middle].start < desiredStart) low = middle + 1;
            else high = middle;
        }
        const position = low;

        const immediateStart = position == 0 ? 0.0 : clips[position - 1].end();
        const immediateEnd = position < clips.length ? clips[position].start : double.max;
        if (immediateEnd == double.max ||
            immediateEnd - immediateStart >= duration - 0.000_001)
            return clampValue(desiredStart, immediateStart,
                immediateEnd == double.max ? desiredStart > immediateStart ? desiredStart : immediateStart :
                immediateEnd - duration);

        double best = double.max;
        double bestDistance = double.max;

        // First fitting gap encountered while walking left is the closest on the
        // left because all earlier gap ends are monotonically smaller.
        for (size_t boundary = position; boundary > 0; --boundary)
        {
            const rightIndex = boundary - 1;
            const gapEnd = clips[rightIndex].start;
            const gapStart = rightIndex == 0 ? 0.0 : clips[rightIndex - 1].end();
            if (gapEnd - gapStart >= duration - 0.000_001)
            {
                const candidate = gapEnd - duration;
                best = candidate;
                bestDistance = fabs(candidate - desiredStart);
                break;
            }
        }

        // The first fitting gap to the right is likewise nearest on the right.
        for (size_t leftIndex = position; leftIndex < clips.length; ++leftIndex)
        {
            const gapStart = clips[leftIndex].end();
            const gapEnd = leftIndex + 1 < clips.length ?
                clips[leftIndex + 1].start : double.max;
            if (gapEnd == double.max ||
                gapEnd - gapStart >= duration - 0.000_001)
            {
                const candidate = desiredStart > gapStart ? desiredStart : gapStart;
                const distance = fabs(candidate - desiredStart);
                if (distance < bestDistance) best = candidate;
                break;
            }
        }
        return best == double.max ? desiredStart : best;
    }

    int insertionIndexAtTime(TrackAddress address, double sequenceTime) const
    {
        if (!validTrack(address)) return 0;
        const clips = trackValue(address).clips;
        size_t low;
        size_t high = clips.length;
        while (low < high)
        {
            const middle = low + (high - low) / 2;
            if (sequenceTime < clips[middle].start + clips[middle].duration() * 0.5)
                high = middle;
            else
                low = middle + 1;
        }
        return cast(int) low;
    }

    double clipStart(TrackAddress address, int requestedIndex) const
    {
        if (!validTrack(address)) return 0.0;
        const clips = trackValue(address).clips;
        if (requestedIndex < 0 || requestedIndex >= cast(int) clips.length) return 0.0;
        return clips[cast(size_t) requestedIndex].start;
    }

    double trackDuration(TrackAddress address) const
    {
        if (!validTrack(address)) return 0.0;
        const clips = trackValue(address).clips;
        // Tracks are kept sorted and collision-free, so the last clip owns the
        // maximum end. Sequence duration therefore scales with track count, not
        // with the total number of clips during scrub/paint/drag operations.
        return clips.length == 0 ? 0.0 : clips[$ - 1].end();
    }

    double familyDuration(TrackKind kind) const
    {
        double result = 0.0;
        foreach (lane; 0 .. trackCount(kind))
        {
            const duration = trackDuration(TrackAddress(kind, lane));
            if (duration > result) result = duration;
        }
        return result;
    }

    double sequenceDuration() const
    {
        const video = familyDuration(TrackKind.video);
        const audio = familyDuration(TrackKind.audio);
        return video > audio ? video : audio;
    }

    int clipAtTime(TrackAddress address, double time) const
    {
        if (!validTrack(address) || time < 0.0) return -1;
        const clips = trackValue(address).clips;
        if (clips.length == 0) return -1;

        size_t low;
        size_t high = clips.length;
        while (low < high)
        {
            const middle = low + (high - low) / 2;
            if (clips[middle].start <= time) low = middle + 1;
            else high = middle;
        }
        if (low == 0) return -1;
        const index = low - 1;
        const clip = clips[index];
        return time >= clip.start && time <= clip.end() + 0.000_001 ?
            cast(int) index : -1;
    }

    bool removeClip(TrackAddress address, int index)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        detachTrackClips(address);
        removeClipAt(track(address).clips, cast(size_t) index);
        return true;
    }

    bool moveClipToTime(TrackAddress source, int index, TrackAddress destination,
        double requestedStart, out int newIndex)
    {
        newIndex = -1;
        if (!validTrack(source)) return false;
        const originalSource = trackValue(source).clips;
        if (index < 0 || index >= cast(int) originalSource.length) return false;
        TimelineClip clip = cloneClip(originalSource[cast(size_t) index]);
        if (clip.isText())
        {
            if (destination.kind != TrackKind.video) return false;
        }
        else if (!canPlace(clip.assetIndex, destination.kind)) return false;

        // Creating a new V/A lane may reallocate a family, so do this before
        // detaching either source or destination.
        ensureTrack(destination.kind, destination.lane);

        detachTrackClips(source);
        removeClipAt(track(source).clips, cast(size_t) index);

        if (source != destination)
            detachTrackClips(destination);
        clip.start = nearestAvailableStart(destination, requestedStart, clip.duration());
        newIndex = insertSorted(track(destination).clips, clip);
        return true;
    }

    bool nudgeClip(TrackAddress address, int index, double delta, out int newIndex)
    {
        if (!validTrack(address) || index < 0 ||
            index >= cast(int) trackValue(address).clips.length)
        {
            newIndex = -1;
            return false;
        }
        const desired = trackValue(address).clips[cast(size_t) index].start + delta;
        return moveClipToTime(address, index, address, desired, newIndex);
    }

    int duplicateClip(TrackAddress address, int index)
    {
        if (!validTrack(address)) return -1;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return -1;
        TimelineClip copy = cloneClip(clips[cast(size_t) index]);
        copy.id = _nextClipId++;
        copy.start = nearestAvailableStart(address, copy.end(), copy.duration());
        detachTrackClips(address);
        return insertSorted(track(address).clips, copy);
    }


    /** Paste a deep clip copy at the requested sequence time. */
    int pasteClip(TrackAddress address, const TimelineClip source,
        double requestedStart)
    {
        endContinuousEdit();
        if (source.isText())
        {
            if (address.kind != TrackKind.video) return -1;
        }
        else if (!canPlace(source.assetIndex, address.kind)) return -1;
        ensureTrack(address.kind, address.lane);
        TimelineClip copy = cloneClip(source);
        copy.id = _nextClipId++;
        copy.start = nearestAvailableStart(address, requestedStart, copy.duration());
        detachTrackClips(address);
        return insertSorted(track(address).clips, copy);
    }

    /** Resize a clip on the sequence without moving other items.
     * Text and still-image items can be extended freely. Video/audio media
     * items trim or reveal source time. */
    bool resizeClipTimeline(TrackAddress address, int index,
        double requestedStart, double requestedEnd, out int newIndex)
    {
        newIndex = -1;
        if (!validTrack(address)) return false;
        const sourceClips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) sourceClips.length) return false;
        TimelineClip original = cloneClip(sourceClips[cast(size_t) index]);
        TimelineClip clip = cloneClip(original);
        const oldStart = clip.start;
        const oldEnd = clip.end();
        requestedStart = clampValue(requestedStart, 0.0, oldEnd - 0.05);
        requestedEnd = requestedEnd < requestedStart + 0.05 ?
            requestedStart + 0.05 : requestedEnd;

        // Do not resize through neighbouring clips.
        const previousEnd = index > 0 ? sourceClips[cast(size_t) index - 1].end() : 0.0;
        const nextStart = index + 1 < cast(int) sourceClips.length ?
            sourceClips[cast(size_t) index + 1].start : double.max;
        requestedStart = requestedStart < previousEnd ? previousEnd : requestedStart;
        if (nextStart != double.max && requestedEnd > nextStart) requestedEnd = nextStart;
        if (requestedEnd <= requestedStart + 0.049) return false;

        const asset = clip.isText() ? null : assetForClip(clip);
        if (!clip.isText() && asset is null) return false;
        if (clip.isText())
        {
            clip.start = requestedStart;
            clip.inPoint = 0.0;
            clip.outPoint = requestedEnd - requestedStart;
        }
        else if (asset.isStillImage())
        {
            clip.start = requestedStart;
            clip.inPoint = 0.0;
            clip.outPoint = (requestedEnd - requestedStart) *
                (clip.playbackRate > 0.000_001 ? clip.playbackRate : 1.0);
        }
        else
        {
            const leftDelta = requestedStart - oldStart;
            double nextIn = clip.inPoint + leftDelta;
            if (nextIn < 0.0)
            {
                requestedStart -= nextIn;
                nextIn = 0.0;
            }
            const rightDelta = requestedEnd - oldEnd;
            double nextOut = clip.outPoint + rightDelta;
            if (nextOut > asset.duration)
            {
                requestedEnd -= nextOut - asset.duration;
                nextOut = asset.duration;
            }
            if (nextOut <= nextIn + 0.05) return false;
            clip.start = requestedStart;
            clip.inPoint = nextIn;
            clip.outPoint = nextOut;
        }
        if (fabs(clip.start - oldStart) < 0.000_001 &&
            fabs(clip.end() - oldEnd) < 0.000_001) return false;
        retimeKeyframesForResize(original, clip, clip.start - oldStart);
        clampClipEffects(clip);
        detachTrackClips(address);
        removeClipAt(track(address).clips, cast(size_t) index);
        newIndex = insertSorted(track(address).clips, clip);
        return true;
    }

    /** Split the clip beneath a sequence time. Returns the index of the right half. */
    int splitAt(TrackAddress address, double sequenceTime)
    {
        const index = clipAtTime(address, sequenceTime);
        if (index < 0) return -1;
        const clips = trackValue(address).clips;
        TimelineClip original = cloneClip(clips[cast(size_t) index]);
        const local = sequenceTime - original.start;
        if (local <= 0.05 || local >= original.duration() - 0.05) return -1;

        TimelineClip left = original;
        TimelineClip right = original;
        const sourceLocal = local * original.playbackRate;
        if (!original.reversed)
            left.outPoint = original.inPoint + sourceLocal;
        else
            left.inPoint = original.outPoint - sourceLocal;
        right.id = _nextClipId++;
        right.start = sequenceTime;
        if (!original.reversed) right.inPoint = left.outPoint;
        else right.outPoint = left.inPoint;
        splitKeyframes(original, local, left.keyframes, right.keyframes);

        detachTrackClips(address);
        auto mutableClips = track(address).clips;
        const i = cast(size_t) index;
        mutableClips.length = mutableClips.length + 1;
        for (size_t cursor = mutableClips.length - 1; cursor > i + 1; --cursor)
            mutableClips[cursor] = mutableClips[cursor - 1];
        mutableClips[i] = left;
        mutableClips[i + 1] = right;
        track(address).clips = mutableClips;
        return index + 1;
    }

    /** Detach the embedded audio of a video item into a real A-track item.
     *
     * The detached item keeps the exact source trim, sequence position, gain,
     * fades, mute state, and volume keyframes.  The source video item is muted
     * so export and preview cannot accidentally mix the same audio twice.
     * A matching free audio lane is preferred; otherwise a new A track is
     * created. */
    bool detachAudioFromVideo(TrackAddress source, int index,
        out TrackAddress destination, out int audioIndex)
    {
        endContinuousEdit();
        audioIndex = -1;
        destination = TrackAddress(TrackKind.audio, 0);
        if (source.kind != TrackKind.video || !validTrack(source)) return false;
        const sourceClips = trackValue(source).clips;
        if (index < 0 || index >= cast(int) sourceClips.length) return false;

        TimelineClip original = cloneClip(sourceClips[cast(size_t) index]);
        if (original.isText()) return false;
        const asset = assetForClip(original);
        if (asset is null || !asset.hasAudio || original.duration() <= 0.0)
            return false;

        const audioCount = trackCount(TrackKind.audio);
        const requestedLane = source.lane;
        bool foundLane;
        bool laneFits(size_t lane)
        {
            const candidate = TrackAddress(TrackKind.audio, lane);
            const available = nearestAvailableStart(candidate, original.start,
                original.duration());
            if (fabs(available - original.start) > 0.000_5) return false;
            destination = candidate;
            return true;
        }
        if (requestedLane < audioCount)
            foundLane = laneFits(requestedLane);
        if (!foundLane)
        {
            foreach (lane; 0 .. audioCount)
            {
                if (lane == requestedLane) continue;
                if (laneFits(lane))
                {
                    foundLane = true;
                    break;
                }
            }
        }
        if (!foundLane)
        {
            destination = TrackAddress(TrackKind.audio,
                addTrack(TrackKind.audio));
        }

        TimelineClip audio = cloneClip(original);
        audio.id = _nextClipId++;
        audio.audioProxyVisible = false;
        // Visual-only values are irrelevant on an A track and retaining them
        // makes later Inspector state misleading.
        audio.scale = 1.0;
        audio.positionX = 0.0;
        audio.positionY = 0.0;
        audio.opacity = 1.0;
        audio.rotation = 0.0;
        audio.blur = 0.0;
        audio.shadowOpacity = 0.0;
        audio.strokeWidth = 0.0;
        EffectKeyframe[] audioKeys;
        foreach (keyframe; audio.keyframes)
            if (keyframe.property == EffectProperty.volume)
                audioKeys ~= keyframe;
        audio.keyframes = audioKeys;

        detachTrackClips(destination);
        audioIndex = insertSorted(track(destination).clips, audio);
        detachTrackClips(source);
        auto video = &track(source).clips[cast(size_t) index];
        video.muted = true;
        video.audioProxyVisible = false;
        return true;
    }

    bool insertCutoutClip(TrackAddress source, int index,
        double cropX, double cropY, double cropWidth, double cropHeight,
        double positionX, double positionY, double scale,
        double rotation, double opacity,
        out TrackAddress destination, out int cutoutIndex)
    {
        endContinuousEdit();
        cutoutIndex = -1;
        destination = TrackAddress(TrackKind.video, 0);
        if (source.kind != TrackKind.video || !validTrack(source)) return false;
        const clips = trackValue(source).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const original = clips[cast(size_t) index];
        if (!original.usesMedia()) return false;
        const asset = assetForClip(original);
        if (asset is null || !asset.hasVideo) return false;

        cropX = clampValue(cropX, 0.0, 1.0);
        cropY = clampValue(cropY, 0.0, 1.0);
        cropWidth = clampValue(cropWidth, 0.0, 1.0 - cropX);
        cropHeight = clampValue(cropHeight, 0.0, 1.0 - cropY);
        if (cropWidth < 0.005 || cropHeight < 0.005) return false;

        const baseX = original.cropEnabled ? original.cropX : 0.0;
        const baseY = original.cropEnabled ? original.cropY : 0.0;
        const baseWidth = original.cropEnabled ? original.cropWidth : 1.0;
        const baseHeight = original.cropEnabled ? original.cropHeight : 1.0;

        TimelineClip cutout = cloneClip(original);
        cutout.id = _nextClipId++;
        cutout.cropEnabled = true;
        cutout.cropX = clampValue(baseX + cropX * baseWidth, 0.0, 1.0);
        cutout.cropY = clampValue(baseY + cropY * baseHeight, 0.0, 1.0);
        cutout.cropWidth = clampValue(cropWidth * baseWidth, 0.005,
            1.0 - cutout.cropX);
        cutout.cropHeight = clampValue(cropHeight * baseHeight, 0.005,
            1.0 - cutout.cropY);
        cutout.positionX = clampValue(positionX, -2.0, 2.0);
        cutout.positionY = clampValue(positionY, -2.0, 2.0);
        cutout.scale = clampValue(scale, 0.1, 4.0);
        cutout.rotation = clampValue(rotation, -360.0, 360.0);
        cutout.opacity = clampValue(opacity, 0.0, 1.0);
        cutout.muted = true;
        cutout.audioProxyVisible = false;
        cutout.keyframes.length = 0;

        destination = TrackAddress(TrackKind.video, addTrack(TrackKind.video));
        detachTrackClips(destination);
        cutoutIndex = insertSorted(track(destination).clips, cutout);
        return true;
    }

    bool setCropAndPosition(TrackAddress address, int index,
        double cropX, double cropY, double cropWidth, double cropHeight,
        double positionX, double positionY)
    {
        if (address.kind != TrackKind.video || !validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const current = clips[cast(size_t) index];
        if (!current.usesMedia()) return false;
        const asset = assetForClip(current);
        if (asset is null || !asset.hasVideo) return false;

        cropX = clampValue(cropX, 0.0, 1.0);
        cropY = clampValue(cropY, 0.0, 1.0);
        cropWidth = clampValue(cropWidth, 0.005, 1.0 - cropX);
        cropHeight = clampValue(cropHeight, 0.005, 1.0 - cropY);
        positionX = clampValue(positionX, -2.0, 2.0);
        positionY = clampValue(positionY, -2.0, 2.0);

        if (current.cropEnabled &&
            fabs(current.cropX - cropX) <= 0.000_001 &&
            fabs(current.cropY - cropY) <= 0.000_001 &&
            fabs(current.cropWidth - cropWidth) <= 0.000_001 &&
            fabs(current.cropHeight - cropHeight) <= 0.000_001 &&
            fabs(current.positionX - positionX) <= 0.000_001 &&
            fabs(current.positionY - positionY) <= 0.000_001)
            return false;

        detachTrackClips(address);
        auto clip = &track(address).clips[cast(size_t) index];
        clip.cropEnabled = true;
        clip.cropX = cropX;
        clip.cropY = cropY;
        clip.cropWidth = cropWidth;
        clip.cropHeight = cropHeight;
        clip.positionX = positionX;
        clip.positionY = positionY;
        return true;
    }

    bool resetTrim(TrackAddress address, int index)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const current = clips[cast(size_t) index];
        const asset = assetForClip(current);
        const sourceDuration = current.isText() ? 5.0 :
            (asset is null ? 0.0 : asset.duration);
        if (sourceDuration <= 0.0) return false;
        if (current.inPoint == 0.0 && current.outPoint == sourceDuration) return false;
        const maximum = maximumOutPoint(address, index, current, sourceDuration);
        detachTrackClips(address);
        auto clip = &track(address).clips[cast(size_t) index];
        clip.inPoint = 0.0;
        clip.outPoint = maximum;
        return true;
    }

    bool resetAudio(TrackAddress address, int index)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const current = clips[cast(size_t) index];
        bool animated;
        foreach (keyframe; current.keyframes)
            if (keyframe.property == EffectProperty.volume) { animated = true; break; }
        if (current.volume == 1.0 && !current.muted && !animated) return false;
        detachTrackClips(address);
        auto clip = &track(address).clips[cast(size_t) index];
        clip.volume = 1.0;
        clip.muted = false;
        EffectKeyframe[] retained;
        foreach (keyframe; clip.keyframes)
            if (keyframe.property != EffectProperty.volume) retained ~= keyframe;
        clip.keyframes = retained;
        return true;
    }

    bool resetTransform(TrackAddress address, int index)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const current = clips[cast(size_t) index];
        bool animated;
        foreach (keyframe; current.keyframes)
            if (keyframe.property != EffectProperty.volume &&
                keyframe.property != EffectProperty.textSize)
            {
                animated = true;
                break;
            }
        if (current.scale == 1.0 && current.positionX == 0.0 &&
            current.positionY == 0.0 && current.opacity == 1.0 &&
            current.rotation == 0.0 && current.blur == 0.0 &&
            current.shadowOpacity == 0.0 && current.strokeWidth == 0.0 &&
            !current.cropEnabled && !animated) return false;
        detachTrackClips(address);
        auto clip = &track(address).clips[cast(size_t) index];
        clip.cropEnabled = false;
        clip.cropX = 0.0;
        clip.cropY = 0.0;
        clip.cropWidth = 1.0;
        clip.cropHeight = 1.0;
        clip.scale = 1.0;
        clip.positionX = 0.0;
        clip.positionY = 0.0;
        clip.opacity = 1.0;
        clip.rotation = 0.0;
        clip.blur = 0.0;
        clip.shadowOpacity = 0.0;
        clip.shadowBlur = 12.0;
        clip.shadowOffsetX = 12.0;
        clip.shadowOffsetY = 12.0;
        clip.strokeWidth = 0.0;
        EffectKeyframe[] retained;
        foreach (keyframe; clip.keyframes)
            if (keyframe.property == EffectProperty.volume ||
                keyframe.property == EffectProperty.textSize)
                retained ~= keyframe;
        clip.keyframes = retained;
        return true;
    }

    bool resetAllProperties(TrackAddress address, int index)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const current = clips[cast(size_t) index];
        const changed = current.volume != 1.0 || current.muted ||
            current.audioProxyVisible || current.scale != 1.0 ||
            current.positionX != 0.0 || current.positionY != 0.0 ||
            current.opacity != 1.0 || current.rotation != 0.0 ||
            current.fadeIn != 0.0 || current.fadeOut != 0.0 ||
            current.blur != 0.0 || current.shadowOpacity != 0.0 ||
            current.shadowBlur != 12.0 || current.shadowOffsetX != 12.0 ||
            current.shadowOffsetY != 12.0 || current.shadowColor != 0xff000000 ||
            current.strokeWidth != 0.0 || current.strokeColor != 0xffffffff ||
            current.cropEnabled || current.cropX != 0.0 ||
            current.cropY != 0.0 || current.cropWidth != 1.0 ||
            current.cropHeight != 1.0 ||
            current.fontName != "Sans" || current.textBold ||
            current.textItalic || current.textUnderline ||
            current.textAlignment != TextAlignment.left ||
            current.textSize != 96.0 || current.textColor != 0xffffffff || current.textBox ||
            current.textBoxColor != 0x80000000 || current.keyframes.length > 0;
        if (!changed) return false;
        detachTrackClips(address);
        auto clip = &track(address).clips[cast(size_t) index];
        clip.volume = 1.0;
        clip.muted = false;
        clip.audioProxyVisible = false;
        clip.cropEnabled = false;
        clip.cropX = 0.0;
        clip.cropY = 0.0;
        clip.cropWidth = 1.0;
        clip.cropHeight = 1.0;
        clip.scale = 1.0;
        clip.positionX = 0.0;
        clip.positionY = 0.0;
        clip.opacity = 1.0;
        clip.rotation = 0.0;
        clip.fadeIn = 0.0;
        clip.fadeOut = 0.0;
        clip.blur = 0.0;
        clip.shadowOpacity = 0.0;
        clip.shadowBlur = 12.0;
        clip.shadowOffsetX = 12.0;
        clip.shadowOffsetY = 12.0;
        clip.shadowColor = 0xff000000;
        clip.strokeWidth = 0.0;
        clip.strokeColor = 0xffffffff;
        clip.fontName = "Sans";
        clip.textBold = false;
        clip.textItalic = false;
        clip.textUnderline = false;
        clip.textAlignment = TextAlignment.left;
        clip.textSize = 96.0;
        clip.textColor = 0xffffffff;
        clip.textBox = false;
        clip.textBoxColor = 0x80000000;
        clip.keyframes.length = 0;
        return true;
    }

    bool setTrimIn(TrackAddress address, int index, double value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const current = clips[cast(size_t) index];
        if (current.isText()) return false;
        const next = clampValue(value, 0.0, current.outPoint - 0.05);
        if (next == current.inPoint) return false;
        detachTrackClips(address);
        auto clip = &track(address).clips[cast(size_t) index];
        clip.inPoint = next;
        clampClipEffects(*clip);
        return true;
    }

    bool setTrimOut(TrackAddress address, int index, double value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const current = clips[cast(size_t) index];
        const asset = assetForClip(current);
        double assetMaximum;
        if (current.isText()) assetMaximum = 86_400.0;
        else
        {
            if (asset is null) return false;
            assetMaximum = asset.duration;
        }
        const maximum = maximumOutPoint(address, index, current, assetMaximum);
        const next = clampValue(value, current.inPoint + 0.05, maximum);
        if (next == current.outPoint) return false;
        detachTrackClips(address);
        auto clip = &track(address).clips[cast(size_t) index];
        clip.outPoint = next;
        clampClipEffects(*clip);
        return true;
    }

    private double maximumOutPoint(TrackAddress address, int index,
        const TimelineClip clip, double assetDuration) const
    {
        const clips = trackValue(address).clips;
        double maximum = assetDuration;
        if (index + 1 < cast(int) clips.length)
        {
            const availableDuration = clips[cast(size_t) index + 1].start - clip.start;
            const sourceMaximum = clip.inPoint + availableDuration;
            if (sourceMaximum < maximum) maximum = sourceMaximum;
        }
        return maximum < clip.inPoint + 0.05 ? clip.inPoint + 0.05 : maximum;
    }

    bool adjustTrimIn(TrackAddress address, int index, double delta)
    {
        if (!validTrack(address) || index < 0 ||
            index >= cast(int) trackValue(address).clips.length) return false;
        return setTrimIn(address, index,
            trackValue(address).clips[cast(size_t) index].inPoint + delta);
    }

    bool adjustTrimOut(TrackAddress address, int index, double delta)
    {
        if (!validTrack(address) || index < 0 ||
            index >= cast(int) trackValue(address).clips.length) return false;
        return setTrimOut(address, index,
            trackValue(address).clips[cast(size_t) index].outPoint + delta);
    }

    bool setVolume(TrackAddress address, int index, double value)
    {
        return updateClipScalar(address, index, value, 0.0, 4.0, 0);
    }

    bool setScale(TrackAddress address, int index, double value)
    {
        return updateClipScalar(address, index, value, 0.1, 4.0, 1);
    }

    bool setPositionX(TrackAddress address, int index, double value)
    {
        return updateClipScalar(address, index, value, -2.0, 2.0, 2);
    }

    bool setPositionY(TrackAddress address, int index, double value)
    {
        return updateClipScalar(address, index, value, -2.0, 2.0, 3);
    }

    bool setOpacity(TrackAddress address, int index, double value)
    {
        return updateClipScalar(address, index, value, 0.0, 1.0, 4);
    }

    bool setRotation(TrackAddress address, int index, double value)
    {
        return updateClipScalar(address, index, value, -360.0, 360.0, 5);
    }

    bool setTextSize(TrackAddress address, int index, double value)
    {
        return updateClipScalar(address, index, value, 8.0, 512.0, 6);
    }

    bool setBlur(TrackAddress address, int index, double value)
    {
        return updateClipStyleScalar(address, index, value, 0.0, 40.0, 5);
    }

    bool setShadowOpacity(TrackAddress address, int index, double value)
    {
        return updateClipStyleScalar(address, index, value, 0.0, 1.0, 0);
    }

    bool setShadowBlur(TrackAddress address, int index, double value)
    {
        return updateClipStyleScalar(address, index, value, 0.0, 40.0, 1);
    }

    bool setShadowOffsetX(TrackAddress address, int index, double value)
    {
        return updateClipStyleScalar(address, index, value, -200.0, 200.0, 2);
    }

    bool setShadowOffsetY(TrackAddress address, int index, double value)
    {
        return updateClipStyleScalar(address, index, value, -200.0, 200.0, 3);
    }

    bool setStrokeWidth(TrackAddress address, int index, double value)
    {
        return updateClipStyleScalar(address, index, value, 0.0, 40.0, 4);
    }

    bool setShadowColor(TrackAddress address, int index, uint value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length ||
            clips[cast(size_t) index].shadowColor == value) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].shadowColor = value;
        return true;
    }

    bool setStrokeColor(TrackAddress address, int index, uint value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length ||
            clips[cast(size_t) index].strokeColor == value) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].strokeColor = value;
        return true;
    }

    bool setPlaybackRate(TrackAddress address, int index, double value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const next = clampValue(value, 0.05, 16.0);
        if (fabs(clips[cast(size_t) index].playbackRate - next) <= 0.000_001)
            return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].playbackRate = next;
        sortTrack(track(address).clips);
        return true;
    }

    bool setReversed(TrackAddress address, int index, bool value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length ||
            clips[cast(size_t) index].reversed == value) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].reversed = value;
        return true;
    }

    bool setFadeIn(TrackAddress address, int index, double value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const current = clips[cast(size_t) index];
        const maximum = current.duration() > current.fadeOut ?
            current.duration() - current.fadeOut : 0.0;
        const next = clampValue(value, 0.0, maximum);
        if (next == current.fadeIn) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].fadeIn = next;
        return true;
    }

    bool setFadeOut(TrackAddress address, int index, double value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const current = clips[cast(size_t) index];
        const maximum = current.duration() > current.fadeIn ?
            current.duration() - current.fadeIn : 0.0;
        const next = clampValue(value, 0.0, maximum);
        if (next == current.fadeOut) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].fadeOut = next;
        return true;
    }

    bool setText(TrackAddress address, int index, string value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length ||
            !clips[cast(size_t) index].isText()) return false;
        if (clips[cast(size_t) index].text == value) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].text = value;
        return true;
    }

    bool setTextColor(TrackAddress address, int index, uint value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length ||
            !clips[cast(size_t) index].isText() ||
            clips[cast(size_t) index].textColor == value) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].textColor = value;
        return true;
    }

    bool setTextBox(TrackAddress address, int index, bool value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length ||
            !clips[cast(size_t) index].isText() ||
            clips[cast(size_t) index].textBox == value) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].textBox = value;
        return true;
    }

    bool setTextBoxColor(TrackAddress address, int index, uint value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length ||
            !clips[cast(size_t) index].isText() ||
            clips[cast(size_t) index].textBoxColor == value) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].textBoxColor = value;
        return true;
    }

    bool setFontName(TrackAddress address, int index, string value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length ||
            !clips[cast(size_t) index].isText()) return false;
        if (value.length == 0) value = "Sans";
        if (clips[cast(size_t) index].fontName == value) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].fontName = value;
        return true;
    }

    bool setTextBold(TrackAddress address, int index, bool value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length ||
            !clips[cast(size_t) index].isText() ||
            clips[cast(size_t) index].textBold == value) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].textBold = value;
        return true;
    }

    bool setTextItalic(TrackAddress address, int index, bool value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length ||
            !clips[cast(size_t) index].isText() ||
            clips[cast(size_t) index].textItalic == value) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].textItalic = value;
        return true;
    }

    bool setTextUnderline(TrackAddress address, int index, bool value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length ||
            !clips[cast(size_t) index].isText() ||
            clips[cast(size_t) index].textUnderline == value) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].textUnderline = value;
        return true;
    }

    bool setTextAlignment(TrackAddress address, int index,
        TextAlignment value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length ||
            !clips[cast(size_t) index].isText() ||
            clips[cast(size_t) index].textAlignment == value) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].textAlignment = value;
        return true;
    }

    bool setKeyframe(TrackAddress address, int index, EffectProperty property,
        double localTime, double value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const current = clips[cast(size_t) index];
        localTime = clampValue(localTime, 0.0, current.duration());
        value = clampEffectValue(property, value);
        detachTrackClips(address);
        auto clip = &track(address).clips[cast(size_t) index];
        foreach (ref keyframe; clip.keyframes)
        {
            if (keyframe.property == property &&
                fabs(keyframe.time - localTime) <= 0.000_5)
            {
                if (keyframe.value == value) return false;
                keyframe.time = localTime;
                keyframe.value = value;
                sortKeyframes(clip.keyframes);
                return true;
            }
        }
        clip.keyframes ~= EffectKeyframe(property, localTime, value);
        sortKeyframes(clip.keyframes);
        return true;
    }

    bool removeKeyframe(TrackAddress address, int index, EffectProperty property,
        double localTime, double tolerance = 0.02)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const source = clips[cast(size_t) index].keyframes;
        foreach (keyIndex, keyframe; source)
        {
            if (keyframe.property == property &&
                fabs(keyframe.time - localTime) <= tolerance)
            {
                detachTrackClips(address);
                auto clip = &track(address).clips[cast(size_t) index];
                removeKeyframeAt(clip.keyframes, keyIndex);
                return true;
            }
        }
        return false;
    }

    bool setKeyframeInterpolation(TrackAddress address, int index,
        EffectProperty property, double localTime, KeyframeInterpolation interpolation,
        double tolerance = 0.02)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        foreach (keyframe; clips[cast(size_t) index].keyframes)
        {
            if (keyframe.property != property ||
                fabs(keyframe.time - localTime) > tolerance) continue;
            if (keyframe.interpolation == interpolation) return false;
            detachTrackClips(address);
            auto clip = &track(address).clips[cast(size_t) index];
            foreach (ref mutableKeyframe; clip.keyframes)
            {
                if (mutableKeyframe.property == property &&
                    fabs(mutableKeyframe.time - localTime) <= tolerance)
                {
                    mutableKeyframe.interpolation = interpolation;
                    return true;
                }
            }
            return false;
        }
        return false;
    }

    bool clearKeyframes(TrackAddress address, int index,
        EffectProperty property)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        bool found;
        foreach (keyframe; clips[cast(size_t) index].keyframes)
            if (keyframe.property == property) { found = true; break; }
        if (!found) return false;
        detachTrackClips(address);
        auto clip = &track(address).clips[cast(size_t) index];
        EffectKeyframe[] result;
        result.reserve(clip.keyframes.length);
        foreach (keyframe; clip.keyframes)
            if (keyframe.property != property) result ~= keyframe;
        clip.keyframes = result;
        return true;
    }

    private static double clampEffectValue(EffectProperty property, double value)
    {
        final switch (property)
        {
            case EffectProperty.volume: return clampValue(value, 0.0, 4.0);
            case EffectProperty.scale: return clampValue(value, 0.1, 4.0);
            case EffectProperty.positionX: return clampValue(value, -2.0, 2.0);
            case EffectProperty.positionY: return clampValue(value, -2.0, 2.0);
            case EffectProperty.opacity: return clampValue(value, 0.0, 1.0);
            case EffectProperty.rotation: return clampValue(value, -360.0, 360.0);
            case EffectProperty.textSize: return clampValue(value, 8.0, 512.0);
        }
    }

    private bool updateClipScalar(TrackAddress address, int index, double value,
        double low, double high, int property)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const currentClip = clips[cast(size_t) index];
        const next = clampValue(value, low, high);
        double current;
        switch (property)
        {
            case 0: current = currentClip.volume; break;
            case 1: current = currentClip.scale; break;
            case 2: current = currentClip.positionX; break;
            case 3: current = currentClip.positionY; break;
            case 4: current = currentClip.opacity; break;
            case 5: current = currentClip.rotation; break;
            case 6: current = currentClip.textSize; break;
            default: return false;
        }
        if (next == current) return false;
        detachTrackClips(address);
        auto clip = &track(address).clips[cast(size_t) index];
        switch (property)
        {
            case 0: clip.volume = next; break;
            case 1: clip.scale = next; break;
            case 2: clip.positionX = next; break;
            case 3: clip.positionY = next; break;
            case 4: clip.opacity = next; break;
            case 5: clip.rotation = next; break;
            case 6: clip.textSize = next; break;
            default: break;
        }
        return true;
    }

    private bool updateClipStyleScalar(TrackAddress address, int index,
        double value, double low, double high, int property)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const currentClip = clips[cast(size_t) index];
        const next = clampValue(value, low, high);
        double current;
        switch (property)
        {
            case 0: current = currentClip.shadowOpacity; break;
            case 1: current = currentClip.shadowBlur; break;
            case 2: current = currentClip.shadowOffsetX; break;
            case 3: current = currentClip.shadowOffsetY; break;
            case 4: current = currentClip.strokeWidth; break;
            case 5: current = currentClip.blur; break;
            default: return false;
        }
        if (next == current) return false;
        detachTrackClips(address);
        auto clip = &track(address).clips[cast(size_t) index];
        switch (property)
        {
            case 0: clip.shadowOpacity = next; break;
            case 1: clip.shadowBlur = next; break;
            case 2: clip.shadowOffsetX = next; break;
            case 3: clip.shadowOffsetY = next; break;
            case 4: clip.strokeWidth = next; break;
            case 5: clip.blur = next; break;
            default: break;
        }
        return true;
    }

    bool setClipAudioProxyVisible(TrackAddress address, int index, bool value)
    {
        if (!validTrack(address) || address.kind != TrackKind.video) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const current = clips[cast(size_t) index];
        const asset = assetForClip(current);
        if (asset is null || !asset.hasAudio || current.audioProxyVisible == value)
            return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].audioProxyVisible = value;
        return true;
    }

    bool setMuted(TrackAddress address, int index, bool value)
    {
        if (!validTrack(address)) return false;
        const clips = trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length ||
            clips[cast(size_t) index].muted == value) return false;
        detachTrackClips(address);
        track(address).clips[cast(size_t) index].muted = value;
        return true;
    }

    /**
     * Cheap copy-on-write timeline snapshot. The outer track array is copied,
     * while immutable clip arrays are shared until a later edit detaches only
     * the affected lane. This keeps long editing sessions from retaining dozens
     * of complete copies of large sequences.
     */
    TimelineTrack[] snapshotTracks(TrackKind kind)
    {
        return tracks(kind).dup;
    }

    /**
     * Restore a snapshot produced by snapshotTracks(). Clip arrays remain
     * shared and are detached lazily by every mutating operation.
     */
    void restoreTimelineSnapshot(TimelineTrack[] video, TimelineTrack[] audio)
    {
        endContinuousEdit();
        videoTracks = video.dup;
        audioTracks = audio.dup;
        if (videoTracks.length == 0) addTrack(TrackKind.video);
        if (audioTracks.length == 0) addTrack(TrackKind.audio);
        recalculateIdentifiers();
    }

    TimelineTrack[] cloneTracks(TrackKind kind) const
    {
        const source = tracks(kind);
        TimelineTrack[] result = new TimelineTrack[source.length];
        foreach (index, timelineTrack; source)
        {
            result[index].id = timelineTrack.id;
            result[index].kind = timelineTrack.kind;
            result[index].muted = timelineTrack.muted;
            result[index].disabled = timelineTrack.disabled;
            result[index].height = timelineTrack.height;
            result[index].clips = new TimelineClip[timelineTrack.clips.length];
            foreach (clipIndex, clip; timelineTrack.clips)
            {
                result[index].clips[clipIndex] = cloneClip(clip);
            }
        }
        return result;
    }

    void restoreTimeline(TimelineTrack[] video, TimelineTrack[] audio)
    {
        endContinuousEdit();
        videoTracks = deepClone(video);
        audioTracks = deepClone(audio);
        foreach (ref timelineTrack; videoTracks) sortTrack(timelineTrack.clips);
        foreach (ref timelineTrack; audioTracks) sortTrack(timelineTrack.clips);
        if (videoTracks.length == 0) addTrack(TrackKind.video);
        if (audioTracks.length == 0) addTrack(TrackKind.audio);

        recalculateIdentifiers();
    }

    /** Begin a high-frequency edit. The affected lane is detached once. */
    bool beginContinuousEdit(TrackAddress address)
    {
        if (!validTrack(address)) return false;
        if (_continuousEdit && _continuousTrack == address) return true;
        endContinuousEdit();
        auto collection = tracks(address.kind).dup;
        collection[address.lane].clips = deepCloneClips(collection[address.lane].clips);
        tracks(address.kind) = collection;
        _continuousTrack = address;
        _continuousEdit = true;
        return true;
    }

    void endContinuousEdit() @safe pure nothrow @nogc
    {
        _continuousEdit = false;
    }

    bool continuousEditActive() const @safe pure nothrow @nogc
    {
        return _continuousEdit;
    }

    /** Detach only the outer track-family array before changing track flags. */
    private void detachTrackFamily(TrackKind kind)
    {
        endContinuousEdit();
        tracks(kind) = tracks(kind).dup;
    }

    /** Detach one lane's clip storage before editing it. */
    private void detachTrackClips(TrackAddress address)
    {
        if (_continuousEdit && _continuousTrack == address) return;
        endContinuousEdit();
        auto collection = tracks(address.kind).dup;
        collection[address.lane].clips = deepCloneClips(collection[address.lane].clips);
        tracks(address.kind) = collection;
    }

    private void recalculateIdentifiers()
    {
        ulong maximumClipId;
        ulong maximumTrackId;
        foreach (kind; [TrackKind.video, TrackKind.audio])
            foreach (timelineTrack; tracks(kind))
            {
                if (timelineTrack.id > maximumTrackId) maximumTrackId = timelineTrack.id;
                foreach (clip; timelineTrack.clips)
                    if (clip.id > maximumClipId) maximumClipId = clip.id;
            }
        _nextClipId = maximumClipId + 1;
        _nextTrackId = maximumTrackId + 1;
        if (_nextClipId == 0) _nextClipId = 1;
        if (_nextTrackId == 0) _nextTrackId = 1;
    }

    private static void removeClipAt(ref TimelineClip[] clips, size_t index)
    {
        assert(index < clips.length);
        foreach (cursor; index .. clips.length - 1)
            clips[cursor] = clips[cursor + 1];
        clips.length = clips.length - 1;
    }

    private static TimelineClip[] deepCloneClips(TimelineClip[] source)
    {
        auto result = new TimelineClip[source.length];
        foreach (index, ref clip; source)
            result[index] = cloneClip(clip);
        return result;
    }

    private static TimelineClip cloneClip(const ref TimelineClip source)
    {
        TimelineClip result;
        result.id = source.id;
        result.kind = source.kind;
        result.assetIndex = source.assetIndex;
        result.start = source.start;
        result.inPoint = source.inPoint;
        result.outPoint = source.outPoint;
        result.volume = source.volume;
        result.muted = source.muted;
        result.audioProxyVisible = source.audioProxyVisible;
        result.playbackRate = source.playbackRate;
        result.reversed = source.reversed;
        result.cropEnabled = source.cropEnabled;
        result.cropX = source.cropX;
        result.cropY = source.cropY;
        result.cropWidth = source.cropWidth;
        result.cropHeight = source.cropHeight;
        result.scale = source.scale;
        result.positionX = source.positionX;
        result.positionY = source.positionY;
        result.opacity = source.opacity;
        result.rotation = source.rotation;
        result.fadeIn = source.fadeIn;
        result.fadeOut = source.fadeOut;
        result.blur = source.blur;
        result.shadowOpacity = source.shadowOpacity;
        result.shadowBlur = source.shadowBlur;
        result.shadowOffsetX = source.shadowOffsetX;
        result.shadowOffsetY = source.shadowOffsetY;
        result.shadowColor = source.shadowColor;
        result.strokeWidth = source.strokeWidth;
        result.strokeColor = source.strokeColor;
        result.text = source.text.idup;
        result.fontName = source.fontName.idup;
        result.textBold = source.textBold;
        result.textItalic = source.textItalic;
        result.textUnderline = source.textUnderline;
        result.textAlignment = source.textAlignment;
        result.textSize = source.textSize;
        result.textColor = source.textColor;
        result.textBox = source.textBox;
        result.textBoxColor = source.textBoxColor;
        result.keyframes = source.keyframes.dup;
        return result;
    }

    private static TimelineTrack[] deepClone(TimelineTrack[] source)
    {
        auto result = source.dup;
        foreach (ref timelineTrack; result)
            timelineTrack.clips = deepCloneClips(timelineTrack.clips);
        return result;
    }

    private static void clampClipEffects(ref TimelineClip clip)
    {
        const duration = clip.duration();
        clip.fadeIn = clampValue(clip.fadeIn, 0.0, duration);
        clip.fadeOut = clampValue(clip.fadeOut, 0.0,
            duration > clip.fadeIn ? duration - clip.fadeIn : 0.0);
        foreach (ref keyframe; clip.keyframes)
            keyframe.time = clampValue(keyframe.time, 0.0, duration);
        sortKeyframes(clip.keyframes);
    }

    /** Keep animation aligned to absolute sequence time while clip edges move. */
    private static void retimeKeyframesForResize(const TimelineClip original,
        ref TimelineClip resized, double leftDelta)
    {
        if (original.keyframes.length == 0) return;
        bool[EffectProperty.max + 1] animated;
        foreach (keyframe; original.keyframes)
            animated[cast(size_t) keyframe.property] = true;
        const newDuration = resized.duration();
        const sourceStart = leftDelta;
        const sourceEnd = leftDelta + newDuration;
        EffectKeyframe[] result;

        foreach (propertyValue; 0 .. animated.length)
        {
            if (!animated[propertyValue]) continue;
            const property = cast(EffectProperty) propertyValue;
            if (sourceStart >= 0.0)
            {
                result ~= EffectKeyframe(property, 0.0,
                    original.evaluatedValue(property, sourceStart),
                    interpolationAt(original, property, sourceStart));
            }
            else
            {
                const value = original.evaluatedValue(property, 0.0);
                result ~= EffectKeyframe(property, 0.0, value,
                    KeyframeInterpolation.hold);
                const originalStartOnNewClip = -sourceStart;
                if (originalStartOnNewClip < newDuration - 0.000_5)
                    result ~= EffectKeyframe(property, originalStartOnNewClip,
                        value, interpolationAt(original, property, 0.0));
            }

            foreach (keyframe; original.keyframes)
            {
                if (keyframe.property != property) continue;
                if (keyframe.time <= sourceStart + 0.000_5 ||
                    keyframe.time >= sourceEnd - 0.000_5) continue;
                const shifted = keyframe.time - sourceStart;
                if (shifted <= 0.000_5 || shifted >= newDuration - 0.000_5)
                    continue;
                result ~= EffectKeyframe(property, shifted, keyframe.value,
                    keyframe.interpolation);
            }

            if (newDuration > 0.000_5)
            {
                const evaluationTime = sourceEnd < 0.0 ? 0.0 :
                    (sourceEnd > original.duration() ? original.duration() : sourceEnd);
                result ~= EffectKeyframe(property, newDuration,
                    original.evaluatedValue(property, evaluationTime),
                    interpolationAt(original, property, evaluationTime));
            }
        }
        sortKeyframes(result);
        resized.keyframes = result;
    }

    private static KeyframeInterpolation interpolationAt(const TimelineClip clip,
        EffectProperty property, double localTime)
    {
        KeyframeInterpolation result = KeyframeInterpolation.linear;
        foreach (keyframe; clip.keyframes)
        {
            if (keyframe.property != property) continue;
            if (keyframe.time > localTime + 0.000_5) break;
            result = keyframe.interpolation;
        }
        return result;
    }

    private static void splitKeyframes(const TimelineClip original, double splitTime,
        out EffectKeyframe[] left, out EffectKeyframe[] right)
    {
        bool[EffectProperty.max + 1] animated;
        foreach (keyframe; original.keyframes)
            animated[cast(size_t) keyframe.property] = true;

        foreach (propertyValue; 0 .. animated.length)
        {
            if (!animated[propertyValue]) continue;
            const property = cast(EffectProperty) propertyValue;
            const value = original.evaluatedValue(property, splitTime);
            const interpolation = interpolationAt(original, property, splitTime);
            left ~= EffectKeyframe(property, splitTime, value, interpolation);
            right ~= EffectKeyframe(property, 0.0, value, interpolation);
        }
        foreach (keyframe; original.keyframes)
        {
            if (keyframe.time < splitTime - 0.000_5)
                left ~= keyframe;
            else if (keyframe.time > splitTime + 0.000_5)
            {
                EffectKeyframe shifted = EffectKeyframe(keyframe.property,
                    keyframe.time - splitTime, keyframe.value,
                    keyframe.interpolation);
                right ~= shifted;
            }
        }
        sortKeyframes(left);
        sortKeyframes(right);
    }

    private static void removeKeyframeAt(ref EffectKeyframe[] keyframes,
        size_t index)
    {
        assert(index < keyframes.length);
        foreach (cursor; index .. keyframes.length - 1)
            keyframes[cursor] = keyframes[cursor + 1];
        keyframes.length = keyframes.length - 1;
    }

    private static bool keyframeBefore(const EffectKeyframe left,
        const EffectKeyframe right) @safe pure nothrow @nogc
    {
        return left.property < right.property ||
            (left.property == right.property && left.time < right.time);
    }

    private static void sortKeyframes(ref EffectKeyframe[] keyframes)
    {
        keyframes.sort!((left, right) => keyframeBefore(left, right));
    }

    private static bool clipBefore(const TimelineClip left,
        const TimelineClip right) @safe pure nothrow @nogc
    {
        return left.start < right.start ||
            (left.start == right.start && left.id < right.id);
    }

    private static void sortTrack(ref TimelineClip[] clips)
    {
        clips.sort!((left, right) => clipBefore(left, right));
    }

    private static int insertSorted(ref TimelineClip[] clips, TimelineClip clip)
    {
        size_t low;
        size_t high = clips.length;
        while (low < high)
        {
            const middle = low + (high - low) / 2;
            if (clipBefore(clips[middle], clip)) low = middle + 1;
            else high = middle;
        }
        const previousLength = clips.length;
        clips.length = previousLength + 1;
        for (size_t cursor = previousLength; cursor > low; --cursor)
            clips[cursor] = clips[cursor - 1];
        clips[low] = clip;
        return cast(int) low;
    }

    private static TimelineClip* clipAtIndex(ref TimelineClip[] clips, int index)
    {
        if (index < 0 || index >= cast(int) clips.length) return null;
        return &clips[cast(size_t) index];
    }
}
