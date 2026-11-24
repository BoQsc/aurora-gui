module auroraopencode.requestintent;

import std.algorithm : canFind;
import std.string : toLower, split, join, startsWith, strip;

/// `changeRequest` and `indeterminate` are parses, not turn decisions. An
/// indicative-mood statement and text with no cue at all both need the session's
/// work state before they mean anything; `resolvedRequestIntent` turns them into
/// one of the six turn intents.
enum RequestIntent { conversation, clarification, diagnosis, analysis, implementation,
    continuation, changeRequest, indeterminate }

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
         // Contracted questions are still questions. Without these a goal like
         // "What's your opinion on this?" looked like a conversation-shaped
         // action goal and demanded work receipts for an answer.
         "what's", "whats", "where's", "wheres", "who's", "whos", "how's", "hows",
         "when's", "whens",
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
    // "Don't just explain it, fix it" emphasizes action. Reading the negated
    // phrase as an explanation restriction inverted the user's emphasis and
    // turned an emphatic repair order into an answer-only turn.
    foreach (phrase; ["don't just explain", "dont just explain", "do not just explain",
            "don't just tell", "dont just tell", "don't just answer",
            "not just explain", "not just tell", "not just answer"])
        if (normalized.canFind(phrase)) return false;
    foreach (phrase; ["answer only", "explain only", "explanation only",
            "just explain", "only explain", "just answer", "just tell me",
            "do not edit", "don't edit", "do not change", "don't change",
            "do not implement", "don't implement", "do not fix", "don't fix",
            "without changing", "no changes", "make no changes"])
        if (normalized.canFind(phrase)) return true;
    return false;
}

/// A why-question about the agent's own authorization asks for an account of
/// what happened, not for a repair. Treating it as a diagnosis let the agent
/// "resolve" the answer by rolling back work the user had already requested and
/// received, so this stays an answer-only question.
bool processAccountabilityQuestion(string text)
{
    import std.regex : matchFirst;
    const value = text.toLower.split().join(" ");
    if (matchFirst(value,
        `\bwhy\b.*\b(?:without|before)\b.*\b(?:approval|permission|asking|a question|consent)\b`))
        return true;
    if (matchFirst(value, `\bwhy (?:nothing|no work|no action|no progress)\b`) ||
        matchFirst(value, `\bwhy (?:is|are|was|were) (?:you|we)\b.*\b(?:doing|working|acting|responding)\b`))
        return true;
    // "Why are you refusing?" is an account of the agent's conduct, not a
    // request to diagnose and repair the product. Reading it as a diagnosis
    // restarted a paused goal's outstanding work after the answer.
    if (matchFirst(value,
        `\bwhy (?:are|is|was|were) (?:you|it|we|they) (?:refusing|declining|stopping|pausing|ignoring)\b`))
        return true;
    return cast(bool) matchFirst(value,
        `\bwhy (?:did|was|were) (?:you|it|implementation|the implementation|the agent|this work)\b.*\b(?:start|begin|began|implement|implemented|change|changed|edit|edited|write|wrote)\b`);
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
    // "Do a quick review" and "do quick review" are instructions even when a
    // qualifier separates the imperative from the verb. Before this rule such a
    // review looked like a bare clarification ("is it organized well, do quick
    // review?"), so the completed task answered it through the tool-free
    // final-answer handoff and the model printed its lookup as XML call text.
    if (i >= 1 && ["do", "perform", "give", "take", "have"].canFind(words[i - 1]))
        return true;
    if (i >= 1)
    {
        size_t begin = i;
        foreach (step; 0 .. 2)
            if (begin > 0 && ["a", "an", "the", "quick", "short", "brief",
                    "full", "thorough", "small", "proper"].canFind(words[begin - 1]))
                --begin;
        if (begin < i && begin > 0 &&
            ["do", "perform", "give", "take", "have"].canFind(words[begin - 1]))
            return true;
    }
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

/// A yes/no status question ("so is all done and complete?") mentions
/// completion but asks for state. Treating it as an implementation request
/// created a task whose objective was the question, which then anchored later
/// corrections to a stale objective.
private bool statusQuestion(const(string)[] words)
{
    size_t i;
    while (i < words.length &&
        ["so", "now", "then", "please", "just", "and", "but"].canFind(words[i])) ++i;
    if (i >= words.length) return false;
    if (!["is", "are", "was", "were", "am", "do", "does", "did",
            "has", "have", "had"].canFind(words[i]))
        return false;
    // "Can you complete it?" is an action request with a modal actor, not a
    // status question about the work.
    foreach (j; i + 1 .. words.length)
        if (["can", "could", "would", "will", "should"].canFind(words[j]) &&
            j + 1 < words.length && ["you", "we"].canFind(words[j + 1]))
            return false;
    return true;
}

/// Lowercase, whitespace-collapsed text with sentence punctuation removed, so a
/// phrase matches whether or not a comma or full stop sits next to it
/// ("thanks, that's all").
private string paddedLower(string text)
{
    char[] buffer;
    buffer.reserve(text.length + 2);
    foreach (ch; text.toLower)
        buffer ~= (ch == ',' || ch == '.' || ch == '!' || ch == '?' ||
            ch == ';' || ch == ':') ? ' ' : ch;
    return " " ~ buffer.idup.split().join(" ") ~ " ";
}

private bool anyWord(const(string)[] words, const(string)[] wanted)
{
    foreach (word; wanted) if (words.canFind(word)) return true;
    return false;
}

/// Wh-words ask for information. They keep a statement-shaped change cue from
/// turning a genuine question ("what should be the default?") into work.
private bool whQuestion(const(string)[] words)
{
    size_t i;
    while (i < words.length &&
        ["so", "now", "then", "please", "instead", "just", "and", "but"].canFind(words[i])) ++i;
    return i < words.length && ["what", "what's", "whats", "how", "how's", "hows",
        "why", "when", "where", "who", "which"].canFind(words[i]);
}

/// "Can you X", "is it possible to X" and "would it be hard to X" ask for X.
/// Reading them as questions made an offered change an explanation request, so
/// the turn answered instead of doing the work.
private bool capabilityRequest(string text, const(string)[] words)
{
    if (anyWord(words, ["what", "what's", "whats", "how", "why", "when", "where",
            "who", "which", "whether"])) return false;
    const value = paddedLower(text);
    foreach (frame; [" can you ", " could you ", " would you ", " will you ",
            " is it possible ", " are you able ", " is there a way ", " any way to ",
            " would it be hard ", " would it be easy ", " would it be possible ",
            " would it be difficult ", " would it be feasible "])
        if (value.canFind(frame)) return true;
    return false;
}

/// A defect or a desired state stated without an imperative verb. Most users
/// report work this way ("the icon is too small", "it keeps jumping"), and a
/// verb-first parser read every one of them as casual conversation.
private bool changeCue(string text)
{
    const value = paddedLower(text);
    foreach (phrase; [" is too ", " are too ", " too small ", " too big ", " too slow ",
            " too fast ", " too large ", " too narrow ", " too wide ", " too bright ",
            " too dark ", " needs to ", " need to ", " should be ", " should probably ",
            " shouldn't ", " would be nice ", " would be better ", " would be good ",
            " it'd be nice ", " that'd be better ", " i'd like ", " i would like ",
            " i want ", " i don't want ", " i dont want ", " keeps ", " keeps failing ",
            " forgets ", " jumps ", " flickers ", " flicker ", " hangs ", " crashes ",
            " crash ", " stutters ", " freezes ", " is slow ", " is broken ",
            " is missing ", " is unusable ", " is off ", " looks off ", " looks wrong ",
            " looks bad ", " is wrong ", " handled this better ", " the old version ",
            " used to ", " was better ", " no way to ", " missing ", " leaks ", " lags ",
            " doesn't work ", " does not work ", " won't ", " can't ", " cannot ",
            " isn't working ", " aren't ", " always ", " never ", " from now on ",
            " scrap that ", " go back to ", " roll back ",
            " don't just ", " dont just ", " do not just ", " not just "])
        if (value.canFind(phrase)) return true;
    return false;
}

/// Instructions whose verb lives in the previous turn.
private bool elidedRequest(string text)
{
    const value = paddedLower(text);
    foreach (phrase; [" same for ", " same with ", " and the other ",
            " the other one ", " the second one ", " the first one ", " likewise ",
            " do the same ", " and then the ", " the rest of them "])
        if (value.canFind(phrase)) return true;
    import std.regex : matchFirst;
    return cast(bool) matchFirst(value, `\bdo (?:step )?\d`);
}

/// "keep going" and "carry on" continue the current work without naming it.
private bool continuesWork(string text)
{
    const value = paddedLower(text);
    foreach (phrase; [" keep going ", " go on ", " carry on ", " keep at it ",
            " keep working ", " next step ", " the next one ", " next one ",
            " finish the rest ", " do the rest ", " the remaining "])
        if (value.canFind(phrase)) return true;
    return false;
}

/// Greetings and short acknowledgements carry no work. "hello" and "thanks" sat
/// in the question-word list, so a greeting took the answer-only path.
private bool socialPhrase(string text)
{
    const words = requestWords(text);
    if (words.length > 4) return false;
    const value = paddedLower(text);
    foreach (phrase; [" hello ", " hi ", " hey ", " thanks ", " thank you ",
            " good morning ", " good night ", " cool ", " nice ", " cheers ",
            " bye ", " good job ", " well done "])
        if (value.canFind(phrase)) return true;
    return false;
}

/// A bare imperative does not need to be in the verb list: sentence position
/// already marks it as an instruction ("hide the empty categories"). Enumerating
/// verbs made every unlisted one read as conversation, so 72 of 72 measured
/// imperatives outside the list were dropped.
private bool leadingImperative(string text, const(string)[] words)
{
    if (words.length < 2) return false;
    const stripped = text.strip;
    if (stripped.length && stripped[$ - 1] == '?') return false;
    static immutable string[] nonVerbs = ["not", "don't", "dont", "no", "yes", "yeah", "yep", "ok",
        "okay", "sure", "maybe", "well", "so", "but", "and", "or", "the", "a", "an",
        "it", "this", "that", "these", "those", "i", "you", "we", "they", "he", "she",
        "there", "here", "please", "now", "then", "also", "just", "only", "still",
        "never", "always", "wait", "hmm", "uh", "oh", "ah", "hello", "hi", "hey",
        "won't", "can't", "cannot", "isn't", "aren't", "doesn't", "didn't",
        "wasn't", "weren't", "shouldn't", "wouldn't", "couldn't",
        "thanks", "what", "how", "why", "when", "where", "who", "which", "is", "are",
        "was", "were", "am", "do", "does", "did", "can", "could", "would", "should",
        "will", "may", "might", "shall", "have", "has", "had", "any", "some", "if",
        "while", "because", "before", "after", "about", "for", "from", "with",
        "without", "to", "at", "on", "in", "of", "by", "as", "than", "very",
        "really", "again", "too", "all", "both", "each", "every", "same", "other",
        "another", "next", "last", "first", "second", "third", "status", "recap",
        "explain", "describe", "summarize", "summarise", "answer", "plan", "analyze",
        "analyse", "review", "inspect", "check", "compare", "evaluate", "diagnose",
        "investigate", "research", "audit", "find", "look", "examine"];
    return !nonVerbs.canFind(words[0]);
}

/// Feedback that the work in progress is still wrong. It often has no action
/// verb of its own, so the generic parser would classify it as casual
/// conversation and stop the turn before the correction was applied.
bool correctiveFollowUpRequest(string text)
{
    const normalized = " " ~ text.toLower.split().join(" ") ~ " ";
    foreach (phrase; [" i said ", " i meant ", " i told you ",
            " second time ", " third time ",
            " not fixing ", " not doing anything ", " not doing anythign ",
            " not what i asked ", " not what was asked ", " not what i wanted ",
            " you're editing ", " you are editing ", " wrong file ", " wrong panel ",
            " wrong one ", " that's not what ", " that is not what ",
            " no, the ", " no, not ", " not that one ", " wait, not ",
            " you keep saying ", " you said it was fixed ",
            " keeps failing ", " keeps happening ", " failed again ",
            " still not ", " still broken ", " still failing ", " still not working ",
            " still does not ", " still doesn't ", " still cannot ", " still can't ",
            " does not work ", " doesn't work ", " not working ", " not fixed ",
            " problem persists ", " same problem ", " same issue ",
            " impossible to click ", " impossible to drag ", " impossible to select ",
            " impossible to move ",
            " testing things that are already known ", " you keep testing "])
        if (normalized.canFind(phrase)) return true;
    return false;
}

/// A complaint that the agent is not acting is a demand to continue the work,
/// even when it is phrased as a why-question ("so why you are not doing
/// anything about it"). A genuine why-question about a failure stays a
/// diagnosis and does not match these inaction phrases.
bool inactionComplaint(string text)
{
    const normalized = " " ~ text.toLower.split().join(" ") ~ " ";
    foreach (phrase; [" you are not fixing ", " you're not fixing ",
            " not fixing what ", " you are not doing ", " you're not doing ",
            " not doing anything ", " not doing anythign ",
            " you are testing ", " you're testing ", " you keep testing ",
            " testing things that are already known "])
        if (normalized.canFind(phrase)) return true;
    return false;
}

/// A terse suffix such as "at all" continues the previous user message rather
/// than becoming a new request on its own. It inherits that message's intent.
bool continuationFragment(string text)
{
    const words = requestWords(text);
    if (!words.length || (text.length && text[$ - 1] == '?')) return false;
    const normalized = words.join(" ");
    foreach (phrase; ["at all", "not at all", "still", "still not", "again",
            "same", "not yet", "and", "too"])
        if (normalized == phrase) return true;
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
                "start", "begin",
                "select", "update", "build", "resolve", "improve", "make", "write", "rebuild", "test", "verify",
                "redesign", "generate", "code", "rewrite", "integrate", "upgrade", "migrate", "enable", "disable",
                "extract", "convert", "configure", "connect", "download", "open", "copy"].canFind(word))
            return RequestIntent.implementation;
        if (["plan", "analyze", "analyse", "review", "inspect", "check", "compare", "evaluate", "diagnose",
                "investigate", "research", "audit", "find", "look", "examine"].canFind(word)) analysis = true;
    }
    if (continuation) return RequestIntent.continuation;
    if (continuesWork(text)) return RequestIntent.continuation;
    // An explicit answer-only restriction wins over a correction so the
    // requested scope is preserved ("explain why it is still broken; do not
    // change anything").
    if (!explicitExplanationOnly(text) && correctiveFollowUpRequest(text) &&
        (!leadingQuestion(words) || inactionComplaint(text)))
        return RequestIntent.continuation;
    if (completion && !statusQuestion(words)) return RequestIntent.implementation;
    if (analysis) return RequestIntent.analysis;
    if (correctiveActionRequest(text)) return RequestIntent.implementation;
    if (clarification) return RequestIntent.clarification;
    if (explicitExplanationOnly(text)) return RequestIntent.clarification;
    // An account of the agent's own conduct is not authorization to undo the
    // delivered work; only an explicit repair request above authorizes a change.
    if (processAccountabilityQuestion(text)) return RequestIntent.clarification;
    // "What is producing/causing this?" asks for the cause of the failure, so
    // it authorizes the same diagnosis and repair as a why-question. Reading it
    // as casual conversation settled the app into a prose-only answer, and the
    // agent then refused to continue the work.
    import std.regex : matchFirst, regex;
    if (matchFirst(text.toLower.split().join(" "),
        `\bwhat(?:'s| is| are| was| were)?\s+(?:producing|causing|triggering)\b|` ~
        `\bwhat causes\b|\bwhat is behind\b|` ~
        `\bwhat(?:'s| is)? the (?:cause|reason) (?:of|for|behind)\b`))
        return RequestIntent.diagnosis;
    // A question about a cause authorizes investigation and correction. It is
    // not a request to stop at an explanation; only an explicit explain-only
    // instruction above remains answer-only.
    if (words.canFind("why")) return RequestIntent.diagnosis;
    // A change request does not need an imperative verb that the list knows:
    // a capability frame, an indicative-mood statement, an elided instruction or
    // sentence position all carry it. These stay parses; the caller resolves them
    // against the session's unfinished work.
    if (capabilityRequest(text, words)) return RequestIntent.changeRequest;
    if (socialPhrase(text)) return RequestIntent.conversation;
    if (!whQuestion(words) && changeCue(text)) return RequestIntent.changeRequest;
    if (elidedRequest(text)) return RequestIntent.changeRequest;
    if (leadingQuestion(words) || words.canFind("explanation"))
        return RequestIntent.clarification;
    if (leadingImperative(text, words)) return RequestIntent.changeRequest;
    return RequestIntent.indeterminate;
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
        // Stored contract intent keeps the six turn values so restored sessions
        // and older builds read the same state.
        case RequestIntent.changeRequest: return "implementation";
        case RequestIntent.indeterminate: return "conversation";
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

/// A question whose answer is recorded task state needs no lookup. Without this
/// the tool-free final answer fired for any direct question, so "what's in the
/// log?" had no channel to read the log.
bool stateQuestionRequest(string text)
{
    const words = requestWords(text);
    foreach (noun; ["left", "remaining", "status", "steps", "step", "plan", "goal",
            "progress", "queue", "next", "summary", "cost", "tokens", "turns",
            "chats", "objective", "blocker"])
        if (words.canFind(noun)) return true;
    return false;
}

/// Turn a parse into a turn intent using the session's work state. While work is
/// unfinished, unplaced text belongs to it. An indicative-mood change belongs to
/// any recorded work, finished or not: "it is still too small" points at what was
/// just delivered, and starting a new task for it archives the work the user is
/// complaining about. With no recorded work a change starts a task.
RequestIntent resolvedRequestIntent(RequestIntent parsed, bool workActive, bool recordedWork)
{
    final switch (parsed)
    {
        case RequestIntent.indeterminate:
            return workActive ? RequestIntent.continuation : RequestIntent.conversation;
        case RequestIntent.changeRequest:
            return recordedWork ? RequestIntent.continuation : RequestIntent.implementation;
        case RequestIntent.conversation:
        case RequestIntent.clarification:
        case RequestIntent.diagnosis:
        case RequestIntent.analysis:
        case RequestIntent.implementation:
        case RequestIntent.continuation:
            return parsed;
    }
}

/// Internal control records can be appended as user-role messages so the model
/// sees them, but they are not user instructions and must never become a new
/// task objective. Recovery, plan review, goal continuation and handoff text
/// all belong to the turn that is already running.
bool controlInstructionText(string text)
{
    const value = text.strip;
    foreach (prefix; [
        "Durable task-state checkpoint.",
        "Internal control-history boundary.",
        "Progress guidance",
        "Plan progress checkpoint",
        "Plan review reminder",
        "Continuation: unfinished authorized work",
        "Execution recovery",
        "Execution obstacle",
        "Persistent goal continuation",
        "Continuation request",
        "Proactive action checkpoint",
        "Agent output recovery",
        "Execution diagnosis checkpoint",
        "Completion handoff requested",
        "The user resumed the",
        "The user started the",
        "The user updated the"])
        if (value.startsWith(prefix)) return true;
    return false;
}

/// A follow-up that opens with "how/whether/why... scope" asks for a direct
/// answer, not another action round. After a completed turn the final-answer
/// handoff otherwise withheld every tool, so the model emitted its lookup as
/// literal `<tool_calls>` text and the turn ended with no result at all.
bool directQuestionRequest(string text)
{
    if (explicitExplanationOnly(text)) return true;
    const words = requestWords(text);
    size_t i;
    while (i < words.length &&
        ["so", "now", "then", "please", "instead", "just", "and", "but"].canFind(words[i])) ++i;
    if (i >= words.length) return false;
    return ["what", "how", "whether", "why", "when", "where", "who", "which",
        "is", "are", "was", "were", "does", "did", "do", "can", "could", "would",
        "should", "will", "explain", "describe", "summarize", "summarise", "recap",
        "status", "any", "anything"].canFind(words[i]) ||
        (text.length && text[$ - 1] == '?');
}

/// The current request explicitly limits work: an explanation was asked for, or
/// the user said not to edit/implement/fix. An active goal waits for the user to
/// lift that restriction. A plain question ("what is left?") is not a
/// restriction: its answer is delivered and the goal keeps owning the work.
bool workRestrictionRequest(string text)
{
    return explicitExplanationOnly(text) || explanationOnlyRequest(text) || holdRequest(text);
}

/// A hold is not an explanation, but it withholds work just the same. An active
/// goal kept running after "hold off for now" because only explanation requests
/// counted as restrictions.
public bool holdRequest(string text)
{
    const value = paddedLower(text);
    foreach (phrase; [" hold off ", " hold on ", " hold that ", " hold the work ",
            " not yet ", " not now ", " don't do anything ", " dont do anything ",
            " do nothing ", " leave it for now ", " stay put ", " wait for now ",
            " wait a moment ", " wait a bit ", " wait a minute ", " let me check ",
            " let me look ", " let me think ", " give me a moment ", " one moment ",
            " stop for now ", " stand by ", " pause for now ", " pause this ",
            " pause the work "])
        if (value.canFind(phrase)) return true;
    return false;
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
    if (["yes", "yeah", "yep", "sure", "ok", "okay", "proceed", "approved", "approve"].canFind(phrase[0]) &&
        (phrase.length == 1 || (phrase.length == 2 && ["now", "then"].canFind(phrase[1]))))
        return true;
    // An approval can introduce the next concrete step ("Go ahead, start with
    // the creature widget."). The exact forms above accept an approval on its
    // own; a following directive is the same authorization. A question,
    // diagnosis or explanation after the approval still asks for an answer.
    const normalized = text.toLower.strip;
    // Delegation transfers the decision to the agent, which authorizes the work
    // it already described just as "go ahead" does.
    foreach (delegation; ["you decide", "you choose", "you pick", "your call",
            "your choice", "up to you", "whatever you think", "whatever you prefer",
            "whatever works", "whichever you think", "whichever you prefer",
            "use your judgment", "use your judgement", "use your best judgment",
            "your best judgment", "your judgment", "your judgement"])
        if (normalized.startsWith(delegation)) return true;
    static immutable string[] approvalPrefixes = ["go ahead", "carry on",
        "sounds good", "that works", "yes", "yeah", "yep",
        "sure", "ok", "okay", "proceed"];
    foreach (prefix; approvalPrefixes)
    {
        if (!normalized.startsWith(prefix)) continue;
        auto rest = normalized[prefix.length .. $];
        if (!rest.length) return true;
        if (rest[0] != ',' && rest[0] != ':' && rest[0] != ';' && rest[0] != '.')
            continue;
        auto directive = rest[1 .. $].strip;
        while (directive.length &&
            (directive[$ - 1] == '.' || directive[$ - 1] == '!' ||
             directive[$ - 1] == ',' || directive[$ - 1] == ';' ||
             directive[$ - 1] == ':'))
            directive = directive[0 .. $ - 1].strip;
        if (!directive.length) return true;
        if (directive[$ - 1] == '?') continue;
        const directiveIntent = requestIntent(directive);
        if (directiveIntent == RequestIntent.clarification ||
            directiveIntent == RequestIntent.diagnosis ||
            directiveIntent == RequestIntent.analysis) continue;
        return true;
    }
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
            "do what's asked", "do what is asked", "do what was asked",
            "do as asked", "do what's needed", "do what is needed",
            "do what needs to be done", "do what you need to do",
            "always clarifying", "always asking", "without asking", "keep asking"])
        if (normalized.canFind(phrase)) return true;
    return false;
}

/// A visible permission question in the assistant's prose is not a completed
/// outcome. The agent already has authorization for routine reversible steps.
bool permissionQuestionReply(string text)
{
    const lower = text.toLower;
    // Phrases first: "I can do that if you want." asks permission without a
    // question mark, and reading it as a completed outcome settled the turn.
    foreach (phrase; ["would you like me to", "should i ", "may i ",
            "do you want me to", "shall i ", "can i proceed", "could i proceed",
            "do you want to proceed", "please confirm", "would you prefer",
            "which option do you prefer", "which approach would you like",
            "let me know if you want me to", "let me know if you'd like me to",
            "if you want me to", "if you'd like me to", "if you want",
            "if you'd like", "say the word", "let me know and i", "want me to",
            "happy to do that if", "just say go"])
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
/// A small refinement of the work in front of the user. One turn after "add a
/// settings page", "make the font bigger" amends that page; treating it as a new
/// action archived the page and started a task named after the refinement.
private bool refinementRequest(string text)
{
    const value = paddedLower(text);
    foreach (phrase; [" bigger ", " smaller ", " wider ", " narrower ", " faster ",
            " slower ", " taller ", " shorter ", " lighter ", " darker ", " dimmer ",
            " brighter ", " quieter ", " louder ", " bolder ", " thinner ", " instead "])
        if (value.canFind(phrase)) return true;
    foreach (prefix; [" make it ", " make that ", " make this ", " make the ",
            " change the ", " set the ", " move the ", " resize the ", " rename the ",
            " tweak ", " adjust ", " use the ", " use that "])
        if (value.startsWith(prefix)) return true;
    return false;
}

bool taskAmendmentRequest(string text)
{
    const value = text.toLower().split().join(" ");
    const words = requestWords(text);
    if (words.canFind("remaining") || words.canFind("original") ||
        value.startsWith("also ") || value.startsWith("additionally ") ||
        value.startsWith("in addition ")) return true;
    if (refinementRequest(text)) return true;
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

/// A new failure report supersedes earlier passing checks. This is deliberately
/// separate from action intent: a complaint can also ask for an explanation.
bool reportedFailureRequest(string text)
{
    import std.regex : matchFirst;
    const value = text.toLower();
    return cast(bool)matchFirst(value, `\b(?:not fixed|not working|does not work|doesn't work|does nothing|no longer|still broken|still not|incorrect|bugged|regress\w*|speed(?:ed)? up|incredibly fast|selects? (?:the )?wrong)\b`);
}
