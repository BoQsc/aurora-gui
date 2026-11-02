module actor_image_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.attachmentstore : AttachmentStore;
import auroraopencode.imagehistory : requestHistoryImageIndices, requestImageByteBudget;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.array : replicate;
import std.conv : to;
import std.file : mkdirRecurse, rename, write;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run test_actor_images.py");
    const directory = absolutePath("actor-images-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    const attachments = buildPath(opencodeStateDirectory(), "attachments");
    auto store = AttachmentStore(attachments);
    string[] digests;
    foreach (i; 0 .. 8) digests ~= store.put("fixture-pixels-" ~ to!string(i));
    ChatSession initial; initial.id = "actor-images"; initial.model = "actor-images";
    foreach (i; 0 .. 48)
    {
        ChatMessage message; message.id = "reference-" ~ to!string(i); message.role = "user";
        message.parentId = initial.activeLeafId; message.content = "Reference " ~ to!string(i);
        ChatImageAttachment image; image.mimeType = "image/png"; image.name = message.id ~ ".png";
        image.blob = digests[i % 8]; image.originalBlob = image.blob;
        message.images = [image]; initial.messages ~= message; initial.activeLeafId = message.id;
    }
    ChatMessage missing; missing.id = "missing-reference"; missing.role = "user";
    missing.parentId = initial.activeLeafId; missing.content = "An unavailable reference";
    ChatImageAttachment lost; lost.mimeType = "image/png"; lost.name = "unavailable.png";
    lost.blob = "A".replicate(64); missing.images = [lost];
    initial.messages ~= missing; initial.activeLeafId = missing.id;

    ActorConfiguration config; config.baseUrl = base; config.apiKey = "fixture";
    config.workspace = directory; config.recordTrace = true; config.request.contextLimit = 64_000;
    auto actor = new ConversationActor(initial, config, null);
    string originalReply;
    foreach (round; 0 .. 3)
    {
        const command = round == 0 ? ActorCommand(ActorCommandKind.start, "Analyze these references.") :
            round == 1 ? ActorCommand(ActorCommandKind.start, "Explain the analysis in words.") :
            ActorCommand(ActorCommandKind.regenerate, "", originalReply);
        assert(actor.post(command) == ActorAdmission.accepted);
        bool ready, began;
        JSONValue latest;
        const deadline = MonoTime.currTime + 10.seconds;
        while (MonoTime.currTime < deadline && !ready)
        {
            foreach (change; actor.takeChanges())
            {
                assert(change.kind != ActorChangeKind.fault, change.text);
                if (change.kind == ActorChangeKind.added)
                {
                    const message = parseJSON(change.text);
                    if (round == 0 && message["role"].str == "assistant") originalReply = change.itemId;
                    if (auto images = "images" in message.object)
                        foreach (image; images.array) assert(!("base64Data" in image.object));
                }
                if (change.kind != ActorChangeKind.metadata) continue;
                latest = parseJSON(change.text);
                if (latest["turnStatus"].str == "running") began = true;
            }
            if (latest.type == JSONType.object) ready = began && latest["turnStatus"].str == "completed";
            assert(!actor.fault().length, actor.fault()); Thread.sleep(2.msecs);
        }
        assert(ready, "Image turn did not complete");
        const execution = latest["execution"];
        assert(execution["routingKey"].str == "aurora-reference-0", "Branch navigation changed the stable provider route");
        assert(execution["selectedImages"].integer == (round == 1 ? 0 : 2));
        assert(execution["selectedImageBytes"].integer <= requestImageByteBudget);
        assert(execution["imageSizeReads"].integer <= 3 && execution["imageBlobReads"].integer <= 2,
            "Execution eagerly opened historical image blobs outside the request window");
    }
    actor.close(); assert(!actor.fault().length, actor.fault());
    const snapshot = actor.finalSnapshot();
    const state = parseJSON(snapshot);
    size_t resident;
    foreach (message; state["messages"].array)
        if (auto images = "images" in message.object)
            foreach (image; images.array)
                if (auto pixels = "base64Data" in image.object) if (pixels.str.length) ++resident;
    assert(resident == 2, "Actor retained hydrated pixels outside the request window");
    assert(state["messages"].array[48]["images"].array[0]["attachmentError"].str.length,
        "An unavailable image lost its reference without a diagnostic");
    const trace = actor.recordedTrace();
    write(buildPath(directory, "trace.json"), trace); write(buildPath(directory, "final.json"), snapshot);
    rename(attachments, attachments ~ "-offline"); config.baseUrl = "http://127.0.0.1:1";
    assert(parseJSON(ConversationActor.replay(initial, config, trace)) == state,
        "Image replay read offline blobs or changed retirement/branch state");

    // A malicious size cannot overflow the byte budget or force a payload read.
    size_t probes;
    size_t huge(const ref ChatImageAttachment image) { ++probes; return size_t.max; }
    const selected = requestHistoryImageIndices(initial, activeMessagePath(initial), 0, 2, &huge);
    foreach (indices; selected) assert(!indices.length);
    assert(probes == 2, "Image size probing ignored the message window");
    writeln("PASS lazy request hydration, unavailable reference, retirement, branch rehydration and exact offline replay");
    return 0;
}
