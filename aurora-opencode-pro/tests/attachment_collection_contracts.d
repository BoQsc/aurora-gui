module attachment_collection_contracts;

import auroraopencode.attachmentstore;
import auroraopencode.attachmentgc;
import core.thread : Thread;
import core.time : MonoTime;
import std.file : mkdirRecurse, write, exists, remove, dirEntries, SpanMode;
import std.path : absolutePath, buildPath, baseName;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.array : replicate;
import std.conv : to;
import std.json : parseJSON;
import std.stdio : writeln;

private final class BlobWriter
{
    string directory, data, digest, error;
    this(string directory, string data) { this.directory = directory; this.data = data; }
    void run()
    {
        try
        {
            auto store = AttachmentStore(directory);
            foreach (_; 0 .. 4)
            { digest = store.put(data); assert(store.get(digest) == data); }
        }
        catch (Throwable failure) { error = failure.msg; }
    }
}

int main()
{
    const directory = absolutePath("attachment-gc-" ~ to!string(MonoTime.currTime.ticks));
    const blobs = buildPath(directory, "attachments");
    const histories = buildPath(directory, "threads");
    mkdirRecurse(blobs); mkdirRecurse(histories);
    auto store = AttachmentStore(blobs);
    string seed(string data)
    {
        const digest = sha256Of(data).toHexString().idup;
        write(buildPath(blobs, digest ~ ".b64"), data); return digest;
    }
    bool present(string digest) { return exists(buildPath(blobs, digest ~ ".b64")); }
    string reference(string digest) { return `{"images":[{"mimeType":"image/png","blob":"` ~ digest ~ `"}]}`; }
    const branch = seed("retained branch");
    const original = seed("retained original pixels");
    const backup = seed("retained backup");
    const legacy = seed("retained legacy");
    const journal = seed("retained journal");
    const inFlight = seed("reused before reference commit");
    const loaded = seed("loaded but no longer in the index");
    const originalInFlight = seed("original retained by an in-flight snapshot");
    const orphan = seed("orphan from a previous crash");
    write(buildPath(histories, "chat.json"), reference(branch));
    write(buildPath(histories, "original.json"),
        `{"images":[{"mimeType":"image/jpeg","originalBlob":"` ~ original ~ `"}]}`);
    write(buildPath(histories, "chat.json.bak"), reference(backup));
    write(buildPath(directory, "sessions.json"), reference(legacy));
    const journalPath = buildPath(directory, "runtime-events.jsonl");
    write(journalPath, reference(journal) ~ "\n");
    assert(store.put("reused before reference commit") == inFlight);
    assert(store.get(loaded) == "loaded but no longer in the index");
    auto pendingImage = parseJSON(`{"mimeType":"image/png","originalBlob":"` ~ originalInFlight ~ `"}`);
    store.externalize(pendingImage);
    AttachmentCollectionPolicy policy;
    policy.minimumAgeHours = 0; policy.timeBudgetMs = 5_000;
    auto result = collectAttachmentGarbage(directory, policy);
    assert(result.marked && result.deleted == 1 && !present(orphan), result.error);
    foreach (digest; [branch, original, backup, legacy, journal, inFlight, originalInFlight, loaded]) assert(present(digest));

    const pending = seed("must survive incomplete scans");
    const broken = buildPath(histories, "broken.json");
    write(broken, `{"messages":[`);
    result = collectAttachmentGarbage(directory, policy);
    assert(!result.marked && result.error.length && present(pending)); remove(broken);
    write(journalPath, reference(journal));
    result = collectAttachmentGarbage(directory, policy);
    assert(!result.marked && present(pending), "A torn journal permitted deletion");
    write(journalPath, reference(journal) ~ "\n");
    auto bounded = policy; bounded.maxReferences = 1;
    result = collectAttachmentGarbage(directory, bounded);
    assert(!result.marked && present(pending));
    bounded = policy; bounded.maxJsonBytes = 16;
    result = collectAttachmentGarbage(directory, bounded);
    assert(!result.marked && present(pending));
    bounded = policy; bounded.maxReferenceBytes = 32;
    result = collectAttachmentGarbage(directory, bounded);
    assert(!result.marked && present(pending));
    bounded = policy; bounded.minimumAgeHours = 24;
    result = collectAttachmentGarbage(directory, bounded);
    assert(result.marked && present(pending), "Collection ignored its age grace period");
    result = collectAttachmentGarbage(directory, policy);
    assert(result.marked && !present(pending));

    const concurrentData = "immutable shared attachment".replicate(40_000);
    BlobWriter[] writers; Thread[] threads;
    foreach (_; 0 .. 8)
    {
        auto writer = new BlobWriter(blobs, concurrentData); writers ~= writer;
        auto thread = new Thread(&writer.run); threads ~= thread; thread.start();
    }
    foreach (_; 0 .. 8) collectAttachmentGarbage(directory, policy);
    foreach (thread; threads) thread.join();
    foreach (writer; writers)
    { assert(!writer.error.length, writer.error); assert(store.get(writer.digest) == concurrentData); }
    foreach (entry; dirEntries(blobs, SpanMode.shallow))
        assert(baseName(entry.name).length == 68, "A concurrent write left temporary data behind");
    const corrupt = seed("checksum protected");
    write(buildPath(blobs, corrupt ~ ".b64"), "damaged");
    bool rejected;
    try store.put("checksum protected"); catch (Exception) { rejected = true; }
    assert(rejected);
    version (Windows)
    {
        // A valid final blob path near MAX_PATH must also admit its temporary
        // write. A suffix on the 64-character digest exceeded that limit.
        const longDirectory = buildPath(directory, "long-" ~ "x".replicate(183 - directory.length));
        mkdirRecurse(longDirectory);
        auto longStore = AttachmentStore(longDirectory);
        assert(longStore.get(longStore.put("long-path pixels")) == "long-path pixels");
    }
    writeln("PASS reference roots, in-flight pins, corruption/budget aborts, age grace and concurrent immutable writes during collection");
    return 0;
}
