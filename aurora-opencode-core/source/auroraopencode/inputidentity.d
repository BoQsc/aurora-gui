module auroraopencode.inputidentity;

import auroraopencode.core : ChatSession;

/// The complete graph and durable pending queues are the authority. Branch
/// navigation cannot make a previously admitted submission new again.
public bool inputRecorded(const ref ChatSession session, string inputId, bool committedOnly = true)
{
    if (!inputId.length) return false;
    foreach_reverse (message; session.messages) if (message.inputId == inputId && (!committedOnly || message.inputCommitted)) return true;
    foreach (context; session.queuedGuidanceContext) if (context.inputId == inputId && (!committedOnly || context.inputCommitted)) return true;
    foreach (context; session.queuedFollowUpContext) if (context.inputId == inputId && (!committedOnly || context.inputCommitted)) return true;
    return false;
}
public void markInputCommitted(ref ChatSession session, string inputId)
{
    foreach (ref message; session.messages) if (message.inputId == inputId) message.inputCommitted = true;
    foreach (ref context; session.queuedGuidanceContext) if (context.inputId == inputId) context.inputCommitted = true;
    foreach (ref context; session.queuedFollowUpContext) if (context.inputId == inputId) context.inputCommitted = true;
}
