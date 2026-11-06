module auroraopencode.requestintent;

import std.algorithm : canFind;
import std.string : toLower, split, join, startsWith;

enum RequestIntent { conversation, clarification, diagnosis, analysis, implementation, continuation }

private string[] requestWords(string text)
{
    auto words = text.toLower().split();
    foreach (ref word; words)
    {
        while (word.length && "\"'([{".canFind(word[0])) word = word[1 .. $];
        while (word.length && ",.!?:;\"')]}".canFind(word[$ - 1])) word = word[0 .. $ - 1];
    }
    return words;
}

private bool leadingQuestion(const(string)[] words)
{
    size_t i;
    while (i < words.length &&
        ["so", "now", "then", "please", "instead", "just"].canFind(words[i])) ++i;
    return i < words.length &&
        ["what", "how", "why", "when", "where", "who", "which", "is", "are",
         "does", "did", "do", "can", "could", "would", "should", "shall", "will",
         "may", "might", "explain", "describe", "summarize", "summarise",
         "status", "recap", "hello", "hi", "thanks"].canFind(words[i]);
}

/// The user asked to be told the cause without authorizing any repair. The
/// guard is explicit so a bare "why" is a diagnosis request, not an answer-only
/// question that leaves a failure unresolved.
private bool explicitExplanationOnly(string text)
{
    const normalized = text.toLower.split().join(" ");
    foreach (phrase; ["answer only", "explain only", "explanation only",
            "just explain", "only explain", "just answer", "just tell me",
            "do not edit", "don't edit", "do not change", "don't change",
            "do not implement", "don't implement", "do not fix", "don't fix",
            "without changing", "no changes", "make no changes"])
        if (normalized.canFind(phrase)) return true;
    return false;
}

private bool requestedVerb(const(string)[] words, const(string)[] raw, size_t i)
{
    // A modal question about an approach is advice, not a command. Restrict
    // this to its clause so a later "Please implement it" still takes effect.
    if (i >= 2 && ["you", "we", "i"].canFind(words[i - 1]) &&
        ["can", "could", "would", "should", "will", "might"].canFind(words[i - 2]))
    {
        size_t clause;
        foreach_reverse (j; 0 .. i)
            if (raw[j].length && ".!?:;".canFind(raw[j][$ - 1])) { clause = j + 1; break; }
        while (clause < i && ["please", "now", "instead", "so", "just"].canFind(words[clause])) ++clause;
        if (clause < i && ["what", "how", "which", "why", "where", "when", "who"].canFind(words[clause])) return false;
    }
    const sentenceStart = i > 0 && raw[i - 1].length && ".!?:;".canFind(raw[i - 1][$ - 1]);
    const clauseStart = i > 0 && raw[i - 1].length && raw[i - 1][$ - 1] == ',' &&
        !["what", "how", "why", "when", "where", "who", "which"].canFind(words[0]);
    if (!sentenceStart && i && ["not", "don't", "dont", "never", "without", "avoid", "stop"].canFind(words[i - 1])) return false;
    if (!sentenceStart && i >= 2 && words[i - 2] == "do" && words[i - 1] == "not") return false;
    if (i == 0 || sentenceStart || clauseStart || (i && ["and", "then", "please", "let's"].canFind(words[i - 1]))) return true;
    if (i >= 2 && words[i - 1] == "you" && ["can", "could", "would", "will"].canFind(words[i - 2])) return true;
    if (i >= 2 && words[i - 1] == "we" && ["can", "could", "would", "will"].canFind(words[i - 2]) &&
        (i == 2 || (i >= 3 && raw[i - 3].length && ".!?:;".canFind(raw[i - 3][$ - 1])))) return true;
    if (i >= 2 && words[i - 1] == "to" && ["me", "you", "need", "want"].canFind(words[i - 2])) return true;
    if (i >= 2 && words[i - 1] == "me" && words[i - 2] == "help") return true;
    if (i >= 2 && words[0] == "i" && ["want", "need"].canFind(words[1])) return true;
    if (i)
    {
        bool prefix = true;
        foreach (word; words[0 .. i])
            if (!["please", "now", "instead", "so", "just"].canFind(word)) prefix = false;
        if (prefix) return true;
    }
    if (i >= 3 && words[0] == "i" && words[1] == "said" && words[2] == "to") return true;
    return false;
}

/// This conservative local classifier controls continuation, not authorization
/// for arbitrary tools. The model still sees the complete current instruction.
RequestIntent requestIntent(string text)
{
    const words = requestWords(text);
    const raw = text.toLower().split();
    bool analysis, continuation, completion, clarification;
    foreach (i, word; words)
    {
        if (!requestedVerb(words, raw, i)) continue;
        if (["continue", "resume", "retry"].canFind(word)) { continuation = true; continue; }
        if (["finish", "complete"].canFind(word)) { completion = true; continue; }
        if (["answer", "explain", "describe", "summarize", "summarise", "recap"].canFind(word))
        { clarification = true; continue; }
        // "Do it/that/this" is an instruction to act. Elsewhere "do" is an
        // auxiliary verb ("How do I fix it?") and must not imply action.
        if (word == "do" && i + 1 < words.length &&
            ["it", "that", "this", "so"].canFind(words[i + 1]))
            return RequestIntent.implementation;
        if (["fix", "repair", "implement", "apply", "change", "refactor", "optimize", "optimise",
                "create", "add", "remove", "delete", "replace", "rename", "move", "save", "commit",
                "ship", "publish", "deploy", "install", "launch", "play", "run", "try",
                "select", "update", "build", "resolve", "improve", "make", "write", "rebuild", "test", "verify",
                "redesign", "generate", "code", "rewrite", "integrate", "upgrade", "migrate", "enable", "disable",
                "extract", "convert", "configure", "connect", "download", "open", "copy"].canFind(word))
            return RequestIntent.implementation;
        if (["plan", "analyze", "analyse", "review", "inspect", "check", "compare", "evaluate", "diagnose",
                "investigate", "research", "audit", "find", "look", "examine"].canFind(word)) analysis = true;
    }
    if (continuation) return RequestIntent.continuation;
    if (completion) return RequestIntent.implementation;
    if (analysis) return RequestIntent.analysis;
    if (correctiveActionRequest(text)) return RequestIntent.implementation;
    if (clarification) return RequestIntent.clarification;
    if (explicitExplanationOnly(text)) return RequestIntent.clarification;
    // A question about a cause authorizes investigation and correction. It is
    // not a request to stop at an explanation; only an explicit explain-only
    // instruction above remains answer-only.
    if (words.canFind("why")) return RequestIntent.diagnosis;
    if (leadingQuestion(words) || words.canFind("explanation"))
        return RequestIntent.clarification;
    return RequestIntent.conversation;
}

string requestIntentName(RequestIntent intent)
{
    final switch (intent)
    {
        case RequestIntent.conversation: return "conversation";
        case RequestIntent.clarification: return "clarification";
        case RequestIntent.diagnosis: return "diagnosis";
        case RequestIntent.analysis: return "analysis";
        case RequestIntent.implementation: return "implementation";
        case RequestIntent.continuation: return "continuation";
    }
}

bool explanationOnlyRequest(string text)
{
    if (requestIntent(text) != RequestIntent.clarification) return false;
    const words = requestWords(text);
    return words.canFind("explain") || words.canFind("explanation") ||
        words.canFind("describe") || words.canFind("summarize") ||
        words.canFind("summarise") || words.canFind("recap");
}

bool answerOnlyRequest(string text) { return requestIntent(text) == RequestIntent.clarification; }

/// The current request explicitly limits work: an explanation was asked for, or
/// the user said not to edit/implement/fix. An active goal waits for the user to
/// lift that restriction. A plain question ("what is left?") is not a
/// restriction: its answer is delivered and the goal keeps owning the work.
bool workRestrictionRequest(string text)
{
    return explicitExplanationOnly(text) || explanationOnlyRequest(text);
}

/// A cause-seeking follow-up must not resume desktop input, even though it does
/// authorize code and tool investigation. This keeps a kill-switch stop intact
/// while the agent works on the cause through non-desktop tools.
bool diagnosticFollowUpRequest(string text)
{
    return explanationOnlyRequest(text) || requestIntent(text) == RequestIntent.diagnosis;
}

/// A short approval authorizes the work the agent already described. It is not
/// a new objective and must not be mistaken for casual conversation, which
/// would leave an unfinished task stalled after a needless confirmation.
bool actionApprovalRequest(string text)
{
    auto words = requestWords(text);
    if (!words.length) return false;
    size_t begin, end;
    if (words[0] == "please") begin = 1;
    end = words.length;
    if (end > begin && words[end - 1] == "please") --end;
    if (begin >= end) return false;
    const phrase = words[begin .. end];
    if (phrase.length == 2 &&
        ((phrase[0] == "go" && phrase[1] == "ahead") ||
         (phrase[0] == "carry" && phrase[1] == "on") ||
         (phrase[0] == "handle" && phrase[1] == "it") ||
         (phrase[0] == "handle" && phrase[1] == "that") ||
         (phrase[0] == "sounds" && phrase[1] == "good") ||
         (phrase[0] == "that" && phrase[1] == "works")))
        return true;
    if (phrase.length == 3 && phrase[0] == "go" && phrase[1] == "for" &&
        phrase[2] == "it")
        return true;
    if (phrase.length == 3 && phrase[0] == "make" && phrase[1] == "it" && phrase[2] == "so")
        return true;
    if (phrase.length == 4 && phrase[0] == "take" && phrase[1] == "care" &&
        phrase[2] == "of" && phrase[3] == "it")
        return true;
    if (["yes", "yeah", "yep", "sure", "ok", "okay", "proceed"].canFind(phrase[0]))
        return phrase.length == 1 || ["now", "then"].canFind(phrase[1]);
    return false;
}

/// Feedback such as "stop asking and just do it" is a corrective action
/// request, not casual conversation. Treating it as chat leaves the old task
/// stalled even though the user has clearly asked for a behavior change.
bool correctiveActionRequest(string text)
{
    const normalized = text.toLower.split().join(" ");
    foreach (phrase; ["be proactive", "stop asking", "stop clarifying",
            "don't ask", "dont ask", "instead of asking", "instead of clarifying",
            "instead of figuring out", "instead of doing", "figure it out",
            "just do it", "just do the", "do the work", "do what i asked",
            "always clarifying", "always asking", "without asking", "keep asking"])
        if (normalized.canFind(phrase)) return true;
    return false;
}

/// A visible permission question in the assistant's prose is not a completed
/// outcome. The agent already has authorization for routine reversible steps.
bool permissionQuestionReply(string text)
{
    const lower = text.toLower;
    if (!lower.canFind("?")) return false;
    foreach (phrase; ["would you like me to", "should i ", "may i ",
            "do you want me to", "shall i ", "can i proceed", "could i proceed",
            "do you want to proceed", "please confirm", "would you prefer",
            "which option do you prefer", "which approach would you like",
            "let me know if you want me to", "let me know if you'd like me to"])
        if (lower.canFind(phrase)) return true;
    return false;
}

bool artifactChangeRequested(string text)
{
    const words = requestWords(text);
    const raw = text.toLower().split();
    foreach (i, word; words)
        if (["fix", "repair", "implement", "apply", "change", "refactor", "optimize", "optimise",
                "create", "add", "remove", "delete", "replace", "rename", "move", "save", "make", "write",
                "redesign", "generate", "code", "rewrite", "integrate", "upgrade", "migrate", "configure"].canFind(word) &&
            requestedVerb(words, raw, i)) return true;
    return false;
}

bool explicitlyNewTask(string text)
{
    const value = text.toLower();
    return value.startsWith("new task") || value.startsWith("instead,") ||
        value.startsWith("instead ") || value.startsWith("forget that") ||
        value.startsWith("switch to ");
}

/// Explicit references to ongoing work refine its acceptance. Independent
/// action requests get their own scope; semantic overlap alone is insufficient.
bool taskAmendmentRequest(string text)
{
    const value = text.toLower().split().join(" ");
    const words = requestWords(text);
    if (words.canFind("remaining") || words.canFind("original") ||
        value.startsWith("also ") || value.startsWith("additionally ") ||
        value.startsWith("in addition ")) return true;
    return ["fix it", "so fix it", "just fix it", "try to fix it", "do it", "do that", "do this"].canFind(value);
}

bool explicitPlanReplacementRequested(string text)
{
    const words = requestWords(text);
    const raw = text.toLower().split();
    foreach (i, word; words)
        if (requestedVerb(words, raw, i))
        {
            if (word == "replan") return true;
            if (["replace", "discard", "drop", "rewrite"].canFind(word) &&
                (words.canFind("plan") || words.canFind("checklist") || words.canFind("steps") || words.canFind("outcomes"))) return true;
        }
    return false;
}
