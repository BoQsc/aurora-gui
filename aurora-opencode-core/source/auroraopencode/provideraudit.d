module auroraopencode.provideraudit;

import auroraopencode.logging : logInfo;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : toLower, startsWith, replace;
import std.process : environment;
import std.conv : to;

/// Opt-in, bounded wire evidence. Headers are never recorded. Inline media and
/// credentials are removed; text is retained to distinguish content/tool channels.
public class ProviderAudit
{
    private ulong requestId;
    private string model, credential;
    private bool enabled;
    private size_t remaining = 128 * 1024;
    private bool truncated;
    this(ulong id, string selectedModel, string apiKey)
    {
        requestId = id;
        model = selectedModel;
        credential = apiKey;
        enabled = environment.get("AURORA_PROVIDER_TRACE", "") == "1";
    }
    void record(string kind, string payload)
    {
        if (!enabled || remaining == 0) return;
        const safe = redactProviderPayload(payload, credential);
        const line = "provider-wire request=" ~ to!string(requestId) ~
            " model=" ~ model ~ " kind=" ~ kind ~ " " ~ safe;
        if (line.length > remaining)
        {
            remaining = 0;
            if (!truncated)
                logInfo("provider-wire request=" ~ to!string(requestId) ~
                    " trace truncated at 128 KiB");
            truncated = true;
            return;
        }
        remaining -= line.length;
        logInfo(line);
    }
}

private void scrub(ref JSONValue value, string credential)
{
    if (value.type == JSONType.object)
    {
        foreach (key, ref child; value.object)
        {
            const lower = key.toLower();
            if (lower == "authorization" || lower == "api_key" ||
                lower == "apikey" || lower == "api-key" ||
                lower == "x-api-key" || lower == "password" ||
                lower == "token" || lower == "client_secret" ||
                lower == "secret" || lower == "access_token" ||
                lower == "refresh_token") child = JSONValue("[redacted]");
            else scrub(child, credential);
        }
    }
    else if (value.type == JSONType.array)
        foreach (ref child; value.array) scrub(child, credential);
    else if (value.type == JSONType.string)
    {
        auto text = value.str;
        if (text.startsWith("data:")) text = "[inline media omitted]";
        else
        {
            if (credential.length > 0) text = text.replace(credential, "[redacted]");
            // Tool arguments are JSON encoded inside a string on the wire.
            if (text.startsWith("{") || text.startsWith("["))
                try
                {
                    auto nested = parseJSON(text);
                    scrub(nested, credential);
                    text = nested.toString();
                }
                catch (Exception) {}
            if (text.length > 2048)
            {
                size_t end = 2048;
                while (end > 0 && (cast(ubyte) text[end] & 0xc0) == 0x80) --end;
                text = text[0 .. end] ~ " [text truncated]";
            }
        }
        value = JSONValue(text);
    }
}

public string redactProviderPayload(string payload, string credential = "")
{
    try
    {
        auto value = parseJSON(payload);
        scrub(value, credential);
        return value.toString();
    }
    catch (Exception)
        return "[non-JSON payload omitted]";
}
