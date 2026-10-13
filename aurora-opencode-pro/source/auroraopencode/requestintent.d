module auroraopencode.requestintent;

import std.algorithm : canFind;
import std.string : toLower, split;

/// Recognize explicit explanation-only steering, rather than assuming every
/// follow-up authorizes continuing an older checklist. Action requests win when
/// the user asks for both diagnosis and work ("explain why and fix it").
bool explanationOnlyRequest(string text)
{
    const raw = toLower(text).split();
    auto words = raw.dup;
    foreach (ref word; words)
    {
        while (word.length && ",.!?:;".canFind(word[$ - 1])) word = word[0 .. $ - 1];
    }
    const diagnostic = words.canFind("why") || words.canFind("explain") ||
        words.canFind("explanation");
    if (!diagnostic) return false;
    foreach (i, word; words)
        if (["continue", "resume", "retry", "fix", "repair", "implement",
                "change", "test", "inspect", "check", "launch", "play", "run",
                "try", "finish", "complete", "select", "update", "build", "resolve",
                "help", "take", "look", "make", "write"].canFind(word))
        {
            const sentenceStart = i > 0 && raw[i - 1].length &&
                ".!?".canFind(raw[i - 1][$ - 1]);
            if (i == 0 || sentenceStart || ["and", "then", "please", "let's"].canFind(words[i - 1])) return false;
            if (i >= 2 && words[i - 1] == "you" &&
                ["can", "could", "would"].canFind(words[i - 2])) return false;
            if (i >= 3 && words[i - 1] == "to" && words[i - 2] == "you" &&
                words[i - 3] == "want") return false;
        }
    return true;
}

/// Questions about an older task do not authorize resuming its implementation.
bool answerOnlyRequest(string text)
{
    if (explanationOnlyRequest(text)) return true;
    const raw = toLower(text).split();
    auto words = raw.dup;
    if (!words.length) return false;
    foreach (ref word; words)
        while (word.length && ",.!?:;".canFind(word[$ - 1])) word = word[0 .. $ - 1];
    if (!["what", "how", "when", "where", "who", "which", "is", "are",
            "does", "did", "do", "can", "could", "would"].canFind(words[0])) return false;
    foreach (i, word; words)
        if (["continue", "resume", "retry", "fix", "repair", "implement",
                "change", "test", "inspect", "check", "launch", "play", "run",
                "try", "finish", "complete", "select", "update", "build", "resolve",
                "help", "take", "look", "make", "write"].canFind(word))
        {
            const sentenceStart = i > 0 && raw[i - 1].length &&
                ".!?".canFind(raw[i - 1][$ - 1]);
            if (sentenceStart || (i > 0 && ["and", "then", "please", "let's"].canFind(words[i - 1]))) return false;
            if (i >= 2 && words[i - 1] == "you" &&
                ["can", "could", "would"].canFind(words[i - 2])) return false;
        }
    return true;
}
