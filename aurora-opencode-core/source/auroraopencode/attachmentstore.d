module auroraopencode.attachmentstore;

import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.file : exists, mkdirRecurse, readText, rename, remove;
import std.json : JSONValue, JSONType;
import std.path : buildPath;
import std.stdio : File;
import auroraopencode.logging : logError;

/// Content-addressed immutable attachment data. References are committed only
/// after their blob exists. Legacy inline image records remain readable.
public struct AttachmentStore
{
    string directory;

    string put(string data)
    {
        const digest = sha256Of(data).toHexString().idup;
        const target = buildPath(directory, digest ~ ".b64");
        if (exists(target))
        {
            if (get(digest) != data) throw new Exception("Attachment content mismatch");
            return digest;
        }
        mkdirRecurse(directory);
        const temporary = target ~ ".tmp";
        auto file = File(temporary, "wb");
        file.write(data);
        file.flush();
        file.close();
        try rename(temporary, target);
        catch (Exception error)
        {
            if (!exists(target)) throw error;
            if (exists(temporary)) remove(temporary);
        }
        return digest;
    }

    string get(string digest)
    {
        if (digest.length != 64) throw new Exception("Invalid attachment reference");
        foreach (ch; digest)
            if (!((ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'F')))
                throw new Exception("Invalid attachment reference");
        const data = readText(buildPath(directory, digest ~ ".b64"));
        if (sha256Of(data).toHexString() != digest)
            throw new Exception("Attachment checksum mismatch");
        return data;
    }

    void externalize(ref JSONValue value)
    {
        if (value.type == JSONType.array)
            foreach (ref child; value.array) externalize(child);
        else if (value.type == JSONType.object)
        {
            if (auto data = "base64Data" in value.object)
                if (data.type == JSONType.string && data.str.length && "mimeType" in value.object)
                {
                    const digest = put(data.str);
                    value.object.remove("base64Data");
                    value["blob"] = digest;
                }
            foreach (ref child; value.object) externalize(child);
        }
    }

    void hydrate(ref JSONValue value)
    {
        if (value.type == JSONType.array)
            foreach (ref child; value.array) hydrate(child);
        else if (value.type == JSONType.object)
        {
            if (auto blob = "blob" in value.object)
                if (blob.type == JSONType.string && "mimeType" in value.object)
                {
                    try value["base64Data"] = get(blob.str);
                    catch (Exception error)
                    {
                        // A damaged image must not discard the surrounding
                        // message or the remainder of a conversation journal.
                        value["attachmentError"] = error.msg;
                        value["base64Data"] = "";
                        logError("Attachment unavailable: " ~ blob.str ~ ": " ~ error.msg);
                    }
                }
            foreach (ref child; value.object) hydrate(child);
        }
    }
}
