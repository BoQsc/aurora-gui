module auroracut.project;

import auroracut.model : ClipKind, EditorModel, EffectKeyframe, EffectProperty,
    KeyframeInterpolation, MediaAsset, TextAlignment, TimelineClip,
    TimelineSnapshot, TimelineTrack, TrackAddress, TrackKind,
    textAlignmentFromName, textAlignmentName;
import auroracut.util : appLog, clampValue;
import std.file : readText, tempDir, write;
import std.format : format;
import std.json : JSONException, JSONType, JSONValue, parseJSON;

enum int defaultPreviewQualityHeight = 720;
enum int defaultCompositionWidth = 1920;
enum int defaultCompositionHeight = 1080;

/** Serializable editor state. Media metadata is stored so opening a project
 * does not block the UI on a fresh FFprobe pass. The undo/redo history rides
 * in the same file, so it travels with the project and is always consistent
 * with the project's asset array (asset removal clears the history, so clip
 * asset indexes stay valid). */
struct ProjectData
{
    MediaAsset[] assets;
    TimelineTrack[] videoTracks;
    TimelineTrack[] audioTracks;
    double playhead;
    bool hasWorkIn;
    bool hasWorkOut;
    double workIn;
    double workOut;
    int previewQualityHeight = defaultPreviewQualityHeight;
    int compositionWidth = defaultCompositionWidth;
    int compositionHeight = defaultCompositionHeight;
    TimelineSnapshot[] undo;
    TimelineSnapshot[] redo;
}

private bool finiteNumber(double value) @safe pure nothrow @nogc
{
    return value == value && value <= double.max && value >= -double.max;
}

/** Project files are standard JSON and therefore cannot contain NaN or
 * infinities. Invalid transient editor values are replaced with a safe
 * field-specific default and recorded with the exact field path. */
private double projectNumber(double value, double fallback, string fieldPath)
{
    if (finiteNumber(value)) return value;
    appLog(format("Project save sanitized non-finite value: %s=%s; using %s",
        fieldPath, value, fallback));
    return fallback;
}

private JSONValue jsonNumber(double value, double fallback, string fieldPath)
{
    return JSONValue(projectNumber(value, fallback, fieldPath));
}

private JSONValue jsonColor(uint value)
{
    return JSONValue(cast(ulong) value);
}

private JSONValue keyframeJson(const EffectKeyframe value, string ownerPath,
    size_t index)
{
    const path = format("%s.keyframes[%s]", ownerPath, index);
    return JSONValue([
        "property": JSONValue(cast(long) value.property),
        "time": jsonNumber(value.time, 0.0, path ~ ".time"),
        "value": jsonNumber(value.value, 0.0, path ~ ".value"),
        "interpolation": JSONValue(cast(long) value.interpolation)
    ]);
}

private JSONValue clipJson(const TimelineClip value)
{
    const path = format("clip[%s]", value.id);
    JSONValue[] keys;
    foreach (index, keyframe; value.keyframes)
        keys ~= keyframeJson(keyframe, path, index);

    const inPoint = projectNumber(value.inPoint, 0.0, path ~ ".inPoint");
    return JSONValue([
        "id": JSONValue(value.id),
        "kind": JSONValue(cast(long) value.kind),
        "assetIndex": JSONValue(cast(ulong) value.assetIndex),
        "start": jsonNumber(value.start, 0.0, path ~ ".start"),
        "inPoint": JSONValue(inPoint),
        "outPoint": jsonNumber(value.outPoint, inPoint, path ~ ".outPoint"),
        "volume": jsonNumber(value.volume, 1.0, path ~ ".volume"),
        "muted": JSONValue(value.muted),
        "audioProxyVisible": JSONValue(value.audioProxyVisible),
        "playbackRate": jsonNumber(value.playbackRate, 1.0, path ~ ".playbackRate"),
        "reversed": JSONValue(value.reversed),
        "cropEnabled": JSONValue(value.cropEnabled),
        "cropX": jsonNumber(value.cropX, 0.0, path ~ ".cropX"),
        "cropY": jsonNumber(value.cropY, 0.0, path ~ ".cropY"),
        "cropWidth": jsonNumber(value.cropWidth, 1.0, path ~ ".cropWidth"),
        "cropHeight": jsonNumber(value.cropHeight, 1.0, path ~ ".cropHeight"),
        "scale": jsonNumber(value.scale, 1.0, path ~ ".scale"),
        "positionX": jsonNumber(value.positionX, 0.0, path ~ ".positionX"),
        "positionY": jsonNumber(value.positionY, 0.0, path ~ ".positionY"),
        "opacity": jsonNumber(value.opacity, 1.0, path ~ ".opacity"),
        "rotation": jsonNumber(value.rotation, 0.0, path ~ ".rotation"),
        "fadeIn": jsonNumber(value.fadeIn, 0.0, path ~ ".fadeIn"),
        "fadeOut": jsonNumber(value.fadeOut, 0.0, path ~ ".fadeOut"),
        "blur": jsonNumber(value.blur, 0.0, path ~ ".blur"),
        "shadowOpacity": jsonNumber(value.shadowOpacity, 0.0, path ~ ".shadowOpacity"),
        "shadowBlur": jsonNumber(value.shadowBlur, 12.0, path ~ ".shadowBlur"),
        "shadowOffsetX": jsonNumber(value.shadowOffsetX, 12.0, path ~ ".shadowOffsetX"),
        "shadowOffsetY": jsonNumber(value.shadowOffsetY, 12.0, path ~ ".shadowOffsetY"),
        "shadowColor": jsonColor(value.shadowColor),
        "strokeWidth": jsonNumber(value.strokeWidth, 0.0, path ~ ".strokeWidth"),
        "strokeColor": jsonColor(value.strokeColor),
        "text": JSONValue(value.text),
        "fontName": JSONValue(value.fontName),
        "textBold": JSONValue(value.textBold),
        "textItalic": JSONValue(value.textItalic),
        "textUnderline": JSONValue(value.textUnderline),
        "textAlignment": JSONValue(textAlignmentName(value.textAlignment)),
        "textSize": jsonNumber(value.textSize, 96.0, path ~ ".textSize"),
        "textColor": jsonColor(value.textColor),
        "textBox": JSONValue(value.textBox),
        "textBoxColor": jsonColor(value.textBoxColor),
        "keyframes": JSONValue(keys)
    ]);
}

/** Serializable track JSON. Used by project files and persisted history. */
JSONValue trackToJson(const TimelineTrack value)
{
    JSONValue[] clips;
    foreach (clip; value.clips) clips ~= clipJson(clip);
    return JSONValue([
        "id": JSONValue(value.id),
        "kind": JSONValue(cast(long) value.kind),
        "muted": JSONValue(value.muted),
        "disabled": JSONValue(value.disabled),
        "height": JSONValue(cast(long) value.height),
        "clips": JSONValue(clips)
    ]);
}

/** Serializable undo/redo snapshot. Each snapshot is a full timeline state
 * including the project media asset array it references. */
JSONValue snapshotToJson(const TimelineSnapshot snapshot)
{
    JSONValue[] assets;
    foreach (index, asset; snapshot.assets) assets ~= assetJson(asset, index);
    JSONValue[] video;
    JSONValue[] audio;
    foreach (track; snapshot.video) video ~= trackToJson(track);
    foreach (track; snapshot.audio) audio ~= trackToJson(track);
    return JSONValue([
        "label": JSONValue(snapshot.label),
        "selectedTrackKind": JSONValue(cast(long) snapshot.selectedTrack.kind),
        "selectedLane": JSONValue(cast(ulong) snapshot.selectedTrack.lane),
        "selectedIndex": JSONValue(cast(long) snapshot.selectedIndex),
        "playhead": jsonNumber(snapshot.playhead, 0.0, "history.playhead"),
        "hasWorkIn": JSONValue(snapshot.hasWorkIn),
        "workIn": jsonNumber(snapshot.workIn, 0.0, "history.workIn"),
        "hasWorkOut": JSONValue(snapshot.hasWorkOut),
        "workOut": jsonNumber(snapshot.workOut, 0.0, "history.workOut"),
        "assets": JSONValue(assets),
        "video": JSONValue(video),
        "audio": JSONValue(audio)
    ]);
}

/** Parse a snapshot written by snapshotToJson. */
TimelineSnapshot snapshotFromJson(const JSONValue value)
{
    TimelineSnapshot snapshot;
    snapshot.label = stringValue(value, "label");
    snapshot.selectedTrack.kind = cast(TrackKind) integerValue(value,
        "selectedTrackKind");
    snapshot.selectedTrack.lane = cast(size_t) unsignedValue(value, "selectedLane");
    snapshot.selectedIndex = cast(int) integerValue(value, "selectedIndex");
    snapshot.playhead = numberValue(value, "playhead");
    snapshot.hasWorkIn = boolValue(value, "hasWorkIn");
    snapshot.workIn = numberValue(value, "workIn");
    snapshot.hasWorkOut = boolValue(value, "hasWorkOut");
    snapshot.workOut = numberValue(value, "workOut");

    auto assets = member(value, "assets");
    if (assets !is null && assets.type == JSONType.array)
        foreach (entry; assets.array)
            snapshot.assets ~= assetFromJson(entry);
    auto video = member(value, "video");
    if (video !is null && video.type == JSONType.array)
        foreach (entry; video.array)
            snapshot.video ~= trackFromJson(entry, TrackKind.video);
    auto audio = member(value, "audio");
    if (audio !is null && audio.type == JSONType.array)
        foreach (entry; audio.array)
            snapshot.audio ~= trackFromJson(entry, TrackKind.audio);
    return snapshot;
}

private JSONValue assetJson(const MediaAsset value, size_t index)
{
    const path = format("assets[%s]", index);
    return JSONValue([
        "path": JSONValue(value.path),
        "name": JSONValue(value.name),
        "duration": jsonNumber(value.duration, 0.0, path ~ ".duration"),
        "hasVideo": JSONValue(value.hasVideo),
        "hasAudio": JSONValue(value.hasAudio),
        "videoCodec": JSONValue(value.videoCodec),
        "width": JSONValue(cast(long) value.width),
        "height": JSONValue(cast(long) value.height),
        "frameRate": jsonNumber(value.frameRate, 0.0, path ~ ".frameRate"),
        "audioChannels": JSONValue(cast(long) value.audioChannels),
        "sampleRate": JSONValue(cast(long) value.sampleRate),
        "playbackProxyPath": JSONValue(value.playbackProxyPath),
        "playbackProxyWidth": JSONValue(cast(long) value.playbackProxyWidth),
        "playbackProxyHeight": JSONValue(cast(long) value.playbackProxyHeight),
        "playbackProxyFrameRate": jsonNumber(value.playbackProxyFrameRate,
            0.0, path ~ ".playbackProxyFrameRate")
    ]);
}

private MediaAsset assetFromJson(const JSONValue entry)
{
    auto asset = new MediaAsset(stringValue(entry, "path"));
    asset.name = stringValue(entry, "name", asset.name);
    asset.duration = numberValue(entry, "duration");
    asset.hasVideo = boolValue(entry, "hasVideo");
    asset.hasAudio = boolValue(entry, "hasAudio");
    asset.videoCodec = stringValue(entry, "videoCodec");
    asset.width = cast(int) integerValue(entry, "width");
    asset.height = cast(int) integerValue(entry, "height");
    asset.frameRate = numberValue(entry, "frameRate");
    asset.audioChannels = cast(int) integerValue(entry, "audioChannels");
    asset.sampleRate = cast(int) integerValue(entry, "sampleRate");
    asset.playbackProxyPath = stringValue(entry, "playbackProxyPath");
    asset.playbackProxyWidth = cast(int) integerValue(entry,
        "playbackProxyWidth");
    asset.playbackProxyHeight = cast(int) integerValue(entry,
        "playbackProxyHeight");
    asset.playbackProxyFrameRate = numberValue(entry,
        "playbackProxyFrameRate");
    return asset;
}

void saveProjectFile(string path, EditorModel model, double playhead,
    bool hasWorkIn, double workIn, bool hasWorkOut, double workOut,
    int previewQualityHeight, int compositionWidth = defaultCompositionWidth,
    int compositionHeight = defaultCompositionHeight,
    const(TimelineSnapshot)[] undo = null,
    const(TimelineSnapshot)[] redo = null)
{
    JSONValue[] assets;
    foreach (index, asset; model.assets) assets ~= assetJson(asset, index);
    JSONValue[] video;
    foreach (track; model.videoTracks) video ~= trackToJson(track);
    JSONValue[] audio;
    foreach (track; model.audioTracks) audio ~= trackToJson(track);

    JSONValue[] undoJson;
    foreach (snapshot; undo) undoJson ~= snapshotToJson(snapshot);
    JSONValue[] redoJson;
    foreach (snapshot; redo) redoJson ~= snapshotToJson(snapshot);

    JSONValue root = JSONValue([
        "format": JSONValue("aurora-cut-project"),
        "version": JSONValue(2L),
        "playhead": jsonNumber(playhead, 0.0, "project.playhead"),
        "hasWorkIn": JSONValue(hasWorkIn),
        "hasWorkOut": JSONValue(hasWorkOut),
        "workIn": jsonNumber(workIn, 0.0, "project.workIn"),
        "workOut": jsonNumber(workOut, 0.0, "project.workOut"),
        "previewQualityHeight": JSONValue(cast(long) previewQualityHeight),
        "compositionWidth": JSONValue(cast(long) compositionWidth),
        "compositionHeight": JSONValue(cast(long) compositionHeight),
        "assets": JSONValue(assets),
        "videoTracks": JSONValue(video),
        "audioTracks": JSONValue(audio),
        "history": JSONValue([
            "undo": JSONValue(undoJson),
            "redo": JSONValue(redoJson)
        ])
    ]);
    write(path, root.toPrettyString());
}

private const(JSONValue)* member(const JSONValue value, string key)
{
    if (value.type != JSONType.object) return null;
    const object = value.object;
    auto found = key in object;
    return found;
}

private string stringValue(const JSONValue value, string key, string fallback = "")
{
    auto item = member(value, key);
    return item !is null && item.type == JSONType.string ? item.str : fallback;
}

private double numberValue(const JSONValue value, string key, double fallback = 0.0)
{
    auto item = member(value, key);
    if (item is null) return fallback;
    switch (item.type)
    {
        case JSONType.float_:
            return finiteNumber(item.floating) ? item.floating : fallback;
        case JSONType.integer: return cast(double) item.integer;
        case JSONType.uinteger: return cast(double) item.uinteger;
        default: return fallback;
    }
}

private long integerValue(const JSONValue value, string key, long fallback = 0)
{
    auto item = member(value, key);
    if (item is null) return fallback;
    switch (item.type)
    {
        case JSONType.integer: return item.integer;
        case JSONType.uinteger: return cast(long) item.uinteger;
        case JSONType.float_: return cast(long) item.floating;
        default: return fallback;
    }
}

private ulong unsignedValue(const JSONValue value, string key, ulong fallback = 0)
{
    auto item = member(value, key);
    if (item is null) return fallback;
    switch (item.type)
    {
        case JSONType.uinteger: return item.uinteger;
        case JSONType.integer: return item.integer < 0 ? fallback : cast(ulong) item.integer;
        case JSONType.float_: return item.floating < 0 ? fallback : cast(ulong) item.floating;
        default: return fallback;
    }
}

private bool boolValue(const JSONValue value, string key, bool fallback = false)
{
    auto item = member(value, key);
    return item !is null && item.type == JSONType.true_ ? true :
        item !is null && item.type == JSONType.false_ ? false : fallback;
}

private TextAlignment textAlignmentValue(const JSONValue value, string key)
{
    auto item = member(value, key);
    if (item is null) return TextAlignment.left;
    switch (item.type)
    {
        case JSONType.string:
            return textAlignmentFromName(item.str);
        case JSONType.integer:
            switch (item.integer)
            {
                case 1: return TextAlignment.center;
                case 2: return TextAlignment.right;
                default: return TextAlignment.left;
            }
        case JSONType.uinteger:
            switch (item.uinteger)
            {
                case 1: return TextAlignment.center;
                case 2: return TextAlignment.right;
                default: return TextAlignment.left;
            }
        default: return TextAlignment.left;
    }
}

private TimelineClip parseClip(const JSONValue value)
{
    TimelineClip clip;
    clip.id = unsignedValue(value, "id");
    clip.kind = cast(ClipKind) integerValue(value, "kind", cast(long) ClipKind.media);
    clip.assetIndex = cast(size_t) unsignedValue(value, "assetIndex");
    clip.start = numberValue(value, "start");
    clip.inPoint = numberValue(value, "inPoint");
    clip.outPoint = numberValue(value, "outPoint");
    clip.volume = numberValue(value, "volume", 1.0);
    clip.muted = boolValue(value, "muted");
    clip.audioProxyVisible = boolValue(value, "audioProxyVisible");
    clip.playbackRate = numberValue(value, "playbackRate", 1.0);
    clip.reversed = boolValue(value, "reversed");
    clip.cropEnabled = boolValue(value, "cropEnabled");
    clip.cropX = clampValue(numberValue(value, "cropX"), 0.0, 1.0);
    clip.cropY = clampValue(numberValue(value, "cropY"), 0.0, 1.0);
    clip.cropWidth = clampValue(numberValue(value, "cropWidth", 1.0),
        0.0, 1.0 - clip.cropX);
    clip.cropHeight = clampValue(numberValue(value, "cropHeight", 1.0),
        0.0, 1.0 - clip.cropY);
    if (clip.cropWidth <= 0.0 || clip.cropHeight <= 0.0)
    {
        clip.cropEnabled = false;
        clip.cropX = 0.0;
        clip.cropY = 0.0;
        clip.cropWidth = 1.0;
        clip.cropHeight = 1.0;
    }
    clip.scale = numberValue(value, "scale", 1.0);
    clip.positionX = numberValue(value, "positionX");
    clip.positionY = numberValue(value, "positionY");
    clip.opacity = numberValue(value, "opacity", 1.0);
    clip.rotation = numberValue(value, "rotation");
    clip.fadeIn = numberValue(value, "fadeIn");
    clip.fadeOut = numberValue(value, "fadeOut");
    clip.blur = numberValue(value, "blur");
    clip.shadowOpacity = numberValue(value, "shadowOpacity");
    clip.shadowBlur = numberValue(value, "shadowBlur", 12.0);
    clip.shadowOffsetX = numberValue(value, "shadowOffsetX", 12.0);
    clip.shadowOffsetY = numberValue(value, "shadowOffsetY", 12.0);
    clip.shadowColor = cast(uint) unsignedValue(value, "shadowColor", 0xff000000);
    clip.strokeWidth = numberValue(value, "strokeWidth");
    clip.strokeColor = cast(uint) unsignedValue(value, "strokeColor", 0xffffffff);
    clip.text = stringValue(value, "text", "Text");
    clip.fontName = stringValue(value, "fontName", "Sans");
    clip.textBold = boolValue(value, "textBold");
    clip.textItalic = boolValue(value, "textItalic");
    clip.textUnderline = boolValue(value, "textUnderline");
    clip.textAlignment = textAlignmentValue(value, "textAlignment");
    clip.textSize = numberValue(value, "textSize", 96.0);
    clip.textColor = cast(uint) unsignedValue(value, "textColor", 0xffffffff);
    clip.textBox = boolValue(value, "textBox");
    clip.textBoxColor = cast(uint) unsignedValue(value, "textBoxColor", 0x80000000);
    auto keys = member(value, "keyframes");
    if (keys !is null && keys.type == JSONType.array)
        foreach (entry; keys.array)
        {
            EffectKeyframe key;
            key.property = cast(EffectProperty) integerValue(entry, "property");
            key.time = numberValue(entry, "time");
            key.value = numberValue(entry, "value");
            key.interpolation = cast(KeyframeInterpolation) integerValue(entry,
                "interpolation", cast(long) KeyframeInterpolation.linear);
            clip.keyframes ~= key;
        }
    return clip;
}

TimelineTrack trackFromJson(const JSONValue value, TrackKind fallbackKind)
{
    TimelineTrack track;
    track.id = unsignedValue(value, "id");
    track.kind = cast(TrackKind) integerValue(value, "kind", cast(long) fallbackKind);
    track.muted = boolValue(value, "muted");
    track.disabled = boolValue(value, "disabled");
    track.height = cast(int) integerValue(value, "height", 24);
    if (track.height < 22) track.height = 22;
    auto clips = member(value, "clips");
    if (clips !is null && clips.type == JSONType.array)
        foreach (entry; clips.array) track.clips ~= parseClip(entry);
    return track;
}

ProjectData loadProjectFile(string path)
{
    const root = parseJSON(readText(path));
    if (root.type != JSONType.object ||
        stringValue(root, "format") != "aurora-cut-project")
        throw new JSONException("Not an Aurora Cut project file.");
    const versionNumber = integerValue(root, "version");
    if (versionNumber < 1 || versionNumber > 2)
        throw new JSONException("Unsupported Aurora Cut project version.");

    ProjectData result;
    result.playhead = numberValue(root, "playhead");
    result.hasWorkIn = boolValue(root, "hasWorkIn");
    result.hasWorkOut = boolValue(root, "hasWorkOut");
    result.workIn = numberValue(root, "workIn");
    result.workOut = numberValue(root, "workOut");
    result.previewQualityHeight = cast(int) integerValue(root,
        "previewQualityHeight", defaultPreviewQualityHeight);
    result.compositionWidth = cast(int) integerValue(root,
        "compositionWidth", defaultCompositionWidth);
    result.compositionHeight = cast(int) integerValue(root,
        "compositionHeight", defaultCompositionHeight);

    auto assets = member(root, "assets");
    if (assets !is null && assets.type == JSONType.array)
        foreach (entry; assets.array)
            result.assets ~= assetFromJson(entry);

    auto video = member(root, "videoTracks");
    if (video !is null && video.type == JSONType.array)
        foreach (entry; video.array)
            result.videoTracks ~= trackFromJson(entry, TrackKind.video);
    auto audio = member(root, "audioTracks");
    if (audio !is null && audio.type == JSONType.array)
        foreach (entry; audio.array)
            result.audioTracks ~= trackFromJson(entry, TrackKind.audio);

    // The undo/redo history is written atomically with the assets it
    // references, so indexes are consistent by construction. Snapshots now
    // carry their own asset array; the loaded project's current asset list is
    // still used as a fallback to sanitize older project files whose snapshots
    // predate asset snapshots (they reference the top-level assets).
    const assetCount = result.assets.length;
    auto history = member(root, "history");
    if (history !is null && history.type == JSONType.object)
    {
        auto undo = member(*history, "undo");
        if (undo !is null && undo.type == JSONType.array)
            foreach (entry; undo.array)
                result.undo ~= snapshotFromJson(entry);
        auto redo = member(*history, "redo");
        if (redo !is null && redo.type == JSONType.array)
            foreach (entry; redo.array)
                result.redo ~= snapshotFromJson(entry);
        result.undo = validHistorySnapshots(result.undo, assetCount);
        result.redo = validHistorySnapshots(result.redo, assetCount);
    }
    return result;
}

/** Drop snapshots whose media clips reference assets outside the snapshot's
 * own asset array, falling back to the project's current asset count for
 * older snapshots that predate asset tracking. Text clips carry no media
 * reference and stay valid. */
private TimelineSnapshot[] validHistorySnapshots(TimelineSnapshot[] snapshots,
    size_t projectAssetCount)
{
    TimelineSnapshot[] result;
    foreach (snapshot; snapshots)
    {
        const count = snapshot.assets.length > 0 ? snapshot.assets.length :
            projectAssetCount;
        bool valid = true;
        foreach (track; snapshot.video)
            foreach (clip; track.clips)
                if (clip.usesMedia() && clip.assetIndex >= count)
                {
                    valid = false;
                    break;
                }
        if (!valid) continue;
        foreach (track; snapshot.audio)
            foreach (clip; track.clips)
                if (clip.usesMedia() && clip.assetIndex >= count)
                {
                    valid = false;
                    break;
                }
        if (valid) result ~= snapshot;
    }
    return result;
}

/// The undo/redo history round-trips inside the project file and stale
/// snapshots that reference removed assets are dropped on load.
unittest
{
    import std.file : exists, remove;
    import std.path : buildPath;

    const projectPath = buildPath(tempDir(),
        "aurora-cut-project-history-unittest.auroracut");
    if (exists(projectPath)) remove(projectPath);
    scope (exit)
    {
        if (exists(projectPath)) remove(projectPath);
    }

    auto model = new EditorModel();
    auto asset = new MediaAsset("C:\\media\\clip.mp4");
    asset.duration = 4.0;
    asset.hasVideo = true;
    asset.hasAudio = true;
    model.assets ~= asset;
    const clipIndex = model.appendClip(0, TrackAddress(TrackKind.video, 0));
    assert(clipIndex == 0);

    TimelineSnapshot undoSnapshot;
    undoSnapshot.label = "Add clip";
    undoSnapshot.assets = model.snapshotAssets();
    undoSnapshot.video = model.snapshotTracks(TrackKind.video);
    undoSnapshot.audio = model.snapshotTracks(TrackKind.audio);
    undoSnapshot.playhead = 1.5;
    undoSnapshot.selectedTrack = TrackAddress(TrackKind.video, 0);
    undoSnapshot.selectedIndex = 0;
    undoSnapshot.hasWorkOut = true;
    undoSnapshot.workOut = 3.0;

    TimelineSnapshot redoSnapshot;
    redoSnapshot.label = "Move clip";

    saveProjectFile(projectPath, model, 2.0, false, 0.0, true, 3.0, 720,
        defaultCompositionWidth, defaultCompositionHeight,
        [undoSnapshot], [redoSnapshot]);

    const loaded = loadProjectFile(projectPath);
    assert(loaded.undo.length == 1 && loaded.redo.length == 1,
        "Project history did not round-trip through the project file");
    assert(loaded.undo[0].label == "Add clip");
    assert(loaded.undo[0].playhead == 1.5);
    assert(loaded.undo[0].selectedTrack.kind == TrackKind.video);
    assert(loaded.undo[0].selectedIndex == 0);
    assert(loaded.undo[0].hasWorkOut && loaded.undo[0].workOut == 3.0);
    assert(loaded.undo[0].video.length == 1 &&
        loaded.undo[0].video[0].clips.length == 1 &&
        loaded.undo[0].video[0].clips[0].assetIndex == 0,
        "History snapshot did not preserve the timeline clip");
    assert(loaded.undo[0].assets.length == 1 &&
        loaded.undo[0].assets[0].path == "C:\\media\\clip.mp4" &&
        loaded.undo[0].assets[0].duration == 4.0,
        "History snapshot did not preserve the media asset array");
    assert(loaded.redo[0].label == "Move clip");

    // A snapshot referencing a removed asset must be dropped, not restored.
    TimelineSnapshot stale = undoSnapshot;
    foreach (ref track; stale.video)
        foreach (ref clip; track.clips)
            clip.assetIndex = 7; // out of range
    saveProjectFile(projectPath, model, 2.0, false, 0.0, true, 3.0, 720,
        defaultCompositionWidth, defaultCompositionHeight,
        [stale], []);
    const reloaded = loadProjectFile(projectPath);
    assert(reloaded.undo.length == 0,
        "History snapshot referencing a missing asset was not dropped");
    assert(reloaded.redo.length == 0);

    // Old project files without a history field load with empty history.
    saveProjectFile(projectPath, model, 2.0, false, 0.0, true, 3.0, 720);
    const legacy = loadProjectFile(projectPath);
    assert(legacy.undo.length == 0 && legacy.redo.length == 0,
        "Legacy project file gained phantom history");
}
