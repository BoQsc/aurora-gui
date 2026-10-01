module screenshot_history_test;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : ChatMessage, ChatImageAttachment, ChatSession,
    ChatRequestMessage, Settings, setOpencodeStateDirectoryForTesting,
    saveSettings, opencodeTheme;
import auroraopencode.imagehistory : requestHistoryImages, pruneHistoryImages;
import auroraopencode.screenshotimage : encodeScreenshotJpeg, pngScreenshotToJpeg;
import std.file : write, read, tempDir, mkdirRecurse, rmdirRecurse;
import std.path : buildPath;
import std.uuid : randomUUID;
import std.conv : to;
import std.string : indexOf;
import std.stdio : writeln;

private void validateToolPairs(const(ChatRequestMessage)[] messages)
{
    foreach (slot, message; messages)
        foreach (call; message.toolCalls)
        {
            bool found;
            for (size_t i = slot + 1; i < messages.length &&
                    messages[i].role == "tool"; ++i)
                if (messages[i].toolCallId == call.id) found = true;
            assert(found, "Compaction orphaned a tool call");
        }
}

int main(string[] args)
{
    const directory = buildPath(tempDir(), "aurora-jpeg-test-" ~ randomUUID().toString());
    mkdirRecurse(directory);
    scope (exit) rmdirRecurse(directory);

    // An odd-width crop exercises row padding and RGB/BGR conversion.
    enum width = 101, height = 77;
    auto rgb = new ubyte[width * height * 3];
    foreach (y; 0 .. height)
        foreach (x; 0 .. width)
        {
            const offset = (y * width + x) * 3;
            rgb[offset] = y < height / 2 ? 240 : 10;
            rgb[offset + 1] = 20;
            rgb[offset + 2] = y < height / 2 ? 10 : 240;
        }
    auto jpeg = encodeScreenshotJpeg(width, height, rgb);
    assert(jpeg.length > 3 && jpeg[0 .. 3] == [0xFF, 0xD8, 0xFF]);
    if (args.length > 1) write(buildPath(args[1], "odd-width.jpg"), jpeg);
    bool invalidRejected;
    try { encodeScreenshotJpeg(width, height, rgb[0 .. $ - 1]); }
    catch (Exception) { invalidRejected = true; }
    assert(invalidRejected);
    if (args.length > 2)
        foreach (path; args[2 .. $])
            write(path ~ ".jpg", pngScreenshotToJpeg(cast(ubyte[]) read(path)));

    ChatSession session;
    ChatMessage upload;
    upload.role = "user";
    upload.images = [ChatImageAttachment("image/png", "user-pixels", "reference.png")];
    session.messages ~= upload;
    size_t[] path = [0];
    // Thousands of frames, including batches and an inactive branch.
    foreach (round; 0 .. 1500)
    {
        ChatMessage message;
        message.role = "user";
        message.internal = true;
        foreach (frame; 0 .. 3)
            message.images ~= ChatImageAttachment("image/jpeg",
                "frame-" ~ to!string(round) ~ "-" ~ to!string(frame), "screen.jpg");
        session.messages ~= message;
        path ~= session.messages.length - 1;
        pruneHistoryImages(session, path, 2);
        auto wire = requestHistoryImages(session, path, 0, 2);
        size_t screens;
        foreach (images; wire[1 .. $]) screens += images.length;
        assert(screens == 1, "A long chat reuploaded stale screens");
        assert(wire[0].length == 1, "Screens displaced the user's reference image");
    }
    auto branch = session.messages[$ - 1];
    branch.images = [ChatImageAttachment("image/png", "branch-pixels", "screen.png")];
    session.messages ~= branch;
    auto branchUpload = upload;
    branchUpload.images = [ChatImageAttachment("image/png", "branch-user-pixels", "reference.png")];
    foreach (i; 0 .. 12) session.messages ~= branchUpload;
    pruneHistoryImages(session, path, 2);
    size_t storedScreens;
    foreach (message; session.messages[1 .. $])
        foreach (image; message.images)
            if (image.base64Data.length && image.name.indexOf("screen.") == 0) ++storedScreens;
    assert(storedScreens == 2, "Inactive branches leaked screenshot payloads");
    assert(session.messages[$ - 1].images[0].base64Data == "branch-user-pixels",
        "Screenshot pruning discarded a user's inactive-branch attachment");
    auto suffix = requestHistoryImages(session, path, path.length - 1, 2);
    assert(suffix[$ - 1].length == 1 && suffix[0].length == 0);
    writeln("4,500 frames: one on wire, two retained; user images preserved");

    // Recovery evidence is a current pair, never another growing image history.
    foreach (round; 0 .. 1000)
    {
        ChatMessage recovery;
        recovery.role = "user";
        recovery.internal = true;
        recovery.images = [
            ChatImageAttachment("image/jpeg", "target-" ~ to!string(round), "screen-target.jpg"),
            ChatImageAttachment("image/jpeg", "instructions-" ~ to!string(round), "screen-instructions.jpg")];
        session.messages ~= recovery;
        path ~= session.messages.length - 1;
        pruneHistoryImages(session, path, 2);
        auto wire = requestHistoryImages(session, path, 0, 2);
        size_t generated;
        foreach (images; wire[1 .. $]) generated += images.length;
        assert(generated == 2 && wire[$ - 1].length == 2,
            "Recovery evidence accumulated or lost part of the current pair");
        assert(wire[0].length == 1, "Recovery evidence displaced the user attachment");
    }
    storedScreens = 0;
    foreach (message; session.messages)
        if (message.internal)
            foreach (image; message.images)
                if (image.base64Data.length) ++storedScreens;
    assert(storedScreens == 2, "Recovery images escaped whole-graph pruning");
    // A subsequent full frame replaces both crops in the request.
    ChatMessage currentScreen;
    currentScreen.role = "user";
    currentScreen.internal = true;
    currentScreen.images = [ChatImageAttachment("image/jpeg", "new-full", "screen.jpg")];
    session.messages ~= currentScreen;
    path ~= session.messages.length - 1;
    auto newWire = requestHistoryImages(session, path, 0, 2);
    size_t newGenerated;
    foreach (images; newWire[1 .. $]) newGenerated += images.length;
    assert(newGenerated == 1 && newWire[$ - 1][0].base64Data == "new-full");
    writeln("1,000 recovery pairs: latest pair only, two retained; a new full frame replaces both");

    setOpencodeStateDirectoryForTesting(directory);
    scope (exit) setOpencodeStateDirectoryForTesting("");
    Settings settings;
    settings.baseUrl = "http://127.0.0.1:1/v1";
    settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options;
    options.title = "Screenshot and long-chat regression";
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    string[] roles = ["user"];
    string[] contents = ["Durable objective: finish the screenshot optimization."];
    foreach (round; 0 .. 240)
    {
        roles ~= "assistant";
        auto text = new char[6000];
        text[] = 'x';
        contents ~= "Historical step " ~ to!string(round) ~ ": " ~ text.idup;
    }
    roles ~= "user";
    contents ~= "LATEST-INSTRUCTION: preserve native screenshot coordinates.";
    root.addConversationForTesting(roles, contents);
    root.appendToolRequestTurnForTesting("", "call-1", "read", "{}");
    root.appendToolReplyForTesting("call-1", "Current tool output.");
    bool created;
    auto compacted = root.rollingRequestMessagesForTesting(128000, created);
    assert(created && root.compactionAnchorForTesting().length);
    size_t bytes;
    bool latest, objective;
    foreach (message; compacted)
    {
        bytes += message.content.length + message.reasoningContent.length;
        latest |= message.content.indexOf("LATEST-INSTRUCTION") >= 0;
        objective |= message.content.indexOf("Durable objective") >= 0;
    }
    assert(bytes < 324000 && latest && objective,
        "Long-chat compaction lost instructions or exceeded the budget");
    validateToolPairs(compacted);
    auto anchor = root.compactionAnchorForTesting();
    root.persistForTesting();
    root.reloadSessionsForTesting();
    assert(root.compactionAnchorForTesting() == anchor);
    auto restored = root.rollingRequestMessagesForTesting(128000, created);
    assert(!created, "Reload discarded the rolling checkpoint");
    validateToolPairs(restored);
    foreach (cycle; 0 .. 3)
    {
        string[] moreRoles, moreContent;
        foreach (round; 0 .. 100)
        {
            moreRoles ~= "assistant";
            moreContent ~= contents[1];
        }
        moreRoles ~= "user";
        moreContent ~= "LATEST-INSTRUCTION: keep optimizing screenshots.";
        root.addConversationForTesting(moreRoles, moreContent);
        auto next = root.rollingRequestMessagesForTesting(128000, created);
        assert(created, "A growing chat stopped rolling its checkpoint");
        size_t nextBytes;
        bool goalKept, latestKept;
        foreach (message; next)
        {
            nextBytes += message.content.length + message.reasoningContent.length;
            goalKept |= message.content.indexOf("Durable objective") >= 0;
            latestKept |= message.content.indexOf("LATEST-INSTRUCTION") >= 0;
        }
        assert(nextBytes < 324000 && goalKept && latestKept);
        validateToolPairs(next);
    }
    writeln("1.4 MB chat compacted to ", bytes,
        " bytes; objective, latest instruction, tool pairs and checkpoint survive reload");
    writeln("Three further checkpoint rollovers preserve the objective and bounded requests");
    // A failed batch still carries valid visual evidence for the next decision.
    import std.base64 : Base64;
    root.pauseToolContinuationForTesting();
    root.appendToolRequestTurnForTesting("", "call_inject", "computer", "{}");
    auto screen = ChatImageAttachment("image/jpeg", Base64.encode(jpeg).idup, "screen.jpg");
    root.injectToolResultForTesting("computer", "Error: step 2 failed. Screen after the batch.",
        true, "{}", 0, 0, "", [screen]);
    auto failedRequest = root.requestMessagesForTesting();
    assert(failedRequest[$ - 1].images.length == 1 &&
        failedRequest[$ - 1].images[0].base64Data == screen.base64Data,
        "Failed computer batch discarded its fresh screenshot");
    assert(failedRequest[$ - 1].content.indexOf("reported failure") >= 0);
    assert(root.lastToolResultForTesting().indexOf("Error: step 2 failed") >= 0);
    root.persistForTesting();
    root.reloadSessionsForTesting();
    failedRequest = root.requestMessagesForTesting();
    assert(failedRequest[$ - 1].images.length == 1);
    writeln("Failed-batch screenshot reaches the next request and survives save/reload");
    root.pauseToolContinuationForTesting();
    root.appendToolRequestTurnForTesting("", "call_recovery", "computer", "{}");
    auto recoveryImages = [
        ChatImageAttachment("image/jpeg", screen.base64Data, "screen-target.jpg"),
        ChatImageAttachment("image/jpeg", screen.base64Data, "screen-instructions.jpg")];
    root.injectToolResultForTesting("computer", "Withheld click. Focused target and instruction evidence.",
        true, "{}", 0, 0, "", recoveryImages);
    auto recoveryRequest = root.requestMessagesForTesting();
    assert(recoveryRequest[$ - 1].images.length == 2);
    assert(recoveryRequest[$ - 1].images[0].name == "screen-target.jpg" &&
        recoveryRequest[$ - 1].images[1].name == "screen-instructions.jpg");
    root.persistForTesting();
    root.reloadSessionsForTesting();
    recoveryRequest = root.requestMessagesForTesting();
    assert(recoveryRequest[$ - 1].images.length == 2 &&
        recoveryRequest[$ - 1].images[0].base64Data == screen.base64Data &&
        recoveryRequest[$ - 1].images[1].base64Data == screen.base64Data,
        "Recovery pair did not survive save/reload");
    writeln("Failed-action recovery pair reaches the next request and survives save/reload");
    return 0;
}
