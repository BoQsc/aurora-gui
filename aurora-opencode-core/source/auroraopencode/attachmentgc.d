module auroraopencode.attachmentgc;

import auroraopencode.attachmentstore : AttachmentStore, validAttachmentDigest;
import auroraopencode.logging : logInfo, logError;
import core.sync.mutex : Mutex;
import core.time : MonoTime, msecs, hours;
import std.array : appender;
import std.conv : to;
import std.datetime : Clock;
import std.file : dirEntries, SpanMode, exists, isSymlink;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : buildPath, baseName;
import std.stdio : File;
import std.string : startsWith, endsWith, indexOf, strip;

public struct AttachmentCollectionPolicy
{
    size_t maxReferenceBytes = 128 * 1024 * 1024;
    size_t maxJsonBytes = 8 * 1024 * 1024;
    size_t maxJournalLineBytes = 2 * 1024 * 1024;
    size_t maxReferences = 65_536;
    size_t maxFiles = 16_384;
    size_t maxDeletes = 128;
    long timeBudgetMs = 500;
    long minimumAgeHours = 24;
}

public struct AttachmentCollection
{
    bool marked;
    size_t deleted;
    ulong reclaimedBytes;
    string error;
}

/// Conservative collection in the application's single-owner state directory.
/// Every branch, backup, legacy snapshot and journal record is a root. A bad,
/// unreadable or over-budget reference source aborts before any deletion.
/// Process-live pins protect references not yet admitted to those files.
public AttachmentCollection collectAttachmentGarbage(string directory,
    AttachmentCollectionPolicy policy = AttachmentCollectionPolicy.init)
{
    AttachmentCollection result;
    const started = MonoTime.currTime;
    auto store = AttachmentStore(buildPath(directory, "attachments"));
    bool[string] references;
    size_t bytes, files;
    void checkBudget()
    {
        if (MonoTime.currTime - started >= policy.timeBudgetMs.msecs)
            throw new Exception("Attachment collection reached its time budget");
    }
    void mark(JSONValue value)
    {
        if (value.type == JSONType.array)
            foreach (child; value.array) mark(child);
        else if (value.type == JSONType.object)
        {
            foreach (key; ["blob", "originalBlob"])
            if (auto blob = key in value.object)
                if ("mimeType" in value.object)
                {
                    if (blob.type != JSONType.string || !validAttachmentDigest(blob.str))
                        throw new Exception("Invalid attachment reference; collection deferred");
                    if (!(blob.str in references))
                    {
                        if (references.length >= policy.maxReferences)
                            throw new Exception("Attachment reference budget exceeded");
                        references[blob.str] = true;
                    }
                }
            foreach (child; value.object) mark(child);
        }
    }
    void markJson(string text)
    {
        auto value = parseJSON(text);
        if (value.type != JSONType.object && value.type != JSONType.array)
            throw new Exception("Invalid attachment reference source");
        mark(value); checkBudget();
    }
    void scan(string path, bool journal)
    {
        checkBudget();
        if (++files > policy.maxFiles || isSymlink(path))
            throw new Exception("Attachment source enumeration is incomplete");
        auto file = File(path, "rb");
        auto text = appender!string();
        ubyte[64 * 1024] buffer;
        while (true)
        {
            const chunk = file.rawRead(buffer[]);
            if (!chunk.length) break;
            if (chunk.length > policy.maxReferenceBytes - bytes)
                throw new Exception("Attachment source byte budget exceeded");
            bytes += chunk.length;
            if (journal)
            {
                size_t start;
                foreach (i, ch; chunk)
                {
                    if (ch != '\n') continue;
                    if (text.data.length + i - start > policy.maxJournalLineBytes)
                        throw new Exception("Attachment journal record budget exceeded");
                    text.put(cast(char[]) chunk[start .. i]);
                    if (text.data.strip.length) markJson(text.data);
                    text = appender!string(); start = i + 1;
                }
                if (text.data.length + chunk.length - start > policy.maxJournalLineBytes)
                    throw new Exception("Attachment journal record budget exceeded");
                text.put(cast(char[]) chunk[start .. $]);
            }
            else
            {
                if (text.data.length + chunk.length > policy.maxJsonBytes)
                    throw new Exception("Attachment snapshot byte budget exceeded");
                text.put(cast(char[]) chunk);
            }
            checkBudget();
        }
        if (journal)
        {
            // A nonterminated tail may still be an in-flight journal append.
            if (text.data.strip.length)
                throw new Exception("Attachment journal append is incomplete");
        }
        else markJson(text.data);
    }
    try
    {
        if (!exists(store.directory) || !store.collectionAllowed()) return result;
        if (isSymlink(store.directory))
            throw new Exception("Attachment directory redirects collection");
        foreach (entry; dirEntries(directory, SpanMode.shallow))
        {
            const name = baseName(entry.name);
            if (!entry.isFile) continue;
            if ((name.startsWith("sessions") || name.startsWith("threads.index")) && name.indexOf(".json") >= 0)
                scan(entry.name, false);
            else if (name.startsWith("runtime-events.jsonl")) scan(entry.name, true);
        }
        const threads = buildPath(directory, "threads");
        if (exists(threads))
        {
            if (isSymlink(threads)) throw new Exception("Attachment history directory redirects collection");
            foreach (entry; dirEntries(threads, SpanMode.shallow))
                if (entry.isFile && baseName(entry.name).indexOf(".json") >= 0) scan(entry.name, false);
        }
        checkBudget(); result.marked = true;
        const cutoff = Clock.currTime - policy.minimumAgeHours.hours;
        size_t candidates;
        foreach (entry; dirEntries(store.directory, SpanMode.shallow))
        {
            checkBudget();
            if (++candidates > policy.maxFiles || result.deleted >= policy.maxDeletes) break;
            const name = baseName(entry.name);
            if (!entry.isFile || entry.isSymlink || !name.endsWith(".b64")) continue;
            const digest = name[0 .. $ - 4];
            if (!validAttachmentDigest(digest) || digest in references || entry.timeLastModified > cutoff) continue;
            const size = entry.size;
            if (store.removeUnpinned(digest)) { ++result.deleted; result.reclaimedBytes += size; }
        }
    }
    catch (Exception error) { result.error = error.msg; }
    return result;
}

private __gshared Mutex maintenanceMutex;
private __gshared MonoTime[string] lastCollection;
shared static this() { maintenanceMutex = new Mutex(); }

/// Invoked by the snapshot owner after a successful store write, never by the
/// window thread. Cleanup failure is maintenance-only and cannot fail a save.
public void collectAttachmentGarbageIfDue(string directory)
{
    synchronized (maintenanceMutex)
    {
        if (auto last = directory in lastCollection)
            if (MonoTime.currTime - *last < 1.hours) return;
        lastCollection[directory] = MonoTime.currTime;
    }
    const result = collectAttachmentGarbage(directory);
    if (result.deleted)
        logInfo("Attachment maintenance reclaimed " ~ to!string(result.reclaimedBytes) ~
            " bytes in " ~ to!string(result.deleted) ~ " unreferenced blobs");
    if (result.error.length) logInfo("Attachment maintenance deferred: " ~ result.error);
}
