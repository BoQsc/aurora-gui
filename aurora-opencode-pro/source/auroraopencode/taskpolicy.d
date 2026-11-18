module auroraopencode.taskpolicy;
import auroraopencode.effectfacts : effectFact, effectFactBool;

import auroraopencode.core : ChatSession, activeMessagePath;
import auroraopencode.checkout : canonicalPath, checkoutIdentity;
import std.algorithm : canFind;
import std.file : exists, isDir;
import std.path : buildPath, dirName, isAbsolute;
import std.regex : matchAll;
import std.string : strip, toLower, startsWith, split, join;
import auroraopencode.taskflow : taskMessagePath;
import auroraopencode.requestintent : answerOnlyRequest, requestIntent, RequestIntent, reportedFailureRequest, artifactChangeRequested;

/// Only real user messages can retarget a task. Tool output, summaries and
/// restart reasons cannot change the checkout that owns its effects/evidence.
string taskWorkspace(const ref ChatSession session, string projectWorkspace)
{
    return effectFact("task.workspace\n" ~ session.id ~ "\n" ~ session.activeLeafId ~ "\n" ~ projectWorkspace,
        () => observedTaskWorkspace(session, projectWorkspace));
}

private string observedTaskWorkspace(const ref ChatSession session, string projectWorkspace)
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
    string selected = session.contract.workspace;
    foreach (index; path)
    {
        const message = session.messages[index];
        if (message.role != "user" || message.internal) continue;

        string messageRoot, messageWorkspace;
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
                            const current = messageWorkspace.length ? messageWorkspace :
                                selected.length ? selected : projectWorkspace;
                            const base = canonicalPath(current);
                            const target = canonicalPath(candidate);
                            // Checkout identity owns leases and evidence, not the
                            // command working directory. Preserve a configured
                            // subproject and honor an explicitly named folder.
                            if (target == base || target.startsWith(base ~ "/") || target.startsWith(base ~ "\\"))
                                messageWorkspace = current;
                            else if (!messageWorkspace.length)
                                messageWorkspace = isDir(candidate) ? target : root;
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
        if (!ambiguous && messageWorkspace.length) selected = messageWorkspace;
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
    return first.length && second.length && effectFactBool("checkout.same\n" ~ first ~ "\n" ~ second,
        () => checkoutIdentity(first) == checkoutIdentity(second));
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

private string latestTaskRequestForEvidence(const ref ChatSession session)
{
    foreach_reverse (index; taskMessagePath(session))
        if (session.messages[index].role == "user" && !session.messages[index].internal)
            return session.messages[index].content;
    return "";
}

string[] requiredEvidence(const ref ChatSession session)
{
    if (session.contract.intent == "analysis" || session.contract.currentIntent == "analysis") return null;
    const current = latestTaskRequestForEvidence(session);
    const outcome = session.contract.requestedOutcome.length ? session.contract.requestedOutcome : session.objective;
    // Repairs need behavioral evidence. Incidental prose such as "layout" or
    // "screenshot" cannot manufacture extra receipt categories. Specific
    // interactions remain acceptance criteria in the outcome ledger.
    import std.regex : matchFirst;
    const operationOnly = cast(bool)matchFirst(outcome.toLower().strip(),
        `^(?:please )?(?:run|launch|open|build|compile|rebuild|publish|package)\b`);
    const implementation = session.contract.intent == "implementation" && !operationOnly;
    return implementation || artifactChangeRequested(outcome) || artifactChangeRequested(current) ||
        reportedFailureRequest(current) || session.verificationStatus == "required"
        ? ["tests"] : null;
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
    import std.conv : to;
    return effectFact("verification.scope\n" ~ workspace ~ "\n" ~ to!string(revision),
        () => observedVerificationScope(workspace, revision));
}

private string observedVerificationScope(string workspace, ulong revision)
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
    // A long task can hold hundreds of check receipts, and a tool result used
    // to revalidate every one of them on the window thread (re-reading each
    // recipe and re-walking its declared inputs). That scan measured 1.6-3.4 s
    // on a 29k-message conversation and held the UI for the same duration.
    // Only the newest fresh receipt that supplies each category can change the
    // coverage union, so validate at most one receipt per needed category
    // instead of one per historical row. A receipt whose categories are
    // already covered adds nothing, and a stale receipt is skipped exactly as
    // before; older rows remain the fallback when the newest one fails.
    import auroraopencode.recipeevidence : RecipeEvidenceCache;
    RecipeEvidenceCache recipes;
    void categories(string check, scope void delegate(string) sink)
    {
        if (check.startsWith("verify:"))
        {
            foreach (kind; check[7 .. $].split(","))
                if (kind.length) sink(kind);
        }
        else if (check.canFind("compile") || check.canFind("build") || check == "cargo check") sink("compile");
        else if (check.canFind("test")) sink("tests");
    }
    bool[string] remaining;
    const path = taskMessagePath(session);
    foreach (index; path)
        categories(session.messages[index].verificationCheck, (kind) { remaining[kind] = true; });
    bool current = true;
    bool contradicted;
    foreach_reverse (index; path)
    {
        if (!remaining.length) break;
        const ref message = session.messages[index];
        if (message.role == "user" && !message.internal &&
            reportedFailureRequest(message.content)) contradicted = true;
        // Everything older than a later failure report is already stale.
        if (contradicted) break;
        recipes.observe(message);
        const recipe = recipes.key(message);
        if (!recipe.length && session.verificationScope.length &&
            message.verificationScope == session.verificationScope &&
            (message.failed || !message.verificationCheck.length)) current = false;
        if (!message.verificationCheck.length) continue;
        bool contributes;
        categories(message.verificationCheck, (kind) { if (kind in remaining) contributes = true; });
        if (!contributes) continue;
        bool fresh;
        if (recipe.length) fresh = recipes.current(message, session.verificationScope);
        else fresh = current && session.verificationScope.length &&
            message.verificationScope == session.verificationScope;
        if (!fresh) continue;
        add(message.verificationCheck);
        categories(message.verificationCheck, (kind) { remaining.remove(kind); });
    }
    if (extraCheck.length) add(extraCheck);
    return "verify:" ~ kinds.join(",");
}

bool diagnosticToolAllowed(string name)
{
    return ["calculate", "read", "read_plan", "read_history", "grep", "glob", "view_image", "checksum", "tool_status"].canFind(name);
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
