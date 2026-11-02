module auroraopencode.conversationimages;

import auroraopencode.core : ChatSession, ChatMessage, ChatImageAttachment, activeMessagePath;
import auroraopencode.attachmentstore : AttachmentStore;
import auroraopencode.effectfacts : effectFact;
import auroraopencode.imagehistory : requestHistoryImageIndices;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.string : startsWith;

public struct ConversationImageStats
{
    size_t sizeReads, blobReads, selectedImages, selectedBytes;
}

/// Execution-owned image effects. View snapshots retain references; only the
/// bounded request window is hydrated. Every observation is replayable offline.
public final class ConversationImages
{
    private AttachmentStore store;
    private bool[string] archived;
    public ConversationImageStats lastRequest;

    this(string directory) { store = AttachmentStore(directory); }

    void archive(ref ChatMessage message)
    {
        foreach (ref image; message.images)
        {
            if (!image.base64Data.length) continue;
            const digest = sha256Of(image.base64Data).toHexString().idup;
            if (digest !in archived)
            {
                const data = image.base64Data;
                const recorded = effectFact("image.archive." ~ digest, () => store.put(data));
                if (recorded != digest) throw new Exception("Recorded attachment digest does not match its pixels");
                if (archived.length < 256) archived[digest] = true;
            }
            image.blob = digest;
        }
    }

    void archive(ref ChatSession session)
    {
        foreach (ref message; session.messages) archive(message);
        foreach (contexts; [session.queuedGuidanceContext, session.queuedFollowUpContext])
            foreach (ref context; contexts)
            {
                ChatMessage message; message.images = context.images; archive(message);
            }
    }

    bool prepare(ref ChatSession session, size_t imageLimit)
    {
        lastRequest = ConversationImageStats.init;
        string[string] errors, payloads;
        size_t[string] lengths;
        size_t length(const ref ChatImageAttachment image)
        {
            if (image.base64Data.length) return image.base64Data.length;
            if (!image.blob.length) return 0;
            if (auto found = image.blob in lengths) return *found;
            const digest = image.blob;
            const fact = effectFact("image.size." ~ digest, delegate() {
                ++lastRequest.sizeReads;
                try return to!string(store.byteLength(digest));
                catch (Exception error) return "error:" ~ error.msg;
            });
            size_t bytes;
            if (fact.startsWith("error:")) errors[digest] = fact[6 .. $];
            else bytes = to!size_t(fact);
            lengths[digest] = bytes; return bytes;
        }
        const path = activeMessagePath(session);
        const selected = requestHistoryImageIndices(session, path, 0, imageLimit, &length);
        bool[size_t][size_t] keep;
        bool changed;
        foreach (slot, indices; selected)
            foreach (i; indices)
            {
                auto image = &session.messages[path[slot]].images[i];
                if (!image.base64Data.length)
                {
                    const digest = image.blob;
                    string fact;
                    if (auto cached = digest in payloads) fact = *cached;
                    else
                    {
                        fact = effectFact("image.load." ~ digest, delegate() {
                            ++lastRequest.blobReads;
                            try return "ok:" ~ store.get(digest);
                            catch (Exception error) return "error:" ~ error.msg;
                        });
                        payloads[digest] = fact;
                    }
                    if (fact.startsWith("error:"))
                    { errors[digest] = fact[6 .. $]; continue; }
                    const data = fact[3 .. $];
                    if (data.length != lengths[digest])
                    { errors[digest] = "Attachment changed while preparing the request"; continue; }
                    image.base64Data = data; image.error = ""; changed = true;
                }
                keep[path[slot]][i] = true;
                ++lastRequest.selectedImages; lastRequest.selectedBytes += image.base64Data.length;
            }
        foreach (index, ref message; session.messages)
            foreach (i, ref image; message.images)
            {
                if (auto error = image.blob in errors)
                    if (image.error != *error) { image.error = *error; changed = true; }
                const row = index in keep;
                if ((row is null || i !in *row) && image.blob.length && image.base64Data.length)
                { image.base64Data = ""; changed = true; }
            }
        return changed;
    }
}
