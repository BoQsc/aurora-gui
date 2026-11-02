module auroraopencode.queuedprompts;

import auroraopencode.core : ChatSession, ChatPromptContext;

public void queuePrompt(ref ChatSession session, string text, ChatPromptContext context, bool steering)
{
    auto texts = steering ? &session.queuedGuidance : &session.queuedFollowUps;
    auto contexts = steering ? &session.queuedGuidanceContext : &session.queuedFollowUpContext;
    // Legacy text additions need no attachment slots until one is supplied.
    if (context.text.length || context.images.length || context.inputId.length)
    { (*contexts).length = (*texts).length; *contexts ~= context; }
    *texts ~= text;
}

public struct QueuedPrompt { string text; ChatPromptContext context; }

public QueuedPrompt takeQueuedPrompt(ref ChatSession session, bool steering, size_t index = 0)
{
    auto texts = steering ? &session.queuedGuidance : &session.queuedFollowUps;
    auto contexts = steering ? &session.queuedGuidanceContext : &session.queuedFollowUpContext;
    if (index >= (*texts).length) throw new Exception("Pending prompt is unavailable");
    QueuedPrompt result; result.text = (*texts)[index];
    if (index < (*contexts).length)
    {
        result.context = (*contexts)[index];
        *contexts = (*contexts)[0 .. index] ~ (*contexts)[index + 1 .. $];
    }
    *texts = (*texts)[0 .. index] ~ (*texts)[index + 1 .. $];
    return result;
}
