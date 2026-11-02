module auroraopencode.conversationmetadata;

import std.json : JSONValue, JSONType;

public struct MetadataUpdate { JSONValue value; bool complete; }

/// Top-level replacement patches keep unchanged histories, archives and queues
/// out of ordinary deliveries. Explicit defaults clear removed optional fields.
public final class MetadataDelta
{
    private JSONValue previous;
    private bool initialized;

    MetadataUpdate update(JSONValue full)
    {
        if (!initialized)
        { previous = full; initialized = true; return MetadataUpdate(full, true); }
        auto patch = JSONValue.emptyObject;
        foreach (key, value; full.object)
            if (auto old = key in previous.object)
            { if (*old != value) patch[key] = value; }
            else patch[key] = value;
        foreach (key, value; previous.object)
            if (!(key in full.object)) patch[key] = clearedValue(key, value);
        if (auto id = "id" in full.object) patch["id"] = *id;
        previous = full; return MetadataUpdate(patch, false);
    }

    void reset(JSONValue full)
    {
        // The caller may add a message graph to a snapshot after this reset.
        previous = JSONValue.emptyObject;
        foreach (key, value; full.object) previous[key] = value;
        initialized = true;
    }
    void clear() { previous = JSONValue.init; initialized = false; }
}

private JSONValue clearedValue(string key, const ref JSONValue previous)
{
    final switch (previous.type)
    {
        case JSONType.string: return JSONValue("");
        case JSONType.array: return JSONValue.emptyArray;
        case JSONType.object: return JSONValue.emptyObject;
        case JSONType.true_:
        case JSONType.false_: return JSONValue(false);
        case JSONType.integer:
        case JSONType.uinteger: return JSONValue(cast(long) (key == "toolsMode" ? -1 : 0));
        case JSONType.float_: return JSONValue(0.0);
        case JSONType.null_: return JSONValue.init;
    }
}
