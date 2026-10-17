module auroraopencode.taskpolicy;

import auroraopencode.core : ChatSession, activeMessagePath;
import auroraopencode.checkout : canonicalPath, checkoutIdentity;
import std.algorithm : canFind;
import std.file : exists, isDir;
import std.path : buildPath, dirName, isAbsolute;
import std.regex : matchAll;
import std.string : strip, toLower, startsWith, split, join;
import auroraopencode.taskflow : taskMessagePath;
import auroraopencode.requestintent : answerOnlyRequest, requestIntent, RequestIntent;

/// Only real user messages can retarget a task. Tool output, summaries and
/// restart reasons cannot change the checkout that owns its effects/evidence.
string taskWorkspace(const ref ChatSession session, string projectWorkspace)
{
    // Widget reconstruction asks for the same scope many times. Cache the
    // durable branch tip before walking a long transcript, not after it.
    static string[string] byLeaf;
    string leafKey;
    if (session.id.length && session.activeLeafId.length)
    {
        import std.conv : to;
        leafKey = session.id ~ "\n" ~ projectWorkspace ~ "\n" ~ session.activeLeafId ~
            "\n" ~ to!string(session.messages.length);
        if (auto cached = leafKey in byLeaf) return *cached;
    }
    void remember(string value)
    {
        if (!leafKey.length) return;
        if (byLeaf.length >= 256) byLeaf = null;
        byLeaf[leafKey] = value;
    }
    const path = activeMessagePath(session);
    string latest;
    foreach_reverse (index; path)
        if (session.messages[index].role == "user" && !session.messages[index].internal)
        {
            latest = session.messages[index].id ~ "\n" ~ session.messages[index].content;
            break;
        }
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;
    static string[string] resolved;
    const cacheKey = sha256Of(session.id ~ "\n" ~ projectWorkspace ~ "\n" ~ latest).toHexString().idup;
    if (auto cached = cacheKey in resolved) { remember(*cached); return *cached; }
    string selected;
    foreach (index; path)
    {
        const message = session.messages[index];
        if (message.role != "user" || message.internal) continue;
        if (answerOnlyRequest(message.content) ||
            (session.contract.intent != "analysis" && requestIntent(message.content) == RequestIntent.analysis)) continue;
        string messageRoot;
        bool ambiguous;
        foreach (match; matchAll(message.content, `(?<![:/A-Za-z0-9])(?:[A-Za-z]:[\\/]|/(?!/))(?:(?![A-Za-z]:[\\/]|[ \t]+/(?!/))[^\r\n<>"` ~ "`" ~ `])+`))
        {
            auto candidate = match.hit.strip();
            // Find the longest existing prefix, preserving spaces in paths.
            // A drive/root alone is never enough to infer a task checkout.
            while (candidate.length > 3)
            {
                while (candidate.length && canFind(" .,:;)'", candidate[$ - 1]))
                    candidate = candidate[0 .. $ - 1];
                try
                {
                    if (isAbsolute(candidate) && exists(candidate))
                    {
                        const root = checkoutIdentity(candidate);
                        if (exists(buildPath(root, ".git")))
                        {
                            if (messageRoot.length && messageRoot != root) ambiguous = true;
                            messageRoot = root;
                        }
                        break;
                    }
                }
                catch (Exception) {}
                size_t cut = candidate.length;
                while (cut && !canFind(" \t,;)", candidate[cut - 1])) --cut;
                if (!cut) break;
                candidate = candidate[0 .. cut - 1].strip();
            }
        }
        if (!ambiguous && messageRoot.length) selected = messageRoot;
    }
    if (selected.length)
    {
        if (resolved.length >= 256) resolved = null;
        resolved[cacheKey] = selected;
    }
    const result = selected.length ? selected : projectWorkspace;
    remember(result);
    return result;
}

bool sameCheckout(string first, string second)
{
    return first.length && second.length && checkoutIdentity(first) == checkoutIdentity(second);
}

/// Compilation outside the checkout can still compile its source. Attribute
/// it only when the actual inputs/include roots name the task checkout.
string checkWorkspace(string program, const(string)[] args, string workdir, string workspace)
{
    if (sameCheckout(workdir, workspace)) return workspace;
    import std.path : baseName, stripExtension, absolutePath;
    const name = stripExtension(baseName(program)).toLower();
    if (name != "dmd" && name != "ldc2" && name != "gdc") return "";
    foreach (arg; args)
    {
        string input;
        if (arg.startsWith("-I") && arg.length > 2) input = arg[2 .. $];
        else if (arg.length > 2 && arg[$ - 2 .. $] == ".d") input = arg;
        if (input.length && sameCheckout(absolutePath(input, workdir), workspace))
            return workspace;
    }
    return "";
}

string[] requiredEvidence(const ref ChatSession session)
{
    string request = session.contract.requestedOutcome.length ? session.contract.requestedOutcome : session.objective;
    foreach (index; taskMessagePath(session))
        if (session.messages[index].role == "user" && !session.messages[index].internal &&
            !answerOnlyRequest(session.messages[index].content) &&
            (session.contract.intent == "analysis" || requestIntent(session.messages[index].content) != RequestIntent.analysis))
            request ~= "\n" ~ session.messages[index].content;
    request = request.toLower();
    const visual = request.canFind("render") || request.canFind("layout") ||
        request.canFind("screenshot") || request.canFind("visual correctness");
    string[] result;
    if (visual) result = ["compile", "tests", "render"];
    if (visual && request.canFind("interact"))
        result ~= "interaction";
    return result;
}

bool satisfiesEvidence(string check, const(string)[] required)
{
    if (!check.length) return false;
    if (!required.length) return true;
    if (!check.startsWith("verify:")) return false;
    const supplied = check[7 .. $].split(",");
    foreach (kind; required) if (!supplied.canFind(kind)) return false;
    return true;
}

string verificationScope(string workspace, ulong revision)
{
    import core.time : MonoTime;
    import std.process : thisProcessID;
    import std.conv : to;
    static string epoch;
    if (!epoch.length) epoch = to!string(thisProcessID()) ~ ":" ~ to!string(MonoTime.currTime.ticks);
    return checkoutIdentity(workspace) ~ "|" ~ epoch ~ "|" ~ to!string(revision);
}

string verificationCoverage(const ref ChatSession session, string extraCheck = "")
{
    string[] kinds;
    void add(string check)
    {
        string[] supplied;
        if (check.startsWith("verify:")) supplied = check[7 .. $].split(",");
        else if (check.canFind("compile") || check.canFind("build") || check == "cargo check") supplied = ["compile"];
        else if (check.canFind("test")) supplied = ["tests"];
        foreach (kind; supplied) if (kind.length && !kinds.canFind(kind)) kinds ~= kind;
    }
    foreach (index; taskMessagePath(session))
    {
        const ref message = session.messages[index];
        if (!session.verificationScope.length || message.verificationScope != session.verificationScope) continue;
        if (!message.verificationCheck.length) kinds = null; // A rejected checker supersedes earlier receipts.
        else if (!message.failed) add(message.verificationCheck);
    }
    if (extraCheck.length) add(extraCheck);
    return "verify:" ~ kinds.join(",");
}

bool diagnosticToolAllowed(string name)
{
    return ["read", "grep", "glob", "view_image", "checksum", "tool_status"].canFind(name);
}

/// The primary rebuild owner gets its reason/diagnostics. Other chats resume
/// their own work, with no instructions copied from the owning conversation.
string scopedResumePrompt(string ownerPrompt, bool ownsRebuild)
{
    return ownsRebuild ? ownerPrompt :
        "Aurora restarted while this conversation was working. Resume this " ~
        "conversation's own durable objective, checklist and recorded evidence. " ~
        "Another conversation's rebuild does not change this task or verify its " ~
        "outputs. Apply only this conversation's queued guidance.";
}

int workingContextBudget(int selected, bool toolsEnabled, int toolRounds)
{
    if (!toolsEnabled || toolRounds < 32 || selected <= 0) return selected;
    import std.process : environment;
    import std.conv : to;
    int target = 128_000;
    try
    {
        const configured = environment.get("AURORA_WORKING_CONTEXT_TOKENS", "");
        if (configured.length)
        {
            const value = to!int(configured);
            if (value == 0) return selected;
            if (value >= 16_000) target = value;
        }
    }
    catch (Exception) {}
    return selected < target ? selected : target;
}
