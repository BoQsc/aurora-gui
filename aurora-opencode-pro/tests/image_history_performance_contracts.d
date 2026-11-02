module image_history_performance_contracts;

import aurora;
import auroraopencode.core;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.attachmentstore : AttachmentStore;
import auroraopencode.restorestore : readThreadHistory;
import auroraopencode.runtime : readAgentRuntimeEvents, projectAgentRuntimeEvents;
import auroraopencode.projectioncache : RequestProjectionCache, ProjectionRevision;
import auroraopencode.imagehistory : requestImageByteBudget;
import core.memory : GC;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.algorithm : sort;
import std.array : appender, replicate;
import std.base64 : Base64;
import std.bitmanip : nativeToBigEndian;
import std.conv : to;
import std.digest.crc : crc32Of;
import std.file : mkdirRecurse, write;
import std.json : JSONValue;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;
import std.zlib : compress;

private string noisyPng(uint random)
{
    enum width = 256, height = 256;
    auto pixels = new ubyte[(width * 3 + 1) * height];
    foreach (y; 0 .. height)
        foreach (x; 1 .. width * 3 + 1)
        {
            random ^= random << 13; random ^= random >> 17; random ^= random << 5;
            pixels[y * (width * 3 + 1) + x] = cast(ubyte) random;
        }
    ubyte[] png = [137, 80, 78, 71, 13, 10, 26, 10];
    void chunk(string kind, const(ubyte)[] bytes)
    {
        png ~= nativeToBigEndian(cast(uint) bytes.length);
        const body = cast(const(ubyte)[]) kind ~ bytes;
        png ~= body;
        const crc = crc32Of(body); png ~= [crc[3], crc[2], crc[1], crc[0]];
    }
    auto header = nativeToBigEndian(cast(uint) width) ~ nativeToBigEndian(cast(uint) height);
    header ~= [8, 2, 0, 0, 0]; chunk("IHDR", header);
    chunk("IDAT", cast(ubyte[]) compress(pixels)); chunk("IEND", null);
    return Base64.encode(png).idup;
}

private Widget findWidget(Widget root, string id)
{
    if (root.id() == id) return root;
    foreach (child; root.children()) if (auto found = findWidget(child, id)) return found;
    return null;
}

int main()
{
    const state = absolutePath("image-history-state");
    mkdirRecurse(buildPath(state, "threads")); setOpencodeStateDirectoryForTesting(state);
    Settings settings; settings.baseUrl = "http://127.0.0.1:9";
    settings.quickTitle = false; settings.toolsEnabled = false;
    settings.experimentalChatRedesign = false; saveSettings(settings);
    auto store = AttachmentStore(buildPath(state, "attachments"));
    string[] digests, pixels;
    foreach (i; 0 .. 8)
    { pixels ~= noisyPng(cast(uint) i + 31); digests ~= store.put(pixels[$ - 1]); }
    JSONValue history, index, metadata;
    JSONValue[] messages;
    auto journal = appender!string();
    size_t logicalBytes;
    foreach (i; 0 .. 512)
    {
        JSONValue message;
        message["id"] = "m" ~ to!string(i); message["role"] = "user";
        if (i) message["parentId"] = "m" ~ to!string(i - 1);
        message["content"] = "image-proof-" ~ to!string(i) ~ "-end";
        ChatImageAttachment image;
        image.mimeType = "image/png"; image.name = "reference-" ~ to!string(i) ~ ".png";
        image.blob = digests[i % 8]; image.originalBlob = image.blob;
        message["images"] = JSONValue([imageAttachmentToJson(image)]);
        messages ~= message; logicalBytes += pixels[i % 8].length;
        JSONValue event;
        event["schema"] = 1; event["sequence"] = cast(long) i + 1;
        event["type"] = "item.added"; event["threadId"] = "image-history";
        event["itemId"] = message["id"]; event["payload"] = message;
        journal.put(event.toString() ~ "\n");
    }
    history["messages"] = JSONValue(messages);
    metadata["id"] = "image-history"; metadata["title"] = "Image history";
    metadata["activeLeaf"] = "m511";
    index["version"] = 2; index["current"] = 0; index["currentId"] = "image-history";
    index["sessions"] = JSONValue([metadata]);
    write(buildPath(state, "threads", "image-history.json"), history.toString());
    write(buildPath(state, "threads.index.json"), index.toString());
    const replayPath = buildPath(state, "image-replay-proof.jsonl"); write(replayPath, journal.data);

    auto before = GC.allocatedInCurrentThread();
    auto began = MonoTime.currTime;
    auto restored = readThreadHistory(state, "image-history");
    const restoreAllocated = GC.allocatedInCurrentThread() - before;
    assert(!restored.error.length && restored.messages.length == 512, restored.error);
    assert(restored.messages[0].images[0].base64Data.ptr == restored.messages[8].images[0].base64Data.ptr,
        "Restoring repeated references duplicated their immutable pixels");
    assert(restoreAllocated < logicalBytes / 2, "Snapshot restore allocated repeated image payloads");
    writeln("images=512 unique_blobs=8 logical_pixel_bytes=", logicalBytes,
        " restore_us=", (MonoTime.currTime - began).total!"usecs", " allocated_bytes=", restoreAllocated);
    before = GC.allocatedInCurrentThread(); began = MonoTime.currTime;
    auto events = readAgentRuntimeEvents(replayPath, true);
    auto replayed = projectAgentRuntimeEvents(events);
    const replayAllocated = GC.allocatedInCurrentThread() - before;
    assert(replayed.length == 1 && replayed[0].messages.length == 512);
    assert(replayed[0].messages[0].images[0].base64Data.ptr == replayed[0].messages[8].images[0].base64Data.ptr);
    assert(events[0].payloadJson.length < 2000, "Replay serialized hydrated pixels into each public event");
    assert(replayAllocated < logicalBytes / 2, "Journal replay duplicated repeated image payloads");
    writeln("image_replay_us=", (MonoTime.currTime - began).total!"usecs", " allocated_bytes=", replayAllocated);
    auto cache = new RequestProjectionCache();
    auto request = cache.project(replayed[0], ProjectionRevision(1, 1));
    size_t imageCount, imageBytes;
    foreach (message; request) foreach (image; message.images)
    { ++imageCount; imageBytes += image.base64Data.length; }
    assert(imageCount == 2 && imageBytes <= requestImageByteBudget);
    assert(cache.retainedBytes() <= 4 * 1024 * 1024);

    WindowOptions options; options.width = 1100; options.height = 780;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme()); auto root = new OpenCodeRoot(window);
    window.setRoot(root); scope (exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    const ready = MonoTime.currTime + 10.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    { window.onNativeTick(0.02); Thread.sleep(2.msecs); }
    assert(!root.startupPendingForTesting());
    while (root.hiddenHistoryCountForTesting()) root.loadOlderHistoryForTesting();
    began = MonoTime.currTime;
    root.projectTranscriptForTesting(); foreach (_; 0 .. 3) assert(driver.paint());
    writeln("image_chip_history_first_paints_us=", (MonoTime.currTime - began).total!"usecs");
    assert(root.materializedTranscriptRowsForTesting() < 100);
    auto input = findWidget(root, "oc-input"); assert(input !is null); input.requestFocus();
    long[] samples;
    foreach (_; 0 .. 20)
    {
        began = MonoTime.currTime; driver.text("x"d);
        root.rebuildForTesting(); root.projectTranscriptForTesting(); assert(driver.paint());
        samples ~= (MonoTime.currTime - began).total!"usecs";
    }
    samples.sort(); assert(root.inputTextForTesting() == "x".replicate(20));
    assert(samples[10] < 100_000 && samples[19] < 500_000);
    writeln("image_chip_input_rebuild_paint_median_us=", samples[10], " p95_us=", samples[19]);
    root.setChatSearchQueryForTesting("image-proof-73-end");
    foreach (_; 0 .. 8) { window.onNativeTick(0.02); root.projectTranscriptForTesting(); assert(driver.paint()); }
    assert(root.chatSearchMatchCountForTesting() == 1 && root.messageInViewportForTesting(73));
    assert(root.materializedTranscriptRowsForTesting() < 100);
    writeln("PASS shared image restore/replay, bounded request pixels, virtualized attachment chips, input and search reveal");
    return 0;
}
