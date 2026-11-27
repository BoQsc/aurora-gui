module auroraopencode.checkreconciliation;

import auroraopencode.core : ChatSession, ChatMessage, activeMessagePath;
import auroraopencode.checkout : canonicalPath, checkoutOwnsPath;
import auroraopencode.effectfacts : effectFact, effectFactBool;
import std.algorithm : canFind;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : absolutePath;
import std.string : startsWith, toLower, indexOf, split, strip;
import std.regex : matchFirst;

private string inputPath(string workspace, string path)
{
    return effectFact("check.revision.path\n" ~ workspace ~ "\n" ~ path,
        () => canonicalPath(absolutePath(path, workspace)));
}

private bool inlineCommand(JSONValue command, string userRequest)
{
    try
    {
        if (!["python", "python.exe", "python3", "python3.exe"].canFind(command["program"].str.toLower())) return false;
        const args = command["args"].array;
        foreach (i, argument; args)
            if (argument.type == JSONType.string && argument.str == "-c" && i + 1 < args.length)
            {
                const source = args[i + 1].str;
                if (matchFirst(source, `\b(?:pytest|unittest|runpy)\b|test_[\w./\\-]+\.py|[\w./\\-]+_test\.py|\bexec\s*\(`)) return false;
                foreach (line; source.split('\n')) foreach (statement; line.split(';'))
                    if (statement.strip().startsWith("assert ") && userRequest.indexOf(statement.strip()) >= 0) return false;
                return true;
            }
    }
    catch (Exception) {}
    return false;
}

private bool adHocTests(const ref ChatMessage message, JSONValue arguments, string userRequest)
{
    if (!message.failed || !message.verificationScope.length ||
        message.verificationCheck.indexOf("test") < 0 || "recipe" in arguments.object) return false;
    if (message.toolName == "run") return inlineCommand(arguments, userRequest);
    if (message.toolName != "verify") return false;
    bool tests;
    foreach (step; arguments["steps"].array)
        if (step["kind"].str == "tests")
        {
            if (!inlineCommand(step["command"], userRequest)) return false;
            tests = true;
        }
    return tests;
}

bool revisableAdHocCheck(const ref ChatMessage message, string userRequest)
{
    try { return adHocTests(message, parseJSON(message.toolArgs), userRequest); }
    catch (Exception) { return false; }
}

/// Reconcile an erroneous model-generated inline hypothesis with a current,
/// passing behavioral check. Named tests and saved recipes remain strict.
JSONValue validatedCheckRevisions(const ref ChatSession session, string arguments,
    string workspace, JSONValue report, out string error)
{
    auto accepted = JSONValue.emptyArray;
    try
    {
        const args = parseJSON(arguments);
        const revisions = "check_revisions" in args.object;
        if (revisions is null) return accepted;
        if (revisions.type != JSONType.array || !revisions.array.length || revisions.array.length > 8)
            throw new Exception("check_revisions requires 1..8 corrections.");
        if (report["passed"].type != JSONType.true_) throw new Exception("A revision requires passing replacement checks.");
        bool tests;
        foreach (step; report["steps"].array)
            if (step["kind"].str == "tests" && step["passed"].type == JSONType.true_) tests = true;
        if (!tests) throw new Exception("A revision requires behavioral tests, not compilation alone.");
        string[] inputs;
        foreach (input; report["inputs"].array)
            inputs ~= inputPath(workspace, input.str);
        bool[string] seen;
        string userRequest;
        foreach_reverse (index; activeMessagePath(session))
            if (session.messages[index].role == "user" && !session.messages[index].internal)
            { userRequest = session.messages[index].content; break; }
        foreach (revision; revisions.array)
        {
            const call = revision["failed_call_id"].str;
            const reason = revision["reason"].str;
            if (!call.length || reason.length < 32 || reason.length > 2000 || call in seen)
                throw new Exception("Name each failed_call_id once and explain the incorrect expectation or check logic.");
            seen[call] = true;
            bool found;
            foreach_reverse (index; activeMessagePath(session))
            {
                const ref old = session.messages[index];
                if (old.role == "user" && !old.internal) break;
                if (old.role != "tool" || (old.toolCallId != call && old.id != call)) continue;
                const original = parseJSON(old.toolArgs);
                if (!adHocTests(old, original, userRequest))
                    throw new Exception("Only failed ad hoc inline tests in this request can be revised; rerun named tests and saved recipes.");
                foreach (input; original["inputs"].array)
                {
                    const path = inputPath(workspace, input.str);
                    bool covered;
                    foreach (current; inputs)
                        if (path == current || path.startsWith(current ~ "/") || path.startsWith(current ~ "\\")) covered = true;
                    const owned = effectFactBool("check.revision.owns\n" ~ workspace ~ "\n" ~ path,
                        () => checkoutOwnsPath(workspace, path));
                    if (!owned || !covered)
                        throw new Exception("The replacement must also verify original input: " ~ path);
                }
                found = true; break;
            }
            if (!found) throw new Exception("failed_call_id is not a recorded result in the current request.");
            JSONValue row; row["failed_call_id"] = call; row["reason"] = reason;
            accepted.array ~= row;
        }
    }
    catch (Exception exception) { error = exception.msg; return JSONValue.emptyArray; }
    return accepted;
}

bool recordedCheckRevision(const ref ChatMessage message, string call)
{
    if (message.failed || message.toolName != "verify") return false;
    try
    {
        const report = parseJSON(message.content);
        if (report["receipt"]["acceptedForCurrentSource"].type != JSONType.true_) return false;
        foreach (revision; report["receipt"]["checkRevisionsAccepted"].array)
            if (revision["failed_call_id"].str == call) return true;
    }
    catch (Exception) {}
    return false;
}
