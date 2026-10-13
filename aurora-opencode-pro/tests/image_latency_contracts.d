module image_latency_contracts;

import aurora;
import auroraopencode.core;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.attachments;
import auroraopencode.attachmentstore : AttachmentStore;
import auroraopencode.imagecontext;
import auroraopencode.imagehistory;
import auroraopencode.imagenormalization;
import auroraopencode.requestbuilder : projectRequestMessages;
import auroraopencode.tools : executeTool;
import std.base64 : Base64;
import std.bitmanip : nativeToBigEndian;
import std.digest.crc : crc32Of;
import std.zlib : compress;
import std.json : JSONValue, parseJSON;
import std.file : mkdirRecurse, write, tempDir, rmdirRecurse;
import std.path : buildPath;
import std.string : indexOf;
import std.conv : to;
import std.stdio : writeln;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;

private ubyte[] generatedPng()
{
    enum width = 1920, height = 1080;
    ubyte[] pixels = new ubyte[(width * 3 + 1) * height];
    uint random = 731;
    foreach (y; 0 .. height)
        foreach (x; 1 .. width * 3 + 1)
        {
            random ^= random << 13; random ^= random >> 17; random ^= random << 5;
            pixels[y * (width * 3 + 1) + x] = cast(ubyte) (24 + random % 7);
        }
    ubyte[] png = [137, 80, 78, 71, 13, 10, 26, 10];
    void chunk(string kind, const(ubyte)[] bytes)
    {
        png ~= nativeToBigEndian(cast(uint) bytes.length);
        const body = cast(const(ubyte)[]) kind ~ bytes;
        png ~= body;
        const crc = crc32Of(body);
        png ~= [crc[3], crc[2], crc[1], crc[0]];
    }
    ubyte[] header = nativeToBigEndian(cast(uint) width) ~ nativeToBigEndian(cast(uint) height);
    header ~= [8, 2, 0, 0, 0];
    chunk("IHDR", header);
    chunk("IDAT", cast(ubyte[]) compress(pixels));
    chunk("IEND", null);
    return png;
}

private size_t imageCount(const(ChatRequestMessage)[] messages)
{
    size_t count;
    foreach (message; messages) count += message.images.length;
    return count;
}

int main()
{
    const directory = buildPath(tempDir(), "aurora-image-contract-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory);
    setOpencodeStateDirectoryForTesting(directory);
    scope (exit) setOpencodeStateDirectoryForTesting("");
    scope (exit) rmdirRecurse(directory);
    const png = generatedPng();
    assert(png.length > 1024 * 1024 && png.length < attachmentImageInputMaxBytes);
    const path = buildPath(directory, "reference.png");
    write(path, png);
    const started = MonoTime.currTime;
    auto attached = attachmentForFile(path);
    const conversionMs = (MonoTime.currTime - started).total!"msecs";
    assert(attached.isImage && attached.image.mimeType == "image/jpeg");
    assert(attached.image.originalWidth == 1920 && attached.image.originalHeight == 1080 &&
        attached.image.width == 1600 && attached.image.height == 900);
    assert(Base64.decode(attached.image.base64Data).length <= inlineImageByteBudget);
    auto store = AttachmentStore(buildPath(directory, "attachments"));
    assert(Base64.decode(store.get(attached.image.originalBlob)) == png, "Original was not preserved exactly");
    auto dimensions = normalizeImage(Base64.decode(attached.image.base64Data), "image/jpeg");
    assert(dimensions.width == 1600 && dimensions.height == 900, "Proportional resize lost unnecessary detail");
    // EXIF orientation 6 rotates a JPEG clockwise; crop coordinates must use
    // that upright original, even when a small JPEG can otherwise pass through.
    const jpegBytes = Base64.decode(attached.image.base64Data);
    ubyte[] exif = [0xFF, 0xE1, 0, 34, 'E', 'x', 'i', 'f', 0, 0,
        'I', 'I', 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 1, 3, 0,
        1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0];
    auto rotated = jpegBytes[0 .. 2] ~ exif ~ jpegBytes[2 .. $];
    auto upright = normalizeImage(rotated, "image/jpeg");
    assert(upright.originalWidth == 900 && upright.originalHeight == 1600);
    auto uprightCrop = normalizeImage(rotated, "image/jpeg", true, ImageCrop(10, 1000, 200, 400));
    assert(uprightCrop.width == 200 && uprightCrop.height == 400,
        "Crop coordinates did not follow the upright original");
    auto json = imageAttachmentToJson(attached.image);
    store.externalize(json);
    store.hydrate(json);
    assert(imageAttachmentFromJson(json) == attached.image ||
        imageAttachmentFromJson(json).originalBlob == attached.image.originalBlob);
    JSONValue args;
    args["filePath"] = path;
    auto viewed = executeTool(OpenCodeToolCall("read-image", "view_image", args.toString()), directory);
    assert(!viewed.failed && viewed.images.length == 1);
    assert(viewed.images[0].mimeType == attached.image.mimeType &&
        viewed.images[0].base64Data == attached.image.base64Data &&
        viewed.images[0].originalBlob == attached.image.originalBlob,
        "Tool image differs from composer optimization or archive metadata was lost over IPC");
    // Reinspect an original after its source file is unavailable, with a crop.
    args = JSONValue.init;
    args["attachmentBlob"] = attached.image.originalBlob;
    args["detail"] = "original";
    args["crop"] = JSONValue.emptyObject;
    args["crop"]["x"] = 10; args["crop"]["y"] = 20;
    args["crop"]["width"] = 800; args["crop"]["height"] = 400;
    auto cropped = executeTool(OpenCodeToolCall("crop-image", "view_image", args.toString()), directory);
    assert(!cropped.failed && cropped.images.length == 1 && cropped.images[0].originalDetail);
    auto cropSize = normalizeImage(Base64.decode(cropped.images[0].base64Data), "image/jpeg");
    assert(cropSize.width == 800 && cropSize.height == 400);
    args["crop"]["x"] = 1900;
    assert(executeTool(OpenCodeToolCall("bad-crop", "view_image", args.toString()), directory).failed);
    write(buildPath(directory, "invalid.png"), "This is text, not image pixels.");
    assert(!attachmentForFile(buildPath(directory, "invalid.png")).isImage);
    writeln("PASS shared normalization, proportional dimensions, exact original archive, host IPC, crop and validation; conversion_ms=", conversionMs);

    ChatSession session;
    ChatMessage user;
    user.id = "reference"; user.role = "user"; user.content = "Use this reference";
    user.images = [attached.image];
    session.messages ~= user;
    foreach (i; 0 .. 2)
    {
        ChatMessage evidence;
        evidence.id = "tool-" ~ to!string(i); evidence.role = "user"; evidence.internal = true;
        evidence.images = [attached.image];
        session.messages ~= evidence;
    }
    auto retained = requestHistoryImages(session, [0UL, 1UL, 2UL], 0, 2);
    assert(retained[0].length == 1 && retained[1].length == 0 && retained[2].length == 1,
        "Tool reads evicted the user reference");
    session.messages = [user];
    session.activeLeafId = user.id;
    assert(imageCount(projectRequestMessages(session)) == 1);
    JSONValue retire;
    retire["imageIds"] = ["reference:1"];
    retire["summary"] = "Visual reference: dark background. Further work only needs this recorded finding.";
    const retired = executeTool(OpenCodeToolCall("retire", "retire_images", retire.toString()), directory);
    assert(!retired.failed && retireImagesSessionError(session, retire.toString()).length == 0);
    ChatMessage request;
    request.id = "retire-call"; request.parentId = user.id; request.role = "assistant";
    request.toolCalls = [OpenCodeToolCall("retire", "retire_images", retire.toString())];
    session.messages ~= request;
    ChatMessage reply;
    reply.id = "retire-reply"; reply.parentId = request.id; reply.role = "tool";
    reply.toolName = "retire_images"; reply.toolCallId = "retire";
    reply.toolArgs = retire.toString(); reply.content = retired.output;
    session.messages ~= reply;
    session.activeLeafId = reply.id;
    const textOnly = projectRequestMessages(session);
    assert(imageCount(textOnly) == 0 && textOnly[$ - 1].content.indexOf("dark background") >= 0);
    assert(session.messages[0].images[0].base64Data == attached.image.base64Data);
    session.activeLeafId = user.id;
    assert(imageCount(projectRequestMessages(session)) == 1, "Retirement leaked into a sibling branch");
    session.activeLeafId = reply.id;
    session.messages[$ - 1].failed = true;
    assert(imageCount(projectRequestMessages(session)) == 1, "Failed retirement hid pixels");
    retire["imageIds"] = ["unknown:1"];
    assert(retireImagesSessionError(session, retire.toString()).length);
    retire["summary"] = "";
    assert(retireImagesArgumentsError(retire.toString()).length);
    session.messages[$ - 1].failed = false;
    ChatMessage followup;
    followup.id = "text-followup"; followup.parentId = reply.id; followup.role = "user";
    followup.content = "Continue editing code using your recorded findings.";
    session.messages ~= followup; session.activeLeafId = followup.id;
    assert(imageCount(projectRequestMessages(session)) == 0, "A later text reply restored retired pixels");
    // One message with many images cannot evade aggregate count/byte limits.
    session.messages = [user]; session.activeLeafId = user.id;
    foreach (_; 0 .. 20) session.messages[0].images ~= attached.image;
    auto bounded = projectRequestMessages(session);
    assert(imageCount(bounded) <= requestImageCountBudget);
    size_t transmitted;
    foreach (message; bounded) foreach (image; message.images) transmitted += image.base64Data.length;
    assert(transmitted <= requestImageByteBudget && bounded[0].content.indexOf("omitted") >= 0);
    ChatMessage batchAnswer; batchAnswer.id = "batch-answer"; batchAnswer.parentId = user.id;
    batchAnswer.role = "assistant"; batchAnswer.content = "Recorded findings; reload originals for unseen details.";
    session.messages ~= batchAnswer; session.activeLeafId = batchAnswer.id;
    session.messages[$ - 1].retiredImages = completedReplyImageIds(session, batchAnswer.id, 2);
    assert(imageCount(projectRequestMessages(session)) == 0,
        "Images omitted by the budget rotated back into a later request after completion");
    session.messages.length = 1; session.activeLeafId = user.id;
    session.messages[0].images.length = 5;
    foreach (ref image; session.messages[0].images)
    {
        auto synthetic = new char[800 * 1024]; synthetic[] = 'A';
        image.base64Data = synthetic.idup;
    }
    bounded = projectRequestMessages(session);
    assert(imageCount(bounded) == 3, "Aggregate byte budget was not enforced below the image-count cap");
    // An explicit original can use the larger single-image allowance.
    session.messages[0].images.length = 1;
    auto full = new char[4 * 1024 * 1024]; full[] = 'A';
    session.messages[0].images[0].base64Data = full.idup;
    session.messages[0].images[0].originalDetail = true;
    assert(imageCount(projectRequestMessages(session)) == 1);
    writeln("PASS retired images leave later requests, summaries and originals remain, branches and failed results retain pixels, batch budget enforced");

    // Drive the real UI event handler and persistence boundary, without a provider.
    Settings settings; settings.baseUrl = "http://127.0.0.1:1/v1"; settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope (exit) root.shutdownClient();
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    { root.tickTree(0.02); Thread.sleep(5.msecs); }
    assert(!root.startupPendingForTesting());
    root.addConversationForTesting(["user"], ["Inspect this image and continue with text."]);
    root.pauseToolContinuationForTesting();
    root.appendToolRequestTurnForTesting("", "call_inject", "view_image", "{}");
    root.injectToolResultForTesting("view_image", viewed.output, false, "{}", 0, 0, "", viewed.images);
    auto before = root.requestMessagesForTesting();
    assert(imageCount(before) == 1);
    const label = before[$ - 1].content;
    const labelStart = label.indexOf("[Image ") + 7;
    const labelEnd = label[labelStart .. $].indexOf(": ") + labelStart;
    const imageId = label[labelStart .. labelEnd];
    retire["imageIds"] = [imageId]; retire["summary"] = "Recorded visual finding: dark background.";
    auto result = executeTool(OpenCodeToolCall("retire", "retire_images", retire.toString()), directory);
    root.appendToolRequestTurnForTesting("", "call_inject", "retire_images", retire.toString());
    root.injectToolResultForTesting("retire_images", result.output, false, retire.toString());
    assert(imageCount(root.requestMessagesForTesting()) == 0);
    root.persistForTesting(); root.reloadSessionsForTesting();
    auto restored = root.requestMessagesForTesting();
    assert(imageCount(restored) == 0 && root.lastToolResultForTesting().indexOf("dark background") >= 0);
    bool archiveReferenceRestored;
    foreach (message; restored)
        archiveReferenceRestored |= message.content.indexOf(attached.image.originalBlob) >= 0;
    assert(archiveReferenceRestored, "Original archive metadata was lost during reload");
    // The original remains readable after a save/reload and can become new evidence.
    args = JSONValue.init; args["attachmentBlob"] = attached.image.originalBlob;
    auto reopened = executeTool(OpenCodeToolCall("reopen", "view_image", args.toString()), directory);
    assert(!reopened.failed && reopened.images[0].base64Data == attached.image.base64Data);
    root.pauseToolContinuationForTesting();
    root.appendToolRequestTurnForTesting("", "call_inject", "view_image", args.toString());
    root.injectToolResultForTesting("view_image", reopened.output, false, args.toString(), 0, 0, "", reopened.images);
    assert(imageCount(root.requestMessagesForTesting()) == 1);
    retire["imageIds"] = ["missing:1"];
    root.appendToolRequestTurnForTesting("", "call_inject", "retire_images", retire.toString());
    root.injectToolResultForTesting("retire_images", "success placeholder", false, retire.toString());
    assert(root.lastToolResultForTesting().indexOf("not on this conversation branch") >= 0 &&
        imageCount(root.requestMessagesForTesting()) == 1);
    writeln("PASS real tool-result path: retirement survives journal/snapshot reload, archived original can be reopened, unknown references rejected");
    root.setImageToolsEnabledForTesting(true);
    root.setAutoRetireImagesForTesting(true);
    root.startTurnClockForTesting(); root.beginStreamForTesting();
    root.streamContentForTesting("Visual analysis complete: the reference has a dark background.");
    root.finishStreamForTesting();
    assert(imageCount(root.requestMessagesForTesting()) == 0, "Successful final answer did not retire pixels automatically");
    root.persistForTesting(); root.reloadSessionsForTesting();
    assert(imageCount(root.requestMessagesForTesting()) == 0, "Automatic retirement did not survive reload");
    root.addConversationForTesting(["user"], ["Continue using the recorded analysis."]);
    assert(imageCount(root.requestMessagesForTesting()) == 0, "Later user message reactivated completed image analysis");
    root.pauseToolContinuationForTesting();
    root.appendToolRequestTurnForTesting("", "call_inject", "view_image", args.toString());
    root.injectToolResultForTesting("view_image", reopened.output, false, args.toString(), 0, 0, "", reopened.images);
    root.setAutoRetireImagesForTesting(false);
    root.startTurnClockForTesting(); root.beginStreamForTesting();
    root.streamContentForTesting("Keep this visual reference active."); root.finishStreamForTesting();
    assert(imageCount(root.requestMessagesForTesting()) == 1, "Disabled automatic retirement still removed pixels");
    root.setAutoRetireImagesForTesting(true);
    root.startTurnClockForTesting(); root.beginStreamForTesting();
    root.streamContentForTesting("Partial inspection"); root.cancelStreamForTesting();
    assert(imageCount(root.requestMessagesForTesting()) == 1, "Cancelled analysis retired pixels");
    root.setImageToolsEnabledForTesting(false);
    root.startTurnClockForTesting(); root.beginStreamForTesting();
    root.streamContentForTesting("Keep pixels because reinspection tools are disabled."); root.finishStreamForTesting();
    assert(imageCount(root.requestMessagesForTesting()) == 1);
    // Pure completion helper excludes truncated output and is idempotent.
    session.messages = [user]; session.messages[0].images = [attached.image];
    ChatMessage finalReply; finalReply.id = "completed"; finalReply.parentId = user.id;
    finalReply.role = "assistant"; finalReply.content = "Recorded visual finding.";
    session.messages ~= finalReply; session.activeLeafId = finalReply.id;
    auto autoIds = completedReplyImageIds(session, finalReply.id, 2);
    assert(autoIds.length == 1);
    session.messages[$ - 1].retiredImages = autoIds;
    assert(completedReplyImageIds(session, finalReply.id, 2) == autoIds);
    session.messages[$ - 1].retiredImages = null; session.messages[$ - 1].finishReason = "length";
    assert(completedReplyImageIds(session, finalReply.id, 2).length == 0);
    Settings preferences; preferences.autoRetireImages = false; saveSettings(preferences);
    assert(!loadSettings().autoRetireImages);
    writeln("PASS automatic retirement after successful answers and later text replies, persistence, opt-out, cancellation, truncation and tools-disabled retention");
    return 0;
}
