module auroraopencode.numericalclaims;

import auroraopencode.core : ChatSession, activeMessagePath;
import auroraopencode.numericalgrounding : numericalCodeRequest;
import std.algorithm : canFind;
import std.conv : to;
import std.json : JSONValue, JSONType, parseJSON;
import std.regex : matchFirst, matchAll;
import std.string : indexOf, strip;

// Exact decimal identity, including exponent notation, without float tolerance.
private string decimalIdentity(string value)
{
    const match = matchFirst(value.strip(), `^([+-]?)([0-9]*)(?:\.([0-9]*))?(?:[eE]([+-]?[0-9]+))?$`);
    if (!match.length || (!match[2].length && !match[3].length)) return "";
    auto digits = match[2] ~ match[3];
    while (digits.length && digits[0] == '0') digits = digits[1 .. $];
    if (!digits.length) return "0";
    long exponent;
    try { if (match[4].length) exponent = to!long(match[4]); }
    catch (Exception) { return value.strip(); }
    if (exponent > 1_000_000 || exponent < -1_000_000) return value.strip();
    exponent -= cast(long)match[3].length;
    while (digits.length && digits[$ - 1] == '0') { digits = digits[0 .. $ - 1]; ++exponent; }
    return (match[1] == "-" ? "-" : "") ~ digits ~ "e" ~ to!string(exponent);
}

private void numericValues(JSONValue value, ref string[] result)
{
    if (value.type == JSONType.object) foreach (key, child; value.object) numericValues(child, result);
    else if (value.type == JSONType.array) foreach (child; value.array) numericValues(child, result);
    else if (value.type == JSONType.string)
    { if (decimalIdentity(value.str).length) result ~= value.str; }
    else if (value.type == JSONType.integer || value.type == JSONType.uinteger)
        result ~= value.toString();
}

/// Decimal-string and integer JSON answers must not introduce an uncalculated
/// expected value after observing the current code. Floating JSON numbers stay
/// outside this exact-decimal check rather than using a float tolerance.
/// No proof is inferred from arguments,
/// source literals, failed execution or receipt metadata.
string unobservedNumericalClaim(const ref ChatSession session)
{
    const path = activeMessagePath(session);
    size_t begin;
    string request;
    foreach (i, index; path)
        if (session.messages[index].role == "user" && !session.messages[index].internal)
        { begin = i + 1; request = session.messages[index].content; }
    if (!numericalCodeRequest(request)) return "";
    string[] claims;
    foreach_reverse (index; path[begin .. $])
    {
        const ref message = session.messages[index];
        if (message.role == "tool") break;
        if (message.role != "assistant" || message.internal || message.toolCalls.length) continue;
        try { numericValues(parseJSON(message.content), claims); }
        catch (Exception) {}
        break;
    }
    if (!claims.length) return "";
    string[] observed;
    bool executionAvailable;
    void outputs(string output)
    {
        foreach (match; matchAll(output, `(?<![\w.])[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?(?![\w.])`))
        {
            const identity = decimalIdentity(match.hit);
            if (identity.length) observed ~= identity;
        }
    }
    foreach (index; path[begin .. $])
    {
        const ref message = session.messages[index];
        if (message.role != "tool" || message.failed) continue;
        try
        {
            if (message.toolName == "run")
            {
                executionAvailable = true;
                const receipt = message.content.indexOf("\nVerification receipt:");
                outputs(receipt < 0 ? message.content : message.content[0 .. receipt]);
            }
            else if (message.toolName == "verify")
            {
                foreach (step; parseJSON(message.content)["steps"].array) outputs(step["output"].str);
                executionAvailable = true;
            }
            else if (message.toolName == "calculate")
            {
                // Keep the native calculator's decimal serialization; parsing
                // and reserializing its binary float can add spurious digits.
                const report = parseJSON(message.content);
                if (report["results"].type == JSONType.array)
                    foreach (match; matchAll(message.content,
                        `"value"\s*:\s*([+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)`)) outputs(match[1]);
            }
        }
        catch (Exception) {}
    }
    if (!executionAvailable) return ""; // Preserve the execution-unavailable reporting path.
    foreach (claim; claims) if (!observed.canFind(decimalIdentity(claim))) return claim;
    return "";
}
