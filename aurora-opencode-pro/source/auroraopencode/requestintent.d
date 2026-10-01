module auroraopencode.requestintent;

import std.algorithm : canFind;
import std.string : toLower, split;

/// Recognize explicit explanation-only steering, rather than assuming every
/// follow-up authorizes continuing an older checklist. Action requests win when
/// the user asks for both diagnosis and work ("explain why and fix it").
bool explanationOnlyRequest(string text)
{
    auto words = toLower(text).split();
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
                "try", "finish", "complete", "select"].canFind(word))
        {
            if (i == 0 || ["and", "then", "please"].canFind(words[i - 1])) return false;
            if (i >= 2 && words[i - 1] == "you" && words[i - 2] == "can") return false;
            if (i >= 3 && words[i - 1] == "to" && words[i - 2] == "you" &&
                words[i - 3] == "want") return false;
        }
    return true;
}
