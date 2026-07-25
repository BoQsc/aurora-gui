module auroracut.project;

import auroracut.model : ClipKind, EditorModel, EffectKeyframe, EffectProperty,
    KeyframeInterpolation, MediaAsset, TimelineClip, TimelineTrack, TrackKind;
import auroracut.util : appLog;
import std.file : readText, write;
import std.format : format;
import std.json : JSONException, JSONType, JSONValue, parseJSON;

/** Serializable editor state. Media metadata is stored so opening a project
 * does not block the UI on a fresh FFprobe pass. */
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
    int previewQualityHeight = 1080;
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
        "textSize": jsonNumber(value.textSize, 96.0, path ~ ".textSize"),
        "textColor": jsonColor(value.textColor),
        "textBox": JSONValue(value.textBox),
        "textBoxColor": jsonColor(value.textBoxColor),
        "keyframes": JSONValue(keys)
    ]);
}

private JSONValue trackJson(const TimelineTrack value)
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

private JSONValue assetJson(const MediaAsset value, size_t index)
{
    const path = format("assets[%s]", index);
    return JSONValue([
        "path": JSONValue(value.path),
        "name": JSONValue(value.name),
        "duration": jsonNumber(value.duration, 0.0, path ~ ".duration"),
        "hasVideo": JSONValue(value.hasVideo),
        "hasAudio": JSONValue(value.hasAudio),
        "width": JSONValue(cast(long) value.width),
        "height": JSONValue(cast(long) value.height),
        "frameRate": jsonNumber(value.frameRate, 0.0, path ~ ".frameRate"),
        "audioChannels": JSONValue(cast(long) value.audioChannels),
        "sampleRate": JSONValue(cast(long) value.sampleRate)
    ]);
}

void saveProjectFile(string path, EditorModel model, double playhead,
    bool hasWorkIn, double workIn, bool hasWorkOut, double workOut,
    int previewQualityHeight)
{
    JSONValue[] assets;
    foreach (index, asset; model.assets) assets ~= assetJson(asset, index);
    JSONValue[] video;
    foreach (track; model.videoTracks) video ~= trackJson(track);
    JSONValue[] audio;
    foreach (track; model.audioTracks) audio ~= trackJson(track);

    JSONValue root = JSONValue([
        "format": JSONValue("aurora-cut-project"),
        "version": JSONValue(2L),
        "playhead": jsonNumber(playhead, 0.0, "project.playhead"),
        "hasWorkIn": JSONValue(hasWorkIn),
        "hasWorkOut": JSONValue(hasWorkOut),
        "workIn": jsonNumber(workIn, 0.0, "project.workIn"),
        "workOut": jsonNumber(workOut, 0.0, "project.workOut"),
        "previewQualityHeight": JSONValue(cast(long) previewQualityHeight),
        "assets": JSONValue(assets),
        "videoTracks": JSONValue(video),
        "audioTracks": JSONValue(audio)
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

private TimelineTrack parseTrack(const JSONValue value, TrackKind fallbackKind)
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
        "previewQualityHeight", 1080);

    auto assets = member(root, "assets");
    if (assets !is null && assets.type == JSONType.array)
        foreach (entry; assets.array)
        {
            auto asset = new MediaAsset(stringValue(entry, "path"));
            asset.name = stringValue(entry, "name", asset.name);
            asset.duration = numberValue(entry, "duration");
            asset.hasVideo = boolValue(entry, "hasVideo");
            asset.hasAudio = boolValue(entry, "hasAudio");
            asset.width = cast(int) integerValue(entry, "width");
            asset.height = cast(int) integerValue(entry, "height");
            asset.frameRate = numberValue(entry, "frameRate");
            asset.audioChannels = cast(int) integerValue(entry, "audioChannels");
            asset.sampleRate = cast(int) integerValue(entry, "sampleRate");
            result.assets ~= asset;
        }

    auto video = member(root, "videoTracks");
    if (video !is null && video.type == JSONType.array)
        foreach (entry; video.array)
            result.videoTracks ~= parseTrack(entry, TrackKind.video);
    auto audio = member(root, "audioTracks");
    if (audio !is null && audio.type == JSONType.array)
        foreach (entry; audio.array)
            result.audioTracks ~= parseTrack(entry, TrackKind.audio);
    return result;
}
