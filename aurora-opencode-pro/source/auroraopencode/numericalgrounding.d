module auroraopencode.numericalgrounding;

import auroraopencode.core : ChatSession, ChatMessage, activeMessagePath;
import auroraopencode.requestintent : requestIntent, RequestIntent;
import std.algorithm : canFind;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : baseName;
import std.regex : matchFirst, matchAll;
import std.string : toLower, indexOf, startsWith, split, strip, join;

bool numericalCodeRequest(string request)
{
    const text = request.toLower();
    if (text.indexOf(".py") < 0 || !matchFirst(text,
        `\bindependently\s+(?:calculate|compute|evaluate)\b|\b(?:calculate|compute)\s+(?:the\s+)?(?:current|actual)\b`)) return false;
    if (text.indexOf("http://") >= 0 || text.indexOf("https://") >= 0) return false;
    foreach (restriction; ["without running", "without executing", "do not run", "don't run",
            "do not execute", "don't execute", "no execution", "no code execution", "static analysis only"])
        if (text.indexOf(restriction) >= 0) return false;
    const intent = requestIntent(request);
    if (intent != RequestIntent.analysis && intent != RequestIntent.clarification) return false;
    return cast(bool) matchFirst(text, `\b[A-Za-z_]\w*\.py\b`);
}

enum numericalGroundingInstruction =
    "Execute a safe read-only probe of the existing referenced Python implementation with the stated inputs before reporting its current numerical result. " ~
    "Compute the required result separately from the original rule; do not substitute the intended behavior for what the current code returns. " ~
    "Use python -B or an equivalent cache-free invocation. No file changes or verification recipe are required. " ~
    "Batch independent calculations in that probe where practical. Once its output agrees with the inspected implementation and stated inputs, " ~
    "use the observed result; do not repeat the probe, inventory, import-path inspection or disassembly merely for confidence. " ~
    "A concrete contradiction, changed input or changed source justifies further investigation. " ~
    "If execution is unavailable, report that limitation accurately and distinguish source-based reasoning from an observed result.";

private bool callsModule(string source, string moduleName)
{
    auto imported = matchFirst(source, `\bimport\s+[^;\n]*\b` ~ moduleName ~ `\b(?:\s+as\s+([A-Za-z_]\w*))?`);
    if (imported.length)
    {
        const name = imported[1].length ? imported[1] : moduleName;
        if (matchFirst(source, `\b` ~ name ~ `\.[A-Za-z_]\w*\s*\(`)) return true;
    }
    auto from = matchFirst(source, `\bfrom\s+(?:[A-Za-z_]\w*\.)*` ~ moduleName ~ `\s+import\s+([^;\n]+)`);
    if (from.length)
        foreach (item; from[1].split(','))
        {
            auto binding = matchFirst(item.strip(), `^([A-Za-z_]\w*)(?:\s+as\s+([A-Za-z_]\w*))?`);
            if (!binding.length) continue;
            const name = binding[2].length ? binding[2] : binding[1];
            if (matchFirst(source, `\b` ~ name ~ `\s*\(`)) return true;
        }
    return false;
}

private bool runsModule(JSONValue command, string moduleName, string output)
{
    try
    {
        if (!matchFirst(baseName(command["program"].str).toLower(), `^(?:py|python(?:3(?:\.\d+)*)?)(?:\.exe)?$`)) return false;
        string[] args;
        foreach (argument; command["args"].array) args ~= argument.str;
        foreach (i, arg; args)
        {
            if (arg == "-c" && i + 1 < args.length)
            {
                const source = args[i + 1];
                if (callsModule(source, moduleName) || (source.indexOf(moduleName ~ ".py") >= 0 &&
                    matchFirst(source, `\b(?:exec|eval|compile)\s*\(`))) return true;
            }
            if (baseName(arg).toLower() == (moduleName ~ ".py").toLower()) return true;
        }
        const invocation = args.join(" ");
        return (invocation.indexOf("unittest") >= 0 || invocation.indexOf("pytest") >= 0) &&
            (invocation.indexOf(moduleName) >= 0 || output.indexOf(moduleName) >= 0);
    }
    catch (Exception) { return false; }
}

bool numericalProbeMissing(const ref ChatSession session)
{
    const path = activeMessagePath(session);
    string request;
    size_t begin;
    foreach (i, index; path)
        if (session.messages[index].role == "user" && !session.messages[index].internal)
        { request = session.messages[index].content; begin = i + 1; }
    if (!numericalCodeRequest(request)) return false;
    string[] modules;
    foreach (match; matchAll(request, `(?i)\b([A-Za-z_]\w*)\.py\b`))
        if (!modules.canFind(match[1])) modules ~= match[1];
    if (!modules.length) return false;
    foreach (index; path[begin .. $])
    {
        const ref message = session.messages[index];
        if (message.role != "tool" || !["run", "verify"].canFind(message.toolName) ||
            message.content.startsWith("Error:")) continue;
        try
        {
            const args = parseJSON(message.toolArgs);
            if (message.toolName == "run")
            {
                foreach (name; modules) if (runsModule(args, name, message.content)) return false;
            }
            else
            {
                const report = parseJSON(message.content);
                foreach (step; report["steps"].array)
                    foreach (name; modules)
                        if (runsModule(step["command"], name, step["output"].str)) return false;
            }
        }
        catch (Exception) {}
    }
    return true;
}
