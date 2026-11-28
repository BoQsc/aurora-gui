module auroraopencode.numericalclaims;

import auroraopencode.core : ChatSession, activeMessagePath;
import auroraopencode.numericalgrounding : numericalCodeRequest;
import std.algorithm : canFind;
import std.conv : to;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : baseName;
import std.regex : matchFirst, matchAll;
import std.string : indexOf, strip, splitLines, toLower;

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

private struct NumericalClaim { string value; bool assertionFact; }

private void numericValues(JSONValue value, ref NumericalClaim[] result, string field = "")
{
    const fact = ["test_expected", "test_expectation", "assertion_expected", "assertion_expectation"].canFind(field.toLower());
    if (value.type == JSONType.object) foreach (key, child; value.object) numericValues(child, result, key);
    else if (value.type == JSONType.array) foreach (child; value.array) numericValues(child, result, field);
    else if (value.type == JSONType.string)
    { if (decimalIdentity(value.str).length) result ~= NumericalClaim(value.str, fact); }
    else if (value.type == JSONType.integer || value.type == JSONType.uinteger)
        result ~= NumericalClaim(value.toString(), fact);
}

// Only a literal expected argument of a real assertion supplies a source fact.
// Mask comments/strings first; numbers in inputs, examples and read metadata do
// not become evidence. This deliberately does not evaluate arbitrary Python.
private string[] assertionExpectations(string output)
{
    string source;
    foreach (line; output.splitLines())
    {
        const numbered = matchFirst(line, `^\d+: (.*)$`);
        if (numbered.length) source ~= numbered[1] ~ "\n";
    }
    auto code = source.dup;
    for (size_t i; i < code.length;)
    {
        if (code[i] == '#')
        { while (i < code.length && code[i] != '\n') code[i++] = ' '; continue; }
        if (code[i] != '\'' && code[i] != '"') { ++i; continue; }
        const quote = code[i];
        const width = i + 2 < code.length && code[i + 1] == quote && code[i + 2] == quote ? 3 : 1;
        foreach (_; 0 .. width) code[i++] = ' ';
        while (i < code.length)
        {
            if (code[i] == '\\')
            { code[i++] = ' '; if (i < code.length) code[i++] = ' '; continue; }
            if (code[i] == quote && (width == 1 ||
                (i + 2 < code.length && code[i + 1] == quote && code[i + 2] == quote)))
            { foreach (_; 0 .. width) code[i++] = ' '; break; }
            if (code[i] != '\n') code[i] = ' ';
            ++i;
        }
    }
    string[] result;
    foreach (line; (cast(string)code).splitLines())
    {
        const call = matchFirst(line, `^\s*(?:def\s+test\w*\s*\([^)]*\)\s*:\s*)?self\.assert(?:Equal|AlmostEqual|NotEqual)\s*\(`);
        if (!call.length) continue;
        const args = line[call[0].length .. $];
        int depth;
        size_t begin;
        string[] values;
        foreach (i, c; args)
        {
            if ((c == ',' || c == ')') && depth == 0)
            { values ~= args[begin .. i].strip(); begin = i + 1; if (c == ')' || values.length == 2) break; }
            else if (c == '(' || c == '[' || c == '{') ++depth;
            else if (c == ')' || c == ']' || c == '}') --depth;
        }
        if (values.length < 2) continue;
        auto expected = decimalIdentity(values[1]);
        if (!expected.length) expected = decimalIdentity(values[0]);
        if (expected.length) result ~= expected;
    }
    return result;
}

/// Decimal-string and integer JSON answers must not introduce an uncalculated
/// expected value after observing the current code. Floating JSON numbers stay
/// outside this exact-decimal check rather than using a float tolerance.
/// Computed values never gain proof from source literals, failed execution or
/// receipt metadata. Explicit assertion-expectation fields may report the
/// observed expected argument of a requested test source.
string unobservedNumericalClaim(const ref ChatSession session)
{
    const path = activeMessagePath(session);
    size_t begin;
    string request;
    foreach (i, index; path)
        if (session.messages[index].role == "user" && !session.messages[index].internal)
        { begin = i + 1; request = session.messages[index].content; }
    if (!numericalCodeRequest(request)) return "";
    NumericalClaim[] claims;
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
    string[][string] assertionFacts;
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
        if (message.role != "tool") continue;
        // Source facts belong to the current observed workspace snapshot.
        if (message.workspaceChanged || ["write", "edit", "apply_patch", "remove"].canFind(message.toolName))
            assertionFacts = null;
        try
        {
            if (message.toolName == "read")
            {
                const file = parseJSON(message.toolArgs)["filePath"].str;
                const name = baseName(file).toLower();
                assertionFacts.remove(file);
                if (!message.failed && name.length > 3 && name[$-3 .. $] == ".py" && request.toLower().indexOf(name) >= 0)
                    assertionFacts[file] = assertionExpectations(message.content);
            }
            if (message.failed) continue;
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
    foreach (claim; claims)
    {
        const identity = decimalIdentity(claim.value);
        if (observed.canFind(identity)) continue;
        bool sourced;
        if (claim.assertionFact)
            foreach (facts; assertionFacts) if (facts.canFind(identity)) { sourced = true; break; }
        if (!sourced) return claim.value;
    }
    return "";
}
