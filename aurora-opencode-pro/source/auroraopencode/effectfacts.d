module auroraopencode.effectfacts;

import std.json : JSONValue, JSONType;

/// A frame records external observations once. Replay must supply every fact;
/// it never silently falls back to a different filesystem or environment.
public final class EffectFacts
{
    private string[string] values;
    private bool replay;
    private size_t bytes;
    public bool complete = true;
    private enum byteBudget = 4 * 1024 * 1024;
    private enum entryBudget = 256;
    this() {}
    this(JSONValue recorded)
    {
        replay = true;
        if (recorded.type != JSONType.object) throw new Exception("Invalid recorded effect facts");
        foreach (key, value; recorded.object)
        {
            if (value.type != JSONType.string) throw new Exception("Invalid recorded effect fact");
            bytes += key.length + value.str.length;
            if (bytes > byteBudget || values.length >= entryBudget)
                throw new Exception("Recorded effect facts exceed the frame budget");
            values[key] = value.str;
        }
    }
    string observe(string key, string delegate() read)
    {
        if (auto value = key in values) return *value;
        if (replay) throw new Exception("Replay is missing an external observation: " ~ key);
        const value = read();
        const cost = key.length + value.length;
        if (values.length >= entryBudget || cost > byteBudget - bytes)
        { complete = false; return value; }
        bytes += cost; values[key] = value; return value;
    }
    JSONValue toJson() const
    {
        auto result = JSONValue.emptyObject;
        foreach (key, value; values) result[key] = value;
        return result;
    }
}

private EffectFacts activeFacts;
public EffectFacts installEffectFacts(EffectFacts facts)
{ auto previous = activeFacts; activeFacts = facts; return previous; }
public string effectFact(string key, string delegate() read)
{ return activeFacts is null ? read() : activeFacts.observe(key, read); }
public bool effectFactBool(string key, bool delegate() read)
{ return effectFact(key, () => read() ? "1" : "0") == "1"; }
