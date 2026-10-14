module auroraopencode.projectdriver;

// ===========================================================================
// Per-project "project manager" prompt assembly (see docs/project-driver.md).
//
// The manager is one persistent special conversation per project. When the user
// reviews a project, the UI hands this module the project's recent
// conversations and gets back the prompt that opens a new working conversation
// to move the project forward. The assembly is pure - no widgets, no network -
// so it can be unit-tested on its own and the UI keeps only the small hook that
// creates and seeds the conversation.
// ===========================================================================

import auroraopencode.core : ChatMessage, ChatSession, chatTitle;
import auroraopencode.turnsummary : turnOpeningSentence;
import std.algorithm : canFind;
import std.array : appender;

/// Most characters of one digest line, so a single long message cannot dominate
/// the review prompt.
private enum size_t digestLineCharacters = 240;

/// The review prompt: a bounded digest of the project's most recent
/// conversations (most recent first) plus instructions to move the project
/// forward. `recent` is expected to be the project's conversations, already
/// filtered (the manager thread itself excluded) and sorted newest-first.
public string buildProjectReviewPrompt(string projectName, string projectPath,
    ChatSession[] recent, size_t maxConversations = 5, size_t maxMessages = 6,
    bool planOnly = false)
{
    auto prompt = appender!string();
    prompt.put("You are the project manager for the project \"");
    prompt.put(projectName.length > 0 ? projectName : "untitled");
    prompt.put("\"");
    if (projectPath.length > 0)
    {
        prompt.put(" (folder: ");
        prompt.put(projectPath);
        prompt.put(")");
    }
    prompt.put(".\n\n");
    prompt.put("Review the recent activity below and move this project forward: ");
    prompt.put("decide the single most valuable next step, state the goal and a ");
    prompt.put("concrete plan, then carry it out. Inspect the workspace ");
    prompt.put("(git status/diff) before deciding. Ask before anything ");
    prompt.put("destructive. Keep it concise.\n");
    if (planOnly)
    {
        prompt.put("Do not modify any files: produce a plan and recommend the ");
        prompt.put("next step only.\n");
    }
    if (recent.length == 0)
    {
        prompt.put("\nThere is no prior conversation activity recorded for this ");
        prompt.put("project yet. Use the workspace tools to see what exists and ");
        prompt.put("propose the first useful step.");
        return prompt.data;
    }
    prompt.put("\nRecent conversations in this project (most recent first):\n");
    size_t shown;
    foreach (session; recent)
    {
        if (shown >= maxConversations) break;
        ++shown;
        prompt.put("\n### ");
        prompt.put(session.title.length > 0 ? session.title : "Untitled");
        if (session.objective.length > 0)
        {
            prompt.put("\n- objective: ");
            prompt.put(session.objective);
        }
        if (session.taskStatus.length > 0)
        {
            prompt.put("\n- task status: ");
            prompt.put(session.taskStatus);
        }
        if (session.verificationStatus.length > 0)
        {
            prompt.put("\n- verification: ");
            prompt.put(session.verificationStatus);
        }
        const total = session.messages.length;
        if (total == 0) continue;
        const start = total > maxMessages ? total - maxMessages : 0;
        foreach (message; session.messages[start .. total])
        {
            const text = digestLine(message);
            if (text.length == 0) continue;
            prompt.put("\n- ");
            prompt.put(message.role.length > 0 ? message.role : "message");
            prompt.put(": ");
            prompt.put(text);
        }
    }
    return prompt.data;
}

/// One readable digest line. Assistant prose is reduced to its opening sentence
/// (as the transcript header does); everything is character-bounded so a long
/// message cannot blow the prompt budget.
private string digestLine(const ref ChatMessage message)
{
    if (message.content.length == 0) return "";
    if (message.role == "assistant")
        return turnOpeningSentence(message.content);
    return chatTitle(message.content, digestLineCharacters);
}

unittest
{
    ChatSession session;
    session.title = "Fix the parser";
    session.objective = "Make the parser handle empty input";
    session.taskStatus = "active";
    session.verificationStatus = "not_required";
    ChatMessage first;
    first.role = "user";
    first.content = "please fix it";
    session.messages ~= first;

    const prompt = buildProjectReviewPrompt("Demo", "C:/demo", [session]);
    assert(prompt.canFind("Fix the parser"));
    assert(prompt.canFind("Make the parser handle empty input"));
    assert(prompt.canFind("please fix it"));

    // An empty project still produces a usable, self-contained prompt.
    const empty = buildProjectReviewPrompt("Fresh", "", null);
    assert(empty.canFind("no prior conversation activity"));
}
