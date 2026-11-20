/// Pragmatic-understanding probe for the request classifier.
///
/// `requestintent.requestIntent` parses an utterance; `resolvedRequestIntent`
/// turns that parse into a turn intent using the session's work state. The turn
/// intent gates tool availability, goal resume, evidence requirements and what
/// the app tells the model about the current request.
///
/// This probe does not assert a shipping contract. It measures the difference
/// between the label a competent reader infers from the utterance and the label
/// the app produces, so the gap is visible and comparable between builds.
///
/// Build and run from the package root:
///   dmd -Isource -i -of=tmp/intent_pragmatics_probe.exe benchmarks/intent_pragmatics_probe.d
///   tmp/intent_pragmatics_probe.exe
module intent_pragmatics_probe;

import auroraopencode.requestintent;
import std.algorithm : canFind;
import std.array : array, join;
import std.conv : to;
import std.string : split;
import std.stdio : writefln, writeln;

struct Case
{
    string text;
    string category;
    RequestIntent[] accept;
    /// True when the utterance arrives while work is already unfinished, so it
    /// amends or corrects that work instead of starting a task.
    bool warm;
    /// True when the session already holds a task or goal, finished or not.
    bool recorded;
}

private string label(RequestIntent intent) { return requestIntentName(intent); }

private bool accepted(const ref Case c, RequestIntent actual)
{
    foreach (wanted; c.accept) if (wanted == actual) return true;
    return false;
}

private string acceptText(const ref Case c)
{
    string[] names;
    foreach (wanted; c.accept) names ~= label(wanted);
    return names.join("|");
}

int main()
{
    alias I = RequestIntent;
    Case[] corpus;
    void expect(string category, string text, I[] accept, bool warm = false, bool recorded = false)
    {
        corpus ~= Case(text, category, accept, warm, recorded || warm);
    }

    // A complaint about the product is a change request. A reader does not
    // need an imperative verb to understand "make this bigger".
    expect("indirect-imperative", "the tray icon is too small", [I.implementation]);
    expect("indirect-imperative", "the scrollbar jumps when I resize the window", [I.implementation]);
    expect("indirect-imperative", "the settings dialog forgets my theme every restart", [I.implementation]);
    expect("indirect-imperative", "this list is slow once it passes 500 items", [I.implementation]);
    expect("indirect-imperative", "the title bar looks off on high dpi screens", [I.implementation]);
    expect("indirect-imperative", "there is a flicker when the panel opens", [I.implementation]);

    // Wishes, needs and suggestions are instructions in ordinary talk.
    expect("wish-modality", "it would be nice if the window remembered its size", [I.implementation]);
    expect("wish-modality", "maybe the log should be shorter", [I.implementation]);
    expect("wish-modality", "we should probably show a spinner while it loads", [I.implementation]);
    expect("wish-modality", "i'd like the sidebar collapsed by default", [I.implementation]);
    expect("wish-modality", "the panel needs to be wider", [I.implementation]);
    expect("wish-modality", "could we make the toast dismiss itself", [I.implementation]);

    // A feasibility or capability question about a change is a request for
    // that change, unless the answer is a fact about existing behavior.
    expect("question-shaped-request", "can you also handle the drag case", [I.implementation]);
    expect("question-shaped-request", "is it possible to keep the scroll position", [I.implementation]);
    expect("question-shaped-request", "would it be hard to add a copy button", [I.implementation]);
    expect("question-shaped-request", "can you support pasting images", [I.implementation]);
    expect("question-shaped-request", "does the updater support a rollback channel", [I.clarification]);
    expect("question-shaped-request", "why not just cache the projection", [I.implementation, I.diagnosis]);

    // A correction of the agent's own work continues it, even mid-task and
    // often without any phrase the correction list knows.
    expect("correction-without-keyword", "you're editing the wrong file", [I.continuation], true);
    expect("correction-without-keyword", "no, the other panel", [I.continuation], true);
    expect("correction-without-keyword", "i meant the dark theme", [I.continuation], true);
    expect("correction-without-keyword", "not the header, the footer", [I.continuation], true);
    expect("correction-without-keyword", "scrap that, go back to how it was", [I.continuation], true);
    expect("correction-without-keyword", "you already have permission, just do it",
        [I.implementation, I.continuation], true);
    expect("correction-without-keyword", "you keep saying it's done but it isn't", [I.continuation], true);
    // The same complaint after the app already marked the work complete still
    // amends it; starting a task there archived the work being complained about.
    expect("correction-without-keyword", "it is still too small", [I.continuation], false, true);

    // Ellipsis and anaphora: the instruction lives in the previous turn.
    expect("deictic-elision", "same for the tray menu", [I.continuation], true);
    expect("deictic-elision", "and the other one too", [I.continuation], true);
    expect("deictic-elision", "do 2 and 3", [I.continuation], true);
    expect("deictic-elision", "keep going", [I.continuation], true);
    expect("deictic-elision", "finish the rest", [I.continuation], true);
    expect("deictic-elision", "now the second one", [I.continuation], true);

    // Scope of negation and emphasis. The parser sees the negated word; the
    // reader sees the emphasized instruction.
    expect("negation-scope", "don't just explain it, fix it", [I.implementation]);
    expect("negation-scope", "i don't want a summary, i want it working", [I.implementation]);
    expect("negation-scope", "stop telling me it's fixed and make it work",
        [I.implementation, I.continuation]);
    expect("negation-scope", "explain it, don't fix it yet", [I.clarification]);
    expect("negation-scope", "don't change anything, just tell me why", [I.clarification]);
    expect("negation-scope", "skip the tests, the change is trivial", [I.implementation]);

    // Reference to another product is a design instruction, not small talk.
    expect("reference-model", "look at how the other app does tabs", [I.analysis, I.implementation]);
    expect("reference-model", "the old version handled this better", [I.implementation, I.diagnosis]);

    // Standing preferences are work: they must persist into later turns.
    expect("preference-instruction", "from now on always ask before deleting", [I.implementation]);
    expect("preference-instruction", "always use the dark theme", [I.implementation]);
    expect("preference-instruction", "never publish without asking me", [I.implementation]);

    expect("plan-reference", "step 3 is wrong", [I.continuation], true);

    // Controls: genuinely answer-only, or genuinely conversation.
    expect("answer-control", "what does the rebuild tool do", [I.clarification]);
    expect("answer-control", "what is left", [I.clarification]);
    expect("answer-control", "how many chats did we have", [I.clarification]);
    expect("answer-control", "thanks, that's all", [I.conversation]);
    expect("answer-control", "hello", [I.conversation]);
    expect("answer-control", "what's your opinion on the new palette", [I.clarification]);

    // Controls: genuine diagnosis and genuine implementation.
    expect("cause-control", "why does it crash on paste", [I.diagnosis]);
    expect("cause-control", "what is causing the stutter", [I.diagnosis]);
    expect("cause-control", "the app hangs on startup", [I.implementation]);
    expect("cause-control", "it crashes when i paste an image", [I.implementation]);
    expect("cause-control", "fix the parser", [I.implementation]);
    expect("cause-control", "add a copy button", [I.implementation]);
    expect("cause-control", "please make the update check quieter", [I.implementation]);

    // Requests whose verb the classifier never enumerated.
    expect("verb-coverage", "can you show the file size in the status bar", [I.implementation]);
    expect("verb-coverage", "hide the empty categories", [I.implementation]);
    expect("verb-coverage", "remember the last folder per project", [I.implementation]);
    expect("verb-coverage", "validate the api key before submitting", [I.implementation]);
    expect("verb-coverage", "debounce the resize handler", [I.implementation]);
    expect("verb-coverage", "align the buttons to the right", [I.implementation]);

    int[string] categoryTotal, categoryMissed;
    string[] categoryOrder;
    int passed, failed, dangerousMisses;
    string[] missesWithoutVerb, missesWithVerb;

    writeln("== Labelled pragmatic corpus (resolved against work state) ==");
    foreach (ref c; corpus)
    {
        const actual = resolvedRequestIntent(requestIntent(c.text), c.warm, c.recorded);
        if (!(c.category in categoryTotal)) categoryOrder ~= c.category;
        ++categoryTotal[c.category];
        if (accepted(c, actual)) { ++passed; continue; }
        ++failed;
        ++categoryMissed[c.category];
        writefln("FAIL [%s] \"%s\"%s", c.category, c.text,
            c.warm ? " (mid-work)" : c.recorded ? " (after completion)" : "");
        writefln("     classified %-14s expected %s", label(actual), acceptText(c));
        const workWanted = c.accept.canFind(I.implementation) || c.accept.canFind(I.continuation);
        if (workWanted && (actual == I.conversation || actual == I.clarification))
            ++dangerousMisses;
        bool knownVerb;
        foreach (word; c.text.split)
            if (requestIntent(word) == I.implementation) knownVerb = true;
        (knownVerb ? missesWithVerb : missesWithoutVerb) ~= c.text;
    }

    writeln("\n== Recall by category (higher is better) ==");
    foreach (category; categoryOrder)
    {
        const missed = categoryMissed.get(category, 0);
        const total = categoryTotal.get(category, 1);
        writefln("%-26s %2d/%-2d ok  %2d miss", category, total - missed, total, missed);
    }
    writefln("\noverall %d/%d correct, %d mismatched", passed, passed + failed, failed);
    writefln("mismatches that removed requested work: %d", dangerousMisses);
    writefln("mismatches carrying a listed verb: %d, without any: %d",
        missesWithVerb.length, missesWithoutVerb.length);
    foreach (text; missesWithVerb) writefln("  listed word present: \"%s\"", text);

    // The final-answer gate. `answerOnly` is a scope decision; it must not by
    // itself remove the tools a lookup needs.
    writeln("\n== Answer-only label versus lookup need ==");
    struct Lookup { string text; bool needsLookup; }
    immutable Lookup[] lookups = [
        Lookup("what is left?", false),
        Lookup("what's in the log?", true),
        Lookup("is the build passing?", true),
        Lookup("how many steps are left?", false),
        Lookup("can you check the log?", true),
        Lookup("what did the last test report?", true),
    ];
    int lookupWrong;
    foreach (const ref probe; lookups)
    {
        const answerOnly = answerOnlyRequest(probe.text);
        const finalAnswerGate = answerOnly &&
            (explanationOnlyRequest(probe.text) || stateQuestionRequest(probe.text));
        const wrong = probe.needsLookup && finalAnswerGate;
        if (wrong) ++lookupWrong;
        writefln("%s \"%s\" answerOnly=%s finalAnswerGate=%s",
            wrong ? "FAIL" : "ok  ", probe.text, answerOnly, finalAnswerGate);
    }

    // Guard-level probes: each one gates whether work resumes or stops.
    writeln("\n== Guard probes ==");
    struct Flag { string text; bool expected; bool actual; }
    immutable Flag[] approvals = [
        Flag("go ahead", true, actionApprovalRequest("go ahead")),
        Flag("yes", true, actionApprovalRequest("yes")),
        Flag("sounds good, go ahead", true, actionApprovalRequest("sounds good, go ahead")),
        Flag("you decide", true, actionApprovalRequest("you decide")),
        Flag("up to you", true, actionApprovalRequest("up to you")),
        Flag("whatever you think is best", true, actionApprovalRequest("whatever you think is best")),
        Flag("approved", true, actionApprovalRequest("approved")),
        Flag("what is the plan", false, actionApprovalRequest("what is the plan")),
    ];
    foreach (const ref f; approvals)
        writefln("%s approval(\"%s\") = %s (expected %s)", f.actual == f.expected ? "ok  " : "FAIL",
            f.text, f.actual, f.expected);

    immutable Flag[] restrictions = [
        Flag("explain why it failed", true, workRestrictionRequest("explain why it failed")),
        Flag("just tell me why", true, workRestrictionRequest("just tell me why")),
        Flag("what's the plan?", false, workRestrictionRequest("what's the plan?")),
        Flag("what is left?", false, workRestrictionRequest("what is left?")),
        Flag("hold off for now", true, workRestrictionRequest("hold off for now")),
        Flag("don't do anything yet", true, workRestrictionRequest("don't do anything yet")),
        Flag("not yet", true, workRestrictionRequest("not yet")),
        Flag("wait, not that one", false, workRestrictionRequest("wait, not that one")),
    ];
    foreach (const ref f; restrictions)
        writefln("%s restriction(\"%s\") = %s (expected %s)", f.actual == f.expected ? "ok  " : "FAIL",
            f.text, f.actual, f.expected);

    immutable Flag[] permissionReplies = [
        Flag("Would you like me to proceed?", true, permissionQuestionReply("Would you like me to proceed?")),
        Flag("Should I also update the docs?", true, permissionQuestionReply("Should I also update the docs?")),
        Flag("I can do that if you want.", true, permissionQuestionReply("I can do that if you want.")),
        Flag("Say the word and I'll continue.", true, permissionQuestionReply("Say the word and I'll continue.")),
        Flag("Fixed the parser and verified the repro.", false,
            permissionQuestionReply("Fixed the parser and verified the repro.")),
        Flag("The parser is fixed; tests pass.", false, permissionQuestionReply("The parser is fixed; tests pass.")),
    ];
    foreach (const ref f; permissionReplies)
        writefln("%s permissionReply(\"%s\") = %s (expected %s)", f.actual == f.expected ? "ok  " : "FAIL",
            f.text, f.actual, f.expected);

    immutable Flag[] fragments = [
        Flag("at all", true, continuationFragment("at all")),
        Flag("again", true, continuationFragment("again")),
        Flag("keep going", false, continuationFragment("keep going")),
        Flag("same for the tray", false, continuationFragment("same for the tray")),
    ];
    foreach (const ref f; fragments)
        writefln("%s continuation(\"%s\") = %s (expected %s)", f.actual == f.expected ? "ok  " : "FAIL",
            f.text, f.actual, f.expected);

    // A refinement amends the work in front of the user; a self-contained new
    // action owns a new task. Archiving the refined task was the long-horizon
    // drift: "make the font bigger" one turn after "add a settings page".
    immutable Flag[] amendments = [
        Flag("make the font bigger", true, taskAmendmentRequest("make the font bigger")),
        Flag("make the button wider", true, taskAmendmentRequest("make the button wider")),
        Flag("use the compact layout instead", true, taskAmendmentRequest("use the compact layout instead")),
        Flag("also handle gzipped files", true, taskAmendmentRequest("also handle gzipped files")),
        Flag("Fix fullscreen switching immediately, globally across the running world and map selector",
             false, taskAmendmentRequest(
                 "Fix fullscreen switching immediately, globally across the running world and map selector")),
        Flag("add a copy button", false, taskAmendmentRequest("add a copy button")),
        Flag("build the exporter for xlsx", false, taskAmendmentRequest("build the exporter for xlsx")),
    ];
    foreach (const ref f; amendments)
        writefln("%s amendment(\"%s\") = %s (expected %s)", f.actual == f.expected ? "ok  " : "FAIL",
            f.text, f.actual, f.expected);

    // Verb coverage: a bare imperative in front of any verb must read as a
    // request, whether or not the verb is enumerated.
    writeln("\n== Verb coverage (\"<verb> the panel\" as a bare imperative, cold start) ==");
    immutable string[] verbs = ["fix", "add", "remove", "change", "update", "make", "write",
        "move", "open", "handle", "support", "show", "hide", "remember", "persist", "cache",
        "preload", "debounce", "throttle", "validate", "expose", "document", "dedupe", "align",
        "center", "pad", "round", "clamp", "scroll", "focus", "refresh", "reload", "format",
        "sort", "group", "tidy", "polish", "wire", "hook", "allow", "prevent", "avoid",
        "simplify", "restructure", "shorten", "enlarge", "shrink", "limit", "trim", "merge",
        "swap", "restore", "revert", "undo", "toggle", "collapse", "expand", "zoom", "snap",
        "dock", "minimize", "maximize", "resize", "style", "fade", "animate", "smooth", "batch",
        "compress", "sanitize", "lock", "pin", "mute", "notify", "prompt", "warn", "confirm",
        "skip", "speed", "quiet"];
    int recognized;
    string[] missed;
    foreach (verb; verbs)
    {
        if (resolvedRequestIntent(requestIntent(verb ~ " the panel"), false, false) == I.implementation)
            ++recognized;
        else missed ~= verb;
    }
    writefln("recognized as implementation: %d/%d", recognized, verbs.length);
    writefln("still read as non-requests: %s", missed.length ? missed.join(" ") : "(none)");

    // Robustness: the classifier is fed raw composer text.
    foreach (text; ["", "?", "   ", "...", "👍", "not now", "ok"])
        requestIntent(text);
    writeln("\nrobustness: empty, whitespace, punctuation, emoji and terse replies classified without error");

    // Harness integrity only. Mismatches above are measurements, not failures:
    // this probe reports the gap instead of asserting a shipping contract.
    assert(corpus.length > 0 && passed + failed == corpus.length);
    assert(passed + failed == 63);

    writeln("\nPROBE COMPLETE");
    return 0;
}
