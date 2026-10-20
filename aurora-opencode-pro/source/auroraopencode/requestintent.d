module auroraopencode.requestintent;

import std.algorithm : canFind;
import std.string : toLower, split, startsWith;

enum RequestIntent { conversation, clarification, analysis, implementation, continuation }

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

private bool requestedVerb(const(string)[] words, const(string)[] raw, size_t i)
{
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
    if (i && ["please", "now", "instead"].canFind(words[0])) return true;
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
        if (["explain", "describe", "summarize", "summarise", "recap"].canFind(word))
        { clarification = true; continue; }
        // "Do it/that/this" is an instruction to act. Elsewhere "do" is an
        // auxiliary verb ("How do I fix it?") and must not imply action.
        if (word == "do" && i + 1 < words.length &&
            ["it", "that", "this", "so"].canFind(words[i + 1]))
            return RequestIntent.implementation;
        if (["fix", "repair", "implement", "apply", "change", "refactor", "optimize", "optimise",
                "create", "add", "remove", "delete", "replace", "rename", "move", "save", "commit",
                "publish", "deploy", "install", "launch", "play", "run", "try",
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
    if (clarification) return RequestIntent.clarification;
    if (words.length && (["what", "how", "why", "when", "where", "who", "which", "is", "are",
            "does", "did", "do", "can", "could", "would", "should", "shall", "will", "may", "might", "explain", "describe", "summarize",
            "summarise", "status", "recap", "hello", "hi", "thanks"].canFind(words[0]) ||
            words.canFind("explanation"))) return RequestIntent.clarification;
    return RequestIntent.conversation;
}

string requestIntentName(RequestIntent intent)
{
    final switch (intent)
    {
        case RequestIntent.conversation: return "conversation";
        case RequestIntent.clarification: return "clarification";
        case RequestIntent.analysis: return "analysis";
        case RequestIntent.implementation: return "implementation";
        case RequestIntent.continuation: return "continuation";
    }
}

bool explanationOnlyRequest(string text)
{
    if (requestIntent(text) != RequestIntent.clarification) return false;
    const words = requestWords(text);
    return words.canFind("why") || words.canFind("explain") || words.canFind("explanation");
}

bool answerOnlyRequest(string text) { return requestIntent(text) == RequestIntent.clarification; }

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
